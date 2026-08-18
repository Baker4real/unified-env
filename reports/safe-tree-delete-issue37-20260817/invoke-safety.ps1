[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path (Join-Path $evidenceHome '..\..')).Path
$pwshPath = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$tests = @(
    'Test-CodexSafeTreeDeleteCrashSafety.ps1',
    'Test-CodexSafeTreeDeleteUncertainRecovery.ps1',
    'Test-CodexSafeTreeDeleteLeafStreamSet.ps1'
)
$results = [Collections.Generic.List[object]]::new()
foreach ($name in $tests) {
    $stdoutPath = Join-Path $evidenceHome ($name -replace '\.ps1$', '.stdout.txt')
    $stderrPath = Join-Path $evidenceHome ($name -replace '\.ps1$', '.stderr.txt')
    $started = [datetimeoffset]::UtcNow
    $process = Start-Process -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-NonInteractive',
        '-File',
        (Join-Path $projectRoot ('tests\' + $name))
    ) -WorkingDirectory $projectRoot -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $ended = [datetimeoffset]::UtcNow
    if ($null -eq $process.ExitCode) {
        throw ($name + ' did not report ExitCode.')
    }
    $results.Add([pscustomobject][ordered]@{
        suite = $name
        exitCode = [int]$process.ExitCode
        elapsedMs = [long]($ended - $started).TotalMilliseconds
        startedAtUtc = $started.ToString('o')
        endedAtUtc = $ended.ToString('o')
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
    })
    if ($process.ExitCode -ne 0) {
        [IO.File]::WriteAllText(
            (Join-Path $evidenceHome 'safety-meta.json'),
            ([pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-issue37-safety-meta'
                results = @($results)
            } | ConvertTo-Json -Depth 6),
            [Text.UTF8Encoding]::new($false))
        exit $process.ExitCode
    }
}
[IO.File]::WriteAllText(
    (Join-Path $evidenceHome 'safety-meta.json'),
    ([pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue37-safety-meta'
        results = @($results)
    } | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))
exit 0
