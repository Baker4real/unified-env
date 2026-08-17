[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testPath = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteThreadJournal.ps1'
$stdoutPath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeleteThreadJournal.stdout.txt'
$stderrPath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeleteThreadJournal.stderr.txt'
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
    suite = 'Test-CodexSafeTreeDeleteThreadJournal.ps1'
    issue = 38
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
