Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path $projectRoot 'scripts\Run-PowerShellTests.cjs'
$source = Get-Content -LiteralPath $runnerPath -Raw

function Get-SpawnCall([string]$StartMarker) {
    $start = $source.IndexOf($StartMarker, [StringComparison]::Ordinal)
    Assert-True ($start -ge 0) "Missing spawn call: $StartMarker"
    $end = $source.IndexOf('});', $start, [StringComparison]::Ordinal)
    Assert-True ($end -gt $start) "Unterminated spawn call: $StartMarker"
    return $source.Substring($start, $end + 3 - $start)
}

$versionProbe = Get-SpawnCall 'spawnSync(POWERSHELL_EXECUTABLE'
$testLaunch = Get-SpawnCall 'spawnSync(powershellExecutable'
$hiddenOptionPattern = '(?m)^\s*windowsHide:\s*true,\s*$'

Assert-True ($versionProbe -match $hiddenOptionPattern) 'PowerShell version probe must hide its Windows console.'
Assert-True ($testLaunch -match $hiddenOptionPattern) 'PowerShell test launch must hide its Windows console.'

function Invoke-RunnerList {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & node $runnerPath @Arguments 2>&1
    return [pscustomobject]@{
        exitCode = $LASTEXITCODE
        lines = @($output | ForEach-Object { [string]$_ })
    }
}

$fullList = Invoke-RunnerList -Arguments @('--list', '--module', 'host-safety', '--profile', 'fixture')
Assert-True ($fullList.exitCode -eq 0) '--list must succeed for host-safety fixture'
Assert-True ($fullList.lines.Count -gt 10) 'fixture list must contain suites'

$onlyPurge = Invoke-RunnerList -Arguments @('--list', '--module', 'host-safety', '--profile', 'fixture', '--only', 'Purge')
Assert-True ($onlyPurge.exitCode -eq 0) '--only must succeed'
Assert-True ($onlyPurge.lines.Count -gt 0 -and $onlyPurge.lines.Count -lt $fullList.lines.Count) '--only must select a strict subset'
Assert-True (@($onlyPurge.lines | Where-Object { $_ -notmatch 'Purge' }).Count -eq 0) '--only labels must all match the regex'

$skipPurge = Invoke-RunnerList -Arguments @('--list', '--module', 'host-safety', '--profile', 'fixture', '--skip', 'Purge')
Assert-True ($skipPurge.exitCode -eq 0) '--skip must succeed'
Assert-True (@($skipPurge.lines | Where-Object { $_ -match 'Purge' }).Count -eq 0) '--skip labels must not match the regex'
Assert-True ($skipPurge.lines.Count -eq ($fullList.lines.Count - $onlyPurge.lines.Count)) '--skip and --only must partition the full list'

$noMatch = Invoke-RunnerList -Arguments @('--list', '--module', 'host-safety', '--profile', 'fixture', '--only', 'NoSuchSuite-Zzz')
Assert-True ($noMatch.exitCode -eq 1) 'an empty --only selection must fail instead of silently running nothing'
Assert-True (($noMatch.lines -join ' ') -match 'No tests selected') 'empty selection must explain the failure'

$badRegex = Invoke-RunnerList -Arguments @('--list', '--module', 'host-safety', '--profile', 'fixture', '--only', '[')
Assert-True ($badRegex.exitCode -eq 1) 'an invalid --only regex must fail'

'ok=True'
