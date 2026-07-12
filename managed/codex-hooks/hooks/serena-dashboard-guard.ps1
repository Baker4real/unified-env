Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'lib\CodexHookRuntime.ps1')
. (Join-Path $scriptRoot 'lib\CodexConfigFile.ps1')

$tomlPath='D:\Codex\.codex\config.toml';$yamlPath='D:\Codex\.serena\serena_config.yml'
$tomlBackup='D:\Codex\.codex\backups_state\serena-dashboard-guard\toml';$yamlBackup='D:\Codex\.codex\backups_state\serena-dashboard-guard\yaml'
$python='D:\Codex\tools\python314-official\python.exe';$serenaPython='D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe';$mutexName='Local\CodexConfigTomlGuard'
$started=[DateTime]::UtcNow;$timer=[Diagnostics.Stopwatch]::StartNew();$runId=[guid]::NewGuid().ToString('N');$errors=[Collections.Generic.List[string]]::new();$changed=$false
function Assert-SerenaToml([string]$Path){$r=Invoke-CodexHookProcess -FilePath $python -ArgumentList @('-c','import pathlib,sys,tomllib; value=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)',$Path);if($r.exitCode){throw 'TOML validator rejected Serena Codex config.'}}
function Assert-SerenaYaml([string]$Path){$r=Invoke-CodexHookProcess -FilePath $serenaPython -ArgumentList @('-c','import pathlib,sys,yaml; value=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)',$Path);if($r.exitCode){throw 'PyYAML validator rejected Serena config.'}}
function Set-SerenaPolicy {
    Invoke-CodexHookMutex -Name $mutexName -ScriptBlock {
        if(-not [IO.File]::Exists($tomlPath) -or -not [IO.File]::Exists($yamlPath)){throw 'Serena config target missing.'}
        Assert-SerenaToml $tomlPath;Assert-SerenaYaml $yamlPath
        $tomlBefore=Get-CodexHookSha256 $tomlPath;$tomlText=[IO.File]::ReadAllText($tomlPath)
        $sections=[ordered]@{
            'mcp_servers.serena'=[ordered]@{type='"stdio"';command='"D:\\Codex\\.codex\\scripts\\start-serena-mcp.cmd"';args=[ordered]@{value='[ "start-mcp-server", "--context=D:\\Codex\\.serena\\contexts\\codex-file-tools.yml", "--project-from-cwd", "--enable-web-dashboard=true", "--open-web-dashboard=false" ]';kind='array'}}
            'mcp_servers.serena.env'=[ordered]@{UV_TOOL_DIR='"D:\\Codex\\tools\\uv\\tools"';UV_TOOL_BIN_DIR='"D:\\Codex\\tools\\uv\\bin"';UV_PYTHON='"D:\\Codex\\tools\\python314-official\\python.exe"';PYTHON314_HOME='"D:\\Codex\\tools\\python314-official"';PYTHON314_EXE='"D:\\Codex\\tools\\python314-official\\python.exe"'}
        }
        $tomlAfter=Update-CodexTomlPolicyText -Text $tomlText -Sections $sections
        $yamlBefore=Get-CodexHookSha256 $yamlPath;$yamlText=[IO.File]::ReadAllText($yamlPath)
        $yamlValues=[ordered]@{gui_log_window='false';web_dashboard='true';web_dashboard_open_on_launch='false';web_dashboard_interface='tray_manager';project_serena_folder_location='"D:/Codex/.serena/projects/$projectFolderName/.serena"'}
        $yamlAfter=Update-SerenaYamlPolicyText -Text $yamlText -Values $yamlValues
        $didChange=$false
        if($tomlAfter -cne $tomlText){$null=Write-CodexHookAtomicText -Path $tomlPath -Text $tomlAfter -Validator ${function:Assert-SerenaToml} -BackupRoot $tomlBackup -ExpectedBeforeSha256 $tomlBefore;$didChange=$true}
        if($yamlAfter -cne $yamlText){$null=Write-CodexHookAtomicText -Path $yamlPath -Text $yamlAfter -Validator ${function:Assert-SerenaYaml} -BackupRoot $yamlBackup -ExpectedBeforeSha256 $yamlBefore;$didChange=$true}
        return $didChange
    }
}
try{$changed=[bool](Set-SerenaPolicy);$ok=$true}catch{$ok=$false;$errors.Add(($_.Exception.Message -replace '(?i)https?://\S+','[redacted-uri]'))}
$timer.Stop();$health=[pscustomobject][ordered]@{hookId='serena-dashboard';runId=$runId;startedAtUtc=$started.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=$timer.ElapsedMilliseconds;ok=$ok;changed=$changed;restartRequired=$changed;errors=[string[]]$errors}
try{$null=Write-CodexHookLatestHealth -HookId 'serena-dashboard' -Payload $health}catch{if($ok){$ok=$false;$errors.Add('health evidence write failed.')}}
if($changed){'Serena dashboard settings normalized for Codex.'}
if(-not $ok){throw ($errors -join '; ')}
