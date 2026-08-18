[CmdletBinding()]
param(
    [switch]$SmokeOnly,
    [switch]$SkipBenchmark
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testPath = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteParallelismBenchmark.ps1'
$stdoutPath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeleteParallelismBenchmark.stdout.txt'
$stderrPath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeleteParallelismBenchmark.stderr.txt'
$metaPath = Join-Path $PSScriptRoot 'suite-meta.json'

[void][IO.Directory]::CreateDirectory($PSScriptRoot)

$argumentList = @(
    '-NoProfile',
    '-NonInteractive',
    '-File',
    $testPath
)
if ($SmokeOnly) { $argumentList += '-SmokeOnly' }
if ($SkipBenchmark) { $argumentList += '-SkipBenchmark' }

$startedAtUtc = [DateTime]::UtcNow.ToString('o')
$process = Start-Process -FilePath $pwsh -ArgumentList $argumentList -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
$code = [int]$process.ExitCode
if ($null -eq $code) { $code = 1 }

$meta = [ordered]@{
    suite = 'Test-CodexSafeTreeDeleteParallelismBenchmark.ps1'
    issue = 40
    pwsh = $pwsh
    testPath = $testPath
    smokeOnly = [bool]$SmokeOnly
    skipBenchmark = [bool]$SkipBenchmark
    startedAtUtc = $startedAtUtc
    finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    exitCode = $code
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
}
[IO.File]::WriteAllText(
    $metaPath,
    ($meta | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))

exit $code
