[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$crashFixturePath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteRestoreCrashFixture.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f [guid]::NewGuid().ToString('N'))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'

. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action | Out-Null } catch { return $_.Exception.Message }
    throw $Message
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete Restore test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete Restore test cleanup'
}

function Get-FileSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    Get-CodexHookCapabilityFileSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete Restore test file'
}

function Get-OperationFileState {
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $RunDirectory -File -Force | Sort-Object -Property Name)) {
        $snapshot = Get-FileSnapshot -Path $file.FullName
        $state.Add([pscustomobject][ordered]@{
            name = [string]$file.Name
            sha256 = [string]$snapshot.sha256
            identity = @($snapshot.identity)
        })
    }
    return @($state)
}

function Assert-OperationFileStateEqual {
    param(
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][object[]]$Actual,
        [Parameter(Mandatory)][string]$Message
    )
    Assert-True `
        (($Expected | ConvertTo-Json -Depth 8 -Compress) -ceq
            ($Actual | ConvertTo-Json -Depth 8 -Compress)) `
        $Message
}

function New-RestoreCase {
    param([Parameter(Mandatory)][string]$Name)

    $targetPath = Join-Path $fixtureRoot $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $targetPath 'nested'))
    [IO.File]::WriteAllText(
        (Join-Path $targetPath 'root.txt'),
        'restore-root',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $targetPath 'nested\child.txt'),
        'restore-child',
        [Text.UTF8Encoding]::new($false))
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    [pscustomobject][ordered]@{
        targetPath = $targetPath
        plan = $plan
        apply = $apply
        runDirectory = Split-Path -Parent ([string]$apply.transactionPath)
    }
}

function Set-TransactionStatus {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][ValidateSet('prepared', 'quarantined', 'purging')][string]$Status
    )
    $transaction = Get-Content -Raw -LiteralPath $TransactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $transaction.status = $Status
    $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
        'o',
        [Globalization.CultureInfo]::InvariantCulture)
    [IO.File]::WriteAllText(
        $TransactionPath,
        ($transaction | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    return (Get-FileSnapshot -Path $TransactionPath).sha256
}

function Invoke-Restore {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256
    )
    & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$Case.apply.transactionPath) `
        -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
        -ConfirmRestore `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
}

function Start-RestoreCrash {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)]
        [ValidateSet('after-intent', 'after-rename', 'after-target-verification', 'after-complete-journal')]
        [string]$Scenario
    )

    $markerPath = Join-Path $fixtureRoot ("$($Case.runDirectory | Split-Path -Leaf)-$Scenario.marker")
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $crashFixturePath,
            '-TransactionPath', [string]$Case.apply.transactionPath,
            '-ApprovedTransactionSha256', [string]$Case.apply.transactionSha256,
            '-FixturePolicyPath', $policyPath,
            '-FixtureEvidenceRoot', $evidenceRoot,
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
}

function Start-ConcurrentRestoreProcess {
    param([Parameter(Mandatory)][object]$Case)

    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $entryPath,
            '-Mode', 'Restore',
            '-TransactionPath', [string]$Case.apply.transactionPath,
            '-ApprovedTransactionSha256', [string]$Case.apply.transactionSha256,
            '-ConfirmRestore',
            '-FixturePolicyPath', $policyPath,
            '-FixtureEvidenceRoot', $evidenceRoot)) {
        [void]$processInfo.ArgumentList.Add($argument)
    }
    return [Diagnostics.Process]::Start($processInfo)
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @([pscustomobject][ordered]@{
            id = 'restore-fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            deniedExactPaths = @($evidenceRoot)
        })
    }
    $policyBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        ($policy | ConvertTo-Json -Depth 16))
    [IO.File]::WriteAllBytes($policyPath, $policyBytes)

    $confirmedCase = New-RestoreCase -Name 'confirmed'
    $runBeforeRefusal = @(Get-OperationFileState -RunDirectory $confirmedCase.runDirectory)
    $unconfirmed = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$confirmedCase.apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$confirmedCase.apply.transactionSha256) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($unconfirmed.refusalReason -ceq 'confirm-restore-required') `
        'Restore 缺少 ConfirmRestore 必须结构化拒绝'
    Assert-OperationFileStateEqual `
        -Expected $runBeforeRefusal `
        -Actual @(Get-OperationFileState -RunDirectory $confirmedCase.runDirectory) `
        -Message 'Restore 确认拒绝必须零写入'
    $missingReferenceError = Assert-Throws -Message 'Restore 缺少 transaction 引用必须拒绝' -Action {
        & $entryPath -Mode Restore -ConfirmRestore `
            -ApprovedTransactionSha256 ([string]$confirmedCase.apply.transactionSha256) `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($missingReferenceError -match 'TransactionPath') `
        'Restore 缺少 transaction 引用必须给出稳定原因'
    $missingShaError = Assert-Throws -Message 'Restore 缺少 transaction SHA 必须拒绝' -Action {
        & $entryPath -Mode Restore -ConfirmRestore `
            -TransactionPath ([string]$confirmedCase.apply.transactionPath) `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($missingShaError -match 'ApprovedTransactionSha256') `
        'Restore 缺少 transaction SHA 必须给出稳定原因'
    $wrongShaError = Assert-Throws -Message 'Restore 错误 transaction SHA 必须拒绝' -Action {
        Invoke-Restore -Case $confirmedCase -ApprovedTransactionSha256 ('0' * 64)
    }
    Assert-True ($wrongShaError -match 'SHA-256') 'Restore transaction SHA 漂移必须失败闭锁'
    Assert-OperationFileStateEqual `
        -Expected $runBeforeRefusal `
        -Actual @(Get-OperationFileState -RunDirectory $confirmedCase.runDirectory) `
        -Message 'Restore 参数或 SHA 拒绝必须保持 operation bytes 与 identity 不变'

    $restored = Invoke-Restore `
        -Case $confirmedCase `
        -ApprovedTransactionSha256 ([string]$confirmedCase.apply.transactionSha256)
    Assert-True ($restored.restored -eq $true -and -not $restored.alreadyRestored) `
        'quarantined transaction 必须可 Restore'
    Assert-True (-not $restored.logicalCompletion -and -not $restored.namespaceAbsent) `
        'Restore 成功不得冒充 logical deletion'
    $expectedLogicalBytes = [Text.Encoding]::UTF8.GetByteCount('restore-root') +
        [Text.Encoding]::UTF8.GetByteCount('restore-child')
    Assert-True ($restored.metrics.logicalBytes -eq $expectedLogicalBytes) `
        'Restore 重复全树复验只可计一次 logical bytes'
    Assert-True ([IO.Directory]::Exists($confirmedCase.targetPath) -and
        -not [IO.Directory]::Exists([string]$confirmedCase.apply.quarantinePath)) `
        'Restore 必须完成同父 namespace rename'
    $journalKinds = @('intent', 'renamed', 'verified', 'complete')
    $journalSnapshots = [ordered]@{}
    foreach ($kind in $journalKinds) {
        $journalPath = Join-Path $confirmedCase.runDirectory "restore-$kind.json"
        Assert-True ([IO.File]::Exists($journalPath)) "Restore 必须发布 $kind create-only journal"
        $journalSnapshots[$kind] = Get-FileSnapshot -Path $journalPath
    }
    $completeDocument = Get-Content -Raw -LiteralPath $journalSnapshots.complete.path |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    foreach ($binding in @(
            [pscustomobject]@{ prefix = 'intent'; kind = 'intent' },
            [pscustomobject]@{ prefix = 'rename'; kind = 'renamed' },
            [pscustomobject]@{ prefix = 'verification'; kind = 'verified' })) {
        $pathName = "$($binding.prefix)Path"
        $shaName = "$($binding.prefix)Sha256"
        $identityName = "$($binding.prefix)Identity"
        $expectedJournal = $journalSnapshots[$binding.kind]
        Assert-True ([string]$completeDocument.$pathName -ceq [string]$expectedJournal.path) `
            "complete 必须精确绑定 $($binding.prefix) path"
        Assert-True ([string]$completeDocument.$shaName -ceq [string]$expectedJournal.sha256) `
            "complete 必须精确绑定 $($binding.prefix) SHA-256"
        Assert-True (Test-CodexHookDirectoryTreeIdentityEqual `
            -Expected @($completeDocument.$identityName) -Actual @($expectedJournal.identity)) `
            "complete 必须精确绑定 $($binding.prefix) file identity"
    }
    $replay = Invoke-Restore -Case $confirmedCase -ApprovedTransactionSha256 ([string]$restored.transactionSha256)
    Assert-True ($replay.restored -eq $true -and $replay.alreadyRestored -eq $true) `
        'Restore terminal replay 必须幂等'
    foreach ($kind in $journalKinds) {
        $afterReplay = Get-FileSnapshot -Path (Join-Path $confirmedCase.runDirectory "restore-$kind.json")
        Assert-True ($afterReplay.sha256 -ceq $journalSnapshots[$kind].sha256 -and
            (Test-CodexHookDirectoryTreeIdentityEqual `
                -Expected @($journalSnapshots[$kind].identity) -Actual @($afterReplay.identity))) `
            "Restore replay 不得重写 $kind create-only journal"
    }

    $preparedCase = New-RestoreCase -Name 'prepared'
    $preparedSha = Set-TransactionStatus `
        -TransactionPath $preparedCase.apply.transactionPath `
        -Status prepared
    $preparedRestore = Invoke-Restore -Case $preparedCase -ApprovedTransactionSha256 $preparedSha
    Assert-True ($preparedRestore.restored -eq $true) `
        'prepared + target missing + quarantine present + no commit anchors 必须可 Restore'

    $purgingCase = New-RestoreCase -Name 'purging'
    $purgingSha = Set-TransactionStatus `
        -TransactionPath $purgingCase.apply.transactionPath `
        -Status purging
    $purgingError = Assert-Throws -Message 'Restore 必须拒绝 purging transaction' -Action {
        Invoke-Restore -Case $purgingCase -ApprovedTransactionSha256 $purgingSha
    }
    Assert-True ($purgingError -match 'purging') 'purging Restore 必须给出稳定原因'
    Assert-True (-not [IO.Directory]::Exists($purgingCase.targetPath) -and
        [IO.Directory]::Exists([string]$purgingCase.apply.quarantinePath)) `
        'purging Restore 拒绝必须零 namespace 写入'
    $purgingResetSha = Set-TransactionStatus `
        -TransactionPath $purgingCase.apply.transactionPath `
        -Status quarantined
    [void](Invoke-Restore -Case $purgingCase -ApprovedTransactionSha256 $purgingResetSha)

    $conflictCase = New-RestoreCase -Name 'conflict'
    $conflictRunBefore = @(Get-OperationFileState -RunDirectory $conflictCase.runDirectory)
    [IO.File]::WriteAllText($conflictCase.targetPath, 'namespace-conflict', [Text.UTF8Encoding]::new($false))
    $conflictError = Assert-Throws -Message 'Restore 两边同时存在必须拒绝' -Action {
        Invoke-Restore -Case $conflictCase -ApprovedTransactionSha256 $conflictCase.apply.transactionSha256
    }
    Assert-True ($conflictError -match 'existence|冲突|namespace') 'Restore namespace 冲突必须给出稳定原因'
    Assert-OperationFileStateEqual `
        -Expected $conflictRunBefore `
        -Actual @(Get-OperationFileState -RunDirectory $conflictCase.runDirectory) `
        -Message 'Restore namespace 冲突必须在 journal 发布前失败闭锁'
    [IO.File]::Delete($conflictCase.targetPath)
    [void](Invoke-Restore -Case $conflictCase -ApprovedTransactionSha256 $conflictCase.apply.transactionSha256)

    $policyDriftCase = New-RestoreCase -Name 'policy-drift'
    $policyDrift = $policy | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16 -DateKind String
    $policyDrift.entries[0].deniedExactPaths = @($evidenceRoot, (Join-Path $fixtureRoot 'never-authorized'))
    [IO.File]::WriteAllText(
        $policyPath,
        ($policyDrift | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $policyDriftError = Assert-Throws -Message 'Restore policy drift 必须拒绝' -Action {
        Invoke-Restore -Case $policyDriftCase -ApprovedTransactionSha256 $policyDriftCase.apply.transactionSha256
    }
    Assert-True ($policyDriftError -match 'policy.*漂移') 'Restore policy drift 必须给出稳定原因'
    [IO.File]::WriteAllBytes($policyPath, $policyBytes)
    [void](Invoke-Restore -Case $policyDriftCase -ApprovedTransactionSha256 $policyDriftCase.apply.transactionSha256)

    $planDriftCase = New-RestoreCase -Name 'plan-drift'
    $planBytes = [IO.File]::ReadAllBytes([string]$planDriftCase.plan.planPath)
    [IO.File]::AppendAllText([string]$planDriftCase.plan.planPath, ' ', [Text.UTF8Encoding]::new($false))
    $planDriftError = Assert-Throws -Message 'Restore plan drift 必须拒绝' -Action {
        Invoke-Restore -Case $planDriftCase -ApprovedTransactionSha256 $planDriftCase.apply.transactionSha256
    }
    Assert-True ($planDriftError -match 'plan SHA-256') 'Restore plan drift 必须给出稳定原因'
    [IO.File]::WriteAllBytes([string]$planDriftCase.plan.planPath, $planBytes)
    [void](Invoke-Restore -Case $planDriftCase -ApprovedTransactionSha256 $planDriftCase.apply.transactionSha256)

    $treeDriftCase = New-RestoreCase -Name 'tree-drift'
    $quarantineChild = Join-Path ([string]$treeDriftCase.apply.quarantinePath) 'nested\child.txt'
    [IO.File]::WriteAllText($quarantineChild, 'restore-drift', [Text.UTF8Encoding]::new($false))
    $treeDriftError = Assert-Throws -Message 'Restore tree hash drift 必须拒绝' -Action {
        Invoke-Restore -Case $treeDriftCase -ApprovedTransactionSha256 $treeDriftCase.apply.transactionSha256
    }
    Assert-True ($treeDriftError -match 'manifest') 'Restore tree drift 必须给出稳定原因'
    [IO.File]::WriteAllText($quarantineChild, 'restore-child', [Text.UTF8Encoding]::new($false))
    [void](Invoke-Restore -Case $treeDriftCase -ApprovedTransactionSha256 $treeDriftCase.apply.transactionSha256)

    foreach ($scenario in @('after-intent', 'after-rename', 'after-target-verification', 'after-complete-journal')) {
        $crashCase = New-RestoreCase -Name ("crash-$($scenario.Replace('after-', ''))")
        Start-RestoreCrash -Case $crashCase -Scenario $scenario
        $transactionSha = (Get-FileSnapshot -Path $crashCase.apply.transactionPath).sha256
        $crashReplay = Invoke-Restore -Case $crashCase -ApprovedTransactionSha256 $transactionSha
        Assert-True ($crashReplay.restored -eq $true) "Restore crash $scenario 必须可重放"
        Assert-True (@(Get-ChildItem -LiteralPath $crashCase.runDirectory -Filter 'restore-*.json' -File).Count -eq 4) `
            "Restore crash $scenario 只能留下四份一致 journal"
    }

    $renameDriftCase = New-RestoreCase -Name 'rename-crash-tree-drift'
    Start-RestoreCrash -Case $renameDriftCase -Scenario 'after-rename'
    $renamedChild = Join-Path $renameDriftCase.targetPath 'nested\child.txt'
    [IO.File]::WriteAllText($renamedChild, 'post-rename-drift', [Text.UTF8Encoding]::new($false))
    $renameCrashSha = (Get-FileSnapshot -Path $renameDriftCase.apply.transactionPath).sha256
    $renameDriftError = Assert-Throws -Message 'rename 后 crash replay 必须复验完整树' -Action {
        Invoke-Restore -Case $renameDriftCase -ApprovedTransactionSha256 $renameCrashSha
    }
    Assert-True ($renameDriftError -match 'manifest') `
        'rename 后 crash replay 必须因子文件 drift 失败闭锁'
    Assert-True (-not [IO.File]::Exists((Join-Path $renameDriftCase.runDirectory 'restore-renamed.json'))) `
        'rename 后完整树复验失败不得发布 rename 后续 journal'
    [IO.File]::WriteAllText($renamedChild, 'restore-child', [Text.UTF8Encoding]::new($false))
    [void](Invoke-Restore -Case $renameDriftCase -ApprovedTransactionSha256 $renameCrashSha)

    $concurrentCase = New-RestoreCase -Name 'concurrent'
    $processes = @(
        (Start-ConcurrentRestoreProcess -Case $concurrentCase),
        (Start-ConcurrentRestoreProcess -Case $concurrentCase))
    try {
        foreach ($process in $processes) {
            Assert-True ($process.WaitForExit(20000)) 'concurrent Restore 必须在超时内退出'
        }
        $successCount = @($processes | Where-Object ExitCode -eq 0).Count
        Assert-True ($successCount -eq 1) '并发 Restore 必须只有一个首次提交者成功'
    } finally {
        foreach ($process in $processes) {
            if (-not $process.HasExited) { $process.Kill($true) }
            [void]$process.WaitForExit(10000)
            $process.Dispose()
        }
    }
    $concurrentTransactionSha = (Get-FileSnapshot -Path $concurrentCase.apply.transactionPath).sha256
    $concurrentReplay = Invoke-Restore `
        -Case $concurrentCase `
        -ApprovedTransactionSha256 $concurrentTransactionSha
    Assert-True ($concurrentReplay.alreadyRestored -eq $true) `
        'concurrent Restore 之后必须可幂等重放'

    'Safe tree delete Restore tests passed: confirmation/SHA, quarantined/prepared, fail-closed drift, 4 crash phases, full-tree replay, journals, mutex/idempotency.'
} finally {
    Remove-TestTree -Path $fixtureRoot
}
