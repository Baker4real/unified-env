Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimePath=Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
. $runtimePath
$manifestPath=Join-Path $projectRoot 'managed\codex-hooks\manifest.json'
$managedRoot=Split-Path -Parent $manifestPath
$manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json -Depth 100

function Assert-True([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Assert-Throws([scriptblock]$Action,[string]$Pattern){try{&$Action;throw 'DID_NOT_THROW'}catch{if($_.Exception.Message -eq 'DID_NOT_THROW' -or $_.Exception.Message -notmatch $Pattern){throw "异常不匹配 [$Pattern]：$($_.Exception.Message)"}}}
function Assert-Bytes([byte[]]$Actual,[byte[]]$Expected,[string]$Message){if(([Convert]::ToHexString($Actual)) -cne ([Convert]::ToHexString($Expected))){throw $Message}}

foreach ($name in @('Get-CodexHookSha256','Assert-CodexHookDPath','Invoke-CodexHookMutex','Write-CodexHookAtomicText','Invoke-CodexHookProcess','ConvertTo-CodexHookRedactedUri','Write-CodexHookLatestHealth')) { Assert-True ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) "缺少接口：$name" }

$forbiddenWrapperTokens=@('C:\Program Files\nodejs','python313-official','D:\hermes-data\.npm-global\python.exe')
$activeWrappers=@($manifest.files|Where-Object{$_.lifecycle -ceq 'active' -and $_.relativePath -like 'hooks/*.cmd'})
Assert-True ($activeWrappers.Count -eq 5) '必须验证全部 5 个 active cmd wrapper'
foreach($file in $activeWrappers){
    $wrapperPath=Join-Path $managedRoot $file.relativePath
    $text=Get-Content -Raw -LiteralPath $wrapperPath
    $owners=@($file.ownerHookIds|ForEach-Object{$id=$_;@($manifest.hooks|Where-Object{$_.id -ceq $id -and $_.lifecycle -ceq 'active'})})
    Assert-True ($owners.Count -eq 1) "active wrapper 必须有唯一 active owner：$($file.relativePath)"
    $owner=$owners[0];$expectedRuntime=[string]$manifest.runtimes.($owner.runtimeId)
    Assert-True ($text.Contains('"'+$expectedRuntime+'"')) "wrapper 必须只调用 manifest runtime：$($file.relativePath)"
    Assert-True ($text -match '(?m)%\*\s*$') "wrapper 必须保留 %*：$($file.relativePath)"
    Assert-True ($text -match '(?m)^exit /b %ERRORLEVEL%\s*$') "wrapper 必须透传退出码：$($file.relativePath)"
    foreach($token in $forbiddenWrapperTokens){Assert-True (-not $text.Contains($token)) "wrapper 禁止旧 runtime：$token"}
    Assert-True ($text -notmatch '(?im)(^|[\s\"])(python)(?:\.exe)?([\s\"]|$)') "wrapper 禁止裸 python：$($file.relativePath)"
}

$githubSource=Get-Content -Raw -LiteralPath (Join-Path $managedRoot 'hooks\codex-github-cli-guard.ps1')
Assert-True ([regex]::Matches($githubSource,'\.WaitOne\(1500\)').Count -eq 2) 'GitHub 两个 mutex 必须各使用 1500ms budget'
Assert-True (-not $githubSource.Contains('.WaitOne(5000)')) 'GitHub mutex 不得保留 5000ms budget'
Assert-True ($githubSource.Contains(". 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1'")) 'GitHub guard 必须加载 shared runtime'
Assert-True ($githubSource.Contains("Write-CodexHookLatestHealth -HookId 'github-cli'")) 'GitHub guard 必须写独立 latest health'
Assert-True ($githubSource.Contains('$GuardStopwatch.ElapsedMilliseconds')) 'GitHub health 必须记录真实 duration 而非常量'
Assert-True ([regex]::Matches($githubSource,"@\('auth', 'status'\)").Count -eq 1 -and $githubSource.Contains('$authProbe = if (-not $CheckAuth)')) 'GitHub quick 路径不得执行 auth/network probe'
$githubEntryPath=Join-Path $managedRoot 'hooks\lib\CodexGitHubCliGuardEntry.ps1'
Assert-True (Test-Path -LiteralPath $githubEntryPath -PathType Leaf) 'GitHub guard 必须使用可独立验证的 published internal entry state machine'
Assert-True ($githubSource.Contains(". 'D:\Codex\.codex\hooks\lib\CodexGitHubCliGuardEntry.ps1'") -and $githubSource.Contains('Invoke-CodexGitHubCliGuardEntry -Operation')) 'GitHub production guard 必须调用 fixed-path internal entry state machine'
$githubHarness=Join-Path $projectRoot 'tests\lib\Invoke-GitHubGuardEntryFixture.ps1'
Assert-True (Test-Path -LiteralPath $githubHarness -PathType Leaf) 'GitHub entry fixture harness 必须留在 tests/lib'
function Invoke-GitHubEntryFixture([string]$Case,[bool]$Json,[bool]$Strict){
    $args=@('-NoProfile','-File',$githubHarness,'-Case',$Case)
    if($Json){$args+='-Json'};if($Strict){$args+='-Strict'}
    Invoke-CodexHookProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -ArgumentList $args
}
$preFailure=Invoke-GitHubEntryFixture 'pre-payload' $true $false
Assert-True ($preFailure.exitCode -eq 0) '非 Strict JSON pre-payload failure 必须 fail-open'
$preJson=$preFailure.stdout|ConvertFrom-Json
Assert-True ($preJson.ok -eq $false -and $preJson.changed -eq $false -and $preJson.restartRequired -eq $false -and @($preJson.errors).Count -eq 1) 'pre-payload failure JSON 必须稳定且脱敏'
Assert-True (@($preFailure.stdout.Trim() -split "`r?`n").Count -eq 1) 'JSON failure stdout 必须严格一个对象'
$postFailure=Invoke-GitHubEntryFixture 'post-mutation' $true $false
$postJson=$postFailure.stdout|ConvertFrom-Json
Assert-True ($postJson.ok -eq $false -and $postJson.changed -eq $true -and $postJson.restartRequired -eq $true) 'post-mutation failure 必须保留真实 changed/restartRequired'
Assert-True (@($postJson.errors)[0] -ceq 'github-cli guard failed') 'post-mutation health 必须接收真实 state 且保留 generic guard error'
$healthFailure=Invoke-GitHubEntryFixture 'health-writer' $true $false
$healthJson=$healthFailure.stdout|ConvertFrom-Json
Assert-True ($healthFailure.exitCode -eq 0 -and $healthJson.ok -eq $false -and @($healthJson.errors)[0] -ceq 'health write failed') 'health writer failure 不得吞 JSON'
$strictFailure=Invoke-GitHubEntryFixture 'pre-payload' $true $true
Assert-True ($strictFailure.exitCode -ne 0 -and @($strictFailure.stdout.Trim() -split "`r?`n").Count -eq 1 -and ($strictFailure.stdout|ConvertFrom-Json).ok -eq $false) 'Strict failure 必须先输出一个失败 JSON 再非零退出'
$sessionFailure=Invoke-GitHubEntryFixture 'pre-payload' $false $false
Assert-True ($sessionFailure.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($sessionFailure.stdout)) '非 JSON SessionStart failure 必须 fail-open 且 stdout 不污染'
$successEntry=Invoke-GitHubEntryFixture 'success' $true $false
$successJson=$successEntry.stdout|ConvertFrom-Json
Assert-True ($successEntry.exitCode -eq 0 -and $successJson.ok -eq $true -and @($successJson.errors).Count -eq 0 -and @($successEntry.stdout.Trim() -split "`r?`n").Count -eq 1) 'JSON success stdout 必须严格一个对象且 errors 为稳定 array'

$runtimeSource=Get-Content -Raw -LiteralPath $runtimePath
$serenaSource=Get-Content -Raw -LiteralPath (Join-Path $managedRoot 'hooks\serena-activate-guarded.ps1')
Assert-True ($serenaSource.Contains("Write-CodexHookLatestHealth -HookId 'serena-activate'")) 'Serena activate 必须写独立 latest health'
Assert-True ($serenaSource.Contains('Assert-CodexSerenaSessionStartOutputBytes') -and $runtimeSource.Contains('function Assert-CodexSerenaSessionStartOutputBytes')) 'Serena activate 必须复用 shared strict SessionStart bytes validator'
Assert-True ($serenaSource.Contains('StandardOutput.BaseStream')) 'Serena activate 必须以 bytes 捕获 vendor stdout'
$serenaTokens=$null;$serenaErrors=$null;$serenaAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $managedRoot 'hooks\serena-activate-guarded.ps1'),[ref]$serenaTokens,[ref]$serenaErrors)
Assert-True ($serenaErrors.Count -eq 0 -and $null -eq $serenaAst.ParamBlock) 'Serena production CLI 不得暴露 public param table'
foreach($forbiddenCapability in @('AllowFixture','VendorPath','FixtureVendorScriptPath','RuntimePath','HealthRoot','codex-hook-serena-fixture','codex-hook-health-test')){Assert-True (-not $serenaSource.Contains($forbiddenCapability)) "Serena production CLI 不得包含 fixture/path override：$forbiddenCapability"}
Assert-Throws { Assert-CodexHookDPath 'C:\fixture\x' } '路径|D 盘'
Assert-True ((ConvertTo-CodexHookRedactedUri 'http://user:secret@example.com:8080/a?q=token#x') -ceq 'http://example.com:8080') 'URI 必须移除 user-info/path/query/fragment'

$fixtureRoot='D:\Codex\projects\统一环境\reports\codex-hook-runtime-test'
if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
[IO.Directory]::CreateDirectory($fixtureRoot)|Out-Null
$target=Join-Path $fixtureRoot 'config.toml';$backups=Join-Path $fixtureRoot 'backups';[IO.Directory]::CreateDirectory($backups)|Out-Null
[IO.File]::WriteAllText($target,"old=true`n",[Text.UTF8Encoding]::new($false));$old=[IO.File]::ReadAllBytes($target);$oldHash=Get-CodexHookSha256 $target
Assert-Throws { Write-CodexHookAtomicText -Path $target -Text 'bad' -Validator {throw 'invalid'} -BackupRoot $backups -ExpectedBeforeSha256 $oldHash } 'invalid'
Assert-Bytes ([IO.File]::ReadAllBytes($target)) $old 'validator 失败不得修改目标'
Assert-Throws { Write-CodexHookAtomicText -Path $target -Text 'new' -Validator {} -BackupRoot $backups -ExpectedBeforeSha256 ('0'*64) } '漂移'
Assert-Bytes ([IO.File]::ReadAllBytes($target)) $old '初始漂移不得修改目标'
$badBackup=Join-Path $fixtureRoot 'backup-is-file';[IO.File]::WriteAllText($badBackup,'x')
Assert-Throws { Write-CodexHookAtomicText -Path $target -Text 'new' -Validator {} -BackupRoot $badBackup -ExpectedBeforeSha256 $oldHash } '.'
Assert-Bytes ([IO.File]::ReadAllBytes($target)) $old '备份失败不得修改目标'
Assert-Throws { Write-CodexHookAtomicText -Path $target -Text 'new' -Validator {} -BackupRoot $backups -ExpectedBeforeSha256 $oldHash -TestBeforeReplace {throw 'replace injected'} } 'replace injected'
Assert-Bytes ([IO.File]::ReadAllBytes($target)) $old '替换失败不得修改目标'
$script:postValidatorCalls=0
Assert-Throws { Write-CodexHookAtomicText -Path $target -Text 'new' -Validator {param($p)$script:postValidatorCalls++;if($script:postValidatorCalls -eq 2){throw 'post-read invalid'}} -BackupRoot $backups -ExpectedBeforeSha256 $oldHash } 'post-read invalid'
Assert-Bytes ([IO.File]::ReadAllBytes($target)) $old 'post-read validator 失败必须从已验证 backup 恢复旧 bytes'
$script:blockedValidatorCalls=0
Assert-Throws { Write-CodexHookAtomicText -Path $target -Text 'new' -Validator {param($p)$script:blockedValidatorCalls++;if($script:blockedValidatorCalls -eq 2){throw 'post-read invalid'}} -BackupRoot $backups -ExpectedBeforeSha256 $oldHash -TestBeforeRollback {throw 'rollback injected'} } 'rollback-blocked'
[IO.File]::WriteAllBytes($target,$old)
$outside=Join-Path $fixtureRoot 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null;$junction=Join-Path $fixtureRoot 'junction'
try{$null=New-Item -ItemType Junction -Path $junction -Target $outside;Assert-Throws { Assert-CodexHookDPath (Join-Path $junction 'target.toml') -AllowMissingLeaf } 'reparse'}finally{if(Test-Path $junction){Remove-Item $junction -Force}}
$result=Write-CodexHookAtomicText -Path $target -Text "new=true`n" -Validator {param($p)if(-not(Get-Content -Raw $p)){throw 'empty'}} -BackupRoot $backups -ExpectedBeforeSha256 $oldHash
Assert-True $result.changed '首次写入应 changed'
Assert-True ((Get-CodexHookSha256 $result.backupPath) -ceq $oldHash) 'backup hash 必须等于旧 bytes'
$newHash=Get-CodexHookSha256 $target;$again=Write-CodexHookAtomicText -Path $target -Text "new=true`n" -Validator {} -BackupRoot $backups -ExpectedBeforeSha256 $newHash
Assert-True (-not $again.changed) '幂等写入 changed=false'

$marker=Join-Path $fixtureRoot 'mutex-ready.txt'
$holderCode='$m=[Threading.Mutex]::new($false,''Local\CodexRuntimeTestBusy'');[void]$m.WaitOne();[IO.File]::WriteAllText('''+$marker+''',''ready'');Start-Sleep -Seconds 3;[void]$m.ReleaseMutex();$m.Dispose()'
$holder=Start-Process -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -ArgumentList @('-NoProfile','-Command',$holderCode) -WindowStyle Hidden -PassThru
try{for($i=0;$i -lt 40 -and -not(Test-Path $marker);$i++){Start-Sleep -Milliseconds 50};Assert-True (Test-Path $marker) 'mutex holder 未就绪';Assert-Throws { Invoke-CodexHookMutex -Name 'Local\CodexRuntimeTestBusy' -ScriptBlock {} } '超时'}finally{if(-not $holder.HasExited){$holder.Kill($true)};$holder.Dispose()}
$abandonedMarker=Join-Path $fixtureRoot 'mutex-abandoned-ready.txt'
$abandonedCode='$m=[Threading.Mutex]::new($false,''Local\CodexRuntimeTestAbandoned'');[void]$m.WaitOne();[IO.File]::WriteAllText('''+$abandonedMarker+''',''ready'');exit 0'
$abandoner=Start-Process -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -ArgumentList @('-NoProfile','-Command',$abandonedCode) -WindowStyle Hidden -PassThru
try{for($i=0;$i -lt 40 -and -not(Test-Path $abandonedMarker);$i++){Start-Sleep -Milliseconds 50};Assert-True (Test-Path $abandonedMarker) 'abandoned holder 未就绪';$abandoner.WaitForExit();$taken=Invoke-CodexHookMutex -Name 'Local\CodexRuntimeTestAbandoned' -ScriptBlock {'taken'};Assert-True ($taken -ceq 'taken') 'abandoned mutex 必须被安全接管'}finally{if(-not $abandoner.HasExited){$abandoner.Kill($true)};$abandoner.Dispose()}
$process=Invoke-CodexHookProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("ok")')
Assert-True ($process.exitCode -eq 0 -and $process.stdout -ceq 'ok') 'process helper 必须捕获输出与退出码'

$serenaFixtureRoot='D:\Codex\projects\统一环境\reports\codex-hook-serena-fixture'
if(Test-Path -LiteralPath $serenaFixtureRoot){Remove-Item -LiteralPath $serenaFixtureRoot -Recurse -Force}
[IO.Directory]::CreateDirectory($serenaFixtureRoot)|Out-Null
$serenaFixtureScript=Join-Path $serenaFixtureRoot 'serena-hooks-fixture.ps1'
$fixtureSource=@'
$null=[Console]::In.ReadToEnd()
$valid="{`"hookSpecificOutput`":{`"hookEventName`":`"SessionStart`",`"additionalContext`":`"fixture context`"}}`r`n"
$output=switch($env:CODEX_SERENA_FIXTURE_MODE){'invalid'{'not-json'}'extra'{"${valid}EXTRA"}default{$valid}}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes($output)
[Console]::OpenStandardOutput().Write($bytes,0,$bytes.Length)
'@
[IO.File]::WriteAllText($serenaFixtureScript,$fixtureSource,[Text.UTF8Encoding]::new($false))
$serenaScript=Join-Path $projectRoot 'tests\lib\Invoke-SerenaActivateFixture.ps1'
$serenaHealthRoot='D:\Codex\projects\统一环境\reports\codex-hook-health-test'
function Invoke-SerenaActivateFixture([string]$Mode){
    if(Test-Path -LiteralPath $serenaHealthRoot){Remove-Item -LiteralPath $serenaHealthRoot -Recurse -Force}
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName='D:\Codex\tools\PowerShell\7.6.3\pwsh.exe';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-File',$serenaScript,'-VendorPath','D:\Codex\tools\PowerShell\7.6.3\pwsh.exe','-FixtureVendorScriptPath',$serenaFixtureScript,'-RuntimePath',$runtimePath,'-HealthRoot',$serenaHealthRoot,'-AllowFixture')){[void]$psi.ArgumentList.Add($arg)}
    $psi.Environment['CODEX_SERENA_FIXTURE_MODE']=$Mode
    $p=[Diagnostics.Process]::new();$p.StartInfo=$psi;$buffer=[IO.MemoryStream]::new()
    try{Assert-True $p.Start() 'Serena fixture process 必须启动';$copy=$p.StandardOutput.BaseStream.CopyToAsync($buffer);$stderrTask=$p.StandardError.ReadToEndAsync();$p.StandardInput.Write('{"session_id":"redacted-session"}');$p.StandardInput.Close();Assert-True ($p.WaitForExit(10000)) 'Serena fixture process 必须结束';$copy.GetAwaiter().GetResult();return [pscustomobject]@{exitCode=$p.ExitCode;stdout=[byte[]]$buffer.ToArray();stderr=$stderrTask.GetAwaiter().GetResult()}}finally{$buffer.Dispose();$p.Dispose()}
}
$validVendorBytes=[Text.UTF8Encoding]::new($false).GetBytes("{`"hookSpecificOutput`":{`"hookEventName`":`"SessionStart`",`"additionalContext`":`"fixture context`"}}`r`n")
$validActivate=@(Invoke-SerenaActivateFixture 'valid')[-1]
Assert-True ($validActivate.exitCode -eq 0) "合法 Serena activate fixture 必须成功：$($validActivate.stderr)"
Assert-Bytes $validActivate.stdout $validVendorBytes ("Serena activate 必须逐字节输出原 vendor JSON；actual={0}; expected={1}" -f [Convert]::ToHexString($validActivate.stdout),[Convert]::ToHexString($validVendorBytes))
$validHealth=Get-Content -Raw -LiteralPath (Join-Path $serenaHealthRoot 'serena-activate.json')|ConvertFrom-Json
Assert-True ($validHealth.ok -eq $true -and $validHealth.hookId -ceq 'serena-activate') 'Serena activate 合法输出后必须写独立成功 health'
foreach($mode in @('invalid','extra')){$failed=@(Invoke-SerenaActivateFixture $mode)[-1];Assert-True ($failed.exitCode -ne 0) "$mode vendor 输出必须 fail closed";Assert-True ($failed.stdout.Length -eq 0) "$mode vendor 输出不得污染 stdout";$failedHealth=Get-Content -Raw -LiteralPath (Join-Path $serenaHealthRoot 'serena-activate.json')|ConvertFrom-Json;Assert-True ($failedHealth.ok -eq $false) "$mode vendor 输出必须写脱敏失败 health"}
Remove-Item -LiteralPath $serenaFixtureRoot -Recurse -Force

$syntheticRoot='D:\Codex\projects\统一环境\reports\codex-hook-serena-synthetic'
if(Test-Path -LiteralPath $syntheticRoot){Remove-Item -LiteralPath $syntheticRoot -Recurse -Force}
[IO.Directory]::CreateDirectory($syntheticRoot)|Out-Null
$syntheticHome=Join-Path $syntheticRoot '.serena'
function Invoke-SerenaVendor([string[]]$Arguments,[string]$InputJson){
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=[string]$manifest.runtimes.serenaHooks;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.Environment['SERENA_HOME']=$syntheticHome
    foreach($arg in $Arguments){[void]$psi.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$psi
    try{$didStart=$p.Start();Assert-True $didStart 'Serena synthetic vendor 必须启动';$stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync();$p.StandardInput.Write($InputJson);$p.StandardInput.Close();Assert-True ($p.WaitForExit(10000)) 'Serena synthetic vendor 必须结束';return [pscustomobject]@{exitCode=$p.ExitCode;stdout=$stdoutTask.GetAwaiter().GetResult();stderr=$stderrTask.GetAwaiter().GetResult()}}finally{$p.Dispose()}
}
$syntheticSession='redacted-session'
$remindInput=[pscustomobject][ordered]@{session_id=$syntheticSession;tool_name='Bash';tool_input=[pscustomobject][ordered]@{command='rg -n hook file.ps1'}}|ConvertTo-Json -Compress -Depth 5
$remind1=@(Invoke-SerenaVendor @('remind','--client=codex') $remindInput)[-1]
$remind2=@(Invoke-SerenaVendor @('remind','--client=codex') $remindInput)[-1]
Assert-True ($remind1.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($remind1.stdout)) 'Serena remind 第一次不得 deny'
Assert-True ($remind2.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($remind2.stdout)) 'Serena remind 第二次不得 deny'
Assert-True (Test-Path -LiteralPath (Join-Path $syntheticHome "hook_data\$syntheticSession\tool_use_counter.pkl") -PathType Leaf) 'Serena remind 前两次必须在 fixture home 产生计数'
$remind3=@(Invoke-SerenaVendor @('remind','--client=codex') $remindInput)[-1]
Assert-True ($remind3.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($remind3.stdout)) 'Serena remind 第三次必须输出协议 JSON'
$remind3Json=$remind3.stdout|ConvertFrom-Json
Assert-True ($remind3Json.hookSpecificOutput.hookEventName -ceq 'PreToolUse') 'Serena remind 第三次必须输出合法 PreToolUse'
$activate=@(Invoke-SerenaVendor @('activate','--client=codex') ("{`"session_id`":`"$syntheticSession`"}"))[-1]
$activateJson=$activate.stdout|ConvertFrom-Json
Assert-True ($activate.exitCode -eq 0 -and $activateJson.hookSpecificOutput.hookEventName -ceq 'SessionStart' -and -not [string]::IsNullOrWhiteSpace($activateJson.hookSpecificOutput.additionalContext)) 'Serena vendor activate 必须输出合法 SessionStart additionalContext'
$cleanup=@(Invoke-SerenaVendor @('cleanup','--client=codex') ("{`"session_id`":`"$syntheticSession`"}"))[-1]
Assert-True ($cleanup.exitCode -eq 0 -and -not(Test-Path -LiteralPath (Join-Path $syntheticHome "hook_data\$syntheticSession"))) 'Serena vendor cleanup 必须清除 fixture session state'
Remove-Item -LiteralPath $syntheticRoot -Recurse -Force

$healthRoot=[IO.Path]::GetFullPath('D:\Codex\projects\统一环境\reports\codex-hook-health-test')
$reportsRoot=[IO.Path]::GetFullPath((Join-Path $projectRoot 'reports') + '\')
Assert-True ($healthRoot.StartsWith($reportsRoot,[StringComparison]::OrdinalIgnoreCase) -and $healthRoot -ieq (Join-Path $reportsRoot 'codex-hook-health-test')) 'health fixture 必须严格位于项目 reports 固定目录'
try{
    if(Test-Path $healthRoot){Remove-Item $healthRoot -Recurse -Force}
    [IO.Directory]::CreateDirectory($healthRoot)|Out-Null
    function New-Health([string]$Id){[pscustomobject][ordered]@{hookId=$Id;runId=[guid]::NewGuid().ToString('N');startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=1;ok=$true;changed=$false;restartRequired=$false;errors=[string[]]@()}}
    $badHealth=New-Health 'provider-stability';$badHealth|Add-Member extra $true;Assert-Throws { Write-CodexHookLatestHealthCore -HookId 'provider-stability' -Payload $badHealth -HealthRoot $healthRoot -AllowFixtureRoot } 'schema'
    foreach($invalidErrors in @('scalar',$null,1,[pscustomobject]@{bad=$true},[object[]]@('ok',1))){$invalid=New-Health 'provider-stability';$invalid.errors=$invalidErrors;Assert-Throws { Write-CodexHookLatestHealthCore -HookId 'provider-stability' -Payload $invalid -HealthRoot $healthRoot -AllowFixtureRoot } 'errors 类型'}
    $jobs=@();foreach($id in @('provider-stability','serena-activate','serena-dashboard','github-cli')){$jobs+=Start-Job -ScriptBlock {param($runtime,$root,$hookId). $runtime;$p=[pscustomobject][ordered]@{hookId=$hookId;runId=[guid]::NewGuid().ToString('N');startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=1;ok=$true;changed=$false;restartRequired=$false;errors=[string[]]@()};Write-CodexHookLatestHealthCore -HookId $hookId -Payload $p -HealthRoot $root -AllowFixtureRoot} -ArgumentList $runtimePath,$healthRoot,$id}
    try{$jobs|Wait-Job|Out-Null;$jobOutput=@($jobs|Receive-Job);Assert-True ($jobOutput.Count -eq 0) 'health writer 不得污染 stdout';foreach($job in $jobs){Assert-True ($job.State -ceq 'Completed') "health 并发 job 必须完成：$($job.State)"}}finally{$jobs|Remove-Job -Force}
    foreach($id in @('provider-stability','serena-activate','serena-dashboard','github-cli')){$path=Join-Path $healthRoot "$id.json";Assert-True (Test-Path $path) "health writer 必须隔离写入 $id.json";$doc=Get-Content -Raw $path|ConvertFrom-Json;Assert-True ($doc.hookId -ceq $id) 'health 文件不得交叉覆盖'}
    $single=New-Health 'provider-stability';$single.errors=[string[]]@('one');$healthOutput=@(Write-CodexHookLatestHealthCore -HookId 'provider-stability' -Payload $single -HealthRoot $healthRoot -AllowFixtureRoot);Assert-True ($healthOutput.Count -eq 0) 'single-error health 写入不得污染 stdout'
    foreach($id in @('provider-stability','serena-activate','serena-dashboard','github-cli')){$raw=Get-Content -Raw (Join-Path $healthRoot "$id.json");$json=[Text.Json.JsonDocument]::Parse($raw);try{Assert-True ($json.RootElement.GetProperty('errors').ValueKind -eq [Text.Json.JsonValueKind]::Array) 'health errors JSON token 必须稳定为 array'}finally{$json.Dispose()}}
    $astErrors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'),[ref]$tokens,[ref]$astErrors);Assert-True ($astErrors.Count -eq 0) 'runtime AST 必须合法'
}finally{
    if(Test-Path $healthRoot){Remove-Item $healthRoot -Recurse -Force}
}
Assert-True (-not(Test-Path $healthRoot)) 'health fixture 必须在测试结束时清理'
'ok=True'
