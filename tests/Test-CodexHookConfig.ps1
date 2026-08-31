Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexConfigFile.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHookPolicy.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Action,[string]$Pattern){try{&$Action;throw 'DID_NOT_THROW'}catch{if($_.Exception.Message -eq 'DID_NOT_THROW' -or $_.Exception.Message -notmatch $Pattern){throw "异常不匹配 [$Pattern]：$($_.Exception.Message)"}}}
function Invoke-HiddenProcess([string]$FilePath,[string[]]$Arguments){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$FilePath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        Assert-True $process.Start() "子进程无法启动：$FilePath"
        $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
        Assert-True ($process.WaitForExit(10000)) "子进程超时：$FilePath"
        [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdoutTask.GetAwaiter().GetResult();stderr=$stderrTask.GetAwaiter().GetResult()}
    }finally{if(-not $process.HasExited){try{$process.Kill($true)}catch{}};$process.Dispose()}
}

$sections=[ordered]@{features=[ordered]@{unified_exec='true'};network=[ordered]@{enabled='true'}}
$input="[features]`n`nunified_exec = false`n`n[network]`nenabled = true`n"
$sw=[Diagnostics.Stopwatch]::StartNew();$output=Update-CodexTomlPolicyText -Text $input -Sections $sections;$sw.Stop();Assert-True ($sw.ElapsedMilliseconds -lt 1000) '空行 fixture 必须在1秒内返回';Assert-True ((Update-CodexTomlPolicyText -Text $output -Sections $sections) -ceq $output) 'TOML 必须幂等'
$commented="[features] # keep`r`n# comment`r`nunified_exec = false`r`nunknown = 7`r`n`r`n[mcp_servers.serena]`r`nargs = [`r`n  `"a`",`r`n  `"b`",`r`n]`r`n"
$changed=Set-CodexTomlSectionValue -Text $commented -Section 'mcp_servers.serena' -Key 'args' -Value '[ "x" ]' -ValueKind array
Assert-True ($changed.Contains("`r`n") -and $changed.Contains('# comment') -and $changed.Contains('unknown = 7')) 'CRLF、注释与未知键必须保留'
Assert-Throws { Set-CodexTomlSectionValue -Text "[features]`n[features]`n" -Section features -Key x -Value true } 'Duplicate TOML section'
Assert-Throws { Set-CodexTomlSectionValue -Text "[features]`nx=1`nx=2`n" -Section features -Key x -Value true } 'Duplicate TOML key'
Assert-Throws { Set-CodexTomlSectionValue -Text "[features]`nx = `"`"`"bad`"`"`"`n" -Section features -Key x -Value true } 'multiline'
$scalarOverArray="[features]`nunified_exec = [`n  false, # old`n]`nunknown = 7`n"
$scalarArrayOut=Set-CodexTomlSectionValue -Text $scalarOverArray -Section features -Key unified_exec -Value true
Assert-True ($scalarArrayOut -ceq "[features]`nunified_exec = true`nunknown = 7`n") 'scalar desired 必须删除当前多行 array 的完整范围'
$scalarOverTable="[features]`r`nunified_exec = {`r`n  old = false,`r`n  nested = { value = `"keep } #`" }, # old`r`n}`r`nunknown = 7 # keep`r`n"
$scalarTableOut=Set-CodexTomlSectionValue -Text $scalarOverTable -Section features -Key unified_exec -Value true
Assert-True ($scalarTableOut -ceq "[features]`r`nunified_exec = true`r`nunknown = 7 # keep`r`n") 'scalar desired 必须删除当前多行 inline table 的完整范围并保持 CRLF/注释/未知键'
Assert-True ((Set-CodexTomlSectionValue -Text $scalarTableOut -Section features -Key unified_exec -Value true) -ceq $scalarTableOut) 'scalar-over-table 必须幂等'

$yaml="web_dashboard: false`nnested:`n  web_dashboard: false`n# keep`n"
$values=[ordered]@{web_dashboard='true';web_dashboard_open_on_launch='false'}
$yamlOut=Update-SerenaYamlPolicyText -Text $yaml -Values $values
Assert-True ($yamlOut -match '(?m)^web_dashboard: true$') '顶层键必须更新';Assert-True ($yamlOut -match '(?m)^  web_dashboard: false$') '嵌套同名键必须保留';Assert-True ($yamlOut.Contains('# keep')) 'YAML 注释必须保留';Assert-True ((Update-SerenaYamlPolicyText -Text $yamlOut -Values $values) -ceq $yamlOut) 'YAML 必须幂等'
Assert-Throws { Update-SerenaYamlPolicyText -Text "web_dashboard: false`nweb_dashboard: true`n" -Values $values } 'Duplicate YAML'
$quotedYaml="web_dashboard: `"false`" # old`nnested:`n  web_dashboard: false # nested`n"
$quotedYamlOut=Update-SerenaYamlPolicyText -Text $quotedYaml -Values $values
Assert-True ($quotedYamlOut -match '(?m)^web_dashboard: true # old$') 'quoted scalar 必须收敛为 desired 并保留 inline comment'
Assert-True ($quotedYamlOut -match '(?m)^  web_dashboard: false # nested$') '嵌套同名键与 inline comment 必须保留'

$fixture='D:\agents\projects\统一环境\reports\codex-hook-config-test';if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force};[IO.Directory]::CreateDirectory($fixture)|Out-Null
$toml=Join-Path $fixture 'fixture.toml';[IO.File]::WriteAllText($toml,$output,[Text.UTF8Encoding]::new($false));$python='D:\Codex\tools\python314-official\python.exe'
$tomlResult=Invoke-HiddenProcess $python @('-c','import pathlib,sys,tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))',$toml);if($tomlResult.exitCode -ne 0){throw 'Python tomllib 验证失败'}
$yamlPath=Join-Path $fixture 'fixture.yml';[IO.File]::WriteAllText($yamlPath,$yamlOut,[Text.UTF8Encoding]::new($false));$serenaPython='D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe'
$yamlResult=Invoke-HiddenProcess $serenaPython @('-c','import pathlib,sys,yaml; value=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)',$yamlPath);if($yamlResult.exitCode -ne 0){throw 'PyYAML shape 验证失败'}
foreach($tomlText in @($scalarArrayOut,$scalarTableOut)){[IO.File]::WriteAllText($toml,$tomlText,[Text.UTF8Encoding]::new($false));$scalarResult=Invoke-HiddenProcess $python @('-c','import pathlib,sys,tomllib; value=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)',$toml);if($scalarResult.exitCode -ne 0){throw 'scalar replacement 后 tomllib 验证失败'}}
$badYaml=Join-Path $fixture 'malformed.yml';[IO.File]::WriteAllText($badYaml,"web_dashboard: [`n",[Text.UTF8Encoding]::new($false));$badYamlResult=Invoke-HiddenProcess $serenaPython @('-c','import pathlib,sys,yaml; yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))',$badYaml);Assert-True ($badYamlResult.exitCode -ne 0) 'malformed YAML 必须被 PyYAML 拒绝'

$astErrors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexConfigFile.ps1'),[ref]$tokens,[ref]$astErrors);Assert-True ($astErrors.Count -eq 0) 'config AST 必须合法'
$providerText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\codex-provider-stability-guard.ps1'))
$providerCoreText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexProviderGuardCore.ps1'))
$dashboardText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\serena-dashboard-guard.ps1'))
$activateText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\serena-behavior-guard.ps1'))
Assert-True ($providerText -match '\[switch\]\$CheckOnly' -and $providerText -match '\[switch\]\$Repair' -and $providerText.Contains('-Repair:$Repair') -and $providerText.Contains('if($CheckOnly -and $Repair){throw')) 'provider 必须默认只读并只允许显式 Repair'
Assert-True ($dashboardText -match '\[switch\]\$CheckOnly' -and $dashboardText.Contains('if(-not $CheckOnly)')) 'dashboard 必须提供明确只读 check-only 分支'
Assert-True ($activateText.Contains('absolute workspace root from environment_context') -and $activateText.Contains('mcp__serena__activate_project') -and $activateText.Contains('mcp__serena__get_current_config')) 'activation reminder 必须要求按 environment_context 的绝对 workspace 显式激活并复验'
Assert-True ($providerText.Contains('-CheckNetwork:$CheckNetwork') -and $providerText.Contains('-NetworkProbe ${function:Invoke-ProviderNetworkProbe}')) 'provider check-only/static acceptance 不得隐式联网；network probe 必须显式受 CheckNetwork 控制'
Assert-True (-not $providerText.Contains('elseif($changed -or $CheckNetwork)')) 'provider 默认 SessionStart 必须 zero stdout'
Assert-True (-not $dashboardText.Contains("if($changed){'Serena dashboard settings normalized for Codex.'}")) 'dashboard 默认 SessionStart 必须 zero stdout'
Assert-True ($providerCoreText.Contains("hookId = 'provider-stability'") -and $providerCoreText.Contains('driftCount = $driftCount') -and -not $providerCoreText.Contains('proxyUrl') -and -not $providerCoreText.Contains('noProxy')) 'provider JSON 必须只发布状态摘要，不得发布 raw proxy 值'
Assert-True (-not $providerText.Contains('$Watch') -and -not $providerText.Contains('Repair-CodexMobilePermissionDrift')) 'provider 不得保留 watcher 或 state/mobile 职责'
Assert-True ($providerText.Contains("Local\CodexConfigTomlGuard") -and $dashboardText.Contains("Local\CodexConfigTomlGuard")) '两者必须共享固定 TOML mutex'
Assert-True ($providerText.Contains('Update-CodexTomlPolicyText') -and $dashboardText.Contains('Update-CodexTomlPolicyText') -and $dashboardText.Contains('Update-SerenaYamlPolicyText')) 'hook 必须只声明 desired 并复用纯变换'
$manifest=Get-Content -Raw (Join-Path $projectRoot 'managed\codex-hooks\manifest.json')|ConvertFrom-Json
foreach($file in @($manifest.files)){
    $sourcePath=Join-Path $projectRoot ('managed\codex-hooks\'+[string]$file.relativePath)
    $actualSha256=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($actualSha256 -ceq [string]$file.sha256) "manifest source SHA-256 必须匹配：$($file.relativePath)"
}
$providerHook=@($manifest.hooks|Where-Object id -ceq 'provider-stability')[0]
$stateHook=@($manifest.hooks|Where-Object id -ceq 'codex-state-policy')[0]
$activateHook=@($manifest.hooks|Where-Object id -ceq 'serena-activate')[0]
$dashboardHook=@($manifest.hooks|Where-Object id -ceq 'serena-dashboard')[0]
Assert-True (($providerHook.quickHealthCheck.arguments -join ',') -ceq '-CheckOnly,-Json') 'provider quick check 必须只读'
Assert-True (($providerHook.fullAcceptanceCommand.arguments -join ',') -ceq '-Json,-CheckNetwork') 'provider full acceptance 必须保留 Task 8 的真实 network 验收；Task 7 另走只读 quick check'
Assert-True (($stateHook.quickHealthCheck.arguments -join ',') -ceq '--check-only,--json') 'state quick check 必须只读'
Assert-True (($stateHook.fullAcceptanceCommand.arguments -join ',') -ceq '--check-only,--json') 'state postcheck 必须只读'
Assert-True ($dashboardHook.quickHealthCheck.commandPath -ceq 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -and ($dashboardHook.quickHealthCheck.arguments -join ' ') -ceq "-NoProfile -Command Test-Path -LiteralPath 'D:\Codex\.codex\hooks\serena-dashboard-guard.cmd'") 'dashboard quick check 必须为固定 wrapper 存在性 static acceptance'
Assert-True (($dashboardHook.fullAcceptanceCommand.arguments -join ',') -ceq '-CheckOnly,-Json') 'dashboard acceptance 必须只读'
$expectedActivateFullAcceptance = @('-NoProfile','-File','D:\Codex\.codex\hooks\serena-behavior-guard.ps1','-Mode','ActivationAcceptance')
Assert-True (
    $activateHook.fullAcceptanceCommand.commandPath -ceq 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -and
    (@($activateHook.fullAcceptanceCommand.arguments) -join "`0") -ceq ($expectedActivateFullAcceptance -join "`0")
) 'activate full acceptance 必须走固定、无残留的受控验收模式'
foreach($hook in @($providerHook,$stateHook,$dashboardHook)){
    Assert-True (@($hook.writeResources|Where-Object{$_.kind -ceq 'abstract' -and $_.value -ceq 'hook-stdout'}).Count -eq 0) "$($hook.id) SessionStart 默认不得声明 stdout"
}
Assert-True (@($activateHook.writeResources|Where-Object{$_.kind -ceq 'abstract' -and $_.value -ceq 'hook-stdout'}).Count -eq 1) 'activate vendor SessionStart bytes 必须精确声明 stdout'
$stateHealthPaths=@($stateHook.writeResources|Where-Object kind -ceq path|ForEach-Object value)
Assert-True ($stateHealthPaths -ccontains 'D:\agents\run-evidence\codex-hook-health\codex-state-policy.json') 'state manifest health path 必须匹配 hook id'
foreach($hookFile in @('codex-provider-stability-guard.ps1','serena-dashboard-guard.ps1')){$source=[IO.File]::ReadAllText((Join-Path $projectRoot "managed\codex-hooks\hooks\$hookFile"));$match=[regex]::Match($source,"Write-CodexHookLatestHealth\s+-HookId\s+'([^']+)'");Assert-True $match.Success "$hookFile 必须调用 health writer";$id=$match.Groups[1].Value;$hook=$manifest.hooks|Where-Object id -CEQ $id;Assert-True ($null -ne $hook) "$hookFile health hookId 必须等于 manifest id";$expected="D:\agents\run-evidence\codex-hook-health\$id.json";$healthPaths=@($hook.writeResources|Where-Object kind -CEQ path|ForEach-Object value);Assert-True ($healthPaths -ccontains $expected) "$id writeResources 必须精确包含派生 health path"}
Assert-True (-not((Get-Content -Raw (Join-Path $projectRoot 'managed\codex-hooks\manifest.json')).Contains('codex-hook-health\\provider.json'))) '兼容 manifest 不得保留旧 provider.json alias'
'ok=True'
