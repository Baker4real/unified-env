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

$fixture='D:\Codex\projects\统一环境\reports\codex-hook-config-test';if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force};[IO.Directory]::CreateDirectory($fixture)|Out-Null
$toml=Join-Path $fixture 'fixture.toml';[IO.File]::WriteAllText($toml,$output,[Text.UTF8Encoding]::new($false));$python='D:\Codex\tools\python314-official\python.exe';&$python -c 'import pathlib,sys,tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $toml;if($LASTEXITCODE -ne 0){throw 'Python tomllib 验证失败'}
$yamlPath=Join-Path $fixture 'fixture.yml';[IO.File]::WriteAllText($yamlPath,$yamlOut,[Text.UTF8Encoding]::new($false));$serenaPython='D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe';&$serenaPython -c 'import pathlib,sys,yaml; value=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)' $yamlPath;if($LASTEXITCODE -ne 0){throw 'PyYAML shape 验证失败'}
foreach($tomlText in @($scalarArrayOut,$scalarTableOut)){[IO.File]::WriteAllText($toml,$tomlText,[Text.UTF8Encoding]::new($false));&$python -c 'import pathlib,sys,tomllib; value=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")); assert isinstance(value,dict)' $toml;if($LASTEXITCODE -ne 0){throw 'scalar replacement 后 tomllib 验证失败'}}
$badYaml=Join-Path $fixture 'malformed.yml';[IO.File]::WriteAllText($badYaml,"web_dashboard: [`n",[Text.UTF8Encoding]::new($false));&$serenaPython -c 'import pathlib,sys,yaml; yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $badYaml 2>$null;Assert-True ($LASTEXITCODE -ne 0) 'malformed YAML 必须被 PyYAML 拒绝'

$astErrors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexConfigFile.ps1'),[ref]$tokens,[ref]$astErrors);Assert-True ($astErrors.Count -eq 0) 'config AST 必须合法'
$providerText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\codex-provider-stability-guard.ps1'))
$dashboardText=[IO.File]::ReadAllText((Join-Path $projectRoot 'managed\codex-hooks\hooks\serena-dashboard-guard.ps1'))
Assert-True (-not $providerText.Contains('$Watch') -and -not $providerText.Contains('Repair-CodexMobilePermissionDrift')) 'provider 不得保留 watcher 或 state/mobile 职责'
Assert-True ($providerText.Contains("Local\CodexConfigTomlGuard") -and $dashboardText.Contains("Local\CodexConfigTomlGuard")) '两者必须共享固定 TOML mutex'
Assert-True ($providerText.Contains('Update-CodexTomlPolicyText') -and $dashboardText.Contains('Update-CodexTomlPolicyText') -and $dashboardText.Contains('Update-SerenaYamlPolicyText')) 'hook 必须只声明 desired 并复用纯变换'
$manifest=Get-Content -Raw (Join-Path $projectRoot 'managed\codex-hooks\manifest.json')|ConvertFrom-Json
foreach($hookFile in @('codex-provider-stability-guard.ps1','serena-dashboard-guard.ps1')){$source=[IO.File]::ReadAllText((Join-Path $projectRoot "managed\codex-hooks\hooks\$hookFile"));$match=[regex]::Match($source,"Write-CodexHookLatestHealth\s+-HookId\s+'([^']+)'");Assert-True $match.Success "$hookFile 必须调用 health writer";$id=$match.Groups[1].Value;$hook=$manifest.hooks|Where-Object id -CEQ $id;Assert-True ($null -ne $hook) "$hookFile health hookId 必须等于 manifest id";$expected="D:\Codex\.codex\run-evidence\codex-hook-health\$id.json";$healthPaths=@($hook.writeResources|Where-Object kind -CEQ path|ForEach-Object value);Assert-True ($healthPaths -ccontains $expected) "$id writeResources 必须精确包含派生 health path"}
Assert-True (-not((Get-Content -Raw (Join-Path $projectRoot 'managed\codex-hooks\manifest.json')).Contains('codex-hook-health\\provider.json'))) 'manifest 不得保留旧 provider.json alias'
'ok=True'
