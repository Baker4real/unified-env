#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShortcutPath,
    [Parameter(Mandatory)][string]$ExpectedTarget,
    [Parameter(Mandatory)][string]$ExecutablePath,
    [string]$ExpectedArguments = '',
    [ValidateSet('Plan','Open','Restart')][string]$Mode = 'Plan',
    [ValidateRange(2,60)][int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

function Get-OrdinaryFile([string]$Path, [string]$Extension) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'absolute-file-path-required' }
    $item = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force
    if ($item.PSIsContainer -or $item.Extension -ine $Extension) { throw 'unexpected-file-type' }
    for ($parent = $item; $null -ne $parent; $parent = if ($parent.PSIsContainer) { $parent.Parent } else { $parent.Directory }) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse-point-in-launch-path' }
    }
    $item.FullName
}

$shortcut = Get-OrdinaryFile $ShortcutPath '.lnk'
$target = Get-OrdinaryFile $ExpectedTarget '.exe'
$executable = Get-OrdinaryFile $ExecutablePath '.exe'
$targetHash = (Get-FileHash -LiteralPath $target).Hash
$linkHash = (Get-FileHash -LiteralPath $shortcut).Hash
$launchLink = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
if ($launchLink.TargetPath -ine $target -or [string]$launchLink.Arguments -cne $ExpectedArguments) {
    throw 'shortcut-target-or-arguments-changed'
}

$result = [ordered]@{status='planned'; shortcut=$shortcut; target=$target; executable=$executable; processId=$null; startedAt=$null; previousProcessId=$null}
if ($Mode -eq 'Plan') { return [pscustomobject]$result }

$antigravity = [IO.Path]::GetFileName($executable) -ieq 'Antigravity.exe'
if ($antigravity) { . "$PSScriptRoot/lib/AntigravityProcessIdentity.ps1" }
$sessionId = (Get-Process -Id $PID).SessionId
$explorer = Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe'
if ($sessionId -eq 0 -or -not (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId -and $_.Path -ieq $explorer })) {
    throw 'interactive-explorer-session-required'
}

function Get-AppWindows([switch]$BeforeLaunch) {
    $name = [IO.Path]::GetFileNameWithoutExtension($executable)
    $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $sessionId -and $_.Path -ieq $executable
    })
    if ($antigravity) {
        if (-not $BeforeLaunch -and $processes.Count -eq 0) { return }
        $main = Get-AntigravityDesktopMainProcess $executable $sessionId $processes -BeforeLaunch:$BeforeLaunch
        if ($main) {
            $process = Assert-AntigravityDesktopMainProcess $main.Snapshot $executable $sessionId $main.Frame
            [pscustomobject]@{ Process=$process; Frame=$main.Frame }
        }
        return
    }
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) { [pscustomobject]@{ Process=$process; Frame=$null } }
    }
}

function Test-AppWindowResponsive($Window) {
    if ($Window.Frame) { return $Window.Frame.IsResponsive($Window.Process.Id) }
    $Window.Process.Responding
}

$before = @(Get-AppWindows -BeforeLaunch)
if ($before.Count -gt 1) { throw 'more-than-one-matching-app-window' }
if ($before.Count -eq 1) {
    $old = $before[0].Process
    try {
        if ($Mode -eq 'Open') {
            if (-not (Test-AppWindowResponsive $before[0])) { throw 'existing-window-not-responding' }
            $result.status = 'already-open'
            $result.processId = $old.Id
            $result.startedAt = $old.StartTime.ToUniversalTime().ToString('o')
            return [pscustomobject]$result
        }
        $result.previousProcessId = $old.Id
        $closeSent = if ($antigravity) { $before[0].Frame.TryClose($old.Id) } else { $old.CloseMainWindow() }
        if (-not $closeSent -or -not $old.WaitForExit($TimeoutSeconds * 1000)) {
            throw 'app-did-not-close-normally'
        }
    } finally { if ($antigravity) { $old.Dispose() } }
}
if ((Get-FileHash -LiteralPath $shortcut).Hash -ne $linkHash -or (Get-FileHash -LiteralPath $target).Hash -ne $targetHash) {
    throw 'shortcut-or-target-changed-before-launch'
}

$started = [datetime]::UtcNow
$launch = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = ('"{0}" "{1}"' -f $explorer, $shortcut)
}
if ($launch.ReturnValue -ne 0) { throw "explorer-launch-refused-$($launch.ReturnValue)" }

$deadline = $started.AddSeconds($TimeoutSeconds)
do {
    $windows = @(Get-AppWindows)
    try {
        $found = @($windows | Where-Object { $_.Process.StartTime.ToUniversalTime() -ge $started -and (Test-AppWindowResponsive $_) })
        if ($found.Count -gt 1) { throw 'more-than-one-new-app-window' }
        if ($found.Count -eq 1) {
            $result.status = 'ready'
            $result.processId = $found[0].Process.Id
            $result.startedAt = $found[0].Process.StartTime.ToUniversalTime().ToString('o')
            return [pscustomobject]$result
        }
    } finally {
        if ($antigravity) { foreach ($window in $windows) { $window.Process.Dispose() } }
    }
    Start-Sleep -Milliseconds 150
} while ([datetime]::UtcNow -lt $deadline)
throw 'new-app-window-not-observed-check-existing-process-before-retry'
