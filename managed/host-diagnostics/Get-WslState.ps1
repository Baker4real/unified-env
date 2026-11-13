#Requires -Version 7.5
<#
.SYNOPSIS
Read WSL packages, distributions, features, services and dependent applications without invoking wsl.exe.
.DESCRIPTION
Prints one JSON snapshot. InstallStatus and other metadata under Lxss are not distributions.
Get-WindowsOptionalFeature falls back to Win32_OptionalFeature when elevation is unavailable.
The ForTest parameters replace only their corresponding collectors with explicit JSON fixtures.
#>
[CmdletBinding()]
param(
    [string]$AppxPackagesForTest,
    [string]$LxssEntriesForTest,
    [string]$FeatureStatesForTest,
    [switch]$ForceFeatureFallbackForTest
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Read-JsonArray([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { throw "JSON fixture is empty: $Path" }
    @($text | ConvertFrom-Json -ErrorAction Stop | Where-Object { $null -ne $_ })
}

$result = [ordered]@{
    status = 'complete'
    observedAt = (Get-Date).ToString('o')
    wslProcesses = @()
    wslAppx = @()
    windowsFeatures = @()
    lxssKeyExists = $false
    distributions = @()
    paths = @()
    services = @()
    relatedAppx = @()
    relatedDesktopApps = @()
    relatedTasks = @()
}

$result['wslProcesses'] = @(
    Get-CimInstance Win32_Process |
        Where-Object Name -eq 'wsl.exe' |
        Select-Object ProcessId, ParentProcessId, CreationDate
)
$appxPackages = if ($AppxPackagesForTest) {
    @(Read-JsonArray $AppxPackagesForTest)
}
else {
    @(Get-AppxPackage -ErrorAction Stop)
}
$result['wslAppx'] = @(
    $appxPackages |
        Where-Object Name -eq 'MicrosoftCorporationII.WindowsSubsystemForLinux' |
        Select-Object Name, Version, PackageFullName, InstallLocation, Status
)

$featureStates = if ($FeatureStatesForTest) { @(Read-JsonArray $FeatureStatesForTest) } else { $null }
$featureNames = @(
    'Microsoft-Windows-Subsystem-Linux',
    'VirtualMachinePlatform',
    'Microsoft-Hyper-V-All',
    'Containers-DisposableClientVM'
)
$result['windowsFeatures'] = @(
    foreach ($featureName in $featureNames) {
        $featureResult = $null
        if (-not $ForceFeatureFallbackForTest) {
            try {
                $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
                $featureResult = [pscustomobject]@{
                    FeatureName = $featureName
                    State = [string]$feature.State
                    InstallState = $feature.InstallState
                    Source = 'Get-WindowsOptionalFeature'
                    Error = $null
                }
            }
            catch {
                $featureResult = $null
            }
        }
        if ($null -eq $featureResult) {
            try {
                $feature = if ($null -ne $featureStates) {
                    @($featureStates | Where-Object Name -EQ $featureName)[0]
                }
                else {
                    Get-CimInstance Win32_OptionalFeature -Filter "Name='$featureName'" -ErrorAction Stop
                }
                if ($null -eq $feature) { throw "Feature is absent from Win32_OptionalFeature: $featureName" }
                $state = switch ([int]$feature.InstallState) {
                    1 { 'Enabled' }
                    2 { 'Disabled' }
                    default { $null }
                }
                $featureResult = [pscustomobject]@{
                    FeatureName = $featureName
                    State = $state
                    InstallState = $feature.InstallState
                    Source = 'Win32_OptionalFeature'
                    Error = $null
                }
            }
            catch {
                $featureResult = [pscustomobject]@{
                    FeatureName = $featureName
                    State = $null
                    InstallState = $null
                    Source = 'unavailable'
                    Error = $_.Exception.Message
                }
            }
        }
        $featureResult
    }
)

$lxssPath = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Lxss'
$result['lxssKeyExists'] = if ($LxssEntriesForTest) { $true } else { Test-Path -LiteralPath $lxssPath }
$lxssEntries = if ($LxssEntriesForTest) {
    @(Read-JsonArray $LxssEntriesForTest)
}
elseif ($result['lxssKeyExists']) {
    @(
        Get-ChildItem -LiteralPath $lxssPath -ErrorAction Stop |
            ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop }
    )
}
else {
    @()
}
$result['distributions'] = @(
    $lxssEntries |
        Where-Object { $null -ne $_.DistributionName -and $_.DistributionName -ne '' } |
        Select-Object DistributionName, BasePath, Version, State, Flags
)

$watchedPaths = @(
    (Join-Path $env:SystemRoot 'System32/wsl.exe'),
    (Join-Path $env:SystemRoot 'System32/bash.exe'),
    (Join-Path $env:SystemRoot 'System32/wslconfig.exe'),
    (Join-Path $env:ProgramFiles 'WSL'),
    (Join-Path $env:USERPROFILE '.wslconfig'),
    (Join-Path $env:LOCALAPPDATA 'wsl'),
    'D:/WSL'
)
$result['paths'] = @(
    foreach ($watchedPath in $watchedPaths) {
        $item = Get-Item -LiteralPath $watchedPath -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Path = $watchedPath
            Exists = $null -ne $item
            LastWriteTime = if ($null -ne $item) { $item.LastWriteTime.ToString('o') } else { $null }
            FileVersion = if ($null -ne $item -and -not $item.PSIsContainer) { $item.VersionInfo.FileVersion } else { $null }
        }
    }
)

$serviceNames = @('WSLService', 'LxssManager', 'vmcompute')
$result['services'] = @(
    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name = $serviceName
            Exists = $null -ne $service
            Status = if ($null -ne $service) { [string]$service.Status } else { $null }
            StartType = if ($null -ne $service) { [string]$service.StartType } else { $null }
        }
    }
)

$appNamePattern = '(?i)Windows Subsystem for Linux|WindowsSubsystemForLinux|Ubuntu|Debian|Kali|SUSE|Docker|Rancher|Podman'
$result['relatedAppx'] = @(
    $appxPackages |
        Where-Object Name -Match $appNamePattern |
        Select-Object Name, Version, PackageFullName, InstallLocation
)

$uninstallRoots = @(
    'HKLM:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*',
    'HKLM:/Software/WOW6432Node/Microsoft/Windows/CurrentVersion/Uninstall/*',
    'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*'
)
$result['relatedDesktopApps'] = @(
    Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object DisplayName -Match $appNamePattern |
        Select-Object DisplayName, DisplayVersion, Publisher, UninstallString
)

$result['relatedTasks'] = @(
    Get-ScheduledTask -ErrorAction Stop |
        Where-Object {
            $actionText = ($_.Actions | Out-String)
            $actionText -match '(?i)wsl|docker|rancher|podman|ubuntu|debian|kali'
        } |
        Select-Object TaskPath, TaskName, State
)

$result | ConvertTo-Json -Depth 6
