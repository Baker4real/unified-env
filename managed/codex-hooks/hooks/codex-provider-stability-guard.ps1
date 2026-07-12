param([switch]$CheckNetwork,[switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'lib\CodexHookRuntime.ps1')
. (Join-Path $scriptRoot 'lib\CodexConfigFile.ps1')

$configPath='D:\Codex\.codex\config.toml'
$backupRoot='D:\Codex\.codex\backups_state\provider-stability-guard'
$pythonPath='D:\Codex\tools\python314-official\python.exe'
$mutexName='Local\CodexConfigTomlGuard'
$proxyUrl='http://127.0.0.1:10808'
$noProxy='localhost,127.0.0.1,::1'
$started=[DateTime]::UtcNow;$timer=[Diagnostics.Stopwatch]::StartNew();$runId=[guid]::NewGuid().ToString('N');$errors=[Collections.Generic.List[string]]::new();$changed=$false

function Assert-ProviderToml([string]$Path){$result=Invoke-CodexHookProcess -FilePath $pythonPath -ArgumentList @('-c','import pathlib,sys,tomllib; value=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)',$Path);if($result.exitCode -ne 0){throw 'TOML validator rejected provider config.'}}
function Set-ProviderConfigPolicy {
    if(-not [IO.File]::Exists($configPath)){throw "Codex config 不存在：$configPath"}
    Invoke-CodexHookMutex -Name $mutexName -ScriptBlock {
        Assert-ProviderToml $configPath
        $before=Get-CodexHookSha256 $configPath;$text=[IO.File]::ReadAllText($configPath)
        $sections=[ordered]@{
            features=[ordered]@{unified_exec='true';image_generation='false';responses_websockets_v2='false';responses_websockets='false';network_proxy='false';respect_system_proxy='false'}
            network=[ordered]@{enabled='true';allow_local_binding='true';allow_upstream_proxy='true';proxy_url='"http://127.0.0.1:10808"'}
        }
        $after=Update-CodexTomlPolicyText -Text $text -Sections $sections -RemoveKeys @('experimental_use_unified_exec_tool')
        if($after -ceq $text){return $false}
        $null=Write-CodexHookAtomicText -Path $configPath -Text $after -Validator ${function:Assert-ProviderToml} -BackupRoot $backupRoot -ExpectedBeforeSha256 $before
        return $true
    }
}
function ConvertTo-SafeEnvironmentValue([string]$Name,[AllowNull()][string]$Value){if($null -eq $Value){return $null};if($Name -match '(?i)proxy' -and $Name -notmatch '(?i)^no_proxy$'){try{return ConvertTo-CodexHookRedactedUri $Value}catch{return '[invalid-uri]'}};return $Value}
function Set-ProviderProxyPolicy {
    $desired=@(
        @('HTTP_PROXY',$proxyUrl),@('HTTPS_PROXY',$proxyUrl),@('http_proxy',$proxyUrl),@('https_proxy',$proxyUrl),
        @('ALL_PROXY',$proxyUrl),@('all_proxy',$proxyUrl),@('NO_PROXY',$noProxy),@('no_proxy',$noProxy)
    );$repairs=[Collections.Generic.List[object]]::new()
    foreach($entry in $desired){$name=[string]$entry[0];$expected=[string]$entry[1];foreach($scope in @('User','Process')){$before=[Environment]::GetEnvironmentVariable($name,$scope);if($before -cne $expected){[Environment]::SetEnvironmentVariable($name,$expected,$scope);$repairs.Add([pscustomobject][ordered]@{name=$name;scope=$scope;before=ConvertTo-SafeEnvironmentValue $name $before;after=ConvertTo-SafeEnvironmentValue $name $expected})}}}
    return @($repairs)
}
function Test-ProviderNetwork {
    if(-not $CheckNetwork){return [pscustomobject][ordered]@{checked=$false}}
    $result=Invoke-CodexHookProcess -FilePath 'C:\Windows\System32\curl.exe' -ArgumentList @('-sS','-o','NUL','-w','http_code=%{http_code} proxy=%{proxy_used}','--connect-timeout','8','https://chatgpt.com/backend-api/codex/models') -TimeoutMilliseconds 9000
    $code=if($result.stdout -match 'http_code=(\d{3})'){$Matches[1]}else{$null};$used=if($result.stdout -match 'proxy=([01])'){$Matches[1]}else{$null}
    return [pscustomobject][ordered]@{checked=$true;ok=($result.exitCode -eq 0 -and $code -in @('200','401','403') -and $used -eq '1');exitCode=$result.exitCode;httpCode=$code;proxyUsed=$used}
}

try{$changed=[bool](Set-ProviderConfigPolicy);$repairs=Set-ProviderProxyPolicy;if($repairs.Count){$changed=$true};$network=Test-ProviderNetwork;if($CheckNetwork -and -not $network.ok){throw 'Codex backend connectivity check failed.'};$ok=$true}catch{$ok=$false;$errors.Add(($_.Exception.Message -replace '(?i)https?://\S+','[redacted-uri]'));$repairs=@();$network=[pscustomobject]@{checked=$false}}
$timer.Stop();$health=[pscustomobject][ordered]@{hookId='provider-stability';runId=$runId;startedAtUtc=$started.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=$timer.ElapsedMilliseconds;ok=$ok;changed=$changed;restartRequired=($repairs.Count -gt 0);errors=[string[]]$errors}
try{$null=Write-CodexHookLatestHealth -HookId 'provider-stability' -Payload $health}catch{if($ok){$ok=$false;$errors.Add('health evidence write failed.')}}
$payload=[pscustomobject][ordered]@{ok=$ok;configChanged=$changed;environmentRepairs=@($repairs);network=$network}
if($Json){$payload|ConvertTo-Json -Depth 8}elseif($changed -or $CheckNetwork){"configChanged=$changed; environmentRepairs=$($repairs.Count); networkChecked=$CheckNetwork"}
if(-not $ok){throw ($errors -join '; ')}
