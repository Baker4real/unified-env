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

function ConvertTo-StatusSemanticJson {
    param([Parameter(Mandatory)][object]$Status)

    $semantic = [ordered]@{}
    foreach ($property in $Status.PSObject.Properties) {
        if ($property.Name -cin @('capturedAtUtc', 'metrics', 'statusSegments')) { continue }
        $semantic[$property.Name] = $property.Value
    }
    return $semantic | ConvertTo-Json -Depth 100 -Compress
}

function Assert-ReceiptReadRejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Read,
        [Parameter(Mandatory)][string]$ExpectedError,
        [Parameter(Mandatory)][string]$Message
    )

    $actualError = $null
    try { & $Read | Out-Null } catch { $actualError = $_.Exception.Message }
    Assert-True ($null -ne $actualError -and $actualError -ceq $ExpectedError) $Message
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $rebuildableTarget = Join-Path $fixtureRoot 'rebuildable-build-output'
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'status-fixture'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @($evidenceRoot)
            },
            [pscustomobject][ordered]@{
                id = 'status-rebuildable-build-output'
                capabilityRoot = $rebuildableTarget
                minimumDescendantDepth = 0
                rootDeletionPurpose = 'rebuildable-build-output'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @()
            }
        )
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
    Assert-True ($targetReparseOperation.lifecycle -ceq 'manual-review' -and
        'restore' -cnotin @($targetReparseOperation.safeActions) -and
        'purge' -cnotin @($targetReparseOperation.safeActions)) `
        'target reparse point 必须分类为 manual-review 且不得建议严格写动作。'
    Assert-True ($targetReparseOperation.namespaceAbsent -eq $false -and
        $targetReparseOperation.targetPresent -eq $true -and
        $targetReparseOperation.targetEntryType -ceq 'reparse-point') `
        'target reparse point 必须报告真实 namespace 状态，不能误报 namespace absent。'
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

    [void][IO.Directory]::CreateDirectory($rebuildableTarget)
    [IO.File]::WriteAllText(
        (Join-Path $rebuildableTarget 'original.txt'),
        'original-build-output',
        [Text.UTF8Encoding]::new($false))
    $rebuildablePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $rebuildableTarget `
        -CapabilityRoot $rebuildableTarget `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $rebuildableApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$rebuildablePlan.planPath) `
        -ApprovedPlanSha256 ([string]$rebuildablePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $rebuildablePurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$rebuildableApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$rebuildableApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    [void][IO.Directory]::CreateDirectory($rebuildableTarget)
    [IO.File]::WriteAllText(
        (Join-Path $rebuildableTarget 'rebuilt.txt'),
        'rebuilt-output',
        [Text.UTF8Encoding]::new($false))
    $rebuiltStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $rebuiltOperation = Get-Operation `
        -Status $rebuiltStatus -TransactionPath $rebuildablePurge.transactionPath
    Assert-True ($rebuiltOperation.lifecycle -ceq 'terminal' -and
        $rebuiltOperation.transactionStatus -ceq 'purged' -and
        $rebuiltOperation.targetPresent -eq $true -and
        $rebuiltOperation.namespaceAbsent -eq $false -and
        $rebuiltOperation.logicalCompletion -eq $true) `
        'rebuildable-build-output 完成删除后重建同名根必须保持 logical terminal。'
    Assert-True ($rebuiltOperation.physicalReclaimStatus -ceq 'unknown' -and
        $rebuiltOperation.deletionOutcome.physicalReclaimStatus -ceq 'unknown') `
        '重建目标不得改变 physical reclaim unknown 语义。'

    $unprovenPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $rebuildableTarget `
        -CapabilityRoot $rebuildableTarget `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $unprovenPlanDocument = Get-Content -Raw -LiteralPath $unprovenPlan.planPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $unprovenTransactionPath = Join-Path `
        (Split-Path -Parent $unprovenPlan.planPath) `
        'transaction.json'
    $unprovenTransaction = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-transaction'
        schemaVersion = 2L
        generationId = [string]$unprovenPlanDocument.generationId
        planPath = [string]$unprovenPlan.planPath
        planSha256 = [string]$unprovenPlan.planSha256
        targetPath = $rebuildableTarget
        quarantinePath = Join-Path `
            (Split-Path -Parent $rebuildableTarget) `
            ('.codex-safe-delete-{0}.quarantine' -f ([string]$unprovenPlanDocument.generationId))
        directoryCommitAnchors = @()
        status = 'purged'
        updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture)
    }
    [IO.File]::WriteAllText(
        $unprovenTransactionPath,
        ($unprovenTransaction | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $unprovenStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $unprovenOperation = Get-Operation `
        -Status $unprovenStatus -TransactionPath $unprovenTransactionPath
    Assert-True ($unprovenOperation.lifecycle -ceq 'manual-review' -and
        $unprovenOperation.transactionStatus -ceq 'purged' -and
        $unprovenOperation.targetPresent -eq $true -and
        $unprovenOperation.logicalCompletion -eq $false) `
        '未完成删除且原 target identity 未变化的 purged 声明必须失败闭锁。'
    Assert-True ($unprovenOperation.physicalReclaimStatus -ceq 'unknown') `
        '未证明完成的 purged 声明也不得推断 physical reclaim。'

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
    Assert-True ($restoreJournalDriftOperation.transactionStatus -ceq 'restored' -and
        [string]$restoreJournalDriftOperation.targetPath -ceq $restoredTarget) `
        '晚期判定失败必须保留已解析的 transaction status 与 target path。'

    $v2PolicyDriftTarget = New-FixtureTarget -Name 'v2-policy-drift'
    $v2PolicyDriftApply = New-FixtureQuarantine -TargetPath $v2PolicyDriftTarget
    $v2PolicyDriftTransaction = Get-Content -Raw -LiteralPath $v2PolicyDriftApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop

    $v1Target = New-FixtureTarget -Name 'v1-policy-drift'
    $v1Apply = New-FixtureQuarantine -TargetPath $v1Target
    $v2Transaction = Get-Content -Raw -LiteralPath $v1Apply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $v1Transaction = [pscustomobject][ordered]@{
        artifactType = [string]$v2Transaction.artifactType
        schemaVersion = 1L
        generationId = [string]$v2Transaction.generationId
        planPath = [string]$v2Transaction.planPath
        planSha256 = [string]$v2Transaction.planSha256
        targetPath = [string]$v2Transaction.targetPath
        quarantinePath = [string]$v2Transaction.quarantinePath
        status = [string]$v2Transaction.status
        updatedAtUtc = [string]$v2Transaction.updatedAtUtc
    }
    [IO.File]::WriteAllText(
        $v1Apply.transactionPath,
        ($v1Transaction | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 16 -Compress),
        [Text.UTF8Encoding]::new($false))
    $beforeV1Status = Get-FixtureState -Root $fixtureRoot
    $v1Status = & $entryPath -Mode Status `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $afterV1Status = Get-FixtureState -Root $fixtureRoot
    $v1Operation = Get-Operation -Status $v1Status -TransactionPath $v1Apply.transactionPath
    $v2PolicyDriftOperation = Get-Operation `
        -Status $v1Status `
        -TransactionPath $v2PolicyDriftApply.transactionPath
    $plannedPolicyDriftOperation = Get-Operation `
        -Status $v1Status `
        -TransactionPath $planned.planPath
    Assert-True ([string]$plannedPolicyDriftOperation.targetPath -ceq $plannedTarget -and
        -not $plannedPolicyDriftOperation.policyCompatible -and
        $plannedPolicyDriftOperation.lifecycle -ceq 'manual-review' -and
        'apply' -cnotin @($plannedPolicyDriftOperation.safeActions)) `
        'policy SHA 漂移后的 plan 必须保留 target，但不得建议严格写路径会拒绝的 Apply。'
    Assert-True ($v2PolicyDriftOperation.transactionSchemaVersion -eq 2L -and
        $v2PolicyDriftOperation.transactionStatus -ceq $v2PolicyDriftTransaction.status -and
        [string]$v2PolicyDriftOperation.targetPath -ceq $v2PolicyDriftTarget -and
        -not $v2PolicyDriftOperation.policyCompatible) `
        'Status 必须把 policy SHA 漂移降级为字段并保留 v2 transaction 的已解析字段。'
    Assert-True ($v1Operation.transactionSchemaVersion -eq 1L -and
        $v1Operation.transactionStatus -ceq $v1Transaction.status -and
        [string]$v1Operation.targetPath -ceq $v1Target -and
        [string]$v1Operation.quarantinePath -ceq $v1Transaction.quarantinePath -and
        [string]$v1Operation.transactionUpdatedAtUtc -ceq $v1Transaction.updatedAtUtc) `
        'Status 必须在 policy SHA 漂移后保留 v1 transaction 的精简观测字段。'
    Assert-True (-not $v1Operation.schemaCompatible -and
        -not $v1Operation.policyCompatible -and
        $v1Operation.lifecycle -ceq 'manual-review') `
        'v1 transaction 必须保持写入不兼容并把 policy SHA 漂移降级为兼容性结论。'
    Assert-True (
        (($beforeV1Status | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($afterV1Status | ConvertTo-Json -Depth 100 -Compress))) `
        'v1 精简观测不得写入 evidence、target、quarantine 或 policy。'

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

    $revokedEvidenceRoot = Join-Path $fixtureRoot 'revoked-evidence'
    $revokedPolicyPath = Join-Path $fixtureRoot 'revoked-policy.json'
    $revokedAllowlistRoot = Join-Path $fixtureRoot 'revoked-allowlist'
    $revokedMinDepthRoot = Join-Path $fixtureRoot 'revoked-mindepth'
    $revokedPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'revoked-allowlist'
                capabilityRoot = $revokedAllowlistRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @()
            },
            [pscustomobject][ordered]@{
                id = 'revoked-mindepth'
                capabilityRoot = $revokedMinDepthRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @()
            }
        )
    }
    [IO.File]::WriteAllText(
        $revokedPolicyPath,
        ($revokedPolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    $revokedV2Target = New-FixtureTarget -Name 'revoked-allowlist\purged-v2'
    $revokedV2Plan = & $entryPath `
        -Mode Plan `
        -TargetPath $revokedV2Target `
        -CapabilityRoot $revokedAllowlistRoot `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedV2Apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$revokedV2Plan.planPath) `
        -ApprovedPlanSha256 ([string]$revokedV2Plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedV2Purge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$revokedV2Apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$revokedV2Apply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot

    $revokedV1Target = New-FixtureTarget -Name 'revoked-allowlist\purged-v1'
    $revokedV1Plan = & $entryPath `
        -Mode Plan `
        -TargetPath $revokedV1Target `
        -CapabilityRoot $revokedAllowlistRoot `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedV1Apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$revokedV1Plan.planPath) `
        -ApprovedPlanSha256 ([string]$revokedV1Plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedV1Purge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$revokedV1Apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$revokedV1Apply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedV1SourceDocument = Get-Content -Raw -LiteralPath ([string]$revokedV1Purge.transactionPath) |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $revokedV1Document = [pscustomobject][ordered]@{
        artifactType = [string]$revokedV1SourceDocument.artifactType
        schemaVersion = 1L
        generationId = [string]$revokedV1SourceDocument.generationId
        planPath = [string]$revokedV1SourceDocument.planPath
        planSha256 = [string]$revokedV1SourceDocument.planSha256
        targetPath = [string]$revokedV1SourceDocument.targetPath
        quarantinePath = [string]$revokedV1SourceDocument.quarantinePath
        status = [string]$revokedV1SourceDocument.status
        updatedAtUtc = [string]$revokedV1SourceDocument.updatedAtUtc
    }
    [IO.File]::WriteAllText(
        [string]$revokedV1Purge.transactionPath,
        ($revokedV1Document | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    $revokedQuarantinedTarget = New-FixtureTarget -Name 'revoked-allowlist\quarantined-v2'
    $revokedQuarantinedPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $revokedQuarantinedTarget `
        -CapabilityRoot $revokedAllowlistRoot `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedQuarantinedApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$revokedQuarantinedPlan.planPath) `
        -ApprovedPlanSha256 ([string]$revokedQuarantinedPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot

    $revokedPlanOnlyTarget = New-FixtureTarget -Name 'revoked-allowlist\plan-only'
    $revokedPlanOnly = & $entryPath `
        -Mode Plan `
        -TargetPath $revokedPlanOnlyTarget `
        -CapabilityRoot $revokedAllowlistRoot `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedPlanOnlyDocument = Get-Content -Raw -LiteralPath ([string]$revokedPlanOnly.planPath) |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $revokedPlanOnlyDocument.expiresAtUtc = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString(
        'o', [Globalization.CultureInfo]::InvariantCulture)
    [IO.File]::WriteAllText(
        [string]$revokedPlanOnly.planPath,
        ($revokedPlanOnlyDocument | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))

    $revokedMinDepthTarget = New-FixtureTarget -Name 'revoked-mindepth\purged-v2'
    $revokedMinDepthPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $revokedMinDepthTarget `
        -CapabilityRoot $revokedMinDepthRoot `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedMinDepthApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$revokedMinDepthPlan.planPath) `
        -ApprovedPlanSha256 ([string]$revokedMinDepthPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedMinDepthPurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$revokedMinDepthApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$revokedMinDepthApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot

    $revokedPolicy.entries = @([pscustomobject][ordered]@{
        id = 'revoked-mindepth'
        capabilityRoot = $revokedMinDepthRoot
        minimumDescendantDepth = 5
        rootDeletionPurpose = 'none'
        allowHardLinks = $false
        allowInternalDirectoryJunctions = $false
        deniedExactPaths = @()
    })
    [IO.File]::WriteAllText(
        $revokedPolicyPath,
        ($revokedPolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    $lockedStream = [IO.FileStream]::new(
        [string]$revokedQuarantinedApply.transactionPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None)
    $revokedLockedStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
    $revokedLockedOperation = Get-Operation `
        -Status $revokedLockedStatus `
        -TransactionPath ([string]$revokedQuarantinedApply.transactionPath)
    Assert-True ($revokedLockedOperation.lifecycle -ceq 'manual-review' -and
        $null -eq $revokedLockedOperation.transactionStatus) `
        '观测路径必须保留既有 handle-bound probe，锁定 transaction 不得解析出部分字段。'
    $lockedStream.Dispose()
    $lockedStream = $null

    $beforeRevokedStatus = Get-FixtureState -Root $fixtureRoot
    $revokedStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
    $afterRevokedStatus = Get-FixtureState -Root $fixtureRoot
    Assert-True (
        (($beforeRevokedStatus | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($afterRevokedStatus | ConvertTo-Json -Depth 100 -Compress))) `
        'policy 拒绝后的 Status 只读观测必须保持 evidence、target 与 policy 零写入。'
    Assert-True (-not $revokedStatus.complete) `
        'policy 拒绝的记录必须继续令全局 complete=false。'

    $revokedV2Document = Get-Content -Raw -LiteralPath ([string]$revokedV2Purge.transactionPath) |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $revokedV2Operation = Get-Operation `
        -Status $revokedStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
    Assert-True ($revokedV2Operation.transactionSchemaVersion -eq 2L -and
        $revokedV2Operation.transactionStatus -ceq [string]$revokedV2Document.status -and
        [string]$revokedV2Operation.targetPath -ceq [string]$revokedV2Document.targetPath -and
        [string]$revokedV2Operation.quarantinePath -ceq [string]$revokedV2Document.quarantinePath -and
        [string]$revokedV2Operation.transactionUpdatedAtUtc -ceq
            [string]$revokedV2Document.updatedAtUtc) `
        'allowlist 拒绝后 v2 purged transaction 必须保留 generation/路径/内容绑定校验后的观测字段。'
    Assert-True ($revokedV2Operation.targetPresent -eq $false -and
        $revokedV2Operation.quarantinePresent -eq $false -and
        $revokedV2Operation.namespaceAbsent -eq $true) `
        'allowlist 拒绝后 v2 purged transaction 必须输出真实 live namespace。'
    Assert-True (-not $revokedV2Operation.schemaCompatible -and
        -not $revokedV2Operation.policyCompatible -and
        $revokedV2Operation.lifecycle -ceq 'manual-review' -and
        'purge' -cnotin @($revokedV2Operation.safeActions) -and
        'restore' -cnotin @($revokedV2Operation.safeActions) -and
        'apply' -cnotin @($revokedV2Operation.safeActions)) `
        'allowlist 拒绝后 v2 transaction 必须标记 schema 不兼容且严格写动作不可用。'
    Assert-True (($revokedV2Operation.errors -join ' ') -match 'allowlist') `
        'allowlist 拒绝原因必须保留在 errors 中。'
    $revokedV2OperationId = Split-Path -Leaf (Split-Path -Parent ([string]$revokedV2Purge.transactionPath))
    Assert-True ($revokedV2OperationId -cin @($revokedStatus.migrationReadiness.blockingRecords)) `
        '未归档的 policy 拒绝记录必须继续 blocking。'

    $revokedV1Operation = Get-Operation `
        -Status $revokedStatus -TransactionPath ([string]$revokedV1Purge.transactionPath)
    Assert-True ($revokedV1Operation.transactionSchemaVersion -eq 1L -and
        $revokedV1Operation.transactionStatus -ceq 'purged' -and
        [string]$revokedV1Operation.targetPath -ceq $revokedV1Target -and
        [string]$revokedV1Operation.quarantinePath -ceq [string]$revokedV1Document.quarantinePath -and
        [string]$revokedV1Operation.transactionUpdatedAtUtc -ceq [string]$revokedV1Document.updatedAtUtc) `
        'allowlist 拒绝后 v1 purged transaction 必须保留精简观测字段。'
    Assert-True ($revokedV1Operation.quarantinePresent -is [bool] -and
        $revokedV1Operation.quarantinePresent -eq $false -and
        $revokedV1Operation.targetPresent -eq $false) `
        'allowlist 拒绝后 v1 purged 记录的 quarantine present 必须是布尔值而非 null。'
    Assert-True (-not $revokedV1Operation.schemaCompatible -and
        $revokedV1Operation.lifecycle -ceq 'manual-review') `
        'v1 transaction 必须保持 schema 不兼容与 manual-review。'

    $revokedQuarantinedOperation = Get-Operation `
        -Status $revokedStatus -TransactionPath ([string]$revokedQuarantinedApply.transactionPath)
    Assert-True ($revokedQuarantinedOperation.transactionSchemaVersion -eq 2L -and
        $revokedQuarantinedOperation.transactionStatus -ceq 'quarantined' -and
        $revokedQuarantinedOperation.quarantinePresent -eq $true -and
        $revokedQuarantinedOperation.targetPresent -eq $false -and
        $revokedQuarantinedOperation.lifecycle -ceq 'manual-review' -and
        'purge' -cnotin @($revokedQuarantinedOperation.safeActions) -and
        'restore' -cnotin @($revokedQuarantinedOperation.safeActions)) `
        '未终结 quarantined 记录不得被误判为 terminal，且不得建议 Purge/Restore。'

    $revokedPlanOnlyOperation = Get-Operation `
        -Status $revokedStatus -TransactionPath ([string]$revokedPlanOnly.planPath)
    Assert-True ($revokedPlanOnlyOperation.lifecycle -ceq 'manual-review' -and
        $null -eq $revokedPlanOnlyOperation.transactionSchemaVersion -and
        $null -eq $revokedPlanOnlyOperation.transactionStatus -and
        $null -eq $revokedPlanOnlyOperation.quarantinePresent -and
        $null -eq $revokedPlanOnlyOperation.targetPath) `
        '无事务过期 plan 不得被扩成可观测 transaction 或 Archive 对象。'

    $revokedMinDepthOperation = Get-Operation `
        -Status $revokedStatus -TransactionPath ([string]$revokedMinDepthPurge.transactionPath)
    Assert-True ($revokedMinDepthOperation.transactionSchemaVersion -eq 2L -and
        $revokedMinDepthOperation.transactionStatus -ceq 'purged' -and
        $revokedMinDepthOperation.quarantinePresent -eq $false -and
        -not $revokedMinDepthOperation.schemaCompatible -and
        $revokedMinDepthOperation.lifecycle -ceq 'manual-review' -and
        (($revokedMinDepthOperation.errors -join ' ') -match '最小后代深度')) `
        '最小深度拒绝后 v2 purged transaction 必须保留观测字段与拒绝原因。'

    $revokedQuarantinedTransactionSha256 = (Get-FileHash `
        -LiteralPath ([string]$revokedQuarantinedApply.transactionPath) `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    $revokedV2TransactionSha256 = (Get-FileHash `
        -LiteralPath ([string]$revokedV2Purge.transactionPath) `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    $beforeRevokedWriteRefusals = Get-FixtureState -Root $fixtureRoot
    $revokedPurgeError = $null
    try {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$revokedQuarantinedApply.transactionPath) `
            -ApprovedTransactionSha256 $revokedQuarantinedTransactionSha256 `
            -ConfirmPurge `
            -FixturePolicyPath $revokedPolicyPath `
            -FixtureEvidenceRoot $revokedEvidenceRoot | Out-Null
    } catch {
        $revokedPurgeError = $_.Exception.Message
    }
    Assert-True ($null -ne $revokedPurgeError) 'policy 拒绝后的 Purge 必须继续抛出拒绝。'
    $revokedRestoreError = $null
    try {
        & $entryPath `
            -Mode Restore `
            -TransactionPath ([string]$revokedV2Purge.transactionPath) `
            -ApprovedTransactionSha256 $revokedV2TransactionSha256 `
            -ConfirmRestore `
            -FixturePolicyPath $revokedPolicyPath `
            -FixtureEvidenceRoot $revokedEvidenceRoot | Out-Null
    } catch {
        $revokedRestoreError = $_.Exception.Message
    }
    Assert-True ($null -ne $revokedRestoreError) 'policy 拒绝后的 Restore 必须继续抛出拒绝。'
    $revokedApplyError = $null
    try {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$revokedPlanOnly.planPath) `
            -ApprovedPlanSha256 ([string]$revokedPlanOnly.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $revokedPolicyPath `
            -FixtureEvidenceRoot $revokedEvidenceRoot | Out-Null
    } catch {
        $revokedApplyError = $_.Exception.Message
    }
    Assert-True ($null -ne $revokedApplyError) 'policy 拒绝后的 Apply 必须继续抛出拒绝。'
    $afterRevokedWriteRefusals = Get-FixtureState -Root $fixtureRoot
    Assert-True (
        (($beforeRevokedWriteRefusals | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($afterRevokedWriteRefusals | ConvertTo-Json -Depth 100 -Compress))) `
        'policy 拒绝后的严格写拒绝必须保持零写入。'

    $revokedQuarantinedArchive = & $entryPath `
        -Mode Archive `
        -TransactionPath ([string]$revokedQuarantinedApply.transactionPath) `
        -ApprovedTransactionSha256 $revokedQuarantinedTransactionSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    Assert-True (-not $revokedQuarantinedArchive.archived -and
        [string]$revokedQuarantinedArchive.refusalReason -ceq 'transaction-status-not-purged') `
        '未终结记录不得进入 Archive 归档。'

    $revokedArchive = & $entryPath `
        -Mode Archive `
        -TransactionPath ([string]$revokedV2Purge.transactionPath) `
        -ApprovedTransactionSha256 $revokedV2TransactionSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $revokedPolicyPath `
        -FixtureEvidenceRoot $revokedEvidenceRoot
    Assert-True ($revokedArchive.archived -eq $true -and -not $revokedArchive.alreadyArchived) `
        'purged 且 quarantine 不存在的 policy 拒绝记录必须能进入现有 Archive 内容认证。'
    $postArchiveStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
    $postArchiveOperation = Get-Operation `
        -Status $postArchiveStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
    Assert-True ($postArchiveOperation.lifecycle -ceq 'terminal' -and
        $postArchiveOperation.journalStatus -ceq 'archived' -and
        $postArchiveOperation.transactionStatus -ceq 'purged') `
        '归档后的 policy 拒绝记录必须按既有 terminal archive 路径分类。'
    $postArchiveQuarantinedOperation = Get-Operation `
        -Status $postArchiveStatus -TransactionPath ([string]$revokedQuarantinedApply.transactionPath)
    Assert-True ($postArchiveQuarantinedOperation.lifecycle -ceq 'manual-review') `
        '归档其他记录不得把未终结 quarantined 记录误判为 terminal。'
    Assert-True (-not [IO.File]::Exists((Join-Path `
        (Split-Path -Parent ([string]$revokedPlanOnly.planPath)) 'terminal-archive.json'))) `
        '无事务过期 plan 不得生成 terminal archive marker。'

    $cacheRoot = Join-Path $fixtureRoot 'status-tree-cache'
    $cacheEvidence = Join-Path $cacheRoot 'evidence'
    $cachePolicyPath = Join-Path $cacheRoot 'policy.json'
    $cacheTarget = Join-Path $cacheRoot 'shared-target'
    [void][IO.Directory]::CreateDirectory($cacheEvidence)
    [void][IO.Directory]::CreateDirectory($cacheTarget)
    $sharedPayload = 'x' * 65536
    [IO.File]::WriteAllText(
        (Join-Path $cacheTarget 'payload-0.txt'),
        $sharedPayload,
        [Text.UTF8Encoding]::new($false))
    $cachePolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'status-tree-cache'
                capabilityRoot = $cacheRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @($cacheEvidence)
            }
        )
    }
    [IO.File]::WriteAllText(
        $cachePolicyPath,
        ($cachePolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $sharedPlan1 = & $entryPath `
        -Mode Plan `
        -TargetPath $cacheTarget `
        -CapabilityRoot $cacheRoot `
        -FixturePolicyPath $cachePolicyPath `
        -FixtureEvidenceRoot $cacheEvidence
    $sharedPlan2 = & $entryPath `
        -Mode Plan `
        -TargetPath $cacheTarget `
        -CapabilityRoot $cacheRoot `
        -FixturePolicyPath $cachePolicyPath `
        -FixtureEvidenceRoot $cacheEvidence
    $previousSegments = $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = '1'
        $sharedStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $cachePolicyPath -FixtureEvidenceRoot $cacheEvidence
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = $previousSegments
    }
    $sharedOp1 = Get-Operation -Status $sharedStatus -TransactionPath ([string]$sharedPlan1.planPath)
    $sharedOp2 = Get-Operation -Status $sharedStatus -TransactionPath ([string]$sharedPlan2.planPath)
    Assert-True ($sharedOp1.lifecycle -ceq 'planned' -and $sharedOp2.lifecycle -ceq 'planned') `
        '同一 live 树的两条 planned 记录必须各自保持 planned。'
    Assert-True ([long]$sharedStatus.metrics.bytesHashed -ge [long]$sharedPayload.Length) `
        'Status 必须至少哈希一次共享 live 树。'
    Assert-True ([long]$sharedStatus.metrics.bytesHashed -lt (2L * [long]$sharedPayload.Length)) `
        '同一 Status 调用不得把同一 live 树再哈希一遍；这不是 Apply/Purge SessionHashCache。'
    Assert-True ([long]$sharedStatus.statusSegments.approvedPlanValidationReuseCount -gt 0L) `
        'canonical approved plan 的 Status fallback 必须复用 C# 已完成的 manifest validation。'

    # #58: real scanner receipts must not suppress fresh transaction plan/policy checks.
    . (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
    $receiptApply = & $entryPath -Mode Apply `
        -PlanPath ([string]$sharedPlan1.planPath) `
        -ApprovedPlanSha256 ([string]$sharedPlan1.planSha256) `
        -ConfirmApply -FixturePolicyPath $cachePolicyPath -FixtureEvidenceRoot $cacheEvidence
    $receiptPlanPath = [string]$sharedPlan1.planPath
    $receiptRun = Get-Item -LiteralPath (Split-Path -Parent $receiptPlanPath) -Force
    $receiptPolicy = Read-CodexSafeTreeDeletePolicy -PolicyPath $cachePolicyPath
    $receiptMetrics = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    $receiptScan = Invoke-CodexSafeTreeDeleteStatusFastScan `
        -RunItems @($receiptRun) -Policy $receiptPolicy -FullEvidenceRoot $cacheEvidence `
        -MetricsState $receiptMetrics -DegreeOfParallelism 1
    $receiptResult = $receiptScan[[string]$receiptRun.FullName]
    $receipt = $receiptResult.ApprovedPlanValidation
    Assert-True ($null -ne $receipt -and $receiptResult.FallbackReason -ceq 'plan-approved') `
        'quarantined v2 fixture 必须取得真实 scanner receipt。'
    $receiptTransactionArguments = @{
        TransactionPath = [string]$receiptApply.transactionPath
        ApprovedTransactionSha256 = [string]$receiptApply.transactionSha256
        PolicyPath = $cachePolicyPath
        EvidenceRoot = $cacheEvidence
        AllowRestoreState = $true
    }
    $receiptControl = Read-CodexSafeTreeDeleteApprovedTransaction @receiptTransactionArguments
    $receiptOptimized = Read-CodexSafeTreeDeleteApprovedTransaction @receiptTransactionArguments `
        -StatusPlanValidation $receipt
    Assert-True ([long]$receiptControl.document.schemaVersion -eq 2L -and
        (($receiptControl | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($receiptOptimized | ConvertTo-Json -Depth 100 -Compress))) `
        '匹配 receipt 的 transaction reader 必须与参考路径返回相同 v2 审批结果。'

    $receiptPlanBytes = [IO.File]::ReadAllBytes($receiptPlanPath)
    try {
        [IO.File]::WriteAllBytes($receiptPlanPath, ($receiptPlanBytes + [byte[]]@(0x20)))
        foreach ($validation in @($null, $receipt)) {
            Assert-ReceiptReadRejected -Read {
                Read-CodexSafeTreeDeleteApprovedTransaction @receiptTransactionArguments `
                    -StatusPlanValidation $validation
            } -ExpectedError 'safe-delete approved plan SHA-256 不匹配。' `
                -Message '扫描后 live plan 改变时，有无 receipt 都必须拒绝 transaction 的旧 SHA。'
        }
    } finally {
        [IO.File]::WriteAllBytes($receiptPlanPath, $receiptPlanBytes)
    }

    $receiptPlanArguments = @{
        PlanPath = $receiptPlanPath
        ApprovedPlanSha256 = [string]$receiptResult.PlanSha256
        PolicyPath = $cachePolicyPath
        EvidenceRoot = $cacheEvidence
        AllowMissingTarget = $true
        AllowExpiredPlan = $true
        AllowPolicyShaDrift = $true
    }
    $otherPlanPath = [string]$sharedPlan2.planPath
    $otherPlanBytes = [IO.File]::ReadAllBytes($otherPlanPath)
    try {
        [IO.File]::WriteAllBytes($otherPlanPath, $receiptPlanBytes)
        Assert-True (-not $receipt.MatchesPlanPath($otherPlanPath) -and
            $receipt.MatchesSnapshot([string]$receiptResult.PlanSha256, [string]$receiptResult.PlanText)) `
            '相同内容与 SHA 不得把 receipt 的路径绑定转移到另一 evidence run。'
        $otherPlanArguments = $receiptPlanArguments.Clone()
        $otherPlanArguments.PlanPath = $otherPlanPath
        $otherControl = Read-CodexSafeTreeDeleteApprovedPlan @otherPlanArguments
        $otherOptimized = Read-CodexSafeTreeDeleteApprovedPlan @otherPlanArguments `
            -StatusPlanValidation $receipt
        Assert-True (($otherControl | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($otherOptimized | ConvertTo-Json -Depth 100 -Compress)) `
            '跨 run receipt 必须回到参考审批，不得改变另一 run 的结果。'
    } finally {
        [IO.File]::WriteAllBytes($otherPlanPath, $otherPlanBytes)
    }

    $changedTextPlan = [string]$receiptResult.PlanText | ConvertFrom-Json -Depth 128 -DateKind String
    $changedTextFile = @($changedTextPlan.treeManifest.entries | Where-Object kind -ceq 'file')[0]
    $changedTextFile.relativePath = 'payload?.txt'
    $changedTextSnapshot = [pscustomobject]@{
        sha256 = [string]$receiptResult.PlanSha256
        text = ($changedTextPlan | ConvertTo-Json -Depth 100)
    }
    Assert-True (-not $receipt.MatchesSnapshot(
        [string]$changedTextSnapshot.sha256, [string]$changedTextSnapshot.text)) `
        '复用原 SHA 字段但改变原文的 snapshot 必须失去 receipt。'
    foreach ($validation in @($null, $receipt)) {
        Assert-ReceiptReadRejected -Read {
            Read-CodexSafeTreeDeleteApprovedPlan @receiptPlanArguments `
                -PreloadedSnapshot $changedTextSnapshot -StatusPlanValidation $validation
        } -ExpectedError 'safe-delete approved plan manifest entry relativePath 含不安全路径段。' `
            -Message '原文不匹配 receipt 时必须重新验证 manifest 并拒绝非法路径。'
    }

    $receiptPolicyBytes = [IO.File]::ReadAllBytes($cachePolicyPath)
    try {
        [IO.File]::WriteAllBytes($cachePolicyPath, ($receiptPolicyBytes + [byte[]]@(0x20)))
        foreach ($validation in @($null, $receipt)) {
            Assert-ReceiptReadRejected -Read {
                Read-CodexSafeTreeDeleteApprovedTransaction @receiptTransactionArguments `
                    -StatusPlanValidation $validation
            } -ExpectedError 'safe-delete policy 自计划生成后已漂移。' `
                -Message 'v2 transaction 不得借 receipt 接受扫描后 policy SHA 漂移。'
        }
    } finally {
        [IO.File]::WriteAllBytes($cachePolicyPath, $receiptPolicyBytes)
    }

    $archivedRunDirectory = Split-Path -Parent ([string]$revokedV2Purge.transactionPath)
    $archivedMarkerPath = Join-Path $archivedRunDirectory 'terminal-archive.json'
    $archivedPlanPath = Join-Path $archivedRunDirectory 'plan.json'
    $intactMarker = [IO.File]::ReadAllText($archivedMarkerPath)
    $intactPlan = [IO.File]::ReadAllBytes($archivedPlanPath)
    $tamperedMarkerDocument = $intactMarker | ConvertFrom-Json -Depth 32 -DateKind String
    $tamperedMarkerDocument.transactionStatus = 'quarantined'
    $tamperedMarker = $tamperedMarkerDocument | ConvertTo-Json -Depth 32
    Assert-True ($tamperedMarker -cne $intactMarker) 'marker 篡改必须改变原文。'
    [IO.File]::WriteAllText($archivedMarkerPath, $tamperedMarker, [Text.UTF8Encoding]::new($false))
    $tamperedMarkerStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
    $tamperedMarkerOperation = Get-Operation `
        -Status $tamperedMarkerStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
    Assert-True ($tamperedMarkerOperation.lifecycle -ceq 'manual-review') `
        '篡改 terminal-archive 内容后不得只凭 marker 文件存在判 terminal。'
    [IO.File]::WriteAllText($archivedMarkerPath, $intactMarker, [Text.UTF8Encoding]::new($false))

    [IO.File]::WriteAllBytes($archivedPlanPath, ($intactPlan + [byte[]]@(0x20)))
    $tamperedPlanStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
    $tamperedPlanOperation = Get-Operation `
        -Status $tamperedPlanStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
    Assert-True ($tamperedPlanOperation.lifecycle -ceq 'manual-review') `
        'plan 字节漂移后 terminal-archive 必须失败闭锁。'
    [IO.File]::WriteAllBytes($archivedPlanPath, $intactPlan)

    $reappearedQuarantine = [string]$revokedV2Operation.quarantinePath
    [void][IO.Directory]::CreateDirectory($reappearedQuarantine)
    $reappearedStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
    $reappearedOperation = Get-Operation `
        -Status $reappearedStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
    Assert-True ($reappearedOperation.lifecycle -ceq 'manual-review') `
        '归档后 quarantine 重新出现必须失败闭锁，不能靠跳过 namespace 核验加速。'
    [IO.Directory]::Delete($reappearedQuarantine)

    $restoredArchiveStatus = & $entryPath -Mode Status `
        -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
    $restoredArchiveOperation = Get-Operation `
        -Status $restoredArchiveStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
    Assert-True ($restoredArchiveOperation.lifecycle -ceq 'terminal' -and
        $restoredArchiveOperation.journalStatus -ceq 'archived') `
        '恢复完好的 terminal-archive 必须重新通过内容认证。'
    Assert-True ($postArchiveQuarantinedOperation.lifecycle -ceq 'manual-review') `
        '#48 未终结 quarantined 观测语义不得被本票改掉。'

    # #49 复核回归（MED-1a/MED-1b）：非 producer 规范形态的 plan 输入必须与参考路径
    # 逐字节一致（fast scan 回退，由 PowerShell 参考语义裁决）。
    $medRoot = Join-Path $fixtureRoot 'med-boundary'
    $medEvidence = Join-Path $medRoot 'evidence'
    $medPolicyPath = Join-Path $medRoot 'policy.json'
    $medTarget = Join-Path $medRoot 'target'
    [void][IO.Directory]::CreateDirectory($medEvidence)
    [void][IO.Directory]::CreateDirectory($medTarget)
    [IO.File]::WriteAllText(
        (Join-Path $medTarget 'payload.txt'),
        'med-boundary',
        [Text.UTF8Encoding]::new($false))
    $medPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'status-med-boundary'
                capabilityRoot = $medRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @()
            }
        )
    }
    [IO.File]::WriteAllText(
        $medPolicyPath,
        ($medPolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $medPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $medTarget `
        -CapabilityRoot $medRoot `
        -FixturePolicyPath $medPolicyPath `
        -FixtureEvidenceRoot $medEvidence
    $medRunDirectory = Split-Path -Parent ([string]$medPlan.planPath)
    $medPlanPath = [string]$medPlan.planPath
    $medPlanDocument = [IO.File]::ReadAllText($medPlanPath) |
        ConvertFrom-Json -Depth 128 -DateKind String

    function Get-MedOperation {
        param([Parameter(Mandatory)][object]$Status, [Parameter(Mandatory)][string]$OperationId)
        $operation = @($Status.operations) | Where-Object operationId -ceq $OperationId
        Assert-True ($null -ne $operation) "MED 边界 slice 必须找到 operation：$OperationId"
        return $operation | ConvertTo-Json -Depth 8 -Compress
    }

    # MED-1a：缺失必需属性 targetPath 且存在 transaction —— 参考路径在拒绝 catch 内
    # 触发 StrictMode PropertyNotFoundException；fast scan 必须回退并逐字节一致。
    $med1aRun = Join-Path $medEvidence '20260823T000001Z-med1a'
    [void][IO.Directory]::CreateDirectory($med1aRun)
    $med1aPlanObject = [ordered]@{}
    foreach ($property in $medPlanDocument.PSObject.Properties) {
        if ($property.Name -ceq 'targetPath') { continue }
        $med1aPlanObject[$property.Name] = $property.Value
    }
    $med1aPlanJson = $med1aPlanObject | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText(
        (Join-Path $med1aRun 'plan.json'), $med1aPlanJson, [Text.UTF8Encoding]::new($false))
    $med1aPlanSha256 = [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($med1aPlanJson)) | ForEach-Object { $_.ToString('x2') }
    $med1aPlanSha256 = [string]::Concat(@($med1aPlanSha256))
    $med1aTransaction = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-transaction'
        schemaVersion = 2
        generationId = [string]$medPlanDocument.generationId
        planPath = (Join-Path $med1aRun 'plan.json')
        planSha256 = $med1aPlanSha256
        targetPath = [string]$medPlan.targetPath
        quarantinePath = Join-Path $medRoot (
            '.codex-safe-delete-{0}.quarantine' -f [string]$medPlanDocument.generationId)
        directoryCommitAnchors = @()
        status = 'purged'
        updatedAtUtc = '2026-08-01T00:00:00.0000000+00:00'
    }
    [IO.File]::WriteAllText(
        (Join-Path $med1aRun 'transaction.json'),
        ($med1aTransaction | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    # MED-1b：属性名大小写变体（summary → Summary）——参考属性集合检查与成员访问
    # 不区分大小写；fast scan 必须回退并逐字节一致（slow 应正常走 approved/planned）。
    $med1bRun = Join-Path $medEvidence '20260823T000002Z-med1b'
    [void][IO.Directory]::CreateDirectory($med1bRun)
    $med1bPlanObject = [ordered]@{}
    foreach ($property in $medPlanDocument.PSObject.Properties) {
        if ($property.Name -ceq 'summary') {
            $med1bPlanObject['Summary'] = $property.Value
        } else {
            $med1bPlanObject[$property.Name] = $property.Value
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $med1bRun 'plan.json'),
        ($med1bPlanObject | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))

    # MED-1c：Windows invalid filename chars（* / ?）必须与参考路径保持逐字节一致。
    $med1cRun = Join-Path $medEvidence '20260823T000003Z-med1c'
    [void][IO.Directory]::CreateDirectory($med1cRun)
    $med1cPlan = $medPlanDocument | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 128 -DateKind String
    $med1cFileEntry = @($med1cPlan.treeManifest.entries | Where-Object kind -ceq 'file') | Select-Object -First 1
    $med1cFileEntry.relativePath = 'payload*.txt'
    [IO.File]::WriteAllText(
        (Join-Path $med1cRun 'plan.json'),
        ($med1cPlan | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))
    $med1fRun = Join-Path $medEvidence '20260823T000006Z-med1f'
    [void][IO.Directory]::CreateDirectory($med1fRun)
    $med1cFileEntry.relativePath = 'payload?.txt'
    [IO.File]::WriteAllText(
        (Join-Path $med1fRun 'plan.json'),
        ($med1cPlan | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))

    # MED-1d：manifest 嵌套属性名大小写变体必须回退到参考路径。
    $med1dRun = Join-Path $medEvidence '20260823T000004Z-med1d'
    [void][IO.Directory]::CreateDirectory($med1dRun)
    $med1dPlan = $medPlanDocument | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 128 -DateKind String
    $med1dManifestObject = [ordered]@{}
    foreach ($property in $med1dPlan.treeManifest.PSObject.Properties) {
        if ($property.Name -ceq 'entries') {
            $med1dManifestObject['Entries'] = $property.Value
        } else {
            $med1dManifestObject[$property.Name] = $property.Value
        }
    }
    $med1dPlan.treeManifest = [pscustomobject]$med1dManifestObject
    [IO.File]::WriteAllText(
        (Join-Path $med1dRun 'plan.json'),
        ($med1dPlan | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))

    # MED-1e：manifest entry 嵌套属性名大小写变体必须回退到参考路径。
    $med1eRun = Join-Path $medEvidence '20260823T000005Z-med1e'
    [void][IO.Directory]::CreateDirectory($med1eRun)
    $med1ePlan = $medPlanDocument | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 128 -DateKind String
    $med1eEntry = @($med1ePlan.treeManifest.entries | Where-Object kind -ceq 'file') | Select-Object -First 1
    $med1eEntryObject = [ordered]@{}
    foreach ($property in $med1eEntry.PSObject.Properties) {
        if ($property.Name -ceq 'relativePath') {
            $med1eEntryObject['RelativePath'] = $property.Value
        } else {
            $med1eEntryObject[$property.Name] = $property.Value
        }
    }
    $med1eEntries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($med1ePlan.treeManifest.entries)) {
        if ([string]$entry.relativePath -ceq [string]$med1eEntry.relativePath -and
            [string]$entry.kind -ceq 'file') {
            $med1eEntries.Add([pscustomobject]$med1eEntryObject)
        } else {
            $med1eEntries.Add($entry)
        }
    }
    $med1ePlan.treeManifest.entries = $med1eEntries.ToArray()
    [IO.File]::WriteAllText(
        (Join-Path $med1eRun 'plan.json'),
        ($med1ePlan | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))

    $previousFastScan = $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN
    $medFastStatus = $null
    $medSlowStatus = $null
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '1'
        $medFastStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $medPolicyPath -FixtureEvidenceRoot $medEvidence
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '0'
        $medSlowStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $medPolicyPath -FixtureEvidenceRoot $medEvidence
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = $previousFastScan
    }
    $med1aFast = Get-MedOperation -Status $medFastStatus -OperationId '20260823T000001Z-med1a'
    $med1aSlow = Get-MedOperation -Status $medSlowStatus -OperationId '20260823T000001Z-med1a'
    Assert-True ($med1aFast -ceq $med1aSlow) `
        'MED-1a（缺失必需属性）fast scan 必须与参考路径逐字节一致。'
    Assert-True (@((Get-MedOperation -Status $medSlowStatus -OperationId '20260823T000001Z-med1a' | ConvertFrom-Json).errors)[0] -cmatch 'targetPath') `
        'MED-1a 参考路径必须以 StrictMode PropertyNotFound 语义记录错误。'
    $med1bFast = Get-MedOperation -Status $medFastStatus -OperationId '20260823T000002Z-med1b'
    $med1bSlow = Get-MedOperation -Status $medSlowStatus -OperationId '20260823T000002Z-med1b'
    Assert-True ($med1bFast -ceq $med1bSlow) `
        'MED-1b（属性名大小写变体）fast scan 必须与参考路径逐字节一致。'
    Assert-True (((Get-MedOperation -Status $medSlowStatus -OperationId '20260823T000002Z-med1b' | ConvertFrom-Json).lifecycle) -ceq 'planned') `
        'MED-1b 参考路径必须按大小写不敏感属性检查正常分类为 planned。'
    $med1cFast = Get-MedOperation -Status $medFastStatus -OperationId '20260823T000003Z-med1c'
    $med1cSlow = Get-MedOperation -Status $medSlowStatus -OperationId '20260823T000003Z-med1c'
    Assert-True ($med1cFast -ceq $med1cSlow) `
        'MED-1c（Windows invalid filename chars）fast scan 必须与参考路径逐字节一致。'
    Assert-True (@((Get-MedOperation -Status $medSlowStatus -OperationId '20260823T000003Z-med1c' | ConvertFrom-Json).errors)[0] -cmatch '不安全路径段') `
        'MED-1c 参考路径必须拒绝 * 文件名字符。'
    $med1fFast = Get-MedOperation -Status $medFastStatus -OperationId '20260823T000006Z-med1f'
    $med1fSlow = Get-MedOperation -Status $medSlowStatus -OperationId '20260823T000006Z-med1f'
    Assert-True ($med1fFast -ceq $med1fSlow -and
        @((ConvertFrom-Json $med1fSlow).errors)[0] -cmatch '不安全路径段') `
        'MED-1f fast scan 与参考路径必须一致拒绝 ? 文件名字符。'
    foreach ($operationId in @('20260823T000004Z-med1d', '20260823T000005Z-med1e')) {
        $fastOperation = Get-MedOperation -Status $medFastStatus -OperationId $operationId
        $slowOperation = Get-MedOperation -Status $medSlowStatus -OperationId $operationId
        Assert-True ($fastOperation -ceq $slowOperation) `
            "$operationId 嵌套非 canonical 属性必须与参考路径逐字节一致。"
        $caseVariantOperation = ConvertFrom-Json $slowOperation
        Assert-True ($caseVariantOperation.lifecycle -ceq 'manual-review' -and
            @($caseVariantOperation.errors)[0] -ceq 'safe-delete Status planned tree manifest 漂移。') `
            "$operationId 嵌套大小写变体必须保留参考路径 manifest SHA 漂移语义。"
    }

    Assert-True ((ConvertTo-StatusSemanticJson $medFastStatus) -ceq
        (ConvertTo-StatusSemanticJson $medSlowStatus)) `
        '混合有效和畸形 plan 的完整 Status 语义输出必须 fast/slow 等价。'
    foreach ($statusFixture in @(
            @{ policy = $cachePolicyPath; evidence = $cacheEvidence },
            @{ policy = $revokedPolicyPath; evidence = $revokedEvidenceRoot })) {
        try {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '1'
            $fastStatus = & $entryPath -Mode Status `
                -FixturePolicyPath $statusFixture.policy -FixtureEvidenceRoot $statusFixture.evidence
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '0'
            $slowStatus = & $entryPath -Mode Status `
                -FixturePolicyPath $statusFixture.policy -FixtureEvidenceRoot $statusFixture.evidence
        } finally {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = $previousFastScan
        }
        Assert-True ((ConvertTo-StatusSemanticJson $fastStatus) -ceq
            (ConvertTo-StatusSemanticJson $slowStatus)) `
            'transaction 与 archive/policy 拒绝记录的完整 Status 语义输出必须 fast/slow 等价。'
    }

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteStatus'
        slices = 32
    }
} finally {
    if ($null -ne $lockedStream) { $lockedStream.Dispose() }
    if ($null -ne $reparsePath -and [IO.Directory]::Exists($reparsePath)) {
        [IO.Directory]::Delete($reparsePath)
    }
    Remove-TestTree -Path $fixtureRoot
}
