#requires -Version 7.4
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repo = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $repo 'managed/host-diagnostics/Test-LoopbackProxy.ps1'
$utf8 = [Text.UTF8Encoding]::new($false)
$evidence = 'D:/agents/run-evidence/loopback-proxy-tests/' + [guid]::NewGuid().ToString('N')
$pathRoot = Join-Path $evidence 'path'
$null = New-Item -ItemType Directory -Path $pathRoot -Force
$fakeCurl = Join-Path $pathRoot 'curl.cmd'
[IO.File]::WriteAllText($fakeCurl, (@(
    '@echo off'
    '>"%~dp0curl-args.txt" echo %*'
    'if "%FAKE_CURL_MODE%"=="success" goto success'
    'if "%FAKE_CURL_MODE%"=="unexpected" goto unexpected'
    'if "%FAKE_CURL_MODE%"=="custom" goto custom'
    'goto connection-failed'
    ':success'
    '<nul set /p "=204"'
    'exit /b 0'
    ':unexpected'
    '<nul set /p "=200"'
    'exit /b 0'
    ':custom'
    '<nul set /p "=200"'
    'exit /b 0'
    ':connection-failed'
    '<nul set /p "=000"'
    'exit /b 7'
) -join "`r`n") + "`r`n", $utf8)
$searchPath = $pathRoot + [IO.Path]::PathSeparator + $env:PATH
$previousPath = $env:PATH
$env:PATH = $searchPath
try {
    $resolved = Get-Command curl -CommandType Application | Select-Object -First 1
    if ($resolved.Source -ne $fakeCurl) { throw "curl resolved to $($resolved.Source) instead of the fixture" }
} finally { $env:PATH = $previousPath }

function Invoke-ProxyEntry([string]$Mode, [string[]]$Arguments = @(), [switch]$RealCurl) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in (@('-NoProfile', '-NonInteractive', '-File', $entry) + $Arguments)) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.Environment['PATH'] = if ($RealCurl) { $previousPath } else { $searchPath }
    $psi.Environment['FAKE_CURL_MODE'] = $Mode
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'Loopback proxy entry timed out' }
    [pscustomobject]@{
        exitCode = $process.ExitCode
        stdout = $stdout.GetAwaiter().GetResult()
        stderr = $stderr.GetAwaiter().GetResult()
    }
}

# The fake curl performs no network I/O and needs no listener. A 204 is therefore sufficient by itself.
$success = Invoke-ProxyEntry 'success'
$successReport = $success.stdout | ConvertFrom-Json -ErrorAction Stop
if ($success.exitCode -ne 0 -or $successReport.exitCode -ne 0 -or $successReport.httpCode -ne 204 -or $successReport.status -ne 'available') { throw "A business HTTP 204 did not pass without a listener probe: $($success.stderr)" }
$curlArguments = [IO.File]::ReadAllText((Join-Path $pathRoot 'curl-args.txt')).Trim()
if (-not $curlArguments.Contains('--proxy http://127.0.0.1:17897') -or -not $curlArguments.Contains('--url https://www.google.com/generate_204')) { throw "Default proxy or URL was not used: $curlArguments" }

$connectionFailure = Invoke-ProxyEntry 'connection-failed'
$failureReport = $connectionFailure.stdout | ConvertFrom-Json -ErrorAction Stop
if ($connectionFailure.exitCode -ne 1 -or $failureReport.exitCode -ne 7 -or $failureReport.httpCode -ne 0 -or $failureReport.status -ne 'unavailable') { throw 'A curl connection failure was reported as available' }

$unexpected = Invoke-ProxyEntry 'unexpected'
$unexpectedReport = $unexpected.stdout | ConvertFrom-Json -ErrorAction Stop
if ($unexpected.exitCode -ne 1 -or $unexpectedReport.exitCode -ne 0 -or $unexpectedReport.httpCode -ne 200 -or $unexpectedReport.status -ne 'unavailable') { throw 'An unexpected business HTTP status was accepted' }

$custom = Invoke-ProxyEntry 'custom' @('-Proxy', 'http://127.0.0.1:12345', '-Url', 'https://example.test/health', '-ExpectedHttpCode', '200')
$customReport = $custom.stdout | ConvertFrom-Json -ErrorAction Stop
$customArguments = [IO.File]::ReadAllText((Join-Path $pathRoot 'curl-args.txt')).Trim()
if ($custom.exitCode -ne 0 -or $customReport.httpCode -ne 200 -or -not $customArguments.Contains('--proxy http://127.0.0.1:12345') -or -not $customArguments.Contains('--url https://example.test/health')) { throw 'Proxy, URL, or expected HTTP code was not parameterizable' }

$serverScript = Join-Path $evidence 'serve_204.py'
$portPath = Join-Path $evidence 'port.txt'
@'
import http.server
import pathlib
import sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port), encoding='ascii')
server.handle_request()
'@ | Set-Content -LiteralPath $serverScript -Encoding utf8
$python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$serverPsi = [Diagnostics.ProcessStartInfo]::new($python)
$serverPsi.ArgumentList.Add($serverScript)
$serverPsi.ArgumentList.Add($portPath)
$serverPsi.UseShellExecute = $false
$serverPsi.CreateNoWindow = $true
$server = [Diagnostics.Process]::Start($serverPsi)
try {
    $port = $null
    for ($i = 0; $i -lt 50 -and -not $port; $i++) {
        if (Test-Path -LiteralPath $portPath -PathType Leaf) { $port = [IO.File]::ReadAllText($portPath).Trim() }
        if (-not $port) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $port) { throw 'Local 204 fixture did not start' }
    $previousNoProxy = $env:NO_PROXY
    try {
        $env:NO_PROXY = '127.0.0.1'
        $bypass = Invoke-ProxyEntry 'unused' @('-Proxy','http://127.0.0.1:1','-Url',"http://127.0.0.1:$port/") -RealCurl
    } finally { $env:NO_PROXY = $previousNoProxy }
    $bypassReport = $bypass.stdout | ConvertFrom-Json -ErrorAction Stop
    if ($bypass.exitCode -ne 1 -or $bypassReport.status -ne 'unavailable') { throw 'NO_PROXY bypassed the explicitly required dead proxy' }
} finally {
    if (-not $server.HasExited) { $server.Kill($true) }
    $server.WaitForExit()
    $server.Dispose()
}
[ordered]@{ status = 'passed'; cases = 5; evidence = $evidence } | ConvertTo-Json -Compress
