function Initialize-AntigravityProcessIdentity {
    if ('HostDiagnostics.AntigravityCommandLine' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace HostDiagnostics {
    public sealed class AntigravityCommandLine {
        [DllImport("shell32.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CommandLineToArgvW(string line, out int argc);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern IntPtr LocalFree(IntPtr memory);

        public bool HasDesktopArguments { get; private set; }
        public bool HasElectronTypeSwitch { get; private set; }
        public bool FirstArgumentIsImport { get; private set; }

        private static bool IsSwitch(string argument, string name) {
            return argument.Equals(name, StringComparison.OrdinalIgnoreCase) ||
                argument.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase);
        }

        public static AntigravityCommandLine Read(string line, string expectedImage) {
            if (string.IsNullOrWhiteSpace(line)) return null;
            IntPtr argv = CommandLineToArgvW(line, out int argc);
            if (argv == IntPtr.Zero) return null;
            try {
                var image = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv));
                if (!string.Equals(image, expectedImage, StringComparison.OrdinalIgnoreCase)) return null;
                var flags = new AntigravityCommandLine {
                    HasDesktopArguments = argc == 1 || (argc == 2 &&
                        Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, IntPtr.Size)) == "--updated")
                };
                for (int i = 1; i < argc; i++) {
                    var argument = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
                    if (argument == "--") break;
                    if (i == 1) flags.FirstArgumentIsImport = IsSwitch(argument, "--import");
                    if (IsSwitch(argument, "--type")) flags.HasElectronTypeSwitch = true;
                }
                return flags;
            } finally { LocalFree(argv); }
        }
    }

    public sealed class AntigravityDesktopFrame {
        private const uint Caption = 0x00C00000, ThickFrame = 0x00040000, PopupOrChild = 0xC0000000;
        private const uint ToolWindow = 0x00000080;
        private const uint WmClose = 0x0010;
        public IntPtr Handle { get; }
        private uint ThreadId { get; }

        private AntigravityDesktopFrame(IntPtr handle, uint threadId) {
            Handle = handle;
            ThreadId = threadId;
        }

        private delegate bool WindowCallback(IntPtr window, IntPtr state);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern bool EnumWindows(WindowCallback callback, IntPtr state);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern IntPtr GetWindow(IntPtr window, uint relation);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern bool IsWindowEnabled(IntPtr window);
        [DllImport("user32.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        private static extern int GetClassNameW(IntPtr window, StringBuilder name, int length);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern uint GetWindowLongW(IntPtr window, int index);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", ExactSpelling = true)]
        private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam,
            uint flags, uint timeoutMs, out UIntPtr result);

        private static uint GetDesktopFrameThread(IntPtr window, uint processId) {
            uint thread = GetWindowThreadProcessId(window, out uint owner);
            if (thread == 0 || owner != processId || !IsWindowVisible(window) || GetWindow(window, 4) != IntPtr.Zero)
                return 0;
            // Antigravity's resizable frame keeps its native caption and sizing border when minimized.
            uint style = GetWindowLongW(window, -16);
            if ((style & (Caption | ThickFrame)) != (Caption | ThickFrame) || (style & PopupOrChild) != 0 ||
                (GetWindowLongW(window, -20) & ToolWindow) != 0) return 0;
            var name = new StringBuilder(64);
            return GetClassNameW(window, name, name.Capacity) > 0 && name.ToString() == "Chrome_WidgetWin_1" ? thread : 0;
        }

        public static AntigravityDesktopFrame[] Find(uint processId) {
            var frames = new List<AntigravityDesktopFrame>();
            if (!EnumWindows((window, state) => {
                uint thread = GetDesktopFrameThread(window, processId);
                if (thread != 0) frames.Add(new AntigravityDesktopFrame(window, thread));
                return true;
            }, IntPtr.Zero)) throw new InvalidOperationException("antigravity-window-enumeration-failed");
            return frames.ToArray();
        }

        public bool Matches(AntigravityDesktopFrame other) {
            return other != null && other.Handle == Handle && other.ThreadId == ThreadId;
        }

        private bool IsOnlyFrame(uint processId) {
            var frames = Find(processId);
            return frames.Length == 1 && Matches(frames[0]);
        }

        public bool TryClose(uint processId) {
            return IsOnlyFrame(processId) && IsWindowEnabled(Handle) &&
                GetDesktopFrameThread(Handle, processId) == ThreadId &&
                PostMessageW(Handle, WmClose, UIntPtr.Zero, IntPtr.Zero);
        }

        public bool IsResponsive(uint processId) {
            return GetDesktopFrameThread(Handle, processId) == ThreadId &&
                SendMessageTimeoutW(Handle, 0, UIntPtr.Zero, IntPtr.Zero, 2, 500, out _) != IntPtr.Zero &&
                IsOnlyFrame(processId);
        }
    }
}
'@ | Out-Null
}

function Get-AntigravityObservedProcess([string]$ExecutablePath, [int]$SessionId, $BoundProcess) {
    function Read-CimProcess([string]$Filter) {
        try {
            Get-CimInstance -ClassName Win32_Process -Filter $Filter -ErrorAction Stop -Verbose:$false -Debug:$false `
                -WarningAction SilentlyContinue -InformationAction SilentlyContinue -ProgressAction SilentlyContinue `
                -Property ProcessId, ParentProcessId, ExecutablePath, SessionId, CreationDate, CommandLine
        } catch { throw 'antigravity-process-query-failed' }
    }

    function Test-NodeParent($Child, [uint32]$ParentId) {
        if ($ParentId -eq 0) { return $false }
        try {
            $parents = @(Read-CimProcess "ProcessId = $ParentId AND Name = 'cmd.exe'")
            if ($parents.Count -ne 1) { return $false }
            $parent = $parents[0]
            $windows = [Environment]::GetFolderPath('Windows')
            if ($parent.ProcessId -ne $ParentId -or $parent.SessionId -ne $Child.SessionId -or
                $parent.CreationDate -isnot [datetime] -or $parent.CreationDate -gt $Child.CreationDate -or
                $parent.ExecutablePath -ine (Join-Path $windows 'System32/cmd.exe')) {
                return $false
            }
            # Check the first command after cmd /c, including cmd's optional outer quote.
            $nodeCommand = '\A(?:"[^"\r\n]+"|[^ \t"\r\n]+)(?:[ \t]+/(?:d|s|q|a|u))*[ \t]+/c[ \t]+"?(?:call[ \t]+)?(?:"(?:[^"\r\n]*[\\/])?node\.cmd"|(?:[^" \t\r\n&|<>()^]*[\\/])?node\.cmd)(?=[ \t"]|\z)'
            [regex]::IsMatch([string]$parent.CommandLine, $nodeCommand, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        } catch { $false }
    }

    if (-not [IO.Path]::IsPathFullyQualified($ExecutablePath) -or [IO.Path]::GetFileName($ExecutablePath) -ine 'Antigravity.exe') {
        throw 'antigravity-executable-path-required'
    }
    $ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
    Initialize-AntigravityProcessIdentity
    $filter = "Name = 'Antigravity.exe' AND SessionId = $SessionId"
    if ($BoundProcess) { $filter += " AND ProcessId = $($BoundProcess.Id)" }
    foreach ($row in Read-CimProcess $filter) {
        if ($row.ExecutablePath -and $row.ExecutablePath -ine $ExecutablePath) { continue }
        try {
            $processId = [uint32]$row.ProcessId
            $parentId = [uint32]$row.ParentProcessId
            if ($processId -eq 0) { throw 'missing-pid' }
        } catch { throw 'antigravity-process-schema-invalid' }
        $flags = $null
        $startUtc = $null
        $windowHandle = [IntPtr]::Zero
        $identityVerified = $false
        try {
            $process = if ($BoundProcess) { $BoundProcess } else {
                Get-Process -Id $processId -ErrorAction Stop -Verbose:$false -Debug:$false
            }
            $startUtc = $process.StartTime.ToUniversalTime()
            # WMI truncates the native 100-nanosecond creation time to microseconds.
            if ($row.CreationDate -is [datetime] -and $startUtc -is [datetime]) {
                $cimDelta = $startUtc.Ticks - $row.CreationDate.ToUniversalTime().Ticks
                $identityVerified = $cimDelta -ge 0 -and $cimDelta -lt 10 -and
                    $row.ExecutablePath -ieq $ExecutablePath -and $process.Path -ieq $ExecutablePath -and
                    $process.Id -eq $processId -and $process.SessionId -eq $SessionId -and
                    $row.SessionId -eq $SessionId -and -not $process.HasExited
            }
            if ($identityVerified) {
                $windowHandle = $process.MainWindowHandle
                $flags = [HostDiagnostics.AntigravityCommandLine]::Read($row.CommandLine, $ExecutablePath)
            }
        } catch {
            $identityVerified = $false
        }
        $firstImport = [bool]($flags -and $flags.FirstArgumentIsImport)
        [pscustomobject]@{
            pid = $processId
            ppid = $parentId
            identityVerified = $identityVerified
            hasMainWindow = $identityVerified -and $windowHandle -ne [IntPtr]::Zero
            # The desktop shortcut supplies no arguments. The official updater supplies only --updated.
            isDesktopMain = $identityVerified -and $windowHandle -ne [IntPtr]::Zero -and $flags -and $flags.HasDesktopArguments
            hasDesktopArguments = [bool]($flags -and $flags.HasDesktopArguments)
            hasElectronTypeSwitch = [bool]($flags -and $flags.HasElectronTypeSwitch)
            firstArgumentIsImport = $firstImport
            parentInvokesNodeCmd = $firstImport -and (Test-NodeParent $row $parentId)
            StartUtc = $startUtc
        }
    }
}

function Get-AntigravityDesktopMainProcess {
    param([string]$ExecutablePath, [int]$SessionId, [object[]]$Processes, [switch]$BeforeLaunch)

    $snapshot = @(Get-AntigravityObservedProcess $ExecutablePath $SessionId)
    $main = @(foreach ($candidate in $Processes) {
        $match = @()
        try {
            $startUtc = $candidate.StartTime.ToUniversalTime()
            $match = @($snapshot | Where-Object { $_.pid -eq $candidate.Id -and $_.identityVerified -and $_.StartUtc -eq $startUtc })
        } catch { }
        if ($match.Count -eq 1) {
            if ($match[0].hasElectronTypeSwitch -or $match[0].firstArgumentIsImport) { continue }
            if ($match[0].hasDesktopArguments) {
                foreach ($frame in [HostDiagnostics.AntigravityDesktopFrame]::Find($candidate.Id)) {
                    [pscustomobject]@{ Snapshot=$match[0]; Frame=$frame }
                }
                continue
            }
        }
        if ($BeforeLaunch) { throw 'antigravity-desktop-main-identity-unverified' }
    })
    if ($main.Count -gt 1) {
        if ($BeforeLaunch) { throw 'more-than-one-matching-app-window' }
        throw 'more-than-one-new-app-window'
    }
    if ($BeforeLaunch) {
        $unaccountedProcess = $snapshot | Where-Object {
            -not ($_.hasElectronTypeSwitch -or $_.firstArgumentIsImport) -and $_.pid -notin @($main.Snapshot.pid)
        } | Select-Object -First 1
        if ($unaccountedProcess -or ($main.Count -eq 0 -and ($snapshot.hasMainWindow -contains $true))) {
            throw 'antigravity-desktop-main-identity-unverified'
        }
    }
    $main
}

function Assert-AntigravityDesktopMainProcess($Snapshot, [string]$ExecutablePath, [int]$SessionId, $Frame) {
    $process = $null
    try {
        $process = Get-Process -Id $Snapshot.pid -ErrorAction Stop -Verbose:$false -Debug:$false
        # Keep the native process handle until the caller finishes; its PID cannot be recycled meanwhile.
        $handle = $process.SafeHandle
        if ($null -eq $handle -or $handle.IsInvalid -or $handle.IsClosed) { throw 'process-handle-unavailable' }
        $readBack = @(Get-AntigravityObservedProcess $ExecutablePath $SessionId $process)
        if ($readBack.Count -ne 1 -or -not $readBack[0].identityVerified -or -not $readBack[0].hasDesktopArguments -or
            $readBack[0].ppid -ne $Snapshot.ppid -or $readBack[0].StartUtc -ne $Snapshot.StartUtc) { throw 'process-identity-mismatch' }
        $process.Refresh()
        if ($process.HasExited) { throw 'process-exited' }
        if ($Frame) {
            $frames = @([HostDiagnostics.AntigravityDesktopFrame]::Find($process.Id))
            if ($frames.Count -ne 1 -or -not $Frame.Matches($frames[0])) { throw 'window-identity-mismatch' }
        }
        $process
    } catch {
        if ($process) { $process.Dispose() }
        throw 'antigravity-desktop-main-identity-changed'
    }
}

function Get-AntigravityProcessSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    Get-AntigravityObservedProcess $ExecutablePath $sessionId | Select-Object pid, ppid, identityVerified, hasMainWindow, `
        isDesktopMain, hasElectronTypeSwitch, firstArgumentIsImport, parentInvokesNodeCmd
}
