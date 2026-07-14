param([switch]$CheckNetwork,[switch]$CheckOnly,[switch]$Repair,[switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($CheckOnly -and $Repair){throw 'CheckOnly 与 Repair 不能同时使用。'}
if($CheckOnly -and $CheckNetwork){throw 'CheckOnly 与 CheckNetwork 不能同时使用。'}
if($Repair -and $CheckNetwork){throw 'Repair 与 CheckNetwork 不能同时使用。'}

$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'lib\CodexHookRuntime.ps1')
. (Join-Path $scriptRoot 'lib\CodexConfigFile.ps1')
. (Join-Path $scriptRoot 'lib\CodexProviderGuardCore.ps1')

$configPath='D:\Codex\.codex\config.toml'
$backupRoot='D:\Codex\.codex\backups_state\provider-stability-guard'
$pythonPath='D:\Codex\tools\python314-official\python.exe'
$mutexName='Local\CodexConfigTomlGuard'
$proxyUrl='http://127.0.0.1:10808'
$noProxy='localhost,127.0.0.1,::1'
$desiredEnvironment=@(
    @('HTTP_PROXY',$proxyUrl),@('HTTPS_PROXY',$proxyUrl),@('http_proxy',$proxyUrl),@('https_proxy',$proxyUrl),
    @('ALL_PROXY',$proxyUrl),@('all_proxy',$proxyUrl),@('NO_PROXY',$noProxy),@('no_proxy',$noProxy)
)

function Assert-ProviderToml([string]$Path){
    $result=Invoke-CodexHookProcess -FilePath $pythonPath -ArgumentList @('-c','import pathlib,sys,tomllib; value=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)',$Path) -TimeoutMilliseconds 1000
    if($result.exitCode -ne 0){throw 'TOML validator rejected provider config.'}
}
function Get-ProviderDesiredConfigText([string]$Text){
    $sections=[ordered]@{
        features=[ordered]@{unified_exec='true';image_generation='false';responses_websockets_v2='false';responses_websockets='false';network_proxy='false';respect_system_proxy='false'}
        network=[ordered]@{enabled='true';allow_local_binding='true';allow_upstream_proxy='true';proxy_url='"http://127.0.0.1:10808"'}
    }
    return Update-CodexTomlPolicyText -Text $Text -Sections $sections -RemoveKeys @('experimental_use_unified_exec_tool')
}
function Read-ProviderConfigState {
    if(-not [IO.File]::Exists($configPath)){throw 'Codex config 不存在。'}
    return Invoke-CodexHookMutex -Name $mutexName -ScriptBlock {
        Assert-ProviderToml $configPath
        $text=[IO.File]::ReadAllText($configPath)
        [ordered]@{drift=((Get-ProviderDesiredConfigText $text) -cne $text)}
    }
}
function Repair-ProviderConfig([object]$Tracker){
    Invoke-CodexHookMutex -Name $mutexName -ScriptBlock {
        Assert-ProviderToml $configPath
        $before=Get-CodexHookSha256 $configPath
        $text=[IO.File]::ReadAllText($configPath)
        $after=Get-ProviderDesiredConfigText $text
        if($after -ceq $text){return}
        $null=Write-CodexHookAtomicText -Path $configPath -Text $after -Validator ${function:Assert-ProviderToml} -BackupRoot $backupRoot -ExpectedBeforeSha256 $before
        $Tracker.changed=$true
        $Tracker.restartRequired=$true
    }
}
function Read-ProviderEnvironmentState {
    $drift=0
    foreach($entry in $desiredEnvironment){
        $name=[string]$entry[0];$expected=[string]$entry[1]
        foreach($scope in @('User','Process')){if([Environment]::GetEnvironmentVariable($name,$scope) -cne $expected){$drift++}}
    }
    return [ordered]@{driftCount=$drift}
}
function Repair-ProviderEnvironment([object]$Tracker){
    foreach($entry in $desiredEnvironment){
        $name=[string]$entry[0];$expected=[string]$entry[1]
        $before=[Environment]::GetEnvironmentVariable($name,'User')
        if($before -ceq $expected){continue}
        [Environment]::SetEnvironmentVariable($name,$expected,'User')
        if([Environment]::GetEnvironmentVariable($name,'User') -cne $expected){throw 'provider User environment post-read failed'}
        $Tracker.changed=$true
        $Tracker.restartRequired=$true
    }
    # 当前子进程不能修改父 Codex 的 Process 环境；该漂移由 post-read 保留到重启后收敛。
}
function Invoke-ProviderNetworkProbe {
    $result=Invoke-CodexHookProcess -FilePath 'C:\Windows\System32\curl.exe' -ArgumentList @('-sS','-o','NUL','-w','http_code=%{http_code} proxy=%{proxy_used}','--connect-timeout','8','https://chatgpt.com/backend-api/codex/models') -TimeoutMilliseconds 9000
    $code=if($result.stdout -match 'http_code=(\d{3})'){$Matches[1]}else{$null}
    $used=if($result.stdout -match 'proxy=([01])'){$Matches[1]}else{$null}
    return [ordered]@{checked=$true;ok=($result.exitCode -eq 0 -and $code -in @('200','401','403') -and $used -eq '1');exitCode=$result.exitCode;httpCode=$code;proxyUsed=$used}
}

$started=[DateTime]::UtcNow;$timer=[Diagnostics.Stopwatch]::StartNew()
$result=Invoke-CodexProviderGuardCore -Repair:$Repair -CheckNetwork:$CheckNetwork `
    -ReadConfigState ${function:Read-ProviderConfigState} `
    -ReadEnvironmentState ${function:Read-ProviderEnvironmentState} `
    -RepairConfig ${function:Repair-ProviderConfig} `
    -RepairEnvironment ${function:Repair-ProviderEnvironment} `
    -NetworkProbe ${function:Invoke-ProviderNetworkProbe}
$timer.Stop()
if($Repair){
    $health=[pscustomobject][ordered]@{hookId='provider-stability';runId=[guid]::NewGuid().ToString('N');startedAtUtc=$started.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=[long]$timer.ElapsedMilliseconds;ok=[bool]$result.ok;changed=[bool]$result.changed;restartRequired=[bool]$result.restartRequired;errors=[string[]]$result.errors}
    try{$null=Write-CodexHookLatestHealth -HookId 'provider-stability' -Payload $health}catch{$result.ok=$false;$result.converged=$false;$result.errors=[string[]](@($result.errors)+@('health evidence write failed'))}
}
if($Json){$result|ConvertTo-Json -Depth 8}
if(-not $result.ok){throw (@($result.errors) -join '; ')}
