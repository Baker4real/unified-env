[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $projectRoot 'scripts\Run-PowerShellTests.cjs'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$outDir = Join-Path $evidenceHome 'regressions'
[void][IO.Directory]::CreateDirectory($outDir)

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Document)
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

Set-Location -LiteralPath $projectRoot
$fixtureNames = @(& node $runner --module host-safety --list)
if ($LASTEXITCODE -ne 0) { throw "list fixture tests failed: $LASTEXITCODE" }

$tests = [Collections.Generic.List[string]]::new()
foreach ($line in $fixtureNames) {
    $name = ([string]$line).Trim()
    if ($name.Length -eq 0) { continue }
    if ($name -notlike 'Test-*.ps1') { continue }
    $tests.Add($name)
}
if ($tests.Count -lt 20) {
    throw "expected ~27 host-safety fixture tests, got $($tests.Count)"
}

$results = [Collections.Generic.List[object]]::new()
foreach ($name in $tests) {
    $started = [datetimeoffset]::UtcNow
    $stdoutPath = Join-Path $outDir ($name + '.stdout.txt')
    $stderrPath = Join-Path $outDir ($name + '.stderr.txt')
    Write-Output ("REGRESS start {0} utc={1}" -f $name, $started.ToString('o'))
    $proc = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', (Join-Path $projectRoot "tests\$name")
    ) -WorkingDirectory $projectRoot -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $ended = [datetimeoffset]::UtcNow
    $exit = [int]$proc.ExitCode
    $waiver = ($name -ceq 'Test-CodexSafeTreeDeleteFileSystem.ps1')
    $row = [pscustomobject][ordered]@{
        name = $name
        exitCode = $exit
        ok = ($exit -eq 0)
        waiver = $waiver
        unexpectedFailure = ($exit -ne 0 -and -not $waiver)
        startedUtc = $started.ToString('o')
        endedUtc = $ended.ToString('o')
        elapsedMs = [long]($ended - $started).TotalMilliseconds
    }
    $results.Add($row)
    Write-JsonFile -Path (Join-Path $evidenceHome 'regression-partial.json') -Document ([pscustomobject]@{
        writtenUtc = $ended.ToString('o')
        results = @($results)
    })
    Write-Output ("REGRESS done {0} exit={1} ms={2}" -f $name, $exit, $row.elapsedMs)
}

$smokeStarted = [datetimeoffset]::UtcNow
$smokeOut = Join-Path $outDir 'Test-CodexSafeTreeDeleteProductionSmoke.stdout.txt'
$smokeErr = Join-Path $outDir 'Test-CodexSafeTreeDeleteProductionSmoke.stderr.txt'
Write-Output ("REGRESS start ProductionSmoke utc={0}" -f $smokeStarted.ToString('o'))
$smokeProc = Start-Process -FilePath $pwsh -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteProductionSmoke.ps1')
) -WorkingDirectory $projectRoot -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr
$smokeEnded = [datetimeoffset]::UtcNow
$results.Add([pscustomobject][ordered]@{
    name = 'Test-CodexSafeTreeDeleteProductionSmoke.ps1'
    profile = 'host-live'
    exitCode = [int]$smokeProc.ExitCode
    ok = ([int]$smokeProc.ExitCode -eq 0)
    waiver = $false
    unexpectedFailure = ([int]$smokeProc.ExitCode -ne 0)
    startedUtc = $smokeStarted.ToString('o')
    endedUtc = $smokeEnded.ToString('o')
    elapsedMs = [long]($smokeEnded - $smokeStarted).TotalMilliseconds
})

$unexpected = @($results | Where-Object { [bool]$_.unexpectedFailure })
$meta = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue42-regression'
    utc = [datetimeoffset]::UtcNow.ToString('o')
    fixtureCount = @($results | Where-Object { [string]$_.name -ne 'Test-CodexSafeTreeDeleteProductionSmoke.ps1' }).Count
    unexpectedFailures = @($unexpected | ForEach-Object { $_.name })
    allOkOrWaived = ($unexpected.Count -eq 0)
    results = @($results)
}
Write-JsonFile -Path (Join-Path $evidenceHome 'regression-meta.json') -Document $meta
Write-Output ("REGRESS summary unexpected={0} allOkOrWaived={1}" -f $unexpected.Count, $meta.allOkOrWaived)
if ($unexpected.Count -gt 0) { exit 1 }
