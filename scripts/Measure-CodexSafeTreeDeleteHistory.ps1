[CmdletBinding()]
param(
    [string]$OutputPath,
    [ValidateRange(0, 10000)][int[]]$HistoryCounts = @(0, 100, 1000),
    [switch]$ColdStartProbe
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
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
$runRoot = Join-Path $scratchRoot ('safe-tree-delete-tests-history-{0}' -f [guid]::NewGuid().ToString('N'))
[void](New-CodexHookCapabilityDirectory -Path $runRoot -CapabilityRoot $scratchRoot -RequireMissing -Name 'history benchmark run')
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
