#Requires -Version 7.5
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Apply', 'PostQuit', 'Rebuild', 'Rollback')]
    [string]$Mode = 'Status',
    [switch]$StageOnly,
    [switch]$SkipShortcutHeal,
    [switch]$Quiet,
    [int]$UpdaterWaitSeconds = 90
)

$ErrorActionPreference = 'Stop'

$ToolsDir = $PSScriptRoot
$NodeExe = 'D:\Codex\tools\bin\node.exe'
$Reconciler = Join-Path $ToolsDir 'reconcile-addons.mjs'
$StateDir = Join-Path $ToolsDir 'state'
$AppDir = 'D:\Apps\Google.Antigravity'
$AppExe = Join-Path $AppDir 'Antigravity.exe'
$AppAsar = Join-Path $AppDir 'resources\app.asar'
$BackupDir = 'D:\Apps\Google.Antigravity.Local'
$LauncherExe = Join-Path $BackupDir 'LaunchAntigravity.exe'

function Invoke-ReconcilerJson {
    param([string[]]$Arguments)
    $raw = & $NodeExe $Reconciler @Arguments 2>&1
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
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Google Antigravity.lnk'),
        (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Antigravity.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Antigravity.lnk'),
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Antigravity.lnk')
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
            if ($exe -match '(?i)antigravity-updater' -or $name -match '(?i)^Antigravity-.*\.exe$') {
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

if ($Mode -eq 'Status') {
    $status = Invoke-ReconcilerJson -Arguments @('status')
    $backupPath = Join-Path $BackupDir ("app.asar.{0}.original" -f $status.version)
    $shortcuts = Get-ShortcutAudit
    $out = [pscustomobject]@{
        mode = 'Status'
        reconciler = $status
        officialBackupExists = (Test-Path -LiteralPath $backupPath -PathType Leaf)
        officialBackupPath = $backupPath
        shortcuts = $shortcuts
        postQuitHookExists = (Test-Path -LiteralPath (Join-Path $StateDir 'post-quit-hook.json') -PathType Leaf)
    }
    if (-not $Quiet) {
        $out | ConvertTo-Json -Depth 8
    }
    return
}

$mutexName = 'Local\AntigravityAddonsReconcileMutex'
$mutex = [Threading.Mutex]::new($false, $mutexName)
$acquired = $false
try {
    $waitMs = if ($Mode -eq 'PostQuit') { 0 } else { 5000 }
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
        # Allow a brief moment for the updater child process to spawn after will-quit
        Start-Sleep -Milliseconds 350
        $updaterSeen = Test-UpdaterRunning
        $preStatus = Invoke-ReconcilerJson -Arguments @('status')
        $shortcutCheck = Get-ShortcutAudit
        $anyShortcutNeedsHeal = @($shortcutCheck | Where-Object { $_.needsHeal }).Count -gt 0

        if (-not $updaterSeen -and $preStatus.status -eq 'up-to-date' -and -not $anyShortcutNeedsHeal) {
            return
        }

        if ($updaterSeen) {
            $deadline = [datetime]::UtcNow.AddSeconds($UpdaterWaitSeconds)
            while ((Test-UpdaterRunning) -and ([datetime]::UtcNow -lt $deadline)) {
                Start-Sleep -Seconds 1
            }
            Start-Sleep -Seconds 1
        }

        $reconcileResult = Invoke-ReconcilerJson -Arguments @('reconcile', '--apply')
        $shortcuts = if ($SkipShortcutHeal) { @() } else { Get-ShortcutAudit -Heal }
        $record = [pscustomobject]@{
            mode = 'PostQuit'
            updaterObserved = $updaterSeen
            reconcile = $reconcileResult
            shortcuts = $shortcuts
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
        $record = [pscustomobject]@{
            mode = $Mode
            stageOnly = [bool]$StageOnly
            reconcile = $reconcileResult
            shortcuts = $shortcuts
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
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
}
