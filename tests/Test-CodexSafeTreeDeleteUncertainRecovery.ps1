[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (crash recovery uncertain / #34):
# 1. Get-CodexSafeTreeDeleteInFlightRecovery — freeze-prepared without commit/abort/anchor
# 2. Invoke-CodexSafeTreeDeletePurge — missing quarantine + uncertain must not write purged
# 3. Get-CodexSafeTreeDeleteStatus / Resolve-CodexSafeTreeDeleteStatusOperation — report lists
# 4. tests/Invoke-CodexSafeTreeDeleteCrashFixture.ps1 FailFastAfterFreeze — pending crash seam
# Not tested: SessionHashCache internals, leaf-dispositions uncertain pairing, production leftover Purge

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$safeTreeLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$crashFixturePath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteCrashFixture.ps1'
$evidenceHome = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'uncertainrecovery'
# pwsh resolution: pinned host runtime first (deterministic anchor), then PATH lookup
# (GitHub runners preinstall pwsh), then the running $PSHOME; fail closed when all miss.
$pwshPinPath = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$pwshOnPath = Get-Command pwsh -ErrorAction SilentlyContinue
$pwshPathCandidates = @(
    $pwshPinPath
    if ($null -ne $pwshOnPath) { [string]$pwshOnPath.Source }
    (Join-Path $PSHOME 'pwsh.exe')
)
$pwshPath = $pwshPathCandidates |
    Where-Object { $_ -and [IO.File]::Exists($_) } |
    Select-Object -First 1
if (-not $pwshPath) {
    throw ("无法解析 pwsh 可执行文件，候选全部缺失：pin={0}；Get-Command={1}；PSHOME={2}" -f
        $pwshPinPath,
        $(if ($null -ne $pwshOnPath) { [string]$pwshOnPath.Source } else { '<missing>' }),
        (Join-Path $PSHOME 'pwsh.exe'))
}

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

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete uncertain recovery test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete uncertain recovery test cleanup'
}

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
}

function Get-TransactionSnapshot {
    param([Parameter(Mandatory)][string]$TransactionPath)
    $runDirectory = Split-Path -Parent $TransactionPath
    return Get-CodexHookCapabilityFileSnapshot `
        -Path $TransactionPath `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($TransactionPath) `
        -Name 'safe-delete uncertain recovery transaction snapshot'
}

function New-FreezeJournalDocument {
    param(
        [Parameter(Mandatory)][string]$GenerationId,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$DirectoryPath,
        [string]$RelativePath = '.'
    )

    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-directory-freeze-intent'
        schemaVersion = 2
        generationId = $GenerationId
        operationId = $OperationId
        directoryPath = $DirectoryPath
        relativePath = $RelativePath
        volumeSerialNumber = '00000001'
        fileIndex = '0000000000000001'
        state = 'freeze-prepared'
        originalSecurityDescriptorSddl = 'O:BAG:SYD:(A;;FA;;;BA)'
        requestedFrozenSecurityDescriptorSddl = 'O:BAG:SYD:(D;;WD;;;WD)(A;;FA;;;BA)'
        createdAtUtc = '2026-08-17T00:00:00.0000000+00:00'
    }
}

function Write-FreezeJournal {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][object]$Document
    )

    $path = Join-Path $RunDirectory ('directory-delete-{0}-freeze.json' -f [string]$Document.operationId)
    [void](New-CodexHookCapabilityJson `
        -Path $path `
        -Document $Document `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($path) `
        -Scope 'safe-delete uncertain recovery freeze fixture')
    return $path
}

function Write-CommitJournal {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][object]$FreezeDocument,
        [Parameter(Mandatory)][string]$FreezePath
    )

    $freezeSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $FreezePath `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($FreezePath) `
        -Name 'safe-delete uncertain recovery freeze snapshot'
    $path = $FreezePath -replace '-freeze\.json$', '-commit.json'
    $document = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-directory-commit-intent'
        schemaVersion = 2
        generationId = [string]$FreezeDocument.generationId
        operationId = [string]$FreezeDocument.operationId
        directoryPath = [string]$FreezeDocument.directoryPath
        relativePath = [string]$FreezeDocument.relativePath
        volumeSerialNumber = [string]$FreezeDocument.volumeSerialNumber
        fileIndex = [string]$FreezeDocument.fileIndex
        state = 'commit-authorized'
        originalSecurityDescriptorSddl = [string]$FreezeDocument.originalSecurityDescriptorSddl
        requestedFrozenSecurityDescriptorSddl = [string]$FreezeDocument.requestedFrozenSecurityDescriptorSddl
        appliedFrozenSecurityDescriptorSddl = [string]$FreezeDocument.requestedFrozenSecurityDescriptorSddl
        freezeIntentPath = $FreezePath
        freezeIntentSha256 = [string]$freezeSnapshot.sha256
        freezeIntentIdentity = @($freezeSnapshot.identity)
        createdAtUtc = '2026-08-17T00:00:01.0000000+00:00'
    }
    [void](New-CodexHookCapabilityJson `
        -Path $path `
        -Document $document `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($path) `
        -Scope 'safe-delete uncertain recovery commit fixture')
    return $path
}

[void][IO.Directory]::CreateDirectory($evidenceHome)
$unitRoot = Join-Path $evidenceHome ('unit-{0}' -f [guid]::NewGuid().ToString('N'))
$generationId = [guid]::NewGuid().ToString('D')
try {
    [void][IO.Directory]::CreateDirectory($unitRoot)
    $pendingExistingPath = Join-Path $unitRoot 'pending-existing'
    $pendingMissingPath = Join-Path $unitRoot 'pending-missing'
    $committedMissingPath = Join-Path $unitRoot 'committed-missing'
    $anchoredMissingPath = Join-Path $unitRoot 'anchored-missing'
    $runExisting = Join-Path $unitRoot 'run-existing'
    $runMissing = Join-Path $unitRoot 'run-missing'
    $runCommitted = Join-Path $unitRoot 'run-committed'
    $runAnchored = Join-Path $unitRoot 'run-anchored'
    foreach ($directory in @(
            $pendingExistingPath, $runExisting, $runMissing, $runCommitted, $runAnchored)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $existingOperationId = [guid]::NewGuid().ToString('N')
    [void](Write-FreezeJournal `
        -RunDirectory $runExisting `
        -Document (New-FreezeJournalDocument `
            -GenerationId $generationId `
            -OperationId $existingOperationId `
            -DirectoryPath $pendingExistingPath))
    $existingRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
        -RunDirectory $runExisting `
        -GenerationId $generationId
    Assert-True (@($existingRecovery.pendingFiles).Count -eq 1) `
        'pending 且路径仍在时必须恰好一条 PendingFiles'
    Assert-True ([string]$existingRecovery.pendingFiles[0] -ceq $pendingExistingPath) `
        'pending 且路径仍在时 PendingFiles 必须是 journal 记录的 directoryPath'
    Assert-True (@($existingRecovery.uncertainFiles).Count -eq 0) `
        'pending 且路径仍在时不得列入 UncertainFiles'

    $missingOperationId = [guid]::NewGuid().ToString('N')
    [void](Write-FreezeJournal `
        -RunDirectory $runMissing `
        -Document (New-FreezeJournalDocument `
            -GenerationId $generationId `
            -OperationId $missingOperationId `
            -DirectoryPath $pendingMissingPath))
    $missingRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
        -RunDirectory $runMissing `
        -GenerationId $generationId
    Assert-True (@($missingRecovery.uncertainFiles).Count -eq 1) `
        'pending 且路径不在时必须恰好一条 UncertainFiles'
    Assert-True ([string]$missingRecovery.uncertainFiles[0] -ceq $pendingMissingPath) `
        'pending 且路径不在时 UncertainFiles 必须是 journal 记录的 directoryPath'
    Assert-True (@($missingRecovery.pendingFiles).Count -eq 0) `
        'pending 且路径不在时不得列入 PendingFiles'

    $committedOperationId = [guid]::NewGuid().ToString('N')
    $committedFreeze = New-FreezeJournalDocument `
        -GenerationId $generationId `
        -OperationId $committedOperationId `
        -DirectoryPath $committedMissingPath
    $committedFreezePath = Write-FreezeJournal `
        -RunDirectory $runCommitted `
        -Document $committedFreeze
    [void](Write-CommitJournal `
        -RunDirectory $runCommitted `
        -FreezeDocument $committedFreeze `
        -FreezePath $committedFreezePath)
    $committedRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
        -RunDirectory $runCommitted `
        -GenerationId $generationId
    Assert-True (@($committedRecovery.pendingFiles).Count -eq 0 -and
        @($committedRecovery.uncertainFiles).Count -eq 0) `
        'commit-authorized 且路径不在时不得标成 uncertain 或 pending'

    $anchoredOperationId = [guid]::NewGuid().ToString('N')
    [void](Write-FreezeJournal `
        -RunDirectory $runAnchored `
        -Document (New-FreezeJournalDocument `
            -GenerationId $generationId `
            -OperationId $anchoredOperationId `
            -DirectoryPath $anchoredMissingPath))
    $anchoredRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
        -RunDirectory $runAnchored `
        -GenerationId $generationId `
        -DirectoryCommitAnchors @([pscustomobject][ordered]@{
            operationId = $anchoredOperationId
        })
    Assert-True (@($anchoredRecovery.pendingFiles).Count -eq 0 -and
        @($anchoredRecovery.uncertainFiles).Count -eq 0) `
        'transaction 已锚定的 operation 即使 commit 文件不在也不得标成 uncertain'
} finally {
    Remove-TestTree -Path $unitRoot
}

Write-Output 'unit-recovery-classification: passed'

function New-UncertainCrashCase {
    $caseRoot = Join-Path `
        'D:\Codex\projects' `
        ('.safe-tree-delete-uncertain-{0}' -f [guid]::NewGuid().ToString('N'))
    $targetPath = Join-Path $caseRoot '.codex'
    $evidenceRoot = Join-Path $caseRoot 'evidence'
    $markerRoot = Join-Path $caseRoot 'markers'
    $policyPath = Join-Path $caseRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory($targetPath)
    [void][IO.Directory]::CreateDirectory($markerRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @([pscustomobject][ordered]@{
            id = 'uncertain-recovery-fixture'
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
    try {
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
            caseRoot = $caseRoot
            targetPath = $targetPath
            evidenceRoot = $evidenceRoot
            markerRoot = $markerRoot
            policyPath = $policyPath
            plan = $plan
            apply = $apply
            runDirectory = Split-Path -Parent ([string]$apply.transactionPath)
        }
    } catch {
        Remove-TestTree -Path $caseRoot
        throw
    }
}

function Invoke-UncertainCrashProcess {
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
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $crashFixturePath,
            '-TransactionPath', [string]$Case.apply.transactionPath,
            '-ApprovedTransactionSha256', [string]$Case.apply.transactionSha256,
            '-FixturePolicyPath', [string]$Case.policyPath,
            '-FixtureEvidenceRoot', [string]$Case.evidenceRoot,
            '-MarkerRoot', [string]$Case.markerRoot,
            '-Scenario', 'FailFastAfterFreeze')) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() 'uncertain recovery crash fixture 必须启动'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-True ($process.WaitForExit(20000)) 'uncertain recovery crash fixture 必须在 20 秒内退出'
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

function Get-UncertainCaseFreeze {
    param([Parameter(Mandatory)][object]$Case)

    $freezePaths = @(Get-ChildItem `
        -LiteralPath $Case.runDirectory `
        -Filter 'directory-delete-*-freeze.json' `
        -File)
    Assert-True ($freezePaths.Count -eq 1) 'FailFastAfterFreeze 必须留下唯一 freeze journal'
    $commitPaths = @(Get-ChildItem `
        -LiteralPath $Case.runDirectory `
        -Filter 'directory-delete-*-commit.json' `
        -File)
    Assert-True ($commitPaths.Count -eq 0) 'FailFastAfterFreeze 不得留下 commit journal'
    return Read-JsonDocument -Path $freezePaths[0].FullName
}

function Get-UncertainStatusOperation {
    param([Parameter(Mandatory)][object]$Case)

    $status = Get-CodexSafeTreeDeleteStatus `
        -PolicyPath ([string]$Case.policyPath) `
        -EvidenceRoot ([string]$Case.evidenceRoot)
    $operationId = Split-Path -Leaf $Case.runDirectory
    $matches = @($status.operations | Where-Object operationId -ceq $operationId)
    Assert-True ($matches.Count -eq 1) 'Status 必须报告唯一 crash operation'
    return [pscustomobject][ordered]@{
        status = $status
        operation = $matches[0]
    }
}

function Remove-PendingPathOutOfBand {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OriginalSddl
    )

    Assert-True ([IO.Directory]::Exists($Path)) 'uncertain 集成必须在 pending 路径仍在时删除它'
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($OriginalSddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
    [IO.Directory]::Delete($Path)
    Assert-True (-not [IO.Directory]::Exists($Path)) 'out-of-band 删除后 pending 路径必须消失'
}

$pendingCase = $null
$uncertainCase = $null
$integrationResults = [ordered]@{ pwshSource = $pwshPath }
try {
    $pendingCase = New-UncertainCrashCase
    $pendingCrash = Invoke-UncertainCrashProcess -Case $pendingCase
    Assert-True ($pendingCrash.exitCode -ne 0) `
        "pending crash fixture 必须非零退出：stdout=$($pendingCrash.stdout) stderr=$($pendingCrash.stderr)"
    Assert-True ([IO.File]::Exists((Join-Path $pendingCase.markerRoot 'after-stream-freeze.marker'))) `
        'pending 集成必须命中 FailFastAfterFreeze seam'
    $pendingFreeze = Get-UncertainCaseFreeze -Case $pendingCase
    $pendingPath = [string]$pendingFreeze.directoryPath
    Assert-True ([IO.Directory]::Exists($pendingPath)) 'pending 集成在恢复前必须保留 quarantine'
    $pendingRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
        -RunDirectory $pendingCase.runDirectory `
        -GenerationId ([string]$pendingFreeze.generationId)
    Assert-True (@($pendingRecovery.pendingFiles).Count -eq 1 -and
        [string]$pendingRecovery.pendingFiles[0] -ceq $pendingPath) `
        'crash 后路径仍在时恢复结果必须把该路径列入 PendingFiles'
    Assert-True (@($pendingRecovery.uncertainFiles).Count -eq 0) `
        'crash 后路径仍在时不得列入 UncertainFiles'
    $pendingStatus = Get-UncertainStatusOperation -Case $pendingCase
    Assert-True (@($pendingStatus.operation.pendingFiles).Count -eq 1 -and
        [string]$pendingStatus.operation.pendingFiles[0] -ceq $pendingPath) `
        'Status 必须输出 PendingFiles'
    Assert-True (@($pendingStatus.operation.uncertainFiles).Count -eq 0) `
        'Status 在 pending 仍在时 UncertainFiles 必须为空'
    Assert-True ($pendingStatus.operation.lifecycle -ceq 'purge-resumable') `
        'pending 且路径仍在时 Status 必须仍是 purge-resumable'
    $integrationResults.pending = [ordered]@{
        pendingPath = $pendingPath
        pendingFiles = @($pendingRecovery.pendingFiles)
        uncertainFiles = @($pendingRecovery.uncertainFiles)
        statusLifecycle = [string]$pendingStatus.operation.lifecycle
        crashExitCode = [int]$pendingCrash.exitCode
    }

    $uncertainCase = New-UncertainCrashCase
    $uncertainCrash = Invoke-UncertainCrashProcess -Case $uncertainCase
    Assert-True ($uncertainCrash.exitCode -ne 0) `
        "uncertain crash fixture 必须非零退出：stdout=$($uncertainCrash.stdout) stderr=$($uncertainCrash.stderr)"
    $uncertainFreeze = Get-UncertainCaseFreeze -Case $uncertainCase
    $uncertainPath = [string]$uncertainFreeze.directoryPath
    Remove-PendingPathOutOfBand `
        -Path $uncertainPath `
        -OriginalSddl ([string]$uncertainFreeze.originalSecurityDescriptorSddl)
    $uncertainRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
        -RunDirectory $uncertainCase.runDirectory `
        -GenerationId ([string]$uncertainFreeze.generationId)
    Assert-True (@($uncertainRecovery.uncertainFiles).Count -eq 1 -and
        [string]$uncertainRecovery.uncertainFiles[0] -ceq $uncertainPath) `
        'crash 后再删 pending 路径时恢复结果必须把该路径列入 UncertainFiles'
    Assert-True (@($uncertainRecovery.pendingFiles).Count -eq 0) `
        'crash 后再删 pending 路径时不得列入 PendingFiles'
    $uncertainStatus = Get-UncertainStatusOperation -Case $uncertainCase
    Assert-True (@($uncertainStatus.operation.uncertainFiles).Count -eq 1 -and
        [string]$uncertainStatus.operation.uncertainFiles[0] -ceq $uncertainPath) `
        'Status 必须输出 UncertainFiles'
    Assert-True ($uncertainStatus.operation.lifecycle -ceq 'manual-review') `
        'uncertain 必须把 Status 打成 manual-review，不得当已删除'
    Assert-True ('purge' -cnotin @($uncertainStatus.operation.safeActions)) `
        'uncertain 不得建议自动 Purge'
    $transactionSnapshot = Get-TransactionSnapshot -TransactionPath ([string]$uncertainCase.apply.transactionPath)
    $uncertainPurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$uncertainCase.apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
        -PolicyPath ([string]$uncertainCase.policyPath) `
        -EvidenceRoot ([string]$uncertainCase.evidenceRoot)
    Assert-True ($uncertainPurge.purged -eq $false) 'uncertain 恢复不得写成 purged'
    Assert-True ([string]$uncertainPurge.refusalReason -ceq 'uncertain-pending-paths') `
        'uncertain Purge 必须返回稳定 refusalReason'
    Assert-True (@($uncertainPurge.uncertainFiles).Count -eq 1 -and
        [string]$uncertainPurge.uncertainFiles[0] -ceq $uncertainPath) `
        'Purge 恢复结果必须输出 UncertainFiles'
    $stillPurging = Read-JsonDocument -Path ([string]$uncertainCase.apply.transactionPath)
    Assert-True ($stillPurging.status -ceq 'purging') 'uncertain 不得把 transaction 收尾为 purged'
    $integrationResults.uncertain = [ordered]@{
        uncertainPath = $uncertainPath
        pendingFiles = @($uncertainRecovery.pendingFiles)
        uncertainFiles = @($uncertainRecovery.uncertainFiles)
        statusLifecycle = [string]$uncertainStatus.operation.lifecycle
        purgePurged = [bool]$uncertainPurge.purged
        purgeRefusalReason = [string]$uncertainPurge.refusalReason
        transactionStatus = [string]$stillPurging.status
        crashExitCode = [int]$uncertainCrash.exitCode
    }
} finally {
    if ($null -ne $pendingCase) { Remove-TestTree -Path ([string]$pendingCase.caseRoot) }
    if ($null -ne $uncertainCase) { Remove-TestTree -Path ([string]$uncertainCase.caseRoot) }
}

$integrationPath = Join-Path $evidenceHome 'integration-results.json'
[IO.File]::WriteAllText(
    $integrationPath,
    ([pscustomobject]$integrationResults | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
Write-Output 'integration-failfast-recovery: passed'
