[CmdletBinding()]
param(
    [int]$FileCount = 10000,
    [int]$BytesPerFile = 4096,
    [int]$SamplesPerMode = 3,
    [int]$CooldownSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 AC1 Plan 独立基准：改造后（C# 单遍 walker，默认）与改造前（PowerShell 三遍回退）
# 同口径对比。树生成复用 #42 iter2 New-ScaleTree 同一代码路径，每样本重建；
# 双聚合器（min/max）显式输出；分段计时来自 $script:CodexSafeTreeDeleteLastPlanSegments。
# 依据 docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md §7 AC1。

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$scratchRoot = Join-Path $projectRoot 'reports\safe-tree-delete-test-issue56'
$scaleRoot = Join-Path $scratchRoot 'plan-bench-scale'
$policyPath = Join-Path $scaleRoot 'policy.json'
$evidenceRoot = Join-Path $scaleRoot 'evidence'

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
        -Name 'safe-delete issue56 plan bench cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete issue56 plan bench cleanup'
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
            id = 'issue56-plan-bench'
            capabilityRoot = $scaleRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        }
    )
})

$processorCount = [Environment]::ProcessorCount
$currentProcess = [Diagnostics.Process]::GetCurrentProcess()

# warm：完整 Plan 管线跑一次小树（JIT/DLL 缓存），并记录。
$warmTarget = Join-Path $scaleRoot 'warm-small'
[void](New-ScaleTree -Path $warmTarget -FileCount 10 -BytesPerFile 16)
$warmWatch = [Diagnostics.Stopwatch]::StartNew()
$warmPlan = New-CodexSafeTreeDeletePlan `
    -TargetPath $warmTarget `
    -CapabilityRoot $scaleRoot `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot
$warmWatch.Stop()
$warmRow = [pscustomobject][ordered]@{
    walker = [string]$script:CodexSafeTreeDeleteLastPlanSegments.walker
    planElapsedMs = [long]$warmPlan.metrics.elapsedMs
    wallMs = [long]$warmWatch.ElapsedMilliseconds
}
Remove-TestTree -Path $warmTarget
Write-Output ("WARM walker={0} planElapsedMs={1} wallMs={2}" -f @(
    $warmRow.walker, $warmRow.planElapsedMs, $warmRow.wallMs))

$rows = [Collections.Generic.List[object]]::new()
$partialPath = Join-Path $evidenceHome 'plan-benchmark-partial.json'
$modes = @('csharp', 'powershell')
foreach ($mode in $modes) {
    for ($sample = 1; $sample -le $SamplesPerMode; $sample++) {
        $label = '{0}-s{1}' -f $mode, $sample
        Write-Output ("STAGE {0} utc={1}" -f $label, [datetimeoffset]::UtcNow.ToString('o'))
        $target = Join-Path $scaleRoot ('candidate-{0}' -f $label)
        $buildWatch = [Diagnostics.Stopwatch]::StartNew()
        $created = New-ScaleTree -Path $target -FileCount $FileCount -BytesPerFile $BytesPerFile
        $buildWatch.Stop()
        if ($created -ne $FileCount) { throw "$label 写出 $created" }
        $cpuBefore = [double]$currentProcess.CPU
        $planArguments = @{
            TargetPath = $target
            CapabilityRoot = $scaleRoot
            PolicyPath = $policyPath
            EvidenceRoot = $evidenceRoot
        }
        if ($mode -ceq 'powershell') { $planArguments.DisablePlanCSharpWalkerForTest = $true }
        $plan = New-CodexSafeTreeDeletePlan @planArguments
        $cpuAfter = [double]$currentProcess.CPU
        $segments = $script:CodexSafeTreeDeleteLastPlanSegments
        $planBytes = [IO.File]::ReadAllBytes([string]$plan.planPath).Length
        $row = [pscustomobject][ordered]@{
            mode = $mode
            sampleIndex = $sample
            utc = [datetimeoffset]::UtcNow.ToString('o')
            fileCount = [int]$plan.fileCount
            planElapsedMs = [long]$plan.metrics.elapsedMs
            entriesScanned = [long]$plan.metrics.entriesScanned
            logicalBytes = [long]$plan.metrics.logicalBytes
            bytesHashed = [long]$plan.metrics.bytesHashed
            planBytes = [long]$planBytes
            treeBuildMs = [long]$buildWatch.ElapsedMilliseconds
            processCpuSecondsDelta = [Math]::Round(($cpuAfter - $cpuBefore), 3)
            segments = $segments
        }
        $rows.Add($row)
        Remove-TestTree -Path $target
        Write-Output (
            'SAMPLE {0} plan={1}ms walkerTotal={2} hash={3} streamSet={4} captures={5} doc={6} pub={7} rb={8} bytes={9} cpuDelta={10}s' -f @(
                $label, $row.planElapsedMs,
                [long]$segments.walkerTotalMs, [long]$segments.hashMs, [long]$segments.streamSetMs,
                $(if ($null -ne $segments.capturesMs) { [long]$segments.capturesMs } else { -1 }),
                [long]$segments.documentMs, [long]$segments.publishMs, [long]$segments.readbackMs,
                $row.planBytes, $row.processCpuSecondsDelta))
        Write-JsonFile -Path $partialPath -Document ([pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-issue56-plan-benchmark-partial'
            samples = @($rows)
        })
        if (-not ($mode -ceq 'powershell' -and $sample -eq $SamplesPerMode)) {
            Start-Sleep -Seconds $CooldownSeconds
        }
    }
}

function Get-Aggregates {
    param([Parameter(Mandatory)][string]$Mode)
    $values = @($rows | Where-Object { $_.mode -ceq $Mode } | ForEach-Object { [long]$_.planElapsedMs })
    return [pscustomobject][ordered]@{
        mode = $Mode
        samples = @($values)
        minMs = [long]($values | Measure-Object -Minimum).Minimum
        maxMs = [long]($values | Measure-Object -Maximum).Maximum
        medianMs = [long](($values | Sort-Object)[[int][Math]::Floor(($values.Count - 1) / 2.0)])
    }
}
$csharpAggregates = Get-Aggregates -Mode 'csharp'
$powerShellAggregates = Get-Aggregates -Mode 'powershell'
$summary = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue56-plan-benchmark'
    utc = [datetimeoffset]::UtcNow.ToString('o')
    fileCount = $FileCount
    bytesPerFile = $BytesPerFile
    samplesPerMode = $SamplesPerMode
    processorCount = $processorCount
    psVersion = [string]$PSVersionTable.PSVersion
    culture = [Globalization.CultureInfo]::CurrentCulture.Name
    aggregator = 'min-and-max'
    warm = $warmRow
    csharpSinglePassWalker = $csharpAggregates
    powershellThreePass = $powerShellAggregates
    speedupPsOverCsharpMedian = [Math]::Round(
        ($powerShellAggregates.medianMs / [double]$csharpAggregates.medianMs), 3)
    metDesignPointCsharpMaxLe32s = [bool]($csharpAggregates.maxMs -le 32000L)
    metHardCapCsharpMaxLe40s = [bool]($csharpAggregates.maxMs -le 40000L)
    note = '判定口径以 issue 预注册状态为准：未确认按票面 40s，确认后按 32s 设计运行点（max）；两套 min/max 并报。'
    samples = @($rows)
}
Write-JsonFile -Path (Join-Path $evidenceHome 'plan-benchmark.json') -Document $summary
Write-Output (
    'AGGREGATE csharp min/med/max={0}/{1}/{2} powershell min/med/max={3}/{4}/{5} speedupMedian={6}' -f @(
        $csharpAggregates.minMs, $csharpAggregates.medianMs, $csharpAggregates.maxMs,
        $powerShellAggregates.minMs, $powerShellAggregates.medianMs, $powerShellAggregates.maxMs,
        $summary.speedupPsOverCsharpMedian))
Write-Output 'PLAN-BENCH DONE'
