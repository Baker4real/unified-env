[CmdletBinding()]
param(
    [int]$FileCount = 10000,
    [int]$BytesPerFile = 4096,
    [int]$SamplesPerScenario = 3,
    [int]$CooldownSeconds = 60,
    [int]$BaselineCooldownSeconds = 120,
    [switch]$SkipBaselineValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 AC2 端到端重测：沿用 #42 iter2 口径（baseline 576238ms 官方分母），扩展为
# ≥3 样本/场景 + min/max 双聚合并报 + 事后同轮 baseline 验证样本（±10%，不参与判定）。
# 依据 docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md §7 AC2。

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$scratchRoot = Join-Path $projectRoot 'reports\safe-tree-delete-test-issue56'
$scaleRoot = Join-Path $scratchRoot 'e2e-bench-scale'
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
        -Name 'safe-delete issue56 e2e cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete issue56 e2e cleanup'
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
        [int]$PurgeMaxDegreeOfParallelismForTest = 0,
        [switch]$ReconstructBaseline
    )

    $planArguments = @{
        TargetPath = $TargetPath
        CapabilityRoot = $scaleRoot
        PolicyPath = $policyPath
        EvidenceRoot = $evidenceRoot
    }
    if ($ReconstructBaseline) {
        $planArguments.DisablePlanCSharpWalkerForTest = $true
    }
    $plan = New-CodexSafeTreeDeletePlan @planArguments
    $applyArguments = @{
        PlanPath = [string]$plan.planPath
        ApprovedPlanSha256 = [string]$plan.planSha256
        PolicyPath = $policyPath
        EvidenceRoot = $evidenceRoot
    }
    if ($ReconstructBaseline) {
        $applyArguments.DisableApplyHashReuseForTest = $true
    }
    $apply = Invoke-CodexSafeTreeDeleteQuarantine @applyArguments
    $purgeArguments = @{
        TransactionPath = [string]$apply.transactionPath
        ApprovedTransactionSha256 = [string]$apply.transactionSha256
        PolicyPath = $policyPath
        EvidenceRoot = $evidenceRoot
    }
    if ($ReconstructBaseline) {
        $purgeArguments.DisablePurgeHashReuseForTest = $true
    } elseif ($PurgeMaxDegreeOfParallelismForTest -ge 1) {
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
        parallelPurge = $purge.parallelPurge
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
            id = 'issue56-e2e-bench'
            capabilityRoot = $scaleRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        }
    )
})

$processorCount = [Environment]::ProcessorCount
$scenarios = @(
    [pscustomobject]@{ name = 'typical-dop2'; dop = 0 },
    [pscustomobject]@{ name = 'best-dop4'; dop = 4 }
)
$samples = [Collections.Generic.List[object]]::new()
$partialPath = Join-Path $evidenceHome 'e2e-benchmark-partial.json'
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
            Write-JsonFile -Path $partialPath -Document ([pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-issue56-e2e-partial'
                samples = @($samples)
            })
            $timings = $null
            if ($null -ne $row.parallelPurge -and $null -ne $row.parallelPurge.timings) {
                $timings = $row.parallelPurge.timings
            }
            Write-Output (
                'SAMPLE {0} total={1} plan={2} apply={3} purge={4} snap={5} coord={6}' -f @(
                    $label,
                    $row.elapsedMs,
                    $row.planElapsedMs,
                    $row.applyElapsedMs,
                    $row.purgeElapsedMs,
                    $(if ($timings) { $timings.snapshotMs } else { -1 }),
                    $(if ($timings) { $timings.coordinatorMs } else { -1 })
                )
            )
            if (-not ($scenario.name -ceq 'best-dop4' -and $sample -eq $SamplesPerScenario -and $SkipBaselineValidation)) {
                Start-Sleep -Seconds $CooldownSeconds
            }
        }
    }
} catch {
    Write-JsonFile -Path (Join-Path $evidenceHome 'e2e-benchmark-failure.json') -Document ([pscustomobject][ordered]@{
        utc = [datetimeoffset]::UtcNow.ToString('o')
        message = [string]$_.Exception.Message
        samples = @($samples)
    })
    throw
}

$baselineRow = $null
if (-not $SkipBaselineValidation) {
    Start-Sleep -Seconds $BaselineCooldownSeconds
    Write-Stage -Name 'baseline-validation'
    $baselineTarget = Join-Path $scaleRoot 'candidate-baseline-validation'
    $created = New-ScaleTree -Path $baselineTarget -FileCount $FileCount -BytesPerFile $BytesPerFile
    if ($created -ne $FileCount) { throw "baseline 写出 $created" }
    $baselineRow = Invoke-BenchPipeline `
        -TargetPath $baselineTarget `
        -Scenario 'baseline-validation' `
        -ReconstructBaseline
    $baselineRow | Add-Member -NotePropertyName sampleIndex -NotePropertyValue 1
    $baselineRow | Add-Member -NotePropertyName scenarioName -NotePropertyValue 'baseline-validation'
    Write-Output (
        'SAMPLE baseline-validation total={0} plan={1} apply={2} purge={3}' -f @(
            $baselineRow.elapsedMs, $baselineRow.planElapsedMs,
            $baselineRow.applyElapsedMs, $baselineRow.purgeElapsedMs))
}

$baselineConstantMedianMs = 576238L
function Get-ScenarioView {
    param([Parameter(Mandatory)][string]$Name)
    $rows = @($samples | Where-Object { $_.scenarioName -ceq $Name })
    $values = @($rows | ForEach-Object { [long]$_.elapsedMs })
    return [pscustomobject][ordered]@{
        name = $Name
        samples = @($values)
        minMs = [long]($values | Measure-Object -Minimum).Minimum
        maxMs = [long]($values | Measure-Object -Maximum).Maximum
        minSpeedupVsBaselineConstant = [Math]::Round($baselineConstantMedianMs / [double]($values | Measure-Object -Minimum).Minimum, 3)
        maxSpeedupVsBaselineConstant = [Math]::Round($baselineConstantMedianMs / [double]($values | Measure-Object -Maximum).Maximum, 3)
    }
}
$typicalView = Get-ScenarioView -Name 'typical-dop2'
$bestView = Get-ScenarioView -Name 'best-dop4'
$baselineValidation = $null
if ($null -ne $baselineRow) {
    $baselineValidation = [pscustomobject][ordered]@{
        elapsedMs = [long]$baselineRow.elapsedMs
        planElapsedMs = [long]$baselineRow.planElapsedMs
        applyElapsedMs = [long]$baselineRow.applyElapsedMs
        purgeElapsedMs = [long]$baselineRow.purgeElapsedMs
        baselineConstantMedianMs = $baselineConstantMedianMs
        deltaPercent = [Math]::Round(
            (([long]$baselineRow.elapsedMs - $baselineConstantMedianMs) / [double]$baselineConstantMedianMs) * 100.0, 3)
        withinTolerancePlusMinus10Percent = [bool](
            [long]$baselineRow.elapsedMs -le [long]($baselineConstantMedianMs * 1.10) -and
            [long]$baselineRow.elapsedMs -ge [long]($baselineConstantMedianMs * 0.90))
        note = '验证样本只锚定环境，不参与 AC 判定；越界须停止验收查环境，不得换分母。'
    }
}
$summary = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue56-e2e-benchmark'
    utc = [datetimeoffset]::UtcNow.ToString('o')
    baselineFromIssue42Iter1 = [pscustomobject]@{
        s1 = 576238L
        s2 = 579452L
        median = 576238L
    }
    aggregator = 'min-and-max'
    processorCount = $processorCount
    psVersion = [string]$PSVersionTable.PSVersion
    typicalDop2 = $typicalView
    bestDop4 = $bestView
    baselineValidation = $baselineValidation
    metTargetTypicalMinAggregator4x = [bool]($typicalView.minSpeedupVsBaselineConstant -ge 4.0)
    metTargetTypicalMaxAggregator4x = [bool]($typicalView.maxSpeedupVsBaselineConstant -ge 4.0)
    metTargetBestMinAggregator6x = [bool]($bestView.minSpeedupVsBaselineConstant -ge 6.0)
    metTargetBestMaxAggregator6x = [bool]($bestView.maxSpeedupVsBaselineConstant -ge 6.0)
    note = '判定口径以 issue 预注册状态为准：未确认=票面逐场景 min 双线；确认后按预注册口径。两套并报。'
    samples = @($samples)
}
Write-JsonFile -Path (Join-Path $evidenceHome 'e2e-benchmark.json') -Document $summary
Write-Output (
    'AGGREGATE typical min/max speedup={0}/{1} best min/max speedup={2}/{3} baselineValidation={4}' -f @(
        $typicalView.minSpeedupVsBaselineConstant,
        $typicalView.maxSpeedupVsBaselineConstant,
        $bestView.minSpeedupVsBaselineConstant,
        $bestView.maxSpeedupVsBaselineConstant,
        $(if ($baselineValidation) { $baselineValidation.elapsedMs } else { 'skipped' })
    )
)
Write-Output 'E2E-BENCH DONE'
