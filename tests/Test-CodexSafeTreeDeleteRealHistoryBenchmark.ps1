[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #75 real-history profile, exercised only against fixture evidence and a stand-in for the
# gate shim. Every invocation passes -EvidenceRoot and -ShimPath explicitly, so this suite
# never reads production evidence or runs the production shim, even on the host.
$projectRoot = Split-Path -Parent $PSScriptRoot
$benchmark = Join-Path $projectRoot 'scripts/Measure-CodexSafeTreeDeleteHistory.ps1'
$fixtureEntry = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')

function Assert-RealHistory([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-TreeManifest([string]$Root) {
    # Names, sizes, content hashes and write times of every entry: any write shows up.
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(('root|{0}' -f [IO.Directory]::GetLastWriteTimeUtc($Root).Ticks))
    foreach ($entry in [IO.DirectoryInfo]::new($Root).EnumerateFileSystemInfos('*', [IO.SearchOption]::AllDirectories)) {
        $entry.Refresh() # listings carry lazily updated copies of sizes and times
        $relative = [IO.Path]::GetRelativePath($Root, $entry.FullName)
        if ($entry -is [IO.DirectoryInfo]) {
            $lines.Add(('d|{0}|{1}' -f $relative, $entry.LastWriteTimeUtc.Ticks))
        } else {
            $hash = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash
            $lines.Add(('f|{0}|{1}|{2}|{3}' -f $relative, $entry.Length, $entry.LastWriteTimeUtc.Ticks, $hash))
        }
    }
    $lines.Sort([StringComparer]::Ordinal)
    return ($lines -join "`n")
}

$scratchBase = Join-Path $projectRoot '.scratch'
function Get-ScratchEntryNames {
    return @([IO.Directory]::EnumerateFileSystemEntries($scratchBase) | ForEach-Object { [IO.Path]::GetFileName($_) })
}

function Get-WorktreeChanges {
    # Tracked and untracked non-ignored paths: a write outside gitignored scratch shows up here.
    $lines = @(& git --no-optional-locks -C $projectRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }
    return ($lines -join "`n")
}

function Set-CiVariables([string]$GitHubActions, [string]$Ci) {
    [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $GitHubActions)
    [Environment]::SetEnvironmentVariable('CI', $Ci)
}

$savedGitHubActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS')
$savedCi = [Environment]::GetEnvironmentVariable('CI')
try {
    # Fixture evidence: one purged and one quarantined operation produced by the real flows.
    $testRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'RealHistoryBenchmark'
    $evidence = Join-Path $testRoot 'evidence'
    $policyPath = Join-Path $testRoot 'policy.json'
    $targets = @((Join-Path $testRoot 'targets\purged'), (Join-Path $testRoot 'targets\quarantined'))
    [void][IO.Directory]::CreateDirectory($evidence)
    $entries = foreach ($index in 0..1) {
        [void][IO.Directory]::CreateDirectory($targets[$index])
        [IO.File]::WriteAllBytes((Join-Path $targets[$index] 'payload.bin'), [byte[]]::new(512))
        [ordered]@{
            id = "real-history-fixture-$index"; capabilityRoot = $targets[$index]; minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'; allowHardLinks = $false
            allowInternalDirectoryJunctions = $false; minimumQuarantineAgeMinutes = 0
            producerFenceMode = 'os-handle-required'; deniedExactPaths = @()
        }
    }
    $policyJson = [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'; schemaVersion = 5; entries = @($entries)
    } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($policyPath, $policyJson, [Text.UTF8Encoding]::new($false))
    $common = @{ FixturePolicyPath = $policyPath; FixtureEvidenceRoot = $evidence }
    $expectedPlanBytes = 0L
    $applies = foreach ($target in $targets) {
        $plan = & $fixtureEntry -Mode Plan -TargetPath $target -CapabilityRoot $target @common
        $expectedPlanBytes += ([IO.FileInfo]::new($plan.planPath)).Length
        & $fixtureEntry -Mode Apply -PlanPath $plan.planPath -ApprovedPlanSha256 $plan.planSha256 -ConfirmApply @common
    }
    $purge = & $fixtureEntry -Mode Purge -TransactionPath $applies[0].transactionPath -ApprovedTransactionSha256 $applies[0].transactionSha256 -ConfirmPurge @common
    Assert-RealHistory ([bool]$purge.purged -and [bool]$applies[1].quarantined) 'Fixture history must hold one purged and one quarantined operation.'
    # Production history also has non-run top-level directories holding stray transactions. This
    # one is named like a producer run id written in fullwidth digits; run ids have ASCII digits
    # only (.NET \d also matches other decimal digits), so it is not a run.
    $lookalikeTimestamp = -join @('20260101T000000Z'.ToCharArray() | ForEach-Object {
            if ([char]::IsAsciiDigit($_)) { [char](0xFF10 + [int]$_ - [int][char]'0') } else { $_ } })
    $strayDirectory = Join-Path $evidence ('{0}-{1}\nested' -f $lookalikeTimestamp, [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($strayDirectory)
    [IO.File]::Copy($purge.transactionPath, (Join-Path $strayDirectory 'transaction.json'))

    # Stand-in for the gate shim: same calling convention (names its repository entry in
    # $codexSafeTreeDeleteRepositoryEntry and forwards its arguments), fixture policy and
    # evidence. Its name must not match the deploy tool's legacy-caller drain.
    $standIn = Join-Path $testRoot 'status-entry-standin.ps1'
    $standInText = @(
        '$ErrorActionPreference = ''Stop'''
        ('$codexSafeTreeDeleteRepositoryEntry = ''{0}''' -f $fixtureEntry.Replace("'", "''"))
        ("& `$codexSafeTreeDeleteRepositoryEntry @args -FixturePolicyPath '{0}' -FixtureEvidenceRoot '{1}'" -f @(
            $policyPath.Replace("'", "''"), $evidence.Replace("'", "''")))
        'exit 0'
    ) -join "`n"
    [IO.File]::WriteAllText($standIn, $standInText, [Text.UTF8Encoding]::new($false))
    $absentEvidence = Join-Path $testRoot 'absent-evidence'

    $evidenceBefore = Get-TreeManifest $evidence
    $scratchBefore = Get-ScratchEntryNames
    $worktreeBefore = Get-WorktreeChanges

    # The real-history profile owns its output location; isolated-fixture options are rejected.
    $mixedRejected = $false
    try {
        & $benchmark -RealHistory -EvidenceRoot $absentEvidence -ShimPath $standIn -OutputPath (Join-Path $testRoot 'mixed.json') | Out-Null
    } catch { $mixedRejected = $true }
    Assert-RealHistory $mixedRejected 'RealHistory must not accept -OutputPath.'

    # CI never runs the profile, even where evidence exists.
    foreach ($ciCase in @(@('true', $null), @($null, 'true'))) {
        Set-CiVariables -GitHubActions $ciCase[0] -Ci $ciCase[1]
        $skip = & $benchmark -RealHistory -EvidenceRoot $evidence -ShimPath $standIn
        Assert-RealHistory ($skip.profile -ceq 'real-history' -and $skip.skipped -and $skip.skipReason -ceq 'ci-environment') 'CI must skip the real-history profile by name.'
    }

    # Named skip when the evidence root is absent; the profile must not create it.
    Set-CiVariables -GitHubActions $null -Ci $null
    $skip = & $benchmark -RealHistory -EvidenceRoot $absentEvidence -ShimPath $standIn
    Assert-RealHistory ($skip.skipped -and $skip.skipReason -ceq 'evidence-root-absent') 'Absent evidence must skip the real-history profile by name.'
    Assert-RealHistory (-not [IO.Directory]::Exists($absentEvidence)) 'Skip must not create the evidence root.'
    Assert-RealHistory ((Get-TreeManifest $evidence) -ceq $evidenceBefore) 'Skips must not touch evidence.'
    Assert-RealHistory (@(Compare-Object $scratchBefore (Get-ScratchEntryNames)).Count -eq 0) 'Skips must not write artifacts.'
    Assert-RealHistory ((Get-WorktreeChanges) -ceq $worktreeBefore) 'Skips must not write into the worktree.'

    $report = & $benchmark -RealHistory -EvidenceRoot $evidence -ShimPath $standIn
    Assert-RealHistory ((Get-TreeManifest $evidence) -ceq $evidenceBefore) 'Real-history profile must leave evidence byte-for-byte unchanged.'
    Assert-RealHistory ($report.ok -and -not $report.skipped -and $report.profile -ceq 'real-history') 'Real-history profile must complete against fixture evidence.'
    Assert-RealHistory ($report.thresholdPolicy -ceq 'record-only') 'Timing must never decide correctness.'

    # Artifacts: exactly one new gitignored run directory under .scratch, holding only the
    # probe policy and the report.
    $newScratch = @(Get-ScratchEntryNames | Where-Object { $_ -notin $scratchBefore })
    Assert-RealHistory ($newScratch.Count -eq 1 -and $newScratch[0] -cmatch '^safe-tree-delete-tests-real-history-[0-9a-f]{32}$') 'Profile must write one scratch run directory.'
    $runRoot = Join-Path $scratchBase $newScratch[0]
    Assert-RealHistory ($report.runRoot -ceq $runRoot) 'Report must name its run directory.'
    $runFiles = @(Get-ChildItem -LiteralPath $runRoot -Recurse -Force | ForEach-Object { [IO.Path]::GetRelativePath($runRoot, $_.FullName) } | Sort-Object)
    Assert-RealHistory (($runFiles -join '|') -ceq 'lookup-probe-policy.json|measurement.json') ('Unexpected run artifacts: ' + ($runFiles -join '|'))
    $measurementPath = Join-Path $runRoot 'measurement.json'
    & git -C $projectRoot check-ignore -q -- $measurementPath
    Assert-RealHistory ($LASTEXITCODE -eq 0) 'Run artifacts must be gitignored.'
    Assert-RealHistory ((Get-WorktreeChanges) -ceq $worktreeBefore) 'Real-history profile must not write outside gitignored scratch.'

    foreach ($phase in @('before', 'after')) {
        $scale = $report.historyScale.$phase
        Assert-RealHistory ($scale.runCount -eq 2 -and $scale.nonRunTopLevelEntries -eq 1 -and $scale.transactionCount -eq 3) ("History scale $phase must count runs and transactions: " + ($scale | ConvertTo-Json -Compress))
        Assert-RealHistory ($scale.planTotalBytes -eq $expectedPlanBytes) "History scale $phase must sum plan bytes."
    }
    Assert-RealHistory ([bool]$report.historyScale.stable) 'Fixture history must stay stable during the run.'

    # The stand-in names the fixture entry, so the library it delegates to is this worktree's.
    $libraryRoot = Join-Path $projectRoot 'scripts\lib'
    Assert-RealHistory ($report.delegatedLibraryRoot -ceq $libraryRoot) 'Report must name the library the shim delegates to.'
    Assert-RealHistory ($report.delegatedLibrarySha256 -ceq (Get-FileHash -LiteralPath (Join-Path $libraryRoot 'CodexSafeTreeDelete.ps1') -Algorithm SHA256).Hash) 'Report must fingerprint the delegated library.'
    $expectedVariant = if ([Environment]::GetEnvironmentVariable('CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER') -ceq '0') { 'base' } else { 'default' }

    $expectedItems = 'status-full-cold-start,reference-lookup-miss,batch-scan-direct,status-scope-1-target,status-scope-10-targets,library-load-cold-start'
    Assert-RealHistory ((@($report.items | ForEach-Object { $_.id }) -join ',') -ceq $expectedItems) 'Unexpected measurement items.'
    $persisted = Get-Content -LiteralPath $measurementPath -Raw | ConvertFrom-Json -Depth 64
    for ($itemIndex = 0; $itemIndex -lt $expectedItems.Split(',').Count; $itemIndex++) {
        $item = $report.items[$itemIndex]
        $samples = @($item.samples)
        Assert-RealHistory ($samples.Count -eq 3 -and (@($samples | ForEach-Object { $_.run }) -join ',') -ceq '1,2,3') "$($item.id) must keep three samples."
        $persistedSamples = @($persisted.items[$itemIndex].samples)
        Assert-RealHistory ($persistedSamples.Count -eq 3) "$($item.id) must persist three samples."
        for ($run = 0; $run -lt 3; $run++) {
            $sample = $samples[$run]
            Assert-RealHistory ($sample.wallMs -gt 0) "$($item.id) sample must record a raw wall time."
            Assert-RealHistory ([math]::Abs([double]$persistedSamples[$run].wallMs - [double]$sample.wallMs) -lt 0.001) "$($item.id) must persist raw values."
            if ($item.id -ceq 'status-full-cold-start') {
                Assert-RealHistory ($sample.exitCode -eq 0 -and $sample.operationCount -eq 3) 'Status sample must cover the whole fixture history.'
                Assert-RealHistory ($sample.statusElapsedMs -le $sample.wallMs) 'Status time must nest inside process wall time.'
            } elseif ($item.id -ceq 'reference-lookup-miss') {
                Assert-RealHistory ($sample.found -eq $false) 'Reference lookup must miss.'
            } elseif ($item.id -ceq 'batch-scan-direct') {
                # Both producer runs sit at canonical locations and match no probe target (one
                # terminal, one live for another target): the prefilter excludes them. The stray
                # copy is at a non-canonical location and falls back to reference authentication.
                Assert-RealHistory ($sample.candidateCount -eq 0) 'Batch scan must find no candidate for the probe target.'
                Assert-RealHistory ($sample.enumeratedFiles -eq 3 -and $sample.canonicalFiles -eq 2 -and
                    $sample.excludedByPrefilter -eq 2 -and $sample.fallbackFiles -eq 1 -and
                    $sample.fullyAuthenticated -eq 1) ('Batch scan counters must reflect the prefilter: ' + ($sample | ConvertTo-Json -Compress))
                Assert-RealHistory ($sample.scanElapsedMs -le $sample.wallMs) 'Scan time must nest inside the item wall time.'
            } elseif ($item.id -ceq 'library-load-cold-start') {
                # Since #86 every C# component of this library loads as one assembly, the shared
                # native generation; the Plan walker is in it only in the default variant.
                $components = @($sample.components)
                Assert-RealHistory ($sample.exitCode -eq 0 -and $sample.nativeVariant -ceq $expectedVariant) 'Library load must report the native variant it loaded.'
                Assert-RealHistory ($components.Count -eq 1 -and $components[0].phase -ceq 'native-generation' -and
                    $components[0].statusFastScan -eq $true -and $components[0].planWalker -eq ($expectedVariant -ceq 'default') -and
                    $components[0].typeCount -gt 0) ('Every C# component must load with the native generation: ' + ($components | ConvertTo-Json -Compress))
                $phaseSum = [double]$sample.nativeGenerationLoadMs + [double]$sample.hostSafetyLibraryMs + [double]$sample.safeTreeDeleteLibraryMs
                Assert-RealHistory ($sample.nativeGenerationLoadMs -gt 0 -and $sample.hostSafetyLibraryMs -gt 0 -and $sample.safeTreeDeleteLibraryMs -gt 0 -and
                    $phaseSum -le [double]$sample.libraryLoadMs -and [double]$sample.libraryLoadMs -le [double]$sample.wallMs) 'Library load phases must nest inside the library load and the process wall time.'
            } else {
                # Scope items (#80): history holds two targets and one unattributable top-level
                # entry; targets beyond the two history ones are never-existing probe targets.
                $expectedTargets = if ($item.id -ceq 'status-scope-1-target') { 1 } else { 10 }
                $expectedHistoryTargets = [Math]::Min($expectedTargets, 2)
                Assert-RealHistory ($sample.exitCode -eq 0 -and $sample.targetCount -eq $expectedTargets -and
                    $sample.historyTargets -eq $expectedHistoryTargets) "$($item.id) must query $expectedTargets targets, $expectedHistoryTargets of them from history."
                Assert-RealHistory ($sample.matchedRecords -eq $expectedHistoryTargets -and $sample.unattributableRecords -eq 1 -and
                    $sample.operationCount -eq $expectedHistoryTargets + 1) "$($item.id) must match each history target's record and keep the unattributable entry."
                Assert-RealHistory ($sample.statusElapsedMs -le $sample.wallMs) 'Status time must nest inside process wall time.'
            }
        }
    }
    [pscustomobject]@{ ok = $true; suite = 'CodexSafeTreeDeleteRealHistoryBenchmark'; evidence = $measurementPath }
} finally {
    Set-CiVariables -GitHubActions $savedGitHubActions -Ci $savedCi
}
