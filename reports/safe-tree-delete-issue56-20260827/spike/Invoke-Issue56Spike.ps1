[CmdletBinding()]
param(
    [int]$FileCount = 10000,
    [int]$BytesPerFile = 4096,
    [int]$Samples = 2,
    [int]$CooldownSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 Wave A 序列化 spike（docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md §4.4）。
# 目的：在改造前量化现行 PS Plan 管线的端到端成本与序列化段成本（决策门 4-8s）。
# 树与计时口径复用 #42 iter2（New-ScaleTree 同一代码路径）；树放在 gitignored 的
# reports/safe-tree-delete-test-issue56/ 下，结论 JSON 写回本目录 spike-summary.json。

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$scratchRoot = Join-Path $projectRoot 'reports\safe-tree-delete-test-issue56'
$scaleRoot = Join-Path $scratchRoot 'spike-scale'
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
        -Name 'safe-delete issue56 spike cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete issue56 spike cleanup'
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
            id = 'issue56-spike'
            capabilityRoot = $scaleRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        }
    )
})

$processorCount = [Environment]::ProcessorCount
$currentProcess = [Diagnostics.Process]::GetCurrentProcess()

# JIT/管线 warm-up：小树跑一次完整 Plan，避免首样本吸收首次调用开销。
$warmTarget = Join-Path $scaleRoot 'warm-small'
[void](New-ScaleTree -Path $warmTarget -FileCount 10 -BytesPerFile 16)
$warmSw = [Diagnostics.Stopwatch]::StartNew()
$warmPlan = New-CodexSafeTreeDeletePlan `
    -TargetPath $warmTarget `
    -CapabilityRoot $scaleRoot `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot
$warmSw.Stop()
Write-Output ("WARM planElapsedMs={0} wallMs={1}" -f $warmPlan.metrics.elapsedMs, $warmSw.ElapsedMilliseconds)
Remove-TestTree -Path $warmTarget

$target = Join-Path $scaleRoot 'candidate-spike'
$buildSw = [Diagnostics.Stopwatch]::StartNew()
$created = New-ScaleTree -Path $target -FileCount $FileCount -BytesPerFile $BytesPerFile
$buildSw.Stop()
if ($created -ne $FileCount) { throw "spike 写出 $created" }
Write-Output ("TREE created={0} buildMs={1}" -f $created, $buildSw.ElapsedMilliseconds)

$spikeRows = [Collections.Generic.List[object]]::new()
try {
    for ($sample = 1; $sample -le $Samples; $sample++) {
        Write-Output ("STAGE spike-s{0} utc={1}" -f $sample, [datetimeoffset]::UtcNow.ToString('o'))
        $cpuBefore = [double]$currentProcess.CPU
        $plan = New-CodexSafeTreeDeletePlan `
            -TargetPath $target `
            -CapabilityRoot $scaleRoot `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot
        $cpuAfter = [double]$currentProcess.CPU
        $planPath = [string]$plan.planPath

        # 序列化/回读 probe：对已发布 plan.json 的解析、再序列化与读回+SHA 成本。
        $probeSw = [Diagnostics.Stopwatch]::StartNew()
        $planText = [IO.File]::ReadAllText($planPath, [Text.UTF8Encoding]::new($false))
        $probeSw.Stop()
        $readTextMs = $probeSw.ElapsedMilliseconds

        $probeSw.Restart()
        $parsed = $planText | ConvertFrom-Json -Depth 128 -DateKind String
        $probeSw.Stop()
        $parseMs = $probeSw.ElapsedMilliseconds

        $probeSw.Restart()
        $null = $parsed | ConvertTo-Json -Depth 100
        $probeSw.Stop()
        $serializeProbeMs = $probeSw.ElapsedMilliseconds

        $probeSw.Restart()
        $planBytes = [IO.File]::ReadAllBytes($planPath)
        $null = [Security.Cryptography.SHA256]::HashData($planBytes)
        $probeSw.Stop()
        $readbackMs = $probeSw.ElapsedMilliseconds

        $row = [pscustomobject][ordered]@{
            sampleIndex = $sample
            utc = [datetimeoffset]::UtcNow.ToString('o')
            planElapsedMs = [long]$plan.metrics.elapsedMs
            entriesScanned = [long]$plan.metrics.entriesScanned
            logicalBytes = [long]$plan.metrics.logicalBytes
            bytesHashed = [long]$plan.metrics.bytesHashed
            planBytes = [long]$planBytes.Length
            probeReadTextMs = [long]$readTextMs
            probeParseMs = [long]$parseMs
            probeSerializeMs = [long]$serializeProbeMs
            probeReadbackMs = [long]$readbackMs
            processCpuSecondsDelta = [Math]::Round(($cpuAfter - $cpuBefore), 3)
        }
        $spikeRows.Add($row)
        Write-Output (
            'SAMPLE spike-s{0} plan={1}ms bytes={2} serializeProbe={3}ms parse={4}ms readback={5}ms cpuDelta={6}s' -f @(
                $sample, $row.planElapsedMs, $row.planBytes, $row.probeSerializeMs,
                $row.probeParseMs, $row.probeReadbackMs, $row.processCpuSecondsDelta))
        if ($sample -lt $Samples) { Start-Sleep -Seconds $CooldownSeconds }
    }
} finally {
    Remove-TestTree -Path $target
}

$summary = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue56-serialization-spike'
    utc = [datetimeoffset]::UtcNow.ToString('o')
    walkerMode = 'powershell-three-pass (pre-change)'
    fileCount = $FileCount
    bytesPerFile = $BytesPerFile
    processorCount = $processorCount
    note = 'probeSerializeMs 为对已发布 plan.json 解析后再 ConvertTo-Json -Depth 100 的探针成本，量级代表 lib 内序列化段；probeReadbackMs 为读回+SHA256。'
    samples = @($spikeRows)
}
Write-JsonFile -Path (Join-Path $evidenceHome 'spike-summary.json') -Document $summary
Write-Output 'SPIKE DONE'
