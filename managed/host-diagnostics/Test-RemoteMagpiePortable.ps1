#requires -Version 7.4
# Public entry + real RemoteStep; replace only SSH, HTTP download and Windows observation boundaries.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$evidence = 'D:/agents/run-evidence/remote-magpie-tests/' + [guid]::NewGuid().ToString('N')
$bin = Join-Path $evidence 'scripts'
$null = New-Item -ItemType Directory -Path $bin -Force
foreach ($name in @('Invoke-RemoteMagpiePortable.ps1','MagpiePortablePayload.ps1','Invoke-RemoteStep.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $bin $name)
}
$bytes = Join-Path $evidence 'official.exe'
[IO.File]::WriteAllText($bytes, 'official-fixture-magpie', $utf8)
$sha = (Get-FileHash -LiteralPath $bytes -Algorithm SHA256).Hash.ToLowerInvariant()
$metadata = @{version='0.1.3616';assets=@{'magpie-windows-amd64.exe'=@{url='https://usemagpie.ai/files/v0.1.3616/magpie-windows-amd64.exe';size=23;sha256=$sha}}}
# File is 23 UTF-8 bytes, including no BOM/newline.
$metadata.assets.'magpie-windows-amd64.exe'.size = (Get-Item -LiteralPath $bytes).Length
$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidence 'metadata.json') -Encoding utf8
@'
param($Target,$ScriptPath,$OutputPath,$StdinScript,$TimeoutSeconds,[switch]$RequireRemoteContext)
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText($ScriptPath)
if ($RequireRemoteContext -and -not $source.StartsWith("if (`$env:CODEX_REMOTE_EXECUTION_TARGET -ne '$Target')")) { throw 'Missing first remote assertion' }
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
foreach ($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'remote-fixture.ps1'),$ScriptPath)) { $psi.ArgumentList.Add($arg) }
$psi.UseShellExecute=$false
$psi.RedirectStandardInput=$true
$psi.RedirectStandardOutput=$true
$psi.RedirectStandardError=$true
$psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
$psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
$psi.Environment['CODEX_REMOTE_EXECUTION_TARGET']= if ($env:MAGPIE_CASE -eq 'wrong-context') { 'study' } else { $Target }
$psi.Environment['COMPUTERNAME']= if ($env:MAGPIE_CASE -eq 'wrong-device') { 'OTHER' } else { 'FIXTURE-PC' }
$p=[Diagnostics.Process]::Start($psi)
$outTask=$p.StandardOutput.ReadToEndAsync()
$errTask=$p.StandardError.ReadToEndAsync()
$p.StandardInput.Write((& $StdinScript | Out-String))
$p.StandardInput.Close()
if (-not $p.WaitForExit(20000)) { $p.Kill($true); throw 'Fixture remote timeout' }
[IO.File]::WriteAllText($OutputPath,$outTask.GetAwaiter().GetResult())
[IO.File]::WriteAllText($OutputPath+'.err',$errTask.GetAwaiter().GetResult())
[IO.File]::WriteAllText((Join-Path $env:MAGPIE_CASE_ROOT 'transport.json'),(@{writeOperation=$RequireRemoteContext.IsPresent;target=$Target}|ConvertTo-Json))
@{result=if($p.ExitCode -eq 0){'ok'}else{'failed'};target=$Target;exitCode=$p.ExitCode;stdout=$OutputPath} | ConvertTo-Json -Compress
exit $p.ExitCode
'@ | Set-Content -LiteralPath (Join-Path $bin 'Invoke-OfficeRemote.ps1') -Encoding utf8
@'
param([string]$Bootstrap)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
function Get-CimInstance {
    param($ClassName,$Filter)
    switch ($ClassName) {
        'Win32_ComputerSystem' { [pscustomobject]@{UserName='FIXTURE-PC\DesktopUser'} }
        'Win32_UserProfile' { [pscustomobject]@{LocalPath=$env:MAGPIE_CASE_ROOT} }
        'Win32_Process' {
            if ($Filter -eq "Name='explorer.exe'" -or $Filter -eq 'ProcessId=11') { [pscustomobject]@{Name='explorer.exe';ProcessId=11;SessionId=3;ExecutablePath='C:\Windows\explorer.exe'} }
            elseif ($Filter -eq 'ProcessId=27496' -and $env:MAGPIE_CASE -like 'running-update-live*') {
                [pscustomobject]@{Name=if($env:MAGPIE_CASE -eq 'running-update-live-bad-name'){'cmd.exe'}else{'magpie.exe'};ProcessId=27496;SessionId=if($env:MAGPIE_CASE -eq 'running-update-live-bad-session'){0}else{3};ExecutablePath=if($env:MAGPIE_CASE -eq 'running-update-live-bad-path'){'D:\other\magpie.exe'}else{Join-Path $env:MAGPIE_CASE_ROOT 'app/magpie.exe'}}
            }
            elseif ($Filter -eq "Name='magpie.exe'" -and $env:MAGPIE_CASE -like 'running*') {
                if ($env:MAGPIE_CASE -like 'running-update*') {
                    [pscustomobject]@{Name='magpie.exe';ProcessId=14124;ParentProcessId=27496;SessionId=3;ExecutablePath=(Join-Path $env:MAGPIE_CASE_ROOT 'app/magpie.exe')}
                } else {
                    [pscustomobject]@{Name='magpie.exe';ProcessId=22;ParentProcessId=if($env:MAGPIE_CASE -eq 'running-wrong-parent'){99}else{11};SessionId=if($env:MAGPIE_CASE -eq 'running-wrong-session'){0}else{3};ExecutablePath=if($env:MAGPIE_CASE -eq 'running-wrong-path'){'D:\other\magpie.exe'}else{Join-Path $env:MAGPIE_CASE_ROOT 'app/magpie.exe'}}
                }
            }
        }
        default { throw "Unexpected CIM class $ClassName" }
    }
}
function Invoke-CimMethod {
    param($InputObject,$MethodName)
    if ($MethodName -eq 'GetOwner') { return [pscustomobject]@{ReturnValue=0;Domain='FIXTURE-PC';User='DesktopUser'} }
    if ($MethodName -eq 'GetOwnerSid') {
        $sid = if ($InputObject.ProcessId -in @(22,14124) -and $env:MAGPIE_CASE -like '*wrong-owner') { 'S-1-5-21-1-2-3-1002' } else { 'S-1-5-21-1-2-3-1001' }
        if ($InputObject.ProcessId -eq 27496 -and $env:MAGPIE_CASE -eq 'running-update-live-bad-owner') { $sid='S-1-5-21-1-2-3-1002' }
        return [pscustomobject]@{ReturnValue=0;Sid=$sid}
    }
    throw "Unexpected CIM method $MethodName"
}
function Get-Item {
    [CmdletBinding()]param($LiteralPath,[switch]$Force)
    if ($LiteralPath -like 'Registry::*') {
        $key = [pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValue { param($Name,$Default,$Options); return (Join-Path $env:MAGPIE_CASE_ROOT 'Desktop') }
        return $key
    }
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
}
function curl.exe {
    $arguments = @($args)
    $output = $arguments[[Array]::IndexOf($arguments,'--output')+1]
    $log = Join-Path $env:MAGPIE_CASE_ROOT 'downloads.txt'
    Add-Content -LiteralPath $log -Value 'download'
    if ($env:MAGPIE_CASE -eq 'bad-hash') { [IO.File]::WriteAllText($output,'corrupted') }
    else { [IO.File]::Copy($env:MAGPIE_BYTES,$output,$true) }
    if ($env:MAGPIE_CASE -eq 'shortcut-race') {
        $shell=New-Object -ComObject WScript.Shell
        $link=$shell.CreateShortcut((Join-Path $env:MAGPIE_CASE_ROOT 'Desktop/Magpie.lnk'))
        $link.TargetPath='D:\other\magpie.exe'
        $link.Save()
    }
    $global:LASTEXITCODE=0
}
function Get-Process {
    param($Id)
    $started=([datetimeoffset]'2026-11-10T22:42:19.8046410+08:00').LocalDateTime
    if ($Id -eq 27496) { $started=if($env:MAGPIE_CASE -eq 'running-update-live-newer-parent'){$started.AddSeconds(30)}else{$started.AddMinutes(-70)} }
    [pscustomobject]@{HasExited=$false;Responding=($env:MAGPIE_CASE -ne 'running-unhealthy');StartTime=$started}
}
function Get-NetTCPConnection {
    param($State,$LocalPort)
    if ($env:MAGPIE_CASE -ne 'running-no-listener') { [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=3425;OwningProcess=if($env:MAGPIE_CASE -like 'running-update*'){14124}else{22}} }
}
& $Bootstrap
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
'@ | Set-Content -LiteralPath (Join-Path $bin 'remote-fixture.ps1') -Encoding utf8
@'
param($Entry,$Mode,$Root,$Metadata,$Case)
$ErrorActionPreference='Stop'
function Invoke-RestMethod {
    param($Uri,$TimeoutSec)
    if ($Uri -ne 'https://usemagpie.ai/api/latest') { throw "Unexpected metadata URL $Uri" }
    if ($Case -eq 'pinned') { throw 'Pinned verification must not fetch changing latest metadata' }
    $value = [IO.File]::ReadAllText($Metadata) | ConvertFrom-Json
    if ($Case -eq 'untrusted-url') { $value.assets.'magpie-windows-amd64.exe'.url='https://example.org/magpie.exe' }
    if ($Case -eq 'missing-hash') { $value.assets.'magpie-windows-amd64.exe'.sha256='' }
    $value
}
$extra=@{}
if ($Case -eq 'pinned') { $extra.ReleaseMetadataPath=$Metadata }
if ($Case -in @('require-running','running-required')) { $extra.RequireRunning=$true }
& $Entry -Mode $Mode -Target office -ExpectedComputerName FIXTURE-PC -InteractiveUser 'FIXTURE-PC\DesktopUser' -Architecture amd64 -InstallDirectory (Join-Path $Root 'app') -EvidenceRoot (Join-Path $Root 'evidence') @extra
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
'@ | Set-Content -LiteralPath (Join-Path $bin 'caller.ps1') -Encoding utf8
function Invoke-Case([string]$Mode,[string]$Case,[string]$Root) {
    $null=New-Item -ItemType Directory -Path (Join-Path $Root 'Desktop') -Force
    $psi=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach($arg in @('-NoProfile','-File',(Join-Path $bin 'caller.ps1'),(Join-Path $bin 'Invoke-RemoteMagpiePortable.ps1'),$Mode,$Root,(Join-Path $evidence 'metadata.json'),$Case)){ $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=$utf8
    $psi.StandardErrorEncoding=$utf8
    $psi.Environment['MAGPIE_CASE']=$Case
    $psi.Environment['MAGPIE_CASE_ROOT']=$Root
    $psi.Environment['MAGPIE_BYTES']=$bytes
    $p=[Diagnostics.Process]::Start($psi)
    $outTask=$p.StandardOutput.ReadToEndAsync()
    $errTask=$p.StandardError.ReadToEndAsync()
    if(-not $p.WaitForExit(30000)){ $p.Kill($true);throw 'Public entry timeout' }
    $text=$outTask.GetAwaiter().GetResult()
    $report=$null
    try{$report=$text|ConvertFrom-Json}catch{}
    [pscustomobject]@{exitCode=$p.ExitCode;report=$report;stdout=$text;stderr=$errTask.GetAwaiter().GetResult()}
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){[Console]::Error.WriteLine($Message);throw $Message}}
$root=Join-Path $evidence 'success'
$first=Invoke-Case Install success $root
Assert ($first.exitCode -eq 0) "Install failed: $($first.stdout) $($first.stderr)"
Assert ($first.report.status -eq 'installed' -and $first.report.asset.sha256 -eq $sha) 'Successful install must report verified official bytes'
Assert ((Get-Content -LiteralPath (Join-Path $root 'transport.json') -Raw | ConvertFrom-Json).writeOperation) 'Install must invoke RemoteStep with WriteOperation'
$verify=Invoke-Case Verify success $root
Assert ($verify.exitCode -eq 0 -and $verify.report.status -eq 'verified') 'Verify must read back the installation'
Assert (-not ((Get-Content -LiteralPath (Join-Path $root 'transport.json') -Raw | ConvertFrom-Json).writeOperation)) 'Verify must not request WriteOperation'
$exePath=Join-Path $root 'app/magpie.exe'
$linkPath=Join-Path $root 'Desktop/Magpie.lnk'
$exeTime=(Get-Item -LiteralPath $exePath).LastWriteTimeUtc
$linkHash=(Get-FileHash -LiteralPath $linkPath).Hash
$linkTime=(Get-Item -LiteralPath $linkPath).LastWriteTimeUtc
$repeat=Invoke-Case Install success $root
Assert ($repeat.exitCode -eq 0 -and $repeat.report.status -eq 'unchanged' -and $repeat.report.changes.Count -eq 0) "Repeat install must be a no-op: $($repeat.stdout)"
Assert (((Get-Item -LiteralPath $exePath).LastWriteTimeUtc -eq $exeTime) -and ((Get-Item -LiteralPath $linkPath).LastWriteTimeUtc -eq $linkTime) -and ((Get-FileHash -LiteralPath $linkPath).Hash -eq $linkHash)) 'Repeat install changed existing files'
Assert (@(Get-Content -LiteralPath (Join-Path $root 'downloads.txt')).Count -eq 1) 'Repeat install downloaded again'
$running=Invoke-Case Install running $root
Assert ($running.exitCode -eq 0 -and $running.report.status -eq 'unchanged' -and $running.report.processState -eq 'running-verified' -and $running.report.processes[0].parentPid -eq 11) "Healthy existing process must pass without relaunch: $($running.stdout)"
Assert ($running.report.changes.Count -eq 0 -and @(Get-Content -LiteralPath (Join-Path $root 'downloads.txt')).Count -eq 1) 'Already-running install performed writes'
$cases=4
foreach($case in @('running-wrong-path','running-wrong-session','running-wrong-parent','running-unhealthy','running-no-listener')){
    $result=Invoke-Case Install $case $root
    Assert ($result.exitCode -ne 0 -and $result.report.status -eq 'failed' -and $result.report.changes.Count -eq 0) "Unsafe process accepted: $case $($result.stdout)"
    $cases++
}
$empty=Join-Path $evidence 'plan-empty'
$plan=Invoke-Case Plan success $empty
Assert ($plan.exitCode -eq 0 -and $plan.report.status -eq 'planned' -and -not (Test-Path -LiteralPath (Join-Path $empty 'app'))) 'Plan must not create the target application directory'
$cases++
foreach($case in @('bad-hash','wrong-device','wrong-context','different-exe','directory-at-exe','unknown-directory','shortcut-conflict','data-conflict')){
    $caseRoot=Join-Path $evidence $case
    $app=Join-Path $caseRoot 'app'
    $null=New-Item -ItemType Directory -Path (Join-Path $caseRoot 'Desktop') -Force
    if($case -in @('different-exe','directory-at-exe','unknown-directory','data-conflict')){$null=New-Item -ItemType Directory -Path $app -Force}
    if($case -eq 'different-exe'){[IO.File]::WriteAllText((Join-Path $app 'magpie.exe'),'user-owned-executable')}
    if($case -eq 'directory-at-exe'){$null=New-Item -ItemType Directory -Path (Join-Path $app 'magpie.exe')}
    if($case -eq 'unknown-directory'){[IO.File]::WriteAllText((Join-Path $app 'unknown.txt'),'user-owned')}
    if($case -eq 'data-conflict'){Copy-Item -LiteralPath $bytes -Destination (Join-Path $app 'magpie.exe');[IO.File]::WriteAllText((Join-Path $app 'data'),'user-owned')}
    if($case -eq 'shortcut-conflict'){
        $shell=New-Object -ComObject WScript.Shell
        $link=$shell.CreateShortcut((Join-Path $caseRoot 'Desktop/Magpie.lnk'))
        $link.TargetPath='D:\other\magpie.exe'
        $link.Save()
    }
    $result=Invoke-Case Install $case $caseRoot
    Assert ($result.exitCode -ne 0 -and ($case -eq 'wrong-context' -or ($null -ne $result.report -and $result.report.status -eq 'failed'))) "Conflict accepted: $case $($result.stdout) $($result.stderr)"
    if($case -eq 'bad-hash'){
        Assert (-not (Test-Path -LiteralPath (Join-Path $app 'magpie.exe')) -and -not (Test-Path -LiteralPath (Join-Path $caseRoot 'Desktop/Magpie.lnk')) -and (Test-Path -LiteralPath $result.report.downloadPath)) 'Integrity failure must retain the failed download but never publish exe/shortcut'
    }else{
        Assert (($case -eq 'wrong-context' -or $result.report.changes.Count -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $caseRoot 'downloads.txt'))) "Conflict caused writes: $case"
    }
    if($case -eq 'different-exe'){Assert ([IO.File]::ReadAllText((Join-Path $app 'magpie.exe')) -eq 'user-owned-executable') 'Existing different executable was overwritten'}
    $cases++
}
$raceRoot=Join-Path $evidence 'shortcut-race'
$race=Invoke-Case Install shortcut-race $raceRoot
Assert ($race.exitCode -ne 0 -and $race.report.status -eq 'failed') 'Shortcut created during download must not be overwritten'
$shell=New-Object -ComObject WScript.Shell
Assert ($shell.CreateShortcut((Join-Path $raceRoot 'Desktop/Magpie.lnk')).TargetPath -eq 'D:\other\magpie.exe') 'Racing shortcut target was overwritten'
$cases++
$pinned=Invoke-Case Verify pinned $root
Assert ($pinned.exitCode -eq 0 -and $pinned.report.status -eq 'verified') 'Pinned official metadata verification failed'
$cases++
$requireRunning=Invoke-Case Verify require-running $root
Assert ($requireRunning.exitCode -ne 0 -and $requireRunning.report.error -like 'Magpie is not running*' -and $requireRunning.report.changes.Count -eq 0) 'RequireRunning must fail read-only when absent'
$cases++
$requireHealthy=Invoke-Case Verify running-required $root
Assert ($requireHealthy.exitCode -eq 0 -and $requireHealthy.report.processState -eq 'running-verified' -and $requireHealthy.report.changes.Count -eq 0) 'RequireRunning did not accept a healthy existing process'
$cases++
foreach($case in @('untrusted-url','missing-hash')){
    $invalidRoot=Join-Path $evidence $case
    $invalid=Invoke-Case Install $case $invalidRoot
    Assert ($invalid.exitCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $invalidRoot 'transport.json')) -and -not (Test-Path -LiteralPath (Join-Path $invalidRoot 'app'))) "Invalid official metadata reached remote execution: $case"
    $cases++
}
$junctionRoot=Join-Path $evidence 'reparse'
$redirectRoot=Join-Path $evidence 'redirect-target'
$null=New-Item -ItemType Directory -Path $junctionRoot,$redirectRoot -Force
$null=New-Item -ItemType Junction -Path (Join-Path $junctionRoot 'app') -Target $redirectRoot
$junction=Invoke-Case Install success $junctionRoot
Assert ($junction.exitCode -ne 0 -and @(Get-ChildItem -LiteralPath $redirectRoot -Force).Count -eq 0) 'Reparse installation path must be refused before writes'
$cases++
$logDirectory=Join-Path $root 'app/data/logs'
$null=New-Item -ItemType Directory -Path $logDirectory -Force
$portableLog=Join-Path $logDirectory 'app.log'
$startupTime=([datetimeoffset]'2026-11-10T22:42:20+08:00').LocalDateTime.ToString('yyyy/MM/dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
$startupLine="$startupTime magpie 0.1.3616 started (app, pid 14124, windows/amd64); this log: $portableLog"
[IO.File]::WriteAllText($portableLog,"unrelated-private-fixture-line`n$startupLine`n",$utf8)
[IO.File]::SetLastWriteTimeUtc($exePath,([datetimeoffset]'2026-11-10T14:42:18.5219003Z').UtcDateTime)
$updated=Invoke-Case Verify running-update-exited $root
Assert ($updated.exitCode -eq 0 -and $updated.report.processState -eq 'running-verified' -and $updated.report.processes[0].parent -eq 'exited' -and $updated.report.processes[0].launchEvidence -eq 'portable-startup-log') "Self-updated process with corroborated startup log must verify: $($updated.stdout)"
Assert ($updated.report.changes.Count -eq 0 -and $updated.stdout -notmatch 'unrelated-private-fixture-line') 'Update verification must be read-only and must not disclose unrelated logs'
$cases++
# An exited parent never permits missing, truncated, duplicated or mismatched startup evidence.
$badLogs=[ordered]@{
    'no-startup'='unrelated-private-fixture-line'
    'wrong-pid'=$startupLine.Replace('pid 14124','pid 99999')
    'wrong-version'=$startupLine.Replace('0.1.3616','0.1.3598')
    'wrong-arch'=$startupLine.Replace('windows/amd64','windows/arm64')
    'wrong-path'=$startupLine.Replace($portableLog,'D:\other\data\logs\app.log')
    'wrong-time'=$startupLine.Replace($startupTime,([datetimeoffset]'2026-11-10T23:42:20+08:00').LocalDateTime.ToString('yyyy/MM/dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture))
    'truncated'="$startupTime magpie 0.1.3616 started (app, pid 14124"
    'duplicate'="$startupLine`n$startupLine"
}
foreach($name in $badLogs.Keys){
    [IO.File]::WriteAllText($portableLog,($badLogs[$name]+"`n"),$utf8)
    $invalid=Invoke-Case Verify running-update-exited $root
    Assert ($invalid.exitCode -ne 0 -and $invalid.report.status -eq 'failed' -and $invalid.report.changes.Count -eq 0) "Invalid startup log accepted: $name"
    Assert ($invalid.stdout -notmatch 'unrelated-private-fixture-line') 'Private log content leaked'
    $cases++
}
[IO.File]::WriteAllText($portableLog,($startupLine+"`n"),$utf8)
foreach($case in @('running-wrong-owner','running-update-wrong-owner','running-update-live-bad-owner','running-update-live-bad-session','running-update-live-bad-name','running-update-live-bad-path','running-update-live-newer-parent')){
    $invalid=Invoke-Case Verify $case $root
    Assert ($invalid.exitCode -ne 0 -and $invalid.report.status -eq 'failed' -and $invalid.report.changes.Count -eq 0) "Invalid owner/live parent accepted: $case $($invalid.stdout)"
    $cases++
}
$liveParent=Invoke-Case Verify running-update-live $root
Assert ($liveParent.exitCode -eq 0 -and $liveParent.report.processes[0].parent -eq 'magpie.exe' -and $liveParent.report.processes[0].launchEvidence -eq 'same-user-magpie-parent' -and $liveParent.report.changes.Count -eq 0) 'Healthy same-path same-owner same-session live Magpie parent must pass'
$cases++
[IO.File]::SetLastWriteTimeUtc($exePath,([datetimeoffset]'2026-11-10T14:43:20Z').UtcDateTime)
$futureBinary=Invoke-Case Verify running-update-exited $root
Assert ($futureBinary.exitCode -ne 0 -and $futureBinary.report.error -eq 'Executable/process startup times conflict') 'Binary modified after process startup must not prove an exited parent'
$cases++
[IO.File]::SetLastWriteTimeUtc($exePath,([datetimeoffset]'2026-11-10T14:42:18.5219003Z').UtcDateTime)
$missingLogRoot=Join-Path $evidence 'missing-startup-log'
$setup=Invoke-Case Install success $missingLogRoot
Assert ($setup.exitCode -eq 0) 'Missing-log fixture setup failed'
$missingLog=Invoke-Case Verify running-update-exited $missingLogRoot
Assert ($missingLog.exitCode -ne 0 -and $missingLog.report.error -eq 'Portable startup log is missing for exited parent' -and $missingLog.report.changes.Count -eq 0) 'Missing startup log must fail closed'
$cases++
[ordered]@{status='passed';cases=$cases;evidence=$evidence}|ConvertTo-Json -Compress
