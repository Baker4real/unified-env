[CmdletBinding()]
param(
    [ValidateSet('Reminder', 'Cleanup', 'Activation', 'ReminderAcceptance', 'CleanupAcceptance', 'ActivationAcceptance')]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-CodexSerenaSessionDirectoryGuard {
    if ('CodexHookRuntime.SerenaSessionDirectoryGuard' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexHookRuntime
{
    public sealed class SerenaSessionDirectoryGuard : IDisposable
    {
        const uint GenericRead = 0x80000000;
        const uint DeleteAccess = 0x00010000;
        const uint ShareRead = 0x00000001;
        const uint ShareWrite = 0x00000002;
        const uint CreateNew = 1;
        const uint OpenExisting = 3;
        const uint BackupSemantics = 0x02000000;
        const uint OpenReparsePoint = 0x00200000;
        const uint ReparsePoint = 0x00000400;
        const uint DirectoryAttribute = 0x00000010;
        const int FileNotFound = 2;
        const int PathNotFound = 3;
        const int AlreadyExists = 183;
        const int FileExists = 80;
        const uint NormalizedName = 0;
        const int FileDispositionInfo = 4;

        [StructLayout(LayoutKind.Sequential)]
        struct FileTime { public uint Low; public uint High; }
        [StructLayout(LayoutKind.Sequential)]
        struct FileInformation
        {
            public uint Attributes; public FileTime Creation; public FileTime Access; public FileTime Write;
            public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IndexHigh; public uint IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct FileDisposition { [MarshalAs(UnmanagedType.Bool)] public bool DeleteFile; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateDirectoryW(string path, IntPtr security);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, System.Text.StringBuilder path, uint length, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref FileDisposition information, uint size);

        readonly List<SafeFileHandle> handles;
        SerenaSessionDirectoryGuard(List<SafeFileHandle> value) { handles = value; }

        public sealed class CounterLease : IDisposable
        {
            SafeFileHandle handle;
            readonly string expectedPath;
            readonly string expectedParent;
            readonly uint volume;
            readonly uint indexHigh;
            readonly uint indexLow;

            internal CounterLease(SafeFileHandle value, string path, string parent, uint expectedVolume, uint expectedIndexHigh, uint expectedIndexLow)
            {
                handle = value; expectedPath = path; expectedParent = parent;
                volume = expectedVolume; indexHigh = expectedIndexHigh; indexLow = expectedIndexLow;
            }

            public void ValidateAfterVendor(string counterPath)
            {
                if (handle == null || handle.IsInvalid || handle.IsClosed) throw new ObjectDisposedException("CounterLease");
                string expected = Trim(Path.GetFullPath(counterPath));
                if (!String.Equals(expected, expectedPath, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Serena counter capability path changed.");
                FileInformation information;
                if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
                ValidateCounter(handle, expectedPath, expectedParent, information);
                if (information.Volume != volume || information.IndexHigh != indexHigh || information.IndexLow != indexLow)
                    throw new IOException("Serena counter identity changed.");
                ValidateCounterClosure(expectedParent, expectedPath);
            }

            public void Dispose() { if (handle != null) { handle.Dispose(); handle = null; } }
        }

        public static SerenaSessionDirectoryGuard Acquire(string trustedParent, string sessionDirectory)
        {
            string root = Trim(Path.GetFullPath(trustedParent));
            string target = Trim(Path.GetFullPath(sessionDirectory));
            if (!Within(target, root) || String.Equals(target, root, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Serena session directory is outside its trusted parent.");
            string volume = Path.GetPathRoot(target);
            var opened = new List<SafeFileHandle>();
            try
            {
                string current = volume;
                opened.Add(OpenVerified(current));
                foreach (string part in target.Substring(volume.Length).Split(new[]{'\\','/'}, StringSplitOptions.RemoveEmptyEntries))
                {
                    current = Path.Combine(current, part);
                    SafeFileHandle handle;
                    int error;
                    bool isLeaf = String.Equals(current, target, StringComparison.OrdinalIgnoreCase);
                    if (!TryOpen(current, isLeaf ? GenericRead | DeleteAccess : GenericRead, out handle, out error))
                    {
                        if ((error != FileNotFound && error != PathNotFound) || !Within(current, root))
                            throw new Win32Exception(error, "Unable to open Serena session directory chain.");
                        if (!CreateDirectoryW(current, IntPtr.Zero))
                        {
                            int createError = Marshal.GetLastWin32Error();
                            if (createError != AlreadyExists) throw new Win32Exception(createError, "Unable to create Serena session directory chain.");
                        }
                        handle = OpenVerified(current, isLeaf ? GenericRead | DeleteAccess : GenericRead);
                    }
                    opened.Add(handle);
                }
                return new SerenaSessionDirectoryGuard(opened);
            }
            catch { foreach (var handle in opened) handle.Dispose(); throw; }
        }

        public CounterLease AcquireCounterLease(string counterPath)
        {
            if (handles.Count == 0) throw new ObjectDisposedException("SerenaSessionDirectoryGuard");
            string heldParent = FinalPath(handles[handles.Count - 1]);
            string expected = Trim(Path.GetFullPath(counterPath));
            if (!String.Equals(heldParent, Trim(Path.GetDirectoryName(expected)), StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(Path.GetFileName(expected), "tool_use_counter.pkl", StringComparison.Ordinal))
                throw new IOException("Serena counter path is outside the held session directory.");

            SafeFileHandle state = CreateFileW(expected, GenericRead, ShareRead | ShareWrite, IntPtr.Zero, CreateNew, OpenReparsePoint, IntPtr.Zero);
            if (state.IsInvalid)
            {
                int createError = Marshal.GetLastWin32Error();
                state.Dispose();
                if (createError != AlreadyExists && createError != FileExists) throw new Win32Exception(createError, "Unable to establish Serena counter name fence.");
                state = CreateFileW(expected, GenericRead, ShareRead | ShareWrite, IntPtr.Zero, OpenExisting, OpenReparsePoint, IntPtr.Zero);
                if (state.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open Serena counter by handle.");
            }
            try
            {
                FileInformation information;
                if (!GetFileInformationByHandle(state, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
                ValidateCounter(state, expected, heldParent, information);
                ValidateCounterClosure(heldParent, expected);
                return new CounterLease(state, expected, heldParent, information.Volume, information.IndexHigh, information.IndexLow);
            }
            catch { state.Dispose(); throw; }
        }

        public void DeleteKnownSessionState(string sessionDirectory)
        {
            string target = Trim(Path.GetFullPath(sessionDirectory));
            if (handles.Count == 0) throw new ObjectDisposedException("SerenaSessionDirectoryGuard");
            string heldParent = FinalPath(handles[handles.Count - 1]);
            if (!String.Equals(target, heldParent, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Serena session directory identity changed.");
            string[] entries = Directory.GetFileSystemEntries(target);
            if (entries.Length > 1 || (entries.Length == 1 && !String.Equals(Path.GetFileName(entries[0]), "tool_use_counter.pkl", StringComparison.Ordinal)))
                throw new IOException("Serena session directory contains unknown state.");
            SafeFileHandle state = null;
            try
            {
                if (entries.Length == 1)
                {
                    string expected = Trim(Path.GetFullPath(entries[0]));
                    state = CreateFileW(expected, GenericRead | DeleteAccess, ShareRead, IntPtr.Zero, OpenExisting, OpenReparsePoint, IntPtr.Zero);
                    if (state.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open Serena session state by handle.");
                    FileInformation information;
                    if (!GetFileInformationByHandle(state, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    ValidateCounter(state, expected, heldParent, information);
                    ValidateCounterClosure(heldParent, expected);
                    var stateDisposition = new FileDisposition { DeleteFile = true };
                    if (!SetFileInformationByHandle(state, FileDispositionInfo, ref stateDisposition, (uint)Marshal.SizeOf(typeof(FileDisposition))))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to delete Serena session state by handle.");
                }
            }
            finally { if (state != null) state.Dispose(); }
            var disposition = new FileDisposition { DeleteFile = true };
            SafeFileHandle leaf = handles[handles.Count - 1];
            if (!SetFileInformationByHandle(leaf, FileDispositionInfo, ref disposition, (uint)Marshal.SizeOf(typeof(FileDisposition))))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to delete Serena session directory by handle.");
        }

        static void ValidateCounter(SafeFileHandle state, string expected, string heldParent, FileInformation information)
        {
            if ((information.Attributes & (ReparsePoint | DirectoryAttribute)) != 0 || information.Links != 1)
                throw new IOException("Serena session state is not a private regular file.");
            string finalState = FinalPath(state);
            if (!String.Equals(expected, finalState, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(heldParent, Trim(Path.GetDirectoryName(finalState)), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Serena session state final path or parent identity mismatch.");
        }

        static void ValidateCounterClosure(string heldParent, string expected)
        {
            string[] entries = Directory.GetFileSystemEntries(heldParent);
            if (entries.Length != 1 || !String.Equals(Trim(Path.GetFullPath(entries[0])), expected, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Serena session directory counter closure changed.");
        }

        static SafeFileHandle OpenVerified(string path, uint access = GenericRead)
        {
            SafeFileHandle handle; int error;
            if (!TryOpen(path, access, out handle, out error)) throw new Win32Exception(error, "Unable to verify Serena session directory chain.");
            return handle;
        }

        static string FinalPath(SafeFileHandle handle)
        {
            var buffer = new System.Text.StringBuilder(32768);
            uint count = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, NormalizedName);
            if (count == 0 || count >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
            string finalPath = buffer.ToString();
            if (finalPath.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) finalPath = @"\\" + finalPath.Substring(8);
            else if (finalPath.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) finalPath = finalPath.Substring(4);
            return Trim(Path.GetFullPath(finalPath));
        }

        static bool TryOpen(string path, out SafeFileHandle handle, out int error)
        {
            return TryOpen(path, GenericRead, out handle, out error);
        }

        static bool TryOpen(string path, uint access, out SafeFileHandle handle, out int error)
        {
            string expected = Trim(Path.GetFullPath(path));
            handle = CreateFileW(expected, access, ShareRead, IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
            if (handle.IsInvalid) { error = Marshal.GetLastWin32Error(); handle.Dispose(); handle = null; return false; }
            try
            {
                FileInformation information;
                if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((information.Attributes & ReparsePoint) != 0 || (information.Attributes & DirectoryAttribute) == 0)
                    throw new IOException("Serena session directory chain contains a reparse point or non-directory.");
                if (!String.Equals(expected, FinalPath(handle), StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Serena session directory final path mismatch.");
                error = 0; return true;
            }
            catch { handle.Dispose(); handle = null; throw; }
        }

        static string Trim(string path)
        {
            string full = Path.GetFullPath(path);
            string root = Path.GetPathRoot(full);
            return String.Equals(full, root, StringComparison.OrdinalIgnoreCase)
                ? root
                : full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        static bool Within(string child, string parent) { return child.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase); }
        public void Dispose() { foreach (var handle in handles) handle.Dispose(); handles.Clear(); }
    }
}
'@
}

function Assert-CodexSerenaSessionInput {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InputText)

    if ([string]::IsNullOrWhiteSpace($InputText)) { throw 'Serena SessionStart payload 为空。' }
    $document = [Text.Json.JsonDocument]::Parse($InputText)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena SessionStart payload 根非法。' }
        $ids = @($root.EnumerateObject() | Where-Object { $_.Name -ceq 'session_id' -or $_.Name -ceq 'sessionId' })
        if ($ids.Count -ne 1 -or $ids[0].Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or [string]::IsNullOrWhiteSpace($ids[0].Value.GetString())) {
            throw 'Serena SessionStart id 非法。'
        }
        $sessionId = $ids[0].Value.GetString()
        if ($sessionId -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z') {
            throw 'Serena SessionStart id 路径语义非法。'
        }
        return $sessionId
    }
    finally { $document.Dispose() }
}

function Assert-CodexSerenaBehaviorOutput {
    param(
        [Parameter(Mandatory)][ValidateSet('Reminder', 'Cleanup', 'Activation')][string]$Behavior,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes
    )

    if ($Behavior -ceq 'Activation') {
        Assert-CodexSerenaSessionStartOutputBytes -Bytes $Bytes
        return
    }
    if ($Behavior -ceq 'Cleanup') {
        if ($Bytes.Length -ne 0) { throw 'Serena cleanup stdout 协议非法。' }
        return
    }
    if ($Bytes.Length -eq 0) { return }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena reminder JSON 根非法。' }
        $rootNames = @($root.EnumerateObject() | ForEach-Object Name)
        if ($rootNames.Count -ne 1 -or $rootNames[0] -cne 'hookSpecificOutput') { throw 'Serena reminder 顶层 schema 非法。' }
        $output = $root.GetProperty('hookSpecificOutput')
        if ($output.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena reminder hookSpecificOutput 非法。' }
        $names = @($output.EnumerateObject() | ForEach-Object Name)
        $expected = @('hookEventName', 'permissionDecision', 'permissionDecisionReason')
        if ($names.Count -ne $expected.Count -or (@($names | Sort-Object) -join "`0") -cne (@($expected | Sort-Object) -join "`0")) { throw 'Serena reminder hookSpecificOutput schema 非法。' }
        if ($output.GetProperty('hookEventName').GetString() -cne 'PreToolUse') { throw 'Serena reminder hookEventName 非法。' }
        if ($output.GetProperty('permissionDecision').GetString() -cne 'deny') { throw 'Serena reminder permissionDecision 非法。' }
        if ([string]::IsNullOrWhiteSpace($output.GetProperty('permissionDecisionReason').GetString())) { throw 'Serena reminder reason 非法。' }
    }
    finally { $document.Dispose() }
}

function Get-CodexSerenaSessionMutexName {
    param(
        [Parameter(Mandatory)][string]$SerenaHome,
        [Parameter(Mandatory)][string]$SessionId
    )

    # Windows path and session directory comparisons are case-insensitive. Use
    # one invariant representation so equivalent spellings share one mutex.
    $canonicalHome = [IO.Path]::GetFullPath($SerenaHome).TrimEnd('\', '/').ToUpperInvariant()
    $canonicalSessionId = $SessionId.ToUpperInvariant()
    $material = $canonicalHome + "`n" + $canonicalSessionId
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($material)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return 'Local\CodexSerenaSession-' + [Convert]::ToHexString($hash)
}

function Enter-CodexSerenaSessionMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMilliseconds = 250
    )

    $mutex = [Threading.Mutex]::new($false, $Name)
    $held = $false
    try {
        try {
            $held = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            # The previous hook died while holding the lock. The state guard
            # below still revalidates every path and counter identity.
            $held = $true
        }
    }
    catch {
        $mutex.Dispose()
        throw
    }
    if (-not $held) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

function Exit-CodexSerenaSessionMutex {
    param([Parameter(Mandatory)][Threading.Mutex]$Mutex)

    try { [void]$Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Invoke-CodexSerenaSessionMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMilliseconds = 250
    )

    Enter-CodexSerenaSessionMutex -Name $Name -TimeoutMilliseconds $TimeoutMilliseconds
}

function Release-CodexSerenaBehaviorState {
    param(
        [Parameter(Mandatory)][ref]$CounterLease,
        [Parameter(Mandatory)][ref]$SessionGuard,
        [Parameter(Mandatory)][ref]$SessionMutex
    )

    # Release the file capabilities before the named mutex. Health reporting is
    # deliberately performed after this function so it cannot extend the
    # session's critical section.
    # Releasing the state is deliberately best-effort. The hook protocol is
    # optional and a disposal race must not replace the original
    # vendor/protocol result or make the host wait on a second exception path.
    try { if ($null -ne $CounterLease.Value) { $CounterLease.Value.Dispose() } } catch {}
    finally { $CounterLease.Value = $null }
    try { if ($null -ne $SessionGuard.Value) { $SessionGuard.Value.Dispose() } } catch {}
    finally { $SessionGuard.Value = $null }
    try { if ($null -ne $SessionMutex.Value) { Exit-CodexSerenaSessionMutex -Mutex $SessionMutex.Value } } catch {}
    finally { $SessionMutex.Value = $null }
}

function Invoke-CodexSerenaBehaviorGuardCore {
    param(
        [Parameter(Mandatory)][ValidateSet('Reminder', 'Cleanup', 'Activation')][string]$Behavior,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText,
        [Parameter(Mandatory)][string]$VendorPath,
        [Parameter(Mandatory)][string]$SerenaHome,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$HealthRoot,
        [switch]$AllowFixture
    )

    $productionVendor = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
    $productionHome = 'D:\Codex\.serena'
    $productionRuntime = 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1'
    $productionHealth = 'D:\agents\run-evidence\codex-hook-health'
    $fixtureHome = 'D:\agents\projects\统一环境\reports\codex-hook-serena-behavior-fixture\.serena'
    $fixtureRuntime = 'D:\agents\projects\统一环境\managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
    $fixtureHealth = 'D:\agents\projects\统一环境\reports\codex-hook-health-test'
    if ($VendorPath -ine $productionVendor) { throw 'Serena behavior vendor capability 非法。' }
    if ($AllowFixture) {
        $legacyFixture = $SerenaHome -ieq $fixtureHome -and $RuntimePath -ieq $fixtureRuntime -and $HealthRoot -ieq $fixtureHealth
        $runtimeFull = [IO.Path]::GetFullPath($RuntimePath)
        $runtimeLib = [IO.Directory]::GetParent($runtimeFull)
        $hookRoot = if ($null -ne $runtimeLib) { $runtimeLib.Parent } else { $null }
        $codexHome = if ($null -ne $hookRoot) { $hookRoot.Parent } else { $null }
        $reconcilerFixture = $false
        if ($null -ne $codexHome -and $hookRoot.FullName -ieq (Join-Path $codexHome.FullName 'hooks')) {
            $marker = Join-Path $codexHome.FullName '.codex-host-hook-reconciliation-fixture'
            $reconcilerFixture = (
                $codexHome.FullName -cmatch '^D:\\agents\\projects\\统一环境\\\.scratch\\host-hook-reconciliation-tests-[0-9a-f]{32}\\[^\\]+\\\.codex\z' -and
                (Test-Path -LiteralPath $marker -PathType Leaf) -and
                (Get-Content -LiteralPath $marker -Raw).Trim() -ceq 'codex-host-hook-reconciliation-fixture-v1' -and
                $RuntimePath -ieq (Join-Path $codexHome.FullName 'hooks\lib\CodexHookRuntime.ps1') -and
                $HealthRoot -ieq (Join-Path $codexHome.FullName 'run-evidence\codex-hook-health') -and
                $SerenaHome -ieq (Join-Path $codexHome.Parent.FullName '.serena-hook-fixture')
            )
        }
        if (-not $legacyFixture -and -not $reconcilerFixture) { throw 'Serena behavior fixture capability 非法。' }
    }
    elseif ($SerenaHome -ine $productionHome -or $RuntimePath -ine $productionRuntime -or $HealthRoot -ine $productionHealth) {
        throw 'Serena behavior production capability 非法。'
    }

    . $RuntimePath
    $hookId = if ($Behavior -ceq 'Reminder') { 'serena-reminder' } elseif ($Behavior -ceq 'Cleanup') { 'serena-cleanup' } else { 'serena-activate' }
    $vendorCommand = if ($Behavior -ceq 'Reminder') { 'remind' } else { 'cleanup' }
    $started = [DateTime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $productionVendor
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['SERENA_HOME'] = $SerenaHome
    [void]$startInfo.ArgumentList.Add($vendorCommand)
    [void]$startInfo.ArgumentList.Add('--client=codex')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $buffer = [IO.MemoryStream]::new()
    $sessionGuard = $null
    $counterLease = $null
    $sessionMutex = $null
    try {
        $sessionId = Assert-CodexSerenaSessionInput -InputText $InputText
        if ($Behavior -ceq 'Activation') {
            $context = 'Use the absolute workspace root from environment_context to call mcp__serena__activate_project, then call mcp__serena__get_current_config to verify the active project. Do not infer the project from cwd.'
            $activationJson = [pscustomobject][ordered]@{ hookSpecificOutput = [pscustomobject][ordered]@{ hookEventName = 'SessionStart'; additionalContext = $context } } | ConvertTo-Json -Compress -Depth 4
            [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($activationJson + "`r`n")
        }
        else {
            $mutexName = Get-CodexSerenaSessionMutexName -SerenaHome $SerenaHome -SessionId $sessionId
            # Leave startup/drain/cleanup headroom inside the host's 10s hook
            # budget while still covering the vendor's 5s bounded drain.
            $mutexTimeoutMilliseconds = if ($Behavior -ceq 'Cleanup') { 6000 } else { 250 }
            $sessionMutex = Invoke-CodexSerenaSessionMutex -Name $mutexName -TimeoutMilliseconds $mutexTimeoutMilliseconds
            if ($null -eq $sessionMutex) {
                # PreToolUse and Stop are optional hooks. When another process
                # owns this session, fail open before touching the shared
                # state; waiting behind it would consume the host's 10s hook
                # budget.
                [byte[]]$bytes = @()
                $watch.Stop()
                if ($Behavior -ceq 'Cleanup') {
                    # Stop fires once per session: a contended Cleanup leaks the
                    # session state directory, so the skip must stay observable.
                    # Reminder skips touch nothing and stay silent, keeping the
                    # hot PreToolUse path off the health writer's .backups.
                    # A health write failure must not flip the fail-open result.
                    $health = [pscustomobject][ordered]@{
                        hookId = $hookId; runId = [guid]::NewGuid().ToString('N'); startedAtUtc = $started.ToString('o')
                        completedAtUtc = [DateTime]::UtcNow.ToString('o'); durationMs = [long]$watch.ElapsedMilliseconds
                        ok = $false; changed = $false; restartRequired = $false; errors = [string[]]@('skipped: session mutex contention')
                    }
                    try { $null = Write-CodexHookLatestHealthCore -HookId $hookId -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot:$AllowFixture } catch {}
                }
                return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; stdout = $bytes; error = $null }
            }
            Initialize-CodexSerenaSessionDirectoryGuard
            $trustedParent = [IO.Directory]::GetParent([IO.Path]::GetFullPath($SerenaHome)).FullName
            $sessionDirectory = Join-Path ([IO.Path]::GetFullPath($SerenaHome)) ("hook_data\{0}" -f $sessionId)
            $sessionGuard = [CodexHookRuntime.SerenaSessionDirectoryGuard]::Acquire($trustedParent, $sessionDirectory)
            if ($Behavior -ceq 'Cleanup') {
                $sessionGuard.DeleteKnownSessionState($sessionDirectory)
                [byte[]]$bytes = @()
            }
            else {
                $counterPath = Join-Path $sessionDirectory 'tool_use_counter.pkl'
                $counterLease = $sessionGuard.AcquireCounterLease($counterPath)
                if (-not $process.Start()) { throw 'Serena behavior vendor 启动失败。' }
                $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
                $stderrTask = $process.StandardError.ReadToEndAsync()
                [byte[]]$inputBytes = [Text.UTF8Encoding]::new($false).GetBytes($InputText)
                $stdinStream = $process.StandardInput.BaseStream
                $stdinTask = $stdinStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
                $stderr = Complete-CodexHookProcessWithBoundedDrain `
                    -Process $process -StdoutTask $stdoutTask -StderrTask $stderrTask `
                    -TimeoutMilliseconds 5000 -ProcessName 'Serena behavior vendor' `
                    -StdinTask $stdinTask -StdinStream $stdinStream
                [byte[]]$bytes = $buffer.ToArray()
                if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($stderr)) { throw 'Serena behavior vendor 失败。' }
                $counterLease.ValidateAfterVendor($counterPath)
            }
        }
        Assert-CodexSerenaBehaviorOutput -Behavior $Behavior -Bytes $bytes
        Release-CodexSerenaBehaviorState -CounterLease ([ref]$counterLease) -SessionGuard ([ref]$sessionGuard) -SessionMutex ([ref]$sessionMutex)
        if ($Behavior -ceq 'Reminder' -and $bytes.Length -eq 0) {
            $watch.Stop()
            return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; stdout = $bytes; error = $null }
        }
        $watch.Stop()
        $health = [pscustomobject][ordered]@{
            hookId = $hookId; runId = [guid]::NewGuid().ToString('N'); startedAtUtc = $started.ToString('o')
            completedAtUtc = [DateTime]::UtcNow.ToString('o'); durationMs = [long]$watch.ElapsedMilliseconds
            ok = $true; changed = $false; restartRequired = $false; errors = [string[]]@()
        }
        # Health reporting is best-effort here as well: a write failure must
        # not flip the result the vendor already produced (same pattern as the
        # catch path below).
        try { $null = Write-CodexHookLatestHealthCore -HookId $hookId -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot:$AllowFixture } catch {}
        return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; stdout = $bytes; error = $null }
    }
    catch {
        $watch.Stop()
        Release-CodexSerenaBehaviorState -CounterLease ([ref]$counterLease) -SessionGuard ([ref]$sessionGuard) -SessionMutex ([ref]$sessionMutex)
        $health = [pscustomobject][ordered]@{
            hookId = $hookId; runId = [guid]::NewGuid().ToString('N'); startedAtUtc = $started.ToString('o')
            completedAtUtc = [DateTime]::UtcNow.ToString('o'); durationMs = [long]$watch.ElapsedMilliseconds
            ok = $false; changed = $false; restartRequired = $false; errors = [string[]]@('serena behavior protocol validation failed')
        }
        try { $null = Write-CodexHookLatestHealthCore -HookId $hookId -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot:$AllowFixture } catch {}
        return [pscustomobject][ordered]@{ ok = $false; exitCode = 0; stdout = [byte[]]@(); error = 'serena behavior hook failed' }
    }
    finally {
        $watch.Stop()
        if ($null -ne $counterLease -or $null -ne $sessionGuard -or $null -ne $sessionMutex) {
            Release-CodexSerenaBehaviorState -CounterLease ([ref]$counterLease) -SessionGuard ([ref]$sessionGuard) -SessionMutex ([ref]$sessionMutex)
        }
        $buffer.Dispose()
        $process.Dispose()
    }
}

function Invoke-CodexSerenaBehaviorAcceptanceCore {
    param(
        [Parameter(Mandatory)][ValidateSet('Reminder', 'Cleanup', 'Activation')][string]$Behavior,
        [Parameter(Mandatory)][string]$VendorPath,
        [Parameter(Mandatory)][string]$SerenaHome,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$HealthRoot,
        [switch]$AllowFixture
    )

    $sessionId = [guid]::NewGuid().ToString()
    if ($Behavior -ceq 'Activation') {
        $activationPayload = [pscustomobject][ordered]@{ session_id = $sessionId } | ConvertTo-Json -Compress
        $activation = Invoke-CodexSerenaBehaviorGuardCore -Behavior Activation -InputText $activationPayload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
        if (-not $activation.ok -or $activation.exitCode -ne 0 -or $activation.stdout.Length -eq 0) { throw 'Serena activation acceptance 失败。' }
        return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; sessionId = $null }
    }

    $sessionPath = Join-Path $SerenaHome "hook_data\$sessionId"
    $payload = [pscustomobject][ordered]@{
        session_id = $sessionId
        tool_name = 'Bash'
        tool_input = [pscustomobject][ordered]@{ command = 'rg -n hook file.ps1' }
    } | ConvertTo-Json -Compress -Depth 4
    try {
        if ($Behavior -ceq 'Reminder') {
            foreach ($attempt in 1..3) {
                $result = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $payload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
                if (-not $result.ok -or $result.exitCode -ne 0) { throw 'Serena reminder acceptance 失败。' }
                if ($attempt -lt 3 -and $result.stdout.Length -ne 0) { throw 'Serena reminder acceptance 过早提醒。' }
                if ($attempt -eq 3 -and $result.stdout.Length -eq 0) { throw 'Serena reminder acceptance 未达到阈值。' }
            }
        }
        else {
            $seed = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $payload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
            if (-not $seed.ok -or $seed.stdout.Length -ne 0 -or -not (Test-Path -LiteralPath $sessionPath -PathType Container)) { throw 'Serena cleanup acceptance seed 失败。' }
        }
    }
    finally {
        $cleanupPayload = [pscustomobject][ordered]@{ session_id = $sessionId } | ConvertTo-Json -Compress
        $cleanup = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup -InputText $cleanupPayload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
        if (-not $cleanup.ok -or $cleanup.exitCode -ne 0 -or $cleanup.stdout.Length -ne 0 -or (Test-Path -LiteralPath $sessionPath)) { throw 'Serena behavior acceptance cleanup 失败。' }
    }
    return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; sessionId = $sessionId }
}

function Get-CodexSerenaBehaviorExecutionConfig {
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $fullRoot = [IO.Path]::GetFullPath($ScriptRoot).TrimEnd('\', '/')
    $liveRoot = [IO.Path]::GetFullPath('D:\Codex\.codex\hooks').TrimEnd('\', '/')
    if ($fullRoot.Equals($liveRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            vendorPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
            serenaHome = 'D:\Codex\.serena'
            runtimePath = 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1'
            healthRoot = 'D:\agents\run-evidence\codex-hook-health'
            allowFixture = $false
        }
    }
    if ($fullRoot -cnotmatch '^D:\\agents\\projects\\统一环境\\\.scratch\\host-hook-reconciliation-tests-[0-9a-f]{32}\\[^\\]+\\\.codex\\hooks\z') {
        throw 'Serena behavior guard 只允许 live root 或项目专用 fixture root'
    }
    $codexHome = [IO.Directory]::GetParent($fullRoot).FullName
    $markerPath = Join-Path $codexHome '.codex-host-hook-reconciliation-fixture'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or (Get-Content -LiteralPath $markerPath -Raw).Trim() -cne 'codex-host-hook-reconciliation-fixture-v1') {
        throw 'Serena behavior fixture marker 非法'
    }
    [pscustomobject]@{
        vendorPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
        serenaHome = Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena-hook-fixture'
        runtimePath = Join-Path $fullRoot 'lib\CodexHookRuntime.ps1'
        healthRoot = Join-Path $codexHome 'run-evidence\codex-hook-health'
        allowFixture = $true
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        [Console]::Error.WriteLine('serena behavior hook failed')
        exit 1
    }
    $executionConfig = Get-CodexSerenaBehaviorExecutionConfig -ScriptRoot $PSScriptRoot
    if ($Mode.EndsWith('Acceptance', [StringComparison]::Ordinal)) {
        try {
            $behavior = $Mode.Substring(0, $Mode.Length - 'Acceptance'.Length)
            $null = Invoke-CodexSerenaBehaviorAcceptanceCore -Behavior $behavior `
                -VendorPath $executionConfig.vendorPath `
                -SerenaHome $executionConfig.serenaHome `
                -RuntimePath $executionConfig.runtimePath `
                -HealthRoot $executionConfig.healthRoot `
                -AllowFixture:$executionConfig.allowFixture
            exit 0
        }
        catch {
            [Console]::Error.WriteLine('serena behavior acceptance failed')
            exit 1
        }
    }
    $inputText = [Console]::In.ReadToEnd()
    $result = Invoke-CodexSerenaBehaviorGuardCore -Behavior $Mode -InputText $inputText `
        -VendorPath $executionConfig.vendorPath `
        -SerenaHome $executionConfig.serenaHome `
        -RuntimePath $executionConfig.runtimePath `
        -HealthRoot $executionConfig.healthRoot `
        -AllowFixture:$executionConfig.allowFixture
    if (-not $result.ok) {
        exit 0
    }
    if ($result.stdout.Length -gt 0) {
        $standardOutput = [Console]::OpenStandardOutput()
        $standardOutput.Write($result.stdout, 0, $result.stdout.Length)
        $standardOutput.Flush()
    }
    exit 0
}
