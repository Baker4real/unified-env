#requires -Version 7.4
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'managed/host-diagnostics/RemoteOperations.psm1') -Force -ErrorAction Stop
# 脚本块里给普通变量赋值只会建局部变量；改哈希表的键，外层才看得到。
$probe = @{ sshCalled = $false }
$offline = Test-StudyLink -PingHandler { [pscustomobject]@{ success = $false; connectionType = 'unreachable' } } -SshHandler { $probe.sshCalled = $true; [pscustomobject]@{ success = $true } }
if ($offline.status -ne 'offline' -or $probe.sshCalled) { throw 'Offline ping did not prevent the SSH probe' }
$relay = Test-StudyLink -PingHandler { [pscustomobject]@{ success = $true; connectionType = 'relay' } } -SshHandler { [pscustomobject]@{ success = $true } }
if ($relay.status -ne 'online' -or $relay.connectionType -ne 'relay' -or -not $relay.sshSuccess) { throw 'Relay plus SSH success was not reported as online' }
$direct = Test-StudyLink -PingHandler { [pscustomobject]@{ success = $true; connectionType = 'direct' } } -SshHandler { [pscustomobject]@{ success = $false } }
if ($direct.status -ne 'ssh-failed' -or $direct.sshSuccess) { throw 'SSH failure was hidden by a successful ping' }

# 生产入口 Test-StudyLink.ps1：不传任何替身参数，只在外边界替身。PATH 最前面放转发到替身的
# tailscale.cmd 并先确认解析到它；同目录放 Invoke-RemoteStep.ps1 替身，免得真的连自习室。
$utf8 = [Text.UTF8Encoding]::new($false)
$evidence = 'D:/agents/run-evidence/study-link-tests/' + [guid]::NewGuid().ToString('N')
$fixture = Join-Path $evidence 'scripts'
$pathRoot = Join-Path $evidence 'path'
$null = New-Item -ItemType Directory -Path $fixture, $pathRoot -Force
foreach ($name in @('Test-StudyLink.ps1', 'RemoteOperations.psm1')) {
    Copy-Item -LiteralPath (Join-Path $repo "managed/host-diagnostics/$name") -Destination (Join-Path $fixture $name)
}
[IO.File]::WriteAllText((Join-Path $fixture 'Invoke-RemoteStep.ps1'), @'
param([string]$Target, [string]$ScriptPath, [int]$TimeoutSeconds)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'step-called.txt'), $Target)
exit ([int]$env:FAKE_STEP_EXIT_CODE)
'@, $utf8)
$fakeTailscale = Join-Path $pathRoot 'tailscale.cmd'
[IO.File]::WriteAllText($fakeTailscale, (@(
    '@echo off'
    '>"%~dp0tailscale-args.txt" echo %*'
    'if "%FAKE_TAILSCALE_MODE%"=="offline" goto offline'
    'if "%FAKE_TAILSCALE_MODE%"=="relay" goto relay'
    'echo pong from zi-xi-shi (192.0.2.10) via 192.0.2.10:41641 in 7ms'
    'exit /b 0'
    ':relay'
    'echo pong from zi-xi-shi (192.0.2.10) via DERP(fixture) in 30ms'
    'exit /b 0'
    ':offline'
    'echo no reply'
    'exit /b 1'
) -join "`r`n") + "`r`n", $utf8)
$searchPath = $pathRoot + [IO.Path]::PathSeparator + $env:PATH
$previousPath = $env:PATH
$env:PATH = $searchPath
try {
    $resolved = Get-Command tailscale -CommandType Application | Select-Object -First 1
    if ($resolved.Source -ne $fakeTailscale) { throw "tailscale resolved to $($resolved.Source) instead of the fixture" }
} finally { $env:PATH = $previousPath }

function Invoke-StudyLinkEntry([string]$Mode, [int]$StepExitCode) {
    $stepMarker = Join-Path $fixture 'step-called.txt'
    if (Test-Path -LiteralPath $stepMarker) { [IO.File]::WriteAllText($stepMarker, '') }
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $fixture 'Test-StudyLink.ps1'), '-EvidenceRoot', (Join-Path $evidence 'runs'))) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.Environment['PATH'] = $searchPath
    $psi.Environment['FAKE_TAILSCALE_MODE'] = $Mode
    $psi.Environment['FAKE_STEP_EXIT_CODE'] = [string]$StepExitCode
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'Study link entry timed out' }
    $text = $stdout.GetAwaiter().GetResult()
    $stepCalled = (Test-Path -LiteralPath $stepMarker) -and [IO.File]::ReadAllText($stepMarker) -eq 'study'
    return [pscustomobject]@{ exitCode = $process.ExitCode; report = ($text | ConvertFrom-Json); stderr = $stderr.GetAwaiter().GetResult(); stepCalled = $stepCalled }
}

$entryOffline = Invoke-StudyLinkEntry 'offline' 0
if ($entryOffline.exitCode -ne 1 -or $entryOffline.report.status -ne 'offline' -or $entryOffline.stepCalled) { throw "Entry did not stop after a failed ping: $($entryOffline.stderr)" }
$pingArguments = [IO.File]::ReadAllText((Join-Path $pathRoot 'tailscale-args.txt')).Trim()
if ($pingArguments -ne 'ping --c 1 --timeout 3s zi-xi-shi') { throw "Entry pinged with unexpected arguments: $pingArguments" }
$entryRelay = Invoke-StudyLinkEntry 'relay' 0
if ($entryRelay.exitCode -ne 0 -or $entryRelay.report.status -ne 'online' -or $entryRelay.report.connectionType -ne 'relay' -or -not $entryRelay.stepCalled) { throw "Entry did not report a relay link as online: $($entryRelay.stderr)" }
$entryDirect = Invoke-StudyLinkEntry 'direct' 1
if ($entryDirect.exitCode -ne 1 -or $entryDirect.report.status -ne 'ssh-failed' -or $entryDirect.report.connectionType -ne 'direct') { throw "Entry hid an SSH failure: $($entryDirect.stderr)" }
[ordered]@{ status = 'passed'; cases = 6; evidence = $evidence } | ConvertTo-Json -Compress
