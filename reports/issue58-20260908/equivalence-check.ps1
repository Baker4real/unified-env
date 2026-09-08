[CmdletBinding()]
param(
    [string]$BaselinePath = (Join-Path $PSScriptRoot 'cold-run-stdout.json'),
    [string]$CandidatePath = (Join-Path $PSScriptRoot 'cold-run-stdout-n2.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'equivalence-n2.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# issue #58 N2 全量等价对照：逐 operationId 比对两份 Status 输出的语义内容
# （剔除 capturedAtUtc/metrics/statusSegments 三个计时/簿记字段）。
function Get-SemanticStatus {
    param([Parameter(Mandatory)][string]$Path)
    $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -Depth 128 -DateKind String
    foreach ($key in @('capturedAtUtc', 'metrics', 'statusSegments')) {
        [void]$parsed.Remove($key)
    }
    return $parsed
}

function ConvertTo-StableJson {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 100 -Compress)
}

$baseline = Get-SemanticStatus -Path $BaselinePath
$candidate = Get-SemanticStatus -Path $CandidatePath

$result = [ordered]@{
    artifactType = 'issue58.n2-equivalence'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    topLevelEqualExcludingOperations = $false
    baselineOperationCount = @($baseline.operations).Count
    candidateOperationCount = @($candidate.operations).Count
    addedOperationIds = @()
    removedOperationIds = @()
    changedOperationIds = @()
    identicalOperationCount = 0
    blockingRecordsEqual = $false
    equal = $false
    error = $null
}

try {
    $baselineTop = [ordered]@{}
    foreach ($entry in $baseline.GetEnumerator()) {
        if ($entry.Key -cne 'operations') { $baselineTop[$entry.Key] = $entry.Value }
    }
    $candidateTop = [ordered]@{}
    foreach ($entry in $candidate.GetEnumerator()) {
        if ($entry.Key -cne 'operations') { $candidateTop[$entry.Key] = $entry.Value }
    }
    $result.topLevelEqualExcludingOperations =
        (ConvertTo-StableJson $baselineTop) -ceq (ConvertTo-StableJson $candidateTop)
    $result.blockingRecordsEqual = (ConvertTo-StableJson @($baselineTop.migrationReadiness.blockingRecords)) -ceq
        (ConvertTo-StableJson @($candidateTop.migrationReadiness.blockingRecords))

    $baselineById = @{}
    foreach ($operation in @($baseline.operations)) { $baselineById[[string]$operation.operationId] = $operation }
    $candidateById = @{}
    foreach ($operation in @($candidate.operations)) { $candidateById[[string]$operation.operationId] = $operation }

    $added = [Collections.Generic.List[string]]::new()
    $removed = [Collections.Generic.List[string]]::new()
    $changed = [Collections.Generic.List[string]]::new()
    $identical = 0
    foreach ($operationId in $baselineById.Keys) {
        if (-not $candidateById.ContainsKey($operationId)) {
            $removed.Add($operationId)
            continue
        }
        if ((ConvertTo-StableJson $baselineById[$operationId]) -ceq
            (ConvertTo-StableJson $candidateById[$operationId])) {
            $identical++
        } else {
            $changed.Add($operationId)
        }
    }
    foreach ($operationId in $candidateById.Keys) {
        if (-not $baselineById.ContainsKey($operationId)) { $added.Add($operationId) }
    }
    $result.addedOperationIds = @($added | Sort-Object)
    $result.removedOperationIds = @($removed | Sort-Object)
    $result.changedOperationIds = @($changed | Sort-Object)
    $result.identicalOperationCount = $identical
    $result.equal = $result.topLevelEqualExcludingOperations -and
        $added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0
} catch {
    $result.error = $_.Exception.Message
}

$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output ("equal={0} identicalOps={1}/{2} added={3} removed={4} changed={5} topLevel={6} blocking={7} error={8}" -f
    $result.equal, $result.identicalOperationCount, $result.baselineOperationCount,
    $result.addedOperationIds.Count, $result.removedOperationIds.Count, $result.changedOperationIds.Count,
    $result.topLevelEqualExcludingOperations, $result.blockingRecordsEqual, $result.error)
Write-Output 'equivalence-done'
