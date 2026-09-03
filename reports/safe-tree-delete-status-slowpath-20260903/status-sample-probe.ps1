$ErrorActionPreference = 'Stop'
$repo = 'D:\agents\projects\统一环境'
. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')

$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'

$metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
$observer = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
$policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyPath -MetricsObserver $observer

$runItems = @(Get-ChildItem -LiteralPath $evidenceRoot -Force | Sort-Object -Property Name -CaseSensitive)
Write-Output ("totalRuns={0}" -f $runItems.Count)

$withSize = foreach ($r in $runItems) {
    $p = Join-Path $r.FullName 'plan.json'
    $bytes = -1L
    if (Test-Path -LiteralPath $p) { $bytes = (Get-Item -LiteralPath $p).Length }
    [pscustomobject]@{ Item = $r; PlanBytes = $bytes }
}
$day02 = @($withSize | Where-Object { $_.Item.Name -like '20260902T*' })
$older = @($withSize | Where-Object { $_.Item.Name -notlike '20260902T*' })
Write-Output ("day02Runs={0} olderRuns={1}" -f $day02.Count, $older.Count)

$rand = [Random]::new(20260902)
$sample = @()
$sample += @($day02 | Sort-Object PlanBytes -Descending | Select-Object -First 5)
$sample += @($day02 | Sort-Object { $rand.Next() } | Select-Object -First 15)
$sample += @($older | Sort-Object { $rand.Next() } | Select-Object -First 10)
$sampleRuns = @($sample | ForEach-Object { $_.Item })
Write-Output ("sampleRuns={0}" -f $sampleRuns.Count)

$dop = Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit
$sw = [Diagnostics.Stopwatch]::StartNew()
$fast = Invoke-CodexSafeTreeDeleteStatusFastScan -RunItems $sampleRuns -Policy $policy -FullEvidenceRoot $evidenceRoot -MetricsState $metricsState -DegreeOfParallelism $dop
$sw.Stop()
Write-Output ("fastScanSampleMs={0} dop={1}" -f $sw.ElapsedMilliseconds, $dop)

$handled = 0L
$fallbackRows = @()
foreach ($r in $sampleRuns) {
    $fr = $fast[[string]$r.FullName]
    $sizeRow = $withSize | Where-Object { [string]$_.Item.FullName -ceq [string]$r.FullName } | Select-Object -First 1
    $mb = if ($null -ne $sizeRow -and $sizeRow.PlanBytes -ge 0) { [math]::Round($sizeRow.PlanBytes / 1MB, 1) } else { -1 }
    if ($null -ne $fr -and [bool]$fr.Handled) { $handled++ } else {
        $fallbackRows += [pscustomobject]@{
            name = $r.Name; planMB = $mb; reason = if ($null -ne $fr) { [string]$fr.FallbackReason } else { 'no-result' }
        }
    }
}
Write-Output ("sampleHandled={0} sampleFallback={1}" -f $handled, $fallbackRows.Count)
Write-Output '--- fallback reasons ---'
$fallbackRows | Group-Object reason | Sort-Object Count -Descending | ForEach-Object {
    Write-Output ("{0}x {1}" -f $_.Count, $_.Name)
}
Write-Output '--- fallback rows (sorted by planMB desc) ---'
$fallbackRows | Sort-Object planMB -Descending | ForEach-Object {
    Write-Output ("{0}  planMB={1}  {2}" -f $_.name, $_.planMB, $_.reason)
}

$treeCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$manifestShaCache = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$prefetch = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $fallbackRows) {
    $fr = $fast[(Join-Path $evidenceRoot $row.name)]
    if ($null -ne $fr -and $null -ne $fr.PlanSha256 -and -not $prefetch.ContainsKey((Join-Path $evidenceRoot $row.name))) {
        $prefetch[(Join-Path $evidenceRoot $row.name)] = [pscustomobject][ordered]@{
            snapshot = [pscustomobject][ordered]@{ sha256 = [string]$fr.PlanSha256; text = [string]$fr.PlanText }
            document = $null
        }
    }
}

$resolveTargets = @($fallbackRows | Sort-Object planMB | Select-Object -First 8)
Write-Output '--- reference resolve timing (ascending plan size) ---'
foreach ($row in $resolveTargets) {
    $runItem = $sampleRuns | Where-Object { $_.Name -ceq $row.name } | Select-Object -First 1
    $w = [Diagnostics.Stopwatch]::StartNew()
    try {
        $op = Resolve-CodexSafeTreeDeleteStatusOperation `
            -RunItem $runItem `
            -PolicyPath $policyPath `
            -CurrentPolicySha256 ([string]$policy.sha256) `
            -FullEvidenceRoot $evidenceRoot `
            -CandidatePolicyRequested:$false `
            -CandidatePolicy $null `
            -MetricsState $metricsState `
            -TreeMetricsObserver $observer `
            -StatusTreeCache $treeCache `
            -LoadedPolicy $policy `
            -StatusPlanPrefetch $prefetch `
            -PlanManifestShaCache $manifestShaCache
        $w.Stop()
        Write-Output ("{0}  resolveMs={1}  lifecycle={2}" -f $row.name, $w.ElapsedMilliseconds, [string]$op.operation.lifecycle)
    } catch {
        $w.Stop()
        Write-Output ("{0}  resolveMs={1}  THREW: {2}" -f $row.name, $w.ElapsedMilliseconds, $_.Exception.Message)
    }
}
Write-Output 'probe-done'
