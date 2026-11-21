#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sync-AntigravityAddons.ps1')

$managedDirectory = 'D:\Apps\Google.Antigravity'
$legacyDirectory = 'C:\Users\Fixture\AppData\Local\Programs\antigravity'
$deployment = [pscustomobject]@{
    directory = $managedDirectory
    executablePath = "$managedDirectory\Antigravity.exe"
    uninstallerPath = "$managedDirectory\Uninstall Antigravity.exe"
    present = $true
    uninstallerPresent = $true
}
$desktop = [pscustomobject]@{ desktopRunning = $false; executablePaths = @(); pathUnverified = $false }
$views = @(foreach ($view in 'Registry32', 'Registry64') {
    [pscustomobject]@{
        view = $view
        readable = $true
        productKeyPresent = $true
        productInstallLocation = $legacyDirectory
        uninstallKeyPresent = $true
        uninstallInstallLocation = $managedDirectory
        uninstallString = '"D:\Apps\Google.Antigravity\Uninstall Antigravity.exe" /currentuser'
        quietUninstallString = '"D:\Apps\Google.Antigravity\Uninstall Antigravity.exe" /currentuser /S'
        machineRegistrationPresent = $false
    }
})

$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.productKeyMatchesDeployment -or -not $result.uninstallRegistrationMatchesDeployment) {
    throw 'D: in Add/Remove Programs must not hide the C: NSIS update target.'
}
foreach ($view in $result.registryViews) {
    if ($view.productReason -cne 'product-location-mismatch' -or $view.productInstallLocation -ine $legacyDirectory) {
        throw "The stale NSIS product path must be reported on $($view.view)."
    }
}
if ($result.running.desktopRunning -or $result.running.otherInstallationRunning -or $result.running.reason -cne 'desktop-not-running') {
    throw 'The absence of a visible desktop is not an installation mismatch.'
}

foreach ($view in $views) { $view.productInstallLocation = 'd:/apps/google.antigravity/' }
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if (-not $result.ready -or -not $result.productKeyMatchesDeployment -or
    -not $result.uninstallRegistrationMatchesDeployment -or $result.running.matchesDeployment) {
    throw 'Both matching views and a closed desktop must be ready, with no running path match reported.'
}

$desktop.desktopRunning = $true
$desktop.executablePaths = @($deployment.executablePath)
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if (-not $result.ready -or -not $result.running.matchesDeployment -or $result.running.otherInstallationRunning) {
    throw 'A running desktop on D: must match the managed deployment.'
}
$desktop.executablePaths += "$legacyDirectory\Antigravity.exe"
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.running.matchesDeployment -or -not $result.running.otherInstallationRunning -or
    $result.running.reason -cne 'other-installation-running') {
    throw 'A second visible desktop from C: must be distinguished from the managed instance.'
}
$desktop.executablePaths = @()
$desktop.pathUnverified = $true
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.running.reason -cne 'running-path-unverified' -or $result.running.otherInstallationRunning) {
    throw 'An unreadable process image must be reported as unverified.'
}
$desktop.desktopRunning = $false
$desktop.pathUnverified = $false

$views[0].productKeyPresent = $false
$views[0].productInstallLocation = $null
$views[1].productInstallLocation = 'D:\Fixture\..\Apps\Google.Antigravity'
$views[1].uninstallString = 'D:\Apps\Google.Antigravity\Uninstall Antigravity.exe /currentuser'
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.productKeyMatchesDeployment -or $result.uninstallRegistrationMatchesDeployment -or
    $result.registryViews[0].productReason -cne 'product-key-missing' -or
    $result.registryViews[1].productReason -cne 'product-location-invalid' -or
    $result.registryViews[1].uninstallReason -cne 'uninstall-path-missing-or-invalid') {
    throw 'Missing product key, dot-segment install location and ambiguously unquoted uninstall command must fail closed.'
}

$views[0].productKeyPresent = $true
$views[0].productInstallLocation = $managedDirectory
$views[1].productInstallLocation = $managedDirectory
$views[1].uninstallString = '"C:\Fixture\Uninstall Antigravity.exe" /currentuser'
$views[1].machineRegistrationPresent = $true
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or -not $result.productKeyMatchesDeployment -or -not $result.machineRegistrationPresent -or
    $result.registryViews[1].uninstallReason -cne 'uninstall-path-mismatch') {
    throw 'Other-install uninstaller and machine-wide registration must be visible.'
}
$missing = Get-AntigravityDeployment ("D:\antigravity-missing-fixture-" + [guid]::NewGuid().ToString('N'))
if ($missing.present -or $missing.executableIssue -cne 'missing' -or $missing.appAsarIssue -cne 'missing') {
    throw 'Missing deployed artifacts must have explicit diagnostics.'
}

$tmpDirectory = if ([IO.Directory]::Exists('D:\agents\tmp')) { 'D:\agents\tmp' } else { 'D:\Codex\temp' }
$artifact = Join-Path $tmpDirectory ('antigravity-artifact-fixture-' + [guid]::NewGuid().ToString('N'))
if ((Get-AntigravityArtifactIssue $artifact) -cne 'missing' -or -not [IO.Directory]::Exists($tmpDirectory)) {
    throw 'Artifact fixture requires its ordinary D: temp directory.'
}
$exclusive = [IO.File]::Open($artifact, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ((Get-AntigravityArtifactIssue $artifact) -cne 'unreadable') { throw 'An exclusive file lock must yield unreadable.' }
} finally {
    $exclusive.Dispose()
    [IO.File]::Delete($artifact)
}

Write-Output 'Antigravity update target fixtures passed.'
