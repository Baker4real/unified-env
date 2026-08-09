[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$crashFixturePath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteCrashFixture.ps1'
$applyCrashFixturePath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteApplyCrashFixture.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$safeTreeLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$pwshPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

. $hostSafetyLibraryPath
. $safeTreeLibraryPath

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )
    try { & $Action | Out-Null } catch { return $_.Exception.ToString() }
    throw $Message
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CodexSafeDeleteCrashParentProbe
{
    private const uint GenericWrite = 0x40000000;
    private const uint OpenAlways = 4;
    private const uint FileAttributeNormal = 0x80;
    private const uint FileFlagOpenReparsePoint = 0x00200000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string name,
        uint access,
        FileShare share,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteFileW(string name);

    public static int TryWriteNamedStream(string directoryPath)
    {
        string streamPath = directoryPath + ":parent-probe-" + Guid.NewGuid().ToString("N");
        using (SafeFileHandle handle = CreateFileW(
            streamPath,
            GenericWrite,
            FileShare.Read | FileShare.Write | FileShare.Delete,
            IntPtr.Zero,
            OpenAlways,
            FileAttributeNormal | FileFlagOpenReparsePoint,
            IntPtr.Zero))
        {
            if (handle.IsInvalid)
            {
                return Marshal.GetLastWin32Error();
            }
        }
        if (!DeleteFileW(streamPath))
        {
            return Marshal.GetLastWin32Error();
        }
        return 0;
    }
}
'@ -ErrorAction Stop

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete crash test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete crash test cleanup'
}

function Get-TransactionSnapshot {
    param([Parameter(Mandatory)][string]$TransactionPath)
    $runDirectory = Split-Path -Parent $TransactionPath
    return Get-CodexHookCapabilityFileSnapshot `
        -Path $TransactionPath `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($TransactionPath) `
        -Name 'safe-delete crash transaction snapshot'
}

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
}

$createOnlyRoot = Join-Path `
    'D:\Codex\projects' `
    ('.safe-tree-delete-create-only-{0}' -f [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($createOnlyRoot)
    $createOnlyPath = Join-Path $createOnlyRoot 'journal.json'
    $firstDocument = [pscustomobject][ordered]@{ state = 'first'; value = 1 }
    $firstSnapshot = New-CodexHookCapabilityJson `
        -Path $createOnlyPath `
        -Document $firstDocument `
        -CapabilityRoot $createOnlyRoot `
        -AllowedExactPaths @($createOnlyPath) `
        -Scope 'safe-delete create-only journal fixture'
    [byte[]]$firstBytes = [IO.File]::ReadAllBytes($createOnlyPath)
    $secondPublishError = Assert-Throws `
        -Message 'create-only journal 二次发布必须失败' `
        -Action {
            [void](New-CodexHookCapabilityJson `
                -Path $createOnlyPath `
                -Document ([pscustomobject][ordered]@{ state = 'second'; value = 2 }) `
                -CapabilityRoot $createOnlyRoot `
                -AllowedExactPaths @($createOnlyPath) `
                -Scope 'safe-delete create-only journal fixture replay')
        }
    Assert-True ($secondPublishError -match 'ExpectedExists=False|missing 状态漂移|预期不存在') `
        'create-only journal 二次发布必须返回稳定的已存在拒绝'
    $afterSecondPublish = Get-CodexHookCapabilityFileSnapshot `
        -Path $createOnlyPath `
        -CapabilityRoot $createOnlyRoot `
        -AllowedExactPaths @($createOnlyPath) `
        -Name 'safe-delete create-only journal after replay'
    Assert-True `
        ([Linq.Enumerable]::SequenceEqual(
            [byte[]]$firstBytes,
            [byte[]][IO.File]::ReadAllBytes($createOnlyPath))) `
        'create-only journal 二次发布不得改变原始 bytes'
    Assert-True `
        (Test-CodexHookDirectoryTreeIdentityEqual `
            -Expected @($firstSnapshot.identity) `
            -Actual @($afterSecondPublish.identity)) `
        'create-only journal 二次发布不得替换 file identity'
} finally {
    Remove-TestTree -Path $createOnlyRoot
}

function New-CrashCase {
    param([Parameter(Mandatory)][string]$Scenario)

    $caseRoot = Join-Path `
        'D:\Codex\projects' `
        ('.safe-tree-delete-crash-{0}-{1}' -f $Scenario.ToLowerInvariant(), [guid]::NewGuid().ToString('N'))
    $targetPath = Join-Path $caseRoot '.codex'
    $evidenceRoot = Join-Path $caseRoot 'evidence'
    $markerRoot = Join-Path $caseRoot 'markers'
    $policyPath = Join-Path $caseRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory($targetPath)
    if ($Scenario -ceq 'FailFastAfterPending') {
        [void][IO.Directory]::CreateDirectory((Join-Path $targetPath 'skill-state'))
    }
    [void][IO.Directory]::CreateDirectory($markerRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @([pscustomobject][ordered]@{
            id = 'crash-fixture'
            capabilityRoot = $targetPath
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'empty-project-state'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $targetPath `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    return [pscustomobject][ordered]@{
        scenario = $Scenario
        caseRoot = $caseRoot
        targetPath = $targetPath
        evidenceRoot = $evidenceRoot
        markerRoot = $markerRoot
        policyPath = $policyPath
        plan = $plan
        planDocument = Read-JsonDocument -Path ([string]$plan.planPath)
        apply = $apply
        originalSddl = (Get-Acl -LiteralPath ([string]$apply.quarantinePath)).Sddl
        runDirectory = Split-Path -Parent ([string]$apply.transactionPath)
    }
}

function New-ApplyCrashCase {
    $caseRoot = Join-Path `
        'D:\Codex\projects' `
        ('.safe-tree-delete-apply-crash-{0}' -f [guid]::NewGuid().ToString('N'))
    $targetPath = Join-Path $caseRoot '.codex'
    $evidenceRoot = Join-Path $caseRoot 'evidence'
    $markerRoot = Join-Path $caseRoot 'markers'
    $policyPath = Join-Path $caseRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory((Join-Path $targetPath 'skill-state'))
    [void][IO.Directory]::CreateDirectory($markerRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @([pscustomobject][ordered]@{
            id = 'apply-crash-fixture'
            capabilityRoot = $targetPath
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'empty-project-state'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $targetPath `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $planDocument = Read-JsonDocument -Path ([string]$plan.planPath)
    return [pscustomobject][ordered]@{
        caseRoot = $caseRoot
        targetPath = $targetPath
        evidenceRoot = $evidenceRoot
        markerRoot = $markerRoot
        policyPath = $policyPath
        plan = $plan
        transactionPath = Join-Path (Split-Path -Parent ([string]$plan.planPath)) 'transaction.json'
        quarantinePath = Join-Path `
            $caseRoot `
            ('.codex-safe-delete-{0}.quarantine' -f ([string]$planDocument.generationId))
    }
}

function Invoke-CrashCaseProcess {
    param([Parameter(Mandatory)][object]$Case)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        $crashFixturePath,
        '-TransactionPath',
        [string]$Case.apply.transactionPath,
        '-ApprovedTransactionSha256',
        [string]$Case.apply.transactionSha256,
        '-FixturePolicyPath',
        [string]$Case.policyPath,
        '-FixtureEvidenceRoot',
        [string]$Case.evidenceRoot,
        '-MarkerRoot',
        [string]$Case.markerRoot,
        '-Scenario',
        [string]$Case.scenario
    )) {
        [void]$start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() "crash fixture 必须启动：$($Case.scenario)"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-True `
            ($process.WaitForExit(20000)) `
            "crash fixture 必须在 20 秒内退出：$($Case.scenario)"
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(1000)
        }
        $process.Dispose()
    }
}

function Invoke-ApplyCrashCaseProcess {
    param([Parameter(Mandatory)][object]$Case)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        $applyCrashFixturePath,
        '-PlanPath',
        [string]$Case.plan.planPath,
        '-ApprovedPlanSha256',
        [string]$Case.plan.planSha256,
        '-FixturePolicyPath',
        [string]$Case.policyPath,
        '-FixtureEvidenceRoot',
        [string]$Case.evidenceRoot,
        '-MarkerRoot',
        [string]$Case.markerRoot
    )) {
        [void]$start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() 'apply crash fixture 必须启动'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-True ($process.WaitForExit(20000)) 'apply crash fixture 必须在 20 秒内退出'
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(1000)
        }
        $process.Dispose()
    }
}

function Get-CaseJournal {
    param([Parameter(Mandatory)][object]$Case)

    $freezePaths = @(Get-ChildItem `
        -LiteralPath $Case.runDirectory `
        -Filter 'directory-delete-*-freeze.json' `
        -File)
    $commitPaths = @(Get-ChildItem `
        -LiteralPath $Case.runDirectory `
        -Filter 'directory-delete-*-commit.json' `
        -File)
    $abortPaths = @(Get-ChildItem `
        -LiteralPath $Case.runDirectory `
        -Filter 'directory-delete-*-abort.json' `
        -File)
    Assert-True ($freezePaths.Count -ge 1) "每个 crash case 必须至少有一个 freeze journal：$($Case.scenario)"
    $freezeDocuments = @($freezePaths | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_
            document = Read-JsonDocument -Path $_.FullName
        }
    })
    $rootFreeze = @($freezeDocuments | Where-Object { $_.document.relativePath -ceq '.' })
    Assert-True ($rootFreeze.Count -eq 1) "每个 crash case 必须有唯一 root freeze journal：$($Case.scenario)"
    $freeze = $rootFreeze[0].document
    $expectedRoot = @($Case.planDocument.treeManifest.entries | Where-Object relativePath -ceq '.')[0]
    Assert-True ($freeze.state -ceq 'freeze-prepared') 'freeze journal 状态必须为 freeze-prepared'
    Assert-True ($freeze.generationId -ceq $Case.planDocument.generationId) 'freeze journal generation 必须匹配 plan'
    Assert-True ($freeze.directoryPath -ceq [string]$Case.apply.quarantinePath) 'freeze journal path 必须匹配 quarantine'
    Assert-True ($freeze.relativePath -ceq '.') 'freeze journal relative path 必须匹配根目录'
    Assert-True ($freeze.volumeSerialNumber -ceq [string]$expectedRoot.identity[0]) 'freeze journal volume identity 必须匹配 plan'
    Assert-True ($freeze.fileIndex -ceq [string]$expectedRoot.identity[1]) 'freeze journal file identity 必须匹配 plan'
    Assert-True ($freeze.originalSecurityDescriptorSddl -ceq $Case.originalSddl) 'freeze journal 必须保留原始 SDDL'
    return [pscustomobject][ordered]@{
        freezePath = $rootFreeze[0].path.FullName
        freeze = $freeze
        commitPaths = $commitPaths
        rootCommitPath = @($commitPaths | Where-Object {
            (Read-JsonDocument -Path $_.FullName).operationId -ceq $freeze.operationId
        } | Select-Object -First 1)
        abortPaths = $abortPaths
    }
}

function Assert-JournalReference {
    param(
        [Parameter(Mandatory)][object]$Journal,
        [Parameter(Mandatory)][object]$TerminalDocument
    )

    $freezeSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $Journal.freezePath `
        -CapabilityRoot (Split-Path -Parent $Journal.freezePath) `
        -AllowedExactPaths @($Journal.freezePath) `
        -Name 'safe-delete crash freeze journal reference'
    Assert-True `
        ($TerminalDocument.freezeIntentPath -ceq $Journal.freezePath) `
        'terminal journal 必须引用精确 freeze journal path'
    Assert-True `
        ($TerminalDocument.freezeIntentSha256 -ceq $freezeSnapshot.sha256) `
        'terminal journal 必须引用精确 freeze journal SHA-256'
    Assert-True `
        ($TerminalDocument.operationId -ceq $Journal.freeze.operationId) `
        'terminal journal operation id 必须匹配 freeze journal'
}

function Complete-CrashCase {
    param([Parameter(Mandatory)][object]$Case)

    $quarantinePath = [string]$Case.apply.quarantinePath
    if ($Case.scenario -ceq 'ConcurrentAds') {
        Remove-Item -LiteralPath $quarantinePath -Stream 'crash-window' -Force -ErrorAction Stop
    }
    if ($Case.scenario -ceq 'PreopenedAds') {
        Remove-Item -LiteralPath $quarantinePath -Stream 'held-crash-window' -Force -ErrorAction Stop
    }
    $transactionSnapshot = Get-TransactionSnapshot `
        -TransactionPath ([string]$Case.apply.transactionPath)
    $purge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$Case.apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
        -ConfirmPurge `
        -FixturePolicyPath ([string]$Case.policyPath) `
        -FixtureEvidenceRoot ([string]$Case.evidenceRoot)
    Assert-True ($purge.purged -eq $true) "crash case 必须可恢复到 purged：$($Case.scenario)"
    $transaction = Read-JsonDocument -Path ([string]$Case.apply.transactionPath)
    Assert-True ($transaction.status -ceq 'purged') "crash case transaction 必须收尾为 purged：$($Case.scenario)"
    return $purge
}

$scenarios = @(
    'ConcurrentAds',
    'PreopenedAds',
    'AclDriftAfterFreeze',
    'FailFastAfterFreeze',
    'CommitPublishReturnFailure',
    'FailFastAfterCommit',
    'FailFastAfterPending'
)
$completed = 0
foreach ($scenario in $scenarios) {
    $case = $null
    try {
        $case = New-CrashCase -Scenario $scenario
        $result = Invoke-CrashCaseProcess -Case $case
        Assert-True `
            ($result.exitCode -ne 0) `
            "crash fixture 必须非零退出：$scenario stdout=$($result.stdout) stderr=$($result.stderr)"
        $journal = Get-CaseJournal -Case $case
        $quarantinePath = [string]$case.apply.quarantinePath
        switch ($scenario) {
            'ConcurrentAds' {
                Assert-True ([IO.File]::Exists((Join-Path $case.markerRoot 'before-stream-freeze.marker'))) '并发 ADS 必须命中 freeze 前 seam'
                Assert-True ([IO.Directory]::Exists($quarantinePath)) '并发 ADS 必须保留 quarantine'
                Assert-True ($journal.commitPaths.Count -eq 0) '并发 ADS 不得发布 commit journal'
                Assert-True ($journal.abortPaths.Count -eq 1) '并发 ADS 回滚必须发布 abort journal'
                $abort = Read-JsonDocument -Path $journal.abortPaths[0].FullName
                Assert-True ($abort.state -ceq 'aborted') '并发 ADS abort journal 状态必须为 aborted'
                Assert-JournalReference -Journal $journal -TerminalDocument $abort
                $restoredSddl = (Get-Acl -LiteralPath $quarantinePath).Sddl
                Assert-True `
                    ([CodexHookGovernance.VerifiedDirectoryChainGuard]::SecurityDescriptorsHaveEquivalentDacl(
                        $case.originalSddl,
                        $restoredSddl)) `
                    "并发 ADS 回滚必须恢复等价 DACL：expected=$($case.originalSddl) actual=$restoredSddl"
                Assert-True `
                    ($abort.restoredSecurityDescriptorSddl -ceq $restoredSddl) `
                    'abort journal 必须记录实际读回的 restored SDDL'
                Assert-True `
                    ((Get-Content -LiteralPath $quarantinePath -Stream 'crash-window' -Raw) -ceq 'must-survive') `
                    '并发 ADS 必须原样保留'
            }
            'PreopenedAds' {
                Assert-True ([IO.File]::Exists((Join-Path $case.markerRoot 'preopened-ads.marker'))) '预打开 ADS 必须命中 freeze 前 seam'
                Assert-True ([IO.Directory]::Exists($quarantinePath)) '预打开 ADS 必须保留 quarantine'
                Assert-True ($journal.commitPaths.Count -eq 0) '预打开 ADS 不得发布 commit journal'
                Assert-True ($journal.abortPaths.Count -eq 1) '预打开 ADS 回滚必须发布 abort journal'
                $abort = Read-JsonDocument -Path $journal.abortPaths[0].FullName
                Assert-JournalReference -Journal $journal -TerminalDocument $abort
                $restoredSddl = (Get-Acl -LiteralPath $quarantinePath).Sddl
                Assert-True `
                    ([CodexHookGovernance.VerifiedDirectoryChainGuard]::SecurityDescriptorsHaveEquivalentDacl(
                        $case.originalSddl,
                        $restoredSddl)) `
                    '预打开 ADS 回滚必须恢复等价 DACL'
                Assert-True `
                    ((Get-Content -LiteralPath $quarantinePath -Stream 'held-crash-window' -Raw) -ceq 'held-must-survive') `
                    '预打开 ADS 句柄的数据必须原样保留'
            }
            'AclDriftAfterFreeze' {
                Assert-True ([IO.File]::Exists((Join-Path $case.markerRoot 'acl-drift-after-freeze.marker'))) 'ACL drift 必须命中 freeze 后 seam'
                Assert-True ([IO.Directory]::Exists($quarantinePath)) 'ACL drift 必须保留 quarantine'
                Assert-True ($journal.commitPaths.Count -eq 0) 'ACL drift 不得发布 commit journal'
                Assert-True ($journal.abortPaths.Count -eq 0) '无法证明回滚 ownership 时不得发布 abort journal'
                Assert-True `
                    ([CodexSafeDeleteCrashParentProbe]::TryWriteNamedStream($quarantinePath) -eq 0) `
                    'ACL drift fixture 必须真实撤销 ADS 写冻结'
            }
            'FailFastAfterFreeze' {
                Assert-True ([IO.File]::Exists((Join-Path $case.markerRoot 'after-stream-freeze.marker'))) 'freeze crash 必须命中 seam'
                Assert-True ([IO.Directory]::Exists($quarantinePath)) 'freeze crash 必须保留 quarantine'
                Assert-True ($journal.commitPaths.Count -eq 0) 'freeze crash 不得发布 commit journal'
                Assert-True ($journal.abortPaths.Count -eq 0) 'FailFast 不得伪造 abort journal'
                Assert-True ((Get-Acl -LiteralPath $quarantinePath).Sddl -cne $case.originalSddl) 'freeze crash 后 DACL 必须持久冻结'
                Assert-True `
                    ([CodexSafeDeleteCrashParentProbe]::TryWriteNamedStream($quarantinePath) -eq 5) `
                    'freeze crash 后独立父进程原生 ADS open 必须返回 access denied'
                $transactionSnapshot = Get-TransactionSnapshot `
                    -TransactionPath ([string]$case.apply.transactionPath)
                $replayFailure = Assert-Throws `
                    -Message 'freeze crash 重放的第二次普通失败必须抛出' `
                    -Action {
                        Invoke-CodexSafeTreeDeletePurge `
                            -TransactionPath ([string]$case.apply.transactionPath) `
                            -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
                            -PolicyPath ([string]$case.policyPath) `
                            -EvidenceRoot ([string]$case.evidenceRoot) `
                            -DirectoryDeleteCheckpointForTest {
                                param($DirectoryPath, $RelativePath, $Phase)
                                if ($Phase -ceq 'after-stream-freeze') {
                                    throw 'safe-delete replay fixture failure after reused freeze'
                                }
                            }
                    }
                Assert-True ($replayFailure -match 'reused freeze') `
                    'freeze crash 重放必须命中复用首份 journal 的失败 seam'
                $restoredSddl = (Get-Acl -LiteralPath $quarantinePath).Sddl
                Assert-True `
                    ([CodexHookGovernance.VerifiedDirectoryChainGuard]::SecurityDescriptorsHaveEquivalentDacl(
                        $case.originalSddl,
                        $restoredSddl)) `
                    'freeze crash 重放再次失败必须恢复首份 freeze 前原始 DACL'
                $replayedJournal = Get-CaseJournal -Case $case
                Assert-True ($replayedJournal.abortPaths.Count -eq 1) `
                    'freeze crash 重放普通失败必须为同一 operation 发布唯一 abort'
                $replayAbort = Read-JsonDocument -Path $replayedJournal.abortPaths[0].FullName
                Assert-True `
                    ([CodexHookGovernance.VerifiedDirectoryChainGuard]::SecurityDescriptorsHaveEquivalentDacl(
                        $case.originalSddl,
                        [string]$replayAbort.restoredSecurityDescriptorSddl)) `
                    'freeze crash 重放 abort 必须记录首份 freeze 前原始 DACL'
            }
            'CommitPublishReturnFailure' {
                Assert-True `
                    ([IO.File]::Exists((Join-Path $case.markerRoot 'commit-publish-return-failure.marker'))) `
                    'commit publisher 返回前失败必须命中真实 seam'
                Assert-True ([IO.Directory]::Exists($quarantinePath)) `
                    'commit publisher 返回前失败必须保留 quarantine'
                Assert-True ($journal.commitPaths.Count -eq 1) `
                    'commit publisher 返回前失败必须保留已发布 commit'
                Assert-True ($journal.abortPaths.Count -eq 0) `
                    'commit publisher 已落盘后的不确定失败绝不得发布 abort'
                $transaction = Read-JsonDocument -Path ([string]$case.apply.transactionPath)
                Assert-True (@($transaction.directoryCommitAnchors).Count -eq 0) `
                    'commit publisher 返回前失败不得伪造 transaction anchor'
                Assert-True `
                    ([CodexSafeDeleteCrashParentProbe]::TryWriteNamedStream($quarantinePath) -eq 5) `
                    'commit publisher 返回前失败必须保持 DACL 冻结'
            }
            'FailFastAfterCommit' {
                Assert-True ([IO.File]::Exists((Join-Path $case.markerRoot 'after-commit-intent.marker'))) 'commit crash 必须命中 seam'
                Assert-True ([IO.Directory]::Exists($quarantinePath)) 'commit 后、pending 前 crash 必须保留 quarantine'
                Assert-True ($journal.commitPaths.Count -eq 1) 'commit crash 必须发布一个 commit journal'
                Assert-True ($journal.abortPaths.Count -eq 0) 'commit 后不得发布 abort journal'
                $commit = Read-JsonDocument -Path $journal.commitPaths[0].FullName
                Assert-True ($commit.state -ceq 'commit-authorized') 'commit journal 状态必须为 commit-authorized'
                Assert-JournalReference -Journal $journal -TerminalDocument $commit
                Assert-True ((Get-Acl -LiteralPath $quarantinePath).Sddl -ceq $commit.appliedFrozenSecurityDescriptorSddl) 'commit crash 后必须保留已读回的 frozen SDDL'
                Assert-True `
                    ([CodexSafeDeleteCrashParentProbe]::TryWriteNamedStream($quarantinePath) -eq 5) `
                    'commit crash 后独立父进程原生 ADS open 必须返回 access denied'
            }
            'FailFastAfterPending' {
                Assert-True ([IO.File]::Exists((Join-Path $case.markerRoot 'after-delete-pending.marker'))) 'pending crash 必须命中 seam'
                Assert-True (-not [IO.Directory]::Exists($quarantinePath)) 'pending crash 只允许删除已 commit 的空 quarantine'
                Assert-True ($journal.commitPaths.Count -eq 2) 'pending crash 的两层空目录必须各有一个 commit journal'
                Assert-True ($journal.abortPaths.Count -eq 0) 'pending crash 不得发布 abort journal'
                Assert-True ($journal.rootCommitPath.Count -eq 1) 'pending crash 必须有唯一 root commit journal'
                $rootCommitPath = $journal.rootCommitPath[0].FullName
                $commit = Read-JsonDocument -Path $rootCommitPath
                Assert-JournalReference -Journal $journal -TerminalDocument $commit
                $transactionSnapshot = Get-TransactionSnapshot `
                    -TransactionPath ([string]$case.apply.transactionPath)
                $withheldCommitPath = "$rootCommitPath.withheld"
                [IO.File]::Move($rootCommitPath, $withheldCommitPath)
                try {
                    $missingCommitError = Assert-Throws `
                        -Message '缺失 commit journal 时不得把 transaction 收尾为 purged' `
                        -Action {
                            & $entryPath `
                                -Mode Purge `
                                -TransactionPath ([string]$case.apply.transactionPath) `
                                -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
                                -ConfirmPurge `
                                -FixturePolicyPath ([string]$case.policyPath) `
                                -FixtureEvidenceRoot ([string]$case.evidenceRoot)
                        }
                    Assert-True ($missingCommitError -match 'commit-authorized') '缺失 commit journal 必须返回稳定拒绝原因'
                } finally {
                    [IO.File]::Move($withheldCommitPath, $rootCommitPath)
                }
                $freezeBytes = [IO.File]::ReadAllBytes($journal.freezePath)
                $commitBytes = [IO.File]::ReadAllBytes($rootCommitPath)
                try {
                    $forgedFreeze = Read-JsonDocument -Path $journal.freezePath
                    $forgedFreeze.createdAtUtc = [datetimeoffset]::UtcNow.AddMinutes(1).ToString('o')
                    [IO.File]::WriteAllText(
                        $journal.freezePath,
                        ($forgedFreeze | ConvertTo-Json -Depth 32),
                        [Text.UTF8Encoding]::new($false))
                    $forgedFreezeSnapshot = Get-CodexHookCapabilityFileSnapshot `
                        -Path $journal.freezePath `
                        -CapabilityRoot $case.runDirectory `
                        -AllowedExactPaths @($journal.freezePath) `
                        -Name 'safe-delete forged freeze journal'
                    $forgedCommit = Read-JsonDocument -Path $rootCommitPath
                    $forgedCommit.freezeIntentSha256 = [string]$forgedFreezeSnapshot.sha256
                    [IO.File]::WriteAllText(
                        $rootCommitPath,
                        ($forgedCommit | ConvertTo-Json -Depth 32),
                        [Text.UTF8Encoding]::new($false))
                    $freezeHashError = Assert-Throws `
                        -Message '一致伪造 freeze+commit pair 时不得把 transaction 收尾为 purged' `
                        -Action {
                            & $entryPath `
                                -Mode Purge `
                                -TransactionPath ([string]$case.apply.transactionPath) `
                                -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
                                -ConfirmPurge `
                                -FixturePolicyPath ([string]$case.policyPath) `
                                -FixtureEvidenceRoot ([string]$case.evidenceRoot)
                        }
                    Assert-True ($freezeHashError -match 'SHA-256') `
                        '一致伪造 freeze+commit pair 必须被 transaction hash anchor 拒绝'
                } finally {
                    [IO.File]::WriteAllBytes($journal.freezePath, $freezeBytes)
                    [IO.File]::WriteAllBytes($rootCommitPath, $commitBytes)
                }
                [byte[]]$transactionBytes = [byte[]]$transactionSnapshot.bytes
                try {
                    $invalidCommit = Read-JsonDocument -Path $rootCommitPath
                    $invalidCommit.appliedFrozenSecurityDescriptorSddl =
                        [string]$invalidCommit.originalSecurityDescriptorSddl
                    [IO.File]::WriteAllText(
                        $rootCommitPath,
                        ($invalidCommit | ConvertTo-Json -Depth 32),
                        [Text.UTF8Encoding]::new($false))
                    $invalidCommitSnapshot = Get-CodexHookCapabilityFileSnapshot `
                        -Path $rootCommitPath `
                        -CapabilityRoot $case.runDirectory `
                        -AllowedExactPaths @($rootCommitPath) `
                        -Name 'safe-delete invalid SDDL commit journal'
                    $invalidTransaction = Read-JsonDocument -Path ([string]$case.apply.transactionPath)
                    $invalidAnchor = @($invalidTransaction.directoryCommitAnchors | Where-Object {
                        $_.operationId -ceq $invalidCommit.operationId
                    })
                    Assert-True ($invalidAnchor.Count -eq 1) `
                        'invalid SDDL fixture 必须定位唯一 transaction anchor'
                    $invalidAnchor[0].commitIntentSha256 = [string]$invalidCommitSnapshot.sha256
                    [IO.File]::WriteAllText(
                        [string]$case.apply.transactionPath,
                        ($invalidTransaction | ConvertTo-Json -Depth 64),
                        [Text.UTF8Encoding]::new($false))
                    $invalidTransactionSnapshot = Get-TransactionSnapshot `
                        -TransactionPath ([string]$case.apply.transactionPath)
                    $invalidSddlError = Assert-Throws `
                        -Message '无首位 deny 的 applied SDDL 不得授权缺失 quarantine 收尾' `
                        -Action {
                            & $entryPath `
                                -Mode Purge `
                                -TransactionPath ([string]$case.apply.transactionPath) `
                                -ApprovedTransactionSha256 ([string]$invalidTransactionSnapshot.sha256) `
                                -ConfirmPurge `
                                -FixturePolicyPath ([string]$case.policyPath) `
                                -FixtureEvidenceRoot ([string]$case.evidenceRoot)
                        }
                    Assert-True ($invalidSddlError -match 'DACL 冻结语义') `
                        'applied SDDL 必须验证首位 deny 与 requested freeze 等价'
                } finally {
                    [IO.File]::WriteAllBytes($rootCommitPath, $commitBytes)
                    [IO.File]::WriteAllBytes(
                        [string]$case.apply.transactionPath,
                        $transactionBytes)
                }
                $transactionSnapshot = Get-TransactionSnapshot `
                    -TransactionPath ([string]$case.apply.transactionPath)
                $commit = Read-JsonDocument -Path $rootCommitPath
                $freezeSnapshot = Get-CodexHookCapabilityFileSnapshot `
                    -Path $journal.freezePath `
                    -CapabilityRoot $case.runDirectory `
                    -AllowedExactPaths @($journal.freezePath) `
                    -Name 'safe-delete conflict freeze journal'
                $abortPath = Join-Path `
                    $case.runDirectory `
                    ('directory-delete-unpaired-{0}-abort.json' -f ([guid]::NewGuid().ToString('N')))
                $abortDocument = [pscustomobject][ordered]@{
                    artifactType = 'env-governance.codex-safe-tree-delete-directory-abort-intent'
                    schemaVersion = 2
                    generationId = [string]$commit.generationId
                    operationId = [string]$commit.operationId
                    directoryPath = [string]$commit.directoryPath
                    relativePath = [string]$commit.relativePath
                    volumeSerialNumber = [string]$commit.volumeSerialNumber
                    fileIndex = [string]$commit.fileIndex
                    state = 'aborted'
                    restoredSecurityDescriptorSddl = [string]$commit.originalSecurityDescriptorSddl
                    freezeIntentPath = $journal.freezePath
                    freezeIntentSha256 = [string]$freezeSnapshot.sha256
                    freezeIntentIdentity = @($freezeSnapshot.identity)
                    createdAtUtc = [datetimeoffset]::UtcNow.ToString('o')
                }
                try {
                    [void](New-CodexHookCapabilityJson `
                        -Path $abortPath `
                        -Document $abortDocument `
                        -CapabilityRoot $case.runDirectory `
                        -AllowedExactPaths @($abortPath) `
                        -Scope 'safe-delete commit abort conflict fixture')
                    $conflictError = Assert-Throws `
                        -Message 'commit+abort 冲突不得把 transaction 收尾为 purged' `
                        -Action {
                            & $entryPath `
                                -Mode Purge `
                                -TransactionPath ([string]$case.apply.transactionPath) `
                                -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
                                -ConfirmPurge `
                                -FixturePolicyPath ([string]$case.policyPath) `
                                -FixtureEvidenceRoot ([string]$case.evidenceRoot)
                        }
                    Assert-True ($conflictError -match 'commit.*abort') `
                        '非同名 commit+abort 冲突必须返回稳定拒绝原因'
                } finally {
                    if ([IO.File]::Exists($abortPath)) { [IO.File]::Delete($abortPath) }
                }
                $unboundOperationId = [guid]::NewGuid().ToString('N')
                $unboundFreezePath = Join-Path `
                    $case.runDirectory `
                    ('directory-delete-unbound-{0}-freeze.json' -f $unboundOperationId)
                $unboundAbortPath = Join-Path `
                    $case.runDirectory `
                    ('directory-delete-unbound-{0}-abort.json' -f $unboundOperationId)
                $unboundAbortDocument = [pscustomobject][ordered]@{
                    artifactType = 'env-governance.codex-safe-tree-delete-directory-abort-intent'
                    schemaVersion = 2
                    generationId = [string]$commit.generationId
                    operationId = $unboundOperationId
                    directoryPath = [string]$commit.directoryPath
                    relativePath = [string]$commit.relativePath
                    volumeSerialNumber = [string]$commit.volumeSerialNumber
                    fileIndex = [string]$commit.fileIndex
                    state = 'aborted'
                    restoredSecurityDescriptorSddl = [string]$commit.originalSecurityDescriptorSddl
                    freezeIntentPath = $journal.freezePath
                    freezeIntentSha256 = [string]$freezeSnapshot.sha256
                    freezeIntentIdentity = @($freezeSnapshot.identity)
                    createdAtUtc = [datetimeoffset]::UtcNow.ToString('o')
                }
                [IO.File]::WriteAllText(
                    $unboundFreezePath,
                    '{"orphan":true}',
                    [Text.UTF8Encoding]::new($false))
                try {
                    [void](New-CodexHookCapabilityJson `
                        -Path $unboundAbortPath `
                        -Document $unboundAbortDocument `
                        -CapabilityRoot $case.runDirectory `
                        -AllowedExactPaths @($unboundAbortPath) `
                        -Scope 'safe-delete unbound abort fixture')
                    $unboundAbortError = Assert-Throws `
                        -Message '未绑定 abort 不得掩盖 orphan freeze' `
                        -Action {
                            & $entryPath `
                                -Mode Purge `
                                -TransactionPath ([string]$case.apply.transactionPath) `
                                -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
                                -ConfirmPurge `
                                -FixturePolicyPath ([string]$case.policyPath) `
                                -FixtureEvidenceRoot ([string]$case.evidenceRoot)
                        }
                    Assert-True ($unboundAbortError -match 'abort/freeze journal') `
                        'abort 必须绑定其精确 freeze，不能掩盖同名 orphan freeze'
                } finally {
                    if ([IO.File]::Exists($unboundAbortPath)) { [IO.File]::Delete($unboundAbortPath) }
                    if ([IO.File]::Exists($unboundFreezePath)) { [IO.File]::Delete($unboundFreezePath) }
                }
                $stillPurging = Read-JsonDocument -Path ([string]$case.apply.transactionPath)
                Assert-True ($stillPurging.status -ceq 'purging') 'journal 拒绝不得伪造 purged transaction'
            }
        }
        $purge = Complete-CrashCase -Case $case
        if ($scenario -ceq 'FailFastAfterPending') {
            Assert-True `
                ($purge.recoveredFromCommitJournal -eq $true) `
                'pending crash 后缺失 quarantine 必须仅凭完整 commit journal 收尾'
            Assert-True ($purge.metrics.schemaVersion -eq 1 -and $purge.metrics.phase -ceq 'purge') `
                '缺失 quarantine 的 commit-journal 恢复也必须返回统一 Purge metrics'
        }
        $completed++
    } finally {
        if ($null -ne $case) {
            Remove-TestTree -Path ([string]$case.caseRoot)
        }
    }
}

$adversarialScenarios = 0
$applyCrashCase = $null
try {
    $applyCrashCase = New-ApplyCrashCase
    $applyCrashResult = Invoke-ApplyCrashCaseProcess -Case $applyCrashCase
    Assert-True ($applyCrashResult.exitCode -ne 0) `
        "apply crash fixture 必须非零退出：stdout=$($applyCrashResult.stdout) stderr=$($applyCrashResult.stderr)"
    Assert-True (
        [IO.File]::Exists((Join-Path $applyCrashCase.markerRoot 'after-quarantine-rename.marker'))
    ) 'Apply hard crash 必须命中 rename 后、状态发布前 checkpoint'
    Assert-True (-not [IO.Directory]::Exists([string]$applyCrashCase.targetPath)) `
        'Apply hard crash 后原目标必须保持缺失'
    Assert-True ([IO.Directory]::Exists([string]$applyCrashCase.quarantinePath)) `
        'Apply hard crash 后 quarantine 必须保留'
    $preparedTransaction = Read-JsonDocument -Path ([string]$applyCrashCase.transactionPath)
    Assert-True ($preparedTransaction.status -ceq 'prepared') `
        'Apply hard crash 必须留下 rename 前已发布的 prepared transaction'
    Assert-True (@($preparedTransaction.directoryCommitAnchors).Count -eq 0) `
        'prepared transaction 不得包含 directory commit anchor'
    $applyCrashRecovery = & $entryPath `
        -Mode BatchPurge `
        -TargetPaths @([string]$applyCrashCase.targetPath) `
        -CapabilityRoot ([string]$applyCrashCase.targetPath) `
        -ConfirmApply `
        -ConfirmPurge `
        -FixturePolicyPath ([string]$applyCrashCase.policyPath) `
        -FixtureEvidenceRoot ([string]$applyCrashCase.evidenceRoot)
    Assert-True ($applyCrashRecovery.completed -eq $true) `
        'Apply hard crash 后 BatchPurge 必须完成受管恢复'
    Assert-True ($applyCrashRecovery.recoveredCount -eq 1) `
        'Apply hard crash 后 BatchPurge 必须识别 prepared recovery transaction'
    Assert-True (-not [IO.Directory]::Exists([string]$applyCrashCase.quarantinePath)) `
        'Apply hard crash recovery 必须清理 quarantine'
    $recoveredTransaction = Read-JsonDocument -Path ([string]$applyCrashCase.transactionPath)
    Assert-True ($recoveredTransaction.status -ceq 'purged') `
        'Apply hard crash recovery 必须将 transaction 收尾为 purged'
    $adversarialScenarios++
} finally {
    if ($null -ne $applyCrashCase) {
        Remove-TestTree -Path ([string]$applyCrashCase.caseRoot)
    }
}

$applyRaceRoot = Join-Path `
    'D:\Codex\projects' `
    ('.safe-tree-delete-apply-race-{0}' -f [guid]::NewGuid().ToString('N'))
try {
    $applyRaceTarget = Join-Path $applyRaceRoot '.codex'
    $applyRaceEvidenceRoot = Join-Path $applyRaceRoot 'evidence'
    $applyRacePolicyPath = Join-Path $applyRaceRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory($applyRaceTarget)
    $applyRacePolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @([pscustomobject][ordered]@{
            id = 'apply-race-fixture'
            capabilityRoot = $applyRaceTarget
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'empty-project-state'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $applyRacePolicyPath,
        ($applyRacePolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $applyRacePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $applyRaceTarget `
        -CapabilityRoot $applyRaceTarget `
        -FixturePolicyPath $applyRacePolicyPath `
        -FixtureEvidenceRoot $applyRaceEvidenceRoot
    $applyRaceTransactionPath = Join-Path `
        (Split-Path -Parent ([string]$applyRacePlan.planPath)) `
        'transaction.json'
    $applyRaceError = Assert-Throws `
        -Message '并发 Apply 交错必须拒绝第二个过期申请' `
        -Action {
            Invoke-CodexSafeTreeDeleteQuarantine `
                -PlanPath ([string]$applyRacePlan.planPath) `
                -ApprovedPlanSha256 ([string]$applyRacePlan.planSha256) `
                -PolicyPath $applyRacePolicyPath `
                -EvidenceRoot $applyRaceEvidenceRoot `
                -BeforeQuarantineMutexForTest {
                    param($TargetPath, $QuarantinePath)
                    [void](Invoke-CodexSafeTreeDeleteQuarantine `
                        -PlanPath ([string]$applyRacePlan.planPath) `
                        -ApprovedPlanSha256 ([string]$applyRacePlan.planSha256) `
                        -PolicyPath $applyRacePolicyPath `
                        -EvidenceRoot $applyRaceEvidenceRoot)
                }
        }
    Assert-True ($applyRaceError -match 'quarantine target 已存在') `
        '并发 Apply 的过期申请必须在受锁复验时拒绝'
    $applyRaceTransaction = Read-JsonDocument -Path $applyRaceTransactionPath
    Assert-True ($applyRaceTransaction.status -ceq 'quarantined') `
        '并发 Apply 不得将已隔离 transaction 降级为 prepared'
    $applyRaceTransactionSnapshot = Get-TransactionSnapshot `
        -TransactionPath $applyRaceTransactionPath
    $applyRacePurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath $applyRaceTransactionPath `
        -ApprovedTransactionSha256 ([string]$applyRaceTransactionSnapshot.sha256) `
        -PolicyPath $applyRacePolicyPath `
        -EvidenceRoot $applyRaceEvidenceRoot
    Assert-True ($applyRacePurge.purged -eq $true) `
        '并发 Apply 后的已隔离 transaction 必须仍可正常 Purge'
    $adversarialScenarios++
} finally {
    Remove-TestTree -Path $applyRaceRoot
}

$purgeRaceCase = $null
try {
    $purgeRaceCase = New-CrashCase -Scenario 'PurgeRace'
    $purgeRaceTransactionSnapshot = Get-TransactionSnapshot `
        -TransactionPath ([string]$purgeRaceCase.apply.transactionPath)
    $purgeRaceError = Assert-Throws `
        -Message '并发 Purge 交错必须拒绝过期 transaction capability' `
        -Action {
            Invoke-CodexSafeTreeDeletePurge `
                -TransactionPath ([string]$purgeRaceCase.apply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$purgeRaceTransactionSnapshot.sha256) `
                -PolicyPath ([string]$purgeRaceCase.policyPath) `
                -EvidenceRoot ([string]$purgeRaceCase.evidenceRoot) `
                -BeforePurgeMutexForTest {
                    param($TargetPath)
                    [void](Invoke-CodexSafeTreeDeletePurge `
                        -TransactionPath ([string]$purgeRaceCase.apply.transactionPath) `
                        -ApprovedTransactionSha256 ([string]$purgeRaceTransactionSnapshot.sha256) `
                        -PolicyPath ([string]$purgeRaceCase.policyPath) `
                        -EvidenceRoot ([string]$purgeRaceCase.evidenceRoot))
                }
        }
    Assert-True ($purgeRaceError -match 'SHA-256') `
        '并发 Purge 的过期 capability 必须在持锁重读时拒绝'
    $purgeRaceTransaction = Read-JsonDocument -Path ([string]$purgeRaceCase.apply.transactionPath)
    Assert-True ($purgeRaceTransaction.status -ceq 'purged') `
        '并发 Purge 不得把已完成 transaction 回退为 purging'
    Assert-True (@($purgeRaceTransaction.directoryCommitAnchors).Count -ge 1) `
        '并发 Purge 不得覆盖已完成 transaction 的 commit anchors'
    Assert-True (-not [IO.Directory]::Exists([string]$purgeRaceCase.apply.quarantinePath)) `
        '并发 Purge 完成后 quarantine 必须保持缺失'
    $adversarialScenarios++
} finally {
    if ($null -ne $purgeRaceCase) {
        Remove-TestTree -Path ([string]$purgeRaceCase.caseRoot)
    }
}

$orphanCommitCase = $null
try {
    $orphanCommitCase = New-CrashCase -Scenario 'UnanchoredCommit'
    $orphanCommitPath = Join-Path `
        $orphanCommitCase.runDirectory `
        ('directory-delete-orphan-{0}-commit.json' -f ([guid]::NewGuid().ToString('N')))
    $orphanTransactionSnapshot = Get-TransactionSnapshot `
        -TransactionPath ([string]$orphanCommitCase.apply.transactionPath)
    $orphanCommitError = Assert-Throws `
        -Message '普通 Purge 必须拒绝未锚定 commit journal' `
        -Action {
            Invoke-CodexSafeTreeDeletePurge `
                -TransactionPath ([string]$orphanCommitCase.apply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$orphanTransactionSnapshot.sha256) `
                -PolicyPath ([string]$orphanCommitCase.policyPath) `
                -EvidenceRoot ([string]$orphanCommitCase.evidenceRoot) `
                -BeforeDirectoryTreeDeleteForTest {
                    param($QuarantinePath)
                    [IO.File]::WriteAllText(
                        $orphanCommitPath,
                        '{"artifactType":"unanchored-fixture"}',
                        [Text.UTF8Encoding]::new($false))
                }
        }
    Assert-True ($orphanCommitError -match '未被 transaction 锚定') `
        '普通 Purge 必须在 transaction 收尾前拒绝任意未锚定 commit journal'
    Assert-True (-not [IO.Directory]::Exists([string]$orphanCommitCase.apply.quarantinePath)) `
        '未锚定 commit 拒绝必须发生在已删除 quarantine 后的收尾门禁'
    $orphanTransaction = Read-JsonDocument -Path ([string]$orphanCommitCase.apply.transactionPath)
    Assert-True ($orphanTransaction.status -ceq 'purging') `
        '未锚定 commit 拒绝不得伪造 purged transaction'
    $adversarialScenarios++
} finally {
    if ($null -ne $orphanCommitCase) {
        Remove-TestTree -Path ([string]$orphanCommitCase.caseRoot)
    }
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteCrashSafety'
    scenarios = $completed + $adversarialScenarios
}
