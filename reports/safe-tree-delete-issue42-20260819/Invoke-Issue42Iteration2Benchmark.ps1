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
$scaleRoot = Join-Path $evidenceHome 'bench-scale-iter2'
$policyPath = Join-Path $scaleRoot 'policy.json'
$evidenceRoot = Join-Path $scaleRoot 'evidence'

function Write-Stage {
    param([Parameter(Mandatory)][string]$Name)
    Write-Output ("STAGE {0} utc={1}" -f $Name, [datetimeoffset]::UtcNow.ToString('o'))
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Document)
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete issue42 iter2 cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete issue42 iter2 cleanup'
}

function New-ScaleTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$FileCount,
        [Parameter(Mandatory)][int]$BytesPerFile
    )
    if ([IO.Directory]::Exists($Path)) { Remove-TestTree -Path $Path }
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
            [IO.File]::WriteAllBytes((Join-Path $directory ('f{0:D2}.bin' -f $fileIndex)), $payload)
            $written += 1
        }
    }
    return $written
}

function Invoke-BenchPipeline {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Scenario,
        [int]$PurgeMaxDegreeOfParallelismForTest = 0
    )

    $plan = New-CodexSafeTreeDeletePlan `
        -TargetPath $TargetPath `
        -CapabilityRoot $scaleRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $apply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $purgeArguments = @{
        TransactionPath = [string]$apply.transactionPath
        ApprovedTransactionSha256 = [string]$apply.transactionSha256
        PolicyPath = $policyPath
        EvidenceRoot = $evidenceRoot
    }
    if ($PurgeMaxDegreeOfParallelismForTest -ge 1) {
        $purgeArguments.PurgeMaxDegreeOfParallelismForTest = $PurgeMaxDegreeOfParallelismForTest
    }
    $purge = Invoke-CodexSafeTreeDeletePurge @purgeArguments
    if (-not [bool]$purge.purged) { throw "$Scenario Purge 未成功" }
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
        parallelPurge = $purge.parallelPurge
        leafDispositionsPath = [string]$purge.leafDispositionsPath
    }
}

if ([string]$PSVersionTable.PSEdition -cne 'Core') { throw '需要 PowerShell Core' }
. $hostSafetyLibraryPath
. $libraryPath
[void][IO.Directory]::CreateDirectory($scaleRoot)
[void][IO.Directory]::CreateDirectory($evidenceRoot)
Write-JsonFile -Path $policyPath -Document ([pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(
        [pscustomobject][ordered]@{
            id = 'issue42-iter2-bench'
            capabilityRoot = $scaleRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        }
    )
})

$scenarios = @(
    [pscustomobject]@{ name = 'typical-dop2'; dop = 0 },
    [pscustomobject]@{ name = 'best-dop4'; dop = 4 }
)
$samples = [Collections.Generic.List[object]]::new()
$partialPath = Join-Path $evidenceHome 'iteration-2-benchmark-samples.json'
try {
    foreach ($scenario in $scenarios) {
        for ($sample = 1; $sample -le $SamplesPerScenario; $sample++) {
            $label = '{0}-s{1}' -f $scenario.name, $sample
            Write-Stage -Name $label
            $target = Join-Path $scaleRoot ('candidate-{0}' -f $label)
            $created = New-ScaleTree -Path $target -FileCount $FileCount -BytesPerFile $BytesPerFile
            if ($created -ne $FileCount) { throw "$label 写出 $created" }
            $row = Invoke-BenchPipeline `
                -TargetPath $target `
                -Scenario $label `
                -PurgeMaxDegreeOfParallelismForTest ([int]$scenario.dop)
            $row | Add-Member -NotePropertyName sampleIndex -NotePropertyValue $sample
            $row | Add-Member -NotePropertyName scenarioName -NotePropertyValue $scenario.name
            $samples.Add($row)
            Write-JsonFile -Path $partialPath -Document ([pscustomobject]@{
                artifactType = 'env-governance.codex-safe-tree-delete-issue42-iteration2-partial'
                samples = @($samples)
            })
            $timings = $null
            if ($null -ne $row.parallelPurge -and $null -ne $row.parallelPurge.timings) {
                $timings = $row.parallelPurge.timings
            }
            Write-Output (
                'SAMPLE {0} total={1} plan={2} apply={3} purge={4} snap={5} batch={6} coord={7} root={8} kind={9}' -f @(
                    $label,
                    $row.elapsedMs,
                    $row.planElapsedMs,
                    $row.applyElapsedMs,
                    $row.purgeElapsedMs,
                    $(if ($timings) { $timings.snapshotMs } else { -1 }),
                    $(if ($timings) { $timings.batchMs } else { -1 }),
                    $(if ($timings) { $timings.coordinatorMs } else { -1 }),
                    $(if ($timings) { $timings.emptyRootMs } else { -1 }),
                    $(if ($timings) { $timings.snapshotKind } else { 'n/a' })
                )
            )
        }
    }
} catch {
    Write-JsonFile -Path (Join-Path $evidenceHome 'iteration-2-benchmark-failure.json') -Document ([pscustomobject]@{
        utc = [datetimeoffset]::UtcNow.ToString('o')
        message = [string]$_.Exception.Message
        samples = @($samples)
    })
    throw
}

$baseline = [pscustomobject]@{ s1 = 576238L; s2 = 579452L; median = 576238L }
$typical = @($samples | Where-Object { $_.scenarioName -ceq 'typical-dop2' })
$best = @($samples | Where-Object { $_.scenarioName -ceq 'best-dop4' })
$typicalMin = [long]($typical | Measure-Object elapsedMs -Minimum).Minimum
$bestMin = [long]($best | Measure-Object elapsedMs -Minimum).Minimum
$typicalSpeedup = 576238.0 / [double]$typicalMin
$bestSpeedup = 576238.0 / [double]$bestMin
$summary = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue42-iteration2-benchmark'
    utc = [datetimeoffset]::UtcNow.ToString('o')
    baselineFromIteration1 = $baseline
    typicalDop2 = @($typical)
    bestDop4 = @($best)
    typicalSpeedupVsIter1Baseline = [Math]::Round($typicalSpeedup, 3)
    bestSpeedupVsIter1Baseline = [Math]::Round($bestSpeedup, 3)
    metTargetTypical = [bool]($typicalSpeedup -ge 4.0)
    metTargetBest = [bool]($bestSpeedup -ge 6.0)
    samples = @($samples)
}
Write-JsonFile -Path (Join-Path $evidenceHome 'iteration-2-benchmark.json') -Document $summary
Write-Output (
    'ITER2 typical={0} ({1}x) best={2} ({3}x) metTypical={4} metBest={5}' -f @(
        $typicalMin,
        [Math]::Round($typicalSpeedup, 3),
        $bestMin,
        [Math]::Round($bestSpeedup, 3),
        $summary.metTargetTypical,
        $summary.metTargetBest
    )
)
