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

'ok=True'
