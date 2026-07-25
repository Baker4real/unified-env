[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$productionEntryPath = Join-Path $projectRoot 'scripts\Invoke-CodexSafeTreeDelete.ps1'
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$policyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHookPolicy.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$rootTargetParent = Join-Path $fixtureRoot 'root-target-parent'
$rootTargetPath = Join-Path $rootTargetParent 'build-output'
$rollbackRootParent = Join-Path $fixtureRoot 'rollback-root-parent'
$rollbackRootTarget = Join-Path $rollbackRootParent 'build-output'
$rollbackSiblingPath = Join-Path $rollbackRootParent 'must-survive.txt'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$invalidProjectRootPolicyPath = Join-Path $fixtureRoot 'invalid-project-root-policy.json'
$invalidStateRootPolicyPath = Join-Path $fixtureRoot 'invalid-state-root-policy.json'

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
        -Name 'safe-delete test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete test cleanup'
}

. $policyLibraryPath

[void][IO.Directory]::CreateDirectory($targetPath)
$payloadPath = Join-Path $targetPath 'payload.txt'
[IO.File]::WriteAllText($payloadPath, 'keep-until-apply', [Text.UTF8Encoding]::new($false))
[IO.File]::SetAttributes($payloadPath, [IO.FileAttributes]::ReadOnly)
[void][IO.Directory]::CreateDirectory($rootTargetPath)
[IO.File]::WriteAllText((Join-Path $rootTargetPath 'root-payload.txt'), 'root-target', [Text.UTF8Encoding]::new($false))
[void][IO.Directory]::CreateDirectory($rollbackRootTarget)
[IO.File]::WriteAllText((Join-Path $rollbackRootTarget 'rollback-payload.txt'), 'rollback-target', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($rollbackSiblingPath, 'must-survive', [Text.UTF8Encoding]::new($false))
$policy = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 2
    entries = @(
        [pscustomobject][ordered]@{
            id = 'fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        },
        [pscustomobject][ordered]@{
            id = 'fixture-root-target'
            capabilityRoot = $rootTargetPath
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        },
        [pscustomobject][ordered]@{
            id = 'fixture-root-rollback'
            capabilityRoot = $rollbackRootTarget
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        }
    )
}
[IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

try {
    Assert-True ([IO.File]::Exists($productionEntryPath)) '生产安全删除 CLI 必须存在'
    Assert-True ([IO.File]::Exists($entryPath)) '安全删除 fixture CLI 必须存在'
    $productionCommand = Get-Command -Name $productionEntryPath
    foreach ($forbiddenParameter in @('Fixture', 'FixturePolicyPath', 'FixtureEvidenceRoot', 'PolicyPath', 'EvidenceRoot')) {
        Assert-True (-not $productionCommand.Parameters.ContainsKey($forbiddenParameter)) "生产 CLI 不得暴露 $forbiddenParameter"
    }
    $planResult = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot

    Assert-True ($planResult.planned -eq $true) 'Plan 必须返回 planned=true'
    Assert-True ([IO.File]::Exists([string]$planResult.planPath)) 'Plan 必须发布受管计划文件'
    Assert-True ([string]$planResult.planSha256 -match '^[0-9a-f]{64}$') 'Plan 必须返回精确 SHA-256 capability'
    Assert-True ([IO.Directory]::Exists($targetPath)) 'Plan 必须保持目标只读不变'

    $unconfirmedApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$planResult.planPath) `
        -ApprovedPlanSha256 ([string]$planResult.planSha256) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($unconfirmedApply.refusalReason -ceq 'confirm-apply-required') 'Apply 缺少确认必须结构化拒绝'
    Assert-True ([IO.Directory]::Exists($targetPath)) '未确认 Apply 不得修改目标'

    $wrongHashError = Assert-Throws -Message '错误计划哈希必须失败关闭' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$planResult.planPath) `
            -ApprovedPlanSha256 ('0' * 64) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($wrongHashError -match 'hash|SHA-256|尚未实现') '错误哈希拒绝必须返回稳定原因'
    Assert-True ([IO.Directory]::Exists($targetPath)) '错误计划哈希不得修改目标'

    $applyResult = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$planResult.planPath) `
        -ApprovedPlanSha256 ([string]$planResult.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($applyResult.quarantined -eq $true) 'Apply 必须返回 quarantined=true'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) 'Apply 必须原子移除原目标命名'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) 'Apply 必须保留可恢复隔离目录'
    $quarantinedPayload = Join-Path ([string]$applyResult.quarantinePath) 'payload.txt'
    Assert-True ([IO.File]::ReadAllText($quarantinedPayload) -ceq 'keep-until-apply') '隔离目录必须完整保留 payload'
    Assert-True (([IO.File]::GetAttributes($quarantinedPayload) -band [IO.FileAttributes]::ReadOnly) -ne 0) '隔离不得改写 ReadOnly 属性'

    $unconfirmedPurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($unconfirmedPurge.refusalReason -ceq 'confirm-purge-required') 'Purge 缺少确认必须结构化拒绝'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) '未确认 Purge 不得清理隔离目录'

    $wrongTransactionError = Assert-Throws -Message '错误 transaction 哈希必须失败关闭' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 ('0' * 64) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($wrongTransactionError -match 'hash|SHA-256|尚未实现') '错误 transaction 哈希拒绝必须返回稳定原因'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) '错误 transaction 哈希不得清理隔离目录'

    $purgeResult = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($purgeResult.purged -eq $true) 'Purge 必须返回 purged=true'
    Assert-True (-not [IO.Directory]::Exists([string]$applyResult.quarantinePath)) 'Purge 必须清理精确隔离目录'
    Assert-True ($purgeResult.recoverable -eq $false) 'Purge 后必须明确标记不可恢复'

    $rootParentEscapeError = Assert-Throws -Message 'minimumDescendantDepth=0 不得授权父目录' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath $rootTargetParent `
            -CapabilityRoot $rootTargetPath `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rootParentEscapeError -match 'capability root 内') '精确 root 策略必须拒绝父目录逃逸'

    $rollbackPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $rollbackRootTarget `
        -CapabilityRoot $rollbackRootTarget `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $rollbackPlanDocument = Get-Content -Raw -LiteralPath ([string]$rollbackPlan.planPath) | ConvertFrom-Json -Depth 128
    $rollbackQuarantinePath = Join-Path `
        $rollbackRootParent `
        ('.codex-safe-delete-{0}.quarantine' -f ([string]$rollbackPlanDocument.generationId))
    $rollbackError = Assert-Throws -Message 'root-target rename 后故障必须回滚' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$rollbackPlan.planPath) `
            -ApprovedPlanSha256 ([string]$rollbackPlan.planSha256) `
            -ConfirmApply `
            -FixtureFailAfterRename `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rollbackError -match 'fixture failure after rename') 'root-target 故障注入必须返回原始失败'
    Assert-True ([IO.Directory]::Exists($rollbackRootTarget)) 'root-target rollback 必须恢复原目录'
    Assert-True (-not [IO.Directory]::Exists($rollbackQuarantinePath)) 'root-target rollback 不得残留 quarantine'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $rollbackRootTarget 'rollback-payload.txt')) -ceq 'rollback-target'
    ) 'root-target rollback 必须完整恢复 payload'
    Assert-True ([IO.File]::ReadAllText($rollbackSiblingPath) -ceq 'must-survive') 'root-target rollback 不得触及同级文件'
    $rollbackTransactionPath = Join-Path (Split-Path -Parent ([string]$rollbackPlan.planPath)) 'transaction.json'
    $rollbackTransaction = Get-Content -Raw -LiteralPath $rollbackTransactionPath | ConvertFrom-Json -Depth 32
    Assert-True ($rollbackTransaction.status -ceq 'rolled-back') 'root-target rollback 必须发布 rolled-back transaction'

    $rootPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $rootTargetPath `
        -CapabilityRoot $rootTargetPath `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($rootPlan.planned -eq $true) 'minimumDescendantDepth=0 必须允许精确 capability root 计划'
    $rootApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$rootPlan.planPath) `
        -ApprovedPlanSha256 ([string]$rootPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($rootApply.quarantined -eq $true) '精确 capability root 必须可隔离'
    Assert-True (-not [IO.Directory]::Exists($rootTargetPath)) '精确 capability root 隔离后原路径必须不存在'
    Assert-True ([IO.Directory]::Exists([string]$rootApply.quarantinePath)) '精确 capability root 必须保留同父隔离目录'
    $rootPurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$rootApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$rootApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($rootPurge.purged -eq $true) '精确 capability root 必须可完成 purge'
    Assert-True (-not [IO.Directory]::Exists([string]$rootApply.quarantinePath)) '精确 capability root purge 后不得残留隔离目录'

    $rootDeleteError = Assert-Throws -Message 'capability root 自身必须拒绝' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath $fixtureRoot `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rootDeleteError -match '最小后代深度') 'minimumDescendantDepth=1 必须继续拒绝 root 删除'

    $invalidProjectRootPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 2
        entries = @([pscustomobject][ordered]@{
            id = 'invalid-project-root'
            capabilityRoot = 'D:\Codex\projects\unsafe-workspace'
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $invalidProjectRootPolicyPath,
        ($invalidProjectRootPolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $projectRootPolicyError = Assert-Throws -Message 'minimumDescendantDepth=0 不得授权项目根' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath 'D:\Codex\projects\unsafe-workspace' `
            -CapabilityRoot 'D:\Codex\projects\unsafe-workspace' `
            -FixturePolicyPath $invalidProjectRootPolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True `
        ($projectRootPolicyError -match '必须位于项目根之下') `
        "项目根授权拒绝必须返回稳定原因，实际为：$projectRootPolicyError"

    $invalidStateRootPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 2
        entries = @([pscustomobject][ordered]@{
            id = 'invalid-state-root'
            capabilityRoot = 'D:\Codex\.codex\skills'
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $invalidStateRootPolicyPath,
        ($invalidStateRootPolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $stateRootPolicyError = Assert-Throws -Message 'depth=0 不得授权 Codex 状态根' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath 'D:\Codex\.codex\skills' `
            -CapabilityRoot 'D:\Codex\.codex\skills' `
            -FixturePolicyPath $invalidStateRootPolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($stateRootPolicyError -match '必须位于项目根之下') '状态根授权必须失败关闭'

    $denylistError = Assert-Throws -Message 'denylist 子树必须拒绝' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath $evidenceRoot `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($denylistError -match 'denylist') 'denylist 拒绝必须返回稳定原因'

    $driftTarget = Join-Path $fixtureRoot 'drift-candidate'
    [void][IO.Directory]::CreateDirectory($driftTarget)
    $driftOriginal = Join-Path $driftTarget 'a-original.txt'
    [IO.File]::WriteAllText($driftOriginal, 'original', [Text.UTF8Encoding]::new($false))
    $driftPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $driftTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $driftAdded = Join-Path $driftTarget 'z-added-after-plan.txt'
    [IO.File]::WriteAllText($driftAdded, 'drift', [Text.UTF8Encoding]::new($false))
    $driftError = Assert-Throws -Message '计划后树漂移必须拒绝' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$driftPlan.planPath) `
            -ApprovedPlanSha256 ([string]$driftPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($driftError -match '漂移') '树漂移拒绝必须返回稳定原因'
    Assert-True ([IO.File]::Exists($driftOriginal) -and [IO.File]::Exists($driftAdded)) '树漂移拒绝必须发生在任何删除前'

    $junctionTarget = Join-Path $fixtureRoot 'junction-candidate'
    $junctionExternal = Join-Path $fixtureRoot 'junction-external'
    $junctionPath = Join-Path $junctionTarget 'linked'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    [void][IO.Directory]::CreateDirectory($junctionExternal)
    [IO.File]::WriteAllText((Join-Path $junctionExternal 'must-survive.txt'), 'outside', [Text.UTF8Encoding]::new($false))
    $junctionOutput = & $env:ComSpec /d /c mklink /J $junctionPath $junctionExternal 2>&1
    if ($LASTEXITCODE -ne 0) { throw "无法创建 safe-delete junction fixture：$junctionOutput" }
    try {
        $junctionError = Assert-Throws -Message 'reparse 子树必须拒绝' -Action {
            & $entryPath `
                -Mode Plan `
                -TargetPath $junctionTarget `
                -CapabilityRoot $fixtureRoot `
                -FixturePolicyPath $policyPath `
                -FixtureEvidenceRoot $evidenceRoot
        }
        Assert-True ($junctionError -match 'reparse') 'reparse 拒绝必须返回稳定原因'
        Assert-True ([IO.File]::Exists((Join-Path $junctionExternal 'must-survive.txt'))) 'reparse 拒绝不得触及外部内容'
    } finally {
        & $env:ComSpec /d /c rmdir $junctionPath | Out-Null
    }

    [pscustomobject][ordered]@{ ok = $true; suite = 'CodexSafeTreeDelete'; slices = 4 }
} finally {
    Remove-TestTree -Path $fixtureRoot
}
