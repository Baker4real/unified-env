[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'recon-scan.json')
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

$policyWatch = [Diagnostics.Stopwatch]::StartNew()
$policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyPath
$policyWatch.Stop()

$enumWatch = [Diagnostics.Stopwatch]::StartNew()
$runItems = @(Get-ChildItem -LiteralPath $evidenceRoot -Force -ErrorAction Stop |
    Sort-Object -Property Name -CaseSensitive)
$enumWatch.Stop()

$scanWatch = [Diagnostics.Stopwatch]::StartNew()
$fastResults = Invoke-CodexSafeTreeDeleteStatusFastScan `
    -RunItems $runItems `
    -Policy $policy `
    -FullEvidenceRoot $evidenceRoot `
    -MetricsState $metricsState `
    -DegreeOfParallelism (Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit)
$scanWatch.Stop()

$handledLifecycle = @{}
$fallbackReasons = @{}
$activeOps = [Collections.Generic.List[object]]::new()
foreach ($runItem in $runItems) {
    $scanResult = $fastResults[[string]$runItem.FullName]
    if ($null -eq $scanResult) {
        if (-not $fallbackReasons.ContainsKey('missing-result')) { $fallbackReasons['missing-result'] = 0 }
        $fallbackReasons['missing-result']++
        continue
    }
    if ([bool]$scanResult.Handled) {
        $lc = [string]$scanResult.Lifecycle
        if (-not $handledLifecycle.ContainsKey($lc)) { $handledLifecycle[$lc] = 0 }
        $handledLifecycle[$lc]++
        continue
    }
    $reason = [string]$scanResult.FallbackReason
    if (-not $fallbackReasons.ContainsKey($reason)) { $fallbackReasons[$reason] = 0 }
    $fallbackReasons[$reason]++
    if ($reason -cne 'plan-approved') { continue }
    # Active approved-plan fallback: extract target/generation from the scanned plan text,
    # then read transaction status (small file) to classify the live tree under verification.
    $bindings = Get-CodexSafeTreeDeleteStatusJsonBindings `
        -Text ([string]$scanResult.PlanText) `
        -Names @('targetPath', 'generationId') `
        -Scope 'issue58 recon plan'
    $targetPath = Get-CodexSafeTreeDeleteStatusJsonString -Map $bindings -Name 'targetPath' -Scope 'issue58 recon plan'
    $generationId = Get-CodexSafeTreeDeleteStatusJsonString -Map $bindings -Name 'generationId' -Scope 'issue58 recon plan'
    $quarantinePath = Join-Path (Split-Path -Parent $targetPath) (
        '.codex-safe-delete-{0}.quarantine' -f $generationId)
    $transactionPath = Join-Path $runItem.FullName 'transaction.json'
    $transactionStatus = $null
    if ([IO.File]::Exists($transactionPath)) {
        $transactionText = [IO.File]::ReadAllText($transactionPath)
        $txBindings = Get-CodexSafeTreeDeleteStatusJsonBindings `
            -Text $transactionText `
            -Names @('status') `
            -Scope 'issue58 recon transaction'
        $transactionStatus = Get-CodexSafeTreeDeleteStatusJsonString -Map $txBindings -Name 'status' -Scope 'issue58 recon transaction'
    }
    $targetState = Get-CodexSafeTreeDeleteNamespaceState -Path $targetPath
    $quarantineState = Get-CodexSafeTreeDeleteNamespaceState -Path $quarantinePath
    $treePath = $null
    $treeKind = $null
    if ($null -eq $transactionStatus) {
        if ([string]$targetState.entryType -ceq 'directory' -and
            [string]$quarantineState.entryType -ceq 'absent') {
            $treePath = $targetPath
            $treeKind = 'planned-target'
        }
    } elseif ($transactionStatus -ceq 'purging' -or
              $transactionStatus -cin @('prepared', 'quarantined')) {
        if ([string]$targetState.entryType -ceq 'absent' -and
            [string]$quarantineState.entryType -ceq 'directory') {
            $treePath = $quarantinePath
            $treeKind = "$transactionStatus-quarantine"
        }
    }
    $activeOps.Add([pscustomobject][ordered]@{
        runName = [string]$runItem.Name
        transactionStatus = $transactionStatus
        targetPath = $targetPath
        quarantinePath = $quarantinePath
        targetEntryType = [string]$targetState.entryType
        quarantineEntryType = [string]$quarantineState.entryType
        treePath = $treePath
        treeKind = $treeKind
        planBytes = [long]$scanResult.LogicalBytes
    })
    # Release the big plan text reference promptly.
    $scanResult.PlanText = $null
}

# Fast raw entry count per live tree (stack-based .NET enumeration, no PS recursion).
$treeWatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($op in $activeOps) {
    if ($null -eq $op.treePath) { continue }
    $entryCount = 0L
    $fileCount = 0L
    $fileBytes = 0L
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push([string]$op.treePath)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
            $entryCount++
            $attr = [IO.File]::GetAttributes($entry)
            if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (($attr -band [IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push($entry)
            } else {
                $fileCount++
                $fileBytes += [IO.FileInfo]::new($entry).Length
            }
        }
    }
    $op | Add-Member -NotePropertyName treeEntryCount -NotePropertyValue $entryCount -Force
    $op | Add-Member -NotePropertyName treeFileCount -NotePropertyValue $fileCount -Force
    $op | Add-Member -NotePropertyName treeFileBytes -NotePropertyValue $fileBytes -Force
}
$treeWatch.Stop()

$result = [pscustomobject][ordered]@{
    artifactType = 'issue58.n1-recon-scan'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    repoHead = (git -C $repo rev-parse HEAD).Trim()
    libLoadMs = $libLoadMs
    policyReadMs = $policyWatch.ElapsedMilliseconds
    directoryEnumerationMs = $enumWatch.ElapsedMilliseconds
    runItemCount = $runItems.Count
    fastScanMs = $scanWatch.ElapsedMilliseconds
    fastScanBytesHashed = [long]$metricsState.bytesHashed
    handledLifecycle = $handledLifecycle
    fallbackReasons = $fallbackReasons
    activePlanApprovedOps = $activeOps.Count
    opsWithLiveTree = @($activeOps | Where-Object { $null -ne $_.treePath }).Count
    totalLiveTreeEntries = [long](($activeOps | Where-Object { $null -ne $_.treePath } |
        Measure-Object -Property treeEntryCount -Sum).Sum)
    totalLiveTreeFileBytes = [long](($activeOps | Where-Object { $null -ne $_.treePath } |
        Measure-Object -Property treeFileBytes -Sum).Sum)
    treeEnumerationMs = $treeWatch.ElapsedMilliseconds
    ops = @($activeOps)
}
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output ("libLoadMs={0} policyMs={1} enumMs={2} runs={3} fastScanMs={4} activePlanApproved={5} withTree={6} totalTreeEntries={7} treeEnumMs={8}" -f
    $libLoadMs, $policyWatch.ElapsedMilliseconds, $enumWatch.ElapsedMilliseconds, $runItems.Count,
    $scanWatch.ElapsedMilliseconds, $activeOps.Count, $result.opsWithLiveTree,
    $result.totalLiveTreeEntries, $treeWatch.ElapsedMilliseconds)
Write-Output 'recon-done'
