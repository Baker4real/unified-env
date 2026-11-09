#requires -Version 7.4
# Invoke-RemoteStep 从自身目录解析 Invoke-OfficeRemote.ps1：把入口复制进夹具目录，旁边放一个
# 按真 helper 合同行事的替身（stdout 打印一行摘要，同时写 .out.txt/.err.txt/.run.json）。
# 依赖线上 helper 的断言检查在 host-live 的 tests/Test-OfficeRemoteContract.ps1。
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'managed/host-diagnostics/Invoke-RemoteStep.ps1'
$evidence = 'D:/agents/run-evidence/remote-step-tests/' + [guid]::NewGuid().ToString('N')
$fixture = Join-Path $evidence 'scripts'
$null = New-Item -ItemType Directory -Path $fixture -Force
$entry = Join-Path $fixture 'Invoke-RemoteStep.ps1'
Copy-Item -LiteralPath $source -Destination $entry
@'
param(
    [string]$Target,
    [string]$ScriptPath,
    [string]$OutputPath,
    [string]$StdinScript,
    [int]$TimeoutSeconds = 300,
    [switch]$RequireRemoteContext,
    [switch]$DryRun
)
$utf8 = [Text.UTF8Encoding]::new($false)
$mode = if ($env:FAKE_REMOTE_MODE) { $env:FAKE_REMOTE_MODE } else { 'ok' }
if ($mode -eq 'refused') {
    [ordered]@{ result = 'refused'; reason = 'remote-context-assertion-missing'; detail = 'fixture' } | ConvertTo-Json -Compress
    exit 2
}
# 与真 helper 相同的命名：-OutputPath 本身是 stdout 文件，<名> 去掉扩展名和末尾 .out。
$scriptFull = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
if ($OutputPath) {
    $outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($outPath), [IO.Path]::GetFileNameWithoutExtension($outPath))
    if ($base.EndsWith('.out')) { $base = $base.Substring(0, $base.Length - 4) }
} else {
    $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($scriptFull), [IO.Path]::GetFileNameWithoutExtension($scriptFull))
    $outPath = "$base.out.txt"
}
$null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outPath)) -Force
$exitCode = if ($env:FAKE_REMOTE_EXIT_CODE) { [int]$env:FAKE_REMOTE_EXIT_CODE } else { 0 }
$stdout = if ($env:FAKE_REMOTE_STDOUT) { $env:FAKE_REMOTE_STDOUT } else { [ordered]@{ hostname = 'fixture-remote'; requireRemoteContext = $RequireRemoteContext.IsPresent } | ConvertTo-Json -Compress }
[IO.File]::WriteAllText($outPath, $stdout, $utf8)
[IO.File]::WriteAllText("$base.err.txt", '', $utf8)
$reported = if ($env:FAKE_REMOTE_TARGET) { $env:FAKE_REMOTE_TARGET } else { $Target }
$line = [ordered]@{ result = $mode; target = $reported; exitCode = $exitCode; stdout = $outPath; stderr = "$base.err.txt" } | ConvertTo-Json -Compress
[IO.File]::WriteAllText("$base.run.json", $line + "`n", $utf8)
$line
exit $exitCode
'@ | Set-Content -LiteralPath (Join-Path $fixture 'Invoke-OfficeRemote.ps1') -Encoding utf8

function Invoke-Step([string]$Entry, [string[]]$Extra = @(), [hashtable]$Environment = @{}) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Entry, '-Target', 'study') + $Extra) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($name in @('FAKE_REMOTE_MODE', 'FAKE_REMOTE_EXIT_CODE', 'FAKE_REMOTE_STDOUT', 'FAKE_REMOTE_TARGET')) { [void]$psi.Environment.Remove($name) }
    foreach ($key in $Environment.Keys) { $psi.Environment[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Remote step test timed out' }
    $text = $stdout.GetAwaiter().GetResult()
    $summary = $null
    try { $summary = $text | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $text; stderr = $stderr.GetAwaiter().GetResult(); summary = $summary }
}

function Invoke-DirectPayload([string]$ScriptPath, [string]$Marker) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath)) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($Marker) { $psi.Environment['CODEX_REMOTE_EXECUTION_TARGET'] = $Marker } else { [void]$psi.Environment.Remove('CODEX_REMOTE_EXECUTION_TARGET') }
    $process = [Diagnostics.Process]::Start($psi)
    if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Direct payload test timed out' }
    return $process.ExitCode
}

$remoteScript = Join-Path $evidence 'Noop.ps1'
'1' | Set-Content -LiteralPath $remoteScript -Encoding utf8
$cases = 0

$businessFailure = Invoke-Step $entry @('-ScriptPath', $remoteScript) @{ FAKE_REMOTE_MODE = 'failed'; FAKE_REMOTE_EXIT_CODE = 0 }
if ($businessFailure.exitCode -eq 0) { throw 'Business failure with process exit 0 was accepted' }
$cases++
$nativeFailure = Invoke-Step $entry @('-ScriptPath', $remoteScript) @{ FAKE_REMOTE_MODE = 'failed'; FAKE_REMOTE_EXIT_CODE = 1 }
if ($nativeFailure.exitCode -eq 0) { throw 'Native remote failure was accepted' }
$cases++
$success = Invoke-Step $entry @('-ScriptPath', $remoteScript)
if ($success.exitCode -ne 0) { throw "Successful step was rejected: $($success.stderr)" }
if ($success.summary.status -ne 'ok' -or $success.summary.target -ne 'study' -or $success.summary.exitCode -ne 0) { throw 'Success summary is incomplete' }
$cases++
$mismatch = Invoke-Step $entry @('-ScriptPath', $remoteScript) @{ FAKE_REMOTE_TARGET = 'office' }
if ($mismatch.exitCode -eq 0) { throw 'A run reported for another target was accepted' }
$cases++

# 上一次成功留下的 .run.json 不能顶替这一次连接前的拒绝。
$staleScript = Join-Path $evidence 'Stale.ps1'
'1' | Set-Content -LiteralPath $staleScript -Encoding utf8
[IO.File]::WriteAllText((Join-Path $evidence 'Stale.run.json'), '{"result":"ok","target":"study","exitCode":0}', $utf8)
$refused = Invoke-Step $entry @('-ScriptPath', $staleScript) @{ FAKE_REMOTE_MODE = 'refused' }
if ($refused.exitCode -eq 0 -or $refused.summary.status -ne 'refused' -or $refused.summary.reason -ne 'remote-context-assertion-missing') { throw "A helper refusal was hidden by a stale run file: $($refused.stdout)" }
$cases++

# -OutputPath 用 .log 等任意扩展名时，输出路径来自 helper 的摘要，而不是由本入口推算。
$logPath = Join-Path $evidence 'custom/result.log'
$custom = Invoke-Step $entry @('-ScriptPath', $remoteScript, '-OutputPath', $logPath, '-IncludeOutput')
if ($custom.exitCode -ne 0 -or [IO.Path]::GetFullPath($custom.summary.outputPath) -ne [IO.Path]::GetFullPath($logPath) -or ($custom.summary.output | ConvertFrom-Json).hostname -ne 'fixture-remote') { throw "Custom output path was not honoured: $($custom.stdout) $($custom.stderr)" }
$cases++

$bounded = Invoke-Step $entry @('-ScriptPath', $remoteScript, '-IncludeOutput', '-MaxOutputChars', '8') @{ FAKE_REMOTE_STDOUT = ('x' * 20) }
if ($bounded.exitCode -ne 0 -or $bounded.summary.output.Length -ne 8 -or -not $bounded.summary.outputTruncated) { throw 'Remote output was not bounded' }
$cases++
$write = Invoke-Step $entry @('-ScriptPath', $remoteScript, '-WriteOperation', '-IncludeOutput')
if (-not ($write.summary.output | ConvertFrom-Json).requireRemoteContext) { throw 'WriteOperation did not reach the remote helper' }
$cases++

# 仓库源码目录里没有 helper：入口必须报缺失，不能落到别处的线上 helper。
$missing = Invoke-Step $source @('-ScriptPath', $remoteScript)
if ($missing.exitCode -eq 0 -or $missing.stderr -notmatch 'Invoke-OfficeRemote\.ps1 is missing') { throw "A missing sibling helper was not reported: $($missing.stderr)" }
$cases++

$directWrite = Join-Path $evidence 'direct-write.txt'
$guardedScript = Join-Path $evidence 'Guarded.ps1'
$guard = "if (`$env:CODEX_REMOTE_EXECUTION_TARGET -ne 'study') { throw 'Remote execution context required: study' }"
[IO.File]::WriteAllText($guardedScript, "$guard`n[IO.File]::WriteAllText('$directWrite', 'proof')`n", $utf8)
$directExit = Invoke-DirectPayload $guardedScript ''
if ($directExit -eq 0 -or (Test-Path -LiteralPath $directWrite)) { throw 'Direct local execution reached the payload write' }
$cases++
$remoteMarkerExit = Invoke-DirectPayload $guardedScript 'study'
if ($remoteMarkerExit -ne 0 -or -not (Test-Path -LiteralPath $directWrite)) { throw 'Marked payload did not execute' }
$cases++
[ordered]@{ status = 'passed'; evidence = $evidence; cases = $cases } | ConvertTo-Json -Compress
