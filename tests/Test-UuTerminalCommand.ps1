#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$repo = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repo 'managed/host-diagnostics/RemoteOperations.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
$runId = 'test-run'
$markerRoot = 'D:/Codex/.codex/tmp/uu-terminal-markers'

$sent = [System.Collections.Generic.List[string]]::new()
$send = { param($WrappedCommand, $MarkerPath) $sent.Add($WrappedCommand) }
$proved = { param($MarkerPath, $ExpectedHash, $RunId, $Index) $true }
$success = Invoke-UuCommandSequence -Command @('hostname', 'whoami') -RunId $runId -MarkerRoot $markerRoot -SendCommand $send -MarkerReader $proved -ProofTimeoutSeconds 1 -PollMilliseconds 10
if ($success.status -ne 'executed' -or $success.completedCount -ne 2 -or $sent.Count -ne 2) { throw 'Two proved commands did not execute sequentially' }
if ($success.results[0].markerPath -eq $success.results[1].markerPath) { throw 'Command markers are not unique' }

$sent.Clear()
$blocked = Invoke-UuCommandSequence -Command @('hostname', 'whoami') -RunId $runId -MarkerRoot $markerRoot -SendCommand $send -MarkerReader { $false } -ProofTimeoutSeconds 1 -PollMilliseconds 10
if ($blocked.status -ne 'blocked' -or $blocked.completedCount -ne 0 -or $sent.Count -ne 1) { throw 'Missing marker allowed the second command to run' }

$sent.Clear()
$sendFailure = Invoke-UuCommandSequence -Command @('hostname', 'whoami') -RunId $runId -MarkerRoot $markerRoot -SendCommand { throw 'synthetic-send-failure' } -MarkerReader $proved -ProofTimeoutSeconds 1 -PollMilliseconds 10
if ($sendFailure.status -ne 'blocked' -or $sendFailure.completedCount -ne 0 -or $sent.Count -ne 0) { throw 'Transport failure was not contained' }

# 信封在真实 cmd.exe 里逐行执行（UU 终端同样逐行喂给 cmd）：成功的命令留下 marker，失败的命令不留。
# 路径写法与线上默认 MarkerRoot 一样用正斜杠。
$evidence = 'D:/agents/run-evidence/uu-terminal-tests/' + [guid]::NewGuid().ToString('N')
$null = New-Item -ItemType Directory -Path $evidence -Force
$localRoot = "$evidence/markers"
$passing = New-UuCommandEnvelope -Command 'ver >nul' -RunId 'local-run' -Index 0 -MarkerRoot $localRoot
$failing = New-UuCommandEnvelope -Command ('type "' + (Join-Path $evidence 'missing.txt') + '"') -RunId 'local-run' -Index 1 -MarkerRoot $localRoot
$shell = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/cmd.exe'))
foreach ($argument in @('/d', '/q')) { $shell.ArgumentList.Add($argument) }
$shell.UseShellExecute = $false
$shell.CreateNoWindow = $true
$shell.RedirectStandardInput = $true
$shell.RedirectStandardOutput = $true
$shell.RedirectStandardError = $true
$cmd = [Diagnostics.Process]::Start($shell)
$cmdOut = $cmd.StandardOutput.ReadToEndAsync()
$cmdErr = $cmd.StandardError.ReadToEndAsync()
foreach ($line in @($passing.wrappedCommand, $failing.wrappedCommand, 'exit')) { $cmd.StandardInput.WriteLine($line) }
$cmd.StandardInput.Close()
if (-not $cmd.WaitForExit(15000)) { $cmd.Kill($true); throw 'Local cmd envelope test timed out' }
$null = $cmdOut.GetAwaiter().GetResult(), $cmdErr.GetAwaiter().GetResult()
if (-not (Test-Path -LiteralPath $passing.markerPath -PathType Leaf)) { throw 'A successful command did not leave its marker' }
$written = Get-Content -LiteralPath $passing.markerPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($written.runId -ne 'local-run' -or $written.index -ne 0 -or $written.commandSha256 -ne $passing.commandSha256) { throw 'The marker written by cmd does not match its envelope' }
if ((Test-Path -LiteralPath $failing.markerPath) -or (Test-Path -LiteralPath "$($failing.markerPath).tmp")) { throw 'A failing command still left a marker' }

$entry = Join-Path $repo 'managed/host-diagnostics/Invoke-UuTerminalCommand.ps1'
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $entry, '-Command', 'hostname')) { $psi.ArgumentList.Add($argument) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$process = [Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'UU CLI test timed out' }
if ($process.ExitCode -eq 0) { throw 'UU CLI started without a marker reader' }
[ordered]@{ status = 'passed'; cases = 6; evidence = $evidence } | ConvertTo-Json -Compress
