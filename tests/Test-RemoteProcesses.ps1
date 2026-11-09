#requires -Version 7.4
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'managed/host-diagnostics/RemoteOperations.psm1') -Force -ErrorAction Stop
$process = [pscustomobject]@{ ProcessId = 424242; ExecutablePath = 'D:\Tools\example.exe' }
$provider = { $process }
$vanishedLookup = { $null }
$vanishedStopper = { throw 'process already exited' }
$stopped = Stop-ProcessByPath -ProcessName 'example.exe' -ExpectedPath 'D:/Tools/example.exe' -ProcessProvider $provider -ProcessStopper $vanishedStopper -ProcessLookup $vanishedLookup
if ($stopped.Count -ne 1 -or $stopped[0] -ne 424242) { throw 'Normalized path and vanished process were not handled' }
$stillAliveStopper = { throw 'synthetic stop failure' }
$aliveLookup = { $process }
$failed = $false
try {
    Stop-ProcessByPath -ProcessName 'example.exe' -ExpectedPath 'D:/Tools/example.exe' -ProcessProvider $provider -ProcessStopper $stillAliveStopper -ProcessLookup $aliveLookup
} catch { $failed = $true }
if (-not $failed) { throw 'A process that remained alive after a stop failure was ignored' }
$mismatchFailed = $false
try {
    Stop-ProcessByPath -ProcessName 'example.exe' -ExpectedPath 'D:/Other/example.exe' -ProcessProvider $provider -ProcessStopper { } -ProcessLookup $vanishedLookup
} catch { $mismatchFailed = $true }
if (-not $mismatchFailed) { throw 'Unexpected executable path was accepted' }

# 不传任何脚本块，走真实的进程枚举与停止。cmd.exe 复制成独一无二的映像名，按名字停止碰不到别的进程。
$evidence = 'D:/agents/run-evidence/remote-process-tests/' + [guid]::NewGuid().ToString('N')
$imageName = 'stop-fixture-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.exe'
$imageA = Join-Path $evidence "a/$imageName"
$imageB = Join-Path $evidence "b/$imageName"
foreach ($image in @($imageA, $imageB)) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $image) -Force
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/cmd.exe') -Destination $image
}
function Start-Fixture([string]$Image) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Image)
    foreach ($argument in @('/d', '/q')) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    [Diagnostics.Process]::Start($psi)
}
$started = [Collections.Generic.List[Diagnostics.Process]]::new()
try {
    $a = Start-Fixture $imageA; $started.Add($a)
    $b = Start-Fixture $imageB; $started.Add($b)
    $refused = $false
    try { $null = Stop-ProcessByPath -ProcessName $imageName -ExpectedPath $imageA } catch { $refused = $_.Exception.Message -match 'Unexpected process path' }
    if (-not $refused) { throw 'A same-named process at another path was not refused' }
    if ($a.HasExited -or $b.HasExited) { throw 'A process was stopped before every path was verified' }
    $b.Kill(); $b.WaitForExit()
    $stoppedIds = @(Stop-ProcessByPath -ProcessName $imageName -ExpectedPath $imageA)
    if ($stoppedIds.Count -ne 1 -or $stoppedIds[0] -ne $a.Id) { throw "Unexpected stopped process ids: $($stoppedIds -join ',')" }
    if (-not $a.WaitForExit(10000)) { throw 'The verified process survived Stop-ProcessByPath' }
} finally {
    foreach ($process in $started) {
        if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(5000) }
        $process.Dispose()
    }
}
[ordered]@{ status = 'passed'; cases = 5; evidence = $evidence } | ConvertTo-Json -Compress
