#Requires -Version 7.5
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Apply', 'PostQuit', 'Rebuild', 'Rollback')]
    [string]$Mode = 'Status',
    [switch]$StageOnly,
    [switch]$SkipShortcutHeal,
    [switch]$SkipRegistrationHeal,
    [switch]$RelaunchAfterUpdate,
    [switch]$Quiet,
    [int]$UpdaterWaitSeconds = 90,
    [string]$AppDir = 'D:\Apps\Google.Antigravity',
    [string]$BackupDir = 'D:\Apps\Google.Antigravity.Local',
    [string]$StateDir = '',
    [string]$EvidenceRoot = '',
    [string]$MutexName = 'Local\AntigravityAddonsReconcileMutex'
)

$ErrorActionPreference = 'Stop'

$ToolsDir = $PSScriptRoot
$NodeExe = if (Test-Path -LiteralPath 'D:\Codex\tools\bin\node.exe' -PathType Leaf) { 'D:\Codex\tools\bin\node.exe' } else { 'node' }
$Reconciler = Join-Path $ToolsDir 'reconcile-addons.mjs'
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path $ToolsDir 'state'
}
$AppExe = Join-Path $AppDir 'Antigravity.exe'
$AppAsar = Join-Path $AppDir 'resources\app.asar'
$LauncherExe = Join-Path $BackupDir 'LaunchAntigravity.exe'
$ProductRegistryKey = 'Software\121a0be4-63bd-531e-acf8-fc3924c7e984'
$UninstallRegistryKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\121a0be4-63bd-531e-acf8-fc3924c7e984'

function Initialize-ShortcutShellInterop {
    if ('AntigravityAddons.ShortcutShellInterop' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AntigravityAddons {
    public static class ShortcutShellInterop {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern void SHChangeNotify(int wEventId, uint uFlags, string dwItem1, IntPtr dwItem2);

        public static void NotifyItemUpdated(string itemPath, string parentDir) {
            const int SHCNE_UPDATEITEM = 0x00002000;
            const int SHCNE_UPDATEDIR = 0x00001000;
            const uint SHCNF_PATHW_FLUSHNOWAIT = 0x3005;
            if (!string.IsNullOrEmpty(itemPath)) {
                SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW_FLUSHNOWAIT, itemPath, IntPtr.Zero);
            }
            if (!string.IsNullOrEmpty(parentDir)) {
                SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATHW_FLUSHNOWAIT, parentDir, IntPtr.Zero);
            }
        }
    }
}
'@
}

function Invoke-ReconcilerJson {
    param([string[]]$Arguments)
    $fullArgs = @($Arguments) + @('--app-dir', $AppDir, '--backup-dir', $BackupDir, '--state-root', $StateDir)
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $fullArgs += @('--evidence-root', $EvidenceRoot)
    }
    $raw = & $NodeExe $Reconciler @fullArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $text = ($raw | Out-String).Trim()
        throw "reconcile-addons.mjs failed (exit $exitCode): $text"
    }
    $lines = @($raw | Where-Object { $_ -is [string] -and $_.Trim().Length -gt 0 })
    if ($lines.Count -eq 0) {
        throw 'reconcile-addons.mjs produced empty output.'
    }
    return ($lines[-1] | ConvertFrom-Json)
}

function Get-ShortcutAudit {
    param([switch]$Heal)
    $taskBarDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Google Antigravity.lnk'),
        (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Antigravity.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Antigravity.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Google Antigravity.lnk'),
        (Join-Path $taskBarDir 'Antigravity.lnk'),
        (Join-Path $taskBarDir 'Google Antigravity.lnk')
    )
    $wsh = New-Object -ComObject WScript.Shell
    $results = @()
    try {
        foreach ($lnkPath in $candidates) {
            if (-not (Test-Path -LiteralPath $lnkPath -PathType Leaf)) {
                continue
            }
            $sc = $wsh.CreateShortcut($lnkPath)
            $beforeTarget = [string]$sc.TargetPath
            $beforeIcon = [string]$sc.IconLocation
            $needsHeal = ($beforeTarget -ine $LauncherExe) -and (
                $beforeTarget -ieq $AppExe -or
                $beforeTarget -match '(?i)\\antigravity\\Antigravity\.exe$'
            )
            $healed = $false
            if ($Heal -and $needsHeal -and (Test-Path -LiteralPath $LauncherExe -PathType Leaf)) {
                $sc.TargetPath = $LauncherExe
                $sc.WorkingDirectory = $AppDir
                $sc.IconLocation = "$AppExe,0"
                $sc.Save()
                Initialize-ShortcutShellInterop
                [AntigravityAddons.ShortcutShellInterop]::NotifyItemUpdated($lnkPath, [IO.Path]::GetDirectoryName($lnkPath))
                $healed = $true
                $needsHeal = $false
            }
            $results += [pscustomobject]@{
                path = $lnkPath
                target = $(if ($healed) { $LauncherExe } else { $beforeTarget })
                icon = $(if ($healed) { "$AppExe,0" } else { $beforeIcon })
                healed = $healed
                needsHeal = $needsHeal
            }
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
    }
    return ,$results
}

function Test-UpdaterRunning {
    try {
        $procs = @(Get-CimInstance Win32_Process -Property ProcessId, Name, ExecutablePath, CommandLine -ErrorAction Stop)
        foreach ($p in $procs) {
            $exe = [string]$p.ExecutablePath
            $name = [string]$p.Name
            $cmdLine = [string]$p.CommandLine
            if ($exe -match '(?i)antigravity-updater' -or
                $name -match '(?i)^Antigravity-.*\.exe$' -or
                $name -ieq 'Uninstall Antigravity.exe' -or
                ($cmdLine -match '(?i)Antigravity-x64\.exe' -and $name -notmatch '(?i)^(?:pwsh|powershell|cmd|node|python)(?:\.exe)?$')) {
                return $true
            }
        }
    } catch {
        return $false
    }
    return $false
}

function Test-AntigravityDesktopRunning {
    $procs = @(Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            if ($p.Path -ieq $AppExe -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
                return $true
            }
        } catch {
            # Ignore transient process inspection failures
        }
    }
    return $false
}

function Test-AnyAntigravityProcessRunning {
    $procs = @(Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            if ($p.Path -ieq $AppExe) {
                return $true
            }
        } catch {
            # Ignore transient process inspection failures
        }
    }
    return $false
}

function Test-LauncherProcessRunning {
    param([string]$ExpectedLauncherPath = $LauncherExe)
    if ([string]::IsNullOrWhiteSpace($ExpectedLauncherPath)) {
        return $false
    }
    $launcherName = [IO.Path]::GetFileNameWithoutExtension($ExpectedLauncherPath)
    $procs = @(Get-Process -Name $launcherName -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            if ($p.Path -ieq $ExpectedLauncherPath) {
                return $true
            }
        } catch {
            # Ignore transient process inspection failures
        }
    }
    return $false
}

function ConvertTo-AntigravityLocalPath($Value) {
    # Compare registry paths lexically. Never open an arbitrary path from the registry.
    if ($Value -isnot [string] -or $Value -notmatch '\A[A-Za-z]:[\\/][^<>:"|?*%\x00-\x1f]+\z' -or
        $Value -match '[. ](?=[\\/]|\z)') { return $null }
    try { [IO.Path]::GetFullPath($Value).TrimEnd([char]'\') }
    catch { $null }
}

function Get-AntigravityUninstallExecutable($Value) {
    if ($Value -isnot [string]) { return $null }
    $command = [regex]::Match($Value, '\A(?:"([^"\r\n]+)"|([^\s"]+\.exe))(?=[ \t]|\z)', 'IgnoreCase')
    if (-not $command.Success) { return $null }
    ConvertTo-AntigravityLocalPath ($command.Groups[1].Value + $command.Groups[2].Value)
}

function Get-AntigravityArtifactIssue([string]$Path) {
    $ancestry = [Collections.Generic.Stack[string]]::new()
    for ($item = $Path; $item; $item = [IO.Path]::GetDirectoryName($item)) { $ancestry.Push($item) }
    foreach ($item in $ancestry) {
        try { $attributes = [IO.File]::GetAttributes($item) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return 'missing' }
        catch { return 'unreadable' }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { return 'reparse-point' }
        $isDirectory = [bool]($attributes -band [IO.FileAttributes]::Directory)
        if ($isDirectory -ne ($item -ne $Path)) { return 'wrong-file-type' }
    }
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $handle = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $handle.Dispose()
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return 'missing'
    } catch {
        return 'unreadable'
    }
}

function Get-AntigravityDeployment([string]$Directory) {
    $exe = Join-Path $Directory 'Antigravity.exe'
    $asar = Join-Path $Directory 'resources/app.asar'
    $uninstaller = Join-Path $Directory 'Uninstall Antigravity.exe'
    $exeIssue = Get-AntigravityArtifactIssue $exe
    $asarIssue = Get-AntigravityArtifactIssue $asar
    $serverIssue = Get-AntigravityArtifactIssue (Join-Path $Directory 'resources/bin/language_server.exe')
    $uninstallerIssue = Get-AntigravityArtifactIssue $uninstaller
    [pscustomobject]@{
        directory = $Directory
        executablePath = $exe
        appAsarPath = $asar
        uninstallerPath = $uninstaller
        present = (-not $exeIssue -and -not $asarIssue -and -not $serverIssue)
        uninstallerPresent = (-not $uninstallerIssue)
        executableIssue = $exeIssue
        appAsarIssue = $asarIssue
        languageServerIssue = $serverIssue
        uninstallerIssue = $uninstallerIssue
    }
}

function Read-AntigravityUpdateRegistration {
    $valueOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    foreach ($view in 'Registry32', 'Registry64') {
        $row = [ordered]@{
            view = $view
            readable = $true
            productKeyPresent = $false
            productInstallLocation = $null
            uninstallKeyPresent = $false
            uninstallInstallLocation = $null
            uninstallString = $null
            quietUninstallString = $null
            machineRegistrationPresent = $false
        }
        foreach ($hive in 'CurrentUser', 'LocalMachine') {
            $baseKey = $product = $uninstall = $null
            try {
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $product = $baseKey.OpenSubKey($ProductRegistryKey, $false)
                $uninstall = $baseKey.OpenSubKey($UninstallRegistryKey, $false)
                if ($hive -eq 'LocalMachine') {
                    $row.machineRegistrationPresent = ($null -ne $product -or $null -ne $uninstall)
                    continue
                }
                $row.productKeyPresent = ($null -ne $product)
                if ($product) { $row.productInstallLocation = $product.GetValue('InstallLocation', $null, $valueOptions) }
                $row.uninstallKeyPresent = ($null -ne $uninstall)
                if ($uninstall) {
                    $row.uninstallInstallLocation = $uninstall.GetValue('InstallLocation', $null, $valueOptions)
                    $row.uninstallString = $uninstall.GetValue('UninstallString', $null, $valueOptions)
                    $row.quietUninstallString = $uninstall.GetValue('QuietUninstallString', $null, $valueOptions)
                }
            } catch {
                $row.readable = $false
            } finally {
                if ($uninstall) { $uninstall.Dispose() }
                if ($product) { $product.Dispose() }
                if ($baseKey) { $baseKey.Dispose() }
            }
        }
        [pscustomobject]$row
    }
}

function Read-AntigravityDesktopObservation {
    $paths = [Collections.Generic.List[string]]::new()
    $observed = $unverified = $false
    try {
        $session = (Get-Process -Id $PID -ErrorAction Stop).SessionId
        foreach ($process in [Diagnostics.Process]::GetProcessesByName('Antigravity')) {
            try {
                if ($process.SessionId -ne $session -or $process.MainWindowHandle -eq [IntPtr]::Zero) { continue }
                $observed = $true
                $exe = ConvertTo-AntigravityLocalPath $process.Path
                if ($exe) { $paths.Add($exe) } else { $unverified = $true }
            } catch {
                if (-not $process.HasExited) { $unverified = $true }
            } finally {
                $process.Dispose()
            }
        }
        if (-not $observed) {
            # Inside hidden desktops (e.g. WinSta0\exebox-*), EnumWindows cannot see WinSta0\Default HWNDs.
            # Fall back to desktop-main command-line classification in the same Windows session.
            $cimRows = @(Get-CimInstance Win32_Process -Filter "Name = 'Antigravity.exe'" -Property ProcessId, SessionId, ExecutablePath, CommandLine -ErrorAction SilentlyContinue)
            foreach ($row in $cimRows) {
                if ($row.SessionId -ne $session) { continue }
                $cmdLine = [string]$row.CommandLine
                if ($cmdLine -match '(?:^|\s)--type=' -or $cmdLine -match '(?:^|\s)(?:"--import"|--import)(?:\s|$)') { continue }
                $observed = $true
                $exe = ConvertTo-AntigravityLocalPath $row.ExecutablePath
                if ($exe) { $paths.Add($exe) } else { $unverified = $true }
            }
        }
    } catch {
        $unverified = $true
    }
    [pscustomobject]@{ desktopRunning = $observed; executablePaths = $paths.ToArray(); pathUnverified = $unverified }
}

function Get-AntigravityUpdateTarget($Deployment, [object[]]$Registration, $Desktop) {
    $pathComparer = [StringComparer]::OrdinalIgnoreCase
    $views = @(foreach ($row in $Registration) {
        $productLocation = ConvertTo-AntigravityLocalPath $row.productInstallLocation
        $uninstallLocation = ConvertTo-AntigravityLocalPath $row.uninstallInstallLocation
        $uninstallExe = Get-AntigravityUninstallExecutable $row.uninstallString
        $quietUninstallExe = Get-AntigravityUninstallExecutable $row.quietUninstallString
        $productReason = if (-not $row.readable) { 'registry-unreadable' }
            elseif (-not $row.productKeyPresent) { 'product-key-missing' }
            elseif ($null -eq $row.productInstallLocation -or
                ($row.productInstallLocation -is [string] -and $row.productInstallLocation.Length -eq 0)) { 'product-location-missing' }
            elseif (-not $productLocation) { 'product-location-invalid' }
            elseif (-not $pathComparer.Equals($productLocation, $Deployment.directory)) { 'product-location-mismatch' }
            elseif (-not $Deployment.present) { 'deployment-unverified' }
        $uninstallReason = if (-not $row.readable) { 'registry-unreadable' }
            elseif (-not $row.uninstallKeyPresent) { 'uninstall-key-missing' }
            elseif (-not $uninstallLocation -or -not $uninstallExe -or -not $quietUninstallExe) { 'uninstall-path-missing-or-invalid' }
            elseif (-not $pathComparer.Equals($uninstallLocation, $Deployment.directory) -or
                -not $pathComparer.Equals($uninstallExe, $Deployment.uninstallerPath) -or
                -not $pathComparer.Equals($quietUninstallExe, $Deployment.uninstallerPath)) { 'uninstall-path-mismatch' }
            elseif (-not $Deployment.uninstallerPresent) { 'uninstaller-unverified' }
        [pscustomobject]@{
            view = $row.view
            productKeyPresent = $row.productKeyPresent
            productInstallLocation = $productLocation
            productMatchesDeployment = (-not $productReason)
            productReason = $productReason
            uninstallKeyPresent = $row.uninstallKeyPresent
            uninstallInstallLocation = $uninstallLocation
            uninstallExecutablePath = $uninstallExe
            quietUninstallExecutablePath = $quietUninstallExe
            uninstallMatchesDeployment = (-not $uninstallReason)
            uninstallReason = $uninstallReason
            machineRegistrationPresent = $row.machineRegistrationPresent
        }
    })
    $productMatches = $views.Count -eq 2 -and ($views.productMatchesDeployment -notcontains $false)
    $uninstallMatches = $views.Count -eq 2 -and ($views.uninstallMatchesDeployment -notcontains $false)
    $paths = @($Desktop.executablePaths | Sort-Object -Unique)
    $otherInstall = @($Desktop.executablePaths | Where-Object { -not $pathComparer.Equals($_, $Deployment.executablePath) }).Count -gt 0
    $runningMatches = $Desktop.desktopRunning -and $paths.Count -gt 0 -and -not $otherInstall -and
        -not $Desktop.pathUnverified -and $Deployment.present
    $runningReason = if ($otherInstall) { 'other-installation-running' }
        elseif ($Desktop.pathUnverified) { 'running-path-unverified' }
        elseif (-not $Desktop.desktopRunning) { 'desktop-not-running' }
        elseif (-not $runningMatches) { 'deployment-unverified' }
    $machineRegistration = $views.machineRegistrationPresent -contains $true
    [pscustomobject]@{
        ready = ($Deployment.present -and $productMatches -and $uninstallMatches -and -not $machineRegistration -and
            -not $otherInstall -and -not $Desktop.pathUnverified)
        productKey = "HKCU\$ProductRegistryKey"
        uninstallKey = "HKCU\$UninstallRegistryKey"
        productKeyMatchesDeployment = $productMatches
        uninstallRegistrationMatchesDeployment = $uninstallMatches
        machineRegistrationPresent = $machineRegistration
        deployment = $Deployment
        registryViews = $views
        running = [pscustomobject]@{
            desktopRunning = $Desktop.desktopRunning
            executablePaths = $paths
            matchesDeployment = $runningMatches
            otherInstallationRunning = $otherInstall
            reason = $runningReason
        }
    }
}

function Repair-AntigravityUninstallRegistration {
    param(
        [object]$Deployment = $null,
        [Microsoft.Win32.RegistryHive]$Hive = [Microsoft.Win32.RegistryHive]::CurrentUser,
        [string]$ProductSubKey = $ProductRegistryKey,
        [string]$UninstallSubKey = $UninstallRegistryKey
    )
    $effectiveDeployment = if ($null -ne $Deployment) { $Deployment } else { Get-AntigravityDeployment $AppDir }
    if (-not $effectiveDeployment.present -or -not $effectiveDeployment.uninstallerPresent) {
        return @()
    }
    $pathComparer = [StringComparer]::OrdinalIgnoreCase
    $valueOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    foreach ($regView in 'Registry32', 'Registry64') {
        $baseKey = $product = $uninstall = $null
        $healed = $false
        $reason = 'unchanged'
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $regView)
            $product = $baseKey.OpenSubKey($ProductSubKey, $false)
            $uninstall = $baseKey.OpenSubKey($UninstallSubKey, $true)
            if ($null -eq $product -or $null -eq $uninstall) {
                $reason = 'key-missing'
            } else {
                $productLoc = ConvertTo-AntigravityLocalPath ($product.GetValue('InstallLocation', $null, $valueOptions))
                $existingLoc = ConvertTo-AntigravityLocalPath ($uninstall.GetValue('InstallLocation', $null, $valueOptions))
                $uExe = Get-AntigravityUninstallExecutable ($uninstall.GetValue('UninstallString', $null, $valueOptions))
                $quExe = Get-AntigravityUninstallExecutable ($uninstall.GetValue('QuietUninstallString', $null, $valueOptions))
                if (-not $productLoc -or -not $pathComparer.Equals($productLoc, $effectiveDeployment.directory)) {
                    $reason = 'product-mismatch'
                } elseif (-not $uExe -or -not $quExe -or
                    -not $pathComparer.Equals($uExe, $effectiveDeployment.uninstallerPath) -or
                    -not $pathComparer.Equals($quExe, $effectiveDeployment.uninstallerPath)) {
                    $reason = 'uninstaller-mismatch'
                } elseif ($existingLoc -and $pathComparer.Equals($existingLoc, $effectiveDeployment.directory)) {
                    $reason = 'already-aligned'
                } elseif ($existingLoc) {
                    $reason = 'existing-location-mismatch'
                } else {
                    $uninstall.SetValue('InstallLocation', $effectiveDeployment.directory, [Microsoft.Win32.RegistryValueKind]::String)
                    $healed = $true
                    $reason = 'healed'
                }
            }
        } catch {
            $reason = 'write-failed'
        } finally {
            if ($uninstall) { $uninstall.Dispose() }
            if ($product) { $product.Dispose() }
            if ($baseKey) { $baseKey.Dispose() }
        }
        [pscustomobject]@{
            view = $regView
            healed = $healed
            reason = $reason
        }
    }
}

function Save-LastSync {
    param([object]$Payload)
    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($StateDir)
    }
    $target = Join-Path $StateDir 'last-sync.json'
    $tmp = "$target.$PID.tmp"
    $json = ($Payload | ConvertTo-Json -Depth 8) + "`n"
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $target -Force
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Mode -eq 'Status') {
    $deployment = Get-AntigravityDeployment $AppDir
    $updateTarget = Get-AntigravityUpdateTarget $deployment @(Read-AntigravityUpdateRegistration) (Read-AntigravityDesktopObservation)
    $status = if ($deployment.appAsarIssue -or ($deployment.languageServerIssue -and $deployment.languageServerIssue -ne 'missing')) {
        [pscustomobject]@{ status = 'deployment-unavailable'; version = $null }
    } else {
        Invoke-ReconcilerJson -Arguments @('status')
    }
    $backupPath = if ($status.version) { Join-Path $BackupDir ("app.asar.{0}.original" -f $status.version) }
    $shortcuts = Get-ShortcutAudit
    $out = [pscustomobject]@{
        mode = 'Status'
        reconciler = $status
        officialBackupExists = ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf))
        officialBackupPath = $backupPath
        shortcuts = $shortcuts
        postQuitHookExists = (Test-Path -LiteralPath (Join-Path $StateDir 'post-quit-hook.json') -PathType Leaf)
        updateTarget = $updateTarget
    }
    if (-not $Quiet) {
        $out | ConvertTo-Json -Depth 8
    }
    return
}

$mutex = [Threading.Mutex]::new($false, $MutexName)
$acquired = $false
$handoffAlreadyActive = $false
try {
    # Non-silent NSIS updates invoke Start Menu Antigravity.lnk -> LaunchAntigravity.exe (-Mode Apply)
    # while PostQuit holds the mutex building the new version's ASAR (~15-30s). Apply/Rebuild/Rollback
    # must wait up to 120s for the mutex rather than timing out at 5s and launching unpatched Antigravity.
    $waitMs = if ($RelaunchAfterUpdate) { 120000 } elseif ($Mode -eq 'PostQuit') { 0 } else { 120000 }
    try {
        $acquired = $mutex.WaitOne($waitMs)
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $busy = [pscustomobject]@{
            mode = $Mode
            status = 'skipped-busy'
            timestamp = [datetime]::UtcNow.ToString('o')
        }
        if (-not $Quiet) { $busy | ConvertTo-Json -Depth 4 }
        return
    }

    if ($Mode -eq 'PostQuit') {
        $updaterSeen = $false
        if ($RelaunchAfterUpdate) {
            if (-not $SkipShortcutHeal) {
                [void](Get-ShortcutAudit -Heal)
            }
            $quitDeadline = [datetime]::UtcNow.AddSeconds(15)
            while ((Test-AnyAntigravityProcessRunning) -and ([datetime]::UtcNow -lt $quitDeadline)) {
                Start-Sleep -Milliseconds 200
            }
            $spawnDeadline = [datetime]::UtcNow.AddSeconds(5)
            while ([datetime]::UtcNow -lt $spawnDeadline) {
                if (Test-UpdaterRunning) {
                    $updaterSeen = $true
                    break
                }
                $probeDeploy = Get-AntigravityDeployment $AppDir
                if ($probeDeploy.present) {
                    $probeStatus = Invoke-ReconcilerJson -Arguments @('status')
                    if ($probeStatus.status -ne 'up-to-date') { break }
                }
                Start-Sleep -Milliseconds 250
            }
        } else {
            # Allow a brief moment for the updater child process to spawn after will-quit
            Start-Sleep -Milliseconds 350
            $updaterSeen = Test-UpdaterRunning
            $preStatus = Invoke-ReconcilerJson -Arguments @('status')
            $shortcutCheck = Get-ShortcutAudit
            $anyShortcutNeedsHeal = @($shortcutCheck | Where-Object { $_.needsHeal }).Count -gt 0

            if (-not $updaterSeen -and $preStatus.status -eq 'up-to-date' -and -not $anyShortcutNeedsHeal) {
                return
            }
            if (-not $updaterSeen -and $preStatus.status -ne 'up-to-date') {
                # Wait for all exiting Antigravity processes to release resources\app.asar
                # so pending builds promote on disk before the next direct Taskbar launch.
                $releaseDeadline = [datetime]::UtcNow.AddSeconds(12)
                while ((Test-AnyAntigravityProcessRunning) -and ([datetime]::UtcNow -lt $releaseDeadline)) {
                    Start-Sleep -Milliseconds 200
                }
            }
        }

        if ($updaterSeen -or $RelaunchAfterUpdate) {
            $deadline = [datetime]::UtcNow.AddSeconds($UpdaterWaitSeconds)
            while ((Test-UpdaterRunning) -and ([datetime]::UtcNow -lt $deadline)) {
                Start-Sleep -Seconds 1
            }
            $settleDeadline = [datetime]::UtcNow.AddSeconds(10)
            while ([datetime]::UtcNow -lt $settleDeadline) {
                $settled = Get-AntigravityDeployment $AppDir
                if ($settled.present) { break }
                Start-Sleep -Milliseconds 250
            }
        }

        $reconcileResult = Invoke-ReconcilerJson -Arguments @('reconcile', '--apply')
        $shortcuts = if ($SkipShortcutHeal) { @() } else { Get-ShortcutAudit -Heal }
        $registrationHealed = @(if (-not $SkipRegistrationHeal) { Repair-AntigravityUninstallRegistration })
        $record = [pscustomobject]@{
            mode = 'PostQuit'
            relaunchAfterUpdate = [bool]$RelaunchAfterUpdate
            updaterObserved = $updaterSeen
            reconcile = $reconcileResult
            shortcuts = $shortcuts
            registration = $registrationHealed
            timestamp = [datetime]::UtcNow.ToString('o')
        }
        Save-LastSync -Payload $record
        if (-not $Quiet) { $record | ConvertTo-Json -Depth 8 }
        return
    }

    if ($Mode -eq 'Apply' -or $Mode -eq 'Rebuild') {
        $cliArgs = @('reconcile')
        if ($Mode -eq 'Rebuild') {
            $cliArgs += '--from-backup'
        }
        if ($StageOnly) {
            $cliArgs += '--stage-only'
        } else {
            $cliArgs += '--apply'
        }
        $reconcileResult = Invoke-ReconcilerJson -Arguments $cliArgs
        $shortcuts = if ($SkipShortcutHeal) { @() } else { Get-ShortcutAudit -Heal }
        $registrationHealed = @(if (-not $SkipRegistrationHeal) { Repair-AntigravityUninstallRegistration })
        $record = [pscustomobject]@{
            mode = $Mode
            stageOnly = [bool]$StageOnly
            reconcile = $reconcileResult
            shortcuts = $shortcuts
            registration = $registrationHealed
            timestamp = [datetime]::UtcNow.ToString('o')
        }
        Save-LastSync -Payload $record
        if (-not $Quiet) { $record | ConvertTo-Json -Depth 8 }
        return
    }

    if ($Mode -eq 'Rollback') {
        if (Test-AntigravityDesktopRunning) {
            throw 'Antigravity desktop is currently running. Close Antigravity before running Rollback.'
        }
        $st = Invoke-ReconcilerJson -Arguments @('status')
        $backupPath = Join-Path $BackupDir ("app.asar.{0}.original" -f $st.version)
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            throw "Official backup not found for version $($st.version): $backupPath"
        }
        $expectedSha = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $tmpAsar = Join-Path (Split-Path -Parent $AppAsar) (".app.asar.rollback-{0}.tmp" -f $PID)
        Copy-Item -LiteralPath $backupPath -Destination $tmpAsar -Force
        Move-Item -LiteralPath $tmpAsar -Destination $AppAsar -Force
        $actualSha = (Get-FileHash -LiteralPath $AppAsar -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -cne $expectedSha) {
            throw "Rollback SHA-256 verification failed: expected $expectedSha, got $actualSha"
        }
        foreach ($stateFile in @('active-build.json', 'pending-apply.json', 'pending-app.asar')) {
            $p = Join-Path $StateDir $stateFile
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                Remove-Item -LiteralPath $p -Force
            }
        }
        $record = [pscustomobject]@{
            mode = 'Rollback'
            status = 'rolled-back'
            version = $st.version
            restoredSha256 = $actualSha
            backupPath = $backupPath
            timestamp = [datetime]::UtcNow.ToString('o')
        }
        Save-LastSync -Payload $record
        if (-not $Quiet) { $record | ConvertTo-Json -Depth 6 }
        return
    }
} finally {
    if ($acquired) {
        if ($Mode -eq 'PostQuit' -and $RelaunchAfterUpdate) {
            $handoffAlreadyActive = (Test-AntigravityDesktopRunning) -or (Test-AnyAntigravityProcessRunning) -or (Test-LauncherProcessRunning)
        }
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
    if ($Mode -eq 'PostQuit' -and $RelaunchAfterUpdate -and $acquired -and -not $handoffAlreadyActive -and -not (Test-AntigravityDesktopRunning) -and -not (Test-LauncherProcessRunning)) {
        try {
            $relaunchTarget = if (Test-Path -LiteralPath $LauncherExe -PathType Leaf) { $LauncherExe } else { $AppExe }
            if (Test-Path -LiteralPath $relaunchTarget -PathType Leaf) {
                [void](Start-Process -FilePath $relaunchTarget -WorkingDirectory $AppDir)
            }
        } catch {}
    }
}
