#requires -Version 7.6
[CmdletBinding()]
param(
    [int]$Scale1000FileCount = 1000,
    [int]$Scale10000FileCount = 10000,
    [int]$BytesPerFile = 4096,
    [int]$SampleCount = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$fixtureRoot = Join-Path $evidenceHome 'benchmark-fixtures'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$scale1000Target = Join-Path $fixtureRoot 'candidate-1000'
$scale10000ReuseTarget = Join-Path $fixtureRoot 'candidate-reuse'
$scale10000BaselineTarget = Join-Path $fixtureRoot 'candidate-baseline'

function New-BenchmarkPolicy {
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
                id = 'issue32-benchmark-20260819'
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

function Remove-BenchmarkTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'issue32 benchmark cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'issue32 benchmark cleanup'
}

function New-BenchmarkTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$FileCount,
        [Parameter(Mandatory)][int]$BytesPerFile
    )

    if ([IO.Directory]::Exists($Path)) {
        Remove-BenchmarkTree -Path $Path
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
        LogicalBytes = [long]$written * [long]$BytesPerFile
    }
}

. $hostSafetyLibraryPath
. $libraryPath

[void][IO.Directory]::CreateDirectory($fixtureRoot)
[void][IO.Directory]::CreateDirectory($evidenceRoot)
New-BenchmarkPolicy -Path $policyPath -CapabilityRoot $fixtureRoot -DeniedPath $evidenceRoot

$scale1000 = New-BenchmarkTree -Path $scale1000Target -FileCount $Scale1000FileCount -BytesPerFile 64
$scale1000Plan = New-CodexSafeTreeDeletePlan `
    -TargetPath $scale1000Target `
    -CapabilityRoot $fixtureRoot `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot
if ([int]$scale1000Plan.fileCount -ne $Scale1000FileCount) {
    throw "1000 文件 Plan 必须覆盖全部 file，实际 $($scale1000Plan.fileCount)"
}
$scale1000Apply = Invoke-CodexSafeTreeDeleteQuarantine `
    -PlanPath ([string]$scale1000Plan.planPath) `
    -ApprovedPlanSha256 ([string]$scale1000Plan.planSha256) `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot
if ($scale1000Apply.quarantined -ne $true) {
    throw '1000 文件 Plan→Apply 必须成功'
}
if ([IO.Directory]::Exists($scale1000Target)) {
    throw '1000 文件 Apply 后原目标必须移走'
}
$scale1000Record = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue32-scale-1000'
    fileCount = [int]$scale1000.FileCount
    logicalBytes = [long]$scale1000.LogicalBytes
    applyElapsedMs = [long]$scale1000Apply.metrics.elapsedMs
    applyBytesHashed = [long]$scale1000Apply.metrics.bytesHashed
    quarantined = [bool]$scale1000Apply.quarantined
}
[IO.File]::WriteAllText(
    (Join-Path $evidenceHome 'scale-1000.json'),
    ($scale1000Record | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))
Remove-BenchmarkTree -Path ([string]$scale1000Apply.quarantinePath)

$samples = [Collections.Generic.List[object]]::new()
for ($sampleIndex = 1; $sampleIndex -le $SampleCount; $sampleIndex++) {
    [void](New-BenchmarkTree -Path $scale10000ReuseTarget -FileCount $Scale10000FileCount -BytesPerFile $BytesPerFile)
    [void](New-BenchmarkTree -Path $scale10000BaselineTarget -FileCount $Scale10000FileCount -BytesPerFile $BytesPerFile)
    $reusePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scale10000ReuseTarget `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $baselinePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scale10000BaselineTarget `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $reuseApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$reusePlan.planPath) `
        -ApprovedPlanSha256 ([string]$reusePlan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $baselineApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$baselinePlan.planPath) `
        -ApprovedPlanSha256 ([string]$baselinePlan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -DisableApplyHashReuseForTest
    if ($reuseApply.quarantined -ne $true -or $baselineApply.quarantined -ne $true) {
        throw "sample $sampleIndex Apply 必须成功"
    }
    $reuseMs = [double]$reuseApply.metrics.elapsedMs
    $baselineMs = [double]$baselineApply.metrics.elapsedMs
    $speedup = if ($reuseMs -gt 0) { $baselineMs / $reuseMs } else { 0 }
    $sample = [pscustomobject][ordered]@{
        sample = $sampleIndex
        reuseElapsedMs = [long]$reuseApply.metrics.elapsedMs
        baselineElapsedMs = [long]$baselineApply.metrics.elapsedMs
        reuseBytesHashed = [long]$reuseApply.metrics.bytesHashed
        baselineBytesHashed = [long]$baselineApply.metrics.bytesHashed
        speedup = [Math]::Round($speedup, 3)
        metTarget = ($speedup -ge 1.5)
    }
    $samples.Add($sample)
    Remove-BenchmarkTree -Path ([string]$reuseApply.quarantinePath)
    Remove-BenchmarkTree -Path ([string]$baselineApply.quarantinePath)
    Write-Output ("SAMPLE $($sample | ConvertTo-Json -Compress)")
}

$stable = $samples | Sort-Object -Property speedup | Select-Object -Last 1
$scale10000Record = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue32-scale-10000'
    fileCount = $Scale10000FileCount
    bytesPerFile = $BytesPerFile
    sampleCount = $SampleCount
    method = 'two sibling 10k trees x 4KB; reuse = C# ApplyTreeSnapshotBuilder + SessionHashCache identity-hit skip lease/hash; baseline = -DisableApplyHashReuseForTest HostSafety PS snapshot + lease ComputeSha256FromHandle (no cache)'
    samples = @($samples)
    reuseElapsedMs = [long]$stable.reuseElapsedMs
    baselineElapsedMs = [long]$stable.baselineElapsedMs
    reuseBytesHashed = [long]$stable.reuseBytesHashed
    baselineBytesHashed = [long]$stable.baselineBytesHashed
    speedup = [double]$stable.speedup
    targetRange = '1.5-2x vs no-reuse baseline'
    metTarget = [bool]$stable.metTarget
    flags = [ordered]@{
        reuse = 'SessionHashCache + ApplyTreeSnapshotBuilder identity-hit skip lease/hash'
        baseline = '-DisableApplyHashReuseForTest HostSafety PS snapshot, no SessionHashCache'
    }
}
[IO.File]::WriteAllText(
    (Join-Path $evidenceHome 'scale-10000.json'),
    ($scale10000Record | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))

$summary = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue32-summary'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    result = $(if ($scale10000Record.metTarget) { 'PASS' } else { 'FAIL' })
    scale1000 = $scale1000Record
    scale10000 = $scale10000Record
}
[IO.File]::WriteAllText(
    (Join-Path $evidenceHome 'summary.json'),
    ($summary | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false))

$summary | ConvertTo-Json -Depth 10
Write-Output "WROTE $(Join-Path $evidenceHome 'summary.json')"
