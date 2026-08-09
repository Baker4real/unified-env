[CmdletBinding()]
param(
    [ValidateSet('All', 'ProducerFencing', 'Retry', 'Reclaim')]
    [string]$Slice = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$producerLeaseFixturePath = Join-Path $PSScriptRoot 'Open-CodexSafeTreeDeleteProducerLeaseFixture.ps1'
$restoreCrashFixturePath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteRestoreCrashFixture.ps1'
$purgeCrashFixturePath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteCrashFixture.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-control-plane-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$producerProcess = $null
$crashedProducerProcess = $null
$lateProducerProcess = $null
$retryCrashProcess = $null

. $hostSafetyLibraryPath

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action | Out-Null } catch { return $_.Exception.Message }
    throw $Message
}

function Assert-MetricsContract {
    param(
        [Parameter(Mandatory)][object]$Metrics,
        [Parameter(Mandatory)][string]$Phase
    )

    Assert-True `
        ((@($Metrics.PSObject.Properties.Name) -join '|') -ceq
            'schemaVersion|phase|elapsedMs|entriesScanned|logicalBytes|bytesHashed|retry') `
        "$Phase metrics 属性结构必须稳定"
    Assert-True ($Metrics.schemaVersion -eq 1 -and [string]$Metrics.phase -ceq $Phase) `
        "$Phase metrics 必须使用统一版本和 phase"
    Assert-True ($Metrics.elapsedMs -is [long] -and [long]$Metrics.elapsedMs -ge 0L) `
        "$Phase metrics elapsedMs 必须是非负 integer"
    Assert-True (
        (@($Metrics.retry.PSObject.Properties.Name) -join '|') -ceq
            'contract|attempts|result|events') `
        "$Phase retry metrics 属性结构必须稳定"
    Assert-True ($Metrics.retry.attempts -is [long] -and [long]$Metrics.retry.attempts -ge 0L) `
        "$Phase retry attempts 必须是非负 integer"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Metrics.retry.result)) `
        "$Phase retry result 不得静默缺失"
}

function Get-FixtureFileState {
    param([Parameter(Mandatory)][string]$Root)

    $state = [Collections.Generic.List[object]]::new()
    if (-not [IO.Directory]::Exists($Root)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Force -Recurse | Sort-Object -Property FullName)) {
        $snapshot = Get-CodexHookCapabilityFileSnapshot `
            -Path $file.FullName `
            -CapabilityRoot $Root `
            -AllowedExactPaths @($file.FullName) `
            -Name 'safe-delete Status immutability fixture file'
        $state.Add([pscustomobject][ordered]@{
            relativePath = [IO.Path]::GetRelativePath($Root, $file.FullName)
            kind = 'file'
            identity = @($snapshot.identity)
            sha256 = [string]$snapshot.sha256
        })
    }
    return @($state)
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete control-plane test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete control-plane test cleanup'
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexSafeDeleteTests
{
    public static class ProcessSuspension
    {
        private const uint ThreadSuspendResume = 0x0002;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenThread(uint desiredAccess, bool inheritHandle, uint threadId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SuspendThread(IntPtr threadHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr threadHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static int[] Suspend(int processId)
        {
            var threadIds = new List<int>();
            using (var process = Process.GetProcessById(processId))
            {
                foreach (ProcessThread thread in process.Threads)
                {
                    threadIds.Add(thread.Id);
                }
            }

            var suspended = new List<int>();
            foreach (var threadId in threadIds)
            {
                var handle = OpenThread(ThreadSuspendResume, false, (uint)threadId);
                if (handle == IntPtr.Zero) continue;
                try
                {
                    if (SuspendThread(handle) != uint.MaxValue) suspended.Add(threadId);
                }
                finally
                {
                    CloseHandle(handle);
                }
            }
            if (suspended.Count == 0) throw new InvalidOperationException("No process threads could be suspended.");
            return suspended.ToArray();
        }

        public static void Resume(int[] threadIds)
        {
            foreach (var threadId in threadIds)
            {
                var handle = OpenThread(ThreadSuspendResume, false, (uint)threadId);
                if (handle == IntPtr.Zero) continue;
                try
                {
                    ResumeThread(handle);
                }
                finally
                {
                    CloseHandle(handle);
                }
            }
        }
    }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexSafeDeleteTests
{
    public sealed class DeletePendingFileProbe : IDisposable
    {
        private const uint GenericRead = 0x80000000;
        private const uint DeleteAccess = 0x00010000;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const int FileDispositionInfo = 4;
        private SafeFileHandle handle;
        private bool pending;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFileDispositionInfo
        {
            [MarshalAs(UnmanagedType.U1)]
            public bool DeleteFile;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle fileHandle,
            int fileInformationClass,
            ref NativeFileDispositionInfo fileInformation,
            uint bufferSize);

        public DeletePendingFileProbe(string path)
        {
            handle = CreateFileW(
                path,
                GenericRead | DeleteAccess,
                FileShare.Read | FileShare.Write | FileShare.Delete,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to open the delete-pending fixture file.");
            }
            SetPending(true);
            pending = true;
        }

        public void Cancel()
        {
            if (!pending) return;
            SetPending(false);
            pending = false;
        }

        public void Dispose()
        {
            if (handle == null) return;
            if (pending) Cancel();
            handle.Dispose();
            handle = null;
        }

        private void SetPending(bool value)
        {
            NativeFileDispositionInfo disposition = new NativeFileDispositionInfo { DeleteFile = value };
            if (!SetFileInformationByHandle(
                handle,
                FileDispositionInfo,
                ref disposition,
                checked((uint)Marshal.SizeOf<NativeFileDispositionInfo>())))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    value
                        ? "Unable to mark the fixture file delete-pending."
                        : "Unable to cancel delete-pending for the fixture file.");
            }
        }
    }

    public sealed class MappedImageProbe : IDisposable
    {
        private const uint GenericRead = 0x80000000;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint PageReadOnly = 0x00000002;
        private const uint SectionImage = 0x01000000;
        private const uint FileMapRead = 0x0004;
        private IntPtr mapping;
        private IntPtr view;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileMappingW(
            SafeFileHandle fileHandle,
            IntPtr securityAttributes,
            uint protect,
            uint maximumSizeHigh,
            uint maximumSizeLow,
            string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr MapViewOfFile(
            IntPtr fileMapping,
            uint desiredAccess,
            uint fileOffsetHigh,
            uint fileOffsetLow,
            UIntPtr bytesToMap);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnmapViewOfFile(IntPtr baseAddress);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public MappedImageProbe(string path)
        {
            using (SafeFileHandle file = CreateFileW(
                path,
                GenericRead,
                FileShare.Read | FileShare.Write | FileShare.Delete,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal,
                IntPtr.Zero))
            {
                if (file.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open the mapped-image fixture.");
                }
                mapping = CreateFileMappingW(
                    file,
                    IntPtr.Zero,
                    PageReadOnly | SectionImage,
                    0,
                    0,
                    null);
                if (mapping == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to create the image section fixture.");
                }
            }
            view = MapViewOfFile(mapping, FileMapRead, 0, 0, UIntPtr.Zero);
            if (view == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(mapping);
                mapping = IntPtr.Zero;
                throw new Win32Exception(error, "Unable to map the image section fixture.");
            }
        }

        public byte ReadFirstByte()
        {
            if (view == IntPtr.Zero) throw new ObjectDisposedException(nameof(MappedImageProbe));
            return Marshal.ReadByte(view);
        }

        public void Dispose()
        {
            if (view != IntPtr.Zero)
            {
                UnmapViewOfFile(view);
                view = IntPtr.Zero;
            }
            if (mapping != IntPtr.Zero)
            {
                CloseHandle(mapping);
                mapping = IntPtr.Zero;
            }
        }
    }
}
'@

$script:reclaimCheckCount = 0

function Assert-ReclaimTrue {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)

    $script:reclaimCheckCount++
    Assert-True -Condition $Condition -Message $Message
}

function Assert-UnknownReclaimOutcome {
    param(
        [Parameter(Mandatory)][object]$Outcome,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][bool]$LogicalCompletion
    )

    Assert-ReclaimTrue `
        ((@($Outcome.PSObject.Properties.Name) -join '|') -ceq
            'schemaVersion|namespaceAbsent|logicalCompletion|physicalReclaimStatus|physicalReclaimReason') `
        "$Scope deletion outcome 字段必须使用统一版本化合同"
    Assert-ReclaimTrue ($Outcome.schemaVersion -eq 1) "$Scope deletion outcome schema 必须为 1"
    Assert-ReclaimTrue ([bool]$Outcome.logicalCompletion -eq $LogicalCompletion) `
        "$Scope logical completion 必须与 transaction 生命周期一致"
    Assert-ReclaimTrue ($Outcome.physicalReclaimStatus -ceq 'unknown') `
        "$Scope 不得把 namespace absence 冒充 physical reclaim"
    Assert-ReclaimTrue (
        $Outcome.physicalReclaimReason -ceq
            'independent-filesystem-allocation-evidence-unavailable') `
        "$Scope 必须说明缺少独立文件系统分配证据"
}

function New-ReclaimCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$AllowHardLinks = $false,
        [string]$Payload = 'reclaim-fixture'
    )

    $target = Join-Path $fixtureRoot "reclaim-$Name"
    $evidence = Join-Path $fixtureRoot "reclaim-$Name-evidence"
    $policyPath = Join-Path $fixtureRoot "reclaim-$Name-policy.json"
    [void][IO.Directory]::CreateDirectory($target)
    [void][IO.Directory]::CreateDirectory($evidence)
    $payloadPath = Join-Path $target 'payload.bin'
    [IO.File]::WriteAllText($payloadPath, $Payload, [Text.UTF8Encoding]::new($false))
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 5
        entries = @([pscustomobject][ordered]@{
            id = "reclaim-$Name"
            capabilityRoot = $target
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            allowHardLinks = $AllowHardLinks
            allowInternalDirectoryJunctions = $false
            minimumQuarantineAgeMinutes = 0
            producerFenceMode = 'os-handle-required'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    return [pscustomobject][ordered]@{
        target = $target
        evidence = $evidence
        policyPath = $policyPath
        payloadPath = $payloadPath
        payload = $Payload
    }
}

function Invoke-ReclaimPlanApply {
    param([Parameter(Mandatory)][object]$Case)

    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath ([string]$Case.target) `
        -CapabilityRoot ([string]$Case.target) `
        -FixturePolicyPath ([string]$Case.policyPath) `
        -FixtureEvidenceRoot ([string]$Case.evidence)
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath ([string]$Case.policyPath) `
        -FixtureEvidenceRoot ([string]$Case.evidence)
    return [pscustomobject][ordered]@{ plan = $plan; apply = $apply }
}

function Invoke-ReclaimPurge {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][object]$Apply,
        [string]$ApprovedTransactionSha256 = ([string]$Apply.transactionSha256)
    )

    return & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$Apply.transactionPath) `
        -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
        -ConfirmPurge `
        -FixturePolicyPath ([string]$Case.policyPath) `
        -FixtureEvidenceRoot ([string]$Case.evidence)
}

function Get-ReclaimStatusOperation {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][string]$TransactionPath
    )

    $status = & $entryPath `
        -Mode Status `
        -FixturePolicyPath ([string]$Case.policyPath) `
        -FixtureEvidenceRoot ([string]$Case.evidence)
    $operationId = Split-Path -Leaf (Split-Path -Parent $TransactionPath)
    $operation = @($status.operations | Where-Object { [string]$_.operationId -ceq $operationId })
    Assert-ReclaimTrue ($operation.Count -eq 1) 'Reclaim Status 必须定位精确 operation'
    return $operation[0]
}

function Invoke-ReclaimScenarios {
    $script:reclaimCheckCount = 0
    $ordinary = New-ReclaimCase -Name 'ordinary' -Payload 'ordinary-allocation'
    $ordinaryLifecycle = Invoke-ReclaimPlanApply -Case $ordinary
    $ordinaryPurge = Invoke-ReclaimPurge -Case $ordinary -Apply $ordinaryLifecycle.apply
    Assert-ReclaimTrue ($ordinaryPurge.purged -eq $true -and $ordinaryPurge.namespaceAbsent -eq $true) `
        '普通文件 Purge 必须按 namespace/transaction 成功'
    Assert-UnknownReclaimOutcome `
        -Outcome $ordinaryPurge.deletionOutcome -Scope '普通文件 Purge' -LogicalCompletion $true
    $ordinaryStatus = Get-ReclaimStatusOperation `
        -Case $ordinary -TransactionPath ([string]$ordinaryPurge.transactionPath)
    Assert-UnknownReclaimOutcome `
        -Outcome $ordinaryStatus.deletionOutcome -Scope '普通文件 Status' -LogicalCompletion $true
    Assert-ReclaimTrue (
        $ordinaryStatus.physicalReclaimReason -ceq
            $ordinaryPurge.physicalReclaimReason) `
        'Status 与 Purge 顶层必须使用同一 physical reclaim reason'
    Assert-ReclaimTrue (
        ($ordinaryPurge | ConvertTo-Json -Depth 12) -notmatch
            'physicalBytes|reclaimedBytes|diskSavings') `
        'Purge 不得宣称精确物理字节或磁盘收益'

    $hardlink = New-ReclaimCase -Name 'hardlink-external' `
        -AllowHardLinks $true -Payload 'shared-allocation'
    $hardlinkAliasPath = Join-Path $fixtureRoot 'reclaim-hardlink-external-alias.bin'
    [void](New-Item -ItemType HardLink -Path $hardlinkAliasPath `
        -Target ([string]$hardlink.payloadPath) -ErrorAction Stop)
    $hardlinkLifecycle = Invoke-ReclaimPlanApply -Case $hardlink
    $hardlinkPurge = Invoke-ReclaimPurge -Case $hardlink -Apply $hardlinkLifecycle.apply
    Assert-ReclaimTrue ([IO.File]::Exists($hardlinkAliasPath)) '外部 hardlink alias 必须继续存在'
    Assert-ReclaimTrue ([IO.File]::ReadAllText($hardlinkAliasPath) -ceq 'shared-allocation') `
        'Purge 不得损坏外部 hardlink alias 内容'
    Assert-UnknownReclaimOutcome `
        -Outcome $hardlinkPurge.deletionOutcome -Scope '外部 hardlink Purge' -LogicalCompletion $true

    $multiName = New-ReclaimCase -Name 'multiple-names' `
        -AllowHardLinks $true -Payload 'same-object-two-names'
    $secondName = Join-Path $multiName.target 'payload-second-name.bin'
    [void](New-Item -ItemType HardLink -Path $secondName `
        -Target ([string]$multiName.payloadPath) -ErrorAction Stop)
    $multiNameLifecycle = Invoke-ReclaimPlanApply -Case $multiName
    $payloadBytes = [Text.UTF8Encoding]::new($false).GetByteCount([string]$multiName.payload)
    Assert-ReclaimTrue ($multiNameLifecycle.plan.metrics.logicalBytes -eq (2L * $payloadBytes)) `
        '多名称对象 logicalBytes 必须按 namespace entry 累计，不能冒充唯一物理分配'
    $multiNamePurge = Invoke-ReclaimPurge -Case $multiName -Apply $multiNameLifecycle.apply
    Assert-ReclaimTrue (-not [IO.Directory]::Exists([string]$multiName.target)) `
        '多名称对象 Purge 必须删除目标 namespace'
    Assert-UnknownReclaimOutcome `
        -Outcome $multiNamePurge.deletionOutcome -Scope '多名称对象 Purge' -LogicalCompletion $true

    $openHandle = New-ReclaimCase -Name 'open-handle' -Payload 'held-readable-bytes'
    $openLifecycle = Invoke-ReclaimPlanApply -Case $openHandle
    $heldPath = Join-Path $openLifecycle.apply.quarantinePath 'payload.bin'
    $heldStream = [IO.FileStream]::new(
        $heldPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $openPurge = Invoke-ReclaimPurge -Case $openHandle -Apply $openLifecycle.apply
        Assert-ReclaimTrue ($openPurge.purged -eq $true -and -not [IO.File]::Exists($heldPath)) `
            'delete-sharing open handle 不得阻止 namespace/transaction 完成'
        Assert-ReclaimTrue ($heldStream.ReadByte() -eq [byte][char]'h') `
            'namespace 删除后开放句柄必须仍能读取原对象'
        Assert-UnknownReclaimOutcome `
            -Outcome $openPurge.deletionOutcome -Scope '开放句柄 Purge' -LogicalCompletion $true
    } finally {
        $heldStream.Dispose()
    }

    $deletePending = New-ReclaimCase -Name 'delete-pending' -Payload 'pending-allocation'
    $pendingLifecycle = Invoke-ReclaimPlanApply -Case $deletePending
    $pendingPath = Join-Path $pendingLifecycle.apply.quarantinePath 'payload.bin'
    $pendingProbe = [CodexSafeDeleteTests.DeletePendingFileProbe]::new($pendingPath)
    try {
        $pendingError = Assert-Throws `
            -Message 'delete-pending leaf 必须令 Purge 失败闭锁' `
            -Action { Invoke-ReclaimPurge -Case $deletePending -Apply $pendingLifecycle.apply }
        Assert-ReclaimTrue (-not [string]::IsNullOrWhiteSpace($pendingError)) `
            'delete-pending Purge 必须返回可观察失败'
        $pendingStatus = Get-ReclaimStatusOperation `
            -Case $deletePending -TransactionPath ([string]$pendingLifecycle.apply.transactionPath)
        Assert-UnknownReclaimOutcome `
            -Outcome $pendingStatus.deletionOutcome `
            -Scope 'delete-pending Status' `
            -LogicalCompletion $false
        $pendingProbe.Cancel()
    } finally {
        $pendingProbe.Dispose()
    }
    $pendingTransaction = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$pendingLifecycle.apply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $pendingLifecycle.apply.transactionPath) `
        -AllowedExactPaths @([string]$pendingLifecycle.apply.transactionPath) `
        -Name 'delete-pending transaction after probe release'
    $pendingPurge = Invoke-ReclaimPurge `
        -Case $deletePending `
        -Apply $pendingLifecycle.apply `
        -ApprovedTransactionSha256 ([string]$pendingTransaction.sha256)
    Assert-UnknownReclaimOutcome `
        -Outcome $pendingPurge.deletionOutcome `
        -Scope 'delete-pending release Purge' `
        -LogicalCompletion $true

    $mappedImage = New-ReclaimCase -Name 'mapped-image' -Payload 'replaced-by-pe-image'
    [IO.File]::Delete([string]$mappedImage.payloadPath)
    [IO.File]::Copy(
        [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,
        [string]$mappedImage.payloadPath)
    $mappedLifecycle = Invoke-ReclaimPlanApply -Case $mappedImage
    $mappedPath = Join-Path $mappedLifecycle.apply.quarantinePath 'payload.bin'
    $imageProbe = [CodexSafeDeleteTests.MappedImageProbe]::new($mappedPath)
    $mappedPurge = $null
    $mappedImageBlockedNamespaceRemoval = $false
    try {
        $mappedError = $null
        try {
            $mappedPurge = Invoke-ReclaimPurge -Case $mappedImage -Apply $mappedLifecycle.apply
        } catch {
            $mappedError = $_.Exception.Message
        }
        Assert-ReclaimTrue ($imageProbe.ReadFirstByte() -eq 0x4d) `
            'SEC_IMAGE view 必须在 Purge 尝试后继续提供真实 PE 映射'
        if ($null -eq $mappedPurge) {
            $mappedImageBlockedNamespaceRemoval = $true
            Assert-ReclaimTrue (-not [string]::IsNullOrWhiteSpace($mappedError)) `
                'mapped image 阻塞删除时必须返回可观察失败'
            $mappedStatus = Get-ReclaimStatusOperation `
                -Case $mappedImage -TransactionPath ([string]$mappedLifecycle.apply.transactionPath)
            Assert-UnknownReclaimOutcome `
                -Outcome $mappedStatus.deletionOutcome `
                -Scope 'mapped image Status' `
                -LogicalCompletion $false
        } else {
            Assert-UnknownReclaimOutcome `
                -Outcome $mappedPurge.deletionOutcome `
                -Scope 'mapped image Purge' `
                -LogicalCompletion $true
        }
    } finally {
        $imageProbe.Dispose()
    }
    if ($null -eq $mappedPurge) {
        $mappedTransaction = Get-CodexHookCapabilityFileSnapshot `
            -Path ([string]$mappedLifecycle.apply.transactionPath) `
            -CapabilityRoot (Split-Path -Parent $mappedLifecycle.apply.transactionPath) `
            -AllowedExactPaths @([string]$mappedLifecycle.apply.transactionPath) `
            -Name 'mapped image transaction after unmap'
        $mappedPurge = Invoke-ReclaimPurge `
            -Case $mappedImage `
            -Apply $mappedLifecycle.apply `
            -ApprovedTransactionSha256 ([string]$mappedTransaction.sha256)
        Assert-UnknownReclaimOutcome `
            -Outcome $mappedPurge.deletionOutcome `
            -Scope 'mapped image release Purge' `
            -LogicalCompletion $true
    }

    return [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteReclaim'
        scenarios = 6
        checks = $script:reclaimCheckCount
        observedOsBehavior = [pscustomobject][ordered]@{
            ordinaryFile = 'namespace-removed-physical-unknown'
            externalHardlinkAlias = 'alias-survived-physical-unknown'
            multipleNames = 'logical-bytes-counted-per-name-physical-unknown'
            openHandle = 'namespace-removed-handle-remained-readable-physical-unknown'
            deletePending = 'purge-blocked-until-cancelled-physical-unknown'
            mappedImage = if ($mappedImageBlockedNamespaceRemoval) {
                'purge-blocked-until-unmapped-physical-unknown'
            } else {
                'namespace-removed-view-remained-readable-physical-unknown'
            }
        }
    }
}

function Invoke-RestoreCrashCase {
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $target = Join-Path $CapabilityRoot ("restore-crash-$($Scenario.Replace('after-', ''))")
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText(
        (Join-Path $target 'payload.txt'),
        "restore-crash-$Scenario",
        [Text.UTF8Encoding]::new($false))
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $target `
        -CapabilityRoot $CapabilityRoot `
        -FixturePolicyPath $PolicyPath `
        -FixtureEvidenceRoot $EvidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $PolicyPath `
        -FixtureEvidenceRoot $EvidenceRoot
    $markerPath = Join-Path $CapabilityRoot ("restore-crash-$($Scenario.Replace('after-', '')).marker")
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $restoreCrashFixturePath,
            '-TransactionPath', [string]$apply.transactionPath,
            '-ApprovedTransactionSha256', [string]$apply.transactionSha256,
            '-FixturePolicyPath', $PolicyPath,
            '-FixtureEvidenceRoot', $EvidenceRoot,
            '-MarkerPath', $markerPath,
            '-Scenario', $Scenario)) {
        [void]$processInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($processInfo)
    try {
        Assert-True ($process.WaitForExit(15000)) "Restore crash $Scenario 必须在超时内退出"
        Assert-True ($process.ExitCode -ne 0) "Restore crash $Scenario 必须非零退出"
        Assert-True ([IO.File]::Exists($markerPath)) "Restore crash $Scenario 必须到达精确 checkpoint"
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        [void]$process.WaitForExit(10000)
        $process.Dispose()
    }
    $transactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$apply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $apply.transactionPath) `
        -AllowedExactPaths @([string]$apply.transactionPath) `
        -Name "Restore crash $Scenario transaction"
    $replay = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
        -ConfirmRestore `
        -FixturePolicyPath $PolicyPath `
        -FixtureEvidenceRoot $EvidenceRoot
    Assert-True ($replay.restored -eq $true) "Restore crash $Scenario 必须可安全重放"
    Assert-True ([IO.Directory]::Exists($target)) "Restore crash $Scenario 重放后 target 必须存在"
    Assert-True (-not [IO.Directory]::Exists([string]$apply.quarantinePath)) `
        "Restore crash $Scenario 重放后 quarantine 必须消失"
    $restoreJournals = @(Get-ChildItem -LiteralPath (Split-Path -Parent $apply.transactionPath) `
        -Filter 'restore-*.json' -File -Force)
    Assert-True ($restoreJournals.Count -eq 4) `
        "Restore crash $Scenario 只能保留 intent、rename、verify 与 complete 四份一致 journal"
}

try {
    if ($Slice -ceq 'Reclaim') {
        Invoke-ReclaimScenarios
        return
    }

    [void][IO.Directory]::CreateDirectory($targetPath)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [IO.File]::WriteAllText(
        (Join-Path $targetPath 'payload.txt'),
        'status-must-not-mutate-this-tree',
        [Text.UTF8Encoding]::new($false))
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @([pscustomobject][ordered]@{
            id = 'control-plane-fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            deniedExactPaths = @($evidenceRoot)
        })
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($plan.planned -eq $true) 'control-plane fixture Plan 必须成功'
    Assert-True ($plan.metrics.schemaVersion -eq 1) 'Plan 必须输出版本化 metrics'
    Assert-True ($plan.metrics.phase -ceq 'plan') 'Plan metrics 必须标明阶段'
    Assert-MetricsContract -Metrics $plan.metrics -Phase 'plan'
    Assert-True ($plan.metrics.entriesScanned -eq 2) 'Plan metrics 必须计入根目录和文件'
    Assert-True ($plan.metrics.logicalBytes -eq 32) 'Plan metrics 必须报告文件逻辑字节'
    $policyBytes = [long](Get-Item -LiteralPath $policyPath).Length
    $planBytes = [long](Get-Item -LiteralPath $plan.planPath).Length
    Assert-True ($plan.metrics.bytesHashed -eq ($policyBytes + 32L + $planBytes)) `
        'Plan metrics 必须精确累计 policy、payload 与发布 plan 的实际哈希读取字节'
    Assert-True ($plan.metrics.retry.attempts -eq 0) 'Plan metrics 必须显式报告零 retry'

    $beforeStatus = @(Get-FixtureFileState -Root $fixtureRoot)
    $status = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $afterStatus = @(Get-FixtureFileState -Root $fixtureRoot)

    Assert-True ($status.artifactType -ceq 'env-governance.codex-safe-tree-delete-status') `
        'Status 必须输出稳定 artifactType'
    Assert-True ($status.schemaVersion -eq 1) 'Status 必须输出稳定 schemaVersion'
    Assert-True ($status.complete -eq $true) '健康 evidence 的 Status 必须完整'
    Assert-True (@($status.operations).Count -eq 1) 'Status 必须枚举健康 operation'
    Assert-True ($status.operations[0].lifecycle -ceq 'planned') '未 Apply 的计划必须分类为 planned'
    Assert-True ($status.operations[0].targetPresent -eq $true) 'Status 必须读取 live target presence'
    Assert-True ($status.operations[0].quarantinePresent -eq $false) 'Status 必须读取 live quarantine presence'
    Assert-True ($status.metrics.schemaVersion -eq 1) 'Status 必须输出统一 metrics'
    Assert-MetricsContract -Metrics $status.metrics -Phase 'status'
    Assert-True ($status.metrics.bytesHashed -eq ((2L * $policyBytes) + (2L * $planBytes) + 32L)) `
        'Status metrics 必须精确累计 policy、plan 双重认证与 live payload 哈希读取'
    Assert-True (
        (($beforeStatus | ConvertTo-Json -Depth 8 -Compress) -ceq
            ($afterStatus | ConvertTo-Json -Depth 8 -Compress))) `
        'Status 不得改变 fixture 中任何文件 bytes'

    $invalidRun = Join-Path $evidenceRoot 'invalid-record'
    [void][IO.Directory]::CreateDirectory($invalidRun)
    [IO.File]::WriteAllText(
        (Join-Path $invalidRun 'transaction.json'),
        '{ invalid json',
        [Text.UTF8Encoding]::new($false))
    $mixedStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($mixedStatus.complete -eq $false) '畸形记录必须令全局 Status incomplete'
    Assert-True (@($mixedStatus.operations).Count -eq 2) '畸形记录不得隐藏健康 operation'
    Assert-True (@($mixedStatus.operations | Where-Object lifecycle -ceq 'planned').Count -eq 1) `
        '混合 Status 必须保留健康记录分类'
    Assert-True (@($mixedStatus.operations | Where-Object lifecycle -ceq 'manual-review').Count -eq 1) `
        '畸形记录必须隔离为 manual-review'

    $repeatEvidenceRoot = Join-Path $fixtureRoot 'repeat-evidence'
    [void][IO.Directory]::CreateDirectory($repeatEvidenceRoot)
    $repeatMetrics = [Collections.Generic.List[object]]::new()
    foreach ($repeatName in @('repeat-a', 'repeat-b')) {
        $repeatTarget = Join-Path $fixtureRoot $repeatName
        [void][IO.Directory]::CreateDirectory($repeatTarget)
        [IO.File]::WriteAllText(
            (Join-Path $repeatTarget 'payload.txt'),
            ('x' * 32),
            [Text.UTF8Encoding]::new($false))
        $repeatPlan = & $entryPath `
            -Mode Plan `
            -TargetPath $repeatTarget `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $repeatEvidenceRoot
        Assert-MetricsContract -Metrics $repeatPlan.metrics -Phase 'plan'
        $repeatPlanBytes = [long](Get-Item -LiteralPath $repeatPlan.planPath).Length
        Assert-True ($repeatPlan.metrics.bytesHashed -eq ($policyBytes + 32L + $repeatPlanBytes)) `
            '重复 fixture 的 Plan metrics 必须可由真实 artifact bytes 复算'
        $repeatMetrics.Add($repeatPlan.metrics)
    }
    Assert-True (
        ((@($repeatMetrics[0].PSObject.Properties.Name) -join '|') -ceq
            (@($repeatMetrics[1].PSObject.Properties.Name) -join '|')) -and
        $repeatMetrics[0].entriesScanned -eq $repeatMetrics[1].entriesScanned -and
        $repeatMetrics[0].logicalBytes -eq $repeatMetrics[1].logicalBytes -and
        ((@($repeatMetrics[0].retry.PSObject.Properties.Name) -join '|') -ceq
            (@($repeatMetrics[1].retry.PSObject.Properties.Name) -join '|'))) `
        '同形 fixture 重复运行除动态耗时外必须产生稳定 metrics 结构与可解释计数'

    $v5EvidenceRoot = Join-Path $fixtureRoot 'v5-evidence'
    $v5PolicyPath = Join-Path $fixtureRoot 'policy-v5.json'
    [void][IO.Directory]::CreateDirectory($v5EvidenceRoot)
    $v5Policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 5
        entries = @([pscustomobject][ordered]@{
            id = 'control-plane-v5-fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            minimumQuarantineAgeMinutes = 0
            producerFenceMode = 'manual-only'
            deniedExactPaths = @($evidenceRoot, $v5EvidenceRoot)
        })
    }
    [IO.File]::WriteAllText(
        $v5PolicyPath,
        ($v5Policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $v5Status = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $v5EvidenceRoot
    Assert-True ($v5Status.policySchemaVersion -eq 5) 'Status 必须暴露 policy v5 schema'
    Assert-True ($v5Status.migrationReadiness.ready -eq $true) '空 evidence 的 v5 migration preflight 必须 ready'
    Assert-True (@($v5Status.migrationReadiness.blockingRecords).Count -eq 0) `
        'ready migration preflight 不得报告阻断记录'

    $candidatePolicyPath = Join-Path $fixtureRoot 'policy-v5-candidate.json'
    $candidatePolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 5
        entries = @([pscustomobject][ordered]@{
            id = 'control-plane-fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            minimumQuarantineAgeMinutes = 10
            producerFenceMode = 'manual-only'
            deniedExactPaths = @($evidenceRoot)
        })
    }
    [IO.File]::WriteAllText(
        $candidatePolicyPath,
        ($candidatePolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $candidatePolicySha256 = (Get-FileHash -LiteralPath $candidatePolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $candidateStatus = & $entryPath `
        -Mode Status `
        -FixtureCandidatePolicyPath $candidatePolicyPath `
        -FixtureApprovedCandidatePolicySha256 $candidatePolicySha256 `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($candidateStatus.migrationReadiness.evaluated -eq $true) `
        'Status 必须显式标记 candidate policy activation preflight 已执行'
    Assert-True ($candidateStatus.migrationReadiness.ready -eq $false) `
        'candidate policy SHA 会冻结非终态 operation 时 activation preflight 必须拒绝'
    Assert-True (@($candidateStatus.migrationReadiness.blockingRecords).Count -ge 1) `
        'candidate policy preflight 必须列出受 policy SHA 漂移影响的 operation'

    $v5Policy.entries[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    [IO.File]::WriteAllText(
        $v5PolicyPath,
        ($v5Policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $unknownPropertyError = Assert-Throws `
        -Message 'policy v5 未知属性必须失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Status `
                -FixturePolicyPath $v5PolicyPath `
                -FixtureEvidenceRoot $v5EvidenceRoot
        }
    Assert-True ($unknownPropertyError -match '属性集合非法') 'policy v5 未知属性必须给出稳定拒绝原因'

    $restoreTarget = Join-Path $fixtureRoot 'restore-candidate'
    [void][IO.Directory]::CreateDirectory($restoreTarget)
    [IO.File]::WriteAllText(
        (Join-Path $restoreTarget 'restore.txt'),
        'restore-me-exactly',
        [Text.UTF8Encoding]::new($false))
    $restorePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $restoreTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $restoreApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$restorePlan.planPath) `
        -ApprovedPlanSha256 ([string]$restorePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $quarantineBeforeRefusal = @(Get-FixtureFileState -Root ([string]$restoreApply.quarantinePath))
    $unconfirmedRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$restoreApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$restoreApply.transactionSha256) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($unconfirmedRestore.refusalReason -ceq 'confirm-restore-required') `
        'Restore 缺少显式确认必须结构化拒绝'
    Assert-True (
        (($quarantineBeforeRefusal | ConvertTo-Json -Depth 8 -Compress) -ceq
            ((Get-FixtureFileState -Root ([string]$restoreApply.quarantinePath)) |
                ConvertTo-Json -Depth 8 -Compress))) `
        'Restore 确认拒绝必须保持 quarantine 字节不变'

    $restore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$restoreApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$restoreApply.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($restore.restored -eq $true) '完整 quarantine 必须可 Restore'
    Assert-True ($restore.logicalCompletion -eq $false) `
        'Restore 恢复 namespace 后不得声称 logical deletion 完成'
    Assert-True ($restore.metrics.logicalBytes -eq 18) `
        'Restore 重复 tree verification 不得重复累计 logical bytes'
    Assert-True ([IO.Directory]::Exists($restoreTarget)) 'Restore 后原 target 必须重新出现'
    Assert-True (-not [IO.Directory]::Exists([string]$restoreApply.quarantinePath)) `
        'Restore 后 quarantine namespace 必须消失'
    Assert-True ([IO.File]::ReadAllText((Join-Path $restoreTarget 'restore.txt')) -ceq 'restore-me-exactly') `
        'Restore 必须保持子文件内容'
    Assert-True ([IO.File]::Exists((Join-Path (Split-Path -Parent $restoreApply.transactionPath) 'restore-intent.json'))) `
        'Restore 必须发布 create-only intent journal'
    Assert-True ([IO.File]::Exists((Join-Path (Split-Path -Parent $restoreApply.transactionPath) 'restore-renamed.json'))) `
        'Restore 必须发布 create-only rename journal'
    Assert-True ([IO.File]::Exists((Join-Path (Split-Path -Parent $restoreApply.transactionPath) 'restore-verified.json'))) `
        'Restore 必须发布 create-only target verification journal'
    Assert-True ([IO.File]::Exists((Join-Path (Split-Path -Parent $restoreApply.transactionPath) 'restore-complete.json'))) `
        'Restore 必须发布 create-only terminal journal'
    $restoredTransaction = Get-Content -Raw -LiteralPath $restore.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ($restoredTransaction.status -ceq 'restored') 'Restore 必须发布 terminal transaction 状态'

    $restoreReplay = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$restore.transactionPath) `
        -ApprovedTransactionSha256 ([string]$restore.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($restoreReplay.restored -eq $true -and $restoreReplay.alreadyRestored -eq $true) `
        'Restore terminal replay 必须幂等'
    Assert-True ($restoreReplay.logicalCompletion -eq $false) `
        'Restore terminal replay 也不得声称 logical deletion 完成'
    $restoredStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $restoredOperationId = Split-Path -Leaf (Split-Path -Parent ([string]$restore.transactionPath))
    $restoredOperation = @($restoredStatus.operations | Where-Object operationId -ceq $restoredOperationId)
    Assert-True ($restoredOperation.Count -eq 1 -and $restoredOperation[0].lifecycle -ceq 'terminal') `
        'Status 必须验证 Restore terminal evidence'
    Assert-True ($restoredOperation[0].journalStatus -ceq 'complete') `
        'Status 必须验证完整 Restore intent/rename/verify/complete journals'
    Assert-True ($restoredOperation[0].logicalCompletion -eq $false) `
        'Status 不得把 restored terminal operation 冒充 logical deletion'

    $restoreCompletePath = Join-Path (Split-Path -Parent $restore.transactionPath) 'restore-complete.json'
    [IO.File]::Delete($restoreCompletePath)
    $journalDriftStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $journalDriftOperation = @($journalDriftStatus.operations | Where-Object operationId -ceq $restoredOperationId)
    Assert-True ($journalDriftStatus.complete -eq $false -and
        $journalDriftOperation[0].lifecycle -ceq 'manual-review') `
        'Restore terminal journal 缺失必须令 Status 失败闭锁'

    $conflictTarget = Join-Path $fixtureRoot 'target-file-conflict'
    [void][IO.Directory]::CreateDirectory($conflictTarget)
    [IO.File]::WriteAllText((Join-Path $conflictTarget 'payload.txt'), 'conflict', [Text.UTF8Encoding]::new($false))
    $conflictPlan = & $entryPath -Mode Plan -TargetPath $conflictTarget -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $conflictApply = & $entryPath -Mode Apply -PlanPath $conflictPlan.planPath `
        -ApprovedPlanSha256 $conflictPlan.planSha256 -ConfirmApply `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    [IO.File]::WriteAllText($conflictTarget, 'occupies-target-name', [Text.UTF8Encoding]::new($false))
    $conflictStatus = & $entryPath -Mode Status -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $conflictOperationId = Split-Path -Leaf (Split-Path -Parent ([string]$conflictApply.transactionPath))
    $conflictOperation = @($conflictStatus.operations | Where-Object operationId -ceq $conflictOperationId)
    Assert-True ($conflictOperation[0].lifecycle -ceq 'manual-review') `
        '普通文件占据 target 时 Status 必须进入 manual-review'
    Assert-True ($conflictOperation[0].namespaceAbsent -eq $false -and
        $conflictOperation[0].targetEntryType -ceq 'file') `
        '普通文件占据 target 时不得误报 namespace absent'
    $conflictPurgeError = Assert-Throws -Message '普通文件占据 target 时 Purge 必须拒绝' -Action {
        & $entryPath -Mode Purge -TransactionPath $conflictApply.transactionPath `
            -ApprovedTransactionSha256 $conflictApply.transactionSha256 -ConfirmPurge `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($conflictPurgeError -match '原目标已重新出现|namespace') `
        'target 文件冲突必须给出稳定拒绝原因'
    [IO.File]::Delete($conflictTarget)
    $conflictRestore = & $entryPath -Mode Restore -TransactionPath $conflictApply.transactionPath `
        -ApprovedTransactionSha256 $conflictApply.transactionSha256 -ConfirmRestore `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($conflictRestore.restored -eq $true) '清除冲突后 quarantine 必须仍可恢复'

    $missingQuarantineTarget = Join-Path $fixtureRoot 'missing-quarantine-status'
    [void][IO.Directory]::CreateDirectory($missingQuarantineTarget)
    [IO.File]::WriteAllText(
        (Join-Path $missingQuarantineTarget 'payload.txt'),
        'must-not-be-called-resumable',
        [Text.UTF8Encoding]::new($false))
    $missingQuarantinePlan = & $entryPath -Mode Plan -TargetPath $missingQuarantineTarget `
        -CapabilityRoot $fixtureRoot -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $missingQuarantineApply = & $entryPath -Mode Apply -PlanPath $missingQuarantinePlan.planPath `
        -ApprovedPlanSha256 $missingQuarantinePlan.planSha256 -ConfirmApply `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $missingQuarantineTransaction = Get-Content -Raw -LiteralPath $missingQuarantineApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $missingQuarantineTransaction.status = 'purging'
    [IO.File]::WriteAllText(
        $missingQuarantineApply.transactionPath,
        ($missingQuarantineTransaction | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    Remove-TestTree -Path $missingQuarantineApply.quarantinePath
    $missingQuarantineStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $missingQuarantineOperationId = Split-Path -Leaf (Split-Path -Parent ([string]$missingQuarantineApply.transactionPath))
    $missingQuarantineOperation = @($missingQuarantineStatus.operations |
        Where-Object operationId -ceq $missingQuarantineOperationId)
    Assert-True ($missingQuarantineOperation[0].lifecycle -cin @('inconsistent', 'manual-review')) `
        'purging transaction 缺少 quarantine 时不得分类为 purge-resumable'
    Assert-True ('purge' -cnotin @($missingQuarantineOperation[0].safeActions)) `
        '缺少 quarantine 时 Status 不得建议 Purge'

    $v5Policy.entries[0].PSObject.Properties.Remove('unexpected')
    $v5Policy.entries[0].minimumQuarantineAgeMinutes = 10
    [IO.File]::WriteAllText(
        $v5PolicyPath,
        ($v5Policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $graceTarget = Join-Path $fixtureRoot 'grace-candidate'
    [void][IO.Directory]::CreateDirectory($graceTarget)
    [IO.File]::WriteAllText(
        (Join-Path $graceTarget 'grace.txt'),
        'wait-for-grace',
        [Text.UTF8Encoding]::new($false))
    $gracePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $graceTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $v5EvidenceRoot
    $graceApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$gracePlan.planPath) `
        -ApprovedPlanSha256 ([string]$gracePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $v5EvidenceRoot
    $graceTransaction = Get-Content -Raw -LiteralPath $graceApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ($graceTransaction.schemaVersion -eq 3) 'policy v5 必须写 transaction v3'
    Assert-True ($null -ne $graceTransaction.quarantineTimeAnchor) `
        'transaction v3 必须绑定 immutable quarantine-time anchor'
    Assert-True ([IO.File]::Exists([string]$graceTransaction.quarantineTimeAnchor.path)) `
        'quarantine-time anchor 必须引用 create-only journal'
    $graceAnchorDocument = Get-Content -Raw -LiteralPath $graceTransaction.quarantineTimeAnchor.path |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-True ($graceAnchorDocument.schemaVersion -eq 2 -and
        $graceAnchorDocument.elapsedTimeSource -ceq 'system-uptime-milliseconds' -and
        $graceAnchorDocument.elapsedTimeStartMilliseconds -is [long]) `
        'quarantine-time anchor 必须绑定可在生产环境检测重启的 monotonic elapsed source'
    Assert-True ($graceApply.metrics.phase -ceq 'apply') 'Apply 必须输出统一 metrics'
    Assert-True ($graceApply.metrics.bytesHashed -ge 42) `
        'Apply metrics 必须累计三次内容认证读取'

    $tooEarlyPurgeError = Assert-Throws `
        -Message '未到 grace 的 Purge 必须拒绝' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$graceApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$graceApply.transactionSha256) `
                -ConfirmPurge `
                -FixturePolicyPath $v5PolicyPath `
                -FixtureEvidenceRoot $v5EvidenceRoot
        }
    Assert-True ($tooEarlyPurgeError -match 'grace') '未到 grace 必须返回稳定拒绝原因'
    Assert-True ([IO.Directory]::Exists([string]$graceApply.quarantinePath)) `
        'grace 拒绝必须保留完整 quarantine'

    $anchorDocument = Get-Content -Raw -LiteralPath $graceTransaction.quarantineTimeAnchor.path |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $exactBoundary = [datetimeoffset]::ParseExact(
        [string]$anchorDocument.createdAtUtc,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind).AddMinutes(10)
    $gracePurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$graceApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$graceApply.transactionSha256) `
        -ConfirmPurge `
        -FixtureTrustedNowUtc $exactBoundary `
        -FixtureTrustedElapsedNowMilliseconds `
            ([long]$graceAnchorDocument.elapsedTimeStartMilliseconds + 600000L) `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $v5EvidenceRoot
    Assert-True ($gracePurge.purged -eq $true) 'grace 精确边界必须允许 Purge'
    Assert-True ($gracePurge.metrics.phase -ceq 'purge') 'Purge 必须输出统一 metrics'
    Assert-True ($gracePurge.namespaceAbsent -eq $true) 'Purge 必须区分 namespace absence'
    Assert-True ($gracePurge.physicalReclaimStatus -ceq 'unknown') `
        '缺少独立分配证据时 physical reclaim 必须为 unknown'

    $clockTarget = Join-Path $fixtureRoot 'clock-anomaly-candidate'
    [void][IO.Directory]::CreateDirectory($clockTarget)
    [IO.File]::WriteAllText(
        (Join-Path $clockTarget 'clock.txt'),
        'trusted-time-only',
        [Text.UTF8Encoding]::new($false))
    $clockPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $clockTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $v5EvidenceRoot
    $clockApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$clockPlan.planPath) `
        -ApprovedPlanSha256 ([string]$clockPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $v5EvidenceRoot
    $clockTransaction = Get-Content -Raw -LiteralPath $clockApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $clockAnchorDocument = Get-Content -Raw -LiteralPath $clockTransaction.quarantineTimeAnchor.path |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $clockAnchorTime = [datetimeoffset]::ParseExact(
        [string]$clockAnchorDocument.createdAtUtc,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
    $futureAnchorError = Assert-Throws `
        -Message 'future anchor 必须阻止 Purge' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$clockApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$clockApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureTrustedNowUtc ($clockAnchorTime.AddSeconds(-1)) `
                -FixturePolicyPath $v5PolicyPath `
                -FixtureEvidenceRoot $v5EvidenceRoot
        }
    Assert-True ($futureAnchorError -match 'anchor 之前') 'future anchor 必须给出稳定拒绝原因'
    $restartAmbiguityError = Assert-Throws `
        -Message 'restart ambiguity 必须阻止 Purge' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$clockApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$clockApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureTrustedTimeRestartAmbiguous `
                -FixturePolicyPath $v5PolicyPath `
                -FixtureEvidenceRoot $v5EvidenceRoot
        }
    Assert-True ($restartAmbiguityError -match 'restart ambiguity') `
        'restart ambiguity 必须给出稳定拒绝原因'
    $clockRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$clockApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$clockApply.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $v5EvidenceRoot
    Assert-True ($clockRestore.restored -eq $true) 'clock anomaly 拒绝必须保持 Restore 可用'

    $manualBatchTarget = Join-Path $fixtureRoot 'manual-batch-candidate'
    [void][IO.Directory]::CreateDirectory($manualBatchTarget)
    [IO.File]::WriteAllText(
        (Join-Path $manualBatchTarget 'manual.txt'),
        'manual-only',
        [Text.UTF8Encoding]::new($false))
    $manualBatchError = Assert-Throws `
        -Message 'manual-only v5 capability 的 BatchPurge 必须拒绝' `
        -Action {
            & $entryPath `
                -Mode BatchPurge `
                -TargetPaths @($manualBatchTarget) `
                -CapabilityRoot $fixtureRoot `
                -ConfirmApply `
                -ConfirmPurge `
                -FixturePolicyPath $v5PolicyPath `
                -FixtureEvidenceRoot $v5EvidenceRoot
        }
    Assert-True ($manualBatchError -match 'producer fence') 'manual-only BatchPurge 必须给出稳定拒绝原因'
    Assert-True ([IO.Directory]::Exists($manualBatchTarget)) 'manual-only BatchPurge 拒绝必须零写入'

    $fencedPolicyPath = Join-Path $fixtureRoot 'policy-fenced-v5.json'
    $fencedEvidenceRoot = Join-Path $fixtureRoot 'fenced-evidence'
    [void][IO.Directory]::CreateDirectory($fencedEvidenceRoot)
    $v5Policy.entries[0].minimumQuarantineAgeMinutes = 0
    $v5Policy.entries[0].producerFenceMode = 'os-handle-required'
    $v5Policy.entries[0].deniedExactPaths = @($evidenceRoot, $v5EvidenceRoot, $fencedEvidenceRoot)
    [IO.File]::WriteAllText(
        $fencedPolicyPath,
        ($v5Policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $fencedTarget = Join-Path $fixtureRoot 'fenced-candidate'
    [void][IO.Directory]::CreateDirectory($fencedTarget)
    [IO.File]::WriteAllText(
        (Join-Path $fencedTarget 'producer.txt'),
        'producer-is-active',
        [Text.UTF8Encoding]::new($false))
    $fencedPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $fencedTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $producerReadyPath = Join-Path $fixtureRoot 'producer.ready'
    $producerReleasePath = Join-Path $fixtureRoot 'producer.release'
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $producerLeaseFixturePath,
            '-TargetPath', $fencedTarget, '-CapabilityRoot', $fixtureRoot,
            '-FixturePolicyPath', $fencedPolicyPath,
            '-ReadyPath', $producerReadyPath, '-ReleasePath', $producerReleasePath)) {
        [void]$processInfo.ArgumentList.Add($argument)
    }
    $producerProcess = [Diagnostics.Process]::Start($processInfo)
    $readyDeadline = [datetimeoffset]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($producerReadyPath)) {
        if ($producerProcess.HasExited) {
            throw "producer lease fixture 提前退出：$($producerProcess.ExitCode)"
        }
        if ([datetimeoffset]::UtcNow -ge $readyDeadline) { throw 'producer lease fixture readiness timeout。' }
        Start-Sleep -Milliseconds 25
    }
    $activeProducerError = Assert-Throws `
        -Message 'active producer 必须阻止 Apply rename' `
        -Action {
            & $entryPath `
                -Mode Apply `
                -PlanPath ([string]$fencedPlan.planPath) `
                -ApprovedPlanSha256 ([string]$fencedPlan.planSha256) `
                -ConfirmApply `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($activeProducerError -match 'sharing|used by another process|open a verified directory') `
        'producer fence 拒绝必须来自 OS handle sharing 语义'
    Assert-True ([IO.Directory]::Exists($fencedTarget)) 'producer fence 拒绝必须保持 target namespace'
    $suspendedThreadIds = [CodexSafeDeleteTests.ProcessSuspension]::Suspend($producerProcess.Id)
    try {
        $suspendedProducerError = Assert-Throws `
            -Message 'suspended producer 必须继续阻止 Apply rename' `
            -Action {
                & $entryPath `
                    -Mode Apply `
                    -PlanPath ([string]$fencedPlan.planPath) `
                    -ApprovedPlanSha256 ([string]$fencedPlan.planSha256) `
                    -ConfirmApply `
                    -FixturePolicyPath $fencedPolicyPath `
                    -FixtureEvidenceRoot $fencedEvidenceRoot
            }
        Assert-True ($suspendedProducerError -match 'sharing|used by another process|open a verified directory') `
            'suspended producer 拒绝必须继续来自 OS handle sharing 语义'
        Assert-True ([IO.Directory]::Exists($fencedTarget)) 'suspended producer 拒绝必须保持 target namespace'
    } finally {
        [CodexSafeDeleteTests.ProcessSuspension]::Resume($suspendedThreadIds)
    }
    [IO.File]::WriteAllText($producerReleasePath, 'release', [Text.UTF8Encoding]::new($false))
    Assert-True ($producerProcess.WaitForExit(10000)) 'producer lease fixture 必须正常释放'
    Assert-True ($producerProcess.ExitCode -eq 0) 'producer lease fixture 释放必须 exit 0'
    $producerProcess.Dispose()
    $producerProcess = $null

    $fencedApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$fencedPlan.planPath) `
        -ApprovedPlanSha256 ([string]$fencedPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($fencedApply.quarantined -eq $true) 'producer lease 释放后 Apply 必须可继续'
    $fencedRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$fencedApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$fencedApply.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($fencedRestore.restored -eq $true) 'producer fence fixture 必须可受管恢复'

    $crashTarget = Join-Path $fixtureRoot 'producer-crash-candidate'
    [void][IO.Directory]::CreateDirectory($crashTarget)
    [IO.File]::WriteAllText(
        (Join-Path $crashTarget 'producer.txt'),
        'producer-will-crash',
        [Text.UTF8Encoding]::new($false))
    $crashReadyPath = Join-Path $fixtureRoot 'producer-crash.ready'
    $crashReleasePath = Join-Path $fixtureRoot 'producer-crash.release'
    $crashProcessInfo = [Diagnostics.ProcessStartInfo]::new()
    $crashProcessInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $crashProcessInfo.UseShellExecute = $false
    $crashProcessInfo.CreateNoWindow = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $producerLeaseFixturePath,
            '-TargetPath', $crashTarget, '-CapabilityRoot', $fixtureRoot,
            '-FixturePolicyPath', $fencedPolicyPath,
            '-ReadyPath', $crashReadyPath, '-ReleasePath', $crashReleasePath)) {
        [void]$crashProcessInfo.ArgumentList.Add($argument)
    }
    $crashedProducerProcess = [Diagnostics.Process]::Start($crashProcessInfo)
    $crashReadyDeadline = [datetimeoffset]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($crashReadyPath)) {
        if ($crashedProducerProcess.HasExited) {
            throw "crashed producer lease fixture 提前退出：$($crashedProducerProcess.ExitCode)"
        }
        if ([datetimeoffset]::UtcNow -ge $crashReadyDeadline) { throw 'crashed producer readiness timeout。' }
        Start-Sleep -Milliseconds 25
    }
    $crashedProducerProcess.Kill($true)
    Assert-True ($crashedProducerProcess.WaitForExit(10000)) 'producer crash 必须在超时内释放 OS handle'
    $crashedProducerProcess.Dispose()
    $crashedProducerProcess = $null
    $postCrashPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $crashTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $postCrashApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$postCrashPlan.planPath) `
        -ApprovedPlanSha256 ([string]$postCrashPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($postCrashApply.quarantined -eq $true) 'producer crash 后的新 Plan/Apply 必须可继续'
    $postCrashRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$postCrashApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$postCrashApply.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($postCrashRestore.restored -eq $true) 'producer crash fixture 必须可受管恢复'

    $lateTarget = Join-Path $fixtureRoot 'producer-late-acquire-candidate'
    [void][IO.Directory]::CreateDirectory($lateTarget)
    [IO.File]::WriteAllText((Join-Path $lateTarget 'payload.txt'), 'rename-wins', [Text.UTF8Encoding]::new($false))
    $latePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $lateTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $lateApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$latePlan.planPath) `
        -ApprovedPlanSha256 ([string]$latePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True (-not [IO.Directory]::Exists($lateTarget)) 'rename 先完成时原 target 必须消失'
    $lateReadyPath = Join-Path $fixtureRoot 'producer-late.ready'
    $lateReleasePath = Join-Path $fixtureRoot 'producer-late.release'
    $lateProcessInfo = [Diagnostics.ProcessStartInfo]::new()
    $lateProcessInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $lateProcessInfo.UseShellExecute = $false
    $lateProcessInfo.CreateNoWindow = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $producerLeaseFixturePath,
            '-TargetPath', $lateTarget, '-CapabilityRoot', $fixtureRoot,
            '-FixturePolicyPath', $fencedPolicyPath,
            '-ReadyPath', $lateReadyPath, '-ReleasePath', $lateReleasePath)) {
        [void]$lateProcessInfo.ArgumentList.Add($argument)
    }
    $lateProducerProcess = [Diagnostics.Process]::Start($lateProcessInfo)
    Assert-True ($lateProducerProcess.WaitForExit(10000)) 'rename 获胜后的 late producer 必须快速失败'
    Assert-True ($lateProducerProcess.ExitCode -ne 0) 'rename 获胜后的 late producer 不得取得旧 target lease'
    Assert-True (-not [IO.File]::Exists($lateReadyPath)) 'late producer 失败不得发布 readiness'
    $lateProducerProcess.Dispose()
    $lateProducerProcess = $null
    $lateRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$lateApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$lateApply.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($lateRestore.restored -eq $true) 'late-acquire fixture 必须可受管恢复'

    $replacementTarget = Join-Path $fixtureRoot 'producer-replacement-candidate'
    [void][IO.Directory]::CreateDirectory($replacementTarget)
    [IO.File]::WriteAllText((Join-Path $replacementTarget 'payload.txt'), 'original', [Text.UTF8Encoding]::new($false))
    $replacementPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $replacementTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $displacedTarget = "$replacementTarget-displaced"
    [IO.Directory]::Move($replacementTarget, $displacedTarget)
    [void][IO.Directory]::CreateDirectory($replacementTarget)
    [IO.File]::WriteAllText((Join-Path $replacementTarget 'payload.txt'), 'replacement', [Text.UTF8Encoding]::new($false))
    $replacementError = Assert-Throws `
        -Message '同名 replacement 必须使已批准 Plan 失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Apply `
                -PlanPath ([string]$replacementPlan.planPath) `
                -ApprovedPlanSha256 ([string]$replacementPlan.planSha256) `
                -ConfirmApply `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($replacementError -match 'identity|manifest|drift|变化|不一致') `
        '同名 replacement 拒绝必须来自 identity 或 manifest 复验'
    Assert-True ([IO.Directory]::Exists($replacementTarget)) 'replacement 拒绝必须保留新 target'
    Assert-True ([IO.Directory]::Exists($displacedTarget)) 'replacement 拒绝必须保留原对象以供人工处理'

    if ($Slice -ceq 'ProducerFencing') {
        [pscustomobject][ordered]@{
            ok = $true
            suite = 'CodexSafeTreeDeleteProducerFencing'
            scenarios = 4
            checks = 22
        }
        return
    }

    foreach ($restoreCrashScenario in @(
            'after-intent',
            'after-rename',
            'after-target-verification',
            'after-complete-journal')) {
        Invoke-RestoreCrashCase `
            -Scenario $restoreCrashScenario `
            -CapabilityRoot $fixtureRoot `
            -PolicyPath $fencedPolicyPath `
            -EvidenceRoot $fencedEvidenceRoot
    }

    $retryTarget = Join-Path $fixtureRoot 'retry-candidate'
    [void][IO.Directory]::CreateDirectory($retryTarget)
    [IO.File]::WriteAllText(
        (Join-Path $retryTarget 'retry.txt'),
        'retry-one-leaf',
        [Text.UTF8Encoding]::new($false))
    $retryPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $retryTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $retryApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$retryPlan.planPath) `
        -ApprovedPlanSha256 ([string]$retryPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $transientFault = {
        param([string]$Path, [int]$Attempt)
        if ($Path -like '*retry.txt' -and $Attempt -in @(1, 2)) {
            return 32
        }
    }.GetNewClosure()
    $retryPurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$retryApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$retryApply.transactionSha256) `
        -ConfirmPurge `
        -FixtureLeafDeleteFault $transientFault `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($retryPurge.purged -eq $true) 'allowlisted sharing violation 必须逐叶 retry 后成功'
    Assert-True ($retryPurge.metrics.retry.attempts -eq 2) 'retry metrics 必须记录每一次实际 retry'
    Assert-True ($retryPurge.metrics.retry.result -ceq 'succeeded-after-retry') `
        'retry metrics 必须记录最终结论'
    Assert-True ($retryPurge.metrics.retry.events[0].errorCategory -ceq 'sharing-violation') `
        'retry metrics 必须记录非敏感错误类别'
    Assert-True (
        (@($retryPurge.metrics.retry.contract.PSObject.Properties.Name) -join '|') -ceq
            'schemaVersion|maxAttempts|wallTimeBudgetMs|delayMilliseconds|allowedErrorCategories') `
        'retry metrics 必须发布稳定的版本化合同'
    Assert-True (
        $retryPurge.metrics.retry.contract.schemaVersion -eq 1 -and
        $retryPurge.metrics.retry.contract.maxAttempts -eq 3 -and
        $retryPurge.metrics.retry.contract.wallTimeBudgetMs -eq 1000 -and
        ((@($retryPurge.metrics.retry.contract.delayMilliseconds) -join ',') -ceq '10,25') -and
        ((@($retryPurge.metrics.retry.contract.allowedErrorCategories) -join ',') -ceq
            'sharing-violation,lock-violation,busy')) `
        'retry metrics 必须精确反映生产 allowlist、attempts、总预算和退避序列'
    Assert-True (
        (@($retryPurge.metrics.retry.events[0].PSObject.Properties.Name) -join '|') -ceq
            'attempt|errorCategory|delayMs|elapsedMs|budgetRemainingMs|revalidation|result') `
        'retry event 必须稳定记录类别、延迟、预算、复验和结论'
    Assert-True (
        $retryPurge.metrics.retry.events.Count -eq 2 -and
        ((@($retryPurge.metrics.retry.events.delayMs) -join ',') -ceq '10,25') -and
        ((@($retryPurge.metrics.retry.events.revalidation) -join ',') -ceq 'failed,passed') -and
        ((@($retryPurge.metrics.retry.events.result) -join ',') -ceq 'failed,succeeded')) `
        '每个 retry event 都必须记录实际退避、复验结果和终态结论'
    Assert-True ($retryPurge.metrics.bytesHashed -ge 42) `
        "Purge metrics 必须至少累计 preflight 与两次临删 handle hash 读取；actual=$($retryPurge.metrics.bytesHashed)"

    $rejectedRetryTarget = Join-Path $fixtureRoot 'rejected-retry-candidate'
    [void][IO.Directory]::CreateDirectory($rejectedRetryTarget)
    [IO.File]::WriteAllText(
        (Join-Path $rejectedRetryTarget 'reject.txt'),
        'do-not-retry-access-denied',
        [Text.UTF8Encoding]::new($false))
    $rejectedRetryPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $rejectedRetryTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $rejectedRetryApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$rejectedRetryPlan.planPath) `
        -ApprovedPlanSha256 ([string]$rejectedRetryPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $rejectedFaultState = [pscustomobject][ordered]@{ calls = 0 }
    $rejectedFault = {
        param([string]$Path, [int]$Attempt)
        $rejectedFaultState.calls = [int]$rejectedFaultState.calls + 1
        return 5
    }.GetNewClosure()
    $rejectedRetryError = Assert-Throws `
        -Message 'ACCESS_DENIED 不得进入 retry' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$rejectedRetryApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$rejectedRetryApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureLeafDeleteFault $rejectedFault `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($rejectedRetryError -match 'Injected safe-delete leaf failure') `
        '拒绝错误必须保持原始失败语义'
    Assert-True ($rejectedFaultState.calls -eq 1) '非 allowlist 错误必须只尝试一次'
    $rejectedTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$rejectedRetryApply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $rejectedRetryApply.transactionPath) `
        -AllowedExactPaths @([string]$rejectedRetryApply.transactionPath) `
        -Name 'rejected retry transaction'
    $rejectedTransaction = [Text.UTF8Encoding]::new($false).GetString($rejectedTransactionSnapshot.bytes) |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ($rejectedTransaction.status -ceq 'quarantined') `
        '零 delete commit 的 retry 失败必须保持 recoverable quarantine'
    $rejectedRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$rejectedRetryApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$rejectedTransactionSnapshot.sha256) `
        -ConfirmRestore `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($rejectedRestore.restored -eq $true) '零 commit retry 失败必须仍可 Restore'

    $budgetTarget = Join-Path $fixtureRoot 'retry-budget-candidate'
    [void][IO.Directory]::CreateDirectory($budgetTarget)
    [IO.File]::WriteAllText(
        (Join-Path $budgetTarget 'budget.txt'),
        'retry-budget-boundary',
        [Text.UTF8Encoding]::new($false))
    $budgetPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $budgetTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $budgetApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$budgetPlan.planPath) `
        -ApprovedPlanSha256 ([string]$budgetPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $budgetState = [pscustomobject][ordered]@{
        calls = 0
        elapsedMs = 0L
        delays = [Collections.Generic.List[long]]::new()
    }
    $budgetFault = {
        param([string]$Path, [int]$Attempt)
        $budgetState.calls = [int]$budgetState.calls + 1
        return 32
    }.GetNewClosure()
    $budgetElapsed = { return [long]$budgetState.elapsedMs }.GetNewClosure()
    $budgetDelay = {
        param([long]$DelayMs)
        $budgetState.delays.Add($DelayMs)
        $budgetState.elapsedMs = [long]$budgetState.elapsedMs + $DelayMs
    }.GetNewClosure()
    $budgetPolicy = [pscustomobject][ordered]@{
        schemaVersion = 1
        maxAttempts = 4
        wallTimeBudgetMs = 25
        delayMilliseconds = @(10, 15, 20)
        allowedWindowsErrors = @(32, 33, 170)
    }
    $budgetFailure = (& $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$budgetApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$budgetApply.transactionSha256) `
            -ConfirmPurge `
            -FixtureLeafDeleteFault $budgetFault `
            -FixtureLeafRetryPolicy $budgetPolicy `
            -FixtureLeafRetryElapsedMilliseconds $budgetElapsed `
            -FixtureLeafRetryDelay $budgetDelay `
            -FixturePolicyPath $fencedPolicyPath `
            -FixtureEvidenceRoot $fencedEvidenceRoot `
            -Json) | ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True (
        $budgetFailure.purged -eq $false -and
        [string]$budgetFailure.refusalReason -ceq 'leaf-delete-failed' -and
        $budgetFailure.recoverable -eq $true) `
        '预算耗尽 JSON 必须给出不泄露内容的失败结论与 recoverable 状态'
    Assert-True (
        $budgetFailure.metrics.retry.result -ceq 'failed-after-retry' -and
        $budgetFailure.metrics.retry.attempts -eq 2 -and
        ((@($budgetFailure.metrics.retry.events.errorCategory) -join ',') -ceq
            'sharing-violation,sharing-violation') -and
        ((@($budgetFailure.metrics.retry.events.revalidation) -join ',') -ceq 'failed,failed') -and
        ((@($budgetFailure.metrics.retry.events.result) -join ',') -ceq 'failed,failed')) `
        '失败 JSON metrics 必须记录每次 retry 的类别、复验终态和最终结论'
    Assert-True ($budgetState.calls -eq 3) `
        '10+15ms 精确等于 25ms 预算时必须允许第三次尝试，下一次 20ms 退避必须拒绝'
    Assert-True ((@($budgetState.delays) -join ',') -ceq '10,15') `
        '总预算必须只执行预算内的两次退避'
    $budgetTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$budgetApply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $budgetApply.transactionPath) `
        -AllowedExactPaths @([string]$budgetApply.transactionPath) `
        -Name 'retry budget transaction'
    $budgetTransaction = [Text.UTF8Encoding]::new($false).GetString(
        $budgetTransactionSnapshot.bytes) |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ($budgetTransaction.status -ceq 'quarantined') `
        '预算耗尽且零 commit 时必须保持完整 recoverable quarantine'
    $budgetRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$budgetApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$budgetTransactionSnapshot.sha256) `
        -ConfirmRestore `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($budgetRestore.restored -eq $true) `
        '预算耗尽且零 commit 时完整 quarantine 必须可 Restore'

    foreach ($allowlistedCase in @(
            [pscustomobject]@{ code = 33; category = 'lock-violation' },
            [pscustomobject]@{ code = 170; category = 'busy' })) {
        $allowlistedTarget = Join-Path $fixtureRoot ("retry-allowlisted-{0}" -f $allowlistedCase.code)
        [void][IO.Directory]::CreateDirectory($allowlistedTarget)
        [IO.File]::WriteAllText(
            (Join-Path $allowlistedTarget 'allowlisted.txt'),
            "retry-$($allowlistedCase.category)",
            [Text.UTF8Encoding]::new($false))
        $allowlistedPlan = & $entryPath `
            -Mode Plan `
            -TargetPath $allowlistedTarget `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $fencedPolicyPath `
            -FixtureEvidenceRoot $fencedEvidenceRoot
        $allowlistedApply = & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$allowlistedPlan.planPath) `
            -ApprovedPlanSha256 ([string]$allowlistedPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $fencedPolicyPath `
            -FixtureEvidenceRoot $fencedEvidenceRoot
        $allowlistedState = [pscustomobject][ordered]@{ calls = 0 }
        $allowlistedFault = {
            param([string]$Path, [int]$Attempt)
            $allowlistedState.calls = [int]$allowlistedState.calls + 1
            if ($Attempt -eq 1) { return [int]$allowlistedCase.code }
        }.GetNewClosure()
        $allowlistedPurge = & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$allowlistedApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$allowlistedApply.transactionSha256) `
            -ConfirmPurge `
            -FixtureLeafDeleteFault $allowlistedFault `
            -FixturePolicyPath $fencedPolicyPath `
            -FixtureEvidenceRoot $fencedEvidenceRoot
        Assert-True ($allowlistedPurge.purged -eq $true -and $allowlistedState.calls -eq 2) `
            "allowlisted error $($allowlistedCase.code) 必须只 retry 一次后成功"
        Assert-True (
            $allowlistedPurge.metrics.retry.events.Count -eq 1 -and
            $allowlistedPurge.metrics.retry.events[0].errorCategory -ceq $allowlistedCase.category -and
            $allowlistedPurge.metrics.retry.events[0].revalidation -ceq 'passed') `
            "allowlisted error $($allowlistedCase.code) 必须记录固定类别和复验结论"
    }

    $unknownTarget = Join-Path $fixtureRoot 'retry-unknown-error'
    [void][IO.Directory]::CreateDirectory($unknownTarget)
    [IO.File]::WriteAllText(
        (Join-Path $unknownTarget 'unknown.txt'),
        'unknown-errors-fail-closed',
        [Text.UTF8Encoding]::new($false))
    $unknownPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $unknownTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $unknownApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$unknownPlan.planPath) `
        -ApprovedPlanSha256 ([string]$unknownPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $unknownState = [pscustomobject][ordered]@{ calls = 0 }
    $unknownFault = {
        param([string]$Path, [int]$Attempt)
        $unknownState.calls = [int]$unknownState.calls + 1
        return 9999
    }.GetNewClosure()
    $unknownError = Assert-Throws `
        -Message '未知 Win32 错误不得进入 retry' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$unknownApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$unknownApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureLeafDeleteFault $unknownFault `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($unknownError -match 'Injected safe-delete leaf failure' -and $unknownState.calls -eq 1) `
        '未知 Win32 错误必须保留原始失败且只尝试一次'
    $unknownTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$unknownApply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $unknownApply.transactionPath) `
        -AllowedExactPaths @([string]$unknownApply.transactionPath) `
        -Name 'unknown retry transaction'
    $unknownRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$unknownApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$unknownTransactionSnapshot.sha256) `
        -ConfirmRestore `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($unknownRestore.restored -eq $true) `
        '未知错误零 commit 后必须保持完整 quarantine 可 Restore'

    $policyDenyTarget = Join-Path $fixtureRoot 'retry-policy-deny'
    [void][IO.Directory]::CreateDirectory($policyDenyTarget)
    [IO.File]::WriteAllText(
        (Join-Path $policyDenyTarget 'policy.txt'),
        'retry-policy-cannot-expand',
        [Text.UTF8Encoding]::new($false))
    $policyDenyPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $policyDenyTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $policyDenyApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$policyDenyPlan.planPath) `
        -ApprovedPlanSha256 ([string]$policyDenyPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $expandedPolicy = [pscustomobject][ordered]@{
        schemaVersion = 1
        maxAttempts = 2
        wallTimeBudgetMs = 10
        delayMilliseconds = @(1)
        allowedWindowsErrors = @(5, 32, 33, 170)
    }
    $policyDenyCalls = [pscustomobject][ordered]@{ calls = 0 }
    $policyDenyFault = {
        param([string]$Path, [int]$Attempt)
        $policyDenyCalls.calls = [int]$policyDenyCalls.calls + 1
        return 5
    }.GetNewClosure()
    $policyDenyError = Assert-Throws `
        -Message 'fixture retry policy 不得扩大生产 allowlist' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$policyDenyApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$policyDenyApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureLeafDeleteFault $policyDenyFault `
                -FixtureLeafRetryPolicy $expandedPolicy `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($policyDenyError -match 'allowlist' -and $policyDenyCalls.calls -eq 0) `
        '非法 retry policy 必须在任何 leaf attempt 前失败闭锁'
    $policyDenyTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$policyDenyApply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $policyDenyApply.transactionPath) `
        -AllowedExactPaths @([string]$policyDenyApply.transactionPath) `
        -Name 'retry policy deny transaction'
    $policyDenyRestore = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$policyDenyApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$policyDenyTransactionSnapshot.sha256) `
        -ConfirmRestore `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($policyDenyRestore.restored -eq $true) `
        '非法 retry policy 零 commit 后必须保持完整 quarantine 可 Restore'

    $retryReplacementTarget = Join-Path $fixtureRoot 'retry-replacement-candidate'
    [void][IO.Directory]::CreateDirectory($retryReplacementTarget)
    [IO.File]::WriteAllText(
        (Join-Path $retryReplacementTarget 'replacement.txt'),
        'planned-file',
        [Text.UTF8Encoding]::new($false))
    $retryReplacementPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $retryReplacementTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $retryReplacementApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$retryReplacementPlan.planPath) `
        -ApprovedPlanSha256 ([string]$retryReplacementPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $retryReplacementOriginal = Join-Path $fixtureRoot 'retry-replacement-original.txt'
    $retryReplacementDelays = [Collections.Generic.List[long]]::new()
    $retryReplacementError = Assert-Throws `
        -Message 'Purge preflight 后的同名 replacement 必须失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$retryReplacementApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$retryReplacementApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureBeforeDirectoryTreeDelete {
                    param([string]$QuarantinePath)
                    $leafPath = Join-Path $QuarantinePath 'replacement.txt'
                    [IO.File]::Move($leafPath, $retryReplacementOriginal)
                    [IO.File]::WriteAllText(
                        $leafPath,
                        'same-name-replacement',
                        [Text.UTF8Encoding]::new($false))
                } `
                -FixtureLeafRetryDelay {
                    param([long]$DelayMs)
                    $retryReplacementDelays.Add($DelayMs)
                } `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($retryReplacementError -match 'identity|内容漂移' -and $retryReplacementDelays.Count -eq 0) `
        'replacement/file ID/hash 漂移必须拒绝且不得 backoff retry'
    Assert-True ([IO.Directory]::Exists([string]$retryReplacementApply.quarantinePath)) `
        'replacement 拒绝必须保留 quarantine 供人工处理'

    $partialTarget = Join-Path $fixtureRoot 'retry-partial-candidate'
    [void][IO.Directory]::CreateDirectory($partialTarget)
    [IO.File]::WriteAllText(
        (Join-Path $partialTarget 'a-committed.txt'),
        'first-leaf-commits',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $partialTarget 'b-retry-exhausted.txt'),
        'second-leaf-retry-exhausted',
        [Text.UTF8Encoding]::new($false))
    $partialPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $partialTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $partialApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$partialPlan.planPath) `
        -ApprovedPlanSha256 ([string]$partialPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $partialState = [pscustomobject][ordered]@{ calls = 0 }
    $partialFault = {
        param([string]$Path, [int]$Attempt)
        $partialState.calls = [int]$partialState.calls + 1
        if ([IO.Path]::GetFileName($Path) -ceq 'b-retry-exhausted.txt') { return 32 }
    }.GetNewClosure()
    $partialError = Assert-Throws `
        -Message '首叶 commit 后第二叶 retry 耗尽必须抛出' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$partialApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$partialApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureLeafDeleteFault $partialFault `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($partialError -match 'Injected safe-delete leaf failure' -and $partialState.calls -eq 4) `
        'partial failure 必须先 commit 第一叶，再对第二叶执行精确三次 attempts'
    Assert-True (
        -not [IO.File]::Exists((Join-Path $partialApply.quarantinePath 'a-committed.txt')) -and
        [IO.File]::Exists((Join-Path $partialApply.quarantinePath 'b-retry-exhausted.txt'))) `
        'partial failure 必须保留已 commit/未 commit 的可观察边界'
    $partialTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$partialApply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $partialApply.transactionPath) `
        -AllowedExactPaths @([string]$partialApply.transactionPath) `
        -Name 'partial retry transaction'
    $partialTransaction = [Text.UTF8Encoding]::new($false).GetString(
        $partialTransactionSnapshot.bytes) |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ($partialTransaction.status -ceq 'purging') `
        '任一 leaf commit 后的失败只能保持 purging'
    $partialStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $partialOperation = @($partialStatus.operations | Where-Object {
        [string]$_.targetPath -ceq $partialTarget
    })
    Assert-True (
        $partialOperation.Count -eq 1 -and
        $partialOperation[0].lifecycle -ceq 'purge-resumable' -and
        ((@($partialOperation[0].safeActions) -join ',') -ceq 'purge')) `
        'partial commit 后 Status 只能暴露 purge-resumable/purge'
    $partialRestoreError = Assert-Throws `
        -Message 'partial commit 后不得 Restore' `
        -Action {
            & $entryPath `
                -Mode Restore `
                -TransactionPath ([string]$partialApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$partialTransactionSnapshot.sha256) `
                -ConfirmRestore `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($partialRestoreError -match '拒绝 purging') `
        'partial commit transaction 必须明确拒绝 Restore'
    $partialResume = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$partialApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$partialTransactionSnapshot.sha256) `
        -ConfirmPurge `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($partialResume.purged -eq $true) `
        '重入 Purge 必须按计划的 partial manifest 完成剩余叶和目录'

    $sharedBudgetTarget = Join-Path $fixtureRoot 'retry-shared-budget-candidate'
    [void][IO.Directory]::CreateDirectory($sharedBudgetTarget)
    [IO.File]::WriteAllText(
        (Join-Path $sharedBudgetTarget 'a-consumes-budget.txt'),
        'first-leaf-consumes-budget',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $sharedBudgetTarget 'b-no-budget-left.txt'),
        'second-leaf-has-no-budget',
        [Text.UTF8Encoding]::new($false))
    $sharedBudgetPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $sharedBudgetTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $sharedBudgetApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$sharedBudgetPlan.planPath) `
        -ApprovedPlanSha256 ([string]$sharedBudgetPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $sharedBudgetState = [pscustomobject][ordered]@{
        calls = 0
        elapsedMs = 0L
        delays = [Collections.Generic.List[long]]::new()
    }
    $sharedBudgetFault = {
        param([string]$Path, [int]$Attempt)
        $sharedBudgetState.calls = [int]$sharedBudgetState.calls + 1
        if ($Attempt -eq 1) { return 32 }
    }.GetNewClosure()
    $sharedBudgetElapsed = { return [long]$sharedBudgetState.elapsedMs }.GetNewClosure()
    $sharedBudgetDelay = {
        param([long]$DelayMs)
        $sharedBudgetState.delays.Add($DelayMs)
        $sharedBudgetState.elapsedMs = [long]$sharedBudgetState.elapsedMs + $DelayMs
    }.GetNewClosure()
    $sharedBudgetPolicy = [pscustomobject][ordered]@{
        schemaVersion = 1
        maxAttempts = 3
        wallTimeBudgetMs = 10
        delayMilliseconds = @(10, 10)
        allowedWindowsErrors = @(32, 33, 170)
    }
    $sharedBudgetError = Assert-Throws `
        -Message 'retry 总预算不得按 leaf 重置' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$sharedBudgetApply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$sharedBudgetApply.transactionSha256) `
                -ConfirmPurge `
                -FixtureLeafDeleteFault $sharedBudgetFault `
                -FixtureLeafRetryPolicy $sharedBudgetPolicy `
                -FixtureLeafRetryElapsedMilliseconds $sharedBudgetElapsed `
                -FixtureLeafRetryDelay $sharedBudgetDelay `
                -FixturePolicyPath $fencedPolicyPath `
                -FixtureEvidenceRoot $fencedEvidenceRoot
        }
    Assert-True ($sharedBudgetError -match 'Injected safe-delete leaf failure') `
        '第二叶预算耗尽必须保留原始 allowlisted 失败'
    Assert-True (
        $sharedBudgetState.calls -eq 3 -and
        ((@($sharedBudgetState.delays) -join ',') -ceq '10')) `
        '第一叶消耗完整预算后，第二叶不得获得独立 retry 预算'
    Assert-True (
        -not [IO.File]::Exists((Join-Path $sharedBudgetApply.quarantinePath 'a-consumes-budget.txt')) -and
        [IO.File]::Exists((Join-Path $sharedBudgetApply.quarantinePath 'b-no-budget-left.txt'))) `
        '共享预算耗尽必须留下准确的 partial commit 边界'
    $sharedBudgetTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$sharedBudgetApply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $sharedBudgetApply.transactionPath) `
        -AllowedExactPaths @([string]$sharedBudgetApply.transactionPath) `
        -Name 'shared retry budget transaction'
    $sharedBudgetResume = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$sharedBudgetApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$sharedBudgetTransactionSnapshot.sha256) `
        -ConfirmPurge `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($sharedBudgetResume.purged -eq $true) `
        '共享总预算耗尽后的 partial transaction 必须可重入 Purge'

    $retryCrashTarget = Join-Path $fixtureRoot 'retry-crash-candidate'
    $retryCrashMarkerRoot = Join-Path $fixtureRoot 'retry-crash-markers'
    [void][IO.Directory]::CreateDirectory($retryCrashTarget)
    [void][IO.Directory]::CreateDirectory($retryCrashMarkerRoot)
    [IO.File]::WriteAllText(
        (Join-Path $retryCrashTarget 'a-crash-committed.txt'),
        'leaf-deleted-before-failfast',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $retryCrashTarget 'b-crash-resume.txt'),
        'leaf-remains-after-failfast',
        [Text.UTF8Encoding]::new($false))
    $retryCrashPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $retryCrashTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $retryCrashApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$retryCrashPlan.planPath) `
        -ApprovedPlanSha256 ([string]$retryCrashPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $retryCrashStart = [Diagnostics.ProcessStartInfo]::new()
    $retryCrashStart.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $retryCrashStart.UseShellExecute = $false
    $retryCrashStart.CreateNoWindow = $true
    $retryCrashStart.RedirectStandardOutput = $true
    $retryCrashStart.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $purgeCrashFixturePath,
            '-TransactionPath', [string]$retryCrashApply.transactionPath,
            '-ApprovedTransactionSha256', [string]$retryCrashApply.transactionSha256,
            '-FixturePolicyPath', $fencedPolicyPath,
            '-FixtureEvidenceRoot', $fencedEvidenceRoot,
            '-MarkerRoot', $retryCrashMarkerRoot,
            '-Scenario', 'FailFastAfterLeafDelete')) {
        [void]$retryCrashStart.ArgumentList.Add($argument)
    }
    $retryCrashProcess = [Diagnostics.Process]::Start($retryCrashStart)
    $retryCrashStdout = $retryCrashProcess.StandardOutput.ReadToEndAsync()
    $retryCrashStderr = $retryCrashProcess.StandardError.ReadToEndAsync()
    Assert-True ($retryCrashProcess.WaitForExit(20000)) `
        'leaf FailFast fixture 必须在 20 秒内退出'
    $retryCrashOutput = $retryCrashStdout.GetAwaiter().GetResult()
    $retryCrashErrorOutput = $retryCrashStderr.GetAwaiter().GetResult()
    Assert-True ($retryCrashProcess.ExitCode -ne 0) `
        "leaf FailFast fixture 必须非零退出；stdout=$retryCrashOutput stderr=$retryCrashErrorOutput"
    $retryCrashProcess.Dispose()
    $retryCrashProcess = $null
    Assert-True ([IO.File]::Exists((Join-Path $retryCrashMarkerRoot 'after-leaf-delete.marker'))) `
        'leaf FailFast 必须命中真实删除后的精确 checkpoint'
    Assert-True (
        -not [IO.File]::Exists((Join-Path $retryCrashApply.quarantinePath 'a-crash-committed.txt')) -and
        [IO.File]::Exists((Join-Path $retryCrashApply.quarantinePath 'b-crash-resume.txt'))) `
        '强杀后必须保留已 commit 与未 commit leaf 的 partial manifest 边界'
    $retryCrashTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$retryCrashApply.transactionPath) `
        -CapabilityRoot (Split-Path -Parent $retryCrashApply.transactionPath) `
        -AllowedExactPaths @([string]$retryCrashApply.transactionPath) `
        -Name 'retry crash transaction'
    $retryCrashTransaction = [Text.UTF8Encoding]::new($false).GetString(
        $retryCrashTransactionSnapshot.bytes) |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ($retryCrashTransaction.status -ceq 'purging') `
        'leaf delete 后强杀必须留下 purging transaction'
    $retryCrashStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $retryCrashOperation = @($retryCrashStatus.operations | Where-Object {
        [string]$_.targetPath -ceq $retryCrashTarget
    })
    Assert-True (
        $retryCrashOperation.Count -eq 1 -and
        $retryCrashOperation[0].lifecycle -ceq 'purge-resumable' -and
        ((@($retryCrashOperation[0].safeActions) -join ',') -ceq 'purge')) `
        'leaf 强杀恢复必须只暴露 purge-resumable/purge'
    $retryCrashResume = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$retryCrashApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$retryCrashTransactionSnapshot.sha256) `
        -ConfirmPurge `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    Assert-True ($retryCrashResume.purged -eq $true) `
        'leaf 强杀后重入必须按 partial manifest 完成 Purge'

    if ($Slice -ceq 'Retry') {
        [pscustomobject][ordered]@{
            ok = $true
            suite = 'CodexSafeTreeDeleteRetry'
            scenarios = 11
            checks = 49
        }
        return
    }

    Invoke-ReclaimScenarios | Out-Null

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteControlPlane'
        slices = 9
    }
} finally {
    if ($null -ne $producerProcess) {
        if (-not $producerProcess.HasExited) { $producerProcess.Kill($true) }
        [void]$producerProcess.WaitForExit(10000)
        $producerProcess.Dispose()
    }
    if ($null -ne $crashedProducerProcess) {
        if (-not $crashedProducerProcess.HasExited) { $crashedProducerProcess.Kill($true) }
        [void]$crashedProducerProcess.WaitForExit(10000)
        $crashedProducerProcess.Dispose()
    }
    if ($null -ne $lateProducerProcess) {
        if (-not $lateProducerProcess.HasExited) { $lateProducerProcess.Kill($true) }
        [void]$lateProducerProcess.WaitForExit(10000)
        $lateProducerProcess.Dispose()
    }
    if ($null -ne $retryCrashProcess) {
        if (-not $retryCrashProcess.HasExited) { $retryCrashProcess.Kill($true) }
        [void]$retryCrashProcess.WaitForExit(10000)
        $retryCrashProcess.Dispose()
    }
    Remove-TestTree -Path $fixtureRoot
}
