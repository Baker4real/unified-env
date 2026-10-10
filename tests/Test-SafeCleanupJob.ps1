[CmdletBinding()]
param([string]$CrashJobPath, [switch]$CrashCheckpoint, [string]$MutexJobPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$library = Join-Path $repo 'scripts/lib/SafeCleanupJob.ps1'
if (-not [IO.File]::Exists($library)) { throw 'SafeCleanupJob public seam missing.' }
. $library
if ($MutexJobPath) {
    $mutex=New-SafeCleanupJobMutex $MutexJobPath;$acquired=$false
    try {
        try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if ($acquired) { exit 3 }
        exit 0
    } finally { if ($acquired) { $mutex.ReleaseMutex() };$mutex.Dispose() }
}
if ($CrashJobPath) {
    $context=Read-SafeCleanupJob $CrashJobPath
    $marker=Join-Path (Split-Path -Parent $CrashJobPath) 'kill-ready.txt'
    $crash={ [IO.File]::WriteAllText($marker,'ready');[Threading.Thread]::Sleep([Threading.Timeout]::Infinite) }.GetNewClosure()
    if ($CrashCheckpoint) { Invoke-SafeCleanupJobReconcile $CrashJobPath -BeforeCheckpoint $crash | Out-Null;exit }
    $self=Get-Process -Id $PID
    Write-SafeCleanupJobJson $context.job.statePath @{processState='running';pid=$PID;processStartUtc=$self.StartTime.ToUniversalTime().ToString('o');executable=$self.Path;ownerTokenHash='CrashJobPath';updatedAtUtc=[datetimeoffset]::UtcNow.ToString('o');error=''}
    $fixtureEntry=Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
    $policyPath=$context.job.policyPath;$evidence=$context.job.transactionEvidenceRoot
    $gate={param($arguments) & $fixtureEntry @arguments -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidence}.GetNewClosure()
    Invoke-SafeCleanupJobUnit $CrashJobPath $context.scope.units[0].path -GateInvoker $gate -AfterPurge $crash | Out-Null
    exit
}
function Assert-Job([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
Assert-Job ((ConvertTo-SafeCleanupJobBaselineCanonical @{createdUtc='2026-10-10T01:00:00+00:00';bytes=12}) -ceq (ConvertTo-SafeCleanupJobBaselineCanonical @{createdUtc='2026-10-10T09:00:00+08:00';bytes=12})) 'Equivalent timestamp offsets must compare as the same instant.'
$state = @{ processState='running'; pid=123; processStartUtc='2026-10-10T01:00:00Z'; executable='D:/pwsh.exe'; ownerTokenHash='owner'; updatedAtUtc='2026-10-10T01:01:00Z'; error='' }
$ledger = @{ units=@(@{path='D:/tmp/a';status='pending';baseline=@{bytes=12}}) }
$result = Get-SafeCleanupJobHealth -State $state -Ledger $ledger -ProcessObservation $null
Assert-Job ($result.health -eq 'interrupted' -and $result.taskFailure -and $result.failedCount -eq 0) 'Dead process must not remain running or become a directory failure.'
$observation = @{ pid=123; startUtc='2026-10-10T01:00:00Z'; executable='D:/pwsh.exe'; commandLine='pwsh owner' }
$result = Get-SafeCleanupJobHealth -State $state -Ledger $ledger -ProcessObservation $observation
Assert-Job ($result.health -eq 'running' -and $result.processIdentityMatches) 'Matching process should run.'
$observation.startUtc='2026-10-10T02:00:00Z'
Assert-Job ((Get-SafeCleanupJobHealth -State $state -Ledger $ledger -ProcessObservation $observation).health -eq 'interrupted') 'PID reuse must fail identity.'
$old = @{schemaVersion=4;entries=@(@{id='temp';capabilityRoot='D:/tmp';minimumDescendantDepth=1;deniedExactPaths=@()})}
$new = @{entries=@(@{deniedExactPaths=@();minimumDescendantDepth=1;capabilityRoot='D:/tmp';id='temp'},@{id='other';capabilityRoot='D:/other'});schemaVersion=4}
Assert-Job ((Compare-SafeCleanupJobPolicy -OldPolicy $old -CurrentPolicy $new -CapabilityRoot 'D:/tmp').compatible) 'Disjoint addition and property order should allow rebind.'
$new.entries[0].minimumDescendantDepth=0
Assert-Job (-not (Compare-SafeCleanupJobPolicy -OldPolicy $old -CurrentPolicy $new -CapabilityRoot 'D:/tmp').compatible) 'Relevant drift must stop.'
$new.entries[0].minimumDescendantDepth=1
$new.entries += @{id='ancestor';capabilityRoot='D:/'}
Assert-Job (-not (Compare-SafeCleanupJobPolicy -OldPolicy $old -CurrentPolicy $new -CapabilityRoot 'D:/tmp').compatible) 'New overlapping capability must stop.'
Assert-Job ((Get-SafeCleanupJobPathGeneration -OriginalIdentity @('vol','old') -CurrentIdentity @('vol','new') -Exists $true) -eq 'recreated-preserved') 'Identity detects recreation.'
Assert-Job ((Get-SafeCleanupJobPathGeneration -OriginalIdentity @('vol','old') -CurrentIdentity @('vol','old') -Exists $true) -eq 'original-present') 'Same identity is not recreation.'
Assert-Job ((Get-SafeCleanupJobPathGeneration -OriginalIdentity @('vol','old') -CurrentIdentity @() -Exists $true) -eq 'unknown-preserved') 'Missing identity must stay uncertain.'
$scratch=Join-Path $repo ('.scratch/safe-tree-delete-tests-job-'+[guid]::NewGuid().ToString('N'))
$target=Join-Path $scratch 'target';$evidence=Join-Path $scratch 'evidence';$intents=Join-Path $scratch 'intents'
[void][IO.Directory]::CreateDirectory($target);[void][IO.Directory]::CreateDirectory($evidence);[void][IO.Directory]::CreateDirectory($intents)
[IO.File]::WriteAllText((Join-Path $target 'data.txt'),'approved fixture')
$policyPath=Join-Path $scratch 'policy.json'
$policy=@{artifactType='env-governance.codex-safe-tree-delete-policy';schemaVersion=4;entries=@(@{id='job-fixture';capabilityRoot=$scratch;minimumDescendantDepth=1;rootDeletionPurpose='none';deniedExactPaths=@()})}
Write-SafeCleanupJobJson $policyPath $policy
$snapshot=Get-CodexHookCapabilityDirectoryTreeSnapshot -Path $target -CapabilityRoot $scratch
$baseline=@{rootIdentity=$snapshot.rootIdentity;treeManifestSha256=(Get-CodexSafeTreeDeleteManifestSha256 $snapshot);bytes=16}
$scopePath=Join-Path $scratch 'scope.json';$ledgerPath=Join-Path $scratch 'ledger.json';$statePath=Join-Path $scratch 'state.json';$jobPath=Join-Path $scratch 'job.json'
$unit=@{path=$target;baseline=$baseline;status='pending'}
Write-SafeCleanupJobJson $scopePath @{capabilityRoot=$scratch;units=@($unit)}
$scopeHash=(Get-FileHash $scopePath).Hash
Write-SafeCleanupJobJson $ledgerPath @{scopeSha256=$scopeHash;units=@($unit)}
Write-SafeCleanupJobJson $statePath $state
Write-SafeCleanupJobJson $jobPath @{scopePath=$scopePath;scopeSha256=$scopeHash;ledgerPath=$ledgerPath;statePath=$statePath;intentRoot=$intents;policyPath=$policyPath;policySnapshotPath=$policyPath;policySnapshotSha256=(Get-FileHash $policyPath).Hash;transactionEvidenceRoot=$evidence}
$mutex=New-SafeCleanupJobMutex $jobPath
[void]$mutex.WaitOne(0)
try {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -MutexJobPath $jobPath.ToUpperInvariant()
    Assert-Job ($LASTEXITCODE -eq 0) 'Case-varied job path must share one cross-process mutex.'
} finally { $mutex.ReleaseMutex();$mutex.Dispose() }
$cli=Join-Path $repo 'scripts/Invoke-SafeCleanupJob.ps1'
$protectedHash=(Get-FileHash $scopePath).Hash
$rejected=$false
try { & $cli -Mode Status -JobPath $jobPath -OutputPath $scopePath.Replace('\','/') | Out-Null } catch { $rejected=$true }
Assert-Job ($rejected -and (Get-FileHash $scopePath).Hash -eq $protectedHash) 'Output must not overwrite scope with alternate path separators.'
$fixtureEntry=Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$fixtureGate={param($arguments)
    & $fixtureEntry @arguments -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidence
}.GetNewClosure()
function Stop-JobFixtureAtCheckpoint([switch]$Checkpoint) {
    $marker=Join-Path $scratch 'kill-ready.txt'
    if (Test-Path $marker) { [IO.File]::WriteAllText($marker,'waiting') }
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach ($arg in @('-NoProfile','-File',$PSCommandPath,'-CrashJobPath',$jobPath)) { $info.ArgumentList.Add($arg) }
    if ($Checkpoint) { $info.ArgumentList.Add('-CrashCheckpoint') }
    $child=[Diagnostics.Process]::Start($info)
    $output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
    try {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt 30 -and -not $child.HasExited) {
            if ((Test-Path $marker) -and [IO.File]::ReadAllText($marker) -eq 'ready') { break }
            Start-Sleep -Milliseconds 50
        }
        if ($child.HasExited -or $watch.Elapsed.TotalSeconds -ge 30) {
            if (-not $child.HasExited) { $child.Kill();$child.WaitForExit() }
            throw ('Crash child did not reach checkpoint: '+$errors.GetAwaiter().GetResult())
        }
        if (-not $Checkpoint) { Assert-Job ((Get-SafeCleanupJobStatus $jobPath).health -eq 'running') 'Live child identity must match.' }
        $child.Kill();$child.WaitForExit()
        [void]$output.GetAwaiter().GetResult();[void]$errors.GetAwaiter().GetResult()
    } finally { if (-not $child.HasExited) { $child.Kill();$child.WaitForExit() };$child.Dispose() }
}
Stop-JobFixtureAtCheckpoint
Assert-Job ((Get-SafeCleanupJobStatus $jobPath).health -eq 'interrupted') 'Killed process must be interrupted, not running.'
Assert-Job (-not (Test-Path $target) -and (Read-SafeCleanupJobJson $ledgerPath).units[0].status -eq 'pending') 'Hard kill must leave successful gate receipt and old valid checkpoint.'
$intentPath=@(Get-ChildItem $intents -File)[0].FullName
$savedIntent=Read-SafeCleanupJobJson $intentPath
$badIntent=Read-SafeCleanupJobJson $intentPath
$badIntent.originalIdentity=@('bad','generation')
Write-SafeCleanupJobJson $intentPath $badIntent
$rejected=$false
$calls=[Collections.Generic.List[string]]::new()
try { Invoke-SafeCleanupJobUnit $jobPath $target -GateInvoker { $calls.Add('called');throw 'Gate must never be called for altered intent.' } | Out-Null } catch { $rejected=$true }
Assert-Job ($rejected -and $calls.Count -eq 0) 'Existing intent must be rejected before any gate invocation.'
Write-SafeCleanupJobJson $intentPath $savedIntent
$savedLedger=Read-SafeCleanupJobJson $ledgerPath
$badLedger=Read-SafeCleanupJobJson $ledgerPath;$badLedger.units[0].baseline.bytes=999
Write-SafeCleanupJobJson $ledgerPath $badLedger
$rejected=$false
try { Read-SafeCleanupJob $jobPath | Out-Null } catch { $rejected=$true }
Assert-Job $rejected 'Ledger baseline drift must fail immutable scope validation.'
Write-SafeCleanupJobJson $ledgerPath $savedLedger
$before=(Get-FileHash $ledgerPath).Hash
$failed=$false
Stop-JobFixtureAtCheckpoint -Checkpoint
Assert-Job ((Get-FileHash $ledgerPath).Hash -eq $before) 'Hard kill before atomic rename must preserve previous checkpoint.'
$replay=Invoke-SafeCleanupJobReconcile $jobPath
Assert-Job ($replay.recoveredCount -eq 1 -and (Read-SafeCleanupJobJson $ledgerPath).units[0].status -eq 'processed') 'Replay must recover exactly one gate success.'
Assert-Job ((Invoke-SafeCleanupJobReconcile $jobPath).recoveredCount -eq 0) 'Replay must be idempotent.'
$verified=Test-SafeCleanupJobVerification $jobPath
Assert-Job ($verified.verified -and $verified.recreatedCount -eq 0) 'Original fixture deletion must verify.'
$savedLedger=Read-SafeCleanupJobJson $ledgerPath
$badLedger=Read-SafeCleanupJobJson $ledgerPath;$badLedger.units[0].outcome.transactionSha256='0'*64
Write-SafeCleanupJobJson $ledgerPath $badLedger
Assert-Job (-not (Test-SafeCleanupJobVerification $jobPath).verified) 'Altered receipt hash must not verify.'
Write-SafeCleanupJobJson $ledgerPath $savedLedger
[void][IO.Directory]::CreateDirectory($target)
[IO.File]::WriteAllText((Join-Path $target 'new.txt'),'new generation')
$verified=Test-SafeCleanupJobVerification $jobPath
Assert-Job ($verified.verified -and $verified.recreatedCount -eq 1 -and (Test-Path (Join-Path $target 'new.txt'))) 'Recreated same-path object must be independently identified and preserved.'
$ledgerDoc=Read-SafeCleanupJobJson $ledgerPath
$ledgerDoc.units[0].outcome.transactionPath=Join-Path $scratch 'forged/transaction.json'
Write-SafeCleanupJobJson $ledgerPath $ledgerDoc
Assert-Job (-not (Test-SafeCleanupJobVerification $jobPath).verified) 'Out-of-evidence receipt must not verify.'
$jobDoc=Read-SafeCleanupJobJson $jobPath;$jobDoc.readOnly=$true
Write-SafeCleanupJobJson $jobPath $jobDoc
$rejected=$false
try { Invoke-SafeCleanupJobReconcile $jobPath | Out-Null } catch { $rejected=$true }
Assert-Job $rejected 'Read-only descriptors cannot write through the library seam.'
[pscustomobject]@{ok=$true;suite='SafeCleanupJob';phase='health-policy-identity-crash-replay';evidence=$scratch}
