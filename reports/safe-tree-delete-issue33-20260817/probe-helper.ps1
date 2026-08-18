Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = 'D:\Codex\projects\统一环境'
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$cmd = Get-Command -Name Invoke-CodexSafeTreeDeletePurgeFileHash -ErrorAction SilentlyContinue
if ($null -eq $cmd) { throw 'helper missing' }
$root = Join-Path $projectRoot 'reports\safe-tree-delete-issue33-20260817\probe-helper-tmp'
$target = Join-Path $root 'candidate'
$evidence = Join-Path $root 'evidence'
$policy = Join-Path $root 'policy.json'
[void][IO.Directory]::CreateDirectory((Join-Path $target 'nested'))
[void][IO.Directory]::CreateDirectory($evidence)
[IO.File]::WriteAllText((Join-Path $target 'payload.txt'), 'probe-payload', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $target 'nested\child.bin'), 'probe-child', [Text.UTF8Encoding]::new($false))
$policyObject = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(
        [pscustomobject][ordered]@{
            id = 'purge-hash-probe'
            capabilityRoot = $root
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidence)
        }
    )
}
[IO.File]::WriteAllText($policy, ($policyObject | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
try {
    $plan = New-CodexSafeTreeDeletePlan -TargetPath $target -CapabilityRoot $root -PolicyPath $policy -EvidenceRoot $evidence
    $document = Get-Content -Raw -LiteralPath ([string]$plan.planPath) | ConvertFrom-Json -Depth 128 -DateKind String
    $map = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $document
    $cache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $first = Invoke-CodexSafeTreeDeletePurgeFileHash -LiteralPath (Join-Path $target 'payload.txt') -RelativePath 'payload.txt' -ExpectedIdentities $map -SessionCache $cache
    $second = Invoke-CodexSafeTreeDeletePurgeFileHash -LiteralPath (Join-Path $target 'payload.txt') -RelativePath 'payload.txt' -ExpectedIdentities $map -SessionCache $cache
    $other = [CodexSafeTreeDelete.SessionHashCache]::new()
    $third = Invoke-CodexSafeTreeDeletePurgeFileHash -LiteralPath (Join-Path $target 'payload.txt') -RelativePath 'payload.txt' -ExpectedIdentities $map -SessionCache $other
    if ($first.Length -ne 32) { throw 'first hash not 32 bytes' }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$first, [byte[]]$second)) { throw 'same-invocation hit mismatch' }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$first, [byte[]]$third)) { throw 'cross-invocation hash mismatch' }
    Write-Output 'HELPER_OK'
    exit 0
} finally {
    if ([IO.Directory]::Exists($root)) {
        $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot -Path $root -CapabilityRoot (Split-Path -Parent $root) -AllowedExactPaths @($root) -Name 'probe cleanup snapshot'
        Remove-CodexHookCapabilityDirectoryTree -Path $root -CapabilityRoot (Split-Path -Parent $root) -AllowedExactPaths @($root) -ExpectedRootIdentity @($snapshot.rootIdentity) -ExpectedTreeManifest $snapshot -Scope 'probe cleanup'
    }
}
