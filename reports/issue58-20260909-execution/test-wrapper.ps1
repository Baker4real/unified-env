param([string]$Revision='v2')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$pwsh='D:/Codex/tools/PowerShell/7.6.5/pwsh.exe'
$cases=@(
    @{mode='success';code=0;parse=$true;timeout=$false},
    @{mode='timeout';code=1;parse=$false;timeout=$true},
    @{mode='bad-json';code=1;parse=$false;timeout=$false},
    @{mode='pipe-timeout';code=1;parse=$false;timeout=$true},
    @{mode='missing-os';code=1;parse=$true;timeout=$false}
)
$rows=@()
foreach($case in $cases){
    $name='checked-'+$Revision+'-'+$case.mode
    $deadline=if($case.timeout){3500}else{10000}
    $arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'invoke-bounded.ps1'),'-Payload',(Join-Path $PSScriptRoot 'synthetic-child.ps1'),'-Name',$name,'-DeadlineMs',[string]$deadline)
    if($case.mode -eq 'missing-os'){$arguments+='-SimulateMissingOsObservation'}else{$arguments+=@('-PayloadArguments',$case.mode)}
    & $pwsh @arguments
    $raw=$LASTEXITCODE
    $r=Get-Content -LiteralPath (Join-Path $PSScriptRoot "$name/result.json") -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $passed=$raw -eq $case.code -and $r.parseSucceeded -eq $case.parse -and $r.timedOut -eq $case.timeout -and $r.jobEmpty -and $r.identityVerified
    if($case.mode -eq 'missing-os'){$passed=$passed -and $r.osObservation -eq 'unverified'}
    if($case.mode -eq 'bad-json'){$passed=$passed -and $r.exitCode -eq 0 -and $r.error.StartsWith('JSON:')}
    if($case.mode -eq 'pipe-timeout'){$passed=$passed -and $r.exitCode -eq 0 -and -not $r.completedBeforeDeadline}
    $rows+=@{case=$case.mode;rawExitCode=$raw;passed=$passed;childExitCode=$r.exitCode;jobEmpty=$r.jobEmpty}
}
if(-not ('Issue58N1.WriteObservation' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'ProcessObservation.cs')}
$scratch=Join-Path 'D:/agents/projects/统一环境/.scratch' ('safe-tree-delete-tests-issue58-n1-'+[guid]::NewGuid().ToString('N'))
$evidence=Join-Path $scratch 'evidence';$policy=Join-Path $scratch 'policy.json'
[void][IO.Directory]::CreateDirectory($evidence)
[IO.File]::WriteAllText($policy,'aaaa')
$watcher=[Issue58N1.WriteObservation]::new($evidence,$policy)
try {
    [IO.File]::WriteAllText($policy,'bbbb');[IO.File]::WriteAllText($policy,'aaaa')
    $one=Join-Path $evidence 'one';$two=Join-Path $evidence 'two'
    [IO.File]::WriteAllText($one,'fixture');[IO.File]::Move($one,$two);[IO.File]::Delete($two)
    Start-Sleep -Milliseconds 500
    $kinds=$watcher.KindCounts
    $rows+=@{case='fixture-write-restore-create-delete-rename';passed=($kinds[0] -gt 0 -and $kinds[1] -gt 0 -and $kinds[2] -gt 0 -and $kinds[3] -gt 0 -and $watcher.Errors.Count -eq 0);counts=$kinds;scratch=$scratch}
    $watcher.SimulateOverflowForTest()
    $rows+=@{case='overflow-invalid';passed=($watcher.OverflowCount -gt 0);injected=$true}
}finally{$watcher.Dispose()}
$unavailable=[Issue58N1.WriteObservation]::new((Join-Path $scratch 'missing'),$policy)
try{$rows+=@{case='watcher-unavailable-invalid';passed=($unavailable.Errors.Count -gt 0)}}finally{$unavailable.Dispose()}
$all=@($rows|Where-Object {-not $_.passed}).Count -eq 0
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "synthetic-checks-$Revision.json"),(@{passed=$all;checks=$rows}|ConvertTo-Json -Depth 8))
Write-Output "合成检查: passed=$all; cases=$($rows.Count)"
if(-not $all){exit 1}
exit 0
