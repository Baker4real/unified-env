Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = 'D:\Codex\projects\统一环境'
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

$root = Join-Path $projectRoot 'reports\safe-tree-delete-issue32-20260817\smoke'
$target = Join-Path $root 'candidate'
$evidence = Join-Path $root 'evidence'
$policyPath = Join-Path $root 'policy.json'
[void][IO.Directory]::CreateDirectory((Join-Path $target 'nested'))
[void][IO.Directory]::CreateDirectory($evidence)
[IO.File]::WriteAllText((Join-Path $target 'payload.txt'), 'smoke-payload', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $target 'nested\child.bin'), 'smoke-child', [Text.UTF8Encoding]::new($false))
$policy = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(
        [pscustomobject][ordered]@{
            id = 'apply-hash-reuse-smoke'
            capabilityRoot = $root
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidence)
        }
    )
}
[IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

function Remove-TestTree {
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path -CapabilityRoot $parent -AllowedExactPaths @($Path) `
        -Name 'issue32 smoke cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path -CapabilityRoot $parent -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'issue32 smoke cleanup'
}

try {
    $plan = New-CodexSafeTreeDeletePlan -TargetPath $target -CapabilityRoot $root -PolicyPath $policyPath -EvidenceRoot $evidence
    $cache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $apply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidence `
        -SessionHashCacheForTest $cache
    if (-not $apply.quarantined) { throw 'smoke Apply 未隔离' }
    $dummy = $null
    $planDocument = Get-Content -Raw -LiteralPath ([string]$plan.planPath) | ConvertFrom-Json -Depth 32 -DateKind String
    $identities = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $planDocument
    foreach ($key in @($identities.Keys)) {
        if ($cache.TryGet($identities[$key], [ref]$dummy)) {
            throw 'smoke Apply 完成后 cache 未清理'
        }
    }
    Write-Output ('smoke-ok quarantined=' + $apply.quarantined + ' elapsedMs=' + $apply.metrics.elapsedMs)
    Remove-TestTree -Path ([string]$apply.quarantinePath)
} finally {
    if ([IO.Directory]::Exists($root)) {
        Remove-TestTree -Path $root
    }
}
