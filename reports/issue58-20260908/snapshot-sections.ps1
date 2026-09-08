[CmdletBinding()]
param(
    [string]$ReconPath = (Join-Path $PSScriptRoot 'recon-scan.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'snapshot-sections.json'),
    [string[]]$RunNames = @(
        '20260902T091741Z-8fd7a020-d26c-4b3a-9756-a3580880e79a',
        '20260905T115125Z-55f5ecb4-77ab-43a5-aa25-0efbc07a6de6'
    )
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'D:\agents\projects\统一环境'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'
. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')
$policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyPath

# Instrumented replica of CodexHostSafety.ps1:827-941
# (Add-CodexHookCapabilityDirectoryTreeSnapshotNode). Control flow and library calls are
# identical; only stopwatch accumulation was added around each section.
$script:t = [ordered]@{
    dirGetItemMs = 0L
    dirEntryAddMs = 0L
    enumChildrenMs = 0L
    childGetItemMs = 0L
    assertChildPathMs = 0L
    dirGuardAcquireMs = 0L
    fileGuardAcquireMs = 0L
    leaseAcquireMs = 0L
    sha256Ms = 0L
    fileEntryAddMs = 0L
    observerMs = 0L
    junctionMs = 0L
    directories = 0L
    files = 0L
    junctions = 0L
    bytesHashed = 0L
}
$script:sw = [Diagnostics.Stopwatch]::new()

function Add-Issue58SnapshotNode {
    param(
        [Parameter(Mandatory)][string]$DirectoryPath,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][object]$DirectoryGuard,
        [Parameter(Mandatory)][object]$Context
    )

    $script:sw.Restart()
    $item = Get-Item -LiteralPath $DirectoryPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "snapshot 遇到非安全普通目录：$DirectoryPath"
    }
    $script:t.dirGetItemMs += $script:sw.ElapsedMilliseconds

    $script:sw.Restart()
    $Context.Entries.Add([pscustomobject][ordered]@{
        relativePath = $RelativePath
        kind = 'directory'
        sha256 = $null
        identity = @([string]$DirectoryGuard.VolumeSerialNumber, [string]$DirectoryGuard.FileIndex)
    })
    $script:t.directories++
    $script:t.dirEntryAddMs += $script:sw.ElapsedMilliseconds

    $script:sw.Restart()
    $children = @(Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction Stop | Sort-Object -Property Name)
    $script:t.enumChildrenMs += $script:sw.ElapsedMilliseconds

    foreach ($child in $children) {
        $childPath = Join-Path $DirectoryPath $child.Name
        $childRelative = if ($RelativePath -ceq '.') { $child.Name } else { "$RelativePath/$($child.Name)" }
        $script:sw.Restart()
        $childItem = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
        $script:t.childGetItemMs += $script:sw.ElapsedMilliseconds
        if (($childItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $script:sw.Restart()
            if (-not $Context.AllowInternalDirectoryJunctions -or -not $childItem.PSIsContainer) {
                throw "snapshot 包含未授权 reparse point：$childPath"
            }
            [void](Assert-CodexHookCapabilityLeafPath `
                -Path $childPath `
                -CapabilityRoot $Context.CapabilityRootPath `
                -Name "snapshot junction leaf")
            $junctionLease = $null
            try {
                $junctionLease = $DirectoryGuard.AcquireSafeTreeDeleteReparseLeafLease($childPath)
                $junctionTarget = Assert-CodexHookDPath `
                    -Value ([string]$junctionLease.TargetPath) `
                    -Name "snapshot junction target"
                if (-not (Test-CodexHookPathWithin -Path $junctionTarget -ParentPath $Context.JunctionTargetRoot)) {
                    throw "snapshot junction target 越界：$childPath"
                }
                [byte[]]$junctionSha256 = $junctionLease.ReparseDataSha256
                $Context.Entries.Add([pscustomobject][ordered]@{
                    relativePath = $childRelative
                    kind = 'directory-junction'
                    sha256 = [Convert]::ToHexString($junctionSha256).ToLowerInvariant()
                    identity = @(
                        [string]$junctionLease.VolumeSerialNumber,
                        [string]$junctionLease.FileIndex)
                })
                $script:t.junctions++
            } finally {
                if ($null -ne $junctionLease) { $junctionLease.Dispose() }
            }
            $script:t.junctionMs += $script:sw.ElapsedMilliseconds
            continue
        }
        $script:sw.Restart()
        [void](Assert-CodexHookCapabilityPath `
            -Path $childPath `
            -CapabilityRoot $Context.CapabilityRootPath `
            -Name "snapshot child")
        $script:t.assertChildPathMs += $script:sw.ElapsedMilliseconds
        if ($childItem.PSIsContainer) {
            $script:sw.Restart()
            $childGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
                $Context.CapabilityRootPath,
                $childPath,
                $false)
            $script:t.dirGuardAcquireMs += $script:sw.ElapsedMilliseconds
            try {
                Add-Issue58SnapshotNode `
                    -DirectoryPath $childPath `
                    -RelativePath $childRelative `
                    -DirectoryGuard $childGuard `
                    -Context $Context
            } finally {
                $childGuard.Dispose()
            }
            continue
        }

        $script:sw.Restart()
        $parentGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
            $Context.CapabilityRootPath,
            $DirectoryPath,
            $false)
        $script:t.fileGuardAcquireMs += $script:sw.ElapsedMilliseconds
        $lease = $null
        try {
            $script:sw.Restart()
            $lease = $parentGuard.AcquireSafeTreeDeleteFileLease(
                $childPath,
                $Context.AllowHardLinks)
            $script:t.leaseAcquireMs += $script:sw.ElapsedMilliseconds
            $length = [long]$lease.Length
            $fileIdentity = @([string]$lease.VolumeSerialNumber, [string]$lease.FileIndex)
            $script:sw.Restart()
            [byte[]]$sha256 = $lease.ComputeSha256FromHandle()
            $script:t.sha256Ms += $script:sw.ElapsedMilliseconds
            $script:t.bytesHashed += $length
            $script:sw.Restart()
            $Context.Entries.Add([pscustomobject][ordered]@{
                relativePath = $childRelative
                kind = 'file'
                sha256 = [Convert]::ToHexString($sha256).ToLowerInvariant()
                identity = $fileIdentity
            })
            $script:t.files++
            $script:t.fileEntryAddMs += $script:sw.ElapsedMilliseconds
        } finally {
            if ($null -ne $lease) { $lease.Dispose() }
            $parentGuard.Dispose()
        }
    }
}

$recon = Get-Content -LiteralPath $ReconPath -Raw | ConvertFrom-Json
$treeOps = @($recon.ops | Where-Object { $null -ne $_.treePath -and $RunNames -contains [string]$_.runName })
if ($treeOps.Count -eq 0) { throw 'No recon operations matched the requested run names.' }

$results = [Collections.Generic.List[object]]::new()
foreach ($op in $treeOps) {
    $treePath = [string]$op.treePath
    # Resolve capability parameters exactly like production does for this op kind.
    $runDirectory = Join-Path 'D:\agents\run-evidence\safe-tree-delete' ([string]$op.runName)
    $planPath = Join-Path $runDirectory 'plan.json'
    $planSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $planPath `
        -Name 'issue58 sections plan' -AllowedExactPaths @($planPath)
    $plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $approved = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath $planPath `
        -ApprovedPlanSha256 ([string]$planSnapshot.sha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot 'D:\agents\run-evidence\safe-tree-delete' `
        -AllowMissingTarget -AllowExpiredPlan -AllowPolicyShaDrift `
        -PreloadedSnapshot $planSnapshot `
        -PreparsedDocument $plan `
        -LoadedPolicy $policy
    if ($op.treeKind -ceq 'planned-target') {
        $capabilityRoot = [string]$approved.target.capabilityRoot
    } else {
        $capabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $approved.target
    }

    foreach ($key in @($script:t.Keys)) { $script:t[$key] = 0L }
    $context = [pscustomobject]@{
        Entries = [Collections.Generic.List[object]]::new()
        CapabilityRootPath = Assert-CodexHookDPath -Value $capabilityRoot -Name 'issue58 sections capability root'
        JunctionTargetRoot = [string]$approved.target.targetPath
        AllowHardLinks = [bool]$approved.target.allowHardLinks
        AllowInternalDirectoryJunctions = [bool]$approved.target.allowInternalDirectoryJunctions
    }
    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $treePath `
        -CapabilityRoot $context.CapabilityRootPath `
        -AllowedExactPaths @($treePath) `
        -Name 'issue58 sections snapshot'
    $totalWatch = [Diagnostics.Stopwatch]::StartNew()
    $rootGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $context.CapabilityRootPath, $fullPath, $false)
    try {
        Add-Issue58SnapshotNode `
            -DirectoryPath $fullPath `
            -RelativePath '.' `
            -DirectoryGuard $rootGuard `
            -Context $context
    } finally {
        $rootGuard.Dispose()
    }
    $totalWatch.Stop()
    $sectionSum = 0L
    foreach ($key in @($script:t.Keys)) {
        if ($key -clike '*Ms') { $sectionSum += [long]$script:t[$key] }
    }
    $depthTotal = 0L
    $depthMax = 0
    foreach ($entry in $context.Entries) {
        $depth = 0
        if ([string]$entry.relativePath -cne '.') {
            $depth = ([regex]::Matches([string]$entry.relativePath, '/')).Count + 1
        }
        $depthTotal += $depth
        if ($depth -gt $depthMax) { $depthMax = $depth }
    }
    $results.Add([pscustomobject][ordered]@{
        runName = [string]$op.runName
        treeKind = [string]$op.treeKind
        treePath = $treePath
        totalSnapshotMs = [long]$totalWatch.ElapsedMilliseconds
        sectionSumMs = $sectionSum
        residualMs = [long]$totalWatch.ElapsedMilliseconds - $sectionSum
        sections = [pscustomobject]$script:t
        entryCount = $context.Entries.Count
        avgDepth = [math]::Round($depthTotal / [math]::Max(1, $context.Entries.Count), 2)
        maxDepth = $depthMax
    })
    Write-Output ("op={0} totalMs={1} sections={2}" -f $op.runName,
        $totalWatch.ElapsedMilliseconds,
        (($script:t.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ','))
}

$out = [pscustomobject][ordered]@{
    artifactType = 'issue58.n1-snapshot-sections'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    repoHead = (git -C $repo rev-parse HEAD).Trim()
    note = 'Instrumented replica of CodexHostSafety.ps1 Get-CodexHookCapabilityDirectoryTreeSnapshot recursion (lines 789-955); identical library calls, stopwatches added per section. MetricsObserver scriptblock calls omitted (measured separately as observerMs in production via segment deltas).'
    ops = @($results)
}
$json = $out | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output 'sections-done'
