#requires -Version 7.6
[CmdletBinding()]
param([int]$FileCount = 2000, [int]$BytesPerFile = 4096)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

$fixtureRoot = Join-Path $evidenceHome 'profile-stream-fixtures'
$targetPath = Join-Path $fixtureRoot 'candidate'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
[void][IO.Directory]::CreateDirectory($evidenceRoot)

$policy = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(
        [pscustomobject][ordered]@{
            id = 'issue32-stream-profile'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        }
    )
}
[IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

if ([IO.Directory]::Exists($targetPath)) {
    $old = Get-CodexHookCapabilityDirectoryTreeSnapshot -Path $targetPath -CapabilityRoot $fixtureRoot -AllowedExactPaths @($targetPath) -Name 'stream profile cleanup'
    Remove-CodexHookCapabilityDirectoryTree -Path $targetPath -CapabilityRoot $fixtureRoot -AllowedExactPaths @($targetPath) -ExpectedRootIdentity @($old.rootIdentity) -ExpectedTreeManifest $old -Scope 'stream profile cleanup'
}

$payload = [byte[]]::new($BytesPerFile)
$directoryCount = [Math]::Max(1, [int][Math]::Ceiling($FileCount / 100.0))
$written = 0
for ($d = 0; $d -lt $directoryCount -and $written -lt $FileCount; $d++) {
    $dir = Join-Path $targetPath ('d{0:D3}' -f $d)
    [void][IO.Directory]::CreateDirectory($dir)
    $batch = [Math]::Min(100, $FileCount - $written)
    for ($f = 0; $f -lt $batch; $f++) {
        [IO.File]::WriteAllBytes((Join-Path $dir ('f{0:D2}.bin' -f $f)), $payload)
        $written++
    }
}

$plan = New-CodexSafeTreeDeletePlan -TargetPath $targetPath -CapabilityRoot $fixtureRoot -PolicyPath $policyPath -EvidenceRoot $evidenceRoot
$planDoc = Get-Content -Raw -LiteralPath ([string]$plan.planPath) | ConvertFrom-Json -Depth 128 -DateKind String
$identities = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $planDoc
$streamSet = Read-CodexSafeTreeDeletePlanStreamSet -Plan $planDoc
$cache = [CodexSafeTreeDelete.SessionHashCache]::new()
$reuse = [CodexSafeTreeDelete.ApplySessionHashCoordinator]::new($identities, $cache, $true)
$baseline = [CodexSafeTreeDelete.ApplySessionHashCoordinator]::new($identities, $cache, $false)

$snap1 = Measure-Command {
    $script:t1 = Get-CodexSafeTreeDeleteApplyTreeSnapshot -Path $targetPath -CapabilityRoot $fixtureRoot -AllowedExactPaths @($targetPath) -Coordinator $reuse -Name 'stream profile snap1'
}
$snap2 = Measure-Command {
    $script:t2 = Get-CodexSafeTreeDeleteApplyTreeSnapshot -Path $targetPath -CapabilityRoot $fixtureRoot -AllowedExactPaths @($targetPath) -Coordinator $reuse -Name 'stream profile snap2'
}
$stream = Measure-Command {
    Assert-CodexSafeTreeDeleteLiveStreamSet -PlanStreamSet $streamSet -TreeManifest $script:t2 -TreePath $targetPath -Phase apply
}
$snap3 = Measure-Command {
    [void](Get-CodexSafeTreeDeleteApplyTreeSnapshot -Path $targetPath -CapabilityRoot $fixtureRoot -AllowedExactPaths @($targetPath) -Coordinator $reuse -Name 'stream profile snap3')
}
$base1 = Measure-Command {
    [void](Get-CodexSafeTreeDeleteApplyTreeSnapshot -Path $targetPath -CapabilityRoot $fixtureRoot -AllowedExactPaths @($targetPath) -Coordinator $baseline -Name 'stream profile base')
}

$result = [ordered]@{
    fileCount = $FileCount
    snap1ReuseMs = [Math]::Round($snap1.TotalMilliseconds, 1)
    snap2ReuseHotMs = [Math]::Round($snap2.TotalMilliseconds, 1)
    liveStreamSetMs = [Math]::Round($stream.TotalMilliseconds, 1)
    snap3ReuseHotMs = [Math]::Round($snap3.TotalMilliseconds, 1)
    snapBaselineMs = [Math]::Round($base1.TotalMilliseconds, 1)
    cacheCountAfterSnap1 = $cache.Count
}
[IO.File]::WriteAllText((Join-Path $evidenceHome 'profile-stream.json'), ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json
