#requires -Version 7.5
# Shared implementation for the three supported Explorer recovery entry points.
# TestSessionPath is a narrow OS boundary: an owned, expiring child of this exact
# caller. It cannot select an executable, supply code, or control another session.
Set-StrictMode -Version Latest

function Initialize-ExplorerRecoveryNative {
    if (-not $IsWindows -or $PSVersionTable.PSEdition -ne 'Core') { throw 'Windows PowerShell Core 7.5 or later is required.' }
    if ('ExplorerRecovery.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
namespace ExplorerRecovery {
    public class WindowState {
        public uint ShellId;
        public int Enumerated, Taskbars, VisibleTaskbars, ResponsiveTaskbars;
        public int Desktops, ResponsiveDesktops, FolderWindows, VisibleFileOperations, VisibleShellDialogs;
        public bool Complete = true;
    }
    public static class Native {
        private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr data);
        [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int size);
        [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wp, IntPtr lp, uint flags, uint timeout, out UIntPtr result);
        [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        public static uint ShellId() { uint id; GetWindowThreadProcessId(GetShellWindow(), out id); return id; }
        public static string OwnerSid(Process process) {
            IntPtr token;
            if (!OpenProcessToken(process.Handle, 8, out token)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try { using (var identity = new WindowsIdentity(token)) { return identity.User.Value; } }
            finally { CloseHandle(token); }
        }
        public static WindowState Snapshot() {
            var state = new WindowState();
            var shell = GetShellWindow();
            state.ShellId = ShellId();
            var timer = Stopwatch.StartNew();
            bool enumerated = EnumWindows((hwnd, unused) => {
                if (++state.Enumerated > 1024 || timer.ElapsedMilliseconds > 2000) { state.Complete = false; return false; }
                var name = new StringBuilder(128); GetClassName(hwnd, name, name.Capacity);
                string cls = name.ToString();
                uint owner; GetWindowThreadProcessId(hwnd, out owner);
                bool visible = IsWindowVisible(hwnd);
                if (cls == "CabinetWClass" || cls == "ExploreWClass") state.FolderWindows++;
                if (visible && cls == "OperationStatusWindow") state.VisibleFileOperations++;
                if (visible && owner == state.ShellId && cls == "#32770") state.VisibleShellDialogs++;
                if (owner == state.ShellId && cls == "Shell_TrayWnd") {
                    state.Taskbars++;
                    if (visible) {
                        state.VisibleTaskbars++;
                        UIntPtr result;
                        if (SendMessageTimeout(hwnd, 0, UIntPtr.Zero, IntPtr.Zero, 2, 100, out result) != IntPtr.Zero) state.ResponsiveTaskbars++;
                    }
                }
                if (hwnd == shell) {
                    state.Desktops++;
                    UIntPtr result;
                    if (SendMessageTimeout(hwnd, 0, UIntPtr.Zero, IntPtr.Zero, 2, 100, out result) != IntPtr.Zero) state.ResponsiveDesktops++;
                }
                return true;
            }, IntPtr.Zero);
            if (!enumerated) state.Complete = false;
            return state;
        }
    }
}
'@
}

function Get-ExplorerRecoveryIdentity {
    param([Parameter(Mandatory)][int]$TargetId)
    Initialize-ExplorerRecoveryNative
    $process = Get-Process -Id $TargetId -ErrorAction Stop
    try {
        [void]$process.Handle
        if ([string]::IsNullOrWhiteSpace([string]$process.Path)) { throw 'ProcessPathUnavailable' }
        [pscustomobject][ordered]@{
            Id = [int]$process.Id
            StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            StartTimeTicks = $process.StartTime.ToUniversalTime().Ticks.ToString()
            ExePath = [string]$process.Path
            SessionId = [int]$process.SessionId
            UserSid = [ExplorerRecovery.Native]::OwnerSid($process)
        }
    }
    finally { $process.Dispose() }
}

function Test-ExplorerRecoveryIdentity {
    param($Expected, $Actual)
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    return ($Expected.Id -eq $Actual.Id -and
        [string]$Expected.StartTimeTicks -ceq [string]$Actual.StartTimeTicks -and
        [string]$Expected.ExePath -ieq [string]$Actual.ExePath -and
        $Expected.SessionId -eq $Actual.SessionId -and $Expected.UserSid -ceq $Actual.UserSid)
}

function Get-ExplorerRecoveryContext {
    $self = Get-ExplorerRecoveryIdentity -TargetId $PID
    [pscustomobject][ordered]@{ MachineName = [Environment]::MachineName; SessionId = $self.SessionId; UserSid = $self.UserSid }
}

function Get-ExplorerRecoveryMutexName {
    param([Parameter(Mandatory)]$Context)
    $sidHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Context.UserSid)))
    'Local\CodexExplorerRecovery-' + $Context.SessionId + '-' + $sidHash
}

function Write-ExplorerRecoveryJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must be written to a real D: path.' }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $json = ConvertTo-Json -InputObject $Value -Depth 15
    [IO.File]::WriteAllText($fullPath, $json, [Text.UTF8Encoding]::new($false))
}

function Read-ExplorerRecoveryJson {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt 131072) { throw 'Recovery JSON exceeds the 128 KiB limit.' }
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String -ErrorAction Stop
}

function Get-ExplorerRecoveryPins {
    $entries = [Collections.Generic.List[string]]::new()
    $complete = $true
    $failure = $null
    $shortcutCount = 0
    try {
        $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband', $false)
        try {
            foreach ($name in @('Favorites','FavoritesResolve')) {
                $value = $null
                if ($registry) { $value = $registry.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
                if ($null -eq $value) { $entries.Add("registry:$name=missing") }
                elseif ($value -is [byte[]]) { $entries.Add("registry:$name=" + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($value))) }
                else { throw 'UnexpectedTaskbandValueType' }
            }
        }
        finally { if ($registry) { $registry.Dispose() } }
        $pinDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar'
        if (Test-Path -LiteralPath $pinDirectory) {
            $files = @(Get-ChildItem -LiteralPath $pinDirectory -File -Force -ErrorAction Stop | Sort-Object Name)
            if ($files.Count -gt 256) { throw 'PinnedItemLimitExceeded' }
            $total = 0L
            foreach ($file in $files) {
                $total += $file.Length
                if ($file.Length -gt 4MB -or $total -gt 16MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'PinnedItemReadLimitExceeded' }
                $nameHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($file.Name)))
                $entries.Add('file:' + $nameHash + '=' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
                $shortcutCount++
            }
        }
        else { $entries.Add('shortcut-directory=missing') }
    }
    catch {
        $complete = $false
        $failure = if ($_.Exception.Message -in @('UnexpectedTaskbandValueType','PinnedItemLimitExceeded','PinnedItemReadLimitExceeded')) { $_.Exception.Message } else { $_.Exception.GetType().Name }
    }
    $hash = if ($complete) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))) } else { $null }
    [pscustomobject][ordered]@{ Complete = $complete; Sha256 = $hash; ShortcutCount = $shortcutCount; Failure = $failure }
}

function Read-ExplorerRecoveryTestSession {
    param([Parameter(Mandatory)][string]$SessionPath)
    $session = Read-ExplorerRecoveryJson -Path $SessionPath
    $token = [Environment]::GetEnvironmentVariable('CODEX_EXPLORER_TEST_TOKEN')
    if (-not $token) { throw 'MissingTestOwnershipToken' }
    $tokenHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($token)))
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($session.IssuedAtUtc)).TotalSeconds
    if ($session.Kind -cne 'OwnedExplorerRecoveryTest' -or $session.OwnerTokenSha256 -cne $tokenHash -or $age -lt 0 -or $age -gt 300 -or
        -not (Test-ExplorerRecoveryIdentity -Expected $session.Owner -Actual (Get-ExplorerRecoveryIdentity -TargetId $PID))) { throw 'TestOwnershipMismatch' }
    return $session
}

function Start-ExplorerRecoveryTestProcess {
    param([Parameter(Mandatory)][string]$SessionPath)
    $session = Read-ExplorerRecoveryTestSession -SessionPath $SessionPath
    if ($session.FailStartsRemaining -gt 0) {
        $session.FailStartsRemaining--
        Write-ExplorerRecoveryJson -Path $SessionPath -Value $session
        throw [ComponentModel.Win32Exception]::new(2, 'InjectedTestProcessCreationFailure')
    }
    $generation = [guid]::NewGuid().ToString('N')
    $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SessionPath))
    $reportPath = Join-Path $root ($generation + '-handshake.json')
    $stopPath = Join-Path $root ($generation + '-stop.txt')
    $intent = [pscustomobject][ordered]@{
        Generation = $generation; IssuedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        OwnershipMode = 'task-scoped'; OwnerTokenSha256 = $session.OwnerTokenSha256
        ExePath = $session.Owner.ExePath; Arguments = @('-NoProfile','-NonInteractive','-File','Test-ExplorerShellRecovery.ps1','-Worker')
        Cwd = $root; Scope = 'one owned test child'; Readiness = 'matching token and process identity handshake'
        ReadinessTimeoutSeconds = 8; ExpectedExitCode = 0; MaximumLifetimeSeconds = 90
        ReportPath = $reportPath; StopPath = $stopPath; Identity = $null; ProcessState = 'launch_intent'; ExitCode = $null
    }
    $session.Children = @($session.Children) + @($intent)
    Write-ExplorerRecoveryJson -Path $SessionPath -Value $session
    $info = [Diagnostics.ProcessStartInfo]::new([string]$session.Owner.ExePath)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.WorkingDirectory = $root
    foreach ($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot '../Test-ExplorerShellRecovery.ps1'),'-Worker')) { $info.ArgumentList.Add($arg) }
    $info.Environment['CODEX_EXPLORER_TEST_TOKEN'] = [Environment]::GetEnvironmentVariable('CODEX_EXPLORER_TEST_TOKEN')
    $info.Environment['CODEX_EXPLORER_TEST_REPORT'] = $reportPath
    $info.Environment['CODEX_EXPLORER_TEST_STOP'] = $stopPath
    $child = [Diagnostics.Process]::Start($info)
    $intent | Add-Member -NotePropertyName CreatedProcessId -NotePropertyValue $child.Id
    $intent.ProcessState = 'awaiting_handshake'
    Write-ExplorerRecoveryJson -Path $SessionPath -Value $session
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $reportPath) -and -not $child.HasExited -and $timer.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $reportPath)) { throw [InvalidOperationException]::new('TestChildHandshakeTimeout; no ownership-based stop is permitted without its handshake.') }
    $report = Read-ExplorerRecoveryJson -Path $reportPath
    $intent.Identity = Get-ExplorerRecoveryIdentity -TargetId $child.Id
    if ($report.OwnerTokenSha256 -cne $session.OwnerTokenSha256 -or $report.ParentId -ne $PID -or $report.Id -ne $child.Id -or
        $report.StartTimeTicks -cne $intent.Identity.StartTimeTicks -or $report.ExePath -ine $intent.Identity.ExePath) { throw 'TestChildHandshakeMismatch' }
    $intent.ProcessState = 'running'
    $session.CurrentGeneration = $generation
    Write-ExplorerRecoveryJson -Path $SessionPath -Value $session
    $child.Dispose()
}

function Initialize-ExplorerRecoveryTestSession {
    param([Parameter(Mandatory)][string]$SessionPath)
    $token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    [Environment]::SetEnvironmentVariable('CODEX_EXPLORER_TEST_TOKEN', $token)
    $session = [ordered]@{
        SchemaVersion = 1; Kind = 'OwnedExplorerRecoveryTest'; IssuedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        OwnerTokenSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($token)))
        TokenChannel = 'child process environment only'; Owner = Get-ExplorerRecoveryIdentity -TargetId $PID
        CurrentGeneration = $null; Children = @(); Ready = $true; DesktopResponding = $true; FailStartsRemaining = 0
        FolderWindows = 0; VisibleFileOperations = 0
    }
    Write-ExplorerRecoveryJson -Path $SessionPath -Value $session
    Start-ExplorerRecoveryTestProcess -SessionPath $SessionPath
}

function Stop-ExplorerRecoveryTestChild {
    param([Parameter(Mandatory)][string]$SessionPath, [Parameter(Mandatory)]$ExpectedIdentity)
    $session = Read-ExplorerRecoveryTestSession -SessionPath $SessionPath
    $matches = @($session.Children | Where-Object { Test-ExplorerRecoveryIdentity -Expected $_.Identity -Actual $ExpectedIdentity })
    if ($matches.Count -ne 1) { throw 'TestChildOwnershipMissing' }
    $child = $matches[0]
    $report = Read-ExplorerRecoveryJson -Path $child.ReportPath
    $process = Get-Process -Id $ExpectedIdentity.Id -ErrorAction Stop
    try {
        [void]$process.Handle
        $actual = Get-ExplorerRecoveryIdentity -TargetId $ExpectedIdentity.Id
        $parent = (Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $ExpectedIdentity.Id)).ParentProcessId
        if (-not (Test-ExplorerRecoveryIdentity -Expected $ExpectedIdentity -Actual $actual) -or
            $report.OwnerTokenSha256 -cne $session.OwnerTokenSha256 -or $report.ParentId -ne $PID -or $parent -ne $PID -or
            $report.Id -ne $actual.Id -or $report.StartTimeTicks -cne $actual.StartTimeTicks -or $report.ExePath -ine $actual.ExePath) { throw 'TestChildOwnershipMismatch' }
        [IO.File]::WriteAllText($child.StopPath, $session.OwnerTokenSha256)
        if (-not $process.WaitForExit(2000)) {
            if (-not (Test-ExplorerRecoveryIdentity -Expected $ExpectedIdentity -Actual (Get-ExplorerRecoveryIdentity -TargetId $ExpectedIdentity.Id))) { throw 'TestChildIdentityChangedBeforeEscalation' }
            $process.Kill()
            if (-not $process.WaitForExit(2000)) { throw 'TestChildStopTimeout' }
            $child.ProcessState = 'stopped'; $child.ExitCode = $process.ExitCode
        }
        else { $child.ProcessState = 'exited'; $child.ExitCode = $process.ExitCode }
        Write-ExplorerRecoveryJson -Path $SessionPath -Value $session
        if ($child.ExitCode -ne 0) { throw 'TestChildUnexpectedExitCode' }
    }
    finally { $process.Dispose() }
}

function Close-ExplorerRecoveryTestSession {
    param([Parameter(Mandatory)][string]$SessionPath)
    if (-not (Test-Path -LiteralPath $SessionPath)) { return }
    $session = Read-ExplorerRecoveryTestSession -SessionPath $SessionPath
    foreach ($child in $session.Children) {
        if ($null -eq $child.Identity) { continue }
        $existing = Get-Process -Id $child.Identity.Id -ErrorAction SilentlyContinue
        if ($existing) { $existing.Dispose(); Stop-ExplorerRecoveryTestChild -SessionPath $SessionPath -ExpectedIdentity $child.Identity }
        elseif ($child.ProcessState -notin @('exited','stopped')) { throw 'TestChildExitedWithoutVerifiedExitCode' }
    }
}

function Get-ExplorerRecoverySnapshot {
    param([string]$TestSessionPath)
    $context = Get-ExplorerRecoveryContext
    if ($TestSessionPath) {
        $session = Read-ExplorerRecoveryTestSession -SessionPath $TestSessionPath
        $child = @($session.Children | Where-Object Generation -eq $session.CurrentGeneration)[0]
        $identity = $null
        $alive = Get-Process -Id $child.Identity.Id -ErrorAction SilentlyContinue
        if ($alive) { $alive.Dispose(); $identity = Get-ExplorerRecoveryIdentity -TargetId $child.Identity.Id }
        $ready = $null -ne $identity -and $session.Ready
        $desktopResponding = $ready -and $session.DesktopResponding
        $windows = [pscustomobject][ordered]@{
            Complete = $true; Enumerated = 0; Taskbars = [int]$ready; VisibleTaskbars = [int]$ready; ResponsiveTaskbars = [int]$ready
            Desktops = [int]$ready; ResponsiveDesktops = [int]$desktopResponding; FolderWindows = $session.FolderWindows
            VisibleFileOperations = $session.VisibleFileOperations; VisibleShellDialogs = 0
        }
        $pins = [pscustomobject][ordered]@{ Complete = $true; Sha256 = ('A' * 64); ShortcutCount = 0; Failure = $null }
        $kind = 'OwnedExplorerRecoveryTest'
        $ready = $ready -and $desktopResponding
    }
    else {
        Initialize-ExplorerRecoveryNative
        $windows = [ExplorerRecovery.Native]::Snapshot()
        $identity = $null
        if ($windows.ShellId -ne 0) {
            try { $identity = Get-ExplorerRecoveryIdentity -TargetId $windows.ShellId }
            catch { $windows.Complete = $false }
        }
        if ([ExplorerRecovery.Native]::ShellId() -ne $windows.ShellId) { $windows.Complete = $false }
        $pins = Get-ExplorerRecoveryPins
        $kind = 'ExplorerShell'
        $ready = $null -ne $identity -and $windows.Complete -and $windows.ResponsiveTaskbars -gt 0 -and $windows.ResponsiveDesktops -gt 0
    }
    [pscustomobject][ordered]@{
        SchemaVersion = 1; Kind = $kind; ObservedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        OwnershipMode = 'observe-only'; Context = $context; ShellProcess = $identity; Windows = $windows; Pins = $pins
        Complete = [bool]($windows.Complete -and $pins.Complete); DesktopAndTaskbarReady = [bool]$ready
        Privacy = 'Counts and aggregate hashes only; no titles, shortcut names, or shortcut targets.'
    }
}

function New-ExplorerRecoveryPlan {
    param([string]$TestSessionPath, [ValidateRange(5,60)][int]$ReadinessTimeoutSeconds = 20)
    $created = [DateTimeOffset]::UtcNow
    $snapshot = Get-ExplorerRecoverySnapshot -TestSessionPath $TestSessionPath
    [pscustomobject][ordered]@{
        SchemaVersion = 1; PlanId = [guid]::NewGuid().ToString('N'); Mode = 'Plan'; ReadOnly = $true
        CreatedAtUtc = $created.ToString('o'); ExpiresAtUtc = $created.AddSeconds(120).ToString('o')
        Snapshot = $snapshot; MaximumAgeSeconds = 120
        ConcurrencyLockName = Get-ExplorerRecoveryMutexName -Context $snapshot.Context
        RecoveryBudget = [pscustomobject]@{ AutoRestartGraceSeconds = $(if ($TestSessionPath) { 0.1 } else { 2 }); ReadinessTimeoutSeconds = $ReadinessTimeoutSeconds; MaximumLaunchAttempts = 2 }
        Action = 'Recheck identity, session, windows and pinned items; restart only the verified shell; verify new desktop and taskbar.'
        VisualIconAcceptance = 'Requires user observation; window readiness cannot prove icon appearance.'
    }
}

function Get-ExplorerRecoveryRefusal {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Current, [string]$TestSessionPath)
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($Plan.CreatedAtUtc)).TotalSeconds
    if ($age -lt 0 -or $age -gt 120 -or [DateTimeOffset]::UtcNow -gt [DateTimeOffset]::Parse($Plan.ExpiresAtUtc)) { return 'PlanExpired' }
    if ($Plan.SchemaVersion -ne 1 -or $Plan.Mode -ne 'Plan' -or $Plan.Snapshot.Kind -cne $Current.Kind) { return 'PlanTypeMismatch' }
    if ($Plan.RecoveryBudget.ReadinessTimeoutSeconds -lt 5 -or $Plan.RecoveryBudget.ReadinessTimeoutSeconds -gt 60) { return 'InvalidRecoveryBudget' }
    $expectedGrace = if ($TestSessionPath) { 0.1 } else { 2 }
    if ($Plan.RecoveryBudget.MaximumLaunchAttempts -ne 2 -or $Plan.RecoveryBudget.AutoRestartGraceSeconds -ne $expectedGrace) { return 'InvalidRecoveryBudget' }
    if ($Plan.Snapshot.Context.MachineName -cne $Current.Context.MachineName -or $Plan.Snapshot.Context.UserSid -cne $Current.Context.UserSid -or $Plan.Snapshot.Context.SessionId -ne $Current.Context.SessionId) { return 'UserSessionChanged' }
    if (-not (Test-ExplorerRecoveryIdentity -Expected $Plan.Snapshot.ShellProcess -Actual $Current.ShellProcess)) { return 'IdentityChanged' }
    if (-not $Plan.Snapshot.Complete -or -not $Current.Complete) { return 'IncompleteSnapshot' }
    if ($Current.Windows.FolderWindows -gt 0 -or $Current.Windows.VisibleFileOperations -gt 0 -or $Current.Windows.VisibleShellDialogs -gt 0) { return 'UnsafeWindowsPresent' }
    if ($Plan.Snapshot.Pins.Sha256 -cne $Current.Pins.Sha256) { return 'PinsChanged' }
    if ($Current.ShellProcess.SessionId -ne $Current.Context.SessionId -or $Current.ShellProcess.UserSid -cne $Current.Context.UserSid) { return 'ShellUserSessionMismatch' }
    if (-not $TestSessionPath) {
        $expectedPath = Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe'
        if ($Current.ShellProcess.ExePath -ine $expectedPath) { return 'UnexpectedExplorerExecutable' }
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return 'ElevatedCallerNotSupported' }
    }
    if (-not [IO.File]::Exists([string]$Current.ShellProcess.ExePath)) { return 'ExecutableUnavailable' }
    return $null
}

function Invoke-ExplorerRecovery {
    param([Parameter(Mandatory)]$Plan, [string]$TestSessionPath, [Parameter(Mandatory)][string]$EvidenceDirectory)
    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1; Mode = 'Apply'; Status = 'refused'; Reason = $null; StopAttempted = $false
        DesktopAndTaskbarReady = $false; PinsUnchanged = $null; ProcessState = 'unchanged'; OriginalIdentity = $Plan.Snapshot.ShellProcess
        NewIdentity = $null; LaunchAttempts = @(); RecoveryMethod = $null; ElapsedSeconds = 0
        ErrorType = $null; SnapshotErrors = 0; EvidenceDirectory = $EvidenceDirectory; EvidencePersisted = $false
        VisualIconAcceptance = 'Not verified; requires user observation.'
    }
    $before = Get-ExplorerRecoverySnapshot -TestSessionPath $TestSessionPath
    $result.Reason = Get-ExplorerRecoveryRefusal -Plan $Plan -Current $before -TestSessionPath $TestSessionPath
    if ($result.Reason) {
        Write-ExplorerRecoveryJson -Path (Join-Path $EvidenceDirectory 'result.json') -Value $result
        return $result
    }
    # Freeze plain values before obtaining/stopping the live Process object.
    [string]$launchPath = $before.ShellProcess.ExePath
    [int]$targetId = $before.ShellProcess.Id
    [string]$targetStart = $before.ShellProcess.StartTimeTicks
    [string]$pinsBefore = $before.Pins.Sha256
    $intent = [ordered]@{
        PlanId = $Plan.PlanId; IssuedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); OriginalIdentity = $before.ShellProcess
        ExePath = $launchPath; Arguments = @(); Scope = 'verified shell in the current user session'
        Lifetime = $(if ($TestSessionPath) { 'task-scoped' } else { 'persistent' })
        Readiness = 'new matching shell identity with responsive taskbar and desktop; pinned-item hash unchanged'
        TimeoutSeconds = $Plan.RecoveryBudget.ReadinessTimeoutSeconds; AutoRestartGraceSeconds = $Plan.RecoveryBudget.AutoRestartGraceSeconds; MaximumLaunchAttempts = 2
        ExpectedResult = 'ready'; Before = $before
    }
    # A write failure here aborts before stop. Recovery never depends on writing after stop.
    Write-ExplorerRecoveryJson -Path (Join-Path $EvidenceDirectory 'intent.json') -Value $intent
    $last = Get-ExplorerRecoverySnapshot -TestSessionPath $TestSessionPath
    $result.Reason = Get-ExplorerRecoveryRefusal -Plan $Plan -Current $last -TestSessionPath $TestSessionPath
    if ($result.Reason) {
        Write-ExplorerRecoveryJson -Path (Join-Path $EvidenceDirectory 'result.json') -Value $result
        return $result
    }
    $heldProcess = $null
    $timer = [Diagnostics.Stopwatch]::new()
    $after = $null
    try {
        if ($TestSessionPath) {
            $result.StopAttempted = $true
            Stop-ExplorerRecoveryTestChild -SessionPath $TestSessionPath -ExpectedIdentity $before.ShellProcess
        }
        else {
            $heldProcess = Get-Process -Id $targetId -ErrorAction Stop
            [void]$heldProcess.Handle
            if ($heldProcess.StartTime.ToUniversalTime().Ticks.ToString() -cne $targetStart -or
                $heldProcess.Path -ine $launchPath -or [ExplorerRecovery.Native]::ShellId() -ne $targetId) { throw 'IdentityChangedImmediatelyBeforeStop' }
            $result.StopAttempted = $true
            $heldProcess.Kill()
            if (-not $heldProcess.WaitForExit(2500)) { throw 'OriginalShellStopTimeout' }
        }
        $result.Status = 'failed'; $result.Reason = 'ReadinessTimeout'; $result.ProcessState = 'readiness_timeout'
        $timer.Start()
        $timeout = [double]$Plan.RecoveryBudget.ReadinessTimeoutSeconds
        $grace = [double]$Plan.RecoveryBudget.AutoRestartGraceSeconds
        do {
            try { $after = Get-ExplorerRecoverySnapshot -TestSessionPath $TestSessionPath }
            catch { $result.SnapshotErrors++; $after = $null }
            if ($after -and $after.ShellProcess) {
                $candidate = $after.ShellProcess
                $isNew = -not (Test-ExplorerRecoveryIdentity -Expected $before.ShellProcess -Actual $candidate)
                $sameOwner = $candidate.ExePath -ieq $launchPath -and $candidate.SessionId -eq $before.Context.SessionId -and $candidate.UserSid -ceq $before.Context.UserSid
                if ($isNew -and $sameOwner -and $after.DesktopAndTaskbarReady -and $timer.Elapsed.TotalSeconds -lt $timeout) {
                    $result.DesktopAndTaskbarReady = $true; $result.NewIdentity = $candidate
                    $result.PinsUnchanged = $after.Pins.Complete -and $after.Pins.Sha256 -ceq $pinsBefore
                    if ($result.PinsUnchanged) {
                        $result.Status = 'ready'; $result.Reason = 'VerifiedNewShell'
                        $result.ProcessState = $(if ($TestSessionPath) { 'running_owned_test' } else { 'running_handed_off' })
                    }
                    else { $result.Reason = 'PinsChangedAfterRestart'; $result.ProcessState = 'running_with_pin_mismatch' }
                    if (-not $result.RecoveryMethod) { $result.RecoveryMethod = 'system-auto-restart' }
                    break
                }
            }
            elseif ($after -and $timer.Elapsed.TotalSeconds -ge $grace -and $timer.Elapsed.TotalSeconds -lt $timeout -and $result.LaunchAttempts.Count -lt 2 -and
                ($result.LaunchAttempts.Count -eq 0 -or $result.LaunchAttempts[-1].State -eq 'creation_failed')) {
                $attempt = [pscustomobject]@{ Number = ($result.LaunchAttempts.Count + 1); ExePath = $launchPath; State = 'attempting'; ErrorType = $null; NativeErrorCode = $null; CreatedProcessId = $null }
                $result.LaunchAttempts = @($result.LaunchAttempts) + @($attempt)
                try {
                    if ($TestSessionPath) { Start-ExplorerRecoveryTestProcess -SessionPath $TestSessionPath }
                    else {
                        $startInfo = [Diagnostics.ProcessStartInfo]::new($launchPath)
                        $startInfo.UseShellExecute = $false
                        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
                        $started = [Diagnostics.Process]::Start($startInfo)
                        if ($started) { $attempt.CreatedProcessId = $started.Id; $started.Dispose() }
                    }
                    $attempt.State = 'created'
                    $result.RecoveryMethod = $(if ($attempt.Number -eq 1) { 'explicit-launch' } else { 'retry-launch' })
                }
                catch {
                    $failure = $_.Exception.GetBaseException()
                    $attempt.ErrorType = $failure.GetType().Name
                    # Retry only a definite native process-creation failure. A
                    # created child with missing readiness is observed, not relaunched.
                    if ($failure -is [ComponentModel.Win32Exception]) {
                        $attempt.State = 'creation_failed'; $attempt.NativeErrorCode = $failure.NativeErrorCode
                    }
                    else { $attempt.State = 'launch_outcome_unknown' }
                }
            }
            Start-Sleep -Milliseconds 100
        } while ($timer.Elapsed.TotalSeconds -lt $timeout)
    }
    catch {
        $result.Status = 'failed'; $result.Reason = 'RecoveryException'; $result.ErrorType = $_.Exception.GetType().Name
        $result.ProcessState = 'manual-review'
    }
    finally { if ($heldProcess) { $heldProcess.Dispose() }; $timer.Stop(); $result.ElapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3) }
    if ($null -eq $after) {
        try { $after = Get-ExplorerRecoverySnapshot -TestSessionPath $TestSessionPath }
        catch { $result.SnapshotErrors++ }
    }
    if ($after -and $null -eq $result.PinsUnchanged) { $result.PinsUnchanged = $after.Pins.Complete -and $after.Pins.Sha256 -ceq $pinsBefore }
    try {
        if ($after) { Write-ExplorerRecoveryJson -Path (Join-Path $EvidenceDirectory 'after.json') -Value $after }
        $result.EvidencePersisted = $true
        Write-ExplorerRecoveryJson -Path (Join-Path $EvidenceDirectory 'result.json') -Value $result
    }
    catch { $result.EvidencePersisted = $false; $result.Status = 'failed'; $result.Reason = 'EvidenceWriteFailed' }
    return $result
}
