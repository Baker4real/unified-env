#Requires -Version 7.4
<#
.SYNOPSIS
List the scheduled tasks and logon entries that open a console window when they start. Reads only.

.DESCRIPTION
Reads the scheduled tasks that run in a user's session (logon type Interactive, InteractiveOrPassword or Group), the
HKCU and HKLM Run and RunOnce keys (WOW6432Node included) and the per-user and common Startup folders. Disabled tasks
and logon entries that Task Manager disabled (StartupApproved value with an odd first byte) are counted, not classified.

Each entry's program is classified:
  hidden           pythonw.exe running a script that starts the program named after it with CREATE_NO_WINDOW (judged
                   from the script's text; the managed hidden console launcher has this form), or
                   conhost.exe --headless; the program it starts must exist
  gui              a GUI-subsystem image, a script that Windows Script Host runs, or pythonw.exe running any other
                   script (consoles that script opens later are not visible here; Watch-ConsoleWindows.ps1 sees them)
  visible-console  a console-subsystem image, a .cmd or .bat file, or conhost or Windows Terminal without --headless.
                   -WindowStyle Hidden does not help: when Windows Terminal hosts the console, its window still opens
  missing          the program, the script pythonw.exe runs, or the program a hidden wrapper starts does not exist
  unknown          the image could not be read as PE
An entry is Codex-owned when a part of its name starts with Codex, or its program or arguments name a path under
D:\Codex\ or D:\agents\. Every Codex-owned entry is listed, findings first. Other entries are listed only when they
open a visible console, as information: change another owner's launch method only after confirming who owns it.

Prints one JSON report; arguments are never printed. Exit 0 when no Codex-owned entry is visible-console, missing or
unknown, 1 otherwise. Under SSH, HKCU and the per-user Startup folder are those of the SSH account.

.PARAMETER EntriesPathForTest
JSON array of collected entries to classify instead of reading this machine (test seam).

.EXAMPLE
& 'D:/Codex/.codex/scripts/Get-ConsoleLaunchAudit.ps1'
#>
[CmdletBinding()]
param([string]$EntriesPathForTest)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$ownedPathPattern = '(?i)(?<![a-z])D:[\\/](Codex|agents)[\\/]'
$terminalHosts = @('conhost.exe', 'wt.exe', 'windowsterminal.exe')
$findingClasses = @('visible-console', 'missing', 'unknown')
$listLimit = 60
$approvedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$runSources = @(
    @{label='HKCU\Run';key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';approved="HKCU:\$approvedRoot\Run"},
    @{label='HKCU\RunOnce';key='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce';approved=$null},
    @{label='HKLM\Run';key='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';approved="HKLM:\$approvedRoot\Run"},
    @{label='HKLM\RunOnce';key='HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce';approved=$null},
    @{label='HKLM\WOW6432Node\Run';key='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';approved="HKLM:\$approvedRoot\Run32"},
    @{label='HKLM\WOW6432Node\RunOnce';key='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce';approved=$null}
)

# Double quotes group text that contains spaces; the launch lines audited here do not use backslash escapes.
function Split-Arguments([string]$Text) {
    $tokens = [Collections.Generic.List[string]]::new()
    $current = [Text.StringBuilder]::new()
    $quoted = $false; $pending = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($character -eq '"') { $quoted = -not $quoted; $pending = $true }
        elseif ([char]::IsWhiteSpace($character) -and -not $quoted) {
            if ($pending) { $tokens.Add($current.ToString()); [void]$current.Clear(); $pending = $false }
        }
        else { [void]$current.Append($character); $pending = $true }
    }
    if ($pending) { $tokens.Add($current.ToString()) }
    ,$tokens.ToArray()
}

function Resolve-Program([string]$Text) {
    $path = [Environment]::ExpandEnvironmentVariables($Text).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    if ([IO.Path]::IsPathRooted($path)) {
        foreach ($candidate in @($path, "$path.exe")) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
        }
        return $null
    }
    $command = Get-Command -Name $path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $command.Source } else { $null }
}

# A Run value is a command line. Like CreateProcess, an unquoted program path with spaces is found by trying each
# space-separated prefix in turn.
function Split-CommandLine([string]$Text) {
    $line = [Environment]::ExpandEnvironmentVariables($Text).Trim()
    if ($line.StartsWith('"')) {
        $end = $line.IndexOf('"', 1)
        if ($end -lt 0) { return @{image=$line.Trim('"');arguments=''} }
        return @{image=$line.Substring(1, $end - 1);arguments=$line.Substring($end + 1).Trim()}
    }
    $parts = $line -split ' '
    for ($count = 1; $count -le $parts.Count; $count++) {
        $candidate = $parts[0..($count - 1)] -join ' '
        if ([IO.Path]::IsPathRooted($candidate) -and ((Test-Path -LiteralPath $candidate -PathType Leaf) -or (Test-Path -LiteralPath "$candidate.exe" -PathType Leaf))) {
            return @{image=$candidate;arguments=(@($parts | Select-Object -Skip $count) -join ' ')}
        }
    }
    @{image=$parts[0];arguments=(@($parts | Select-Object -Skip 1) -join ' ')}
}

function Get-PeSubsystem([string]$Path) {
    $buffer = [byte[]]::new(4096)
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { $read = $stream.ReadAtLeast($buffer, $buffer.Length, $false) } finally { $stream.Dispose() }
    }
    catch { return 'unreadable' }
    if ($read -lt 0x40 -or $buffer[0] -ne 0x4D -or $buffer[1] -ne 0x5A) { return 'not-pe' }
    $header = [BitConverter]::ToInt32($buffer, 0x3C)
    if ($header -lt 0 -or $header + 24 + 70 -gt $read -or [BitConverter]::ToUInt32($buffer, $header) -ne 0x4550) { return 'not-pe' }
    if ([BitConverter]::ToUInt16($buffer, $header + 24) -notin 0x10B, 0x20B) { return 'not-pe' }
    switch ([BitConverter]::ToUInt16($buffer, $header + 24 + 68)) { 2 { 'gui' } 3 { 'console' } default { 'other-subsystem' } }
}

function Get-Classification([string]$Image, [string]$Arguments) {
    $result = [ordered]@{classification=$null;image=$Image}
    $resolved = Resolve-Program $Image
    if (-not $resolved) { $result.classification = 'missing'; $result.reason = 'program-missing'; return $result }
    $result.image = $resolved
    $tokens = Split-Arguments ([Environment]::ExpandEnvironmentVariables($Arguments))
    $leaf = [IO.Path]::GetFileName($resolved).ToLowerInvariant()
    $wrapperAt = -1
    if ($leaf -eq 'pythonw.exe') {
        $scriptAt = -1
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if ([IO.Path]::GetExtension($tokens[$i]) -ieq '.py') { $scriptAt = $i; break }
        }
        if ($scriptAt -ge 0) {
            if (-not (Test-Path -LiteralPath $tokens[$scriptAt] -PathType Leaf)) { $result.classification = 'missing'; $result.reason = 'script-missing'; return $result }
            $startsProgram = $scriptAt + 1 -lt $tokens.Count -and -not $tokens[$scriptAt + 1].StartsWith('-')
            if ($startsProgram -and (Get-Content -LiteralPath $tokens[$scriptAt] -Raw) -match 'CREATE_NO_WINDOW') { $wrapperAt = $scriptAt; $result.wrapper = 'pythonw-no-window' }
        }
    }
    elseif ($leaf -eq 'conhost.exe' -and $tokens.Count -gt 0 -and $tokens[0] -ieq '--headless') { $wrapperAt = 0; $result.wrapper = 'conhost-headless' }
    if ($wrapperAt -ge 0) {
        $target = if ($wrapperAt + 1 -lt $tokens.Count) { Resolve-Program $tokens[$wrapperAt + 1] }
        if (-not $target) { $result.classification = 'missing'; $result.reason = 'target-missing'; return $result }
        $result.target = $target; $result.classification = 'hidden'; return $result
    }
    if ($leaf -in $terminalHosts) { $result.classification = 'visible-console'; $result.reason = 'terminal-window'; return $result }
    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($extension -in '.cmd', '.bat') { $result.classification = 'visible-console'; $result.reason = 'batch-file'; return $result }
    if ($extension -in '.vbs', '.vbe', '.js', '.jse', '.wsf') { $result.classification = 'gui'; $result.reason = 'windows-script-host'; return $result }
    $subsystem = Get-PeSubsystem $resolved
    switch ($subsystem) {
        'gui' { $result.classification = 'gui' }
        'console' { $result.classification = 'visible-console' }
        default { $result.classification = 'unknown'; $result.reason = $subsystem }
    }
    $result
}

function Test-StartupDisabled([string]$ApprovedKey, [string]$Name) {
    if (-not $ApprovedKey -or -not (Test-Path -LiteralPath $ApprovedKey)) { return $false }
    $value = (Get-Item -LiteralPath $ApprovedKey).GetValue($Name)
    # Task Manager writes an even first byte for an enabled entry and an odd one for a disabled entry.
    $value -is [byte[]] -and $value.Length -gt 0 -and ($value[0] -band 1) -eq 1
}

function Get-TaskEntries {
    foreach ($task in @(Get-ScheduledTask)) {
        if ([string]$task.Principal.LogonType -notin 'Interactive', 'InteractiveOrPassword', 'Group') { continue }
        $actions = @($task.Actions | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskExecAction' })
        for ($i = 0; $i -lt $actions.Count; $i++) {
            [pscustomobject]@{
                source = 'task'
                name = $task.TaskPath + $task.TaskName + $(if ($actions.Count -gt 1) { " #$($i + 1)" })
                user = if ($task.Principal.UserId) { $task.Principal.UserId } else { $task.Principal.GroupId }
                execute = $actions[$i].Execute
                arguments = $actions[$i].Arguments
                enabled = [string]$task.State -ne 'Disabled'
            }
        }
    }
}

function Get-RunEntries {
    foreach ($source in $runSources) {
        if (-not (Test-Path -LiteralPath $source.key)) { continue }
        $key = Get-Item -LiteralPath $source.key
        foreach ($name in $key.GetValueNames()) {
            if ($name -eq '') { continue }
            [pscustomobject]@{source='run';name="$($source.label)\$name";command=[string]$key.GetValue($name);enabled=-not (Test-StartupDisabled $source.approved $name)}
        }
    }
}

function Get-StartupEntries {
    foreach ($folder in @(
        @{label='Startup';path=[Environment]::GetFolderPath('Startup');approved="HKCU:\$approvedRoot\StartupFolder"},
        @{label='CommonStartup';path=[Environment]::GetFolderPath('CommonStartup');approved="HKLM:\$approvedRoot\StartupFolder"}
    )) {
        if (-not $folder.path -or -not (Test-Path -LiteralPath $folder.path)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder.path -File -Force)) {
            if ($file.Name -ieq 'desktop.ini') { continue }
            [pscustomobject]@{source='startup';name="$($folder.label)\$($file.Name)";path=$file.FullName;enabled=-not (Test-StartupDisabled $folder.approved $file.Name)}
        }
    }
}

$collected = @(
    if ($EntriesPathForTest) { Get-Content -LiteralPath $EntriesPathForTest -Raw -Encoding utf8 | ConvertFrom-Json }
    else { Get-TaskEntries; Get-RunEntries; Get-StartupEntries }
)
$checked = [ordered]@{task=0;run=0;startup=0}
$skipped = [ordered]@{task=0;run=0;startup=0}
$codexFindings = [Collections.Generic.List[object]]::new()
$codexOthers = [Collections.Generic.List[object]]::new()
$otherVisible = [Collections.Generic.List[object]]::new()
$shell = $null
foreach ($raw in $collected) {
    if (-not $raw.enabled) { $skipped[$raw.source]++; continue }
    $checked[$raw.source]++
    switch ($raw.source) {
        'task' { $image = $raw.execute; $arguments = $raw.arguments }
        'run' { $parts = Split-CommandLine $raw.command; $image = $parts.image; $arguments = $parts.arguments }
        'startup' {
            if ([IO.Path]::GetExtension($raw.path) -ieq '.lnk') {
                if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                $link = $shell.CreateShortcut($raw.path)
                $image = $link.TargetPath; $arguments = $link.Arguments
            }
            else { $image = $raw.path; $arguments = '' }
        }
    }
    $item = [ordered]@{source=$raw.source;name=$raw.name}
    if ($raw.user) { $item.user = $raw.user }
    $classified = Get-Classification $image $arguments
    foreach ($key in $classified.Keys) { $item[$key] = $classified[$key] }
    $owned = $raw.name -match '(?i)(^|\\)codex' -or "$image $arguments $($classified.target)" -match $ownedPathPattern
    if (-not $owned) { if ($item.classification -eq 'visible-console') { $otherVisible.Add($item) } }
    elseif ($item.classification -in $findingClasses) { $codexFindings.Add($item) }
    else { $codexOthers.Add($item) }
}
$codexEntries = @($codexFindings) + @($codexOthers)
[ordered]@{
    status = if ($codexFindings.Count -gt 0) { 'findings' } else { 'clean' }
    findings = $codexFindings.Count
    computer = $env:COMPUTERNAME
    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    checked = $checked
    skippedDisabled = $skipped
    codexEntries = @($codexEntries | Select-Object -First $listLimit)
    codexEntriesOmitted = [Math]::Max(0, $codexEntries.Count - $listLimit)
    otherVisibleConsole = @($otherVisible | Select-Object -First $listLimit)
    otherVisibleConsoleOmitted = [Math]::Max(0, $otherVisible.Count - $listLimit)
} | ConvertTo-Json -Depth 5 -Compress
exit $(if ($codexFindings.Count -gt 0) { 1 } else { 0 })
