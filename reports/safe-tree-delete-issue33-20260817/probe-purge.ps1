Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = 'D:\Codex\projects\统一环境'
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$root = Join-Path $projectRoot 'reports\safe-tree-delete-issue33-20260817\probe-purge-tmp'
$target = Join-Path $root 'candidate'
$nested = Join-Path $target 'nested'
$evidence = Join-Path $root 'evidence'
$policy = Join-Path $root 'policy.json'
[void][IO.Directory]::CreateDirectory($nested)
[void][IO.Directory]::CreateDirectory($evidence)
[IO.File]::WriteAllText((Join-Path $target 'payload.txt'), 'purge-probe-payload', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $nested 'child.bin'), 'purge-probe-child', [Text.UTF8Encoding]::new($false))
$policyObject = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(
        [pscustomobject][ordered]@{
            id = 'purge-hash-probe-full'
            capabilityRoot = $root
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidence)
        }
    )
}
[IO.File]::WriteAllText($policy, ($policyObject | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$apply = $null
try {
    $plan = New-CodexSafeTreeDeletePlan -TargetPath $target -CapabilityRoot $root -PolicyPath $policy -EvidenceRoot $evidence
    $apply = Invoke-CodexSafeTreeDeleteQuarantine -PlanPath ([string]$plan.planPath) -ApprovedPlanSha256 ([string]$plan.planSha256) -PolicyPath $policy -EvidenceRoot $evidence
    if (-not $apply.quarantined) { throw 'apply failed' }
    $cache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $hits = [Collections.Generic.List[bool]]::new()
    $purge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$apply.transactionSha256) `
        -PolicyPath $policy `
        -EvidenceRoot $evidence `
        -SessionHashCacheForTest $cache `
        -BeforeDirectoryTreeDeleteForTest {
            param($Quarantine)
            $identity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath (Join-Path $Quarantine 'payload.txt')
            $hash = $null
            $hits.Add([bool]$cache.TryGet($identity, [ref]$hash))
        }
    if (-not $purge.purged) { throw 'purge failed' }
    if ($hits.Count -ne 1 -or -not $hits[0]) { throw 'snapshot did not populate cache before delete' }
    $after = $null
    $live = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath (Join-Path $projectRoot 'CONTEXT.md')
    if ($cache.TryGet($live, [ref]$after)) { throw 'unexpected leftover cache entry' }
    if ([IO.Directory]::Exists([string]$apply.quarantinePath)) { throw 'quarantine still exists' }
    if (-not [IO.File]::Exists([string]$purge.leafDispositionsPath)) { throw 'missing dispositions' }
    Write-Output 'PURGE_OK'
    exit 0
} catch {
    Write-Output ($_ | Out-String)
    if ($_.Exception) { Write-Output $_.Exception.ToString() }
    exit 1
} finally {
    foreach ($path in @($target, $(if ($null -ne $apply) { [string]$apply.quarantinePath }), $root)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and [IO.Directory]::Exists($path)) {
            $parent = Split-Path -Parent $path
            $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot -Path $path -CapabilityRoot $parent -AllowedExactPaths @($path) -Name 'probe purge cleanup snapshot'
            Remove-CodexHookCapabilityDirectoryTree -Path $path -CapabilityRoot $parent -AllowedExactPaths @($path) -ExpectedRootIdentity @($snapshot.rootIdentity) -ExpectedTreeManifest $snapshot -Scope 'probe purge cleanup'
        }
    }
}
