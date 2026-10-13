[CmdletBinding(DefaultParameterSetName = 'IsolatedFixture')]
param(
    [Parameter(ParameterSetName = 'IsolatedFixture')][string]$OutputPath,
    [Parameter(ParameterSetName = 'IsolatedFixture')][ValidateRange(0, 10000)][int[]]$HistoryCounts = @(0, 100, 1000),
    [Parameter(ParameterSetName = 'IsolatedFixture')][switch]$ColdStartProbe,
    # Real-history profile (#75): read-only measurements against production evidence. Run it
    # only in a quiet window agreed with the user: Status samples hold the deployment gate.
    [Parameter(ParameterSetName = 'RealHistory', Mandatory)][switch]$RealHistory,
    [Parameter(ParameterSetName = 'RealHistory')][string]$EvidenceRoot = 'D:\agents\run-evidence\safe-tree-delete',
    [Parameter(ParameterSetName = 'RealHistory')][string]$ShimPath = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($RealHistory) {
    # Named skips run before any library load or write. CI never runs this profile.
    $skipReason = if ([string]$env:GITHUB_ACTIONS -eq 'true' -or [string]$env:CI -eq 'true') {
        'ci-environment'
    } elseif (-not [IO.Directory]::Exists($EvidenceRoot)) {
        'evidence-root-absent'
    } else { $null }
    if ($null -ne $skipReason) {
        return [pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-history-benchmark'; schemaVersion = 1
            ok = $true; profile = 'real-history'; skipped = $true; skipReason = $skipReason; evidenceRoot = $EvidenceRoot
        }
    }
}
$libraryPath = Join-Path $PSScriptRoot 'lib/CodexSafeTreeDelete.ps1'
$loadWatch = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'lib/CodexHostSafety.ps1')
. $libraryPath
$loadWatch.Stop()
if ($ColdStartProbe) {
    [pscustomobject]@{ libraryLoadMs = $loadWatch.Elapsed.TotalMilliseconds } | ConvertTo-Json -Compress
    return
}
if ($HistoryCounts.Count -eq 0) { throw 'HistoryCounts must not be empty.' }
for ($i = 1; $i -lt $HistoryCounts.Count; $i++) {
    if ($HistoryCounts[$i] -le $HistoryCounts[$i - 1]) { throw 'HistoryCounts must be strictly increasing.' }
}
$scratchRoot = Join-Path $projectRoot '.scratch'
[void][IO.Directory]::CreateDirectory($scratchRoot)
$scratchRoot = Assert-CodexHookDPath -Value $scratchRoot -Name 'history benchmark scratch'
[void](Assert-CodexHookCapabilityPath -Path $scratchRoot -CapabilityRoot $projectRoot -Name 'history benchmark scratch')
$runPrefix = if ($RealHistory) { 'safe-tree-delete-tests-real-history' } else { 'safe-tree-delete-tests-history' }
$runRoot = Join-Path $scratchRoot ('{0}-{1}' -f $runPrefix, [guid]::NewGuid().ToString('N'))
[void](New-CodexHookCapabilityDirectory -Path $runRoot -CapabilityRoot $scratchRoot -RequireMissing -Name 'history benchmark run')

function Get-RealHistoryScale([string]$Root) {
    # Metadata only (no file opens): counts plus a fingerprint that changes on any write.
    # runCount: top-level directories named like producer runs; transaction and plan files
    # count at any depth, as the reference lookup scans them.
    $runCount = 0L; $nonRunTopLevelEntries = 0L; $transactionCount = 0L; $planFileCount = 0L; $planTotalBytes = 0L
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(('root|{0}' -f [IO.Directory]::GetLastWriteTimeUtc($Root).Ticks))
    foreach ($entry in [IO.DirectoryInfo]::new($Root).EnumerateFileSystemInfos('*', [IO.SearchOption]::AllDirectories)) {
        # Listings carry lazily updated copies of sizes and times; read the entry itself.
        $entry.Refresh()
        $relative = [IO.Path]::GetRelativePath($Root, $entry.FullName)
        $isDirectory = $entry -is [IO.DirectoryInfo]
        if ($relative.IndexOf('\') -lt 0) {
            if ($isDirectory -and $entry.Name -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                $runCount++
            } else { $nonRunTopLevelEntries++ }
        }
        if ($isDirectory) {
            $lines.Add(('d|{0}|{1}' -f $relative, $entry.LastWriteTimeUtc.Ticks))
            continue
        }
        if ($entry.Name -ieq 'transaction.json') { $transactionCount++ }
        if ($entry.Name -ieq 'plan.json') { $planFileCount++; $planTotalBytes += $entry.Length }
        $lines.Add(('f|{0}|{1}|{2}' -f $relative, $entry.Length, $entry.LastWriteTimeUtc.Ticks))
    }
    $lines.Sort([StringComparer]::Ordinal)
    [pscustomobject][ordered]@{
        runCount = $runCount; nonRunTopLevelEntries = $nonRunTopLevelEntries; transactionCount = $transactionCount
        planFileCount = $planFileCount; planTotalBytes = $planTotalBytes
        metadataSha256 = Get-CodexHookTextSha256 -Text ($lines -join "`n")
    }
}
function Invoke-RealHistoryShimSample([string]$ShimArguments) {
    # Literal parameter tokens keep the shim's @args forwarding identical to a real caller;
    # the prelude makes the child's redirected stdout UTF-8.
    $command = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false); & '{0}' {1}; exit `$LASTEXITCODE" -f $shimFull.Replace("'", "''"), $ShimArguments
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command)) { [void]$startInfo.ArgumentList.Add($argument) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit(); $watch.Stop()
        [pscustomobject]@{
            wallMs = $watch.Elapsed.TotalMilliseconds; exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult(); stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}
function ConvertFrom-RealHistoryStatusSample([object]$Sample) {
    $lastLine = @($Sample.stdout -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
    $status = $null
    if ($lastLine.Count -eq 1) { try { $status = $lastLine[0] | ConvertFrom-Json -Depth 64 } catch { $status = $null } }
    if ($Sample.exitCode -ne 0 -or $null -eq $status -or $null -eq $status.PSObject.Properties['artifactType'] -or
        $status.artifactType -cne 'env-governance.codex-safe-tree-delete-status') {
        $tail = if ($lastLine.Count -eq 1) { $lastLine[0].Substring(0, [Math]::Min(500, $lastLine[0].Length)) } else { '' }
        throw ('Status sample failed: exit {0}; stdout tail: {1}; stderr: {2}' -f $Sample.exitCode, $tail, $Sample.stderr)
    }
    return $status
}
function Invoke-RealHistoryScopeSample([int]$TargetCount) {
    # Scope query (#80): the latest distinct targets of the last status-full-cold-start sample,
    # padded with never-existing probe targets in this run directory when history holds fewer.
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($target in @($script:scopeHistoryTargets | Select-Object -First $TargetCount)) { $targets.Add($target) }
    $historyTargets = $targets.Count
    for ($probe = 0; $targets.Count -lt $TargetCount; $probe++) {
        $targets.Add((Join-Path $runRoot ('scope-probe-target-{0}' -f $probe)))
    }
    $sample = Invoke-RealHistoryShimSample -ShimArguments ("-Mode Status -Json -TargetPaths '{0}'" -f ($targets -join '::').Replace("'", "''"))
    $status = ConvertFrom-RealHistoryStatusSample $sample
    if ($null -eq $status.PSObject.Properties['scope'] -or @($status.scope.targets).Count -ne $TargetCount) {
        throw ('Scope Status sample must report {0} targets.' -f $TargetCount)
    }
    [ordered]@{
        wallMs = $sample.wallMs; exitCode = $sample.exitCode
        stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($sample.stdout)
        statusElapsedMs = [long]$status.metrics.elapsedMs
        operationCount = @($status.operations).Count; complete = [bool]$status.complete
        targetCount = $TargetCount; historyTargets = $historyTargets
        matchedRecords = [long]$status.scope.matchedRecords
        unattributableRecords = [long]$status.scope.unattributableRecords
    }
}

if ($RealHistory) {
    $evidenceFull = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'real-history evidence root'
    $shimFull = Assert-CodexHookDPath -Value $ShimPath -Name 'real-history gate shim'
    if (-not [IO.File]::Exists($shimFull)) { throw "Gate shim not found: $shimFull" }
    # The lookup probe target lives in this run directory and never exists, so it is absent
    # from history; its policy is generated here and never carries production policy values.
    $lookupTarget = Join-Path $runRoot 'lookup-probe-target'
    $lookupPolicyPath = Join-Path $runRoot 'lookup-probe-policy.json'
    [void](Set-CodexHookCapabilityJson -Path $lookupPolicyPath -CapabilityRoot $runRoot -AllowedExactPaths @($lookupPolicyPath) -Scope 'real-history lookup probe policy' -Document ([ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'; schemaVersion = 5
        entries = @([ordered]@{
            id = 'real-history-lookup-probe'; capabilityRoot = $lookupTarget; minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'; allowHardLinks = $false
            allowInternalDirectoryJunctions = $false; minimumQuarantineAgeMinutes = 0
            producerFenceMode = 'os-handle-required'; deniedExactPaths = @()
        })
    }))
    # Measurement items, each sampled $repetitions times in order. To add an item, append an
    # entry: id, what its wall time covers, and a scriptblock returning one sample as an
    # ordered dictionary with wallMs plus any item-specific raw fields.
    $repetitions = 3
    # Latest distinct targetPaths of the last full Status sample; the scope items query them.
    $scopeHistoryTargets = @()
    $items = @(
        [pscustomobject]@{
            id = 'status-full-cold-start'
            boundary = 'fresh pwsh running the gate shim with -Mode Status -Json; wall from process start to exit: pwsh startup, gate wait, library load, full Status, JSON output'
            measure = {
                $sample = Invoke-RealHistoryShimSample -ShimArguments '-Mode Status -Json'
                $status = ConvertFrom-RealHistoryStatusSample $sample
                $operations = @($status.operations)
                $seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                $script:scopeHistoryTargets = @(for ($index = $operations.Count - 1; $index -ge 0; $index--) {
                        $targetPath = [string]$operations[$index].targetPath
                        if (-not [string]::IsNullOrEmpty($targetPath) -and $seenTargets.Add($targetPath)) { $targetPath }
                    })
                [ordered]@{
                    wallMs = $sample.wallMs; exitCode = $sample.exitCode
                    stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($sample.stdout)
                    statusElapsedMs = [long]$status.metrics.elapsedMs
                    operationCount = @($status.operations).Count; complete = [bool]$status.complete
                }
            }
        }
        [pscustomobject]@{
            id = 'reference-lookup-miss'
            boundary = 'in-process Find-CodexSafeTreeDeleteRecoverableTransaction for one target absent from history (BatchPurge per-target cost, the kill switch 0 path): probe policy read, target resolve, full transaction.json scan; no gate held'
            measure = {
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $match = Find-CodexSafeTreeDeleteRecoverableTransaction -TargetPath $lookupTarget -CapabilityRoot $lookupTarget -PolicyPath $lookupPolicyPath -EvidenceRoot $evidenceFull
                $watch.Stop()
                if ($null -ne $match) { throw 'Lookup probe target unexpectedly matched a recoverable transaction.' }
                [ordered]@{ wallMs = $watch.Elapsed.TotalMilliseconds; found = $false }
            }
        }
        [pscustomobject]@{
            id = 'batch-scan-direct'
            boundary = 'in-process Get-CodexSafeTreeDeleteRecoverableTransactionCandidates called directly, not through the delete path (the BatchPurge fast history scan with the C# prefilter, #78) for the same absent target: full transaction.json enumeration, prefilter, reference authentication of every file the prefilter does not exclude; no policy read, target resolve or gate held'
            measure = {
                $scanMetrics = New-CodexSafeTreeDeleteHistoryScanMetrics -Mode 'fast'
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $candidates = Get-CodexSafeTreeDeleteRecoverableTransactionCandidates -FullEvidenceRoot $evidenceFull -TargetPaths @($lookupTarget) -Metrics $scanMetrics
                $watch.Stop()
                $candidateCount = $candidates[$lookupTarget].Count
                if ($candidateCount -ne 0) { throw 'Batch scan probe target unexpectedly has history candidates.' }
                [ordered]@{
                    wallMs = $watch.Elapsed.TotalMilliseconds; candidateCount = $candidateCount
                    enumeratedFiles = [long]$scanMetrics.enumeratedFiles; canonicalFiles = [long]$scanMetrics.canonicalFiles
                    fallbackFiles = [long]$scanMetrics.fallbackFiles; excludedByPrefilter = [long]$scanMetrics.excludedByPrefilter
                    fullyAuthenticated = [long]$scanMetrics.fullyAuthenticated; scanElapsedMs = [long]$scanMetrics.elapsedMs
                }
            }
        }
        # Scope items (#80) must follow status-full-cold-start: they take its latest targets.
        [pscustomobject]@{
            id = 'status-scope-1-target'
            boundary = 'as status-full-cold-start, with -TargetPaths holding one target (the latest targetPath in history, else a never-existing probe target): scope prefilter, Status for in-scope and unattributable records, JSON output'
            measure = { Invoke-RealHistoryScopeSample -TargetCount 1 }
        }
        [pscustomobject]@{
            id = 'status-scope-10-targets'
            boundary = 'as status-full-cold-start, with -TargetPaths holding ten targets joined by :: (the latest distinct targetPaths in history, padded with never-existing probe targets): scope prefilter, Status for in-scope and unattributable records, JSON output'
            measure = { Invoke-RealHistoryScopeSample -TargetCount 10 }
        }
    )
    $killSwitches = [ordered]@{}
    foreach ($name in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'CODEX_SAFE_TREE_DELETE_*' } | Sort-Object)) {
        $killSwitches[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $scaleBefore = Get-RealHistoryScale $evidenceFull
    $itemResults = foreach ($item in $items) {
        $samples = foreach ($run in 1..$repetitions) {
            $sample = [ordered]@{ run = $run }
            $measured = & $item.measure
            foreach ($key in $measured.Keys) { $sample[$key] = $measured[$key] }
            [pscustomobject]$sample
        }
        [pscustomobject][ordered]@{ id = $item.id; boundary = $item.boundary; samples = @($samples) }
    }
    $scaleAfter = Get-RealHistoryScale $evidenceFull
    $stable = $scaleBefore.metadataSha256 -ceq $scaleAfter.metadataSha256
    $report = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-history-benchmark'; schemaVersion = 1
        ok = $stable; profile = 'real-history'; skipped = $false
        capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o'); thresholdPolicy = 'record-only'; runRoot = $runRoot
        evidenceRoot = $evidenceFull; shimPath = $shimFull
        shimSha256 = (Get-FileHash -LiteralPath $shimFull -Algorithm SHA256).Hash
        sourceLibrarySha256 = (Get-FileHash -LiteralPath $libraryPath -Algorithm SHA256).Hash
        powerShellVersion = $PSVersionTable.PSVersion.ToString(); killSwitchEnvironment = $killSwitches
        repetitions = $repetitions
        historyScale = [ordered]@{ before = $scaleBefore; after = $scaleAfter; stable = $stable }
        items = @($itemResults)
        unmeasured = @('OS file cache state (not controlled; sample 1 may be cold)', 'gate wait apart from Status work (both inside the Status wall time)', 'BatchPurge work other than the history lookup (per-target reference lookup or one batch scan)')
    }
    $outputFull = Join-Path $runRoot 'measurement.json'
    [void](Set-CodexHookCapabilityJson -Path $outputFull -Document $report -CapabilityRoot $runRoot -AllowedExactPaths @($outputFull) -Scope 'real-history benchmark report')
    return $report
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $runRoot 'measurement.json' }
$outputFull = Assert-CodexHookDPath -Value $OutputPath -Name 'history benchmark output'
[void](Assert-CodexHookCapabilityPath -Path $outputFull -CapabilityRoot $scratchRoot -Name 'history benchmark output')
$fixtureEntry = Join-Path $projectRoot 'tests/Invoke-CodexSafeTreeDeleteFixture.ps1'

function Assert-Benchmark([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Write-FixtureJson([string]$Path, [object]$Document) {
    [void](Set-CodexHookCapabilityJson -Path $Path -Document $Document -CapabilityRoot $runRoot -AllowedExactPaths @($Path) -Scope 'history benchmark fixture')
}
function Invoke-HistoryCase([int]$Count) {
    $caseRoot = Join-Path $runRoot ('history-{0}' -f $Count)
    $target = Join-Path $caseRoot 'payload'
    $evidence = Join-Path $caseRoot 'evidence'
    [void][IO.Directory]::CreateDirectory($target)
    [void][IO.Directory]::CreateDirectory($evidence)
    [IO.File]::WriteAllBytes((Join-Path $target 'small.bin'), [byte[]]::new(1024))
    $policyPath = Join-Path $caseRoot 'policy.json'
    Write-FixtureJson $policyPath ([ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'; schemaVersion = 5
        entries = @([ordered]@{
            id = 'history-benchmark'; capabilityRoot = $target; minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'; allowHardLinks = $false
            allowInternalDirectoryJunctions = $false; minimumQuarantineAgeMinutes = 0
            producerFenceMode = 'os-handle-required'; deniedExactPaths = @()
        })
    })
    # Terminal records are serialized copies of one real fixture receipt. The finder
    # reads their JSON and skips terminal status before plan authentication. This is
    # a controlled scan corpus, not a claim that N authentic historical deletes ran.
    for ($j = 0; $j -lt $Count; $j++) {
        $historyDir = Join-Path $evidence ('synthetic-terminal-{0:D5}' -f $j)
        [void][IO.Directory]::CreateDirectory($historyDir)
        [IO.File]::WriteAllBytes((Join-Path $historyDir 'transaction.json'), $script:terminalSeedBytes)
    }
    $historyPaths = @(Get-ChildItem -LiteralPath $evidence -Filter transaction.json -Recurse -File | Select-Object -ExpandProperty FullName)
    Assert-Benchmark ($historyPaths.Count -eq $Count) 'Synthetic history count mismatch.'
    $common = @{ FixturePolicyPath = $policyPath; FixtureEvidenceRoot = $evidence }
    $lookup = @{ TargetPath = $target; CapabilityRoot = $target; PolicyPath = $policyPath; EvidenceRoot = $evidence }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $miss = Find-CodexSafeTreeDeleteRecoverableTransaction @lookup
    $watch.Stop(); $missMs = $watch.Elapsed.TotalMilliseconds
    Assert-Benchmark ($null -eq $miss) 'Terminal history must not yield a recoverable transaction.'
    $watch.Restart()
    $plan = & $fixtureEntry -Mode Plan -TargetPath $target -CapabilityRoot $target @common
    $watch.Stop(); $planMs = $watch.Elapsed.TotalMilliseconds
    $watch.Restart()
    $apply = & $fixtureEntry -Mode Apply -PlanPath $plan.planPath -ApprovedPlanSha256 $plan.planSha256 -ConfirmApply @common
    $watch.Stop(); $applyMs = $watch.Elapsed.TotalMilliseconds
    Assert-Benchmark ([bool]$apply.quarantined) 'Fixture Apply did not quarantine target.'
    $watch.Restart()
    $hit = Find-CodexSafeTreeDeleteRecoverableTransaction @lookup
    $watch.Stop(); $hitMs = $watch.Elapsed.TotalMilliseconds
    Assert-Benchmark ($null -ne $hit -and $hit.transactionPath -ceq $apply.transactionPath -and $hit.transactionSha256 -ceq $apply.transactionSha256) 'Recoverable lookup must return this exact transaction and hash.'
    $watch.Restart()
    $purge = & $fixtureEntry -Mode Purge -TransactionPath $apply.transactionPath -ApprovedTransactionSha256 $apply.transactionSha256 -ConfirmPurge @common
    $watch.Stop(); $purgeMs = $watch.Elapsed.TotalMilliseconds
    Assert-Benchmark ([bool]$purge.purged) 'Fixture Purge failed.'
    $receiptBytes = [IO.File]::ReadAllBytes($purge.transactionPath)
    $receipt = [Text.Encoding]::UTF8.GetString($receiptBytes) | ConvertFrom-Json -Depth 64
    $targetAbsent = -not (Test-Path -LiteralPath $target)
    $quarantineAbsent = -not (Test-Path -LiteralPath $receipt.quarantinePath)
    Assert-Benchmark ($targetAbsent -and $quarantineAbsent -and $receipt.status -ceq 'purged') 'Final deletion namespaces or transaction disagree.'
    foreach ($path in $historyPaths) {
        Assert-Benchmark ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $script:terminalSeedHash) 'Benchmark changed historical receipt bytes.'
    }
    if ($Count -eq 0) {
        $script:terminalSeedBytes = $receiptBytes
        $script:terminalSeedHash = (Get-FileHash -LiteralPath $purge.transactionPath -Algorithm SHA256).Hash
    }
    [pscustomobject][ordered]@{
        historyCount = $Count; payloadBytes = 1024; lookupMissWasNull = $true; lookupHitMatched = $true
        lookupMissMs = $missMs; lookupHitMs = $hitMs; planWallMs = $planMs; applyWallMs = $applyMs; purgeWallMs = $purgeMs
        metrics = [ordered]@{ plan = $plan.metrics; apply = $apply.metrics; purge = $purge.metrics }
        transactionPath = $purge.transactionPath; transactionSha256 = $purge.transactionSha256
        finalStatus = $receipt.status; targetAbsent = $targetAbsent; quarantineAbsent = $quarantineAbsent; historyUnchanged = $true
        physicalReclaimStatus = $purge.deletionOutcome.physicalReclaimStatus
    }
}

$script:terminalSeedBytes = $null
$script:terminalSeedHash = $null
# Measure a fresh child separately: process wall includes executable startup and library
# loading; libraryLoadMs is the nested load interval, not a subtraction estimate.
$startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-ColdStartProbe')) { [void]$startInfo.ArgumentList.Add($argument) }
$coldWatch = [Diagnostics.Stopwatch]::StartNew()
$process = [Diagnostics.Process]::Start($startInfo)
$stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit(); $coldWatch.Stop()
$stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
try { Assert-Benchmark ($process.ExitCode -eq 0) ('Cold probe failed: ' + $stderr) } finally { $process.Dispose() }
$probe = $stdout | ConvertFrom-Json
$cases = [Collections.Generic.List[object]]::new()
$baseline = Invoke-HistoryCase 0
if ($HistoryCounts[0] -eq 0) { $cases.Add($baseline) }
foreach ($count in $HistoryCounts) { if ($count -ne 0) { $cases.Add((Invoke-HistoryCase $count)) } }
$report = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-history-benchmark'; schemaVersion = 1
    ok = $true; profile = 'isolated-fixture'; capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    thresholdPolicy = 'record-only'; runRoot = $runRoot
    sourceLibrarySha256 = (Get-FileHash -LiteralPath $libraryPath -Algorithm SHA256).Hash
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    startup = [ordered]@{ coldProcessWallMs = $coldWatch.Elapsed.TotalMilliseconds; libraryLoadMs = $probe.libraryLoadMs }
    historyModel = 'synthetic-terminal-receipt-copies; finder terminal-skip path; no Status/authentication scaling claim'
    measurementBoundaries = @('lookup: full finder call including policy/path validation and history read', 'plan/apply/purge: fixture invocation wall including validation, IO, and evidence publication', 'startup: independent cold process, not additive to warm fixture phases')
    unmeasured = @('pure validation time', 'pure filesystem deletion time', 'production gate overhead', 'physical disk reclaim', 'real history distribution')
    cases = @($cases)
}
[void](Set-CodexHookCapabilityJson -Path $outputFull -Document $report -CapabilityRoot $scratchRoot -AllowedExactPaths @($outputFull) -Scope 'history benchmark report')
$report
