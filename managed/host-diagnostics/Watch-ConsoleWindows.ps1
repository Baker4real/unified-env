#Requires -Version 7.4
<#
.SYNOPSIS
Watch the interactive desktop for console windows while chosen scheduled tasks or a shortcut start.

.DESCRIPTION
Get-ConsoleLaunchAudit.ps1 classifies launch lines; this checks what the user's session actually shows. It registers
two temporary Interactive tasks for the current account, neither with a trigger: a monitor started through
conhost.exe --headless, and a control that runs pwsh with no wrapper. The monitor records each new visible console
window (ConsoleWindowClass, PseudoConsoleWindow, Windows Terminal) and each new WindowsTerminal or OpenConsole
process. The control has to open one, which flashes a console window on the user's desktop for about 2.5 seconds and
shows that the monitor can see that desktop. Each task in -StartTasks then starts 5 seconds apart, and the monitor
opens -LaunchPath through the shell, as Explorer does for a Startup shortcut at logon.

Each sighting is attributed to the trigger before it. Status:
  quiet                the control was seen and nothing after it opened a console window
  windows-seen         something else opened one; the report names the trigger, process and window class
  control-missed       the monitor saw no control window, so the run vouches for nothing
  trigger-failed       a task in -StartTasks could not be started
  monitor-not-started  the monitor task did not run, usually because the account has no interactive logon
Exit 0 for quiet, 1 otherwise. Both temporary tasks are removed before the report is written; a killed run leaves
them behind as zz-CodexConsoleWatch-*. Window titles and command lines are not recorded.

.PARAMETER EvidenceDirectory
New D drive directory that receives monitor.jsonl and result.json.

.PARAMETER StartTasks
Task names separated by ';'. A name without a leading '\' is looked up in the root folder.

.PARAMETER LaunchPath
File the monitor opens through the shell after the tasks have started.

.PARAMETER SettleSeconds
How long the monitor keeps watching after the last trigger.

.EXAMPLE
& 'D:/Codex/.codex/scripts/Watch-ConsoleWindows.ps1' -EvidenceDirectory 'D:/agents/run-evidence/console-watch/<new-run>' -StartTasks 'CodexPwshRouterDriftCheck;RemoteInputLockOsdGuard'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$StartTasks,
    [string]$LaunchPath,
    [ValidateRange(5, 600)][int]$SettleSeconds = 20,
    # The monitor task's own command line sets these.
    [switch]$Monitor,
    [int]$MonitorSeconds,
    [int]$LaunchAfterSeconds
)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$directory = [IO.Path]::GetFullPath($EvidenceDirectory)
$jsonl = Join-Path $directory 'monitor.jsonl'
function Get-UnixMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

if ($Monitor) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ConsoleWindowProbe {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    public static List<object[]> Visible() {
        var found = new List<object[]>();
        EnumWindows((hwnd, unused) => {
            if (!IsWindowVisible(hwnd)) return true;
            var name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            string windowClass = name.ToString();
            if (windowClass != "ConsoleWindowClass" && windowClass != "CASCADIA_HOSTING_WINDOW_CLASS" && windowClass != "PseudoConsoleWindow") return true;
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            found.Add(new object[] { hwnd.ToInt64(), (int)pid, windowClass, IsIconic(hwnd) });
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
    function Write-Event([hashtable]$Record) {
        $Record.ms = Get-UnixMs
        [IO.File]::AppendAllText($jsonl, (($Record | ConvertTo-Json -Compress) + "`n"), $utf8)
    }
    $seen = @{}
    foreach ($window in [ConsoleWindowProbe]::Visible()) { $seen["w$($window[0])"] = $true }
    foreach ($process in @(Get-Process -Name WindowsTerminal, OpenConsole -ErrorAction SilentlyContinue)) { $seen["p$($process.Id)"] = $true }
    $started = [Diagnostics.Stopwatch]::StartNew()
    Write-Event @{kind='start';pid=$PID;session=(Get-Process -Id $PID).SessionId;baseline=$seen.Count}
    $launched = -not $LaunchPath
    $nextProcessCheck = 0
    while ($started.Elapsed.TotalSeconds -lt $MonitorSeconds) {
        if (-not $launched -and $started.Elapsed.TotalSeconds -ge $LaunchAfterSeconds) {
            $launched = $true
            try { Start-Process -FilePath $LaunchPath; Write-Event @{kind='trigger';target='launch'} }
            catch { Write-Event @{kind='trigger';target='launch';error=$_.Exception.Message} }
        }
        foreach ($window in [ConsoleWindowProbe]::Visible()) {
            if ($seen.ContainsKey("w$($window[0])")) { continue }
            $seen["w$($window[0])"] = $true
            $owner = Get-Process -Id $window[1] -ErrorAction SilentlyContinue
            Write-Event @{kind='window';pid=$window[1];class=$window[2];minimized=$window[3];process=$owner.ProcessName;path=$owner.Path}
        }
        if ($started.ElapsedMilliseconds -ge $nextProcessCheck) {
            foreach ($process in @(Get-Process -Name WindowsTerminal, OpenConsole -ErrorAction SilentlyContinue)) {
                if ($seen.ContainsKey("p$($process.Id)")) { continue }
                $seen["p$($process.Id)"] = $true
                Write-Event @{kind='terminal-process';pid=$process.Id;process=$process.ProcessName}
            }
            $nextProcessCheck = $started.ElapsedMilliseconds + 1000
        }
        Start-Sleep -Milliseconds 120
    }
    Write-Event @{kind='end'}
    exit 0
}

if (-not $directory.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'EvidenceDirectory must resolve to the D drive.' }
if (Test-Path -LiteralPath $directory) { throw "EvidenceDirectory already exists; use a new one: $directory" }
if ($LaunchPath -and -not (Test-Path -LiteralPath $LaunchPath -PathType Leaf)) { throw "LaunchPath does not exist: $LaunchPath" }
$targets = @(foreach ($label in @($StartTasks -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $taskPath = if ($label.StartsWith('\')) { $label.Substring(0, $label.LastIndexOf('\') + 1) } else { '\' }
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName (Split-Path -Leaf $label)
    [pscustomobject]@{label=$label;path=$task.TaskPath;name=$task.TaskName}
})
[void][IO.Directory]::CreateDirectory($directory)
$controlLead = 2; $controlSettle = 8; $taskSpacing = 5
$launchAfter = $controlLead + $controlSettle + $taskSpacing * $targets.Count
$watchSeconds = $launchAfter + $SettleSeconds
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$monitorTask = "zz-CodexConsoleWatch-$id-monitor"
$controlTask = "zz-CodexConsoleWatch-$id-control"
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$monitorArguments = "--headless `"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Monitor -EvidenceDirectory `"$directory`" -MonitorSeconds $watchSeconds -LaunchAfterSeconds $launchAfter"
if ($LaunchPath) { $monitorArguments += " -LaunchPath `"$([IO.Path]::GetFullPath($LaunchPath))`"" }
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds ($watchSeconds + 120))
$triggers = [Collections.Generic.List[object]]::new()
$cleanupErrors = [Collections.Generic.List[string]]::new()
$status = $null
try {
    Register-ScheduledTask -TaskPath '\' -TaskName $monitorTask -Principal $principal -Settings $settings -Action (New-ScheduledTaskAction -Execute (Join-Path ([Environment]::SystemDirectory) 'conhost.exe') -Argument $monitorArguments) | Out-Null
    Register-ScheduledTask -TaskPath '\' -TaskName $controlTask -Principal $principal -Settings $settings -Action (New-ScheduledTaskAction -Execute $pwsh -Argument '-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 2500"') | Out-Null
    Start-ScheduledTask -TaskPath '\' -TaskName $monitorTask
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $jsonl) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $jsonl)) { $status = 'monitor-not-started' }
    else {
        Start-Sleep -Seconds $controlLead
        Start-ScheduledTask -TaskPath '\' -TaskName $controlTask
        $triggers.Add([pscustomobject]@{target='control';ms=(Get-UnixMs);error=$null})
        Start-Sleep -Seconds $controlSettle
        foreach ($target in $targets) {
            $failure = $null
            try { Start-ScheduledTask -TaskPath $target.path -TaskName $target.name } catch { $failure = $_.Exception.Message }
            $triggers.Add([pscustomobject]@{target=$target.label;ms=(Get-UnixMs);error=$failure})
            Start-Sleep -Seconds $taskSpacing
        }
        $deadline = (Get-Date).AddSeconds($SettleSeconds + 60)
        while ((Get-ScheduledTask -TaskPath '\' -TaskName $monitorTask).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    }
}
finally {
    foreach ($name in $monitorTask, $controlTask) {
        try { Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false -ErrorAction Stop } catch { $cleanupErrors.Add("${name}: $($_.Exception.Message)") }
    }
}

$records = @(if (Test-Path -LiteralPath $jsonl) { Get-Content -LiteralPath $jsonl -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } })
foreach ($launch in @($records | Where-Object kind -EQ 'trigger')) { $triggers.Add([pscustomobject]@{target=$launch.target;ms=$launch.ms;error=$launch.error}) }
$ordered = @($triggers | Sort-Object ms)
$sightings = @(foreach ($record in @($records | Where-Object { $_.kind -in 'window', 'terminal-process' })) {
    $before = @($ordered | Where-Object ms -LE $record.ms)
    [ordered]@{trigger=$(if ($before.Count -gt 0) { $before[-1].target } else { 'before-control' });kind=$record.kind;class=$record.class;process=$record.process;path=$record.path;pid=$record.pid}
})
$controlSeen = @($sightings | Where-Object { $_.trigger -eq 'control' -and $_.kind -eq 'window' }).Count -gt 0
if (-not $status) {
    $status = if (-not $controlSeen) { 'control-missed' }
        elseif (@($ordered | Where-Object error).Count -gt 0) { 'trigger-failed' }
        elseif (@($sightings | Where-Object trigger -NE 'control').Count -gt 0) { 'windows-seen' }
        else { 'quiet' }
}
$tasks = @(foreach ($target in $targets) {
    $info = Get-ScheduledTaskInfo -TaskPath $target.path -TaskName $target.name
    [ordered]@{task=$target.label;state=[string](Get-ScheduledTask -TaskPath $target.path -TaskName $target.name).State;lastRunTime=$(if ($info.LastRunTime) { $info.LastRunTime.ToUniversalTime().ToString('o') });lastResult=('0x{0:X}' -f [uint32]$info.LastTaskResult)}
})
$result = [ordered]@{
    status = $status
    computer = $env:COMPUTERNAME
    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    monitorSession = @($records | Where-Object kind -EQ 'start')[0].session
    controlSeen = $controlSeen
    triggers = @($ordered)
    sightings = $sightings
    tasks = $tasks
    cleanupErrors = @($cleanupErrors)
    evidenceDirectory = $directory
}
[IO.File]::WriteAllText((Join-Path $directory 'result.json'), ($result | ConvertTo-Json -Depth 5), $utf8)
$result | ConvertTo-Json -Depth 5 -Compress
exit $(if ($status -eq 'quiet') { 0 } else { 1 })
