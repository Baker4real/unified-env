[CmdletBinding()]
param(
    [int]$FileCount = 10000,
    [int]$BytesPerFile = 4096,
    [int]$SamplesPerScenario = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$scaleRoot = Join-Path $evidenceHome 'bench-scale'
$policyPath = Join-Path $scaleRoot 'policy.json'
$evidenceRoot = Join-Path $scaleRoot 'evidence'
$totalBytes = [long]$FileCount * [long]$BytesPerFile

function Write-Stage {
    param([Parameter(Mandatory)][string]$Name)
    Write-Output ("STAGE {0} utc={1}" -f $Name, [datetimeoffset]::UtcNow.ToString('o'))
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document
    )
    [IO.File]::WriteAllText(
        $Path,
        ($Document | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete issue42 bench cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete issue42 bench cleanup'
}

function New-ScaleTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$FileCount,
        [Parameter(Mandatory)][int]$BytesPerFile
    )
    if ([IO.Directory]::Exists($Path)) {
        Remove-TestTree -Path $Path
    }
    $directoryCount = [Math]::Max(1, [int][Math]::Ceiling($FileCount / 100.0))
    $payload = [byte[]]::new($BytesPerFile)
    for ($index = 0; $index -lt $payload.Length; $index++) {
        $payload[$index] = [byte](($index + 17) % 251)
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
    return $written
}

function Invoke-BenchPipeline {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Scenario,
        [int]$PurgeMaxDegreeOfParallelismForTest = 0,
        [switch]$DisableHashReuse
    )

    $plan = New-CodexSafeTreeDeletePlan `
        -TargetPath $TargetPath `
        -CapabilityRoot $scaleRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $applyArguments = @{
        PlanPath = [string]$plan.planPath
        ApprovedPlanSha256 = [string]$plan.planSha256
        PolicyPath = $policyPath
        EvidenceRoot = $evidenceRoot
    }
    if ($DisableHashReuse) {
        $applyArguments.DisableApplyHashReuseForTest = $true
    }
    $apply = Invoke-CodexSafeTreeDeleteQuarantine @applyArguments
    $purgeArguments = @{
        TransactionPath = [string]$apply.transactionPath
        ApprovedTransactionSha256 = [string]$apply.transactionSha256
        PolicyPath = $policyPath
        EvidenceRoot = $evidenceRoot
    }
    if ($DisableHashReuse) {
        $purgeArguments.DisablePurgeHashReuseForTest = $true
    }
    if ($PurgeMaxDegreeOfParallelismForTest -ge 1) {
        $purgeArguments.PurgeMaxDegreeOfParallelismForTest = $PurgeMaxDegreeOfParallelismForTest
    }
    $purge = Invoke-CodexSafeTreeDeletePurge @purgeArguments
    if (-not [bool]$purge.purged) {
        throw "$Scenario Purge 未成功"
    }
    if ([IO.Directory]::Exists($TargetPath) -or [IO.Directory]::Exists([string]$apply.quarantinePath)) {
        throw "$Scenario Purge 后目标或 quarantine 仍在"
    }
    $planMs = [long]$plan.metrics.elapsedMs
    $applyMs = [long]$apply.metrics.elapsedMs
    $purgeMs = [long]$purge.metrics.elapsedMs
    return [pscustomobject][ordered]@{
        scenario = $Scenario
        utc = [datetimeoffset]::UtcNow.ToString('o')
        fileCount = [int]$plan.fileCount
        planElapsedMs = $planMs
        applyElapsedMs = $applyMs
        purgeElapsedMs = $purgeMs
        elapsedMs = $planMs + $applyMs + $purgeMs
        applyBytesHashed = [long]$apply.metrics.bytesHashed
        purgeBytesHashed = [long]$purge.metrics.bytesHashed
        parallelPurge = $(if ($null -ne $purge.PSObject.Properties['parallelPurge']) {
            $purge.parallelPurge
        } else { $null })
        leafDispositionsPath = [string]$purge.leafDispositionsPath
    }
}

$runtimeEdition = [string]$PSVersionTable.PSEdition
if ($runtimeEdition -cne 'Core') { throw "需要 PowerShell Core，实际 $runtimeEdition" }
. $hostSafetyLibraryPath
. $libraryPath

[void][IO.Directory]::CreateDirectory($scaleRoot)
[void][IO.Directory]::CreateDirectory($evidenceRoot)
Write-JsonFile -Path $policyPath -Document ([pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(
        [pscustomobject][ordered]@{
            id = 'issue42-production-bench'
            capabilityRoot = $scaleRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        }
    )
})

$scenarios = @(
    [pscustomobject]@{ name = 'baseline'; disableReuse = $true; dop = 0 },
    [pscustomobject]@{ name = 'typical-dop2'; disableReuse = $false; dop = 0 },
    [pscustomobject]@{ name = 'best-dop4'; disableReuse = $false; dop = 4 }
)

$samples = [Collections.Generic.List[object]]::new()
$partialPath = Join-Path $evidenceHome 'benchmark-samples.json'
try {
    foreach ($scenario in $scenarios) {
        for ($sample = 1; $sample -le $SamplesPerScenario; $sample++) {
            $label = '{0}-s{1}' -f $scenario.name, $sample
            Write-Stage -Name $label
            $target = Join-Path $scaleRoot ('candidate-{0}' -f $label)
            $created = New-ScaleTree -Path $target -FileCount $FileCount -BytesPerFile $BytesPerFile
            if ($created -ne $FileCount) {
                throw "$label 写出 $created 个文件，期望 $FileCount"
            }
            $row = Invoke-BenchPipeline `
                -TargetPath $target `
                -Scenario $label `
                -PurgeMaxDegreeOfParallelismForTest ([int]$scenario.dop) `
                -DisableHashReuse:([bool]$scenario.disableReuse)
            $row | Add-Member -NotePropertyName sampleIndex -NotePropertyValue $sample
            $row | Add-Member -NotePropertyName scenarioName -NotePropertyValue $scenario.name
            $samples.Add($row)
            Write-JsonFile -Path $partialPath -Document ([pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-issue42-benchmark-partial'
                writtenUtc = [datetimeoffset]::UtcNow.ToString('o')
                samples = @($samples)
            })
            Write-Output (
                'SAMPLE {0} total={1} plan={2} apply={3} purge={4} parallel={5} dop={6} journal%={7}' -f @(
                    $label,
                    $row.elapsedMs,
                    $row.planElapsedMs,
                    $row.applyElapsedMs,
                    $row.purgeElapsedMs,
                    $(if ($null -ne $row.parallelPurge) { [bool]$row.parallelPurge.used } else { $false }),
                    $(if ($null -ne $row.parallelPurge) { [int]$row.parallelPurge.maxDegreeOfParallelism } else { 0 }),
                    $(if ($null -ne $row.parallelPurge -and $null -ne $row.parallelPurge.journalOverheadPercent) {
                        [double]$row.parallelPurge.journalOverheadPercent
                    } else { -1 })
                )
            )
        }
    }
} catch {
    Write-JsonFile -Path (Join-Path $evidenceHome 'benchmark-failure.json') -Document ([pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue42-benchmark-failure'
        utc = [datetimeoffset]::UtcNow.ToString('o')
        message = [string]$_.Exception.Message
        type = [string]$_.Exception.GetType().FullName
        samples = @($samples)
    })
    throw
}

function Get-ScenarioStats {
    param([Parameter(Mandatory)][string]$Name)
    $rows = @($samples | Where-Object { [string]$_.scenarioName -ceq $Name })
    $totals = @($rows | ForEach-Object { [long]$_.elapsedMs })
    $purges = @($rows | ForEach-Object { [long]$_.purgeElapsedMs })
    return [pscustomobject][ordered]@{
        name = $Name
        sampleCount = $rows.Count
        totalsMs = @($totals)
        purgeMs = @($purges)
        medianTotalMs = [long](@($totals | Sort-Object)[[int][Math]::Floor(($totals.Count - 1) / 2.0)])
        minTotalMs = [long]($totals | Measure-Object -Minimum).Minimum
        maxTotalMs = [long]($totals | Measure-Object -Maximum).Maximum
        medianPurgeMs = [long](@($purges | Sort-Object)[[int][Math]::Floor(($purges.Count - 1) / 2.0)])
        samples = @($rows)
    }
}

$baselineStats = Get-ScenarioStats -Name 'baseline'
$typicalStats = Get-ScenarioStats -Name 'typical-dop2'
$bestStats = Get-ScenarioStats -Name 'best-dop4'
$baselineMs = [double]$baselineStats.medianTotalMs
$typicalRatio = if ($baselineMs -gt 0) { [double]$typicalStats.medianTotalMs / $baselineMs } else { 0 }
$bestRatio = if ($baselineMs -gt 0) { [double]$bestStats.medianTotalMs / $baselineMs } else { 0 }
$typicalSpeedup = if ($typicalRatio -gt 0) { 1.0 / $typicalRatio } else { 0 }
$bestSpeedup = if ($bestRatio -gt 0) { 1.0 / $bestRatio } else { 0 }
$baselinePurgeMs = [double]$baselineStats.medianPurgeMs
$typicalPurgeSpeedup = if ([double]$typicalStats.medianPurgeMs -gt 0) {
    $baselinePurgeMs / [double]$typicalStats.medianPurgeMs
} else { 0 }
$bestPurgeSpeedup = if ([double]$bestStats.medianPurgeMs -gt 0) {
    $baselinePurgeMs / [double]$bestStats.medianPurgeMs
} else { 0 }

$typicalJournals = @(
    $typicalStats.samples |
        Where-Object { $null -ne $_.parallelPurge -and $null -ne $_.parallelPurge.journalOverheadPercent } |
        ForEach-Object { [double]$_.parallelPurge.journalOverheadPercent }
)
$journalMedian = if ($typicalJournals.Count -gt 0) {
    [double](@($typicalJournals | Sort-Object)[[int][Math]::Floor(($typicalJournals.Count - 1) / 2.0)])
} else { $null }

$summary = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue42-production-benchmark'
    utc = [datetimeoffset]::UtcNow.ToString('o')
    fileCount = $FileCount
    bytesPerFile = $BytesPerFile
    totalBytes = $totalBytes
    samplesPerScenario = $SamplesPerScenario
    method = 'sequential 10k x 4KB production Plan→Apply→Purge; baseline = DisableApplyHashReuseForTest + DisablePurgeHashReuseForTest; typical = default DOP from FileSystemCapabilities (2); best = PurgeMaxDegreeOfParallelismForTest 4; HostSafety deleter; no File.Delete; every sample recorded'
    baseline = $baselineStats
    typicalDop2 = $typicalStats
    bestDop4 = $bestStats
    fullPipeline = [pscustomobject][ordered]@{
        typicalRatio = [Math]::Round($typicalRatio, 3)
        typicalSpeedup = [Math]::Round($typicalSpeedup, 3)
        bestRatio = [Math]::Round($bestRatio, 3)
        bestSpeedup = [Math]::Round($bestSpeedup, 3)
        metTargetTypical = [bool]($typicalSpeedup -ge 4.0)
        metTargetBest = [bool]($bestSpeedup -ge 6.0)
        targetTypical = 'typical/baseline <= 0.25 (>=4x) full Plan→Apply→Purge'
        targetBest = 'best/baseline <= 0.17 (>=6x) full Plan→Apply→Purge'
    }
    purgeOnly = [pscustomobject][ordered]@{
        typicalSpeedup = [Math]::Round($typicalPurgeSpeedup, 3)
        bestSpeedup = [Math]::Round($bestPurgeSpeedup, 3)
        note = 'Purge-stage only; not the AC 4x/6x denominator'
    }
    journalOverheadTypicalPercent = $journalMedian
    journalWithinTarget = $(if ($null -ne $journalMedian) { [bool]($journalMedian -lt 10.0) } else { $null })
    samples = @($samples)
}
Write-JsonFile -Path (Join-Path $evidenceHome 'benchmark.json') -Document $summary
Write-Output (
    'BENCH baseline={0} typical={1} ({2}x) best={3} ({4}x) journal%={5} metTypical={6} metBest={7}' -f @(
        $baselineStats.medianTotalMs,
        $typicalStats.medianTotalMs,
        [Math]::Round($typicalSpeedup, 3),
        $bestStats.medianTotalMs,
        [Math]::Round($bestSpeedup, 3),
        $journalMedian,
        $summary.fullPipeline.metTargetTypical,
        $summary.fullPipeline.metTargetBest
    )
)
