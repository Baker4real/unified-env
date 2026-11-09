#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Command,
    [scriptblock]$MarkerReader,
    [string]$DeviceId = 'aeawutfrjia4s5i6',
    [string]$MarkerRoot = 'D:/Codex/.codex/tmp/uu-terminal-markers',
    [ValidateRange(1, 120)][int]$ProofTimeoutSeconds = 20,
    [ValidateRange(10, 5000)][int]$PollMilliseconds = 250,
    [string]$EvidenceRoot = 'D:/agents/run-evidence/uu-terminal',
    [string]$UuRoot = 'D:/Program Files/Netease/GameViewer/bin'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
if ($null -eq $MarkerReader) {
    [ordered]@{ status = 'blocked'; reason = 'marker-reader-required'; commandsSent = 0 } | ConvertTo-Json -Compress
    exit 1
}
$modulePath = Join-Path $PSScriptRoot 'RemoteOperations.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
$runId = [guid]::NewGuid().ToString('N')
$session = "uu-agent-$($runId.Substring(0, 8))"
$evidence = Join-Path $EvidenceRoot $runId
$null = New-Item -ItemType Directory -Path $evidence -Force
$uu = Join-Path $UuRoot 'uuyc-cli.exe'
$console = Join-Path $UuRoot 'OpenConsole.exe'
$psi = [Diagnostics.ProcessStartInfo]::new($console)
foreach ($argument in @('--headless', $uu, 'term', '-d', $DeviceId, 'new', $session, '--shell', 'cmd')) { $psi.ArgumentList.Add($argument) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardInputEncoding = $utf8
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$process = [Diagnostics.Process]::Start($psi)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$send = {
    param($WrappedCommand, $MarkerPath)
    if ($process.HasExited) { throw 'UU transport exited before the command was sent' }
    $process.StandardInput.WriteLine($WrappedCommand)
}
try {
    $sequence = Invoke-UuCommandSequence -Command $Command -RunId $runId -MarkerRoot $MarkerRoot -SendCommand $send -MarkerReader $MarkerReader -ProofTimeoutSeconds $ProofTimeoutSeconds -PollMilliseconds $PollMilliseconds
} finally {
    if (-not $process.HasExited) {
        try { $process.StandardInput.WriteLine('exit') } catch { }
        $process.StandardInput.Close()
    }
    if (-not $process.WaitForExit(15000)) {
        try { $process.Kill($true) } catch [InvalidOperationException] { }
    }
    $process.WaitForExit()
}
$localExitCode = $process.ExitCode
[IO.File]::WriteAllText((Join-Path $evidence 'transport.stdout.txt'), $stdoutTask.GetAwaiter().GetResult(), $utf8)
[IO.File]::WriteAllText((Join-Path $evidence 'transport.stderr.txt'), $stderrTask.GetAwaiter().GetResult(), $utf8)
& $uu term -d $DeviceId kill $session | Out-Null
$cleanupExitCode = $LASTEXITCODE
$complete = $sequence.status -eq 'executed' -and $localExitCode -eq 0 -and $cleanupExitCode -eq 0
[ordered]@{
    status = if ($complete) { 'executed' } else { 'incomplete' }
    runId = $runId
    session = $session
    completedCount = $sequence.completedCount
    commands = @($sequence.results)
    localExitCode = $localExitCode
    cleanupExitCode = $cleanupExitCode
    evidence = $evidence
} | ConvertTo-Json -Depth 6 -Compress
if (-not $complete) { exit 1 }
