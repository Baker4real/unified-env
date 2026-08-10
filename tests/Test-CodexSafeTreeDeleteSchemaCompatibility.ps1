[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$fixtureRoot = Join-Path $projectRoot (
    'reports\safe-tree-delete-schema-compatibility-test-{0}' -f ([guid]::NewGuid().ToString('N')))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'

. $hostSafetyLibraryPath

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    } catch {
        return $_.Exception.Message
    }
    throw $Message
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete schema compatibility test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete schema compatibility test cleanup'
}

function New-TestPolicy {
    param([Parameter(Mandatory)][long]$SchemaVersion)

    $entryProperties = [ordered]@{
        id = "schema-v$SchemaVersion-fixture"
        capabilityRoot = $fixtureRoot
        minimumDescendantDepth = 1
        rootDeletionPurpose = 'none'
        deniedExactPaths = @($evidenceRoot)
    }
    if ($SchemaVersion -ge 4L) {
        $entryProperties.allowHardLinks = $false
        $entryProperties.allowInternalDirectoryJunctions = $false
    }
    if ($SchemaVersion -eq 5L) {
        $entryProperties.minimumQuarantineAgeMinutes = 0L
        $entryProperties.producerFenceMode = 'manual-only'
    }
    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = $SchemaVersion
        entries = @([pscustomobject]$entryProperties)
    }
}

function Write-TestJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Document | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)

    foreach ($schemaVersion in @(3L, 4L, 5L)) {
        $policyPath = Join-Path $fixtureRoot "policy-v$schemaVersion.json"
        Write-TestJson -Path $policyPath -Document (New-TestPolicy -SchemaVersion $schemaVersion)
        $status = & $entryPath `
            -Mode Status `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
        Assert-True ($status.policySchemaVersion -eq $schemaVersion -and $status.complete) `
            "policy v$schemaVersion 必须保持严格兼容读取"
    }

    $incompleteV5 = New-TestPolicy -SchemaVersion 5L
    $incompleteV5.entries[0].PSObject.Properties.Remove('allowHardLinks')
    $incompletePolicyPath = Join-Path $fixtureRoot 'policy-v5-incomplete.json'
    Write-TestJson -Path $incompletePolicyPath -Document $incompleteV5
    $incompleteError = Assert-Throws `
        -Message '不完整 policy v5 必须失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Status `
                -FixturePolicyPath $incompletePolicyPath `
                -FixtureEvidenceRoot $evidenceRoot
        }
    Assert-True ($incompleteError -match '属性集合非法') `
        '不完整 policy v5 必须返回稳定 schema 拒绝原因'

    $largeAgePolicy = New-TestPolicy -SchemaVersion 5L
    $largeAgePolicy.entries[0].minimumQuarantineAgeMinutes = 525601L
    $largeAgePolicyPath = Join-Path $fixtureRoot 'policy-v5-large-age.json'
    Write-TestJson -Path $largeAgePolicyPath -Document $largeAgePolicy
    $largeAgeStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $largeAgePolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($largeAgeStatus.policySchemaVersion -eq 5L -and $largeAgeStatus.complete) `
        'policy v5 minimumQuarantineAgeMinutes 必须接受完整非负 JSON integer 域'

    $nonArrayEntriesPolicy = New-TestPolicy -SchemaVersion 5L
    $nonArrayEntriesPolicy.entries = $nonArrayEntriesPolicy.entries[0]
    $nonArrayEntriesPath = Join-Path $fixtureRoot 'policy-v5-non-array-entries.json'
    Write-TestJson -Path $nonArrayEntriesPath -Document $nonArrayEntriesPolicy
    $nonArrayEntriesError = Assert-Throws `
        -Message 'policy entries 的错误 JSON collection 类型必须失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Status `
                -FixturePolicyPath $nonArrayEntriesPath `
                -FixtureEvidenceRoot $evidenceRoot
        }
    Assert-True ($nonArrayEntriesError -match 'entries.*JSON array') `
        'policy entries 类型拒绝必须给出稳定原因'

    $nonArrayDeniedPolicy = New-TestPolicy -SchemaVersion 5L
    $nonArrayDeniedPolicy.entries[0].deniedExactPaths = $evidenceRoot
    $nonArrayDeniedPath = Join-Path $fixtureRoot 'policy-v5-non-array-denied.json'
    Write-TestJson -Path $nonArrayDeniedPath -Document $nonArrayDeniedPolicy
    $nonArrayDeniedError = Assert-Throws `
        -Message 'deniedExactPaths 的错误 JSON collection 类型必须失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Status `
                -FixturePolicyPath $nonArrayDeniedPath `
                -FixtureEvidenceRoot $evidenceRoot
        }
    Assert-True ($nonArrayDeniedError -match 'deniedExactPaths.*JSON array') `
        'deniedExactPaths 类型拒绝必须给出稳定原因'

    $numericIdPolicy = New-TestPolicy -SchemaVersion 5L
    $numericIdPolicy.entries[0].id = 7L
    $numericIdPath = Join-Path $fixtureRoot 'policy-v5-numeric-id.json'
    Write-TestJson -Path $numericIdPath -Document $numericIdPolicy
    $numericIdError = Assert-Throws `
        -Message 'policy id 的错误 JSON scalar 类型必须失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Status `
                -FixturePolicyPath $numericIdPath `
                -FixtureEvidenceRoot $evidenceRoot
        }
    Assert-True ($numericIdError -match 'id.*JSON string') `
        'policy scalar 类型拒绝必须给出稳定原因'

    $v4EvidenceRoot = Join-Path $fixtureRoot 'v4-evidence'
    [void][IO.Directory]::CreateDirectory($v4EvidenceRoot)
    $v4Policy = New-TestPolicy -SchemaVersion 4L
    $v4Policy.entries[0].deniedExactPaths = @($v4EvidenceRoot)
    $v4PolicyPath = Join-Path $fixtureRoot 'transaction-v4-policy.json'
    Write-TestJson -Path $v4PolicyPath -Document $v4Policy
    $v2Target = Join-Path $fixtureRoot 'transaction-v2-target'
    [void][IO.Directory]::CreateDirectory($v2Target)
    [IO.File]::WriteAllText(
        (Join-Path $v2Target 'payload.txt'),
        'transaction-v2',
        [Text.UTF8Encoding]::new($false))
    $v2Plan = & $entryPath `
        -Mode Plan `
        -TargetPath $v2Target `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $v4PolicyPath `
        -FixtureEvidenceRoot $v4EvidenceRoot
    $v2Apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$v2Plan.planPath) `
        -ApprovedPlanSha256 ([string]$v2Plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $v4PolicyPath `
        -FixtureEvidenceRoot $v4EvidenceRoot
    $v2Status = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v4PolicyPath `
        -FixtureEvidenceRoot $v4EvidenceRoot
    Assert-True ($v2Status.operations.Count -eq 1 -and
        $v2Status.operations[0].transactionSchemaVersion -eq 2L -and
        $v2Status.operations[0].schemaCompatible) `
        '现役 transaction v2 必须保持严格兼容读取'

    $v1EvidenceRoot = Join-Path $fixtureRoot 'transaction-v1-evidence'
    [void][IO.Directory]::CreateDirectory($v1EvidenceRoot)
    $v1Policy = New-TestPolicy -SchemaVersion 4L
    $v1Policy.entries[0].deniedExactPaths = @($v1EvidenceRoot)
    $v1PolicyPath = Join-Path $fixtureRoot 'transaction-v1-policy.json'
    Write-TestJson -Path $v1PolicyPath -Document $v1Policy
    $v1Target = Join-Path $fixtureRoot 'transaction-v1-target'
    [void][IO.Directory]::CreateDirectory($v1Target)
    [IO.File]::WriteAllText(
        (Join-Path $v1Target 'payload.txt'),
        'transaction-v1',
        [Text.UTF8Encoding]::new($false))
    $v1Plan = & $entryPath `
        -Mode Plan `
        -TargetPath $v1Target `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $v1PolicyPath `
        -FixtureEvidenceRoot $v1EvidenceRoot
    $v1Apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$v1Plan.planPath) `
        -ApprovedPlanSha256 ([string]$v1Plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $v1PolicyPath `
        -FixtureEvidenceRoot $v1EvidenceRoot
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
    Write-TestJson -Path $v1Apply.transactionPath -Document $v1Transaction
    $v1TransactionSha256 = (Get-FileHash `
        -LiteralPath $v1Apply.transactionPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    $v1Status = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v1PolicyPath `
        -FixtureEvidenceRoot $v1EvidenceRoot
    $v1Operation = @($v1Status.operations)[0]
    Assert-True ($v1Status.operations.Count -eq 1 -and
        $v1Operation.transactionSchemaVersion -eq 1L -and
        $v1Operation.transactionStatus -ceq 'quarantined' -and
        [string]$v1Operation.targetPath -ceq $v1Target -and
        -not $v1Operation.schemaCompatible) `
        'transaction v1 必须仅在 Status 只读路径保留真实状态与 target'

    $v1Policy.entries[0].minimumDescendantDepth = 2L
    Write-TestJson -Path $v1PolicyPath -Document $v1Policy
    $v1SemanticPolicyDriftStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v1PolicyPath `
        -FixtureEvidenceRoot $v1EvidenceRoot
    $v1SemanticPolicyDriftOperation = @($v1SemanticPolicyDriftStatus.operations)[0]
    Assert-True ($v1SemanticPolicyDriftStatus.operations.Count -eq 1 -and
        $v1SemanticPolicyDriftOperation.transactionSchemaVersion -eq 1L -and
        $v1SemanticPolicyDriftOperation.transactionStatus -ceq 'quarantined' -and
        [string]$v1SemanticPolicyDriftOperation.targetPath -ceq $v1Target -and
        [string]$v1SemanticPolicyDriftOperation.quarantinePath -ceq $v1Transaction.quarantinePath -and
        [string]$v1SemanticPolicyDriftOperation.transactionUpdatedAtUtc -ceq $v1Transaction.updatedAtUtc -and
        -not $v1SemanticPolicyDriftOperation.schemaCompatible -and
        -not $v1SemanticPolicyDriftOperation.policyCompatible -and
        $v1SemanticPolicyDriftOperation.lifecycle -ceq 'manual-review') `
        'plan 语义拒绝必须继续 blocking，但不得清空 v1 transaction 的只读观测字段'

    $beforeV1WriteRefusals = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $fixtureRoot `
        -CapabilityRoot (Split-Path -Parent $fixtureRoot) `
        -AllowedExactPaths @($fixtureRoot) `
        -Name 'safe-delete transaction v1 write refusal before state'
    $v1PurgeError = Assert-Throws `
        -Message 'Purge 必须继续拒绝 transaction v1' `
        -Action {
            & $entryPath `
                -Mode Purge `
                -TransactionPath ([string]$v1Apply.transactionPath) `
                -ApprovedTransactionSha256 $v1TransactionSha256 `
                -ConfirmPurge `
                -FixturePolicyPath $v1PolicyPath `
                -FixtureEvidenceRoot $v1EvidenceRoot
        }
    Assert-True ($v1PurgeError -match
        'transaction schemaVersion 必须是 JSON integer 2 或 3') `
        'Purge 对 transaction v1 必须返回稳定 schema 拒绝原因'
    $v1RestoreError = Assert-Throws `
        -Message 'Restore 必须继续拒绝 transaction v1' `
        -Action {
            & $entryPath `
                -Mode Restore `
                -TransactionPath ([string]$v1Apply.transactionPath) `
                -ApprovedTransactionSha256 $v1TransactionSha256 `
                -ConfirmRestore `
                -FixturePolicyPath $v1PolicyPath `
                -FixtureEvidenceRoot $v1EvidenceRoot
        }
    Assert-True ($v1RestoreError -match
        'transaction schemaVersion 必须是 JSON integer 2 或 3') `
        'Restore 对 transaction v1 必须返回稳定 schema 拒绝原因'
    $afterV1WriteRefusals = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $fixtureRoot `
        -CapabilityRoot (Split-Path -Parent $fixtureRoot) `
        -AllowedExactPaths @($fixtureRoot) `
        -Name 'safe-delete transaction v1 write refusal after state'
    Assert-True (
        (($beforeV1WriteRefusals | ConvertTo-Json -Depth 100 -Compress) -ceq
            ($afterV1WriteRefusals | ConvertTo-Json -Depth 100 -Compress))) `
        'Purge/Restore 对 transaction v1 的拒绝必须保持 fixture 零写入'
    $persistedV1Transaction = Get-Content -Raw -LiteralPath $v1Apply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ($null -eq $persistedV1Transaction.PSObject.Properties['directoryCommitAnchors']) `
        'Status/Purge/Restore 都不得为 transaction v1 补写 directoryCommitAnchors'

    $v5Policy = New-TestPolicy -SchemaVersion 5L
    $v5PolicyPath = Join-Path $fixtureRoot 'transaction-v5-policy.json'
    Write-TestJson -Path $v5PolicyPath -Document $v5Policy
    $v3Target = Join-Path $fixtureRoot 'transaction-v3-target'
    [void][IO.Directory]::CreateDirectory($v3Target)
    [IO.File]::WriteAllText(
        (Join-Path $v3Target 'payload.txt'),
        'transaction-v3',
        [Text.UTF8Encoding]::new($false))
    $v3Plan = & $entryPath `
        -Mode Plan `
        -TargetPath $v3Target `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $v3Apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$v3Plan.planPath) `
        -ApprovedPlanSha256 ([string]$v3Plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $v3Status = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($v3Status.operations.Count -eq 1 -and
        $v3Status.operations[0].transactionSchemaVersion -eq 3L -and
        $v3Status.operations[0].schemaCompatible) `
        '完整 transaction v3 必须报告 schema compatible'

    $validV3TransactionText = Get-Content -Raw -LiteralPath $v3Apply.transactionPath
    $v3Transaction = $validV3TransactionText |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $v3QuarantineTimeAnchor = $v3Transaction.quarantineTimeAnchor
    $v3Transaction.quarantineTimeAnchor = $null
    Write-TestJson -Path $v3Apply.transactionPath -Document $v3Transaction
    $incompleteV3Status = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $v3OperationId = Split-Path -Leaf (Split-Path -Parent ([string]$v3Apply.transactionPath))
    $incompleteV3Operation = @($incompleteV3Status.operations |
        Where-Object operationId -ceq $v3OperationId)
    Assert-True ($incompleteV3Operation.Count -eq 1 -and
        -not $incompleteV3Operation[0].schemaCompatible -and
        $v3OperationId -cin @($incompleteV3Status.migrationReadiness.blockingRecords)) `
        '不完整非终态 transaction v3 必须逐项阻断 migration readiness'

    $v3Transaction.quarantineTimeAnchor = $v3QuarantineTimeAnchor
    $v3Transaction.status = 'restored'
    $v3Transaction.restoreJournalAnchors = @()
    Write-TestJson -Path $v3Apply.transactionPath -Document $v3Transaction
    $missingRestoreAnchorsStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $missingRestoreAnchorsOperation = @($missingRestoreAnchorsStatus.operations |
        Where-Object operationId -ceq $v3OperationId)
    Assert-True ($missingRestoreAnchorsOperation.Count -eq 1 -and
        -not $missingRestoreAnchorsOperation[0].schemaCompatible -and
        (($missingRestoreAnchorsOperation[0].errors -join ' ') -match 'Restore journal anchor')) `
        'restored transaction v3 必须绑定完整 Restore journal anchors'

    $v4EvidenceBeforePreflight = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $v4EvidenceRoot `
        -CapabilityRoot $fixtureRoot `
        -AllowedExactPaths @($v4EvidenceRoot) `
        -Name 'safe-delete candidate preflight before state'
    $candidatePolicySha256 = (Get-FileHash -LiteralPath $v5PolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $candidateStatus = & $entryPath `
        -Mode Status `
        -FixtureCandidatePolicyPath $v5PolicyPath `
        -FixtureApprovedCandidatePolicySha256 $candidatePolicySha256 `
        -FixturePolicyPath $v4PolicyPath `
        -FixtureEvidenceRoot $v4EvidenceRoot
    $v2OperationId = Split-Path -Leaf (Split-Path -Parent ([string]$v2Apply.transactionPath))
    Assert-True ($candidateStatus.migrationReadiness.evaluated -and
        -not $candidateStatus.migrationReadiness.ready -and
        $v2OperationId -cin @($candidateStatus.migrationReadiness.blockingRecords) -and
        -not $candidateStatus.operations[0].candidatePolicyCompatible) `
        'candidate policy SHA 漂移必须逐项列出并阻止非终态 transaction 激活'
    $v4EvidenceAfterPreflight = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $v4EvidenceRoot `
        -CapabilityRoot $fixtureRoot `
        -AllowedExactPaths @($v4EvidenceRoot) `
        -Name 'safe-delete candidate preflight after state'
    Assert-True (((
        $v4EvidenceBeforePreflight | ConvertTo-Json -Depth 100 -Compress) -ceq
        ($v4EvidenceAfterPreflight | ConvertTo-Json -Depth 100 -Compress))) `
        'candidate migration preflight 必须保持历史 ledger 字节与 identity 不变'

    $candidateShaError = Assert-Throws `
        -Message 'candidate policy 未经精确 SHA 批准必须失败闭锁' `
        -Action {
            & $entryPath `
                -Mode Status `
                -FixtureCandidatePolicyPath $v5PolicyPath `
                -FixtureApprovedCandidatePolicySha256 ('0' * 64) `
                -FixturePolicyPath $v4PolicyPath `
                -FixtureEvidenceRoot $v4EvidenceRoot
        }
    Assert-True ($candidateShaError -match 'approved SHA-256 不匹配') `
        'candidate SHA 拒绝必须给出稳定原因'

    $rollbackStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v4PolicyPath `
        -FixtureEvidenceRoot $v4EvidenceRoot
    Assert-True (-not $rollbackStatus.migrationReadiness.evaluated -and
        $rollbackStatus.operations[0].schemaCompatible -and
        $null -eq $rollbackStatus.operations[0].candidatePolicyCompatible) `
        'candidate parser preflight 后旧 policy/transaction 读取必须保持原合同'

    $wrongTimestampTransaction = $validV3TransactionText |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $wrongTimestampTransaction.updatedAtUtc = 7L
    Write-TestJson -Path $v3Apply.transactionPath -Document $wrongTimestampTransaction
    $wrongTimestampStatus = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $v5PolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $wrongTimestampOperation = @($wrongTimestampStatus.operations |
        Where-Object operationId -ceq $v3OperationId)
    Assert-True ($wrongTimestampOperation.Count -eq 1 -and
        -not $wrongTimestampOperation[0].schemaCompatible -and
        (($wrongTimestampOperation[0].errors -join ' ') -match 'updatedAtUtc')) `
        'transaction v3 updatedAtUtc 的错误 JSON 类型必须失败闭锁'

    $invalidPolicyCases = @(
        [pscustomobject]@{
            name = 'unknown-version'
            document = New-TestPolicy -SchemaVersion 6L
        },
        [pscustomobject]@{
            name = 'extra-property'
            document = $(
                $document = New-TestPolicy -SchemaVersion 5L
                $document.entries[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
                $document
            )
        },
        [pscustomobject]@{
            name = 'string-age'
            document = $(
                $document = New-TestPolicy -SchemaVersion 5L
                $document.entries[0].minimumQuarantineAgeMinutes = '10'
                $document
            )
        },
        [pscustomobject]@{
            name = 'decimal-age'
            document = $(
                $document = New-TestPolicy -SchemaVersion 5L
                $document.entries[0].minimumQuarantineAgeMinutes = 10.5
                $document
            )
        },
        [pscustomobject]@{
            name = 'string-boolean'
            document = $(
                $document = New-TestPolicy -SchemaVersion 5L
                $document.entries[0].allowHardLinks = 'false'
                $document
            )
        }
    )
    foreach ($invalidPolicyCase in $invalidPolicyCases) {
        $invalidPolicyPath = Join-Path $fixtureRoot ("invalid-policy-{0}.json" -f $invalidPolicyCase.name)
        Write-TestJson -Path $invalidPolicyPath -Document $invalidPolicyCase.document
        [void](Assert-Throws `
            -Message ("非法 policy case {0} 必须失败闭锁" -f $invalidPolicyCase.name) `
            -Action {
                & $entryPath `
                    -Mode Status `
                    -FixturePolicyPath $invalidPolicyPath `
                    -FixtureEvidenceRoot $evidenceRoot
            })
    }

    $invalidTransactionCases = @(
        [pscustomobject]@{
            name = 'unknown-version'
            mutate = { param($Document) $Document.schemaVersion = 99L }
        },
        [pscustomobject]@{
            name = 'extra-property'
            mutate = {
                param($Document)
                $Document | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
            }
        },
        [pscustomobject]@{
            name = 'missing-v3-property'
            mutate = { param($Document) $Document.PSObject.Properties.Remove('restoreJournalAnchors') }
        },
        [pscustomobject]@{
            name = 'non-array-commit-anchors'
            mutate = { param($Document) $Document.directoryCommitAnchors = [pscustomobject]@{} }
        }
    )
    foreach ($invalidTransactionCase in $invalidTransactionCases) {
        $invalidTransaction = $validV3TransactionText |
            ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
        & $invalidTransactionCase.mutate $invalidTransaction
        Write-TestJson -Path $v3Apply.transactionPath -Document $invalidTransaction
        $invalidTransactionStatus = & $entryPath `
            -Mode Status `
            -FixturePolicyPath $v5PolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
        $invalidTransactionOperation = @($invalidTransactionStatus.operations |
            Where-Object operationId -ceq $v3OperationId)
        Assert-True ($invalidTransactionOperation.Count -eq 1 -and
            -not $invalidTransactionOperation[0].schemaCompatible -and
            $v3OperationId -cin @($invalidTransactionStatus.migrationReadiness.blockingRecords)) `
            ("非法 transaction case {0} 必须逐项阻断" -f $invalidTransactionCase.name)
    }
    [IO.File]::WriteAllText(
        $v3Apply.transactionPath,
        $validV3TransactionText,
        [Text.UTF8Encoding]::new($false))

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteSchemaCompatibility'
        slices = 10
    }
} finally {
    Remove-TestTree -Path $fixtureRoot
}
