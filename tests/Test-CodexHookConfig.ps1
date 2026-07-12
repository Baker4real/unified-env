Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexConfigFile.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Action,[string]$Pattern){try{&$Action;throw 'DID_NOT_THROW'}catch{if($_.Exception.Message -eq 'DID_NOT_THROW' -or $_.Exception.Message -notmatch $Pattern){throw "异常不匹配 [$Pattern]：$($_.Exception.Message)"}}}

$sections=[ordered]@{features=[ordered]@{unified_exec='true'};network=[ordered]@{enabled='true'}}
$input="[features]`n`nunified_exec = false`n`n[network]`nenabled = true`n"
$sw=[Diagnostics.Stopwatch]::StartNew();$output=Update-CodexTomlPolicyText -Text $input -Sections $sections;$sw.Stop();Assert-True ($sw.ElapsedMilliseconds -lt 1000) '空行 fixture 必须在1秒内返回';Assert-True ((Update-CodexTomlPolicyText -Text $output -Sections $sections) -ceq $output) 'TOML 必须幂等'
$commented="[features] # keep`r`n# comment`r`nunified_exec = false`r`nunknown = 7`r`n`r`n[mcp_servers.serena]`r`nargs = [`r`n  `"a`",`r`n  `"b`",`r`n]`r`n"
$changed=Set-CodexTomlSectionValue -Text $commented -Section 'mcp_servers.serena' -Key 'args' -Value '[ "x" ]' -ValueKind array
Assert-True ($changed.Contains("`r`n") -and $changed.Contains('# comment') -and $changed.Contains('unknown = 7')) 'CRLF、注释与未知键必须保留'
Assert-Throws { Set-CodexTomlSectionValue -Text "[features]`n[features]`n" -Section features -Key x -Value true } 'Duplicate TOML section'
Assert-Throws { Set-CodexTomlSectionValue -Text "[features]`nx=1`nx=2`n" -Section features -Key x -Value true } 'Duplicate TOML key'
Assert-Throws { Set-CodexTomlSectionValue -Text "[features]`nx = `"`"`"bad`"`"`"`n" -Section features -Key x -Value true } 'multiline'

$yaml="web_dashboard: false`nnested:`n  web_dashboard: false`n# keep`n"
$values=[ordered]@{web_dashboard='true';web_dashboard_open_on_launch='false'}
$yamlOut=Update-SerenaYamlPolicyText -Text $yaml -Values $values
Assert-True ($yamlOut -match '(?m)^web_dashboard: true$') '顶层键必须更新';Assert-True ($yamlOut -match '(?m)^  web_dashboard: false$') '嵌套同名键必须保留';Assert-True ($yamlOut.Contains('# keep')) 'YAML 注释必须保留';Assert-True ((Update-SerenaYamlPolicyText -Text $yamlOut -Values $values) -ceq $yamlOut) 'YAML 必须幂等'
Assert-Throws { Update-SerenaYamlPolicyText -Text "web_dashboard: false`nweb_dashboard: true`n" -Values $values } 'Duplicate YAML'

$fixture='D:\Codex\projects\统一环境\reports\codex-hook-config-test';if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force};[IO.Directory]::CreateDirectory($fixture)|Out-Null
$toml=Join-Path $fixture 'fixture.toml';[IO.File]::WriteAllText($toml,$output,[Text.UTF8Encoding]::new($false));$python='D:\Codex\tools\python314-official\python.exe';&$python -c 'import pathlib,sys,tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $toml;if($LASTEXITCODE -ne 0){throw 'Python tomllib 验证失败'}
$yamlPath=Join-Path $fixture 'fixture.yml';[IO.File]::WriteAllText($yamlPath,$yamlOut,[Text.UTF8Encoding]::new($false));$serenaPython='D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe';&$serenaPython -c 'import pathlib,sys,yaml; value=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)' $yamlPath;if($LASTEXITCODE -ne 0){throw 'PyYAML shape 验证失败'}

$astErrors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexConfigFile.ps1'),[ref]$tokens,[ref]$astErrors);Assert-True ($astErrors.Count -eq 0) 'config AST 必须合法'
$providerText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\codex-provider-stability-guard.ps1'))
$dashboardText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\serena-dashboard-guard.ps1'))
Assert-True (-not $providerText.Contains('$Watch') -and -not $providerText.Contains('Repair-CodexMobilePermissionDrift')) 'provider 不得保留 watcher 或 state/mobile 职责'
Assert-True ($providerText.Contains("Local\CodexConfigTomlGuard") -and $dashboardText.Contains("Local\CodexConfigTomlGuard")) '两者必须共享固定 TOML mutex'
Assert-True ($providerText.Contains('Update-CodexTomlPolicyText') -and $dashboardText.Contains('Update-CodexTomlPolicyText') -and $dashboardText.Contains('Update-SerenaYamlPolicyText')) 'hook 必须只声明 desired 并复用纯变换'
'ok=True'
