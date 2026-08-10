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
$batchFailureHardLinkPath = $null
$batchFailureHardLinkAliasPath = $null
$batchPurgeMappedImageProbe = $null

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

    $archiveEvidenceRoot = Join-Path $fixtureRoot 'archive-evidence'
    $archiveTarget = Join-Path $fixtureRoot 'archive-candidate'
    [void][IO.Directory]::CreateDirectory($archiveTarget)
    [IO.File]::WriteAllText(
        (Join-Path $archiveTarget 'payload.txt'),
        'archive-terminal-v1',
        [Text.UTF8Encoding]::new($false))
    $archivePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $archiveTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archiveApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$archivePlan.planPath) `
        -ApprovedPlanSha256 ([string]$archivePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archivePurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$archiveApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$archiveApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archiveV2Transaction = Get-Content -Raw -LiteralPath $archivePurge.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $archiveV1Transaction = [pscustomobject][ordered]@{
        artifactType = [string]$archiveV2Transaction.artifactType
        schemaVersion = 1L
        generationId = [string]$archiveV2Transaction.generationId
        planPath = [string]$archiveV2Transaction.planPath
        planSha256 = [string]$archiveV2Transaction.planSha256
        targetPath = [string]$archiveV2Transaction.targetPath
        quarantinePath = [string]$archiveV2Transaction.quarantinePath
        status = [string]$archiveV2Transaction.status
        updatedAtUtc = [string]$archiveV2Transaction.updatedAtUtc
    }
    [IO.File]::WriteAllText(
        $archivePurge.transactionPath,
        ($archiveV1Transaction | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $archiveTransactionSha256 =
        (Get-FileHash -LiteralPath $archivePurge.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveRunDirectory = Split-Path -Parent ([string]$archivePurge.transactionPath)
    $archiveOperationId = Split-Path -Leaf $archiveRunDirectory
    $beforeArchiveFiles = @(Get-FixtureFileState -Root $archiveRunDirectory)
    $beforeArchiveStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    Assert-True ($archiveOperationId -cin @($beforeArchiveStatus.migrationReadiness.blockingRecords)) `
        '未归档的 terminal v1 transaction 必须继续阻断 Status'

    $unconfirmedArchive = & $entryPath `
        -Mode Archive `
        -TransactionPath ([string]$archivePurge.transactionPath) `
        -ApprovedTransactionSha256 $archiveTransactionSha256 `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    Assert-True (-not $unconfirmedArchive.archived -and
        [string]$unconfirmedArchive.refusalReason -ceq 'confirm-archive-required') `
        'Archive 缺少显式确认必须以稳定结构化原因拒绝'
    Assert-True (
        (($beforeArchiveFiles | ConvertTo-Json -Depth 16 -Compress) -ceq
            ((Get-FixtureFileState -Root $archiveRunDirectory) |
                ConvertTo-Json -Depth 16 -Compress))) `
        'Archive 确认拒绝必须保持 operation run 零写入'

    $archive = & $entryPath `
        -Mode Archive `
        -TransactionPath ([string]$archivePurge.transactionPath) `
        -ApprovedTransactionSha256 $archiveTransactionSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archiveMarkerPath = Join-Path $archiveRunDirectory 'terminal-archive.json'
    Assert-True ($archive.archived -eq $true -and -not $archive.alreadyArchived) `
        '已验证 terminal v1 transaction 必须可受管归档'
    Assert-True ([string]$archive.archivePath -ceq $archiveMarkerPath -and
        [IO.File]::Exists($archiveMarkerPath)) `
        'Archive 必须在 operation run 内发布固定 create-only marker'
    $archiveDocument = Get-Content -Raw -LiteralPath $archiveMarkerPath |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $archiveTime = [datetimeoffset]::MinValue
    Assert-True ($archiveDocument.artifactType -ceq
        'env-governance.codex-safe-tree-delete-terminal-archive' -and
        $archiveDocument.schemaVersion -eq 1L -and
        [datetimeoffset]::TryParseExact(
            [string]$archiveDocument.archivedAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$archiveTime)) `
        'Archive marker 必须使用稳定 schema 并记录可追溯归档时点'
    $afterArchiveFiles = @(Get-FixtureFileState -Root $archiveRunDirectory)
    Assert-True ($afterArchiveFiles.Count -eq ($beforeArchiveFiles.Count + 1)) `
        'Archive 只允许新增一份 marker，不得删除 evidence'
    foreach ($beforeArchiveFile in $beforeArchiveFiles) {
        $afterArchiveFile = @($afterArchiveFiles | Where-Object {
            [string]$_.relativePath -ceq [string]$beforeArchiveFile.relativePath
        })
        Assert-True ($afterArchiveFile.Count -eq 1 -and
            [string]$afterArchiveFile[0].sha256 -ceq [string]$beforeArchiveFile.sha256 -and
            ((@($afterArchiveFile[0].identity) -join '|') -ceq
                (@($beforeArchiveFile.identity) -join '|'))) `
            "Archive 不得改写或删除既有 evidence：$($beforeArchiveFile.relativePath)"
    }
    $afterArchiveStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archivedOperation = @($afterArchiveStatus.operations | Where-Object operationId -ceq $archiveOperationId)
    Assert-True ($afterArchiveStatus.complete -eq $true -and
        $archivedOperation.Count -eq 1 -and
        $archivedOperation[0].lifecycle -ceq 'terminal' -and
        $archiveOperationId -cnotin @($afterArchiveStatus.migrationReadiness.blockingRecords)) `
        'Status 必须认证 Archive marker 后让 operation 退出 blockingRecords'
    Assert-MetricsContract -Metrics $archive.metrics -Phase 'archive'

    $archiveCandidatePolicyPath = Join-Path $fixtureRoot 'archive-policy-v5-candidate.json'
    $archiveCandidatePolicy = $policy | ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16 -DateKind String -ErrorAction Stop
    $archiveCandidatePolicy.schemaVersion = 5L
    $archiveCandidatePolicy.entries[0] | Add-Member `
        -NotePropertyName minimumQuarantineAgeMinutes -NotePropertyValue 0L
    $archiveCandidatePolicy.entries[0] | Add-Member `
        -NotePropertyName producerFenceMode -NotePropertyValue 'manual-only'
    [IO.File]::WriteAllText(
        $archiveCandidatePolicyPath,
        ($archiveCandidatePolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $archiveCandidatePolicySha256 =
        (Get-FileHash -LiteralPath $archiveCandidatePolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveMigrationStatus = & $entryPath `
        -Mode Status `
        -FixtureCandidatePolicyPath $archiveCandidatePolicyPath `
        -FixtureApprovedCandidatePolicySha256 $archiveCandidatePolicySha256 `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    Assert-True ($archiveMigrationStatus.migrationReadiness.evaluated -eq $true -and
        $archiveMigrationStatus.migrationReadiness.ready -eq $true -and
        @($archiveMigrationStatus.migrationReadiness.blockingRecords).Count -eq 0) `
        '已归档 terminal v1 operation 不得阻断 candidate v5 migration readiness'

    $archiveMarkerBeforeReplay = Get-CodexHookCapabilityFileSnapshot `
        -Path $archiveMarkerPath `
        -CapabilityRoot $archiveRunDirectory `
        -AllowedExactPaths @($archiveMarkerPath) `
        -Name 'safe-delete Archive replay marker before'
    $archiveReplay = & $entryPath `
        -Mode Archive `
        -TransactionPath ([string]$archivePurge.transactionPath) `
        -ApprovedTransactionSha256 $archiveTransactionSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archiveMarkerAfterReplay = Get-CodexHookCapabilityFileSnapshot `
        -Path $archiveMarkerPath `
        -CapabilityRoot $archiveRunDirectory `
        -AllowedExactPaths @($archiveMarkerPath) `
        -Name 'safe-delete Archive replay marker after'
    Assert-True ($archiveReplay.archived -eq $true -and $archiveReplay.alreadyArchived -eq $true) `
        '重复 Archive 必须报告已归档并保持幂等'
    Assert-True ([string]$archiveMarkerAfterReplay.sha256 -ceq
        [string]$archiveMarkerBeforeReplay.sha256 -and
        ((@($archiveMarkerAfterReplay.identity) -join '|') -ceq
            (@($archiveMarkerBeforeReplay.identity) -join '|'))) `
        '重复 Archive 不得改变 create-only marker bytes 或 file identity'

    $archiveMarkerBytes = [IO.File]::ReadAllBytes($archiveMarkerPath)
    $forgedArchiveDocument = Get-Content -Raw -LiteralPath $archiveMarkerPath |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $forgedArchiveDocument.transactionSha256 = '0' * 64
    [IO.File]::WriteAllText(
        $archiveMarkerPath,
        ($forgedArchiveDocument | ConvertTo-Json -Depth 32),
        [Text.UTF8Encoding]::new($false))
    $forgedArchiveStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $forgedArchiveOperation = @($forgedArchiveStatus.operations |
        Where-Object operationId -ceq $archiveOperationId)
    Assert-True (-not $forgedArchiveStatus.complete -and
        $forgedArchiveOperation.Count -eq 1 -and
        $forgedArchiveOperation[0].lifecycle -ceq 'manual-review' -and
        $archiveOperationId -cin @($forgedArchiveStatus.migrationReadiness.blockingRecords)) `
        'Status 不得把伪造 transaction SHA 的 marker 当成可信 terminal 认证'
    [IO.File]::WriteAllBytes($archiveMarkerPath, $archiveMarkerBytes)
    $restoredArchiveMarker = Get-CodexHookCapabilityFileSnapshot `
        -Path $archiveMarkerPath `
        -CapabilityRoot $archiveRunDirectory `
        -AllowedExactPaths @($archiveMarkerPath) `
        -Name 'safe-delete Archive marker restored after forgery test'
    Assert-True ([string]$restoredArchiveMarker.sha256 -ceq
        [string]$archiveMarkerBeforeReplay.sha256 -and
        ((@($restoredArchiveMarker.identity) -join '|') -ceq
            (@($archiveMarkerBeforeReplay.identity) -join '|'))) `
        '伪造 marker fixture 恢复必须保留原始 bytes 与 identity'

    $archivedTransactionBytes = [IO.File]::ReadAllBytes([string]$archivePurge.transactionPath)
    $archivedTransactionBeforeReplacement = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$archivePurge.transactionPath) `
        -CapabilityRoot $archiveRunDirectory `
        -AllowedExactPaths @([string]$archivePurge.transactionPath) `
        -Name 'safe-delete archived transaction before identity replacement'
    [IO.File]::Delete([string]$archivePurge.transactionPath)
    [IO.File]::WriteAllBytes([string]$archivePurge.transactionPath, $archivedTransactionBytes)
    $archivedTransactionAfterReplacement = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$archivePurge.transactionPath) `
        -CapabilityRoot $archiveRunDirectory `
        -AllowedExactPaths @([string]$archivePurge.transactionPath) `
        -Name 'safe-delete archived transaction after identity replacement'
    Assert-True ([string]$archivedTransactionAfterReplacement.sha256 -ceq
        [string]$archivedTransactionBeforeReplacement.sha256 -and
        ((@($archivedTransactionAfterReplacement.identity) -join '|') -cne
            (@($archivedTransactionBeforeReplacement.identity) -join '|'))) `
        'identity replacement fixture 必须保持 transaction bytes 但更换 file identity'
    $identityDriftStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $identityDriftOperation = @($identityDriftStatus.operations |
        Where-Object operationId -ceq $archiveOperationId)
    Assert-True (-not $identityDriftStatus.complete -and
        $identityDriftOperation.Count -eq 1 -and
        $identityDriftOperation[0].lifecycle -ceq 'manual-review' -and
        (($identityDriftOperation[0].errors -join ' ') -match 'identity')) `
        'Status 必须拒绝 bytes 相同但 transaction file identity 已替换的 Archive marker'

    $archiveRefusalTarget = Join-Path $fixtureRoot 'archive-refusal-candidate'
    [void][IO.Directory]::CreateDirectory($archiveRefusalTarget)
    [IO.File]::WriteAllText(
        (Join-Path $archiveRefusalTarget 'payload.txt'),
        'archive-refusal-v1',
        [Text.UTF8Encoding]::new($false))
    $archiveRefusalPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $archiveRefusalTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archiveRefusalApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$archiveRefusalPlan.planPath) `
        -ApprovedPlanSha256 ([string]$archiveRefusalPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $archiveRefusalV2 = Get-Content -Raw -LiteralPath $archiveRefusalApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $archiveRefusalV1 = [pscustomobject][ordered]@{
        artifactType = [string]$archiveRefusalV2.artifactType
        schemaVersion = 1L
        generationId = [string]$archiveRefusalV2.generationId
        planPath = [string]$archiveRefusalV2.planPath
        planSha256 = [string]$archiveRefusalV2.planSha256
        targetPath = [string]$archiveRefusalV2.targetPath
        quarantinePath = [string]$archiveRefusalV2.quarantinePath
        status = [string]$archiveRefusalV2.status
        updatedAtUtc = [string]$archiveRefusalV2.updatedAtUtc
    }
    $archiveRefusalRunDirectory = Split-Path -Parent ([string]$archiveRefusalApply.transactionPath)
    $archiveRefusalMarkerPath = Join-Path $archiveRefusalRunDirectory 'terminal-archive.json'
    foreach ($nonTerminalStatus in @(
            'prepared', 'quarantined', 'purging', 'restored', 'rolled-back')) {
        $archiveRefusalV1.status = $nonTerminalStatus
        [IO.File]::WriteAllText(
            $archiveRefusalApply.transactionPath,
            ($archiveRefusalV1 | ConvertTo-Json -Depth 16),
            [Text.UTF8Encoding]::new($false))
        $nonTerminalSha256 =
            (Get-FileHash -LiteralPath $archiveRefusalApply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $beforeNonTerminalArchive = @(Get-FixtureFileState -Root $archiveRefusalRunDirectory)
        $nonTerminalArchive = & $entryPath `
            -Mode Archive `
            -TransactionPath ([string]$archiveRefusalApply.transactionPath) `
            -ApprovedTransactionSha256 $nonTerminalSha256 `
            -ConfirmArchive `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $archiveEvidenceRoot
        Assert-True (-not $nonTerminalArchive.archived -and
            [string]$nonTerminalArchive.refusalReason -ceq 'transaction-status-not-purged') `
            "Archive 必须以稳定原因拒绝 v1 $nonTerminalStatus transaction"
        Assert-True (
            (($beforeNonTerminalArchive | ConvertTo-Json -Depth 16 -Compress) -ceq
                ((Get-FixtureFileState -Root $archiveRefusalRunDirectory) |
                    ConvertTo-Json -Depth 16 -Compress)) -and
            -not [IO.File]::Exists($archiveRefusalMarkerPath)) `
            "Archive 拒绝 v1 $nonTerminalStatus transaction 时必须零写入"
    }
    $archiveRefusalV1.status = 'purged'
    [IO.File]::WriteAllText(
        $archiveRefusalApply.transactionPath,
        ($archiveRefusalV1 | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $quarantinePresentTransactionSha256 =
        (Get-FileHash -LiteralPath $archiveRefusalApply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $beforeQuarantinePresentArchive = @(Get-FixtureFileState -Root $archiveRefusalRunDirectory)
    $quarantinePresentArchive = & $entryPath `
        -Mode Archive `
        -TransactionPath ([string]$archiveRefusalApply.transactionPath) `
        -ApprovedTransactionSha256 $quarantinePresentTransactionSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    Assert-True (-not $quarantinePresentArchive.archived -and
        [string]$quarantinePresentArchive.refusalReason -ceq 'quarantine-present') `
        'Archive 必须以稳定原因拒绝 quarantine 仍存在的 purged transaction'
    Assert-True (
        (($beforeQuarantinePresentArchive | ConvertTo-Json -Depth 16 -Compress) -ceq
            ((Get-FixtureFileState -Root $archiveRefusalRunDirectory) |
                ConvertTo-Json -Depth 16 -Compress)) -and
        -not [IO.File]::Exists($archiveRefusalMarkerPath)) `
        'Archive 拒绝 quarantine 仍存在的 transaction 时必须零写入'

    $invalidV2ArchiveTarget = Join-Path $fixtureRoot 'archive-invalid-v2-journal'
    [void][IO.Directory]::CreateDirectory($invalidV2ArchiveTarget)
    $invalidV2ArchivePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $invalidV2ArchiveTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $invalidV2ArchiveApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$invalidV2ArchivePlan.planPath) `
        -ApprovedPlanSha256 ([string]$invalidV2ArchivePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $invalidV2ArchivePurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$invalidV2ArchiveApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$invalidV2ArchiveApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $invalidV2ArchiveTransaction = Get-Content -Raw -LiteralPath $invalidV2ArchivePurge.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $invalidV2ArchivePlanDocument = Get-Content -Raw -LiteralPath $invalidV2ArchivePlan.planPath |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $invalidV2ArchiveRunDirectory = Split-Path -Parent ([string]$invalidV2ArchivePurge.transactionPath)
    $invalidV2OperationId = '0' * 32
    $invalidV2ArchiveTransaction.directoryCommitAnchors = @([pscustomobject][ordered]@{
        generationId = [string]$invalidV2ArchiveTransaction.generationId
        operationId = $invalidV2OperationId
        directoryPath = [string]$invalidV2ArchiveTransaction.quarantinePath
        relativePath = '.'
        volumeSerialNumber = [string]$invalidV2ArchivePlanDocument.treeManifest.rootIdentity[0]
        fileIndex = [string]$invalidV2ArchivePlanDocument.treeManifest.rootIdentity[1]
        freezeIntentPath = Join-Path $invalidV2ArchiveRunDirectory `
            "directory-delete-$invalidV2OperationId-freeze.json"
        freezeIntentSha256 = '0' * 64
        freezeIntentIdentity = @($invalidV2ArchivePlanDocument.treeManifest.rootIdentity)
        commitIntentPath = Join-Path $invalidV2ArchiveRunDirectory `
            "directory-delete-$invalidV2OperationId-commit.json"
        commitIntentSha256 = '0' * 64
        commitIntentIdentity = @($invalidV2ArchivePlanDocument.treeManifest.rootIdentity)
    })
    [IO.File]::WriteAllText(
        $invalidV2ArchivePurge.transactionPath,
        ($invalidV2ArchiveTransaction | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    $invalidV2ArchiveTransactionSha256 =
        (Get-FileHash -LiteralPath $invalidV2ArchivePurge.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $invalidV2ArchiveMarkerPath = Join-Path $invalidV2ArchiveRunDirectory 'terminal-archive.json'
    $invalidV2ArchiveError = $null
    try {
        & $entryPath `
            -Mode Archive `
            -TransactionPath ([string]$invalidV2ArchivePurge.transactionPath) `
            -ApprovedTransactionSha256 $invalidV2ArchiveTransactionSha256 `
            -ConfirmArchive `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $archiveEvidenceRoot | Out-Null
    } catch {
        $invalidV2ArchiveError = $_.Exception.Message
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$invalidV2ArchiveError) -and
        -not [IO.File]::Exists($invalidV2ArchiveMarkerPath)) `
        'Archive 必须拒绝 directory commit anchor/journal 绑定畸形的 purged v2 且 marker 零写入'

    $invalidPlanTimeTarget = Join-Path $fixtureRoot 'archive-invalid-plan-time'
    [void][IO.Directory]::CreateDirectory($invalidPlanTimeTarget)
    [IO.File]::WriteAllText(
        (Join-Path $invalidPlanTimeTarget 'payload.txt'),
        'archive-invalid-plan-time',
        [Text.UTF8Encoding]::new($false))
    $invalidPlanTimePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $invalidPlanTimeTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $invalidPlanTimeApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$invalidPlanTimePlan.planPath) `
        -ApprovedPlanSha256 ([string]$invalidPlanTimePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $invalidPlanTimePurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$invalidPlanTimeApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$invalidPlanTimeApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $archiveEvidenceRoot
    $invalidPlanTimeDocument = Get-Content -Raw -LiteralPath $invalidPlanTimePlan.planPath |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $invalidPlanTimeDocument.expiresAtUtc = 'not-a-roundtrip-timestamp'
    [IO.File]::WriteAllText(
        $invalidPlanTimePlan.planPath,
        ($invalidPlanTimeDocument | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    $invalidPlanTimePlanSha256 =
        (Get-FileHash -LiteralPath $invalidPlanTimePlan.planPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $invalidPlanTimeTransaction = Get-Content -Raw -LiteralPath $invalidPlanTimePurge.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $invalidPlanTimeTransaction.planSha256 = $invalidPlanTimePlanSha256
    [IO.File]::WriteAllText(
        $invalidPlanTimePurge.transactionPath,
        ($invalidPlanTimeTransaction | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    $invalidPlanTimeTransactionSha256 =
        (Get-FileHash -LiteralPath $invalidPlanTimePurge.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $invalidPlanTimeRunDirectory = Split-Path -Parent ([string]$invalidPlanTimePurge.transactionPath)
    $invalidPlanTimeMarkerPath = Join-Path $invalidPlanTimeRunDirectory 'terminal-archive.json'
    $invalidPlanTimeRunBefore = @(Get-FixtureFileState -Root $invalidPlanTimeRunDirectory)
    $invalidPlanTimeError = $null
    try {
        & $entryPath `
            -Mode Archive `
            -TransactionPath ([string]$invalidPlanTimePurge.transactionPath) `
            -ApprovedTransactionSha256 $invalidPlanTimeTransactionSha256 `
            -ConfirmArchive `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $archiveEvidenceRoot | Out-Null
    } catch {
        $invalidPlanTimeError = $_.Exception.Message
    }
    $invalidPlanTimeRunAfter = @(Get-FixtureFileState -Root $invalidPlanTimeRunDirectory)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$invalidPlanTimeError) -and
        (($invalidPlanTimeRunBefore | ConvertTo-Json -Depth 16 -Compress) -ceq
            ($invalidPlanTimeRunAfter | ConvertTo-Json -Depth 16 -Compress)) -and
        -not [IO.File]::Exists($invalidPlanTimeMarkerPath)) `
        'Archive 必须拒绝 expiresAtUtc 语法畸形但 SHA 重新绑定的历史 v2 plan 且 marker 零写入'

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

    $v1BatchTarget = Join-Path $fixtureRoot 'batch-v1-candidate'
    [void][IO.Directory]::CreateDirectory($v1BatchTarget)
    [IO.File]::WriteAllText(
        (Join-Path $v1BatchTarget 'legacy.txt'),
        'legacy-transaction',
        [Text.UTF8Encoding]::new($false))
    $v1BatchPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $v1BatchTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $v1BatchApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$v1BatchPlan.planPath) `
        -ApprovedPlanSha256 ([string]$v1BatchPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $v3BatchTransaction = Get-Content -Raw -LiteralPath $v1BatchApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $v1BatchTransaction = [pscustomobject][ordered]@{
        artifactType = [string]$v3BatchTransaction.artifactType
        schemaVersion = 1L
        generationId = [string]$v3BatchTransaction.generationId
        planPath = [string]$v3BatchTransaction.planPath
        planSha256 = [string]$v3BatchTransaction.planSha256
        targetPath = [string]$v3BatchTransaction.targetPath
        quarantinePath = [string]$v3BatchTransaction.quarantinePath
        status = [string]$v3BatchTransaction.status
        updatedAtUtc = [string]$v3BatchTransaction.updatedAtUtc
    }
    [IO.File]::WriteAllText(
        $v1BatchApply.transactionPath,
        ($v1BatchTransaction | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $v1BatchTransactionSha256 =
        (Get-FileHash -LiteralPath $v1BatchApply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $v1BatchQuarantineBefore = @(Get-FixtureFileState -Root $v1BatchApply.quarantinePath)

    $healthyBatchTarget = Join-Path $fixtureRoot 'batch-healthy-candidate'
    [void][IO.Directory]::CreateDirectory($healthyBatchTarget)
    [IO.File]::WriteAllText(
        (Join-Path $healthyBatchTarget 'healthy.txt'),
        'healthy-target',
        [Text.UTF8Encoding]::new($false))
    $schemaFilteredBatch = & $entryPath `
        -Mode BatchPurge `
        -TargetPaths @($v1BatchTarget, $healthyBatchTarget) `
        -CapabilityRoot $fixtureRoot `
        -ConfirmApply `
        -ConfirmPurge `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $schemaSkipped = @($schemaFilteredBatch.results | Where-Object {
        [string]$_.targetPath -ceq $v1BatchTarget
    })
    Assert-True (-not $schemaFilteredBatch.completed) `
        '含不可执行 transaction schema 的 BatchPurge 不得报告整批完成'
    Assert-True ($schemaFilteredBatch.targetCount -eq 2 -and
        $schemaFilteredBatch.purgedCount -eq 1 -and
        $schemaFilteredBatch.recoveredCount -eq 0 -and
        $schemaFilteredBatch.alreadyAbsentCount -eq 0 -and
        $schemaFilteredBatch.skippedCount -eq 1 -and
        $schemaFilteredBatch.failedCount -eq 0) `
        'schema 过滤批次的汇总计数必须与真实结果一致'
    Assert-True ($schemaSkipped.Count -eq 1 -and
        $schemaSkipped[0].action -ceq 'skipped-unsupported-transaction-schema' -and
        $schemaSkipped[0].reason -ceq 'transaction-schema-unsupported' -and
        $schemaSkipped[0].purged -eq $false) `
        'v1 transaction 必须在挑选阶段以稳定 action/reason 跳过'
    Assert-True (-not [IO.Directory]::Exists($healthyBatchTarget)) `
        'v1 transaction 被跳过后同批健康目标必须继续完成'
    Assert-True ([IO.Directory]::Exists([string]$v1BatchApply.quarantinePath) -and
        -not [IO.Directory]::Exists($v1BatchTarget)) `
        'v1 transaction 被拒绝时 target/quarantine namespace 必须零写入'
    Assert-True (
        (Get-FileHash -LiteralPath $v1BatchApply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant() `
            -ceq $v1BatchTransactionSha256) `
        'v1 transaction 被拒绝时 transaction bytes 必须零写入'
    $v1BatchQuarantineAfter = @(Get-FixtureFileState -Root $v1BatchApply.quarantinePath)
    Assert-True (
        (($v1BatchQuarantineBefore | ConvertTo-Json -Depth 16 -Compress) -ceq
            ($v1BatchQuarantineAfter | ConvertTo-Json -Depth 16 -Compress))) `
        'v1 transaction 被拒绝时 quarantine 内容必须零写入'

    $mixedSchemaTarget = Join-Path $fixtureRoot 'batch-mixed-schema-candidate'
    [void][IO.Directory]::CreateDirectory($mixedSchemaTarget)
    [IO.File]::WriteAllText(
        (Join-Path $mixedSchemaTarget 'legacy.txt'),
        'legacy-generation',
        [Text.UTF8Encoding]::new($false))
    $mixedV1Plan = & $entryPath `
        -Mode Plan `
        -TargetPath $mixedSchemaTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $mixedV1Apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$mixedV1Plan.planPath) `
        -ApprovedPlanSha256 ([string]$mixedV1Plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $mixedV3Transaction = Get-Content -Raw -LiteralPath $mixedV1Apply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $mixedV1Transaction = [pscustomobject][ordered]@{
        artifactType = [string]$mixedV3Transaction.artifactType
        schemaVersion = 1L
        generationId = [string]$mixedV3Transaction.generationId
        planPath = [string]$mixedV3Transaction.planPath
        planSha256 = [string]$mixedV3Transaction.planSha256
        targetPath = [string]$mixedV3Transaction.targetPath
        quarantinePath = [string]$mixedV3Transaction.quarantinePath
        status = [string]$mixedV3Transaction.status
        updatedAtUtc = [string]$mixedV3Transaction.updatedAtUtc
    }
    [IO.File]::WriteAllText(
        $mixedV1Apply.transactionPath,
        ($mixedV1Transaction | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    [void][IO.Directory]::CreateDirectory($mixedSchemaTarget)
    [IO.File]::WriteAllText(
        (Join-Path $mixedSchemaTarget 'current.txt'),
        'supported-generation',
        [Text.UTF8Encoding]::new($false))
    $mixedSupportedPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $mixedSchemaTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $mixedSupportedApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$mixedSupportedPlan.planPath) `
        -ApprovedPlanSha256 ([string]$mixedSupportedPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $mixedV1TransactionSha256 =
        (Get-FileHash -LiteralPath $mixedV1Apply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $mixedSupportedTransactionSha256 =
        (Get-FileHash -LiteralPath $mixedSupportedApply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $mixedV1QuarantineBefore = @(Get-FixtureFileState -Root $mixedV1Apply.quarantinePath)
    $mixedSupportedQuarantineBefore = @(Get-FixtureFileState -Root $mixedSupportedApply.quarantinePath)
    $mixedHealthyTarget = Join-Path $fixtureRoot 'batch-mixed-schema-healthy'
    [void][IO.Directory]::CreateDirectory($mixedHealthyTarget)
    [IO.File]::WriteAllText(
        (Join-Path $mixedHealthyTarget 'healthy.txt'),
        'continue-after-ambiguous-schema',
        [Text.UTF8Encoding]::new($false))
    $mixedSchemaBatch = & $entryPath `
        -Mode BatchPurge `
        -TargetPaths @($mixedSchemaTarget, $mixedHealthyTarget) `
        -CapabilityRoot $fixtureRoot `
        -ConfirmApply `
        -ConfirmPurge `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $mixedSchemaSkipped = @($mixedSchemaBatch.results | Where-Object {
        [string]$_.targetPath -ceq $mixedSchemaTarget
    })
    Assert-True (-not $mixedSchemaBatch.completed -and
        $mixedSchemaBatch.targetCount -eq 2 -and
        $mixedSchemaBatch.purgedCount -eq 1 -and
        $mixedSchemaBatch.recoveredCount -eq 0 -and
        $mixedSchemaBatch.alreadyAbsentCount -eq 0 -and
        $mixedSchemaBatch.skippedCount -eq 1 -and
        $mixedSchemaBatch.failedCount -eq 0) `
        'mixed schema 批次必须跳过歧义目标且保持旧计数语义'
    Assert-True ($mixedSchemaSkipped.Count -eq 1 -and
        $mixedSchemaSkipped[0].action -ceq 'skipped-ambiguous-transaction-schema' -and
        $mixedSchemaSkipped[0].reason -ceq 'transaction-schema-ambiguous' -and
        $mixedSchemaSkipped[0].purged -eq $false) `
        '同目标 mixed schema 必须返回稳定 skipped/ambiguous 结果'
    Assert-True ([IO.Directory]::Exists([string]$mixedV1Apply.quarantinePath) -and
        [IO.Directory]::Exists([string]$mixedSupportedApply.quarantinePath) -and
        -not [IO.Directory]::Exists($mixedSchemaTarget)) `
        '同目标 mixed schema 跳过时两个 quarantine namespace 都必须零写入'
    Assert-True (
        (Get-FileHash -LiteralPath $mixedV1Apply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant() `
            -ceq $mixedV1TransactionSha256 -and
        (Get-FileHash -LiteralPath $mixedSupportedApply.transactionPath -Algorithm SHA256).Hash.ToLowerInvariant() `
            -ceq $mixedSupportedTransactionSha256) `
        '同目标 mixed schema 跳过时两笔 transaction bytes 都必须零写入'
    $mixedV1QuarantineAfter = @(Get-FixtureFileState -Root $mixedV1Apply.quarantinePath)
    $mixedSupportedQuarantineAfter = @(Get-FixtureFileState -Root $mixedSupportedApply.quarantinePath)
    Assert-True (
        (($mixedV1QuarantineBefore | ConvertTo-Json -Depth 16 -Compress) -ceq
            ($mixedV1QuarantineAfter | ConvertTo-Json -Depth 16 -Compress)) -and
        (($mixedSupportedQuarantineBefore | ConvertTo-Json -Depth 16 -Compress) -ceq
            ($mixedSupportedQuarantineAfter | ConvertTo-Json -Depth 16 -Compress))) `
        '同目标 mixed schema 跳过时两棵 quarantine 内容都必须零写入'
    Assert-True (-not [IO.Directory]::Exists($mixedHealthyTarget)) `
        '同目标 mixed schema 被跳过后同批健康目标必须继续完成'

    $isolatedFailureTarget = Join-Path $fixtureRoot 'batch-isolated-hardlink-failure'
    [void][IO.Directory]::CreateDirectory($isolatedFailureTarget)
    $batchFailureHardLinkPath = Join-Path $isolatedFailureTarget 'payload.txt'
    $batchFailureHardLinkAliasPath = Join-Path $isolatedFailureTarget 'payload-alias.txt'
    [IO.File]::WriteAllText(
        $batchFailureHardLinkPath,
        'disallowed-hardlink',
        [Text.UTF8Encoding]::new($false))
    [void](New-Item -ItemType HardLink -Path $batchFailureHardLinkAliasPath `
        -Target $batchFailureHardLinkPath -ErrorAction Stop)
    $isolatedHealthyTarget = Join-Path $fixtureRoot 'batch-isolated-healthy'
    [void][IO.Directory]::CreateDirectory($isolatedHealthyTarget)
    [IO.File]::WriteAllText(
        (Join-Path $isolatedHealthyTarget 'healthy.txt'),
        'continue-after-failure',
        [Text.UTF8Encoding]::new($false))
    $isolatedBatch = & $entryPath `
        -Mode BatchPurge `
        -TargetPaths @($isolatedFailureTarget, $isolatedHealthyTarget) `
        -CapabilityRoot $fixtureRoot `
        -ConfirmApply `
        -ConfirmPurge `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $isolatedFailure = @($isolatedBatch.results | Where-Object {
        [string]$_.targetPath -ceq $isolatedFailureTarget
    })
    Assert-True (-not $isolatedBatch.completed -and
        $isolatedBatch.targetCount -eq 2 -and
        $isolatedBatch.purgedCount -eq 1 -and
        $isolatedBatch.recoveredCount -eq 0 -and
        $isolatedBatch.alreadyAbsentCount -eq 0 -and
        $isolatedBatch.skippedCount -eq 1 -and
        $isolatedBatch.failedCount -eq 0) `
        '单目标失败批次的完成态与汇总计数必须与真实结果一致'
    Assert-True ($isolatedFailure.Count -eq 1 -and
        $isolatedFailure[0].action -ceq 'skipped-target-error' -and
        $isolatedFailure[0].reason -ceq 'target-operation-failed' -and
        [string]$isolatedFailure[0].error -match 'hard link') `
        '单目标实际失败必须返回稳定 skipped action/reason 与原始错误'
    Assert-True ([IO.Directory]::Exists($isolatedFailureTarget) -and
        [IO.File]::Exists($batchFailureHardLinkPath) -and
        [IO.File]::Exists($batchFailureHardLinkAliasPath)) `
        '单目标 Plan 拒绝必须对失败目标零写入'
    Assert-True (-not [IO.Directory]::Exists($isolatedHealthyTarget)) `
        '单目标实际失败后同批健康目标必须继续完成'

    $postWriteFailureTarget = Join-Path $fixtureRoot 'batch-post-write-purge-failure'
    [void][IO.Directory]::CreateDirectory($postWriteFailureTarget)
    $postWriteMappedPath = Join-Path $postWriteFailureTarget 'mapped.exe'
    [IO.File]::Copy(
        [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,
        $postWriteMappedPath)
    $batchPurgeMappedImageProbe = [CodexSafeDeleteTests.MappedImageProbe]::new(
        $postWriteMappedPath)
    $postWriteHealthyTarget = Join-Path $fixtureRoot 'batch-post-write-healthy'
    [void][IO.Directory]::CreateDirectory($postWriteHealthyTarget)
    [IO.File]::WriteAllText(
        (Join-Path $postWriteHealthyTarget 'healthy.txt'),
        'continue-after-purge-failure',
        [Text.UTF8Encoding]::new($false))
    $postWriteBatch = & $entryPath `
        -Mode BatchPurge `
        -TargetPaths @($postWriteFailureTarget, $postWriteHealthyTarget) `
        -CapabilityRoot $fixtureRoot `
        -ConfirmApply `
        -ConfirmPurge `
        -FixturePolicyPath $fencedPolicyPath `
        -FixtureEvidenceRoot $fencedEvidenceRoot
    $postWriteFailure = @($postWriteBatch.results | Where-Object {
        [string]$_.targetPath -ceq $postWriteFailureTarget
    })
    $postWriteTransactions = @(Get-ChildItem -LiteralPath $fencedEvidenceRoot `
            -Filter 'transaction.json' -File -Force -Recurse | ForEach-Object {
            $document = Get-Content -Raw -LiteralPath $_.FullName |
                ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
            if ([string]$document.targetPath -ceq $postWriteFailureTarget) {
                [pscustomobject][ordered]@{
                    path = $_.FullName
                    document = $document
                }
            }
        })
    Assert-True ($postWriteTransactions.Count -eq 1 -and
        [string]$postWriteTransactions[0].document.status -cin @('quarantined', 'purging') -and
        -not [IO.Directory]::Exists($postWriteFailureTarget) -and
        [IO.Directory]::Exists([string]$postWriteTransactions[0].document.quarantinePath)) `
        ("post-write fixture 必须真实到达 Apply 成功后的 Purge 失败状态：" +
            "transactions=$($postWriteTransactions.Count) " +
            "statuses=$(@($postWriteTransactions | ForEach-Object { $_.document.status }) -join ',') " +
            "targetPresent=$([IO.Directory]::Exists($postWriteFailureTarget)) " +
            "resultAction=$(@($postWriteFailure | ForEach-Object { $_.action }) -join ',') " +
            "resultError=$(@($postWriteFailure | ForEach-Object { $_.error }) -join ',')")
    Assert-True (-not $postWriteBatch.completed -and
        $postWriteBatch.targetCount -eq 2 -and
        $postWriteBatch.purgedCount -eq 1 -and
        $postWriteBatch.recoveredCount -eq 0 -and
        $postWriteBatch.alreadyAbsentCount -eq 0 -and
        $postWriteBatch.skippedCount -eq 0 -and
        $postWriteBatch.failedCount -eq 1) `
        'Apply 后 Purge 失败批次必须与 skipped 分开计数且不得报告完成'
    Assert-True ($postWriteFailure.Count -eq 1 -and
        $postWriteFailure[0].action -ceq 'applied-purge-failed' -and
        $postWriteFailure[0].reason -ceq 'purge-failed-after-apply' -and
        $postWriteFailure[0].purged -eq $false -and
        [string]$postWriteFailure[0].error -match 'safe-tree-delete file leaf' -and
        $null -eq $postWriteFailure[0].transactionObservationError -and
        $null -eq $postWriteFailure[0].targetNamespaceObservationError -and
        $null -eq $postWriteFailure[0].quarantineNamespaceObservationError -and
        $postWriteFailure[0].recoverable -eq $true -and
        $postWriteFailure[0].purgeResumable -eq $false) `
        'Apply 后 Purge 失败必须返回稳定的非 skipped action/reason'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$postWriteFailure[0].transactionPath) -and
        [IO.File]::Exists([string]$postWriteFailure[0].transactionPath) -and
        [string]$postWriteFailure[0].transactionSha256 -match '^[0-9a-f]{64}$') `
        'Apply 后 Purge 失败必须返回可受管识别的 transaction path/SHA-256'
    $postWriteTransaction = Get-Content -Raw -LiteralPath $postWriteFailure[0].transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True (
        (Get-FileHash -LiteralPath $postWriteFailure[0].transactionPath -Algorithm SHA256).Hash.ToLowerInvariant() `
            -ceq [string]$postWriteFailure[0].transactionSha256 -and
        [string]$postWriteFailure[0].transactionStatus -ceq [string]$postWriteTransaction.status) `
        'Apply 后 Purge 失败返回的 transaction SHA/status 必须对应当前受管文档'
    Assert-True ($postWriteFailure[0].targetPresent -eq $false -and
        $postWriteFailure[0].quarantinePresent -eq $true -and
        [string]$postWriteFailure[0].quarantinePath -ceq [string]$postWriteTransaction.quarantinePath -and
        -not [IO.Directory]::Exists($postWriteFailureTarget) -and
        [IO.Directory]::Exists([string]$postWriteFailure[0].quarantinePath)) `
        'Apply 后 Purge 失败必须报告真实 target/quarantine namespace 状态'
    Assert-True (-not [IO.Directory]::Exists($postWriteHealthyTarget)) `
        'Apply 后 Purge 失败不得阻断同批健康目标'
    Assert-True ($batchPurgeMappedImageProbe.ReadFirstByte() -eq 0x4d) `
        'Apply 后 Purge 失败必须保持真实 SEC_IMAGE 映射可读'
    $batchPurgeMappedImageProbe.Dispose()
    $batchPurgeMappedImageProbe = $null

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
        slices = 10
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
    if (-not [string]::IsNullOrWhiteSpace($batchFailureHardLinkAliasPath) -and
        [IO.File]::Exists($batchFailureHardLinkAliasPath)) {
        [IO.File]::Delete($batchFailureHardLinkAliasPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($batchFailureHardLinkPath) -and
        [IO.File]::Exists($batchFailureHardLinkPath)) {
        [IO.File]::Delete($batchFailureHardLinkPath)
    }
    if ($null -ne $batchPurgeMappedImageProbe) {
        $batchPurgeMappedImageProbe.Dispose()
    }
    Remove-TestTree -Path $fixtureRoot
}
