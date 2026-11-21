#Requires -Version 7.5
[CmdletBinding()]
param([ValidateSet('Projection','QueryFailure')][string]$ProcessFixture)

$ErrorActionPreference = 'Stop'
$diagnostics = Join-Path (Split-Path -Parent $PSScriptRoot) 'managed/host-diagnostics'
$desktopDiagnostic = Join-Path $diagnostics 'antigravity/Test-AntigravityDesktop.ps1'
$fixtureToken = 'synthetic-only-prefix--type=credential-fragment-fixture-tail'
$fixtureValue = 'synthetic-environment-value--fixture-tail'

if ($ProcessFixture) {
    $appPath = 'D:\Apps\Google.Antigravity\Antigravity.exe'
    $cmdPath = Join-Path $env:SystemRoot 'System32/cmd.exe'
    $created = [datetime]::new(2026, 1, 1, 0, 0, 1, [DateTimeKind]::Utc)
    $argsById = @{
        4101 = ''
        4102 = ' --type=renderer --csrf_token=' + $fixtureToken
        4103 = ' "--import" preload.mjs --csrf_token=' + $fixtureToken
        4104 = ' --csrf_token=' + $fixtureToken + ' --metadata="value --type=not-a-switch" --type-renderer'
        4105 = ' --updated'
        4106 = ' --updated --import preload.mjs'
    }
    function Get-CimInstance {
        [CmdletBinding()]
        param($ClassName, $Filter, $Property)
        if ($ProcessFixture -eq 'QueryFailure') {
            Write-Warning $fixtureToken
            Write-Information $fixtureValue
            throw $fixtureToken
        }
        if ($Filter -eq "ProcessId = 4200 AND Name = 'cmd.exe'") {
            return [pscustomobject]@{
                ProcessId=4200; SessionId=7; ExecutablePath=$cmdPath; CreationDate=$created.AddSeconds(-1)
                CommandLine=('"{0}" /d /s /c ""D:\Fixture with spaces\node.cmd" {1}"' -f $cmdPath, $fixtureToken)
            }
        }
        foreach ($number in 4101..4106) {
            [pscustomobject]@{
                ProcessId=$number; ParentProcessId=$(if ($number -eq 4103) { 4200 } else { 4000 })
                ExecutablePath=$appPath; SessionId=7; CreationDate=$created
                CommandLine=('"{0}"{1}' -f $appPath, $argsById[$number])
                Environment=@{FIXTURE_SECRET=$fixtureValue}
            }
        }
    }
    function Get-Process($Id) {
        [pscustomobject]@{Id=$Id; SessionId=7; Path=$appPath; StartTime=$created; MainWindowHandle=100; HasExited=$false}
    }
    & $desktopDiagnostic -ProcessSnapshot
    return
}

function Invoke-ProcessSnapshotFixture([string]$Fixture) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-ProcessFixture', $Fixture)) {
        $start.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($start)
    try {
        $out = $child.StandardOutput.ReadToEndAsync()
        $err = $child.StandardError.ReadToEndAsync()
        $child.WaitForExit()
        $stdout = $out.GetAwaiter().GetResult()
        $stderr = $err.GetAwaiter().GetResult()
        foreach ($stream in @($stdout, $stderr)) {
            foreach ($fragment in @($fixtureToken, $fixtureValue, 'credential-fragment-fixture-tail', 'not-a-switch', 'node.cmd', '--csrf_token')) {
                if ($stream.Contains($fragment, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Synthetic process data escaped to stdout or stderr.'
                }
            }
        }
        [pscustomobject]@{exitCode=$child.ExitCode; stdout=$stdout; stderr=$stderr}
    } finally { $child.Dispose() }
}
$projected = Invoke-ProcessSnapshotFixture Projection
if ($projected.exitCode -ne 0 -or $projected.stderr) { throw 'The process snapshot did not succeed with clean stderr.' }
$rows = $projected.stdout | ConvertFrom-Json -NoEnumerate
if ($rows -isnot [array] -or $rows.Count -ne 6) { throw 'Expected one fixed JSON row per fixture process.' }
$expectedFields = 'pid,ppid,identityVerified,hasMainWindow,isDesktopMain,hasElectronTypeSwitch,firstArgumentIsImport,parentInvokesNodeCmd'
foreach ($row in $rows) {
    if (($row.PSObject.Properties.Name -join ',') -cne $expectedFields -or
        $row.pid -isnot [long] -or $row.ppid -isnot [long]) { throw 'A process snapshot row has an unexpected shape.' }
    foreach ($property in $row.PSObject.Properties | Select-Object -Skip 2) {
        if ($property.Value -isnot [bool]) { throw 'Process roles and switches must be booleans.' }
    }
}
$main, $renderer, $wrapper, $opaque, $updated, $mixed = $rows | Sort-Object pid
if ($main.pid -ne 4101 -or -not $main.isDesktopMain -or
    $renderer.pid -ne 4102 -or -not $renderer.hasElectronTypeSwitch -or $renderer.isDesktopMain -or
    $wrapper.pid -ne 4103 -or $wrapper.ppid -ne 4200 -or -not $wrapper.firstArgumentIsImport -or
    -not $wrapper.parentInvokesNodeCmd -or $wrapper.isDesktopMain -or
    $opaque.pid -ne 4104 -or $opaque.hasElectronTypeSwitch -or $opaque.firstArgumentIsImport -or $opaque.isDesktopMain) {
    throw 'The process snapshot misclassified a Desktop, renderer, Node wrapper or opaque argument.'
}
if (-not $updated.isDesktopMain -or $mixed.isDesktopMain) {
    throw 'Only a sole --updated argument may identify a desktop launched by the updater.'
}
$failed = Invoke-ProcessSnapshotFixture QueryFailure
if ($failed.exitCode -ne 1 -or $failed.stdout -or -not $failed.stderr.Contains('antigravity-process-query-failed')) {
    throw 'Process query failure did not return the fixed refusal with empty stdout.'
}
'Antigravity process snapshot checked fixed booleans and synthetic data exclusion on stdout and stderr, including query failure.'

& (Join-Path $diagnostics 'Test-DesktopShortcut.ps1')
& (Join-Path $diagnostics 'antigravity/Test-AntigravityLauncher.ps1')
& (Join-Path $diagnostics 'antigravity/Test-AntigravityCustomizationStatus.ps1')
& python -B -I (Join-Path $diagnostics 'antigravity/test_wsl_patch.py')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& node (Join-Path $diagnostics 'antigravity/test_quota_health.cjs')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
