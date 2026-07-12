Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1')

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
$process=Invoke-CodexHookProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("ok")')
Assert-True ($process.exitCode -eq 0 -and $process.stdout -ceq 'ok') 'process helper 必须捕获输出与退出码'

$astErrors=$null;$tokens=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'),[ref]$tokens,[ref]$astErrors);Assert-True ($astErrors.Count -eq 0) 'runtime AST 必须合法'
'ok=True'
