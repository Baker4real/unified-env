Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimePath=Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
. $runtimePath

function Assert-True([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Assert-Throws([scriptblock]$Action,[string]$Pattern){try{&$Action;throw 'DID_NOT_THROW'}catch{if($_.Exception.Message -eq 'DID_NOT_THROW' -or $_.Exception.Message -notmatch $Pattern){throw "异常不匹配 [$Pattern]：$($_.Exception.Message)"}}}
function Assert-Bytes([byte[]]$Actual,[byte[]]$Expected,[string]$Message){if(([Convert]::ToHexString($Actual)) -cne ([Convert]::ToHexString($Expected))){throw $Message}}

foreach ($name in @('Get-CodexHookSha256','Assert-CodexHookDPath','Invoke-CodexHookMutex','Write-CodexHookAtomicText','Invoke-CodexHookProcess','ConvertTo-CodexHookRedactedUri','Write-CodexHookLatestHealth')) { Assert-True ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) "缺少接口：$name" }
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

$healthRoot='D:\Codex\projects\统一环境\reports\codex-hook-health-test';if(Test-Path $healthRoot){Remove-Item $healthRoot -Recurse -Force};[IO.Directory]::CreateDirectory($healthRoot)|Out-Null
function New-Health([string]$Id){[pscustomobject][ordered]@{hookId=$Id;runId=[guid]::NewGuid().ToString('N');startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=1;ok=$true;changed=$false;restartRequired=$false;errors=[string[]]@()}}
$badHealth=New-Health 'provider-stability';$badHealth|Add-Member extra $true;Assert-Throws { Write-CodexHookLatestHealthCore -HookId 'provider-stability' -Payload $badHealth -HealthRoot $healthRoot -AllowFixtureRoot } 'schema'
$jobs=@();foreach($id in @('provider-stability','serena-dashboard')){$jobs+=Start-Job -ScriptBlock {param($runtime,$root,$hookId). $runtime;$p=[pscustomobject][ordered]@{hookId=$hookId;runId=[guid]::NewGuid().ToString('N');startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=1;ok=$true;changed=$false;restartRequired=$false;errors=[string[]]@()};Write-CodexHookLatestHealthCore -HookId $hookId -Payload $p -HealthRoot $root -AllowFixtureRoot} -ArgumentList $runtimePath,$healthRoot,$id}
try{$jobs|Wait-Job|Out-Null;$jobOutput=@($jobs|Receive-Job);Assert-True ($jobOutput.Count -eq 0) 'health writer 不得污染 stdout';foreach($job in $jobs){Assert-True ($job.State -ceq 'Completed') "health 并发 job 必须完成：$($job.State)"}}finally{$jobs|Remove-Job -Force}
foreach($id in @('provider-stability','serena-dashboard')){$path=Join-Path $healthRoot "$id.json";Assert-True (Test-Path $path) "health writer 必须隔离写入 $id.json";$doc=Get-Content -Raw $path|ConvertFrom-Json;Assert-True ($doc.hookId -ceq $id) 'health 文件不得交叉覆盖'}

$astErrors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'),[ref]$tokens,[ref]$astErrors);Assert-True ($astErrors.Count -eq 0) 'runtime AST 必须合法'
'ok=True'
