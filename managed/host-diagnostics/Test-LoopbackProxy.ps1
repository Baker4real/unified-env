#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Proxy = 'http://127.0.0.1:17897',
    [string]$Url = 'https://www.google.com/generate_204',
    [ValidateRange(100, 599)][int]$ExpectedHttpCode = 204
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$curlResult = $null
try {
    $curl = Get-Command curl -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $psi = [Diagnostics.ProcessStartInfo]::new($curl.Source)
    $arguments = @(
        '--disable',
        '--silent', '--show-error',
        '--output', 'NUL',
        '--write-out', '%{http_code}',
        '--connect-timeout', '5',
        '--max-time', '15',
        '--noproxy', '',
        '--proxy', $Proxy,
        '--url', $Url
    )
    foreach ($argument in $arguments) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit(20000)
        if ($timedOut) { $process.Kill($true) }
        $process.WaitForExit()
        $curlResult = [pscustomobject]@{
            exitCode = [int]$process.ExitCode
            stdout = $stdout.GetAwaiter().GetResult()
            stderr = $stderr.GetAwaiter().GetResult()
            timedOut = $timedOut
        }
    } finally {
        $process.Dispose()
    }
} catch {
    $curlResult = $null
}

$httpCode = $null
if ($null -ne $curlResult -and [string]$curlResult.stdout -match '^\s*(?<code>\d{3})\s*$') {
    $httpCode = [int]$Matches.code
}
$available = $null -ne $curlResult -and -not $curlResult.timedOut -and $curlResult.exitCode -eq 0 -and $httpCode -eq $ExpectedHttpCode
$report = [ordered]@{
    exitCode = if ($null -ne $curlResult) { $curlResult.exitCode } else { $null }
    httpCode = $httpCode
    status = if ($available) { 'available' } else { 'unavailable' }
}
[Console]::Out.WriteLine(($report | ConvertTo-Json -Compress))
if (-not $available) { exit 1 }
