#Requires -Version 7.4
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/console-launch-audit-tests')
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$runRoot = [IO.Path]::GetFullPath((Join-Path $EvidenceRoot ([guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Get-ConsoleLaunchAudit.ps1'
$fixture = Join-Path $runRoot 'fixture'
$secret = 'SYNTHETIC_PRIVATE_VALUE'
$cases = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $cases.Add([pscustomobject]@{name=$Name;passed=$true}) }
    catch { $cases.Add([pscustomobject]@{name=$Name;passed=$false;reason=$_.Exception.Message}) }
}
function Assert([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
# A minimal PE32+ header; the audit reads only the optional header's Subsystem field (2 GUI, 3 console).
function New-PeImage([string]$Path, [uint16]$Subsystem) {
    $bytes = [byte[]]::new(0x200)
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
    [BitConverter]::GetBytes([uint16]0x20B).CopyTo($bytes, 0x98)
    [BitConverter]::GetBytes($Subsystem).CopyTo($bytes, 0x98 + 68)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function Write-Fixture([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Invoke-Audit([string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$entry) + $Arguments) { $psi.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($psi)
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()
    $child.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exit = $child.ExitCode; $child.Dispose()
    Assert ([string]::IsNullOrWhiteSpace($stderr)) ('audit-stderr: ' + $stderr)
    Assert (-not $stdout.Contains($secret)) 'arguments-echoed'
    [pscustomobject]@{exitCode=$exit;report=($stdout | ConvertFrom-Json -ErrorAction Stop)}
}
function Find-Entry($Report, [string]$Name) { @($Report.codexEntries | Where-Object name -EQ $Name)[0] }
function New-TaskEntry([string]$Name, [string]$Execute, [string]$Arguments, [bool]$Enabled = $true) {
    [ordered]@{source='task';name=$Name;user='fixture';execute=$Execute;arguments=$Arguments;enabled=$Enabled}
}
function New-RunEntry([string]$Name, [string]$Command) { [ordered]@{source='run';name=$Name;command=$Command;enabled=$true} }
function New-StartupEntry([string]$Name, [string]$Path) { [ordered]@{source='startup';name=$Name;path=$Path;enabled=$true} }

$tools = Join-Path $fixture 'tools'
$pwshImage = Join-Path $tools 'pwsh.exe'; New-PeImage $pwshImage 3
$pythonwImage = Join-Path $tools 'pythonw.exe'; New-PeImage $pythonwImage 2
# The real conhost.exe is a GUI-subsystem image that still opens a console window unless --headless is given.
$conhostImage = Join-Path $tools 'conhost.exe'; New-PeImage $conhostImage 2
$spacedImage = Join-Path $tools 'gui app\viewer.exe'; New-PeImage $spacedImage 2
$notPeImage = Join-Path $tools 'broken.exe'; Write-Fixture $notPeImage 'not a PE image'
# The audit judges a pythonw script by its text: starting the next argument with CREATE_NO_WINDOW hides its console.
$launcher = Join-Path $fixture 'lib\launch-hidden.py'
Write-Fixture $launcher 'import subprocess, sys; raise SystemExit(subprocess.run(sys.argv[1:], creationflags=subprocess.CREATE_NO_WINDOW).returncode)'
$plainScript = Join-Path $fixture 'lib\launch-plain.py'; Write-Fixture $plainScript 'import subprocess, sys; subprocess.run(sys.argv[1:])'
$goneLauncher = Join-Path $fixture 'gone\launch-hidden.py'
$goneTarget = Join-Path $fixture 'gone\pwsh.exe'
$batch = Join-Path $fixture 'startup\Codex run-me.cmd'; Write-Fixture $batch '@echo off'
$shortcut = Join-Path $fixture 'startup\Codex check.lnk'
$scriptArguments = "-NoProfile -WindowStyle Hidden -File `"D:\Codex\fixture.ps1`" -Token $secret"
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath = $pwshImage; $link.Arguments = $scriptArguments; $link.Save()
$systemConsole = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
$wrapped = New-TaskEntry '\CodexWrapped' $pythonwImage "-I -S -B -X utf8 `"$launcher`" `"$pwshImage`" $scriptArguments"
$headless = New-TaskEntry '\CodexHeadless' $conhostImage "--headless `"$pwshImage`" $scriptArguments"
$viewer = New-RunEntry 'HKCU\Run\CodexViewer' "$spacedImage --flag"
$thirdParty = New-RunEntry 'HKCU\Run\ThirdPartyConsole' "`"$systemConsole`" /c exit $secret"
$allPath = Join-Path $runRoot 'entries-all.json'
[IO.File]::WriteAllText($allPath, (ConvertTo-Json -Depth 4 -InputObject @(
    (New-TaskEntry '\CodexPlain' $pwshImage $scriptArguments), $wrapped,
    (New-TaskEntry '\CodexNoLauncher' $pythonwImage "-I -S -B -X utf8 `"$goneLauncher`" `"$pwshImage`" $scriptArguments"),
    (New-TaskEntry '\CodexLostTarget' $pythonwImage "-I -S -B -X utf8 `"$launcher`" `"$goneTarget`" $scriptArguments"),
    (New-TaskEntry '\CodexPlainScript' $pythonwImage "-I -S -B -X utf8 `"$plainScript`" `"$pwshImage`" $scriptArguments"),
    $headless, (New-TaskEntry '\CodexConhostWindow' $conhostImage "`"$pwshImage`" $scriptArguments"),
    (New-TaskEntry '\CodexDisabled' $pwshImage $scriptArguments $false),
    $viewer, (New-RunEntry 'HKCU\Run\CodexBroken' "`"$notPeImage`" /x"),
    (New-StartupEntry 'Startup\Codex check.lnk' $shortcut), (New-StartupEntry 'Startup\Codex run-me.cmd' $batch), $thirdParty
)), $utf8)
$cleanPath = Join-Path $runRoot 'entries-clean.json'
[IO.File]::WriteAllText($cleanPath, (ConvertTo-Json -Depth 4 -InputObject @($wrapped, $headless, $viewer, $thirdParty)), $utf8)

$all = $null
Check 'audit-reports-without-echoing-arguments' { $script:all = Invoke-Audit @('-EntriesPathForTest', $allPath) }
Check 'console-programs-without-a-hidden-wrapper-are-findings' {
    foreach ($name in '\CodexPlain', '\CodexConhostWindow', 'Startup\Codex check.lnk', 'Startup\Codex run-me.cmd') {
        Assert ((Find-Entry $all.report $name).classification -eq 'visible-console') "not-visible-console: $name"
    }
    Assert ((Find-Entry $all.report 'Startup\Codex check.lnk').image -eq $pwshImage) 'shortcut-target-not-resolved'
    Assert ($all.exitCode -eq 1 -and $all.report.status -eq 'findings') 'findings-not-signalled'
}
Check 'no-window-launcher-and-headless-conhost-are-hidden' {
    $item = Find-Entry $all.report '\CodexWrapped'
    Assert ($item.classification -eq 'hidden' -and $item.wrapper -eq 'pythonw-no-window' -and $item.target -eq $pwshImage) 'launcher-wrap-not-hidden'
    $item = Find-Entry $all.report '\CodexHeadless'
    Assert ($item.classification -eq 'hidden' -and $item.wrapper -eq 'conhost-headless' -and $item.target -eq $pwshImage) 'headless-conhost-not-hidden'
    $item = Find-Entry $all.report '\CodexPlainScript'
    Assert ($item.classification -eq 'gui' -and $null -eq $item.wrapper) 'plain-pythonw-script-counted-as-hidden'
}
Check 'missing-launcher-or-wrapped-program-is-reported' {
    $item = Find-Entry $all.report '\CodexNoLauncher'
    Assert ($item.classification -eq 'missing' -and $item.reason -eq 'script-missing') 'missing-launcher-not-reported'
    $item = Find-Entry $all.report '\CodexLostTarget'
    Assert ($item.classification -eq 'missing' -and $item.reason -eq 'target-missing') 'missing-target-not-reported'
}
Check 'unquoted-run-path-with-spaces-resolves' {
    $item = Find-Entry $all.report 'HKCU\Run\CodexViewer'
    Assert ($item.classification -eq 'gui' -and $item.image -eq $spacedImage) ('spaced-path-misparsed: ' + $item.image)
}
Check 'unreadable-image-is-a-finding' {
    $item = Find-Entry $all.report 'HKCU\Run\CodexBroken'
    Assert ($item.classification -eq 'unknown' -and $item.reason -eq 'not-pe') 'non-pe-image-classified'
    Assert ($all.report.findings -eq 7) ('finding-count-' + $all.report.findings)
}
Check 'disabled-entries-are-counted-not-classified' {
    Assert ($null -eq (Find-Entry $all.report '\CodexDisabled')) 'disabled-entry-classified'
    Assert ($all.report.skippedDisabled.task -eq 1 -and $all.report.checked.task -eq 7) 'disabled-entry-not-counted'
}
Check 'other-console-entries-are-information-only' {
    $clean = Invoke-Audit @('-EntriesPathForTest', $cleanPath)
    Assert ($clean.exitCode -eq 0 -and $clean.report.status -eq 'clean' -and $clean.report.findings -eq 0) 'third-party-entry-failed-audit'
    $other = @($clean.report.otherVisibleConsole)
    Assert ($other.Count -eq 1 -and $other[0].name -eq 'HKCU\Run\ThirdPartyConsole' -and $null -eq (Find-Entry $clean.report 'HKCU\Run\ThirdPartyConsole')) 'third-party-entry-misfiled'
}
# Without the seam: a real Interactive task (no trigger, never runs) must come back through the production collectors.
Check 'live-audit-reads-registered-interactive-tasks' {
    $probe = 'zz-CodexConsoleAuditProbe-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath '\' -TaskName $probe -Action (New-ScheduledTaskAction -Execute $pwshImage -Argument $scriptArguments) -Principal $principal | Out-Null
    try {
        $live = Invoke-Audit @()
        $item = Find-Entry $live.report ('\' + $probe)
        Assert ($null -ne $item -and $item.classification -eq 'visible-console' -and $item.image -eq $pwshImage) 'registered-task-not-audited'
        Assert ($live.exitCode -eq 1 -and $live.report.status -eq 'findings') 'live-finding-not-signalled'
        Assert ($live.report.checked.run -ge 0 -and $live.report.checked.startup -ge 0) 'live-sources-not-reported'
    }
    finally { Unregister-ScheduledTask -TaskPath '\' -TaskName $probe -Confirm:$false }
}
$report = [pscustomobject]@{passed=(@($cases | Where-Object { -not $_.passed }).Count -eq 0);cases=@($cases);runRoot=$runRoot}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot 'result.json') -Encoding utf8
$report | ConvertTo-Json -Depth 6 -Compress
if (-not $report.passed) { exit 1 }
