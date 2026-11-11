[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts/lib/SafeCleanupJob.ps1')
$scratch=Join-Path $repo ('.scratch/safe-tree-delete-tests-prepare-'+[guid]::NewGuid().ToString('N'))
$evidence=Join-Path $scratch 'gate-evidence'
$jobRoot=Join-Path $scratch 'jobs'
[void][IO.Directory]::CreateDirectory($evidence)
[void][IO.Directory]::CreateDirectory($jobRoot)
$entries=@();$targets=@()
foreach($name in @('first','second')){
 $cap=Join-Path $scratch $name
 $target=Join-Path $cap 'target'
 [void][IO.Directory]::CreateDirectory($target)
 [IO.File]::WriteAllText((Join-Path $target 'payload.txt'),'approved fixture')
 $entries+=@{id=$name;capabilityRoot=$cap;minimumDescendantDepth=1;rootDeletionPurpose='none';deniedExactPaths=@()}
 $targets+=$target
}
$policyPath=Join-Path $scratch 'policy.json'
Write-SafeCleanupJobJson $policyPath @{artifactType='env-governance.codex-safe-tree-delete-policy';schemaVersion=4;entries=$entries}
$fixture=Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$gate={param($arguments) & $fixture @arguments -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidence}.GetNewClosure()
$result=New-SafeCleanupJobSet -TargetPaths $targets -JobDirectory $jobRoot -PolicyPath $policyPath -TransactionEvidenceRoot $evidence -GateInvoker $gate
if($result.jobs.Count -ne 2){throw 'Prepare must group by the gate Check policyEntryId.'}
foreach($row in $result.jobs){
 $context=Read-SafeCleanupJob $row.jobPath
 if($context.ledger.units.Count -ne 1 -or $context.ledger.units[0].status -ne 'pending'){throw 'Every approved target must be durably pending.'}
 if(@(Get-ChildItem -LiteralPath $context.job.intentRoot -File).Count -ne 0 -or -not (Test-Path (Join-Path (Split-Path -Parent $row.jobPath) 'prepared-plans.json'))){throw 'Audit baseline must be durable without creating an execution intent that expires before Run.'}
 if(-not (Test-Path -LiteralPath $context.scope.units[0].path)){throw 'Preparation must not delete targets.'}
}
$refused=$false
try{New-SafeCleanupJobSet -TargetPaths $targets -JobDirectory $jobRoot -PolicyPath $policyPath -TransactionEvidenceRoot $evidence -GateInvoker $gate | Out-Null}catch{$refused=$true}
if(-not $refused){throw 'Existing immutable job sets must not be overwritten.'}
# Lost host job IDs do not matter: recover an Apply-completed, Purge-pending intent.
$first=Read-SafeCleanupJob $result.jobs[0].jobPath
$applyThenCrash={param($arguments) $observed=& $gate $arguments; if($arguments.Mode -eq 'Apply'){throw 'fixture-worker-lost-after-apply'};return $observed}.GetNewClosure()
$interrupted=$false
try{Invoke-SafeCleanupJobUnit $result.jobs[0].jobPath $first.scope.units[0].path -GateInvoker $applyThenCrash | Out-Null}catch{$interrupted=$true}
$intentFile=@(Get-ChildItem -LiteralPath $first.job.intentRoot -File)[0].FullName
$intent=Read-SafeCleanupJobJson $intentFile
$audit=Read-SafeCleanupJobJson (Join-Path (Split-Path -Parent $result.jobs[0].jobPath) 'prepared-plans.json')
if($intent.planPath -eq $audit.plans[0].planPath){throw 'Execution must create a fresh Plan instead of binding the queue to the preparation TTL.'}
if(-not $interrupted -or (Test-Path -LiteralPath $intent.targetPath)){throw 'Fixture must stop with the original target in quarantine.'}
[void](Invoke-SafeCleanupJobUnit $result.jobs[0].jobPath $intent.targetPath -GateInvoker $gate)
if(-not (Test-SafeCleanupJobVerification $result.jobs[0].jobPath).verified){throw 'Durable intent must resume through Purge without original path existence.'}
# One denied Plan must report the exact elevation need and publish no runnable partial job set.
$deniedRoot=Join-Path $scratch 'denied-jobs'
[void][IO.Directory]::CreateDirectory($deniedRoot)
$deniedGate={param($arguments) if($arguments.Mode -eq 'Plan'){throw [UnauthorizedAccessException]::new('fixture access denied')}; & $gate $arguments}.GetNewClosure()
$denied=New-SafeCleanupJobSet -TargetPaths @($targets[1]) -JobDirectory $deniedRoot -PolicyPath $policyPath -TransactionEvidenceRoot $evidence -GateInvoker $deniedGate
if($denied.status -ne 'preflight-failed' -or -not $denied.needsElevation -or $denied.jobs.Count -ne 0 -or -not (Test-Path -LiteralPath $targets[1])){throw 'Access refusal must stay explicit and non-destructive.'}
$rootOnlyJobs=Join-Path $scratch 'root-only-jobs'
[void][IO.Directory]::CreateDirectory($rootOnlyJobs)
$rootTarget=Split-Path -Parent $targets[1]
$rootOnlyGate={param($arguments) if($arguments.Mode -ne 'Check'){throw 'Root-only inputs must be refused before any Plan/publication.'};@{allowed=$true;results=@(@{allowed=$true;targetPath=$rootTarget;capabilityRoot=$rootTarget;policyEntryId='fixture-explicit-root'})}}.GetNewClosure()
$rootOnly=New-SafeCleanupJobSet -TargetPaths @($rootTarget) -JobDirectory $rootOnlyJobs -PolicyPath $policyPath -TransactionEvidenceRoot $evidence -GateInvoker $rootOnlyGate
if($rootOnly.status -ne 'preflight-failed' -or @(Get-ChildItem -LiteralPath $rootOnlyJobs -Force).Count -ne 0){throw 'Unsupported Worker root scopes must leave no runnable partial jobs.'}
[pscustomobject]@{ok=$true;suite='SafeCleanupPreparation';jobs=$result.jobs.Count;applyCrashResume=$true;elevationPreflight=$true;unsupportedRootsRejectedBeforePublication=$true}
