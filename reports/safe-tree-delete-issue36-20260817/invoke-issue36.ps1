Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $evidenceHome '..\..')).Path
$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$suites = @(
    [pscustomobject]@{
        name = 'HashSafely'
        path = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteHashSafely.ps1'
        stdout = 'Test-CodexSafeTreeDeleteHashSafely.stdout.txt'
        stderr = 'Test-CodexSafeTreeDeleteHashSafely.stderr.txt'
    }
    [pscustomobject]@{
        name = 'LeafStreamSet'
        path = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteLeafStreamSet.ps1'
        stdout = 'Test-CodexSafeTreeDeleteLeafStreamSet.stdout.txt'
        stderr = 'Test-CodexSafeTreeDeleteLeafStreamSet.stderr.txt'
    }
    [pscustomobject]@{
        name = 'UncertainRecovery'
        path = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteUncertainRecovery.ps1'
        stdout = 'Test-CodexSafeTreeDeleteUncertainRecovery.stdout.txt'
        stderr = 'Test-CodexSafeTreeDeleteUncertainRecovery.stderr.txt'
    }
    [pscustomobject]@{
        name = 'CrashSafety'
        path = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteCrashSafety.ps1'
        stdout = 'Test-CodexSafeTreeDeleteCrashSafety.stdout.txt'
        stderr = 'Test-CodexSafeTreeDeleteCrashSafety.stderr.txt'
    }
    [pscustomobject]@{
        name = 'Phase1Integration'
        path = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeletePhase1Integration.ps1'
        stdout = 'Test-CodexSafeTreeDeletePhase1Integration.stdout.txt'
        stderr = 'Test-CodexSafeTreeDeletePhase1Integration.stderr.txt'
    }
)

function Invoke-Suite {
    param([Parameter(Mandatory)]$Suite)

    $stdoutPath = Join-Path $evidenceHome $Suite.stdout
    $stderrPath = Join-Path $evidenceHome $Suite.stderr
    $started = [datetimeoffset]::UtcNow
    $process = Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $Suite.path) `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $finished = [datetimeoffset]::UtcNow
    $code = [int]$process.ExitCode
    [Console]::Error.WriteLine(
        ("SUITE {0} exit={1} elapsedMs={2}" -f $Suite.name, $code, [int]($finished - $started).TotalMilliseconds))
    return [pscustomobject][ordered]@{
        name = [string]$Suite.name
        path = [string]$Suite.path
        exitCode = $code
        startedAtUtc = $started.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        elapsedMs = [long]($finished - $started).TotalMilliseconds
        stdout = $Suite.stdout
        stderr = $Suite.stderr
    }
}

$results = [Collections.Generic.List[object]]::new()
foreach ($suite in $suites) {
    $results.Add((Invoke-Suite -Suite $suite))
}

$meta = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue36-suite-meta'
    pwsh = $pwsh
    suites = @($results)
}
[IO.File]::WriteAllText(
    (Join-Path $evidenceHome 'suite-meta.json'),
    ($meta | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))

$failed = @($results | Where-Object { $_.exitCode -ne 0 })
if ($failed.Count -gt 0) {
    throw ('issue36 suites failed: ' + (($failed | ForEach-Object { $_.name + '=' + $_.exitCode }) -join ', '))
}
