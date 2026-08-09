[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-status-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$reparsePath = $null
$lockedStream = $null

. $hostSafetyLibraryPath

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete Status test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete Status test cleanup'
}

function Get-FixtureState {
    param([Parameter(Mandatory)][string]$Root)

    return Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Root `
        -CapabilityRoot (Split-Path -Parent $Root) `
        -AllowedExactPaths @($Root) `
        -Name 'safe-delete Status immutability fixture'
}

function New-FixtureTarget {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Payloads = @('payload')
    )

    $target = Join-Path $fixtureRoot $Name
    [void][IO.Directory]::CreateDirectory($target)
    for ($index = 0; $index -lt $Payloads.Count; $index++) {
        [IO.File]::WriteAllText(
            (Join-Path $target ("payload-{0}.txt" -f $index)),
            [string]$Payloads[$index],
            [Text.UTF8Encoding]::new($false))
    }
    return $target
}

function New-FixturePlan {
    param([Parameter(Mandatory)][string]$TargetPath)

    return & $entryPath `
        -Mode Plan `
        -TargetPath $TargetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
}

function New-FixtureQuarantine {
    param([Parameter(Mandatory)][string]$TargetPath)

    $plan = New-FixturePlan -TargetPath $TargetPath
    return & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
}

function Set-FixtureTransactionStatus {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$Status
    )

    $transaction = Get-Content -Raw -LiteralPath $TransactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $transaction.status = $Status
    [IO.File]::WriteAllText(
        $TransactionPath,
        ($transaction | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
}

function Get-Operation {
    param(
        [Parameter(Mandatory)][object]$Status,
        [Parameter(Mandatory)][string]$TransactionPath
    )

    $operationId = Split-Path -Leaf (Split-Path -Parent $TransactionPath)
    $matches = @($Status.operations | Where-Object operationId -ceq $operationId)
    Assert-True ($matches.Count -eq 1) "Status operation $operationId 必须唯一。"
    return $matches[0]
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @([pscustomobject][ordered]@{
            id = 'status-fixture'
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

    $plannedTarget = New-FixtureTarget -Name 'planned'
    $planned = New-FixturePlan -TargetPath $plannedTarget
    $beforeStatus = Get-FixtureState -Root $fixtureRoot
    $status = & $entryPath -Mode Status -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $afterStatus = Get-FixtureState -Root $fixtureRoot
    Assert-True ($status.artifactType -ceq 'env-governance.codex-safe-tree-delete-status') `
        'Status 必须输出稳定 artifactType。'
    Assert-True ($status.schemaVersion -eq 1 -and $status.complete -eq $true) `
        '健康 Status 必须输出完整的 schema 1。'
    Assert-True ($status.operations[0].lifecycle -ceq 'planned') `
        '未 Apply 的 operation 必须分类为 planned。'
    Assert-True (
        (($beforeStatus | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($afterStatus | ConvertTo-Json -Depth 100 -Compress))) `
        'Status 前后 evidence、target 与 policy 的 bytes/identity 必须不变。'

    $invalidRun = Join-Path $evidenceRoot 'zz-invalid-record'
    [void][IO.Directory]::CreateDirectory($invalidRun)
    [IO.File]::WriteAllText(
        (Join-Path $invalidRun 'plan.json'),
        '{ invalid json',
        [Text.UTF8Encoding]::new($false))
    $mixed = & $entryPath -Mode Status -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    Assert-True (-not $mixed.complete -and @($mixed.operations).Count -eq 2) `
        '畸形记录必须隔离且令全局 complete=false。'
    Assert-True (@($mixed.operations | Where-Object lifecycle -ceq 'planned').Count -eq 1) `
        '畸形记录不得隐藏健康 operation。'
    Assert-True (
        (($mixed.operations | ForEach-Object operationId) -join '|') -ceq
            ((@($mixed.operations | ForEach-Object operationId) | Sort-Object) -join '|')) `
        'Status operations 必须确定性排序。'

    $unknownSchemaRun = Join-Path $evidenceRoot 'zz-unknown-schema'
    [void][IO.Directory]::CreateDirectory($unknownSchemaRun)
    [IO.File]::WriteAllText(
        (Join-Path $unknownSchemaRun 'plan.json'),
        '{"schemaVersion":999}',
        [Text.UTF8Encoding]::new($false))
    $unknownSchemaStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $unknownSchemaOperation = @($unknownSchemaStatus.operations |
        Where-Object operationId -ceq 'zz-unknown-schema')
    Assert-True (-not $unknownSchemaStatus.complete -and
        $unknownSchemaOperation.Count -eq 1 -and
        $unknownSchemaOperation[0].lifecycle -ceq 'manual-review' -and
        $unknownSchemaOperation[0].planSchemaVersion -eq 999) `
        '未知 schema 必须逐条隔离并保留已解析的 schemaVersion。'

    $lockedRun = Join-Path $evidenceRoot 'zz-locked-record'
    [void][IO.Directory]::CreateDirectory($lockedRun)
    $lockedPlanPath = Join-Path $lockedRun 'plan.json'
    [IO.File]::WriteAllText($lockedPlanPath, '{}', [Text.UTF8Encoding]::new($false))
    $lockedStream = [IO.FileStream]::new(
        $lockedPlanPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None)
    $lockedStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $lockedOperation = @($lockedStatus.operations | Where-Object operationId -ceq 'zz-locked-record')
    Assert-True (-not $lockedStatus.complete -and
        $lockedOperation.Count -eq 1 -and
        $lockedOperation[0].lifecycle -ceq 'manual-review') `
        '不可访问记录必须逐条隔离且不得隐藏其他 operation。'
    Assert-True ($null -eq $lockedOperation[0].namespaceAbsent) `
        '不可访问记录的 namespace 状态必须保持 unknown。'
    $lockedStream.Dispose()
    $lockedStream = $null

    $recoverableTarget = New-FixtureTarget -Name 'recoverable'
    $recoverableApply = New-FixtureQuarantine -TargetPath $recoverableTarget
    $recoverableStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $recoverableOperation = Get-Operation `
        -Status $recoverableStatus -TransactionPath $recoverableApply.transactionPath
    Assert-True ($recoverableOperation.lifecycle -ceq 'recoverable') `
        '完整 quarantine 必须分类为 recoverable。'

    [IO.File]::WriteAllText($recoverableTarget, 'namespace-conflict', [Text.UTF8Encoding]::new($false))
    $conflictStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $conflictOperation = Get-Operation -Status $conflictStatus -TransactionPath $recoverableApply.transactionPath
    Assert-True ($conflictOperation.lifecycle -ceq 'manual-review') `
        '普通文件占据 target 时必须分类为 manual-review。'
    Assert-True (-not $conflictOperation.namespaceAbsent -and $conflictOperation.targetEntryType -ceq 'file') `
        '普通文件占据 target 时不得误报 namespace absent。'
    [IO.File]::Delete($recoverableTarget)

    $targetReparseDestination = Join-Path $fixtureRoot 'target-reparse-destination'
    [void][IO.Directory]::CreateDirectory($targetReparseDestination)
    [IO.File]::WriteAllText(
        (Join-Path $targetReparseDestination 'outside.txt'),
        'must-not-be-followed',
        [Text.UTF8Encoding]::new($false))
    $reparsePath = $recoverableTarget
    [void](New-Item `
        -ItemType Junction `
        -Path $reparsePath `
        -Target $targetReparseDestination `
        -ErrorAction Stop)
    $targetReparseStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $targetReparseOperation = Get-Operation `
        -Status $targetReparseStatus -TransactionPath $recoverableApply.transactionPath
    Assert-True ($targetReparseOperation.lifecycle -ceq 'manual-review') `
        'target reparse point 必须分类为 manual-review。'
    Assert-True ($null -eq $targetReparseOperation.namespaceAbsent -and
        $targetReparseOperation.targetEntryType -ceq 'unknown') `
        'target reparse point 必须报告 unknown，不能误报 namespace absent。'
    Assert-True (($targetReparseOperation.errors -join ' ') -match 'reparse') `
        'target reparse point 必须输出稳定错误详情。'
    [IO.Directory]::Delete($reparsePath)
    $reparsePath = $null
    Assert-True ([IO.File]::Exists((Join-Path $targetReparseDestination 'outside.txt'))) `
        'Status 与 junction 清理不得触碰 target reparse destination。'

    $partialTarget = New-FixtureTarget -Name 'partial-purge' -Payloads @('keep', 'delete')
    $partialApply = New-FixtureQuarantine -TargetPath $partialTarget
    Set-FixtureTransactionStatus -TransactionPath $partialApply.transactionPath -Status 'purging'
    [IO.File]::Delete((Join-Path $partialApply.quarantinePath 'payload-1.txt'))
    $partialStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $partialOperation = Get-Operation -Status $partialStatus -TransactionPath $partialApply.transactionPath
    Assert-True ($partialOperation.lifecycle -ceq 'purge-resumable') `
        '已认证的 purging 部分删除必须分类为 purge-resumable。'
    Assert-True ('purge' -cin @($partialOperation.safeActions)) `
        'purge-resumable operation 必须允许显式 Purge。'

    $missingTarget = New-FixtureTarget -Name 'missing-quarantine'
    $missingApply = New-FixtureQuarantine -TargetPath $missingTarget
    Set-FixtureTransactionStatus -TransactionPath $missingApply.transactionPath -Status 'purging'
    Remove-TestTree -Path $missingApply.quarantinePath
    $missingStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $missingOperation = Get-Operation -Status $missingStatus -TransactionPath $missingApply.transactionPath
    Assert-True ($missingOperation.lifecycle -cin @('inconsistent', 'manual-review')) `
        'purging 缺少 quarantine 时不得分类为 purge-resumable。'
    Assert-True ('purge' -cnotin @($missingOperation.safeActions)) `
        'purging 缺少 quarantine 时不得建议 Purge。'

    $terminalTarget = New-FixtureTarget -Name 'terminal'
    $terminalApply = New-FixtureQuarantine -TargetPath $terminalTarget
    $terminal = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$terminalApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$terminalApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $terminalStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $terminalOperation = Get-Operation -Status $terminalStatus -TransactionPath $terminal.transactionPath
    Assert-True ($terminalOperation.lifecycle -ceq 'terminal') `
        'purged transaction 的 live namespace 一致时必须分类为 terminal。'
    [IO.File]::WriteAllText($terminalTarget, 'terminal-drift', [Text.UTF8Encoding]::new($false))
    $terminalDriftStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $terminalDriftOperation = Get-Operation `
        -Status $terminalDriftStatus -TransactionPath $terminal.transactionPath
    Assert-True ($terminalDriftOperation.lifecycle -ceq 'manual-review') `
        'purged transaction 出现 live namespace 时必须失败闭锁。'
    [IO.File]::Delete($terminalTarget)

    $restoredTarget = New-FixtureTarget -Name 'restored-terminal'
    $restoredApply = New-FixtureQuarantine -TargetPath $restoredTarget
    $restored = & $entryPath `
        -Mode Restore `
        -TransactionPath ([string]$restoredApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$restoredApply.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $restoredStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $restoredOperation = Get-Operation -Status $restoredStatus -TransactionPath $restored.transactionPath
    Assert-True ($restoredOperation.lifecycle -ceq 'terminal' -and
        $restoredOperation.journalStatus -ceq 'complete' -and
        -not $restoredOperation.logicalCompletion) `
        'restored terminal 必须验证 live tree 与完整 journal，且不得冒充 logical deletion。'
    $restoreCompletePath = Join-Path (Split-Path -Parent $restored.transactionPath) 'restore-complete.json'
    [IO.File]::Delete($restoreCompletePath)
    $restoreJournalDriftStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $restoreJournalDriftOperation = Get-Operation `
        -Status $restoreJournalDriftStatus -TransactionPath $restored.transactionPath
    Assert-True (-not $restoreJournalDriftStatus.complete -and
        $restoreJournalDriftOperation.lifecycle -ceq 'manual-review') `
        'restored terminal 缺少 complete journal 时必须失败闭锁。'

    $outsideRecord = Join-Path $fixtureRoot 'outside-record'
    [void][IO.Directory]::CreateDirectory($outsideRecord)
    [IO.File]::WriteAllText(
        (Join-Path $outsideRecord 'plan.json'),
        '{"mustNotBeRead":true}',
        [Text.UTF8Encoding]::new($false))
    $reparsePath = Join-Path $evidenceRoot 'zz-reparse-record'
    [void](New-Item -ItemType Junction -Path $reparsePath -Target $outsideRecord -ErrorAction Stop)
    $reparseStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $reparseOperation = @($reparseStatus.operations | Where-Object operationId -ceq 'zz-reparse-record')
    Assert-True (-not $reparseStatus.complete -and $reparseOperation.Count -eq 1) `
        'reparse record 必须逐条隔离并令 complete=false。'
    Assert-True ($reparseOperation[0].lifecycle -ceq 'manual-review') `
        'Status 不得跟随 evidence reparse target。'
    [IO.Directory]::Delete($reparsePath)
    $reparsePath = $null
    Assert-True ([IO.File]::Exists((Join-Path $outsideRecord 'plan.json'))) `
        'Status 与 junction 清理不得触碰 reparse target。'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteStatus'
        slices = 12
    }
} finally {
    if ($null -ne $lockedStream) { $lockedStream.Dispose() }
    if ($null -ne $reparsePath -and [IO.Directory]::Exists($reparsePath)) {
        [IO.Directory]::Delete($reparsePath)
    }
    Remove-TestTree -Path $fixtureRoot
}
