[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'perop-profile.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'D:\agents\projects\统一环境'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'

$watch = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')
$libLoadMs = $watch.ElapsedMilliseconds

# Replica of Get-CodexSafeTreeDeleteStatus (scripts/lib/CodexSafeTreeDelete.ps1:4186-4418)
# with per-operation stopwatches added. Library calls and wiring are identical.
$metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
Add-Member -InputObject $metricsState -NotePropertyMembers @{
    segmentDirectoryEnumerationMs = 0L
    segmentPlanTransactionReadMs = 0L
    segmentTerminalArchiveAuthMs = 0L
    segmentTreeMaterializationMs = 0L
    segmentSha256Ms = 0L
    segmentActiveResolveMs = 0L
    segmentArchivedResolveMs = 0L
    segmentPrefetchMs = 0L
    segmentFastScanMs = 0L
    approvedPlanValidationReuseCount = 0L
} -Force
$statusTreeCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$planManifestShaCache = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$treeMetricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState

$policyWatch = [Diagnostics.Stopwatch]::StartNew()
$policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyPath -MetricsObserver $treeMetricsObserver
$policyWatch.Stop()

$enumWatch = [Diagnostics.Stopwatch]::StartNew()
$runItems = @(Get-ChildItem -LiteralPath $evidenceRoot -Force -ErrorAction Stop |
    Sort-Object -Property Name -CaseSensitive)
$enumWatch.Stop()

$fastDop = Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit
$fastWatch = [Diagnostics.Stopwatch]::StartNew()
$fastResults = Invoke-CodexSafeTreeDeleteStatusFastScan `
    -RunItems $runItems `
    -Policy $policy `
    -FullEvidenceRoot $evidenceRoot `
    -MetricsState $metricsState `
    -DegreeOfParallelism $fastDop
$fastWatch.Stop()
$statusPlanPrefetch = [pscustomobject][ordered]@{
    cache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    throttleLimit = [int]$fastDop
    prefetchedCount = 0L
    parsedCount = 0L
}

$operations = [Collections.Generic.List[object]]::new()
$complete = $true
$fastHandled = 0L
$fastFallback = 0L
$perOp = [Collections.Generic.List[object]]::new()
$loopWatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($runItem in $runItems) {
    $isArchived = [IO.File]::Exists((Join-Path $runItem.FullName 'terminal-archive.json'))
    $fastResult = $null
    if ($null -ne $fastResults) {
        $fastResult = $fastResults[[string]$runItem.FullName]
    }
    $opWatch = [Diagnostics.Stopwatch]::StartNew()
    $mode = ''
    if ($null -ne $fastResult -and [bool]$fastResult.Handled) {
        $mode = 'fast-handled'
        $fastHandled = $fastHandled + 1L
        $operationStatus = New-CodexSafeTreeDeleteStatusOperationFromScan `
            -ScanResult $fastResult `
            -CandidatePolicyRequested:$false
    } else {
        $mode = 'fallback-' + $(if ($null -eq $fastResult) { 'missing' } else { [string]$fastResult.FallbackReason })
        $fastFallback = $fastFallback + 1L
        if ($null -ne $fastResult -and
            $null -ne $fastResult.PlanSha256 -and
            -not $statusPlanPrefetch.cache.ContainsKey([string]$runItem.FullName)) {
            $statusPlanPrefetch.cache[[string]$runItem.FullName] = [pscustomobject][ordered]@{
                snapshot = [pscustomobject][ordered]@{
                    sha256 = [string]$fastResult.PlanSha256
                    text = [string]$fastResult.PlanText
                }
                document = $null
                approvedPlanValidation = $fastResult.ApprovedPlanValidation
            }
        }
        $operationStatus = Resolve-CodexSafeTreeDeleteStatusOperation `
            -RunItem $runItem `
            -PolicyPath $policyPath `
            -CurrentPolicySha256 ([string]$policy.sha256) `
            -FullEvidenceRoot $evidenceRoot `
            -CandidatePolicyRequested:$false `
            -CandidatePolicy $null `
            -MetricsState $metricsState `
            -TreeMetricsObserver $treeMetricsObserver `
            -StatusTreeCache $statusTreeCache `
            -LoadedPolicy $policy `
            -StatusPlanPrefetch $statusPlanPrefetch.cache `
            -PlanManifestShaCache $planManifestShaCache
    }
    $opWatch.Stop()
    $operations.Add($operationStatus.operation)
    if (-not [bool]$operationStatus.complete) { $complete = $false }
    $perOp.Add([pscustomobject][ordered]@{
        runName = [string]$runItem.Name
        mode = $mode
        archived = $isArchived
        lifecycle = [string]$operationStatus.operation.lifecycle
        complete = [bool]$operationStatus.complete
        elapsedMs = [long]$opWatch.ElapsedMilliseconds
    })
}
$loopWatch.Stop()

$blockingWatch = [Diagnostics.Stopwatch]::StartNew()
$blockingRecords = @($operations | Where-Object {
    $_.lifecycle -cne 'terminal' -and
    (-not [bool]$_.schemaCompatible -or
        -not [bool]$_.policyCompatible -or
        @($_.errors).Count -ne 0)
} | ForEach-Object { [string]$_.operationId })
$blockingWatch.Stop()
$status = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-status'
    schemaVersion = 1
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    complete = $complete
    policyPath = [string]$policy.path
    policySha256 = [string]$policy.sha256
    policySchemaVersion = [long]$policy.schemaVersion
    migrationReadiness = [pscustomobject][ordered]@{
        evaluated = $false
        candidatePolicyPath = $null
        candidatePolicySha256 = $null
        candidatePolicySchemaVersion = $null
        ready = ($complete -and $blockingRecords.Count -eq 0)
        blockingRecords = @($blockingRecords)
    }
    operations = @($operations)
    metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
}
$serializeWatch = [Diagnostics.Stopwatch]::StartNew()
$statusJson = $status | ConvertTo-Json -Depth 12 -Compress
$serializeWatch.Stop()
$statusJsonSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes($statusJson))).ToLowerInvariant()
$semanticSource = $status | Select-Object -Property * -ExcludeProperty capturedAtUtc, metrics
$semanticSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes(($semanticSource | ConvertTo-Json -Depth 100 -Compress)))).ToLowerInvariant()

$byMode = @{}
foreach ($row in $perOp) {
    if (-not $byMode.ContainsKey($row.mode)) {
        $byMode[$row.mode] = [pscustomobject]@{ count = 0L; totalMs = 0L; maxMs = 0L }
    }
    $byMode[$row.mode].count++
    $byMode[$row.mode].totalMs += $row.elapsedMs
    if ($row.elapsedMs -gt $byMode[$row.mode].maxMs) { $byMode[$row.mode].maxMs = $row.elapsedMs }
}
$byLifecycle = @{}
foreach ($row in $perOp) {
    $key = $row.lifecycle
    if (-not $byLifecycle.ContainsKey($key)) {
        $byLifecycle[$key] = [pscustomobject]@{ count = 0L; totalMs = 0L; maxMs = 0L }
    }
    $byLifecycle[$key].count++
    $byLifecycle[$key].totalMs += $row.elapsedMs
    if ($row.elapsedMs -gt $byLifecycle[$key].maxMs) { $byLifecycle[$key].maxMs = $row.elapsedMs }
}

$result = [pscustomobject][ordered]@{
    artifactType = 'issue58.n1-perop-profile'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    repoHead = (git -C $repo rev-parse HEAD).Trim()
    libLoadMs = $libLoadMs
    policyReadMs = $policyWatch.ElapsedMilliseconds
    directoryEnumerationMs = $enumWatch.ElapsedMilliseconds
    fastScanMs = $fastWatch.ElapsedMilliseconds
    loopMs = $loopWatch.ElapsedMilliseconds
    blockingBuildMs = $blockingWatch.ElapsedMilliseconds
    statusObjectBuildAndMetricsMs = 0L
    serializeMs = $serializeWatch.ElapsedMilliseconds
    totalInProcessMs = $watch.ElapsedMilliseconds
    runItemCount = $runItems.Count
    fastHandled = $fastHandled
    fastFallback = $fastFallback
    operationCount = $operations.Count
    complete = $complete
    blockingCount = $blockingRecords.Count
    statusJsonBytes = [Text.Encoding]::UTF8.GetByteCount($statusJson)
    statusJsonSha256 = $statusJsonSha256
    semanticSha256 = $semanticSha256
    metricsElapsedMs = [long]$status.metrics.elapsedMs
    metricsEntriesScanned = [long]$status.metrics.entriesScanned
    metricsBytesHashed = [long]$status.metrics.bytesHashed
    segments = [pscustomobject][ordered]@{
        planTransactionReadMs = [long]$metricsState.segmentPlanTransactionReadMs
        terminalArchiveAuthMs = [long]$metricsState.segmentTerminalArchiveAuthMs
        treeMaterializationMs = [long]$metricsState.segmentTreeMaterializationMs
        sha256Ms = [long]$metricsState.segmentSha256Ms
        activeResolveMs = [long]$metricsState.segmentActiveResolveMs
        archivedResolveMs = [long]$metricsState.segmentArchivedResolveMs
        approvedPlanValidationReuseCount = [long]$metricsState.approvedPlanValidationReuseCount
    }
    byMode = $byMode
    byLifecycle = $byLifecycle
    slowestOps = @($perOp | Sort-Object -Property elapsedMs -Descending | Select-Object -First 25)
    perOp = @($perOp)
}
# Note: statusObjectBuildMs folded into loop tail; not separately instrumented (negligible).
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output ("libLoadMs={0} policyMs={1} enumMs={2} fastScanMs={3} loopMs={4} serializeMs={5} totalMs={6} ops={7} handled={8} fallback={9}" -f
    $libLoadMs, $policyWatch.ElapsedMilliseconds, $enumWatch.ElapsedMilliseconds,
    $fastWatch.ElapsedMilliseconds, $loopWatch.ElapsedMilliseconds,
    $serializeWatch.ElapsedMilliseconds, $watch.ElapsedMilliseconds,
    $operations.Count, $fastHandled, $fastFallback)
Write-Output ("treeMaterializationMs={0} planTransactionReadMs={1} sha256Ms={2} terminalArchiveAuthMs={3}" -f
    $metricsState.segmentTreeMaterializationMs, $metricsState.segmentPlanTransactionReadMs,
    $metricsState.segmentSha256Ms, $metricsState.segmentTerminalArchiveAuthMs)
Write-Output 'perop-done'
