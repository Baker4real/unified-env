[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$benchmark = Join-Path $projectRoot 'scripts/Measure-CodexSafeTreeDeleteHistory.ps1'
function Assert-History([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
Assert-History (Test-Path -LiteralPath $benchmark -PathType Leaf) 'History benchmark script must exist.'
$report = & $benchmark -HistoryCounts @(0, 2, 5)
$output=Join-Path $report.runRoot 'measurement.json'
Assert-History ($report.ok -and $report.profile -ceq 'isolated-fixture') 'Benchmark must complete its isolated fixture.'
Assert-History ($report.thresholdPolicy -ceq 'record-only') 'Timing must never decide correctness.'
Assert-History ($report.cases.Count -eq 3) 'All requested history sizes must run.'
Assert-History ($report.startup.coldProcessWallMs -ge $report.startup.libraryLoadMs) 'Startup boundaries must be nested.'
foreach ($case in $report.cases) {
    Assert-History ($case.historyCount -in @(0, 2, 5)) 'Unexpected history size.'
    Assert-History ($case.lookupMissWasNull -and $case.lookupHitMatched) 'Lookup semantics must hold at every history size.'
    Assert-History ($case.targetAbsent -and $case.quarantineAbsent) 'Purge must remove both namespaces.'
    Assert-History ($case.historyUnchanged -and $case.finalStatus -ceq 'purged') 'Receipt and corpus consistency must hold.'
    Assert-History ($case.physicalReclaimStatus -ceq 'unknown') 'Logical purge cannot prove physical reclaim.'
    foreach ($phase in @('lookupMissMs','lookupHitMs','planWallMs','applyWallMs','purgeWallMs')) {
        Assert-History ($case.$phase -ge 0) "Missing measured phase: $phase"
    }
}
$persisted = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -Depth 64
Assert-History ($persisted.ok -and $persisted.cases.Count -eq 3) 'Persisted evidence must match successful execution.'
$rejected = $false
try { & $benchmark -OutputPath $output -HistoryCounts @(2, 1) | Out-Null } catch { $rejected = $true }
Assert-History $rejected 'Non-increasing history sequence must be rejected.'
[pscustomobject]@{ ok = $true; suite = 'CodexSafeTreeDeleteHistoryBenchmark'; cases = 3; evidence = $output }
