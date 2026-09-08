[CmdletBinding()]
param(
    [string]$ReconPath = (Join-Path $PSScriptRoot 'recon-scan.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'substage-profile.json'),
    [int]$TopN = 4
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'D:\agents\projects\统一环境'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'

$libWatch = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')
$libWatch.Stop()

$policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyPath

$recon = Get-Content -LiteralPath $ReconPath -Raw | ConvertFrom-Json
$treeOps = @($recon.ops | Where-Object { $null -ne $_.treePath } |
    Sort-Object -Property treeEntryCount -Descending | Select-Object -First $TopN)
if ($treeOps.Count -eq 0) { throw 'Recon file carries no live-tree operations.' }

$results = [Collections.Generic.List[object]]::new()
foreach ($op in $treeOps) {
    $runDirectory = Join-Path $evidenceRoot ([string]$op.runName)
    $planPath = Join-Path $runDirectory 'plan.json'
    $transactionPath = Join-Path $runDirectory 'transaction.json'
    $row = [ordered]@{
        runName = [string]$op.runName
        treeKind = [string]$op.treeKind
        treePath = [string]$op.treePath
        treeEntryCount = [long]$op.treeEntryCount
        treeFileCount = [long]$op.treeFileCount
        treeFileBytes = [long]$op.treeFileBytes
        planJsonBytes = [long]([IO.FileInfo]::new($planPath).Length)
        stages = [ordered]@{}
    }
    # 1. plan read+hash (production: reused from fast scan snapshot; measure reference cost)
    $w = [Diagnostics.Stopwatch]::StartNew()
    $planSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $planPath `
        -Name 'issue58 substage plan' -AllowedExactPaths @($planPath)
    $w.Stop(); $row.stages['planReadHashMs'] = [long]$w.ElapsedMilliseconds
    # 2. strict JSON validation (skipped in production when receipt matches; reference cost)
    $w = [Diagnostics.Stopwatch]::StartNew()
    Assert-CodexHookStrictJsonText -JsonText $planSnapshot.text
    $w.Stop(); $row.stages['planStrictJsonMs'] = [long]$w.ElapsedMilliseconds
    # 3. plan parse (production pays this even with receipt: CodexSafeTreeDelete.ps1:4524)
    $w = [Diagnostics.Stopwatch]::StartNew()
    $plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $w.Stop(); $row.stages['planConvertFromJsonMs'] = [long]$w.ElapsedMilliseconds
    $row.planManifestEntryCount = [long]@($plan.treeManifest.entries).Count
    # 4. approved-plan read without receipt (worst case: includes manifest conversion)
    $w = [Diagnostics.Stopwatch]::StartNew()
    $approved = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath $planPath `
        -ApprovedPlanSha256 ([string]$planSnapshot.sha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -AllowMissingTarget -AllowExpiredPlan -AllowPolicyShaDrift `
        -PreloadedSnapshot $planSnapshot `
        -PreparsedDocument $plan `
        -LoadedPolicy $policy
    $w.Stop(); $row.stages['approvedPlanReadNoReceiptMs'] = [long]$w.ElapsedMilliseconds
    # 5. plan manifest structural conversion alone (skipped in production with receipt)
    $w = [Diagnostics.Stopwatch]::StartNew()
    $plannedManifest = ConvertTo-CodexHookExpectedDirectoryTreeManifest `
        -Manifest $plan.treeManifest -Scope 'issue58 substage planned'
    $w.Stop(); $row.stages['planManifestConvertMs'] = [long]$w.ElapsedMilliseconds
    # 6. plan manifest ConvertTo-Json + SHA-256 (production: cached per plan sha)
    $w = [Diagnostics.Stopwatch]::StartNew()
    $planManifestSha = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest
    $w.Stop(); $row.stages['planManifestJsonShaMs'] = [long]$w.ElapsedMilliseconds
    # 7. live tree snapshot (production: Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot,
    #    fresh cache = same work; segmentTreeMaterializationMs)
    $freshCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $treeMetricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    $observer = New-CodexSafeTreeDeleteMetricsObserver -State $treeMetricsState
    $treePath = [string]$op.treePath
    if ($op.treeKind -ceq 'planned-target') {
        $snapshotCapabilityRoot = [string]$approved.target.capabilityRoot
        $allowed = @($treePath)
    } else {
        $snapshotCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $approved.target
        $allowed = @($treePath)
    }
    $w = [Diagnostics.Stopwatch]::StartNew()
    $tree = Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
        -Path $treePath `
        -CapabilityRoot $snapshotCapabilityRoot `
        -AllowedExactPaths $allowed `
        -AllowHardLinks:([bool]$approved.target.allowHardLinks) `
        -AllowInternalDirectoryJunctions:([bool]$approved.target.allowInternalDirectoryJunctions) `
        -InternalDirectoryJunctionTargetRoot ([string]$approved.target.targetPath) `
        -MetricsObserver $observer `
        -Name 'issue58 substage tree' `
        -StatusTreeCache $freshCache `
        -MetricsState $treeMetricsState
    $w.Stop(); $row.stages['liveTreeSnapshotMs'] = [long]$w.ElapsedMilliseconds
    $row.liveTreeEntryCount = [long]@($tree.entries).Count
    # 8. live manifest ConvertTo-Json + SHA-256 (production: every planned/recoverable op)
    $w = [Diagnostics.Stopwatch]::StartNew()
    $liveSha = Get-CodexSafeTreeDeleteStatusLiveManifestSha256 -Snapshot $tree
    $w.Stop(); $row.stages['liveManifestJsonShaMs'] = [long]$w.ElapsedMilliseconds
    # 9. purging-only: partial purge manifest assert (production line 3911)
    if ($op.treeKind -ceq 'purging-quarantine') {
        $w = [Diagnostics.Stopwatch]::StartNew()
        $currentManifest = ConvertTo-CodexHookExpectedDirectoryTreeManifest `
            -Manifest $tree -Scope 'issue58 substage current'
        $w.Stop(); $row.stages['currentManifestConvertMs'] = [long]$w.ElapsedMilliseconds
        $w = [Diagnostics.Stopwatch]::StartNew()
        Assert-CodexSafeTreeDeletePartialPurgeManifest `
            -CurrentManifest $tree `
            -PlannedManifest $plan.treeManifest
        $w.Stop(); $row.stages['partialPurgeAssertTotalMs'] = [long]$w.ElapsedMilliseconds
    }
    $row.stageSumMs = [long](($row.stages.GetEnumerator() | Measure-Object -Property Value -Sum).Sum)
    $results.Add([pscustomobject]$row)
    Write-Output ("op={0} kind={1} stages={2}" -f $op.runName, $op.treeKind,
        (($row.stages.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ','))
}

$out = [pscustomobject][ordered]@{
    artifactType = 'issue58.n1-substage-profile'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    repoHead = (git -C $repo rev-parse HEAD).Trim()
    libLoadMs = $libWatch.ElapsedMilliseconds
    ops = @($results)
}
$json = $out | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output 'substage-done'
