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
                # 结构规则 3（#84）：嵌套的构建产物根必须被父条目精确 deny。
                deniedExactPaths = @($evidenceRoot, $rebuildableTarget)
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
    $previousTerminalFastScan = $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '1'
        $terminalFastStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '0'
        $terminalSlowStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = $previousTerminalFastScan
    }
    $terminalFastOperation = Get-Operation -Status $terminalFastStatus -TransactionPath $terminal.transactionPath
    $terminalSlowOperation = Get-Operation -Status $terminalSlowStatus -TransactionPath $terminal.transactionPath
    Assert-True (($terminalFastOperation | ConvertTo-Json -Depth 100 -Compress) -ceq
        ($terminalSlowOperation | ConvertTo-Json -Depth 100 -Compress)) `
        'approved purged terminal fast scan 必须与参考路径逐字节一致。'
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
    $previousParallelFallback = $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = '1'
        # 单树去重合同由串行参考路径持有；并行 fallback 按 worker 持有独立树缓存，
        # 共享树至多多哈希 workerCount-1 次（语义输出不受影响，另有并行等价 slice 覆盖）。
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '0'
        $sharedStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $cachePolicyPath -FixtureEvidenceRoot $cacheEvidence
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = $previousSegments
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = $previousParallelFallback
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

    $escapedMarkerDocument = $intactMarker | ConvertFrom-Json -Depth 32 -DateKind String
    $escapedMarkerDocument.planPath = Join-Path $fixtureRoot 'outside-plan.json'
    $escapedMarker = $escapedMarkerDocument | ConvertTo-Json -Depth 32
    try {
        [IO.File]::WriteAllText($archivedMarkerPath, $escapedMarker, [Text.UTF8Encoding]::new($false))
        $previousArchiveFastScan = $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN
        try {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '1'
            $escapedArchiveFastStatus = & $entryPath -Mode Status `
                -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '0'
            $escapedArchiveSlowStatus = & $entryPath -Mode Status `
                -FixturePolicyPath $revokedPolicyPath -FixtureEvidenceRoot $revokedEvidenceRoot
        } finally {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = $previousArchiveFastScan
        }
        $escapedArchiveFastOperation = Get-Operation `
            -Status $escapedArchiveFastStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
        $escapedArchiveSlowOperation = Get-Operation `
            -Status $escapedArchiveSlowStatus -TransactionPath ([string]$revokedV2Purge.transactionPath)
        Assert-True (($escapedArchiveFastOperation | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($escapedArchiveSlowOperation | ConvertTo-Json -Depth 100 -Compress)) `
            'terminal-archive 越界引用 fast scan 必须与参考路径逐字节一致。'
    } finally {
        [IO.File]::WriteAllText($archivedMarkerPath, $intactMarker, [Text.UTF8Encoding]::new($false))
    }

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
    $previousParallelFallback = $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK
    $medFastStatus = $null
    $medSlowStatus = $null
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '1'
        $medFastStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $medPolicyPath -FixtureEvidenceRoot $medEvidence
        # N5 L4：slow 腿同时钉死并行 fallback，保证参考侧是纯串行基线（不依赖 FAST_SCAN=0
        # 对 fallback 输入的间接清空）。
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '0'
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '0'
        $medSlowStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $medPolicyPath -FixtureEvidenceRoot $medEvidence
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = $previousFastScan
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = $previousParallelFallback
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
            "$operationId 嵌套非 canonical 属性必须与参考路径逐字节一致。`nfast=$fastOperation`nslow=$slowOperation"
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
            # N5 L4：slow 腿同时钉死并行 fallback（纯串行基线）。
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '0'
            $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '0'
            $slowStatus = & $entryPath -Mode Status `
                -FixturePolicyPath $statusFixture.policy -FixtureEvidenceRoot $statusFixture.evidence
        } finally {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = $previousFastScan
            $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = $previousParallelFallback
        }
        Assert-True ((ConvertTo-StatusSemanticJson $fastStatus) -ceq
            (ConvertTo-StatusSemanticJson $slowStatus)) `
            'transaction 与 archive/policy 拒绝记录的完整 Status 语义输出必须 fast/slow 等价。'
    }

    # Slice 35（issue #58）：C# 快速树快照必须与 PS 参考路径逐字节等价
    # （嵌套/非 ASCII/排序敏感名/深树/空文件），聚合 metrics 与逐 entry observer 簿记一致。
    $snapRoot = Join-Path $fixtureRoot 'fastpath-snapshot-equiv'
    $snapTree = Join-Path $snapRoot 'tree'
    [void][IO.Directory]::CreateDirectory($snapTree)
    foreach ($snapDir in @('a-b', 'ab', '_a', '-x', '中文 目录', "子'目录",
            'deep\deeper\deepest\nested\leaf', 'empty-dir')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $snapTree $snapDir))
    }
    [IO.File]::WriteAllText((Join-Path $snapTree 'a-b\file one.txt'), 'payload-1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $snapTree 'ab\中文 文件.txt'), '中文内容', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $snapTree '_a\x.bin'), '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $snapTree '中文 目录\a&b.dat'), ('x' * 5000), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $snapTree 'deep\deeper\deepest\nested\leaf\deep.txt'), 'deep', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $snapTree 'root.txt'), 'root', [Text.UTF8Encoding]::new($false))
    $snapRefMetrics = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    $snapRef = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $snapTree -CapabilityRoot $snapRoot -AllowedExactPaths @($snapTree) `
        -MetricsObserver (New-CodexSafeTreeDeleteMetricsObserver -State $snapRefMetrics) `
        -Name 'safe-delete Status fastpath equivalence snapshot'
    $snapFastMetrics = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    $snapFast = Get-CodexSafeTreeDeleteStatusTreeSnapshotFast `
        -Path $snapTree -CapabilityRoot $snapRoot -AllowedExactPaths @($snapTree) `
        -AllowHardLinks:$false -AllowInternalDirectoryJunctions:$false `
        -MetricsState $snapFastMetrics `
        -Name 'safe-delete Status fastpath equivalence snapshot' `
        -AttachLiveManifestSha256
    $snapAttachedSha = [string]$snapFast.statusLiveManifestSha256
    $snapFast.PSObject.Properties.Remove('statusLiveManifestSha256')
    Assert-True (($snapRef | ConvertTo-Json -Depth 100 -Compress) -ceq
        ($snapFast | ConvertTo-Json -Depth 100 -Compress)) `
        'C# 快速树快照必须与 PS 参考快照逐字节等价。'
    Assert-True ($snapAttachedSha -ceq (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $snapRef)) `
        '快速快照附挂的 live manifest SHA 必须与参考计算一致。'
    Assert-True ([long]$snapRefMetrics.entriesScanned -eq [long]$snapFastMetrics.entriesScanned -and
        [long]$snapRefMetrics.logicalBytes -eq [long]$snapFastMetrics.logicalBytes -and
        [long]$snapRefMetrics.bytesHashed -eq [long]$snapFastMetrics.bytesHashed) `
        '快速快照的聚合 metrics 必须与参考路径逐 entry observer 簿记一致。'

    # Slice 36（issue #58）：未授权 reparse point 必须触发类型化回退，最终错误与参考路径一致。
    $reparseEquivRoot = Join-Path $fixtureRoot 'fastpath-reparse-fallback'
    $reparseEquivTree = Join-Path $reparseEquivRoot 'tree'
    $reparseEquivTarget = Join-Path $reparseEquivRoot 'target'
    [void][IO.Directory]::CreateDirectory($reparseEquivTree)
    [void][IO.Directory]::CreateDirectory($reparseEquivTarget)
    [IO.File]::WriteAllText((Join-Path $reparseEquivTarget 'inner.txt'), 'inner', [Text.UTF8Encoding]::new($false))
    $reparseEquivLink = Join-Path $reparseEquivTree 'link'
    try {
        [void](New-Item -ItemType Junction -Path $reparseEquivLink -Target $reparseEquivTarget -ErrorAction Stop)
        $reparseFallbackError = $null
        try {
            [void][CodexSafeTreeDelete.StatusTreeSnapshotScanner]::Scan($reparseEquivTree, $false, $false, $null)
        } catch [CodexSafeTreeDelete.StatusFastPathFallbackException] {
            $reparseFallbackError = $_.Exception.Message
        }
        Assert-True (-not [string]::IsNullOrEmpty($reparseFallbackError)) `
            '未授权 reparse point 必须让 C# 扫描器抛 StatusFastPathFallbackException。'
        $previousTreeFast = $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST
        try {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = '1'
            $reparseFastMessage = $null
            try {
                [void](Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
                    -Path $reparseEquivTree -CapabilityRoot $reparseEquivRoot `
                    -AllowedExactPaths @($reparseEquivTree) `
                    -AllowHardLinks:$false -AllowInternalDirectoryJunctions:$false `
                    -MetricsObserver (New-CodexSafeTreeDeleteMetricsObserver -State (
                        New-CodexSafeTreeDeleteMetricsState -Phase 'status')) `
                    -Name 'safe-delete Status reparse fallback snapshot' `
                    -MetricsState (New-CodexSafeTreeDeleteMetricsState -Phase 'status'))
            } catch { $reparseFastMessage = $_.Exception.Message }
        } finally {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = $previousTreeFast
        }
        $reparseRefMessage = $null
        try {
            [void](Get-CodexHookCapabilityDirectoryTreeSnapshot `
                -Path $reparseEquivTree -CapabilityRoot $reparseEquivRoot `
                -AllowedExactPaths @($reparseEquivTree) `
                -Name 'safe-delete Status reparse fallback snapshot')
        } catch { $reparseRefMessage = $_.Exception.Message }
        Assert-True ($null -ne $reparseFastMessage -and $reparseFastMessage -ceq $reparseRefMessage) `
            '未授权 reparse point 回退后的错误消息必须与 PS 参考路径逐字节一致。'
    } finally {
        if ([IO.Directory]::Exists($reparseEquivLink)) { [IO.Directory]::Delete($reparseEquivLink) }
    }

    # Slice 37（issue #58）：授权内部 junction 快速快照与参考逐字节等价；target root 越界同错误回退。
    $junctionRoot = Join-Path $fixtureRoot 'fastpath-junction'
    $junctionTree = Join-Path $junctionRoot 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $junctionTree 'target-sub\inner'))
    [IO.File]::WriteAllText((Join-Path $junctionTree 'target-sub\inner\j.txt'), 'junction-payload', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $junctionTree 'f.txt'), 'f', [Text.UTF8Encoding]::new($false))
    $junctionLink = Join-Path $junctionTree 'jlink'
    try {
        [void](New-Item -ItemType Junction -Path $junctionLink `
            -Target (Join-Path $junctionTree 'target-sub') -ErrorAction Stop)
        $junctionRef = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $junctionTree -CapabilityRoot $junctionRoot -AllowedExactPaths @($junctionTree) `
            -AllowInternalDirectoryJunctions -InternalDirectoryJunctionTargetRoot $junctionTree `
            -Name 'safe-delete Status junction equivalence snapshot'
        $junctionFast = Get-CodexSafeTreeDeleteStatusTreeSnapshotFast `
            -Path $junctionTree -CapabilityRoot $junctionRoot -AllowedExactPaths @($junctionTree) `
            -AllowHardLinks:$false -AllowInternalDirectoryJunctions:$true `
            -InternalDirectoryJunctionTargetRoot $junctionTree `
            -MetricsState (New-CodexSafeTreeDeleteMetricsState -Phase 'status') `
            -Name 'safe-delete Status junction equivalence snapshot'
        Assert-True (($junctionRef | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($junctionFast | ConvertTo-Json -Depth 100 -Compress)) `
            '授权内部 junction 的快速快照必须与 PS 参考快照逐字节等价。'
        Assert-True (@($junctionFast.entries | Where-Object kind -ceq 'directory-junction').Count -eq 1) `
            '等价快照必须恰好包含一个 junction 条目。'
        $junctionOutOfRootFallback = $null
        try {
            [void][CodexSafeTreeDelete.StatusTreeSnapshotScanner]::Scan(
                $junctionTree, $false, $true, (Join-Path $junctionTree 'sub-none'))
        } catch [CodexSafeTreeDelete.StatusFastPathFallbackException] {
            $junctionOutOfRootFallback = $_.Exception.Message
        }
        Assert-True (-not [string]::IsNullOrEmpty($junctionOutOfRootFallback)) `
            'junction target root 越界必须让 C# 扫描器抛 StatusFastPathFallbackException。'
        $junctionOutFastMessage = $null
        $previousTreeFast = $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST
        try {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = '1'
            try {
                [void](Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
                    -Path $junctionTree -CapabilityRoot $junctionRoot -AllowedExactPaths @($junctionTree) `
                    -AllowHardLinks:$false -AllowInternalDirectoryJunctions:$true `
                    -InternalDirectoryJunctionTargetRoot (Join-Path $junctionTree 'sub-none') `
                    -MetricsObserver (New-CodexSafeTreeDeleteMetricsObserver -State (
                        New-CodexSafeTreeDeleteMetricsState -Phase 'status')) `
                    -Name 'safe-delete Status junction out-of-root snapshot' `
                    -MetricsState (New-CodexSafeTreeDeleteMetricsState -Phase 'status'))
            } catch { $junctionOutFastMessage = $_.Exception.Message }
        } finally {
            $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = $previousTreeFast
        }
        $junctionOutRefMessage = $null
        try {
            [void](Get-CodexHookCapabilityDirectoryTreeSnapshot `
                -Path $junctionTree -CapabilityRoot $junctionRoot -AllowedExactPaths @($junctionTree) `
                -AllowInternalDirectoryJunctions `
                -InternalDirectoryJunctionTargetRoot (Join-Path $junctionTree 'sub-none') `
                -Name 'safe-delete Status junction out-of-root snapshot')
        } catch { $junctionOutRefMessage = $_.Exception.Message }
        Assert-True ($null -ne $junctionOutFastMessage -and
            $junctionOutFastMessage -ceq $junctionOutRefMessage) `
            'junction target root 越界时，缓存封装回退后的错误消息必须与参考路径一致。'
    } finally {
        if ([IO.Directory]::Exists($junctionLink)) { [IO.Directory]::Delete($junctionLink) }
    }

    # Slice 38（issue #58）：plan 文本流式 manifest SHA 与 ConvertFrom/ConvertTo 参考计算等价；
    # 大小写变体与属性重排保持一致；manifest 内非规范数字必须类型化回退且回退后结果等价。
    $shaPlan = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-plan'
        schemaVersion = 1
        treeManifest = [pscustomobject][ordered]@{
            schemaVersion = 2
            rootIdentity = @('5d26df61', '001900000009a9f2')
            entries = @(
                [pscustomobject][ordered]@{
                    relativePath = '.'
                    kind = 'directory'
                    sha256 = $null
                    identity = @('5d26df61', '001900000009a9f2')
                },
                [pscustomobject][ordered]@{
                    relativePath = '中文 目录/a&b.dat'
                    kind = 'file'
                    sha256 = 'a' * 64
                    identity = @('5d26df61', '00070000000700ae')
                }
            )
        }
        summary = 'x'
    }
    $shaPlanText = $shaPlan | ConvertTo-Json -Depth 100 -Compress
    $shaReference = {
        param([string]$Text)
        $shaDocument = $Text | ConvertFrom-Json -Depth 128 -DateKind String
        return Get-CodexSafeTreeDeleteManifestSha256 -Manifest $shaDocument.treeManifest
    }
    $shaBaseline = & $shaReference $shaPlanText
    Assert-True ([CodexSafeTreeDelete.StatusPlanManifestSha256]::ComputeFromPlanText($shaPlanText) -ceq
        $shaBaseline) 'plan 文本流式 manifest SHA 必须与参考计算一致。'
    $shaReorderedPlan = [pscustomobject][ordered]@{
        summary = 'x'
        treeManifest = $shaPlan.treeManifest
        schemaVersion = 1
        artifactType = 'env-governance.codex-safe-tree-delete-plan'
    }
    $shaReorderedText = $shaReorderedPlan | ConvertTo-Json -Depth 100 -Compress
    Assert-True ([CodexSafeTreeDelete.StatusPlanManifestSha256]::ComputeFromPlanText($shaReorderedText) -ceq
        (& $shaReference $shaReorderedText)) '顶层属性重排的 plan 文本必须与参考计算一致。'
    $shaCaseText = $shaPlanText.Replace('"treeManifest"', '"TreeManifest"')
    Assert-True ([CodexSafeTreeDelete.StatusPlanManifestSha256]::ComputeFromPlanText($shaCaseText) -ceq
        (& $shaReference $shaCaseText)) 'treeManifest 键大小写变体必须与参考计算一致。'
    $shaNonCanonicalText = $shaPlanText.Replace('"schemaVersion":2', '"schemaVersion":2.0')
    $shaNonCanonicalFallback = $null
    try {
        [void][CodexSafeTreeDelete.StatusPlanManifestSha256]::ComputeFromPlanText($shaNonCanonicalText)
    } catch [CodexSafeTreeDelete.StatusFastPathFallbackException] {
        $shaNonCanonicalFallback = $_.Exception.Message
    }
    Assert-True (-not [string]::IsNullOrEmpty($shaNonCanonicalFallback)) `
        'manifest 内非规范数字必须让 C# 流式计算抛 StatusFastPathFallbackException。'
    $shaNonCanonicalDocument = $shaNonCanonicalText | ConvertFrom-Json -Depth 128 -DateKind String
    $previousTreeFast = $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = '1'
        $shaWrapped = Get-CodexSafeTreeDeleteStatusCachedPlanManifestSha256 `
            -PlanTreeManifest $shaNonCanonicalDocument.treeManifest `
            -PlanSha256 ('b' * 64) -Cache $null -PlanText $shaNonCanonicalText
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = $previousTreeFast
    }
    Assert-True ($shaWrapped -ceq
        (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $shaNonCanonicalDocument.treeManifest)) `
        '非规范数字回退后，缓存封装返回的 manifest SHA 必须与参考计算一致。'

    # Slice 39（issue #58）：并行 fallback 必须实际接管全部 fallback op，且与串行参考路径语义全等。
    $parRoot = Join-Path $fixtureRoot 'fastpath-parallel'
    $parEvidence = Join-Path $parRoot 'evidence'
    $parPolicyPath = Join-Path $parRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory($parEvidence)
    $parPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'fastpath-parallel'
                capabilityRoot = $parRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @($parEvidence)
            }
        )
    }
    [IO.File]::WriteAllText(
        $parPolicyPath,
        ($parPolicy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    foreach ($parTargetSpec in @(@('target-a', 'alpha'), @('target-b', 'bravo'))) {
        $parTarget = Join-Path $parRoot ([string]$parTargetSpec[0])
        [void][IO.Directory]::CreateDirectory($parTarget)
        [IO.File]::WriteAllText(
            (Join-Path $parTarget 'payload.txt'),
            [string]$parTargetSpec[1],
            [Text.UTF8Encoding]::new($false))
        [void](& $entryPath -Mode Plan -TargetPath $parTarget -CapabilityRoot $parRoot `
            -FixturePolicyPath $parPolicyPath -FixtureEvidenceRoot $parEvidence)
    }
    $parBrokenRun = Join-Path $parEvidence 'zz-broken-plan'
    [void][IO.Directory]::CreateDirectory($parBrokenRun)
    [IO.File]::WriteAllText((Join-Path $parBrokenRun 'plan.json'), '{', [Text.UTF8Encoding]::new($false))
    $previousParallelFallback = $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK
    $previousSegments = $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS
    $previousTreeFast = $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = '1'
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '1'
        $parStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $parPolicyPath -FixtureEvidenceRoot $parEvidence
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '0'
        $parSerialStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $parPolicyPath -FixtureEvidenceRoot $parEvidence
        # N5 L4：TREE_FAST=0 整轮——worker 内树快照与 plan manifest SHA 都走 PS 参考实现，
        # 并行 fallback 仍接管；必须与串行控制输出逐字节等价。
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '1'
        $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = '0'
        $parTreeRefStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $parPolicyPath -FixtureEvidenceRoot $parEvidence
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = $previousParallelFallback
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = $previousSegments
        $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST = $previousTreeFast
    }
    Assert-True ((ConvertTo-StatusSemanticJson $parStatus) -ceq
        (ConvertTo-StatusSemanticJson $parSerialStatus)) `
        '并行 fallback 的完整 Status 语义输出必须与串行参考路径逐字节等价。'
    Assert-True ([long]$parSerialStatus.statusSegments.parallelFallbackResolved -eq 0L) `
        '串行参考路径不得报告并行 fallback 接管。'
    if ([int]$parStatus.statusSegments.fastScanDop -ge 2) {
        Assert-True ([long]$parStatus.statusSegments.parallelFallbackResolved -eq
            [long]$parStatus.statusSegments.fastScanFallback -and
            [long]$parStatus.statusSegments.fastScanFallback -ge 2L) `
            '并行 fallback 必须实际接管全部 fast scan 未处理的 op。'
    }
    Assert-True ([long]$parStatus.metrics.bytesHashed -eq [long]$parSerialStatus.metrics.bytesHashed -and
        [long]$parStatus.metrics.entriesScanned -eq [long]$parSerialStatus.metrics.entriesScanned) `
        '互斥 target 的并行/串行运行必须保持 metrics 计数一致（无共享树重复哈希）。'
    Assert-True ((ConvertTo-StatusSemanticJson $parTreeRefStatus) -ceq
        (ConvertTo-StatusSemanticJson $parSerialStatus)) `
        'TREE_FAST=0 整轮（worker 内 PS 参考树快照）语义输出必须与串行参考路径逐字节等价。'
    Assert-True ([long]$parTreeRefStatus.metrics.bytesHashed -eq [long]$parSerialStatus.metrics.bytesHashed -and
        [long]$parTreeRefStatus.metrics.entriesScanned -eq [long]$parSerialStatus.metrics.entriesScanned) `
        'TREE_FAST=0 整轮必须保持 metrics 计数与串行参考一致。'

    # Slice 40（issue #58 N3）：receipt 门控 fallback 快路径必须与串行参考路径逐字节等价。
    # 覆盖 planned 干净/树漂移/命名空间不一致、planned+policy 漂移覆盖（:4214）、
    # transaction v2 policy 漂移（T1 观测塌缩）、transaction 严格校验失败记录与 v1 回退。
    $n3Root = Join-Path $fixtureRoot 'receipt-fastpath'
    $n3Evidence = Join-Path $n3Root 'evidence'
    $n3PolicyPath = Join-Path $n3Root 'policy.json'
    [void][IO.Directory]::CreateDirectory($n3Evidence)
    $n3PolicyEntry = [pscustomobject][ordered]@{
        id = 'receipt-fastpath'
        capabilityRoot = $n3Root
        minimumDescendantDepth = 1
        rootDeletionPurpose = 'none'
        allowHardLinks = $false
        allowInternalDirectoryJunctions = $false
        deniedExactPaths = @($n3Evidence)
    }
    [IO.File]::WriteAllText(
        $n3PolicyPath,
        ([pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-policy'
            schemaVersion = 4
            entries = @($n3PolicyEntry)
        } | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    function New-N3PlannedRun {
        param([Parameter(Mandatory)][string]$Name)
        $target = Join-Path $n3Root $Name
        [void][IO.Directory]::CreateDirectory($target)
        [IO.File]::WriteAllText(
            (Join-Path $target 'payload.txt'), "payload-$Name", [Text.UTF8Encoding]::new($false))
        $n3Plan = & $entryPath -Mode Plan -TargetPath $target -CapabilityRoot $n3Root `
            -FixturePolicyPath $n3PolicyPath -FixtureEvidenceRoot $n3Evidence
        $n3PlanPath = [string]$n3Plan.planPath
        $n3RunDirectory = Split-Path -Parent $n3PlanPath
        $n3PlanText = [IO.File]::ReadAllText($n3PlanPath)
        $n3PlanDocument = $n3PlanText | ConvertFrom-Json -Depth 128 -DateKind String
        $n3PlanShaParts = [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($n3PlanText)) | ForEach-Object { $_.ToString('x2') }
        return [pscustomobject][ordered]@{
            name = [string](Split-Path -Leaf $n3RunDirectory)
            runDirectory = $n3RunDirectory
            targetPath = $target
            planDocument = $n3PlanDocument
            planSha256 = [string]::Concat(@($n3PlanShaParts))
            quarantinePath = Join-Path $n3Root (
                '.codex-safe-delete-{0}.quarantine' -f [string]$n3PlanDocument.generationId)
        }
    }
    function New-N3Transaction {
        param(
            [Parameter(Mandatory)][object]$Run,
            [Parameter(Mandatory)][long]$SchemaVersion,
            [Parameter(Mandatory)][string]$Status
        )
        $n3Transaction = [pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-transaction'
            schemaVersion = $SchemaVersion
            generationId = [string]$Run.planDocument.generationId
            planPath = (Join-Path $Run.runDirectory 'plan.json')
            planSha256 = [string]$Run.planSha256
            targetPath = [string]$Run.planDocument.targetPath
            quarantinePath = [string]$Run.quarantinePath
            status = $Status
            updatedAtUtc = '2026-08-01T00:00:00.0000000+00:00'
        }
        if ($SchemaVersion -ge 2L) {
            $n3Transaction = [pscustomobject][ordered]@{
                artifactType = $n3Transaction.artifactType
                schemaVersion = $n3Transaction.schemaVersion
                generationId = $n3Transaction.generationId
                planPath = $n3Transaction.planPath
                planSha256 = $n3Transaction.planSha256
                targetPath = $n3Transaction.targetPath
                quarantinePath = $n3Transaction.quarantinePath
                directoryCommitAnchors = @()
                status = $n3Transaction.status
                updatedAtUtc = $n3Transaction.updatedAtUtc
            }
        }
        [IO.File]::WriteAllText(
            (Join-Path $Run.runDirectory 'transaction.json'),
            ($n3Transaction | ConvertTo-Json -Depth 16),
            [Text.UTF8Encoding]::new($false))
    }

    # policy v1 时代的 run：T1 漂移、broken transaction、v1 回退、planned+漂移覆盖。
    $n3RunT1 = New-N3PlannedRun -Name 'target-txn-drift'
    New-N3Transaction -Run $n3RunT1 -SchemaVersion 2 -Status 'purging'
    $n3RunBroken = New-N3PlannedRun -Name 'target-txn-broken'
    [IO.File]::WriteAllText(
        (Join-Path $n3RunBroken.runDirectory 'transaction.json'), '{', [Text.UTF8Encoding]::new($false))
    $n3RunV1 = New-N3PlannedRun -Name 'target-txn-v1'
    New-N3Transaction -Run $n3RunV1 -SchemaVersion 1 -Status 'quarantined'
    $n3RunPlannedDrift = New-N3PlannedRun -Name 'target-planned-drift'
    # N4：v1 policy 时代的 planned run，plan 生成后删除 target——命中 C# 直出分支
    # （planned 无 transaction + namespace 不一致 + policy 漂移）。冻结基线对该分支的
    # 编码为 inconsistent + 单错误（N2 注记称"生产未命中"，N4 取证证伪：基线内 23 个
    # 生产 op 命中）；纯参考解析器分叉为 manual-review + 双错误（:4214 覆盖）。
    $n3RunInconsistentDrift = New-N3PlannedRun -Name 'target-planned-inconsistent-drift'
    Remove-TestTree -Path $n3RunInconsistentDrift.targetPath

    # policy bump：追加无关 entry 使 sha 漂移，既有 plan 的 target 解析不变。
    $n3InertRoot = Join-Path $fixtureRoot 'receipt-fastpath-inert'
    [void][IO.Directory]::CreateDirectory($n3InertRoot)
    [IO.File]::WriteAllText(
        $n3PolicyPath,
        ([pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-policy'
            schemaVersion = 4
            entries = @(
                $n3PolicyEntry,
                [pscustomobject][ordered]@{
                    id = 'receipt-fastpath-inert'
                    capabilityRoot = $n3InertRoot
                    minimumDescendantDepth = 1
                    rootDeletionPurpose = 'none'
                    allowHardLinks = $false
                    allowInternalDirectoryJunctions = $false
                    deniedExactPaths = @()
                }
            )
        } | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    # 当前 policy 下的 planned 三态（无 policy 漂移）。
    $n3RunClean = New-N3PlannedRun -Name 'target-planned-clean'
    $n3RunTreeDrift = New-N3PlannedRun -Name 'target-planned-treedrift'
    [IO.File]::AppendAllText((Join-Path $n3RunTreeDrift.targetPath 'payload.txt'), '-drift')
    $n3RunInconsistent = New-N3PlannedRun -Name 'target-planned-inconsistent'
    [void][IO.Directory]::CreateDirectory($n3RunInconsistent.quarantinePath)

    # Slice 42（issue #58 N5 L4）：plan 生成后 target 被普通文件替换。C# ProbeNamespace 对
    # 非目录/非 reparse 条目一律回退（namespace-entry-type-other，发生在 receipt 签发之前），
    # 该 op 由并行 fallback 的参考重放产出 record A 形状；PS 快路径 record A 分支本身是
    # 扫描→worker 执行间 TOCTOU 窗口的防御，由下方直调钉确定性覆盖。
    $n3RunRecordA = New-N3PlannedRun -Name 'target-replaced-by-file'
    Remove-TestTree -Path $n3RunRecordA.targetPath
    [IO.File]::WriteAllText($n3RunRecordA.targetPath, 'not-a-directory', [Text.UTF8Encoding]::new($false))

    $previousParallelFallback = $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK
    $previousSegments = $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = '1'
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '1'
        $n3Status = & $entryPath -Mode Status `
            -FixturePolicyPath $n3PolicyPath -FixtureEvidenceRoot $n3Evidence
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '0'
        $n3SerialStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $n3PolicyPath -FixtureEvidenceRoot $n3Evidence
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = $previousParallelFallback
        $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = $previousSegments
    }
    Assert-True ((ConvertTo-StatusSemanticJson $n3Status) -ceq
        (ConvertTo-StatusSemanticJson $n3SerialStatus)) `
        'receipt 快路径的完整 Status 语义输出必须与串行参考路径逐字节等价。'
    Assert-True ([long]$n3Status.metrics.bytesHashed -eq [long]$n3SerialStatus.metrics.bytesHashed -and
        [long]$n3Status.metrics.entriesScanned -eq [long]$n3SerialStatus.metrics.entriesScanned) `
        'receipt 快路径必须保持 metrics 计数与串行参考一致。'
    if ([int]$n3Status.statusSegments.fastScanDop -ge 2) {
        # record A（namespace-entry-type-other）在 receipt 签发前回退、没有路由键，留在串行尾段解析，不进并行池。
        Assert-True ([long]$n3Status.statusSegments.parallelFallbackResolved -eq 7L -and
            [long]$n3Status.statusSegments.fastScanFallback -eq 8L) `
            '本 fixture 全部 8 个 op 都必须经 fallback 解析。'
        Assert-True ([long]$n3Status.statusSegments.parallelFallbackReceiptFastResolved -eq 6L) `
            'receipt 快路径必须实际接管 6 个 op（v1 transaction 与 record A 命名空间回退参考路径）。'
    }
    Assert-True ([long]$n3SerialStatus.statusSegments.parallelFallbackReceiptFastResolved -eq 0L) `
        '串行参考路径不得报告 receipt 快路径接管。'
    $n3Ops = @{}
    foreach ($n3Op in @($n3Status.operations)) { $n3Ops[[string]$n3Op.operationId] = $n3Op }
    $n3T1Op = $n3Ops[[string]$n3RunT1.name]
    Assert-True ($null -ne $n3T1Op -and
        [string]$n3T1Op.lifecycle -ceq 'manual-review' -and
        [string]$n3T1Op.journalStatus -ceq 'invalid' -and
        -not [bool]$n3T1Op.schemaCompatible -and
        -not [bool]$n3T1Op.policyCompatible -and
        [long]$n3T1Op.transactionSchemaVersion -eq 2L -and
        [string]$n3T1Op.transactionStatus -ceq 'purging' -and
        [string]$n3T1Op.transactionUpdatedAtUtc -ceq '2026-08-01T00:00:00.0000000+00:00' -and
        @($n3T1Op.errors).Count -eq 1 -and
        [string]$n3T1Op.errors[0] -ceq 'safe-delete policy 自计划生成后已漂移。') `
        'T1（transaction v2 + policy 漂移）记录必须与参考观测塌缩一致。'
    $n3BrokenOp = $n3Ops[[string]$n3RunBroken.name]
    Assert-True ($null -ne $n3BrokenOp -and
        [string]$n3BrokenOp.lifecycle -ceq 'manual-review' -and
        [string]$n3BrokenOp.journalStatus -ceq 'invalid' -and
        $null -eq $n3BrokenOp.transactionSchemaVersion -and
        @($n3BrokenOp.errors).Count -eq 1) `
        'broken transaction 必须保持参考路径的严格校验错误记录形状。'
    $n3V1Op = $n3Ops[[string]$n3RunV1.name]
    Assert-True ($null -ne $n3V1Op -and @($n3V1Op.errors).Count -ge 1) `
        'v1 transaction 必须经参考路径产出观测错误记录。'
    $n3CleanOp = $n3Ops[[string]$n3RunClean.name]
    Assert-True ($null -ne $n3CleanOp -and
        [string]$n3CleanOp.lifecycle -ceq 'planned' -and
        @($n3CleanOp.safeActions).Count -eq 1 -and
        [string]$n3CleanOp.safeActions[0] -ceq 'apply' -and
        @($n3CleanOp.errors).Count -eq 0 -and
        [bool]$n3CleanOp.policyCompatible -and
        [bool]$n3CleanOp.schemaCompatible -and
        [string]$n3CleanOp.journalStatus -ceq 'not-started') `
        'planned 干净 op 必须保持 planned/apply 记录。'
    $n3TreeDriftOp = $n3Ops[[string]$n3RunTreeDrift.name]
    Assert-True ($null -ne $n3TreeDriftOp -and
        [string]$n3TreeDriftOp.lifecycle -ceq 'manual-review' -and
        @($n3TreeDriftOp.errors).Count -eq 1 -and
        [string]$n3TreeDriftOp.errors[0] -ceq 'safe-delete Status planned tree manifest 漂移。' -and
        [string]$n3TreeDriftOp.journalStatus -ceq 'not-started') `
        'planned 树漂移 op 必须只带 manifest 漂移错误（无 policy 漂移追加）。'
    $n3InconsistentOp = $n3Ops[[string]$n3RunInconsistent.name]
    Assert-True ($null -ne $n3InconsistentOp -and
        [string]$n3InconsistentOp.lifecycle -ceq 'inconsistent' -and
        @($n3InconsistentOp.errors).Count -eq 1 -and
        [string]$n3InconsistentOp.errors[0] -ceq 'planned operation 的 target/quarantine namespace 不一致。' -and
        [bool]$n3InconsistentOp.policyCompatible) `
        'planned 命名空间不一致 op 必须保持 inconsistent 记录（无漂移覆盖）。'
    $n3RecordAOp = $n3Ops[[string]$n3RunRecordA.name]
    Assert-True ($null -ne $n3RecordAOp -and
        [string]$n3RecordAOp.lifecycle -ceq 'manual-review' -and
        @($n3RecordAOp.errors).Count -eq 1 -and
        [string]$n3RecordAOp.errors[0] -ceq 'safe-delete Status target/quarantine namespace entry 不是普通目录。' -and
        @($n3RecordAOp.safeActions).Count -eq 1 -and
        [string]$n3RecordAOp.safeActions[0] -ceq 'manual-review' -and
        [string]$n3RecordAOp.journalStatus -ceq 'not-evaluated' -and
        -not [bool]$n3RecordAOp.schemaCompatible -and
        [bool]$n3RecordAOp.targetPresent -and
        [string]$n3RecordAOp.targetEntryType -ceq 'file' -and
        $null -eq $n3RecordAOp.transactionSchemaVersion) `
        'record A（target 为文件）op 必须保持命名空间类型错误记录形状（journal/schema 初值）。'
    $n3PlannedDriftOp = $n3Ops[[string]$n3RunPlannedDrift.name]
    Assert-True ($null -ne $n3PlannedDriftOp -and
        [string]$n3PlannedDriftOp.lifecycle -ceq 'manual-review' -and
        @($n3PlannedDriftOp.errors).Count -eq 1 -and
        [string]$n3PlannedDriftOp.errors[0] -ceq 'plan policy SHA 已漂移；当前严格写路径不可执行该计划。' -and
        [string]$n3PlannedDriftOp.journalStatus -ceq 'not-started' -and
        [bool]$n3PlannedDriftOp.schemaCompatible -and
        -not [bool]$n3PlannedDriftOp.policyCompatible) `
        'planned+policy 漂移 op 必须保持 :4214 覆盖后的记录形状。'
    $n3InconsistentDriftOp = $n3Ops[[string]$n3RunInconsistentDrift.name]
    Assert-True ($null -ne $n3InconsistentDriftOp -and
        [string]$n3InconsistentDriftOp.lifecycle -ceq 'inconsistent' -and
        @($n3InconsistentDriftOp.errors).Count -eq 1 -and
        [string]$n3InconsistentDriftOp.errors[0] -ceq 'planned operation 的 target/quarantine namespace 不一致。' -and
        @($n3InconsistentDriftOp.safeActions).Count -eq 1 -and
        [string]$n3InconsistentDriftOp.safeActions[0] -ceq 'manual-review' -and
        [string]$n3InconsistentDriftOp.journalStatus -ceq 'not-started' -and
        [bool]$n3InconsistentDriftOp.schemaCompatible -and
        -not [bool]$n3InconsistentDriftOp.policyCompatible -and
        $null -eq $n3InconsistentDriftOp.transactionSchemaVersion -and
        -not [bool]$n3InconsistentDriftOp.targetPresent -and
        -not [bool]$n3InconsistentDriftOp.quarantinePresent -and
        [bool]$n3InconsistentDriftOp.namespaceAbsent) `
        'planned+inconsistent+policy 漂移 op 的管线输出必须保持冻结基线语义（inconsistent + 单错误）。'
    # 分叉钉：纯参考解析器（仅 FAST_SCAN=0 诊断模式可达）对同一 run 产出 :4214 覆盖后的
    # 双 absent namespace 是唯一收窄的 PS/reference 分叉；其他 policy-only drift 和
    # namespace 反例仍由严格 policy-drift 覆盖处理。
    $n3RefPolicy = Read-CodexSafeTreeDeletePolicy -PolicyPath $n3PolicyPath
    $n3RefMetrics = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    $n3RefOp = Resolve-CodexSafeTreeDeleteStatusOperation `
        -RunItem (Get-Item -LiteralPath $n3RunInconsistentDrift.runDirectory) `
        -PolicyPath $n3PolicyPath `
        -CurrentPolicySha256 ([string]$n3RefPolicy.sha256) `
        -FullEvidenceRoot $n3Evidence `
        -CandidatePolicyRequested $false `
        -CandidatePolicy $null `
        -MetricsState $n3RefMetrics `
        -TreeMetricsObserver (New-CodexSafeTreeDeleteMetricsObserver -State $n3RefMetrics) `
        -StatusTreeCache ([Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)) `
        -LoadedPolicy $n3RefPolicy `
        -StatusPlanPrefetch $null `
        -PlanManifestShaCache ([Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal))
    Assert-True ($null -ne $n3RefOp -and
        [string]$n3RefOp.operation.lifecycle -ceq 'inconsistent' -and
        @($n3RefOp.operation.errors).Count -eq 1 -and
        [string]$n3RefOp.operation.errors[0] -ceq 'planned operation 的 target/quarantine namespace 不一致。' -and
        @($n3RefOp.operation.safeActions).Count -eq 1 -and
        [string]$n3RefOp.operation.safeActions[0] -ceq 'manual-review' -and
        -not [bool]$n3RefOp.operation.policyCompatible -and
        $null -eq $n3RefOp.operation.transactionSchemaVersion -and
        -not [bool]$n3RefOp.operation.targetPresent -and
        -not [bool]$n3RefOp.operation.quarantinePresent) `
        '纯参考解析器对 approved plan + 无 transaction + 双 absent namespace 必须与生产 C# 保持 inconsistent 单错误。'

    # C# approved-missing fast path 反例：quarantine directory 存在时必须回退，
    # 不得把它误判为双 absent namespace。
    [void][IO.Directory]::CreateDirectory($n3RunInconsistentDrift.quarantinePath)
    $n3QuarantineDirectoryScan = Invoke-CodexSafeTreeDeleteStatusFastScan `
        -RunItems @(Get-Item -LiteralPath $n3RunInconsistentDrift.runDirectory -Force) `
        -Policy $n3RefPolicy -FullEvidenceRoot $n3Evidence `
        -MetricsState (New-CodexSafeTreeDeleteMetricsState -Phase 'status') -DegreeOfParallelism 1
    $n3QuarantineDirectoryResult = $n3QuarantineDirectoryScan[[string]$n3RunInconsistentDrift.runDirectory]
    Assert-True (-not [bool]$n3QuarantineDirectoryResult.Handled) `
        'approved-missing fast path 在 quarantine directory 存在时必须 fallback。'

    # Slice 42（续）：PS 快路径 record A 分支直调钉。receipt 在 target 仍是目录时签发，
    # 随后 target 被文件替换（模拟扫描→worker 执行间的 TOCTOU 窗口）；直调必须命中
    # record A 分支直接提交命名空间类型错误记录，而不是回退参考路径。
    $n3RunRecordADirect = New-N3PlannedRun -Name 'target-replaced-by-file-direct'
    $n3RecordAMetrics = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    Add-Member -InputObject $n3RecordAMetrics -NotePropertyMembers @{
        segmentDirectoryEnumerationMs = 0L
        segmentPlanTransactionReadMs = 0L
        segmentTerminalArchiveAuthMs = 0L
        segmentTreeMaterializationMs = 0L
        segmentSha256Ms = 0L
        segmentActiveResolveMs = 0L
        segmentArchivedResolveMs = 0L
        segmentPrefetchMs = 0L
        segmentFastScanMs = 0L
        approvedPlanValidationReuseCount = 0L
    } -Force
    $n3RecordAScan = Invoke-CodexSafeTreeDeleteStatusFastScan `
        -RunItems @(Get-Item -LiteralPath $n3RunRecordADirect.runDirectory -Force) `
        -Policy $n3RefPolicy -FullEvidenceRoot $n3Evidence `
        -MetricsState $n3RecordAMetrics -DegreeOfParallelism 1
    $n3RecordAScanResult = $n3RecordAScan[[string]$n3RunRecordADirect.runDirectory]
    Assert-True ($null -ne $n3RecordAScanResult -and
        -not [bool]$n3RecordAScanResult.Handled -and
        [string]$n3RecordAScanResult.FallbackReason -ceq 'plan-approved' -and
        $null -ne $n3RecordAScanResult.ApprovedPlanValidation) `
        'record A 直调 fixture 必须在 target 仍是目录时取得 plan-approved receipt。'
    [IO.File]::Delete((Join-Path $n3RunRecordADirect.targetPath 'payload.txt'))
    [IO.Directory]::Delete($n3RunRecordADirect.targetPath, $false)
    [IO.File]::WriteAllText(
        $n3RunRecordADirect.targetPath, 'not-a-directory', [Text.UTF8Encoding]::new($false))
    $n3RecordAPrefetch = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $n3RecordAPrefetch[[string]$n3RunRecordADirect.runDirectory] = [pscustomobject][ordered]@{
        snapshot = [pscustomobject][ordered]@{
            sha256 = [string]$n3RecordAScanResult.PlanSha256
            text = [string]$n3RecordAScanResult.PlanText
        }
        document = $null
        approvedPlanValidation = $n3RecordAScanResult.ApprovedPlanValidation
        planManifestSha256 = if ($null -ne $n3RecordAScanResult.PlanManifestSha256) {
            [string]$n3RecordAScanResult.PlanManifestSha256
        } else {
            $null
        }
        receiptPlanTargetPath = if ($null -ne $n3RecordAScanResult.ReceiptPlanTargetPath) {
            [string]$n3RecordAScanResult.ReceiptPlanTargetPath
        } else {
            $null
        }
        receiptPlanQuarantinePath = if ($null -ne $n3RecordAScanResult.ReceiptPlanQuarantinePath) {
            [string]$n3RecordAScanResult.ReceiptPlanQuarantinePath
        } else {
            $null
        }
        receiptPlanCapabilityRoot = if ($null -ne $n3RecordAScanResult.ReceiptPlanCapabilityRoot) {
            [string]$n3RecordAScanResult.ReceiptPlanCapabilityRoot
        } else {
            $null
        }
        receiptPlanPolicySha256 = if ($null -ne $n3RecordAScanResult.ReceiptPlanPolicySha256) {
            [string]$n3RecordAScanResult.ReceiptPlanPolicySha256
        } else {
            $null
        }
        scanResult = $n3RecordAScanResult
    }
    $n3RecordAFast = Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation `
        -RunItem (Get-Item -LiteralPath $n3RunRecordADirect.runDirectory -Force) `
        -CurrentPolicySha256 ([string]$n3RefPolicy.sha256) `
        -FullEvidenceRoot $n3Evidence `
        -MetricsState $n3RecordAMetrics `
        -TreeMetricsObserver (New-CodexSafeTreeDeleteMetricsObserver -State $n3RecordAMetrics) `
        -StatusTreeCache ([Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)) `
        -LoadedPolicy $n3RefPolicy `
        -StatusPlanPrefetch $n3RecordAPrefetch `
        -PlanManifestShaCache ([Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal))
    Assert-True ($null -ne $n3RecordAFast -and
        -not [bool]$n3RecordAFast.complete -and
        [string]$n3RecordAFast.operation.lifecycle -ceq 'manual-review' -and
        @($n3RecordAFast.operation.errors).Count -eq 1 -and
        [string]$n3RecordAFast.operation.errors[0] -ceq 'safe-delete Status target/quarantine namespace entry 不是普通目录。' -and
        [string]$n3RecordAFast.operation.journalStatus -ceq 'not-evaluated' -and
        -not [bool]$n3RecordAFast.operation.schemaCompatible -and
        [bool]$n3RecordAFast.operation.targetPresent -and
        [string]$n3RecordAFast.operation.targetEntryType -ceq 'file') `
        'PS 快路径 record A 分支必须直接提交命名空间类型错误记录（TOCTOU 防御）。'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteStatus'
        slices = 42
    }
} finally {
    if ($null -ne $lockedStream) { $lockedStream.Dispose() }
    if ($null -ne $reparsePath -and [IO.Directory]::Exists($reparsePath)) {
        [IO.Directory]::Delete($reparsePath)
    }
    Remove-TestTree -Path $fixtureRoot
}
