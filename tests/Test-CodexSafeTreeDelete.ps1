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
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'

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
$policy = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 1
    entries = @([pscustomobject][ordered]@{
        id = 'fixture'
        capabilityRoot = $fixtureRoot
        minimumDescendantDepth = 1
        deniedExactPaths = @($evidenceRoot)
    })
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

    $rootDeleteError = Assert-Throws -Message 'capability root 自身必须拒绝' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath $fixtureRoot `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rootDeleteError -match '严格后代') 'root 删除拒绝必须返回稳定原因'

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
