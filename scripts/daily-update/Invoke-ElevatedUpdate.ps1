[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('Validate','Launch','Worker')][string]$Mode,
 [Parameter(Mandatory)][string]$Spec,
 [Parameter(Mandatory)][string]$Receipt,
 [string]$Python='D:/Codex/tools/python315-official/python.exe',
 [string]$ExpectedSpecSha256,
 [string]$ExpectedScriptSha256,
 [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$step=Join-Path $PSScriptRoot 'daily-update-step.py'
$process=$null
try{
 if(-not [IO.Path]::IsPathFullyQualified($Spec) -or -not [IO.Path]::IsPathFullyQualified($Receipt)){throw 'absolute-spec-and-receipt-required'}
 # This validates JSON, paths, typed Mode/phase and business predicates before UAC.
 $raw=& $Python -B $step validate --spec $Spec --require-phase
 if($LASTEXITCODE -ne 0){throw 'pre-elevation-contract-rejected'}
 $validated=($raw|Out-String)|ConvertFrom-Json
 if(-not $validated.ok -or $validated.phase -notin @('Prepare','Apply','Rollback')){throw 'pre-elevation-contract-rejected'}
 $specFile=Get-Item -LiteralPath $Spec
 $receiptPath=[IO.Path]::GetFullPath($Receipt)
 $receiptParent=[IO.Path]::GetDirectoryName($receiptPath)
 if(-not (Test-Path -LiteralPath $receiptParent -PathType Container)){throw 'receipt-parent-required'}
 if($Mode -ne 'Worker' -and ((Test-Path -LiteralPath ($receiptPath+'.launch.json')) -or (Test-Path -LiteralPath ($receiptPath+'.launched.json')))){throw 'launch-evidence-already-exists'}
 # RunEvidence supplies the same run/path check used by the eventual worker, without writes.
 $probe='import importlib.util,pathlib,sys; s=importlib.util.spec_from_file_location("step",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);w=m.receipt_run(pathlib.Path(sys.argv[2]),None);w.output_path(sys.argv[3])'
 & $Python -B -c $probe $step $Spec $Receipt
 if($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $receiptPath)){throw 'receipt-path-not-new-in-current-run'}
 if($Mode -eq 'Validate'){
  @{ok=$true;status='validated-not-elevated';phase=$validated.phase;spec_sha256=$validated.spec_sha256}|ConvertTo-Json -Compress
  return
 }
 if($Mode -eq 'Worker'){
  $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'elevated-worker-required'}
  if(-not $ExpectedSpecSha256 -or $ExpectedSpecSha256 -cne $validated.spec_sha256){throw 'spec-changed-before-elevation'}
  if(-not $ExpectedScriptSha256 -or $ExpectedScriptSha256 -cne $validated.script_sha256){throw 'script-changed-before-elevation'}
  & $Python -B $step run --spec $Spec --receipt $Receipt --expected-spec-sha256 $ExpectedSpecSha256 --expected-script-sha256 $ExpectedScriptSha256
  exit $LASTEXITCODE
 }
 if(-not $ConfirmApply){throw 'explicit-confirm-apply-required'}
 $intentPath=$receiptPath+'.launch.json'
 $launch=@{status='launch-intent';phase=$validated.phase;spec_sha256=$validated.spec_sha256;script_sha256=$validated.script_sha256;spec=$specFile.FullName;receipt=$receiptPath;script=$PSCommandPath;python=(Get-Item -LiteralPath $Python).FullName;cwd=(Get-Location).Path;lifetime='single-receipt-worker';ready_when='receipt-written-and-worker-exited'}
 $stream=[IO.File]::Open($intentPath,[IO.FileMode]::CreateNew)
 try{$bytes=[Text.Encoding]::UTF8.GetBytes(($launch|ConvertTo-Json -Depth 5));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
 # Paths are exact arguments to pwsh -File, not evaluated command text.
 foreach($value in @($Spec,$Receipt,$Python,$PSCommandPath)){if($value.Contains('"')){throw 'quote-in-launch-path'}}
 $args=@('-NoLogo','-NoProfile','-NonInteractive','-File',('"'+$PSCommandPath+'"'),'-Mode','Worker','-Spec',('"'+$specFile.FullName+'"'),'-Receipt',('"'+$receiptPath+'"'),'-Python',('"'+$launch.python+'"'),'-ExpectedSpecSha256',$validated.spec_sha256,'-ExpectedScriptSha256',$validated.script_sha256)
 $resultPath=$receiptPath+'.launched.json'
 # Reserve the lifecycle result before UAC; a conflicting sidecar cannot fail
 # after the worker has already started. Keep this exact handle through publish.
 $resultStream=[IO.File]::Open($resultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 $process=$null
 try{
  $process=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $args -WorkingDirectory (Get-Location).Path -PassThru
  $launch.status='launched-not-yet-verified';$launch.pid=$process.Id;$launch.start_time=$process.StartTime.ToUniversalTime().ToString('o')
  $bytes=[Text.Encoding]::UTF8.GetBytes(($launch|ConvertTo-Json -Depth 5));$resultStream.Write($bytes,0,$bytes.Length);$resultStream.Flush($true)
 }finally{$resultStream.Dispose()}
 @{ok=$true;status=$launch.status;pid=$launch.pid;phase=$launch.phase;receipt=$receiptPath;launch_evidence=$resultPath}|ConvertTo-Json -Compress
}catch{
 $code=if($_.Exception.Message -match '^[a-z][a-z-]+$'){$_.Exception.Message}else{'elevation-entry-failed'}
 if($null -ne $process){@{ok=$false;status='worker-started-evidence-error';pid=$process.Id;receipt=$receiptPath;error_code=$code}|ConvertTo-Json -Compress}
 else{@{ok=$false;status='rejected';error_code=$code}|ConvertTo-Json -Compress}
 exit 1
}
