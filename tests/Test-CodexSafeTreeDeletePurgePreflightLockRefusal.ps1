[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

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
        -Name 'purge preflight lock test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'purge preflight lock test cleanup'
}

$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'purgepreflightlock'
$evidenceRoot = Join-Path $scratchRoot 'evidence'
$policyPath = Join-Path $scratchRoot 'policy.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$lock = $null

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @([pscustomobject][ordered]@{
            id = 'purge-preflight-lock-fixture'
            capabilityRoot = $scratchRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            deniedExactPaths = @($evidenceRoot)
        })
    }
    [IO.File]::WriteAllBytes($policyPath, $utf8.GetBytes(($policy | ConvertTo-Json -Depth 16)))

    $targetPath = Join-Path $scratchRoot 'target'
    [void][IO.Directory]::CreateDirectory($targetPath)
    [IO.File]::WriteAllText((Join-Path $targetPath 'locked-payload.txt'), 'purge-preflight-lock', $utf8)

    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $scratchRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ([bool]$apply.quarantined) 'Apply 必须隔离目标'
    $quarantinePayload = Join-Path ([string]$apply.quarantinePath) 'locked-payload.txt'
    Assert-True ([IO.File]::Exists($quarantinePayload)) '隔离 payload 必须存在'

    # 在第一次 Purge 之前就持锁（FileShare.Read，不共享 Delete）：
    # 预检快照的 lease 必然撞 Win32 32，两次调用都必须返回同一份结构化拒绝，
    # 而不是裸异常（2026-10-27 host-live issue21-fail-purge-forwarded 现场）。
    $lock = [IO.File]::Open($quarantinePayload, 'Open', 'Read', 'Read')
    $purgeArguments = @{
        Mode = 'Purge'
        TransactionPath = [string]$apply.transactionPath
        ApprovedTransactionSha256 = [string]$apply.transactionSha256
        ConfirmPurge = $true
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
        Json = $true
    }
    foreach ($attempt in @(1, 2)) {
        $purge = (& $entryPath @purgeArguments) | ConvertFrom-Json -Depth 16
        Assert-True ($purge.purged -eq $false) "第 $attempt 次持锁 Purge 必须 purged=false"
        Assert-True ([string]$purge.refusalReason -ceq 'leaf-delete-failed') (
            "第 $attempt 次持锁 Purge 必须结构化返回 leaf-delete-failed（预检冲突不得抛裸异常）")
        Assert-True ($null -ne $purge.metrics) "第 $attempt 次持锁 Purge 必须带 metrics"
        Assert-True ([bool]$purge.recoverable) '预检冲突不得改写 transaction：仍可恢复'
        Assert-True ([IO.File]::Exists($quarantinePayload)) "第 $attempt 次拒绝后 payload 必须仍在"
    }

    $lock.Dispose()
    $lock = $null
    $released = (& $entryPath @purgeArguments) | ConvertFrom-Json -Depth 16
    Assert-True ([bool]$released.purged) '释锁后同一 transaction 必须能 Purge 成功'
    Assert-True (-not [IO.Directory]::Exists([string]$apply.quarantinePath)) 'Purge 成功后隔离目录必须消失'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeletePurgePreflightLockRefusal'
        lockedAttemptsStructured = 2
        releasedPurgeSucceeded = $true
    }
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    Remove-TestTree -Path $scratchRoot
}
