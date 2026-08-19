#requires -Version 7.6
[CmdletBinding()]
param(
    [int]$FileCount = 200,
    [int]$BytesPerFile = 4096,
    [int]$PrimitiveIterations = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$fixtureRoot = Join-Path $evidenceHome 'profile-fixtures'
$targetPath = Join-Path $fixtureRoot 'candidate'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'

function New-ProfilePolicy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$DeniedPath
    )

    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'issue32-profile-20260819'
                capabilityRoot = $CapabilityRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($DeniedPath)
            }
        )
    }
    [IO.File]::WriteAllText(
        $Path,
        ($policy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
}

function Remove-ProfileTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'issue32 profile cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'issue32 profile cleanup'
}

function New-ProfileTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$FileCount,
        [Parameter(Mandatory)][int]$BytesPerFile
    )

    if ([IO.Directory]::Exists($Path)) {
        Remove-ProfileTree -Path $Path
    }
    $directoryCount = [Math]::Max(1, [int][Math]::Ceiling($FileCount / 100.0))
    $payload = [byte[]]::new($BytesPerFile)
    for ($index = 0; $index -lt $payload.Length; $index++) {
        $payload[$index] = [byte](($index + 7) % 251)
    }
    $written = 0
    for ($directoryIndex = 0; $directoryIndex -lt $directoryCount -and $written -lt $FileCount; $directoryIndex++) {
        $directory = Join-Path $Path ('d{0:D3}' -f $directoryIndex)
        [void][IO.Directory]::CreateDirectory($directory)
        $remaining = $FileCount - $written
        $batch = [Math]::Min(100, $remaining)
        for ($fileIndex = 0; $fileIndex -lt $batch; $fileIndex++) {
            $filePath = Join-Path $directory ('f{0:D2}.bin' -f $fileIndex)
            [IO.File]::WriteAllBytes($filePath, $payload)
            $written += 1
        }
    }
    return [pscustomobject]@{
        FileCount = $written
        FirstFile = (Join-Path (Join-Path $Path 'd000') 'f00.bin')
    }
}

function Measure-ActionMs {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][int]$Iterations
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        & $Action | Out-Null
    }
    $sw.Stop()
    return [pscustomobject]@{
        totalMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 3)
        perCallUs = [Math]::Round(($sw.Elapsed.TotalMilliseconds * 1000.0) / $Iterations, 1)
        iterations = $Iterations
    }
}

. $hostSafetyLibraryPath
. $libraryPath

[void][IO.Directory]::CreateDirectory($fixtureRoot)
[void][IO.Directory]::CreateDirectory($evidenceRoot)
New-ProfilePolicy -Path $policyPath -CapabilityRoot $fixtureRoot -DeniedPath $evidenceRoot
$tree = New-ProfileTree -Path $targetPath -FileCount $FileCount -BytesPerFile $BytesPerFile
$sample = [string]$tree.FirstFile

$sampleParent = Split-Path -Parent $sample
$parentGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($fixtureRoot, $sampleParent, $false)
try {
    $identityPath = Measure-ActionMs -Iterations $PrimitiveIterations -Action {
        [void][CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($sample)
    }

    $lease = $parentGuard.AcquireSafeTreeDeleteFileLease($sample, $false)
    try {
        $leaseHandleType = $lease.GetType()
        $handleProp = $leaseHandleType.GetProperty('SafeFileHandle')
        $dangerousMethod = $leaseHandleType.GetMethod('DangerousGetHandle')
        $identityFromLeaseHandleUs = $null
        if ($null -ne $handleProp) {
            $safeHandle = $handleProp.GetValue($lease)
            $identityFromLeaseHandle = Measure-ActionMs -Iterations $PrimitiveIterations -Action {
                [void][CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($safeHandle)
            }
            $identityFromLeaseHandleUs = $identityFromLeaseHandle
        }

        $hashFromLease = Measure-ActionMs -Iterations $PrimitiveIterations -Action {
            [void]$lease.ComputeSha256FromHandle()
        }

        $cache = [CodexSafeTreeDelete.SessionHashCache]::new()
        $expected = [CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($sample)
        $hashBytes = $lease.ComputeSha256FromHandle()
        $cache.Set($expected, $hashBytes)
        $cacheHit = Measure-ActionMs -Iterations $PrimitiveIterations -Action {
            $cached = $null
            [void]$cache.TryGet($expected, [ref]$cached)
        }
        $identityEquals = Measure-ActionMs -Iterations $PrimitiveIterations -Action {
            $current = [CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($sample)
            [void]($current -eq $expected)
        }
    } finally {
        $lease.Dispose()
    }

    $leaseAcquire = Measure-ActionMs -Iterations $PrimitiveIterations -Action {
        $temp = $parentGuard.AcquireSafeTreeDeleteFileLease($sample, $false)
        $temp.Dispose()
    }
} finally {
    $parentGuard.Dispose()
}

$parentGuardAcquire = Measure-ActionMs -Iterations $PrimitiveIterations -Action {
    $g = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($fixtureRoot, $sampleParent, $false)
    $g.Dispose()
}

$snapshotNoProvider = Measure-Command {
    [void](Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $targetPath `
        -CapabilityRoot $fixtureRoot `
        -AllowedExactPaths @($targetPath) `
        -Name 'issue32 profile snapshot baseline')
}

$emptyCache = [CodexSafeTreeDelete.SessionHashCache]::new()
$identMap = [Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]::new([StringComparer]::Ordinal)
$firstRel = 'd000/f00.bin'
$identMap[$firstRel] = [CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($sample)
$provider = New-CodexSafeTreeDeleteApplyFileHashProvider -ExpectedIdentities $identMap -SessionCache $emptyCache
# Provider needs all files; populate from a no-provider snapshot first.
$seedSnap = Get-CodexHookCapabilityDirectoryTreeSnapshot `
    -Path $targetPath `
    -CapabilityRoot $fixtureRoot `
    -AllowedExactPaths @($targetPath) `
    -Name 'issue32 profile snapshot seed'
foreach ($entry in @($seedSnap.entries)) {
    if ([string]$entry.kind -cne 'file') { continue }
    $abs = Join-Path $targetPath (([string]$entry.relativePath) -replace '/', [IO.Path]::DirectorySeparatorChar)
    $identMap[[string]$entry.relativePath] = [CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($abs)
}
$reuseProvider = New-CodexSafeTreeDeleteApplyFileHashProvider -ExpectedIdentities $identMap -SessionCache $emptyCache
$snapshotReuseCold = Measure-Command {
    [void](Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $targetPath `
        -CapabilityRoot $fixtureRoot `
        -AllowedExactPaths @($targetPath) `
        -FileContentHashProvider $reuseProvider `
        -Name 'issue32 profile snapshot reuse-cold')
}

$hotCache = [CodexSafeTreeDelete.SessionHashCache]::new()
foreach ($entry in @($seedSnap.entries)) {
    if ([string]$entry.kind -cne 'file') { continue }
    $abs = Join-Path $targetPath (([string]$entry.relativePath) -replace '/', [IO.Path]::DirectorySeparatorChar)
    $id = $identMap[[string]$entry.relativePath]
    $bytes = [Convert]::FromHexString([string]$entry.sha256)
    $hotCache.Set($id, $bytes)
}
$hotProvider = New-CodexSafeTreeDeleteApplyFileHashProvider -ExpectedIdentities $identMap -SessionCache $hotCache
$snapshotReuseHot = Measure-Command {
    [void](Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $targetPath `
        -CapabilityRoot $fixtureRoot `
        -AllowedExactPaths @($targetPath) `
        -FileContentHashProvider $hotProvider `
        -Name 'issue32 profile snapshot reuse-hot')
}

$planReuse = New-CodexSafeTreeDeletePlan `
    -TargetPath $targetPath `
    -CapabilityRoot $fixtureRoot `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot
$applyReuse = Invoke-CodexSafeTreeDeleteQuarantine `
    -PlanPath ([string]$planReuse.planPath) `
    -ApprovedPlanSha256 ([string]$planReuse.planSha256) `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot
Remove-ProfileTree -Path ([string]$applyReuse.quarantinePath)

$treeBaseline = New-ProfileTree -Path $targetPath -FileCount $FileCount -BytesPerFile $BytesPerFile
$planBaseline = New-CodexSafeTreeDeletePlan `
    -TargetPath $targetPath `
    -CapabilityRoot $fixtureRoot `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot
$applyBaseline = Invoke-CodexSafeTreeDeleteQuarantine `
    -PlanPath ([string]$planBaseline.planPath) `
    -ApprovedPlanSha256 ([string]$planBaseline.planSha256) `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot `
    -DisableApplyHashReuseForTest
Remove-ProfileTree -Path ([string]$applyBaseline.quarantinePath)

$result = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue32-profile'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    fileCount = $FileCount
    bytesPerFile = $BytesPerFile
    primitiveIterations = $PrimitiveIterations
    primitives = [ordered]@{
        identityV2Path = $identityPath
        identityFromLeaseHandle = $identityFromLeaseHandleUs
        leaseHandlePropertyPresent = ($null -ne $handleProp)
        leaseDangerousGetHandlePresent = ($null -ne $dangerousMethod)
        computeSha256FromLease4kb = $hashFromLease
        sessionCacheTryGet = $cacheHit
        identityPathPlusEquals = $identityEquals
        leaseAcquireDispose = $leaseAcquire
        parentGuardAcquireDispose = $parentGuardAcquire
    }
    snapshots = [ordered]@{
        noProviderMs = [Math]::Round($snapshotNoProvider.TotalMilliseconds, 1)
        reuseColdMs = [Math]::Round($snapshotReuseCold.TotalMilliseconds, 1)
        reuseHotMs = [Math]::Round($snapshotReuseHot.TotalMilliseconds, 1)
        reuseHotVsNoProvider = [Math]::Round($snapshotNoProvider.TotalMilliseconds / [Math]::Max(1.0, $snapshotReuseHot.TotalMilliseconds), 3)
        reuseColdVsNoProvider = [Math]::Round($snapshotNoProvider.TotalMilliseconds / [Math]::Max(1.0, $snapshotReuseCold.TotalMilliseconds), 3)
    }
    apply = [ordered]@{
        reuseElapsedMs = [long]$applyReuse.metrics.elapsedMs
        baselineElapsedMs = [long]$applyBaseline.metrics.elapsedMs
        speedup = [Math]::Round(
            ([double]$applyBaseline.metrics.elapsedMs) / [Math]::Max(1.0, [double]$applyReuse.metrics.elapsedMs),
            3)
        reuseBytesHashed = [long]$applyReuse.metrics.bytesHashed
        baselineBytesHashed = [long]$applyBaseline.metrics.bytesHashed
    }
}

$outPath = Join-Path $evidenceHome 'profile.json'
[IO.File]::WriteAllText(
    $outPath,
    ($result | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 8
Write-Output "WROTE $outPath"
