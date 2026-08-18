[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path (Join-Path $evidenceHome '..\..')).Path
$pwshPath = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$testPath = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeletePurgeBatch.ps1'
$stdoutPath = Join-Path $evidenceHome 'Test-CodexSafeTreeDeletePurgeBatch.stdout.txt'
$stderrPath = Join-Path $evidenceHome 'Test-CodexSafeTreeDeletePurgeBatch.stderr.txt'
$metaPath = Join-Path $evidenceHome 'suite-meta.json'

[void][IO.Directory]::CreateDirectory($evidenceHome)
$started = [datetimeoffset]::UtcNow
$process = Start-Process -FilePath $pwshPath -ArgumentList @(
    '-NoProfile',
    '-NonInteractive',
    '-File',
    $testPath
) -WorkingDirectory $projectRoot -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath
$ended = [datetimeoffset]::UtcNow
if ($null -eq $process.ExitCode) {
    throw 'issue37 test process did not report ExitCode.'
}
$meta = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue37-suite-meta'
    suite = 'Test-CodexSafeTreeDeletePurgeBatch.ps1'
    pwsh = $pwshPath
    startedAtUtc = $started.ToString('o')
    endedAtUtc = $ended.ToString('o')
    elapsedMs = [long]($ended - $started).TotalMilliseconds
    exitCode = [int]$process.ExitCode
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
}
[IO.File]::WriteAllText(
    $metaPath,
    ($meta | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))
exit $process.ExitCode
