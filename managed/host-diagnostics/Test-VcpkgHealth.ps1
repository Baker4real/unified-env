#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/vcpkg-health-tests')
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Get-VcpkgHealth.ps1'
$cases = [Collections.Generic.List[object]]::new()

function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $cases.Add([pscustomobject]@{name=$Name;passed=$true}) }
    catch { $cases.Add([pscustomobject]@{name=$Name;passed=$false;reason=$_.Exception.Message}) }
}
function Assert([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
function Write-Fixture([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 10 -Compress),$utf8)
}
function Invoke-Vcpkg([string[]]$Arguments, [hashtable]$Environment = @{}) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$entry) + $Arguments) { $psi.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $psi.Environment[$key] = $Environment[$key] }
    $child = [Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $child.StandardOutput.ReadToEndAsync()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(60000)) {
            $child.Kill($true)
            [void]$child.WaitForExit(5000)
            throw 'vcpkg-health-timeout'
        }
        [pscustomobject]@{
            exitCode = $child.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $child.Dispose() }
}
function Get-Report($Result) {
    Assert ([string]::IsNullOrWhiteSpace($Result.stderr)) ('unexpected-stderr: ' + $Result.stderr)
    $lines = @($Result.stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert ($lines.Count -eq 1) 'expected-exactly-one-json-line'
    $lines[0] | ConvertFrom-Json -ErrorAction Stop
}

$exePath = Join-Path $runRoot 'vcpkg.exe'
[IO.File]::WriteAllBytes($exePath,[byte[]](0x4D,0x5A))
$managerListPath = Join-Path $runRoot 'manager-list.json'
$managerLogPath = Join-Path $runRoot 'manager-log.json'
$packageSearchPath = Join-Path $runRoot 'package-search.json'
$managerList = [ordered]@{
    status = 'success'
    managers = @([ordered]@{name='vcpkg';ready=$true;executablePath=$exePath})
}
$managerLog = [ordered]@{
    status = 'success'
    managers = @([ordered]@{
        name = 'vcpkg'
        tasks = @([ordered]@{lines=@(
            'Logged subprocess-based task on manager vcpkg. Task type is RefreshIndexes',
            'Command-line arguments: "/C .\bootstrap-vcpkg.bat"',
            'Return code: SUCCESS (0)'
        )})
    })
}
Write-Fixture $managerListPath $managerList
Write-Fixture $managerLogPath $managerLog

Check 'fast-health-does-not-read-package-fixture' {
    $result = Invoke-Vcpkg @(
        '-ManagerListJsonPathForTest',$managerListPath,
        '-ManagerLogJsonPathForTest',$managerLogPath,
        '-PackageSearchJsonPathForTest',$packageSearchPath
    )
    $report = Get-Report $result
    Assert ($result.exitCode -eq 0 -and $report.status -eq 'healthy') 'fast-health-not-healthy'
    Assert ($report.mode -eq 'Fast' -and $report.manager -eq 'vcpkg' -and $report.ready -eq $true) 'fast-manager-contract'
    Assert ($report.executablePath -eq $exePath -and $report.executableExists -eq $true) 'fast-executable-contract'
    Assert ($report.bootstrap.status -eq 'success') 'fast-bootstrap-contract'
    Assert ($report.packageSearch.status -eq 'not_run') 'fast-read-package-fixture'
}

Write-Fixture $packageSearchPath ([ordered]@{status='success';packages=@(@{name='zlib'},@{name='zlib-ng'})})
$fakeCliPath = Join-Path $runRoot 'uniget.cmd'
$fakeCallsPath = Join-Path $runRoot 'cli-calls.txt'
$fakeEnvironment = @{
    VCPKG_TEST_MANAGER_LIST = $managerListPath
    VCPKG_TEST_MANAGER_LOG = $managerLogPath
    VCPKG_TEST_PACKAGE = $packageSearchPath
    VCPKG_TEST_CALLS = $fakeCallsPath
    VCPKG_TEST_EXE = $exePath
}
$fakeCli = @'
@echo off
setlocal
if "%*"=="manager list" (
    type "%VCPKG_TEST_MANAGER_LIST%"
    exit /b 0
)
if "%*"=="log manager --manager vcpkg --verbose" (
    type "%VCPKG_TEST_MANAGER_LOG%"
    exit /b 0
)
if "%*"=="package search --manager vcpkg --query zlib --max-results 3" (
    echo package>>"%VCPKG_TEST_CALLS%"
    type "%VCPKG_TEST_PACKAGE%"
    if /i "%VCPKG_TEST_DELETE_EXE%"=="1" del /q "%VCPKG_TEST_EXE%"
    exit /b 0
)
exit /b 17
'@
[IO.File]::WriteAllText($fakeCliPath,$fakeCli,[Text.Encoding]::ASCII)

Check 'live-default-cli-resolution-searches-and-rechecks-executable' {
    $environment = $fakeEnvironment.Clone()
    $environment.PATH = $runRoot + [IO.Path]::PathSeparator + $env:PATH
    $result = Invoke-Vcpkg -Arguments @('-Mode','Live') -Environment $environment
    $report = Get-Report $result
    Assert ($result.exitCode -eq 0 -and $report.status -eq 'healthy') 'live-health-not-healthy'
    Assert ($report.mode -eq 'Live' -and $report.packageSearch.status -eq 'success') 'live-search-contract'
    Assert ($report.packageSearch.resultCount -eq 2 -and $report.packageSearch.executableExistsAfter -eq $true) 'live-recheck-contract'
    Assert ((Test-Path -LiteralPath $fakeCallsPath -PathType Leaf) -and (Get-Content -LiteralPath $fakeCallsPath -Raw).Contains('package')) 'live-query-not-observed'
}

Check 'live-missing-executable-cannot-be-washed-green-by-package-success' {
    $missingExe = Join-Path $runRoot 'missing-vcpkg.exe'
    $calls = Join-Path $runRoot 'core-cli-calls.txt'
    $managerList.managers[0].executablePath = $missingExe
    Write-Fixture $managerListPath $managerList
    try {
        $environment = $fakeEnvironment.Clone()
        $environment.VCPKG_TEST_CALLS = $calls
        $result = Invoke-Vcpkg -Arguments @(
            '-Mode','Live','-UniGetCliPath',$fakeCliPath,
            '-ManagerListJsonPathForTest',$managerListPath,
            '-ManagerLogJsonPathForTest',$managerLogPath
        ) -Environment $environment
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'executable_missing') 'missing-executable-washed-green'
        Assert ($report.ready -eq $true -and $report.executableExists -eq $false) 'missing-executable-facts-wrong'
        Assert ($report.bootstrap.status -eq 'success' -and $report.packageSearch.status -eq 'not_run') 'prefailure-state-wrong'
        Assert (-not (Test-Path -LiteralPath $calls)) 'package-query-executed-after-prefailure'
    }
    finally {
        $managerList.managers[0].executablePath = $exePath
        Write-Fixture $managerListPath $managerList
    }
}

Check 'ready-false-does-not-hide-existing-executable' {
    $managerList.managers[0].ready = $false
    Write-Fixture $managerListPath $managerList
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath,'-PackageSearchJsonPathForTest',$packageSearchPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'ready_false') 'ready-false-status-wrong'
        Assert ($report.ready -eq $false -and $report.executableExists -eq $true) 'ready-short-circuited-executable-check'
    }
    finally {
        $managerList.managers[0].ready = $true
        Write-Fixture $managerListPath $managerList
    }
}

Check 'blank-executable-path-is-unhealthy' {
    $managerList.managers[0].executablePath = '   '
    Write-Fixture $managerListPath $managerList
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'executable_path_missing') 'blank-path-status-wrong'
        Assert ($report.ready -eq $true -and $report.executableExists -eq $false) 'blank-path-facts-wrong'
    }
    finally {
        $managerList.managers[0].executablePath = $exePath
        Write-Fixture $managerListPath $managerList
    }
}

Check 'directory-cannot-impersonate-executable' {
    $managerList.managers[0].executablePath = $runRoot
    Write-Fixture $managerListPath $managerList
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'executable_missing' -and $report.executableExists -eq $false) 'directory-accepted-as-executable'
    }
    finally {
        $managerList.managers[0].executablePath = $exePath
        Write-Fixture $managerListPath $managerList
    }
}

Check 'manager-missing-is-unhealthy' {
    $savedManagers = $managerList.managers
    $managerList.managers = @()
    Write-Fixture $managerListPath $managerList
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'manager_missing' -and $report.packageSearch.status -eq 'not_run') 'manager-missing-contract'
    }
    finally {
        $managerList.managers = $savedManagers
        Write-Fixture $managerListPath $managerList
    }
}

Check 'duplicate-manager-is-indeterminate' {
    $savedManagers = $managerList.managers
    $managerList.managers = @($savedManagers[0],$savedManagers[0])
    Write-Fixture $managerListPath $managerList
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 3 -and $report.status -eq 'manager_duplicate') 'duplicate-manager-contract'
    }
    finally {
        $managerList.managers = $savedManagers
        Write-Fixture $managerListPath $managerList
    }
}

Check 'ready-must-be-a-json-boolean' {
    $managerList.managers[0].ready = 'true'
    Write-Fixture $managerListPath $managerList
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 3 -and $report.status -eq 'manager_ready_invalid') 'string-ready-was-coerced'
    }
    finally {
        $managerList.managers[0].ready = $true
        Write-Fixture $managerListPath $managerList
    }
}

Check 'malformed-manager-json-is-indeterminate' {
    [IO.File]::WriteAllText($managerListPath,'{"managers":[',$utf8)
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 3 -and $report.status -eq 'manager_list_invalid') 'malformed-manager-json-contract'
    }
    finally { Write-Fixture $managerListPath $managerList }
}

Check 'malformed-log-json-is-indeterminate' {
    [IO.File]::WriteAllText($managerLogPath,'{"managers":[',$utf8)
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 3 -and $report.status -eq 'manager_log_invalid') 'malformed-log-json-contract'
    }
    finally { Write-Fixture $managerLogPath $managerLog }
}

Check 'missing-cli-is-indeterminate' {
    $result = Invoke-Vcpkg @('-UniGetCliPath',(Join-Path $runRoot 'absent-uniget.exe'))
    $report = Get-Report $result
    Assert ($result.exitCode -eq 3 -and $report.status -eq 'cli_missing') 'missing-cli-contract'
}

Check 'ordinary-refresh-and-bootstrap-mentions-are-not-bootstrap-evidence' {
    $savedTasks = $managerLog.managers[0].tasks
    $managerLog.managers[0].tasks = @(
        [ordered]@{lines=@('Logged subprocess-based task on manager vcpkg. Task type is RefreshIndexes','Return code: SUCCESS (0)')},
        [ordered]@{lines=@('bootstrap-vcpkg.bat was mentioned but not invoked','Return code: SUCCESS (0)')}
    )
    Write-Fixture $managerLogPath $managerLog
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 3 -and $report.status -eq 'bootstrap_not_recorded') 'missing-bootstrap-record-washed-green'
        Assert ($report.bootstrap.status -eq 'not_recorded') 'bootstrap-not-recorded-field'
    }
    finally {
        $managerLog.managers[0].tasks = $savedTasks
        Write-Fixture $managerLogPath $managerLog
    }
}

Check 'latest-explicit-bootstrap-record-controls-health' {
    $savedTasks = $managerLog.managers[0].tasks
    $managerLog.managers[0].tasks = @(
        [ordered]@{lines=@('Task type is RefreshIndexes','Command-line arguments: "/C .\bootstrap-vcpkg.bat"','Return code: SUCCESS (0)')},
        [ordered]@{lines=@('Task type is RefreshIndexes','Command-line arguments: "/C .\bootstrap-vcpkg.bat"','Return code: FAILED (1)')},
        [ordered]@{lines=@('Task type is RefreshIndexes','Return code: SUCCESS (0)')}
    )
    Write-Fixture $managerLogPath $managerLog
    try {
        $result = Invoke-Vcpkg @('-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'bootstrap_failed') 'latest-bootstrap-failure-hidden'
        Assert ($report.bootstrap.status -eq 'failed' -and $report.bootstrap.taskIndex -eq 1) 'wrong-bootstrap-record-selected'
    }
    finally {
        $managerLog.managers[0].tasks = $savedTasks
        Write-Fixture $managerLogPath $managerLog
    }
}

Check 'live-empty-package-result-is-unhealthy' {
    Write-Fixture $packageSearchPath ([ordered]@{status='success';packages=@()})
    try {
        $result = Invoke-Vcpkg @('-Mode','Live','-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath,'-PackageSearchJsonPathForTest',$packageSearchPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'package_search_empty') 'empty-search-washed-green'
        Assert ($report.packageSearch.status -eq 'empty' -and $report.packageSearch.resultCount -eq 0 -and $report.packageSearch.executableExistsAfter -eq $true) 'empty-search-fields'
    }
    finally { Write-Fixture $packageSearchPath ([ordered]@{status='success';packages=@(@{name='zlib'},@{name='zlib-ng'})}) }
}

Check 'live-null-package-list-does-not-count-as-a-result' {
    Write-Fixture $packageSearchPath ([ordered]@{status='success';packages=$null})
    try {
        $result = Invoke-Vcpkg @('-Mode','Live','-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath,'-PackageSearchJsonPathForTest',$packageSearchPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'package_search_empty' -and $report.packageSearch.resultCount -eq 0) 'null-package-list-counted'
    }
    finally { Write-Fixture $packageSearchPath ([ordered]@{status='success';packages=@(@{name='zlib'},@{name='zlib-ng'})}) }
}

Check 'live-explicit-package-failure-is-unhealthy' {
    Write-Fixture $packageSearchPath ([ordered]@{status='failed';packages=@()})
    try {
        $result = Invoke-Vcpkg @('-Mode','Live','-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath,'-PackageSearchJsonPathForTest',$packageSearchPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'package_search_failed') 'package-failure-washed-green'
        Assert ($report.packageSearch.status -eq 'failed' -and $report.packageSearch.executableExistsAfter -eq $true) 'package-failure-fields'
    }
    finally { Write-Fixture $packageSearchPath ([ordered]@{status='success';packages=@(@{name='zlib'},@{name='zlib-ng'})}) }
}

Check 'live-malformed-package-json-is-indeterminate' {
    [IO.File]::WriteAllText($packageSearchPath,'{"status":',$utf8)
    try {
        $result = Invoke-Vcpkg @('-Mode','Live','-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath,'-PackageSearchJsonPathForTest',$packageSearchPath)
        $report = Get-Report $result
        Assert ($result.exitCode -eq 3 -and $report.status -eq 'package_search_invalid') 'malformed-package-json-contract'
    }
    finally { Write-Fixture $packageSearchPath ([ordered]@{status='success';packages=@(@{name='zlib'},@{name='zlib-ng'})}) }
}

Check 'live-package-ipc-failure-is-indeterminate' {
    $failingCli = Join-Path $runRoot 'uniget-fail.cmd'
    [IO.File]::WriteAllText($failingCli,"@echo off`r`nexit /b 23`r`n",[Text.Encoding]::ASCII)
    $result = Invoke-Vcpkg @('-Mode','Live','-UniGetCliPath',$failingCli,'-ManagerListJsonPathForTest',$managerListPath,'-ManagerLogJsonPathForTest',$managerLogPath)
    $report = Get-Report $result
    Assert ($result.exitCode -eq 3 -and $report.status -eq 'package_search_invalid') 'package-ipc-failure-contract'
}

Check 'live-recheck-detects-executable-removed-by-query' {
    $environment = $fakeEnvironment.Clone()
    $environment.PATH = $runRoot + [IO.Path]::PathSeparator + $env:PATH
    $environment.VCPKG_TEST_DELETE_EXE = '1'
    $environment.VCPKG_TEST_CALLS = Join-Path $runRoot 'delete-cli-calls.txt'
    try {
        $result = Invoke-Vcpkg -Arguments @('-Mode','Live') -Environment $environment
        $report = Get-Report $result
        Assert ($result.exitCode -eq 1 -and $report.status -eq 'executable_missing_after_search') 'post-query-removal-missed'
        Assert ($report.executableExists -eq $true -and $report.packageSearch.status -eq 'success' -and $report.packageSearch.executableExistsAfter -eq $false) 'post-query-recheck-fields'
        Assert (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) 'fixture-delete-did-not-run'
    }
    finally { [IO.File]::WriteAllBytes($exePath,[byte[]](0x4D,0x5A)) }
}

$report = [pscustomobject]@{passed=(@($cases | Where-Object { -not $_.passed }).Count -eq 0);cases=@($cases);runRoot=$runRoot}
[IO.File]::WriteAllText((Join-Path $runRoot 'result.json'),($report | ConvertTo-Json -Depth 6),$utf8)
$report | ConvertTo-Json -Depth 6 -Compress
if (-not $report.passed) { exit 1 }
