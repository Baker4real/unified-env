#Requires -Version 7.5
<#
.SYNOPSIS
Check vcpkg manager readiness, executable presence and bootstrap evidence without repairing it.
.DESCRIPTION
Fast reads manager list and manager log. Live additionally searches for zlib only after every Fast
check passes, then rechecks the executable. Prints one JSON report. Exit 0 is healthy, 1 is explicitly
unhealthy, and 3 means the CLI, IPC, JSON or required evidence cannot support a health judgment.
.PARAMETER UniGetCliPath
Optional uniget command or path. By default resolve uniget from PATH, then D:/UniGetUI/uniget.exe.
.PARAMETER ManagerListJsonPathForTest
Read manager-list JSON from this fixture instead of invoking the CLI.
.PARAMETER ManagerLogJsonPathForTest
Read manager-log JSON from this fixture instead of invoking the CLI.
.PARAMETER PackageSearchJsonPathForTest
Read package-search JSON from this fixture instead of invoking the CLI. Fast never reads it.
#>
[CmdletBinding()]
param(
    [ValidateSet('Fast','Live')][string]$Mode = 'Fast',
    [string]$UniGetCliPath,
    [string]$ManagerListJsonPathForTest,
    [string]$ManagerLogJsonPathForTest,
    [string]$PackageSearchJsonPathForTest
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

$result = [ordered]@{
    status = 'indeterminate'
    mode = $Mode
    manager = 'vcpkg'
    ready = $null
    executablePath = $null
    executableExists = $null
    bootstrap = [ordered]@{status='not_run';taskIndex=$null}
    packageSearch = [ordered]@{status='not_run';resultCount=$null;executableExistsAfter=$null}
}
function Complete-Check([string]$Status, [int]$ExitCode) {
    $result.status = $Status
    [pscustomobject]$result | ConvertTo-Json -Depth 6 -Compress
    exit $ExitCode
}
$uniGetCliSpecified = $PSBoundParameters.ContainsKey('UniGetCliPath')
$resolvedCli = $null
function Resolve-UniGetCli {
    if ($null -ne $script:resolvedCli) { return $script:resolvedCli }
    $command = $null
    if ($script:uniGetCliSpecified) {
        if (-not [string]::IsNullOrWhiteSpace($UniGetCliPath)) {
            if (Test-Path -LiteralPath $UniGetCliPath -PathType Leaf) {
                $script:resolvedCli = (Get-Item -LiteralPath $UniGetCliPath).FullName
                return $script:resolvedCli
            }
            $command = Get-Command -Name $UniGetCliPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    else {
        $command = Get-Command -Name 'uniget' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command -and (Test-Path -LiteralPath 'D:/UniGetUI/uniget.exe' -PathType Leaf)) {
            $script:resolvedCli = 'D:/UniGetUI/uniget.exe'
            return $script:resolvedCli
        }
    }
    if ($null -ne $command) { $script:resolvedCli = $command.Source }
    if ($null -eq $script:resolvedCli) { Complete-Check 'cli_missing' 3 }
    $script:resolvedCli
}
function Read-JsonInput(
    [string]$FixturePath,
    [bool]$FixtureProvided,
    [string[]]$Arguments,
    [string]$InvalidStatus
) {
    try {
        if ($FixtureProvided) {
            if ([string]::IsNullOrWhiteSpace($FixturePath)) { throw 'empty-fixture-path' }
            $text = [IO.File]::ReadAllText($FixturePath)
        }
        else {
            $cli = Resolve-UniGetCli
            $output = @(& $cli @Arguments 2>$null)
            if ($LASTEXITCODE -ne 0) { throw "uniget-exit-$LASTEXITCODE" }
            $text = $output -join "`n"
        }
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { Complete-Check $InvalidStatus 3 }
}
function Test-Executable([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop) }
    catch { return $false }
}

$managerPayload = Read-JsonInput -FixturePath $ManagerListJsonPathForTest -FixtureProvided ($PSBoundParameters.ContainsKey('ManagerListJsonPathForTest')) -Arguments @('manager','list') -InvalidStatus 'manager_list_invalid'
$managers = @($managerPayload.managers | Where-Object { $_.name -eq 'vcpkg' })
if ($managers.Count -eq 0) { Complete-Check 'manager_missing' 1 }
if ($managers.Count -ne 1) { Complete-Check 'manager_duplicate' 3 }
$manager = $managers[0]
if ($manager.ready -isnot [bool]) { Complete-Check 'manager_ready_invalid' 3 }
$result.ready = $manager.ready
if ($manager.executablePath -is [string]) { $result.executablePath = $manager.executablePath }
$result.executableExists = Test-Executable $result.executablePath

$logPayload = Read-JsonInput -FixturePath $ManagerLogJsonPathForTest -FixtureProvided ($PSBoundParameters.ContainsKey('ManagerLogJsonPathForTest')) -Arguments @('log','manager','--manager','vcpkg','--verbose') -InvalidStatus 'manager_log_invalid'
$tasks = if ($null -eq $logPayload.managers) { @() } else { @($logPayload.managers[0].tasks) }
$bootstrapIndexes = @(
    for ($index = 0; $index -lt $tasks.Count; $index++) {
        $lines = @($tasks[$index].lines)
        if ($lines.Count -gt 0 -and [string]$lines[0] -match 'RefreshIndexes' -and
            @($lines | Where-Object { [string]$_ -match '(?i)^\s*Command-line arguments:.*bootstrap-vcpkg\.bat' }).Count -gt 0) {
            $index
        }
    }
)
if ($bootstrapIndexes.Count -eq 0) {
    $result.bootstrap.status = 'not_recorded'
}
else {
    $bootstrapIndex = $bootstrapIndexes[-1]
    $result.bootstrap.taskIndex = $bootstrapIndex
    $success = @($tasks[$bootstrapIndex].lines | Where-Object { $_ -eq 'Return code: SUCCESS (0)' }).Count -gt 0
    $result.bootstrap.status = if ($success) { 'success' } else { 'failed' }
}

if (-not $result.ready) { Complete-Check 'ready_false' 1 }
if ([string]::IsNullOrWhiteSpace($result.executablePath)) { Complete-Check 'executable_path_missing' 1 }
if (-not $result.executableExists) { Complete-Check 'executable_missing' 1 }
if ($result.bootstrap.status -eq 'not_recorded') { Complete-Check 'bootstrap_not_recorded' 3 }
if ($result.bootstrap.status -ne 'success') { Complete-Check 'bootstrap_failed' 1 }
if ($Mode -eq 'Live') {
    $searchPayload = Read-JsonInput -FixturePath $PackageSearchJsonPathForTest -FixtureProvided ($PSBoundParameters.ContainsKey('PackageSearchJsonPathForTest')) -Arguments @('package','search','--manager','vcpkg','--query','zlib','--max-results','3') -InvalidStatus 'package_search_invalid'
    $packages = if ($null -eq $searchPayload.packages) { @() } else { @($searchPayload.packages | Where-Object { $null -ne $_ }) }
    $result.packageSearch.resultCount = $packages.Count
    $result.packageSearch.status = if ($searchPayload.status -ne 'success') { 'failed' } elseif ($packages.Count -eq 0) { 'empty' } else { 'success' }
    $result.packageSearch.executableExistsAfter = Test-Executable $result.executablePath
    if ($result.packageSearch.status -eq 'failed') { Complete-Check 'package_search_failed' 1 }
    if ($result.packageSearch.status -eq 'empty') { Complete-Check 'package_search_empty' 1 }
    if (-not $result.packageSearch.executableExistsAfter) { Complete-Check 'executable_missing_after_search' 1 }
}
Complete-Check 'healthy' 0
