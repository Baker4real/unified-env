param([string]$RunName = '20260902T122602Z-4a062e3f-6440-4b9a-8bc6-37dc04e322af')
$ErrorActionPreference = 'Stop'
$repo = 'D:\agents\projects\统一环境'
. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')

$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'
$metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
$observer = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
$policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyPath -MetricsObserver $observer

$runItem = Get-Item -LiteralPath (Join-Path $evidenceRoot $RunName) -Force
$treeCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$manifestShaCache = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$prefetch = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)

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
    Write-Output ("run={0} resolveMs={1} lifecycle={2}" -f $RunName, $w.ElapsedMilliseconds, [string]$op.operation.lifecycle)
} catch {
    $w.Stop()
    Write-Output ("run={0} resolveMs={1} THREW: {2}" -f $RunName, $w.ElapsedMilliseconds, $_.Exception.Message)
}
Write-Output 'bigprobe-done'
