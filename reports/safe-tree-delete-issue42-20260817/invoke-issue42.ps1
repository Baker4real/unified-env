[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testPath = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeletePhase3Integration.ps1'
$stdoutPath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeletePhase3Integration.stdout.txt'
$stderrPath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeletePhase3Integration.stderr.txt'
$metaPath = Join-Path $PSScriptRoot 'suite-meta.json'

[void][IO.Directory]::CreateDirectory($PSScriptRoot)

$startedAtUtc = [DateTime]::UtcNow.ToString('o')
$process = Start-Process -FilePath $pwsh -ArgumentList @(
    '-NoProfile',
    '-NonInteractive',
    '-File',
    $testPath
) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

$meta = [ordered]@{
    suite = 'Test-CodexSafeTreeDeletePhase3Integration.ps1'
    issue = 42
    pwsh = $pwsh
    testPath = $testPath
    startedAtUtc = $startedAtUtc
    finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    exitCode = [int]$process.ExitCode
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
}
[IO.File]::WriteAllText(
    $metaPath,
    ($meta | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))

exit $process.ExitCode
