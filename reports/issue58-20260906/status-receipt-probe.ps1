param(
    [ValidateRange(1, 3)][int]$Iterations = 1,
    [switch]$ReceiptOnly,
    [switch]$AssertNoDuplicatePlanValidation,
    [switch]$ProfileComponents
)
$ErrorActionPreference = 'Stop'
$repo = 'D:\agents\projects\统一环境'
. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')
if ($ProfileComponents) {
    $script:readValidator = (Get-Command Read-CodexHookSafeUtf8FileSnapshot).ScriptBlock
    $script:readTimes = [Collections.Generic.List[object]]::new()
    function Read-CodexHookSafeUtf8FileSnapshot {
        [CmdletBinding()]
        param([string]$Path, [string]$Name, [string[]]$AllowedExactPaths = @(), [string[]]$AllowedRoots = @())
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try { & $script:readValidator @PSBoundParameters }
        finally { $script:readTimes.Add([pscustomobject]@{ name=$Name; ms=$watch.ElapsedMilliseconds }) }
    }
    $script:policyReader = (Get-Command Read-CodexSafeTreeDeletePolicy).ScriptBlock
    $script:policyMs = 0L
    function Read-CodexSafeTreeDeletePolicy {
        param([string]$PolicyPath, [scriptblock]$MetricsObserver)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try { & $script:policyReader @PSBoundParameters }
        finally { $script:policyMs += $watch.ElapsedMilliseconds }
    }
    $script:treePolicyValidator = (Get-Command Assert-CodexSafeTreeDeleteTargetTreePolicy).ScriptBlock
    $script:treePolicyMs = 0L
    function Assert-CodexSafeTreeDeleteTargetTreePolicy {
        param([object]$Target, [object]$TreeManifest, [string]$TreePath)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try { & $script:treePolicyValidator @PSBoundParameters }
        finally { $script:treePolicyMs += $watch.ElapsedMilliseconds }
    }
}

$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'
$runName = '20260902T092255Z-311486d4-5406-4e07-ab78-cfaaaaa3ca9b'
$runItem = Get-Item -LiteralPath (Join-Path $evidenceRoot $runName) -Force
$metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
$observer = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
$policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyPath -MetricsObserver $observer
$dop = Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit
$inputPaths = @((Join-Path $runItem.FullName 'plan.json'), (Join-Path $runItem.FullName 'transaction.json'), $policyPath)
$beforeHashes = @($inputPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
$scanWatch = [Diagnostics.Stopwatch]::StartNew()
$scan = Invoke-CodexSafeTreeDeleteStatusFastScan `
    -RunItems @($runItem) `
    -Policy $policy `
    -FullEvidenceRoot $evidenceRoot `
    -MetricsState $metricsState `
    -DegreeOfParallelism $dop
$scanWatch.Stop()
$result = $scan[[string]$runItem.FullName]
if ($null -eq $result -or [bool]$result.Handled -or [string]$result.FallbackReason -cne 'plan-approved') {
    throw "Expected approved-plan fallback, got handled=$($result.Handled) reason=$($result.FallbackReason)."
}

function Measure-Resolve {
    param([Parameter(Mandatory)][bool]$WithReceipt)
    $localMetrics = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    Add-Member -InputObject $localMetrics -NotePropertyName approvedPlanValidationReuseCount -NotePropertyValue 0L -Force
    $localObserver = New-CodexSafeTreeDeleteMetricsObserver -State $localMetrics
    $treeCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $manifestCache = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $prefetch = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefetched = [pscustomobject][ordered]@{
        snapshot = [pscustomobject][ordered]@{
            sha256 = [string]$result.PlanSha256
            text = [string]$result.PlanText
        }
        document = $null
    }
    if ($WithReceipt) { $prefetched | Add-Member -NotePropertyName approvedPlanValidation -NotePropertyValue $result.ApprovedPlanValidation -Force }
    $prefetch[[string]$runItem.FullName] = $prefetched
    $script:planReadCount = 0
    $script:strictPlanCount = 0
    $readBreakpoint = $null
    $strictBreakpoint = $null
    if ($AssertNoDuplicatePlanValidation) {
    $readBreakpoint = Set-PSBreakpoint -Command Read-CodexHookSafeUtf8FileSnapshot -Action {
        if ([string]$Path -ceq (Join-Path $runItem.FullName 'plan.json')) { $script:planReadCount++ }
    }
    $strictBreakpoint = Set-PSBreakpoint -Command Assert-CodexHookStrictJsonText -Action {
        if ($JsonText.Length -gt 1000000) { $script:strictPlanCount++ }
    }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
    $operation = Resolve-CodexSafeTreeDeleteStatusOperation `
        -RunItem $runItem `
        -PolicyPath $policyPath `
        -CurrentPolicySha256 ([string]$policy.sha256) `
        -FullEvidenceRoot $evidenceRoot `
        -CandidatePolicyRequested:$false `
        -CandidatePolicy $null `
        -MetricsState $localMetrics `
        -TreeMetricsObserver $localObserver `
        -StatusTreeCache $treeCache `
        -LoadedPolicy $policy `
        -StatusPlanPrefetch $prefetch `
        -PlanManifestShaCache $manifestCache
    } finally {
        if ($null -ne $readBreakpoint) { Remove-PSBreakpoint -Breakpoint $readBreakpoint, $strictBreakpoint }
    }
    $watch.Stop()
    [pscustomobject][ordered]@{
        withReceipt = $WithReceipt
        resolveMs = [long]$watch.ElapsedMilliseconds
        lifecycle = [string]$operation.operation.lifecycle
        reuseCount = [long]$localMetrics.approvedPlanValidationReuseCount
        planRereadCount = if ($AssertNoDuplicatePlanValidation) { $script:planReadCount } else { $null }
        strictPlanCount = if ($AssertNoDuplicatePlanValidation) { $script:strictPlanCount } else { $null }
        operation = ($operation.operation | ConvertTo-Json -Depth 32 -Compress)
    }
}

$control = @(if (-not $ReceiptOnly) { 1..$Iterations | ForEach-Object { Measure-Resolve -WithReceipt:$false } })
$optimized = @(1..$Iterations | ForEach-Object { Measure-Resolve -WithReceipt:$true })
$afterHashes = @($inputPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
$unchanged = ($beforeHashes -join ',') -ceq ($afterHashes -join ',')
$equal = @(@($control) + @($optimized) | Select-Object -ExpandProperty operation -Unique).Count -eq 1
$report = [pscustomobject][ordered]@{
    run = $runName
    planBytes = (Get-Item -LiteralPath (Join-Path $runItem.FullName 'plan.json')).Length
    fastScanMs = $scanWatch.ElapsedMilliseconds
    fallbackReason = [string]$result.FallbackReason
    control = $control
    optimized = $optimized
    inputHashes = $beforeHashes
    inputUnchanged = $unchanged
    operationsEqual = $equal
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'receipt-probe-result.json') -Encoding utf8
@($control) + @($optimized) | Select-Object withReceipt,resolveMs,reuseCount,planRereadCount,strictPlanCount,lifecycle | Format-Table | Out-Host
Write-Output "fastScanMs=$($scanWatch.ElapsedMilliseconds) inputUnchanged=$unchanged operationsEqual=$equal"
if ($ProfileComponents) {
    $parseWatch = [Diagnostics.Stopwatch]::StartNew()
    $parsedPlan = $result.PlanText | ConvertFrom-Json -Depth 128 -DateKind String
    $parseWatch.Stop()
    Write-Output "parseMs=$($parseWatch.ElapsedMilliseconds) treePolicyMs=$script:treePolicyMs manifestEntryCount=$(@($parsedPlan.treeManifest.entries).Count)"
    Write-Output "policyMs=$script:policyMs"
    $script:readTimes | Format-Table | Out-Host
}
if (-not $unchanged -or -not $equal) { throw 'Input integrity or operation equivalence failed.' }
if ($AssertNoDuplicatePlanValidation -and @($optimized | Where-Object { $_.strictPlanCount -ne 0 }).Count -ne 0) {
    throw 'Status receipt path repeated strict JSON validation.'
}
