[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$guardPath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\CodexRemotePluginCatalogGuard.ps1'
$entryPath = Join-Path $projectRoot 'scripts\Invoke-CodexRemotePluginCatalogGuard.ps1'
$policyPath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\policy.json'
$handleIoPath = Join-Path $projectRoot 'scripts\lib\CodexHookHandleBoundIO.cs'
$pwshPath = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$safeDeleteWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$reportsRoot = Join-Path $projectRoot 'reports'
$fixtureParent = Join-Path $reportsRoot ("catalog-guard-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
$fixtureRoot = Join-Path $fixtureParent '.codex'
$catalogRoot = Join-Path $fixtureRoot 'cache\remote_plugin_catalog'
$catalogPath = Join-Path $catalogRoot 'aaaaaaaaaaaaaaaa.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$junctionCreated = $false
$managedArtifactJunctionCreated = $false
$managedArtifactJunctionPath = $null

if (-not ('CodexHookGovernance.VerifiedDirectoryChainGuard' -as [type])) {
    Add-Type -Path $handleIoPath -ErrorAction Stop
}

$eaTestApiSource = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexCatalogGuardTests
{
    public static class ExtendedAttributeApi
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint SynchronizeAccess = 0x00100000;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock
        {
            public IntPtr Status;
            public UIntPtr Information;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("ntdll.dll")]
        private static extern int NtSetEaFile(
            SafeFileHandle fileHandle,
            out IoStatusBlock ioStatusBlock,
            byte[] buffer,
            uint length);

        [DllImport("ntdll.dll")]
        private static extern int NtQueryEaFile(
            SafeFileHandle fileHandle,
            out IoStatusBlock ioStatusBlock,
            byte[] buffer,
            uint length,
            [MarshalAs(UnmanagedType.U1)] bool returnSingleEntry,
            byte[] eaList,
            uint eaListLength,
            IntPtr eaIndex,
            [MarshalAs(UnmanagedType.U1)] bool restartScan);

        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FlushFileBuffers(SafeFileHandle fileHandle);

        public static void SetValue(string path, string name, byte[] value)
        {
            if (value == null) { throw new ArgumentNullException(nameof(value)); }
            using (SafeFileHandle handle = Open(path, true))
            {
                SetValue(handle, name, value);
                Flush(handle);
            }
        }

        public static void DeleteValue(string path, string name)
        {
            using (SafeFileHandle handle = Open(path, true))
            {
                SetValue(handle, name, Array.Empty<byte>());
                Flush(handle);
            }
        }

        public static byte[] ReadValue(string path, string name)
        {
            using (SafeFileHandle handle = Open(path, false))
            {
                byte[] nameBytes = GetNameBytes(name);
                byte[] eaList = new byte[checked(5 + nameBytes.Length + 1)];
                eaList[4] = checked((byte)nameBytes.Length);
                Buffer.BlockCopy(nameBytes, 0, eaList, 5, nameBytes.Length);
                byte[] output = new byte[65536];
                IoStatusBlock ioStatusBlock;
                int status = NtQueryEaFile(handle, out ioStatusBlock, output, checked((uint)output.Length), true, eaList, checked((uint)eaList.Length), IntPtr.Zero, true);
                ThrowForNtStatus(status, "NtQueryEaFile failed in the EA hardening fixture.");
                int returnedNameLength = output[5];
                int valueLength = output[6] | (output[7] << 8);
                int valueOffset = checked(9 + returnedNameLength);
                if (returnedNameLength != nameBytes.Length || valueOffset + valueLength > checked((int)ioStatusBlock.Information.ToUInt64()))
                {
                    throw new InvalidDataException("The EA hardening fixture received an invalid response.");
                }
                byte[] value = new byte[valueLength];
                Buffer.BlockCopy(output, valueOffset, value, 0, valueLength);
                return value;
            }
        }

        public static int CountNamedValues(string path, string name)
        {
            using (SafeFileHandle handle = Open(path, false))
            {
                byte[] output = new byte[65536];
                IoStatusBlock ioStatusBlock;
                int status = NtQueryEaFile(handle, out ioStatusBlock, output, checked((uint)output.Length), false, null, 0, IntPtr.Zero, true);
                ThrowForNtStatus(status, "NtQueryEaFile enumeration failed in the EA hardening fixture.");
                int used = checked((int)ioStatusBlock.Information.ToUInt64());
                int offset = 0;
                int count = 0;
                while (offset < used)
                {
                    if (used - offset < 9) { throw new InvalidDataException("The EA enumeration entry is truncated."); }
                    uint nextOffset = BitConverter.ToUInt32(output, offset);
                    int nameLength = output[offset + 5];
                    int valueLength = output[offset + 6] | (output[offset + 7] << 8);
                    int valueOffset = checked(offset + 9 + nameLength);
                    if (valueOffset + valueLength > used) { throw new InvalidDataException("The EA enumeration value is truncated."); }
                    string entryName = Encoding.ASCII.GetString(output, offset + 8, nameLength);
                    if (string.Equals(entryName, name, StringComparison.OrdinalIgnoreCase)) { count++; }
                    if (nextOffset == 0) { break; }
                    if (nextOffset < 9 || offset + nextOffset >= used) { throw new InvalidDataException("The EA enumeration offset is invalid."); }
                    offset = checked(offset + (int)nextOffset);
                }
                return count;
            }
        }

        private static SafeFileHandle Open(string path, bool writable)
        {
            string fullPath = Path.GetFullPath(path);
            uint access = GenericRead | SynchronizeAccess;
            if (writable) { access |= GenericWrite; }
            SafeFileHandle handle = CreateFileW(ToExtendedPath(fullPath), access, FileShare.Read, IntPtr.Zero, OpenExisting, FileAttributeNormal | FileFlagOpenReparsePoint, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "CreateFileW failed in the EA hardening fixture.");
            }
            return handle;
        }

        private static void SetValue(SafeFileHandle handle, string name, byte[] value)
        {
            byte[] nameBytes = GetNameBytes(name);
            if (value.Length > ushort.MaxValue) { throw new ArgumentOutOfRangeException(nameof(value)); }
            byte[] buffer = new byte[checked(8 + nameBytes.Length + 1 + value.Length)];
            buffer[5] = checked((byte)nameBytes.Length);
            buffer[6] = (byte)(value.Length & 0xff);
            buffer[7] = (byte)((value.Length >> 8) & 0xff);
            Buffer.BlockCopy(nameBytes, 0, buffer, 8, nameBytes.Length);
            Buffer.BlockCopy(value, 0, buffer, 9 + nameBytes.Length, value.Length);
            IoStatusBlock ioStatusBlock;
            int status = NtSetEaFile(handle, out ioStatusBlock, buffer, checked((uint)buffer.Length));
            ThrowForNtStatus(status, "NtSetEaFile failed in the EA hardening fixture.");
        }

        private static byte[] GetNameBytes(string name)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(name);
            if (bytes.Length == 0 || bytes.Length > byte.MaxValue) { throw new ArgumentOutOfRangeException(nameof(name)); }
            return bytes;
        }

        private static void Flush(SafeFileHandle handle)
        {
            if (!FlushFileBuffers(handle)) { throw new Win32Exception(Marshal.GetLastWin32Error(), "FlushFileBuffers failed in the EA hardening fixture."); }
        }

        private static void ThrowForNtStatus(int status, string message)
        {
            if (status >= 0) { return; }
            throw new Win32Exception(checked((int)RtlNtStatusToDosError(status)), message);
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) { return path; }
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) { return @"\\?\UNC\" + path.Substring(2); }
            return @"\\?\" + path;
        }
    }
}
'@

if (-not ('CodexCatalogGuardTests.ExtendedAttributeApi' -as [type])) {
    Add-Type -TypeDefinition $eaTestApiSource -Language CSharp -ErrorAction Stop
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-BytesWithFullSharing {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $buffer = [IO.MemoryStream]::new()
        try { $stream.CopyTo($buffer); return $buffer.ToArray() } finally { $buffer.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function New-TargetCatalog {
    param([object[]]$ExtraEntries = @())
    return [ordered]@{
        schema_version = 1
        plugins = @(
            [ordered]@{ id = 'keep-before'; name = 'before'; payload = [ordered]@{ nested = @(1, 2, 3) } }
            [ordered]@{ id = 'plugin_asdk_app_69418aad55e08191aa5e437b649ca2e4'; name = 'heygen'; payload = 'remove' }
            [ordered]@{ id = 'keep-after'; name = 'after'; payload = [ordered]@{ nested = @($true, $false, $null) } }
            $ExtraEntries
        )
    }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32) + "`n"), $utf8)
}

function Invoke-GuardSweep {
    param(
        [string]$Mutation,
        [byte[]]$PostIsolationReplacementBytes,
        [byte[]]$PostprocessReplacementBytes,
        [string]$PublishFailure,
        [string]$StageExit,
        [string]$DurableRenameExit,
        [string]$VendorAbortExit,
        [string]$SealFailure,
        [string]$TransientSharingFailure,
        [byte[]]$MarkerCleanupReplacementBytes,
        [switch]$InterruptAfterQuarantine
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $guardPath,
        '-Mode', 'Sweep',
        '-PolicyPath', $policyPath,
        '-FixtureRoot', $fixtureRoot,
        '-Json'
    )) {
        [void]$start.ArgumentList.Add($argument)
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    if (-not [string]::IsNullOrWhiteSpace($Mutation)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MUTATION'] = $Mutation
    }
    if ($null -ne $PostIsolationReplacementBytes) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_POST_ISOLATION_BYTES_BASE64'] = [Convert]::ToBase64String($PostIsolationReplacementBytes)
    }
    if ($null -ne $PostprocessReplacementBytes) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_POSTPROCESS_BYTES_BASE64'] = [Convert]::ToBase64String($PostprocessReplacementBytes)
    }
    if (-not [string]::IsNullOrWhiteSpace($PublishFailure)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_PUBLISH_FAILURE'] = $PublishFailure
    }
    if (-not [string]::IsNullOrWhiteSpace($StageExit)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_STAGE_EXIT'] = $StageExit
    }
    if (-not [string]::IsNullOrWhiteSpace($DurableRenameExit)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DURABLE_RENAME_EXIT'] = $DurableRenameExit
    }
    if (-not [string]::IsNullOrWhiteSpace($VendorAbortExit)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_VENDOR_ABORT_EXIT'] = $VendorAbortExit
    }
    if (-not [string]::IsNullOrWhiteSpace($SealFailure)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_SEAL_FAILURE'] = $SealFailure
    }
    if (-not [string]::IsNullOrWhiteSpace($TransientSharingFailure)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_TRANSIENT_SHARING_FAILURE'] = $TransientSharingFailure
    }
    if ($null -ne $MarkerCleanupReplacementBytes) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MARKER_CLEANUP_REPLACEMENT_BASE64'] = [Convert]::ToBase64String($MarkerCleanupReplacementBytes)
    }
    if ($InterruptAfterQuarantine) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_INTERRUPT_AFTER_QUARANTINE'] = '1'
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() 'guard hardening fixture 无法启动'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        Assert-True ($process.WaitForExit(30000)) 'guard hardening fixture 超时'
        $result = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 32 }
        return [pscustomobject][ordered]@{ exitCode = $process.ExitCode; result = $result; stderr = $stderr }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}

function Invoke-GuardSweepWithCanonicalLeaseProbe {
    param(
        [string]$PausePoint,
        [byte[]]$PostIsolationReplacementBytes,
        [string]$PublishFailure
    )
    $readyPath = Join-Path $fixtureRoot 'state\canonical-lease.ready'
    $releasePath = Join-Path $fixtureRoot 'state\canonical-lease.release'
    foreach ($probePath in @($readyPath, $releasePath)) { if ([IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) } }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $guardPath,
        '-Mode', 'Sweep',
        '-PolicyPath', $policyPath,
        '-FixtureRoot', $fixtureRoot,
        '-Json'
    )) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_CANONICAL_LEASE_PAUSE'] = $PausePoint
    if ($null -ne $PostIsolationReplacementBytes) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_POST_ISOLATION_BYTES_BASE64'] = [Convert]::ToBase64String($PostIsolationReplacementBytes)
    }
    if (-not [string]::IsNullOrWhiteSpace($PublishFailure)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_PUBLISH_FAILURE'] = $PublishFailure
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $releaseWritten = $false
    $replacementPath = Join-Path $catalogRoot 'canonical-lease-replacement.tmp'
    $renamedPath = Join-Path $catalogRoot 'canonical-lease-renamed.json'
    try {
        Assert-True $process.Start() "canonical lease probe 无法启动：$PausePoint"
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($readyPath) -and -not $process.HasExited -and $stopwatch.ElapsedMilliseconds -lt 30000) {
            Start-Sleep -Milliseconds 10
        }
        Assert-True ([IO.File]::Exists($readyPath)) "canonical lease checkpoint 未到达：point=$PausePoint exit=$(if ($process.HasExited) { $process.ExitCode } else { 'running' })"
        Assert-True ([IO.File]::ReadAllText($readyPath, $utf8).Trim() -ceq $PausePoint) "canonical lease ready point 漂移：$PausePoint"
        Assert-True ([IO.File]::Exists($catalogPath)) "canonical lease checkpoint 缺少 canonical：$PausePoint"
        $canonicalBytes = $null
        try { $canonicalBytes = Read-BytesWithFullSharing -Path $catalogPath } catch [IO.IOException] {}
        $replacementBytes = $utf8.GetBytes("replacement must be denied at $PausePoint`n")
        [IO.File]::WriteAllBytes($replacementPath, $replacementBytes)

        $renameDenied = $false
        try { [IO.File]::Move($catalogPath, $renamedPath, $false) } catch [IO.IOException] { $renameDenied = $true }
        $replaceDenied = $false
        try { [IO.File]::Move($replacementPath, $catalogPath, $true) } catch [IO.IOException] { $replaceDenied = $true }
        $deleteDenied = $false
        try { [IO.File]::Delete($catalogPath) } catch [IO.IOException] { $deleteDenied = $true }
        $canonicalUnchanged = [IO.File]::Exists($catalogPath)
        if ($null -ne $canonicalBytes) {
            $canonicalUnchanged = $canonicalUnchanged -and (Get-BytesSha256 -Bytes (Read-BytesWithFullSharing -Path $catalogPath)) -ceq (Get-BytesSha256 -Bytes $canonicalBytes)
        }

        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $releasePath))
        [IO.File]::WriteAllText($releasePath, "$PausePoint`n", $utf8)
        $releaseWritten = $true
        Assert-True ($process.WaitForExit(30000)) "canonical lease probe 释放后超时：$PausePoint"
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $result = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 32 }
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            result = $result
            stderr = $stderr
            renameDenied = $renameDenied
            replaceDenied = $replaceDenied
            deleteDenied = $deleteDenied
            canonicalUnchanged = $canonicalUnchanged
        }
    } finally {
        if (-not $releaseWritten -and -not $process.HasExited) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $releasePath))
            [IO.File]::WriteAllText($releasePath, "$PausePoint`n", $utf8)
        }
        if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
        foreach ($probePath in @($readyPath, $releasePath, $replacementPath, $renamedPath)) { if ([IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) } }
    }
}

function Invoke-GuardSweepWithDurablePublicationProbe {
    param([string]$Point)
    $pauseValue = "txn:$Point"
    $readyPath = Join-Path $fixtureRoot 'state\durable-publication.ready'
    $releasePath = Join-Path $fixtureRoot 'state\durable-publication.release'
    foreach ($probePath in @($readyPath, $releasePath)) { if ([IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) } }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $guardPath,
        '-Mode', 'Sweep',
        '-PolicyPath', $policyPath,
        '-FixtureRoot', $fixtureRoot,
        '-Json'
    )) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DURABLE_RENAME_PAUSE'] = $pauseValue

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $releaseWritten = $false
    $replacementPath = Join-Path $catalogRoot 'durable-publication-replacement.tmp'
    $renamedPath = Join-Path $catalogRoot 'durable-publication-renamed.tmp'
    try {
        Assert-True $process.Start() "durable publication probe 无法启动：$pauseValue"
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($readyPath) -and -not $process.HasExited -and $stopwatch.ElapsedMilliseconds -lt 30000) {
            Start-Sleep -Milliseconds 10
        }
        Assert-True ([IO.File]::Exists($readyPath)) "durable publication checkpoint 未到达：point=$pauseValue exit=$(if ($process.HasExited) { $process.ExitCode } else { 'running' })"
        Assert-True ([IO.File]::ReadAllText($readyPath, $utf8).Trim() -ceq $pauseValue) "durable publication ready point 漂移：$pauseValue"
        $protectedPath = if ($Point -ceq 'after-clear') {
            @(Get-StagingArtifacts | Where-Object Name -CLike '*.txn')[0].FullName
        } else {
            Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.txn'
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($protectedPath) -and [IO.File]::Exists($protectedPath)) "durable publication 受保护对象不存在：$pauseValue"
        $protectedBytes = Read-BytesWithFullSharing -Path $protectedPath
        [IO.File]::WriteAllBytes($replacementPath, $utf8.GetBytes("durable replacement must be denied: $pauseValue`n"))

        $renameDenied = $false
        try { [IO.File]::Move($protectedPath, $renamedPath, $false) } catch [IO.IOException] { $renameDenied = $true }
        $replaceDenied = $false
        try { [IO.File]::Move($replacementPath, $protectedPath, $true) } catch [IO.IOException] { $replaceDenied = $true }
        $deleteDenied = $false
        try { [IO.File]::Delete($protectedPath) } catch [IO.IOException] { $deleteDenied = $true }
        $protectedUnchanged = [IO.File]::Exists($protectedPath) -and (Get-BytesSha256 -Bytes (Read-BytesWithFullSharing -Path $protectedPath)) -ceq (Get-BytesSha256 -Bytes $protectedBytes)

        [IO.File]::WriteAllText($releasePath, "$pauseValue`n", $utf8)
        $releaseWritten = $true
        Assert-True ($process.WaitForExit(30000)) "durable publication probe 释放后超时：$pauseValue"
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $result = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 32 }
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            result = $result
            stderr = $stderr
            renameDenied = $renameDenied
            replaceDenied = $replaceDenied
            deleteDenied = $deleteDenied
            protectedUnchanged = $protectedUnchanged
        }
    } finally {
        if (-not $releaseWritten -and -not $process.HasExited) { [IO.File]::WriteAllText($releasePath, "$pauseValue`n", $utf8) }
        if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
        foreach ($probePath in @($readyPath, $releasePath, $replacementPath, $renamedPath)) { if ([IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) } }
    }
}

function Get-TransactionArtifacts {
    return @(Get-ChildItem -LiteralPath $catalogRoot -File -Force | Where-Object Name -CLike '.codex-catalog-guard-*' | Sort-Object Name)
}

function Get-StagingArtifacts {
    return @(Get-ChildItem -LiteralPath $catalogRoot -Force | Where-Object Name -CLike '.codex-catalog-guard-*.stage-*' | Sort-Object Name)
}

function Replace-FileWithSameBytes {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $replacementPath = Join-Path $catalogRoot ("identity-replacement-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllBytes($replacementPath, $bytes)
    [IO.File]::Move($replacementPath, $Path, $true)
    return $bytes
}

function Get-TestFileIdentity {
    param([string]$Path)
    $guard = $null
    $file = $null
    try {
        $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($catalogRoot, $catalogRoot, $false)
        $file = $guard.AcquirePreparedTempFile($Path)
        return @([string]$file.VolumeSerialNumber, [string]$file.FileIndex)
    } finally {
        if ($null -ne $file) { $file.Dispose() }
        if ($null -ne $guard) { $guard.Dispose() }
    }
}

function Write-InPlacePreservingIdentity {
    param([string]$Path, [byte[]]$Bytes)
    $beforeIdentity = @(Get-TestFileIdentity -Path $Path)
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stream.SetLength(0)
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    $afterIdentity = @(Get-TestFileIdentity -Path $Path)
    Assert-True (($beforeIdentity -join ':') -ceq ($afterIdentity -join ':')) "原地改写改变了 File ID：$Path"
    return [pscustomobject][ordered]@{ beforeIdentity = $beforeIdentity; afterIdentity = $afterIdentity }
}

function Get-SameLengthJsonWhitespaceMutation {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path, $utf8)
    $mutated = $text.Replace('"schemaVersion": 2', '"schemaVersion":2 ')
    Assert-True ($mutated -cne $text) "JSON whitespace mutation 未命中：$Path"
    $bytes = $utf8.GetBytes($mutated)
    Assert-True ($bytes.Length -eq $utf8.GetBytes($text).Length) "JSON whitespace mutation 未保持长度：$Path"
    return $bytes
}

function Get-DifferentLengthJsonWhitespaceMutation {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path, $utf8)
    $bytes = $utf8.GetBytes($text + ' ')
    Assert-True ($bytes.Length -ne $utf8.GetBytes($text).Length) "JSON whitespace mutation 未改变长度：$Path"
    $document = [Text.Json.JsonDocument]::Parse($utf8.GetString($bytes))
    $document.Dispose()
    return $bytes
}

function Get-TransactionAfterShaMutation {
    param([string]$Path, [string]$AfterSha256, [switch]$DifferentLength)
    $beforeBytes = [IO.File]::ReadAllBytes($Path)
    $marker = [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -Depth 16
    $marker.afterSha256 = $AfterSha256
    $text = ($marker | ConvertTo-Json -Depth 16) + "`n"
    if ($DifferentLength) { $text += ' ' }
    $bytes = $utf8.GetBytes($text)
    Assert-True ($marker.afterSha256 -ceq $AfterSha256) "transaction afterSha256 mutation 未生效：$Path"
    Assert-True ((-not $DifferentLength) -or $bytes.Length -ne $beforeBytes.Length) "transaction mutation 未改变长度：$Path"
    $document = [Text.Json.JsonDocument]::Parse($utf8.GetString($bytes))
    $document.Dispose()
    return $bytes
}

function Clear-TransactionFixture {
    foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }
    foreach ($stage in @(Get-StagingArtifacts)) { [IO.File]::Delete($stage.FullName) }
    if ([IO.File]::Exists($catalogPath)) { [IO.File]::Delete($catalogPath) }
}

function Get-TransactionArtifactState {
    $state = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @(Get-TransactionArtifacts)) {
        $state.Add([pscustomobject][ordered]@{
            name = $artifact.Name
            sha256 = Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($artifact.FullName))
            identity = @(Get-TestFileIdentity -Path $artifact.FullName)
        })
    }
    return @($state)
}

function Assert-TransactionArtifactStateUnchanged {
    param([object[]]$Before, [string]$Label)

    $after = @(Get-TransactionArtifactState)
    Assert-True ($after.Count -eq $Before.Count) "$Label transaction artifact 数量漂移：before=$($Before.Count) after=$($after.Count)"
    foreach ($expected in $Before) {
        $actual = @($after | Where-Object name -CEQ $expected.name)
        Assert-True ($actual.Count -eq 1) "$Label transaction artifact 丢失或重复：$($expected.name)"
        Assert-True ($actual[0].sha256 -ceq $expected.sha256) "$Label transaction artifact 默认流被覆盖：$($expected.name)"
        Assert-True (($actual[0].identity -join ':') -ceq ($expected.identity -join ':')) "$Label transaction artifact identity 漂移：$($expected.name)"
    }
}

function Set-IntegrityAnchorMutation {
    param(
        [string]$Path,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind,
        [ValidateSet('missing', 'truncated', 'wrong-length', 'wrong-magic', 'wrong-version', 'wrong-kind', 'wrong-sha')][string]$Mutation
    )

    $eaName = 'CodexCatalogGuardV1'
    [byte[]]$anchor = [CodexCatalogGuardTests.ExtendedAttributeApi]::ReadValue($Path, $eaName)
    Assert-True ($anchor.Length -eq 42) "可信 $ArtifactKind artifact 的原始 EA 长度异常：$($anchor.Length)"
    if ($Mutation -ceq 'missing') {
        [CodexCatalogGuardTests.ExtendedAttributeApi]::DeleteValue($Path, $eaName)
        return
    }

    [byte[]]$mutated = [byte[]]$anchor.Clone()
    switch ($Mutation) {
        'truncated' {
            $mutated = [byte[]]::new($anchor.Length - 1)
            [Array]::Copy($anchor, $mutated, $mutated.Length)
        }
        'wrong-length' {
            $mutated = [byte[]]::new($anchor.Length + 1)
            [Array]::Copy($anchor, $mutated, $anchor.Length)
            $mutated[$mutated.Length - 1] = 0x5a
        }
        'wrong-magic' { $mutated[0] = [byte]($mutated[0] -bxor 0xff) }
        'wrong-version' { $mutated[8] = 2 }
        'wrong-kind' {
            $mutated[9] = if ($ArtifactKind -ceq 'txn') { 2 } elseif ($ArtifactKind -ceq 'publish') { 3 } else { 1 }
        }
        'wrong-sha' { $mutated[10] = [byte]($mutated[10] -bxor 0xff) }
    }
    [CodexCatalogGuardTests.ExtendedAttributeApi]::SetValue($Path, $eaName, $mutated)
    [byte[]]$actual = [CodexCatalogGuardTests.ExtendedAttributeApi]::ReadValue($Path, $eaName)
    Assert-True ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($mutated)) "EA mutation 未精确落盘：artifact=$ArtifactKind mutation=$Mutation"
}

function New-TrustedIntegrityArtifactFixture {
    param([ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind)

    Clear-TransactionFixture
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $invocation = $null
    $canonicalBytes = $null
    $expectedArtifactCount = 0
    if ($ArtifactKind -ceq 'txn') {
        $canonicalBytes = [IO.File]::ReadAllBytes($catalogPath)
        $invocation = Invoke-GuardSweep -DurableRenameExit 'txn:after-second-open'
        $expectedArtifactCount = 1
        Assert-True ($invocation.exitCode -eq 89 -and $null -eq $invocation.result) "可信 txn fixture 未在 durable publication 点退出：$($invocation | ConvertTo-Json -Compress -Depth 8)"
    } elseif ($ArtifactKind -ceq 'publish') {
        $canonicalBytes = [IO.File]::ReadAllBytes($catalogPath)
        $invocation = Invoke-GuardSweep -DurableRenameExit 'publish:after-second-open'
        $expectedArtifactCount = 2
        Assert-True ($invocation.exitCode -eq 89 -and $null -eq $invocation.result) "可信 publish fixture 未在 durable publication 点退出：$($invocation | ConvertTo-Json -Compress -Depth 8)"
    } else {
        $vendorCatalog = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-ea-vendor'; name = 'ea-vendor'; payload = 'vendor-must-survive' })
        $canonicalBytes = $utf8.GetBytes((($vendorCatalog | ConvertTo-Json -Depth 32) + "`n"))
        $invocation = Invoke-GuardSweep -PostIsolationReplacementBytes $canonicalBytes -VendorAbortExit 'after-phase'
        $expectedArtifactCount = 4
        Assert-True ($invocation.exitCode -eq 88 -and $null -eq $invocation.result) "可信 vendor-abort fixture 未在 durable phase 后退出：$($invocation | ConvertTo-Json -Compress -Depth 8)"
    }

    $artifactPath = Join-Path $catalogRoot ".codex-catalog-guard-aaaaaaaaaaaaaaaa.$ArtifactKind"
    Assert-True ([IO.File]::Exists($catalogPath)) "可信 $ArtifactKind fixture 缺少 canonical"
    Assert-True ([IO.File]::Exists($artifactPath)) "可信 $ArtifactKind fixture 缺少目标 artifact"
    Assert-True (@(Get-TransactionArtifacts).Count -eq $expectedArtifactCount) "可信 $ArtifactKind fixture 的 transaction artifact 数量异常"
    return [pscustomobject][ordered]@{
        artifactPath = $artifactPath
        canonicalBytes = [byte[]]$canonicalBytes
        canonicalIdentity = @(Get-TestFileIdentity -Path $catalogPath)
        transactionState = @(Get-TransactionArtifactState)
    }
}

function Assert-Blocked {
    param([object]$Invocation, [int]$ExitCode, [string]$Code, [string]$Label)
    Assert-True ($Invocation.exitCode -eq $ExitCode) "$Label exit code 错误：$($Invocation.exitCode) $($Invocation.stderr)"
    if ($ExitCode -eq 2) {
        Assert-True ($Invocation.result.ok -eq $false -and $Invocation.result.blockedCount -eq 1) "$Label 必须产生一个 blocked catalog"
        Assert-True ($Invocation.result.blocked[0].code -ceq $Code) "$Label 错误码不精确：$($Invocation.result.blocked[0].code) stderr=$($Invocation.stderr)"
    } else {
        Assert-True ($Invocation.result.ok -eq $false -and $Invocation.result.error.code -ceq $Code) "$Label 顶层错误码不精确：$($Invocation.result.error.code)"
    }
}

function Invoke-GuardAudit {
    param([string]$FixturePolicyPath)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $guardPath,
        '-Mode', 'Audit',
        '-PolicyPath', $FixturePolicyPath,
        '-FixtureRoot', $fixtureRoot,
        '-Json'
    )) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() 'guard audit fixture 无法启动'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        Assert-True ($process.WaitForExit(30000)) 'guard audit fixture 超时'
        $result = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 48 }
        return [pscustomobject][ordered]@{ exitCode = $process.ExitCode; result = $result; stderr = $stderr }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}

function Invoke-GovernanceFixtureCheck {
    param([string]$FixturePolicyPath, [string]$FixtureStatePath)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $entryPath,
        '-Mode', 'Check',
        '-Json',
        '-FixtureRoot', $fixtureRoot,
        '-FixturePolicyPath', $FixturePolicyPath
    )) { $arguments.Add($argument) }
    if (-not [string]::IsNullOrWhiteSpace($FixtureStatePath)) {
        $arguments.Add('-FixtureStatePath')
        $arguments.Add($FixtureStatePath)
    }
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() 'governance Check fixture 无法启动'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        Assert-True ($process.WaitForExit(30000)) 'governance Check fixture 超时'
        $result = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 64 }
        return [pscustomobject][ordered]@{ exitCode = $process.ExitCode; result = $result; stderr = $stderr }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}

function New-WatchStateFixture {
    param([string]$Status, [int]$PendingRetryCount, [DateTime]$LastSweepUtc)
    $blockedCount = if ($PendingRetryCount -gt 0) { 1 } else { 0 }
    $blockedEntries = if ($blockedCount -eq 0) {
        ,([object[]]::new(0))
    } else {
        ,([object[]]@([ordered]@{ file = 'aaaaaaaaaaaaaaaa.json'; code = 'malformed-json' }))
    }
    return [ordered]@{
        schemaVersion = 2
        pid = 4242
        startedUtc = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
        heartbeatUtc = [DateTime]::UtcNow.ToString('o')
        status = $Status
        catalogRoot = $catalogRoot
        metrics = [ordered]@{ metadataProbeCount = 1; contentReadCount = 1; rewriteCount = 0 }
        lastSweep = [ordered]@{
            schemaVersion = 1
            ok = $Status -ceq 'running' -and $PendingRetryCount -eq 0
            mode = 'Sweep'
            completedAtUtc = $LastSweepUtc.ToString('o')
            scannedCount = 1
            changedCount = 0
            removedCount = 0
            blockedCount = $blockedCount
            pendingRetryCount = $PendingRetryCount
            skippedUnchangedCount = 0
            results = @()
            blocked = $blockedEntries
        }
    }
}

function Remove-FixtureWithManagedDelete {
    if (-not [IO.Directory]::Exists($fixtureParent)) { return }
    $planText = & $safeDeleteWrapper -Mode Plan -TargetPath $fixtureParent -CapabilityRoot $reportsRoot -Json
    $planExit = $LASTEXITCODE
    Assert-True ($planExit -eq 0) "safe delete Plan 失败，exit=$planExit"
    $plan = $planText | ConvertFrom-Json -Depth 16
    $applyText = & $safeDeleteWrapper -Mode Apply -PlanPath $plan.planPath -ApprovedPlanSha256 $plan.planSha256 -ConfirmApply -Json
    $applyExit = $LASTEXITCODE
    Assert-True ($applyExit -eq 0) "safe delete Apply 失败，exit=$applyExit"
    $apply = $applyText | ConvertFrom-Json -Depth 16
    $purgeText = & $safeDeleteWrapper -Mode Purge -TransactionPath $apply.transactionPath -ApprovedTransactionSha256 $apply.transactionSha256 -ConfirmPurge -Json
    $purgeExit = $LASTEXITCODE
    Assert-True ($purgeExit -eq 0) "safe delete Purge 失败，exit=$purgeExit"
    $purge = $purgeText | ConvertFrom-Json -Depth 16
    Assert-True ($purge.purged -eq $true -and -not [IO.Directory]::Exists($fixtureParent)) 'safe delete 未完整清理 hardening fixture'
}

try {
    [void][IO.Directory]::CreateDirectory($catalogRoot)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot '.remote-plugin-catalog-guard-fixture'), "fixture-v1`n", $utf8)
    $fixturePolicyPath = Join-Path $fixtureRoot 'policy.json'
    [IO.File]::WriteAllBytes($fixturePolicyPath, [IO.File]::ReadAllBytes($policyPath))

    $pluginSentinel = Join-Path $fixtureRoot 'plugins\cache\sentinel-plugin\payload.txt'
    $skillSentinel = Join-Path $fixtureRoot 'skills\sentinel-skill\SKILL.md'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $pluginSentinel))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $skillSentinel))
    [IO.File]::WriteAllText($pluginSentinel, "plugin payload must survive`n", $utf8)
    [IO.File]::WriteAllText($skillSentinel, "skill payload must survive`n", $utf8)
    $pluginSentinelSha = Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($pluginSentinel))
    $skillSentinelSha = Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($skillSentinel))

    $eaName = 'CodexCatalogGuardV1'
    $eaBehaviorPath = Join-Path $catalogRoot 'ea-api-behavior.tmp'
    $eaBehaviorBytes = $utf8.GetBytes("same-name EA API behavior`n")
    [IO.File]::WriteAllBytes($eaBehaviorPath, $eaBehaviorBytes)
    $eaBehaviorIdentity = @(Get-TestFileIdentity -Path $eaBehaviorPath)
    [byte[]]$eaFirstValue = @(1, 2, 3)
    [byte[]]$eaSecondValue = @(4, 5, 6, 7)
    [CodexCatalogGuardTests.ExtendedAttributeApi]::SetValue($eaBehaviorPath, $eaName, $eaFirstValue)
    [CodexCatalogGuardTests.ExtendedAttributeApi]::SetValue($eaBehaviorPath, $eaName, $eaSecondValue)
    [byte[]]$eaObservedValue = [CodexCatalogGuardTests.ExtendedAttributeApi]::ReadValue($eaBehaviorPath, $eaName)
    Assert-True ([Convert]::ToBase64String($eaObservedValue) -ceq [Convert]::ToBase64String($eaSecondValue)) 'NtSetEaFile 同名写入未替换为第二个 value'
    Assert-True ([CodexCatalogGuardTests.ExtendedAttributeApi]::CountNamedValues($eaBehaviorPath, $eaName) -eq 1) 'NtSetEaFile 同名写入产生了重复 EA entry'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($eaBehaviorPath))) -ceq (Get-BytesSha256 -Bytes $eaBehaviorBytes)) '同名 EA API 行为测试改变了默认流'
    Assert-True (((Get-TestFileIdentity -Path $eaBehaviorPath) -join ':') -ceq ($eaBehaviorIdentity -join ':')) '同名 EA API 行为测试改变了 File ID'
    [CodexCatalogGuardTests.ExtendedAttributeApi]::DeleteValue($eaBehaviorPath, $eaName)
    [IO.File]::Delete($eaBehaviorPath)

    $integrityMutationCount = 0
    $integrityMutations = @('missing', 'truncated', 'wrong-length', 'wrong-magic', 'wrong-version', 'wrong-kind', 'wrong-sha')
    foreach ($integrityArtifactKind in @('txn', 'publish', 'vendor-abort')) {
        foreach ($integrityMutation in $integrityMutations) {
            $integrityFixture = New-TrustedIntegrityArtifactFixture -ArtifactKind $integrityArtifactKind
            $artifactIdentityBeforeMutation = @(Get-TestFileIdentity -Path $integrityFixture.artifactPath)
            Set-IntegrityAnchorMutation -Path $integrityFixture.artifactPath -ArtifactKind $integrityArtifactKind -Mutation $integrityMutation
            Assert-True (((Get-TestFileIdentity -Path $integrityFixture.artifactPath) -join ':') -ceq ($artifactIdentityBeforeMutation -join ':')) "EA mutation 改变了 artifact File ID：artifact=$integrityArtifactKind mutation=$integrityMutation"

            $integrityRecovery = Invoke-GuardSweep
            Assert-Blocked -Invocation $integrityRecovery -ExitCode 2 -Code 'catalog-transaction-conflict' -Label "EA $integrityMutation $integrityArtifactKind recovery"
            Assert-True ([IO.File]::Exists($catalogPath)) "EA mutation recovery 删除了 canonical：artifact=$integrityArtifactKind mutation=$integrityMutation"
            Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $integrityFixture.canonicalBytes)) "EA mutation recovery 覆盖了 canonical：artifact=$integrityArtifactKind mutation=$integrityMutation"
            Assert-True (((Get-TestFileIdentity -Path $catalogPath) -join ':') -ceq ($integrityFixture.canonicalIdentity -join ':')) "EA mutation recovery 替换了 canonical identity：artifact=$integrityArtifactKind mutation=$integrityMutation"
            Assert-TransactionArtifactStateUnchanged -Before $integrityFixture.transactionState -Label "EA $integrityMutation $integrityArtifactKind recovery"
            $integrityMutationCount++
            Clear-TransactionFixture
        }
    }

    $sealFailureCount = 0
    foreach ($sealArtifactKind in @('txn', 'publish', 'vendor-abort')) {
        foreach ($sealFailurePoint in @('nt-set-ea', 'flush-file-buffers')) {
            Clear-TransactionFixture
            Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
            $sealExpectedCanonicalBytes = [IO.File]::ReadAllBytes($catalogPath)
            $sealFailureInvocation = $null
            if ($sealArtifactKind -ceq 'vendor-abort') {
                $sealVendorCatalog = New-TargetCatalog -ExtraEntries @([ordered]@{ id = "keep-seal-$sealFailurePoint"; name = "seal-$sealFailurePoint"; payload = 'vendor-must-survive' })
                $sealExpectedCanonicalBytes = $utf8.GetBytes((($sealVendorCatalog | ConvertTo-Json -Depth 32) + "`n"))
                $sealFailureInvocation = Invoke-GuardSweep -PostIsolationReplacementBytes $sealExpectedCanonicalBytes -SealFailure "vendor-abort:$sealFailurePoint"
            } else {
                $sealFailureInvocation = Invoke-GuardSweep -SealFailure "${sealArtifactKind}:$sealFailurePoint"
            }
            Assert-Blocked -Invocation $sealFailureInvocation -ExitCode 2 -Code 'catalog-io-failure' -Label "seal failure $sealArtifactKind $sealFailurePoint"
            Assert-True (@(Get-StagingArtifacts).Count -eq 0) "seal 失败后 delete-on-close 未清理 staging：artifact=$sealArtifactKind point=$sealFailurePoint"
            Assert-True ([IO.File]::Exists($catalogPath)) "seal 失败后 canonical 消失：artifact=$sealArtifactKind point=$sealFailurePoint"
            Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $sealExpectedCanonicalBytes)) "seal 失败覆盖了 canonical：artifact=$sealArtifactKind point=$sealFailurePoint"
            $failedFinalPath = Join-Path $catalogRoot ".codex-catalog-guard-aaaaaaaaaaaaaaaa.$sealArtifactKind"
            Assert-True (-not [IO.File]::Exists($failedFinalPath)) "seal 失败 artifact 被发布：artifact=$sealArtifactKind point=$sealFailurePoint"
            if ($sealArtifactKind -ceq 'vendor-abort') {
                Assert-True (@(Get-TransactionArtifacts).Count -eq 3) "vendor-abort seal 失败未保留既有可恢复 transaction：point=$sealFailurePoint"
            } else {
                Assert-True (@(Get-TransactionArtifacts).Count -eq 0) "seal 失败在隔离前留下最终 transaction artifact：artifact=$sealArtifactKind point=$sealFailurePoint"
            }

            $sealRecovery = Invoke-GuardSweep
            Assert-True ($sealRecovery.exitCode -eq 0 -and $sealRecovery.result.removedCount -eq 1) "seal 失败后的无注入 sweep 未收敛：artifact=$sealArtifactKind point=$sealFailurePoint invocation=$($sealRecovery | ConvertTo-Json -Compress -Depth 8)"
            Assert-True (@(Get-StagingArtifacts).Count -eq 0 -and @(Get-TransactionArtifacts).Count -eq 0) "seal 失败恢复后仍有 artifact：artifact=$sealArtifactKind point=$sealFailurePoint"
            $sealAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
            Assert-True (-not (@($sealAfter.plugins.name) -ccontains 'heygen')) "seal 失败恢复后未过滤目标：artifact=$sealArtifactKind point=$sealFailurePoint"
            $sealFailureCount++
            [IO.File]::Delete($catalogPath)
        }
    }

    Clear-TransactionFixture
    $sharingVendorCatalog = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-sharing-retry'; name = 'sharing-retry'; payload = 'vendor-must-survive' })
    $sharingVendorBytes = $utf8.GetBytes((($sharingVendorCatalog | ConvertTo-Json -Depth 32) + "`n"))
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $sharingFault = Invoke-GuardSweep -PostIsolationReplacementBytes $sharingVendorBytes -DurableRenameExit 'vendor-abort:after-clear'
    Assert-True ($sharingFault.exitCode -eq 89 -and $null -eq $sharingFault.result) "transient sharing retry 前置 vendor-abort staging 未形成：$($sharingFault | ConvertTo-Json -Compress -Depth 8)"
    $sharingRecovery = Invoke-GuardSweep -TransientSharingFailure 'publish'
    Assert-True ($sharingRecovery.exitCode -eq 0 -and $sharingRecovery.result.ok -eq $true -and $sharingRecovery.result.removedCount -eq 1) "transient sharing retry 未在单次 Sweep 内收敛：$($sharingRecovery | ConvertTo-Json -Compress -Depth 8)"
    Assert-True (@(Get-StagingArtifacts).Count -eq 0 -and @(Get-TransactionArtifacts).Count -eq 0) 'transient sharing retry 收敛后残留 artifact'
    $sharingRetryEvents = @(Get-Content -LiteralPath (Join-Path $fixtureRoot 'logs\guard.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 16 } | Where-Object event -CEQ 'transaction-sharing-retry')
    Assert-True ($sharingRetryEvents.Count -ge 1 -and $sharingRetryEvents[-1].file -ceq '.codex-catalog-guard-aaaaaaaaaaaaaaaa.publish' -and $sharingRetryEvents[-1].nativeErrorCode -eq 32 -and $sharingRetryEvents[-1].attempt -eq 1) 'transient sharing retry 未记录精确 Win32 32 操作级证据'
    $sharingAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
    Assert-True ((@($sharingAfter.plugins.name) -join ',') -ceq 'before,after,sharing-retry') 'transient sharing retry 未保留 vendor 非目标内容'
    [IO.File]::Delete($catalogPath)

    foreach ($txnMutationKind in @('same-length-whitespace', 'different-length-after-sha')) {
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $txnInPlaceInterrupted = Invoke-GuardSweep -InterruptAfterQuarantine
        Assert-True ($txnInPlaceInterrupted.exitCode -eq 86 -and -not [IO.File]::Exists($catalogPath)) "txn 原地改写前置 transaction 未形成：kind=$txnMutationKind invocation=$($txnInPlaceInterrupted | ConvertTo-Json -Compress -Depth 8)"
        $txnInPlacePath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.txn'
        $txnInPlaceBytes = if ($txnMutationKind -ceq 'same-length-whitespace') {
            Get-SameLengthJsonWhitespaceMutation -Path $txnInPlacePath
        } else {
            Get-TransactionAfterShaMutation -Path $txnInPlacePath -AfterSha256 ('f' * 64) -DifferentLength
        }
        [void](Write-InPlacePreservingIdentity -Path $txnInPlacePath -Bytes $txnInPlaceBytes)
        $txnInPlaceRecovery = Invoke-GuardSweep
        Assert-Blocked -Invocation $txnInPlaceRecovery -ExitCode 2 -Code 'catalog-transaction-conflict' -Label "same-identity txn in-place rewrite $txnMutationKind"
        Assert-True (-not [IO.File]::Exists($catalogPath) -and @(Get-TransactionArtifacts).Count -eq 3) "txn 原地改写后 transaction 未完整失败闭锁：$txnMutationKind"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($txnInPlacePath))) -ceq (Get-BytesSha256 -Bytes $txnInPlaceBytes)) "txn 原地改写对象被删除或覆盖：$txnMutationKind"
        foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }
    }

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $publishInPlaceInterrupted = Invoke-GuardSweep -InterruptAfterQuarantine
    Assert-True ($publishInPlaceInterrupted.exitCode -eq 86 -and -not [IO.File]::Exists($catalogPath)) "publish 原地改写前置 transaction 未形成：$($publishInPlaceInterrupted | ConvertTo-Json -Compress -Depth 8)"
    $publishInPlacePath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.publish'
    $txnInPlacePath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.txn'
    $schemaValidPublishMutation = [ordered]@{
        schema_version = 1
        plugins = @(
            [ordered]@{ id = 'keep-before'; name = 'before'; payload = [ordered]@{ nested = @(1, 2, 3) } }
            [ordered]@{ id = 'keep-after'; name = 'after'; payload = [ordered]@{ nested = @($true, $false, $null) } }
            [ordered]@{ id = 'keep-injected'; name = 'injected'; payload = 'not-derived-from-quarantine' }
        )
    }
    $publishInPlaceBytes = $utf8.GetBytes((($schemaValidPublishMutation | ConvertTo-Json -Depth 32) + "`n"))
    $publishInPlaceSha = Get-BytesSha256 -Bytes $publishInPlaceBytes
    $txnSynchronizedBytes = Get-TransactionAfterShaMutation -Path $txnInPlacePath -AfterSha256 $publishInPlaceSha
    [void](Write-InPlacePreservingIdentity -Path $publishInPlacePath -Bytes $publishInPlaceBytes)
    [void](Write-InPlacePreservingIdentity -Path $txnInPlacePath -Bytes $txnSynchronizedBytes)
    $publishInPlaceRecovery = Invoke-GuardSweep
    Assert-Blocked -Invocation $publishInPlaceRecovery -ExitCode 2 -Code 'catalog-transaction-conflict' -Label 'same-identity publish rewrite with synchronized txn afterSha256'
    Assert-True (-not [IO.File]::Exists($catalogPath) -and @(Get-TransactionArtifacts).Count -eq 3) 'publish/txn 同步原地改写后 transaction 未完整失败闭锁'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($publishInPlacePath))) -ceq $publishInPlaceSha) 'publish 原地改写对象被删除或覆盖'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($txnInPlacePath))) -ceq (Get-BytesSha256 -Bytes $txnSynchronizedBytes)) '同步 afterSha256 的 txn 被删除或覆盖'
    foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }

    foreach ($abortMutationKind in @('same-length-whitespace', 'different-length-whitespace')) {
        $abortInPlaceVendor = New-TargetCatalog -ExtraEntries @([ordered]@{ id = "keep-abort-in-place-$abortMutationKind"; name = "abort-in-place-$abortMutationKind"; payload = 'vendor-must-survive' })
        $abortInPlaceVendorBytes = $utf8.GetBytes((($abortInPlaceVendor | ConvertTo-Json -Depth 32) + "`n"))
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $abortInPlaceInterrupted = Invoke-GuardSweep -PostIsolationReplacementBytes $abortInPlaceVendorBytes -VendorAbortExit 'after-phase'
        Assert-True ($abortInPlaceInterrupted.exitCode -eq 88 -and @(Get-TransactionArtifacts).Count -eq 4) "vendor-abort 原地改写前置 transaction 未形成：kind=$abortMutationKind invocation=$($abortInPlaceInterrupted | ConvertTo-Json -Compress -Depth 8)"
        $abortInPlacePath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.vendor-abort'
        $abortInPlaceBytes = if ($abortMutationKind -ceq 'same-length-whitespace') {
            Get-SameLengthJsonWhitespaceMutation -Path $abortInPlacePath
        } else {
            Get-DifferentLengthJsonWhitespaceMutation -Path $abortInPlacePath
        }
        [void](Write-InPlacePreservingIdentity -Path $abortInPlacePath -Bytes $abortInPlaceBytes)
        $abortInPlaceRecovery = Invoke-GuardSweep
        Assert-Blocked -Invocation $abortInPlaceRecovery -ExitCode 2 -Code 'catalog-transaction-conflict' -Label "same-identity vendor-abort in-place rewrite $abortMutationKind"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 4) "vendor-abort 原地改写后 transaction 未完整失败闭锁：$abortMutationKind"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($abortInPlacePath))) -ceq (Get-BytesSha256 -Bytes $abortInPlaceBytes)) "vendor-abort 原地改写对象被删除或覆盖：$abortMutationKind"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $abortInPlaceVendorBytes)) "vendor-abort 原地改写覆盖了 vendor canonical：$abortMutationKind"
        foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }
        [IO.File]::Delete($catalogPath)
    }

    $malformedBytes = $utf8.GetBytes('{"schema_version":1,"plugins":[')
    [IO.File]::WriteAllBytes($catalogPath, $malformedBytes)
    $malformed = Invoke-GuardSweep
    Assert-Blocked -Invocation $malformed -ExitCode 2 -Code 'malformed-json' -Label 'malformed JSON'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $malformedBytes)) 'malformed JSON 原文件字节被覆盖'
    [IO.File]::Delete($catalogPath)

    Write-JsonFile -Path $catalogPath -Value ([ordered]@{ schema_version = 1; plugins = @([ordered]@{ id = 'wrong-id'; name = 'heygen' }) })
    $pairBytes = [IO.File]::ReadAllBytes($catalogPath)
    $pairMismatch = Invoke-GuardSweep
    Assert-Blocked -Invocation $pairMismatch -ExitCode 2 -Code 'target-pair-mismatch' -Label 'target pair mismatch'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $pairBytes)) 'pair mismatch 原文件字节被覆盖'
    [IO.File]::Delete($catalogPath)

    Write-JsonFile -Path $catalogPath -Value ([ordered]@{ schema_version = 1; nested = [ordered]@{ plugins = @((New-TargetCatalog).plugins) } })
    $schemaBytes = [IO.File]::ReadAllBytes($catalogPath)
    $schemaDrift = Invoke-GuardSweep
    Assert-Blocked -Invocation $schemaDrift -ExitCode 2 -Code 'catalog-schema-drift' -Label 'schema path drift'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $schemaBytes)) 'schema drift 原文件字节被覆盖'
    [IO.File]::Delete($catalogPath)

    foreach ($fetchedAt in @('2026-07-30T16:17:38.598434Z', '2026-08-01T21:51:59.725144300Z')) {
        Write-JsonFile -Path $catalogPath -Value ([ordered]@{ schema_version = 1; fetched_at = $fetchedAt; plugins = @((New-TargetCatalog).plugins) })
        $fetchedSchema = Invoke-GuardSweep
        Assert-True ($fetchedSchema.exitCode -eq 0 -and $fetchedSchema.result.removedCount -eq 1) "带 fetched_at 的官方 schema v1 必须受支持：timestamp=$fetchedAt exit=$($fetchedSchema.exitCode) result=$($fetchedSchema.result | ConvertTo-Json -Compress -Depth 8) stderr=$($fetchedSchema.stderr)"
        $fetchedAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32 -DateKind String
        Assert-True ($fetchedAfter.fetched_at -ceq $fetchedAt -and (@($fetchedAfter.plugins.name) -join ',') -ceq 'before,after') 'fetched_at 或非目标条目未保留'
        [IO.File]::Delete($catalogPath)
    }

    $fetchedAtWithTrailingLf = '2026-08-01T21:51:59.725144300Z' + [char]10
    Write-JsonFile -Path $catalogPath -Value ([ordered]@{ schema_version = 1; fetched_at = $fetchedAtWithTrailingLf; plugins = @((New-TargetCatalog).plugins) })
    $fetchedAtWithTrailingLfBytes = [IO.File]::ReadAllBytes($catalogPath)
    $fetchedAtWithTrailingLfResult = Invoke-GuardSweep
    Assert-Blocked -Invocation $fetchedAtWithTrailingLfResult -ExitCode 2 -Code 'catalog-schema-drift' -Label 'fetched_at trailing LF'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $fetchedAtWithTrailingLfBytes)) '带 trailing LF 的 fetched_at 原文件字节被覆盖'
    [IO.File]::Delete($catalogPath)

    $sentinelRoot = Join-Path $fixtureRoot 'sentinels'
    [void][IO.Directory]::CreateDirectory($sentinelRoot)
    $hardlinkSource = Join-Path $sentinelRoot 'hardlink-source.json'
    Write-JsonFile -Path $hardlinkSource -Value (New-TargetCatalog)
    [void](New-Item -ItemType HardLink -Path $catalogPath -Target $hardlinkSource -ErrorAction Stop)
    $hardlinkBytes = [IO.File]::ReadAllBytes($hardlinkSource)
    $hardlink = Invoke-GuardSweep
    Assert-Blocked -Invocation $hardlink -ExitCode 2 -Code 'hard-link' -Label 'hardlink catalog'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($hardlinkSource))) -ceq (Get-BytesSha256 -Bytes $hardlinkBytes)) 'hardlink source 被覆盖'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $hardlinkBytes)) 'hardlink catalog 被覆盖'
    [IO.File]::Delete($catalogPath)
    [IO.File]::Delete($hardlinkSource)

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $beforeHashDrift = [IO.File]::ReadAllBytes($catalogPath)
    $expectedHashDrift = [byte[]]::new($beforeHashDrift.Length + 2)
    [Array]::Copy($beforeHashDrift, $expectedHashDrift, $beforeHashDrift.Length)
    $expectedHashDrift[$expectedHashDrift.Length - 2] = [byte][char]' '
    $expectedHashDrift[$expectedHashDrift.Length - 1] = [byte]10
    $hashDrift = Invoke-GuardSweep -Mutation 'hash-drift'
    Assert-Blocked -Invocation $hashDrift -ExitCode 2 -Code 'catalog-hash-drift' -Label 'hash race'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $expectedHashDrift)) 'hash race 的竞争写入被 guard 覆盖'
    [IO.File]::Delete($catalogPath)

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $beforeIdentityDrift = [IO.File]::ReadAllBytes($catalogPath)
    $identityDrift = Invoke-GuardSweep -Mutation 'identity-drift'
    Assert-Blocked -Invocation $identityDrift -ExitCode 2 -Code 'catalog-identity-drift' -Label 'identity race'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $beforeIdentityDrift)) 'identity race replacement bytes 被 guard 覆盖'
    [IO.File]::Delete($catalogPath)

    $unknownArtifactPath = Join-Path $catalogRoot '.codex-catalog-guard-bbbbbbbbbbbbbbbb.quarantine'
    $unknownArtifactBytes = $utf8.GetBytes("unknown transaction artifact`n")
    [IO.File]::WriteAllBytes($unknownArtifactPath, $unknownArtifactBytes)
    $unknownArtifact = Invoke-GuardSweep
    Assert-Blocked -Invocation $unknownArtifact -ExitCode 2 -Code 'catalog-transaction-unknown-artifact' -Label 'unknown transaction artifact'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($unknownArtifactPath))) -ceq (Get-BytesSha256 -Bytes $unknownArtifactBytes)) '未知 transaction artifact 被修改或误删'
    [IO.File]::Delete($unknownArtifactPath)

    $caseVariantArtifacts = @(
        '.codex-catalog-guard-AAAAAAAAAAAAAAAA.stage-ffffffffffffffffffffffffffffffff.txn'
        '.codex-catalog-guard-AAAAAAAAAAAAAAAA.txn'
        '.codex-catalog-guard-AAAAAAAAAAAAAAAA.publish'
        '.codex-catalog-guard-AAAAAAAAAAAAAAAA.quarantine'
        '.codex-catalog-guard-AAAAAAAAAAAAAAAA.vendor-abort'
    )
    foreach ($caseVariantLeaf in $caseVariantArtifacts) {
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $caseVariantCanonicalBytes = [IO.File]::ReadAllBytes($catalogPath)
        $caseVariantPath = Join-Path $catalogRoot $caseVariantLeaf
        $caseVariantBytes = $utf8.GetBytes("case-variant artifact must survive: $caseVariantLeaf`n")
        [IO.File]::WriteAllBytes($caseVariantPath, $caseVariantBytes)

        $caseVariantSweep = Invoke-GuardSweep
        Assert-Blocked -Invocation $caseVariantSweep -ExitCode 2 -Code 'catalog-transaction-unknown-artifact' -Label "case-variant Sweep $caseVariantLeaf"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $caseVariantCanonicalBytes)) "case-variant Sweep 修改了对应 canonical：$caseVariantLeaf"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($caseVariantPath))) -ceq (Get-BytesSha256 -Bytes $caseVariantBytes)) "case-variant Sweep 修改了未知 artifact：$caseVariantLeaf"

        $caseVariantAudit = Invoke-GuardAudit -FixturePolicyPath $policyPath
        Assert-True ($caseVariantAudit.exitCode -eq 2 -and $caseVariantAudit.result.blocked[0].code -ceq 'catalog-transaction-unknown-artifact') "case-variant Audit 未报红：$caseVariantLeaf"
        $caseVariantCheck = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath
        Assert-True ($caseVariantCheck.exitCode -eq 2 -and @($caseVariantCheck.result.drift) -ccontains 'catalog:blocked' -and $caseVariantCheck.result.catalog.blocked[0].code -ceq 'catalog-transaction-unknown-artifact') "case-variant Check 未报红：$caseVariantLeaf"

        [IO.File]::Delete($caseVariantPath)
        [IO.File]::Delete($catalogPath)
    }

    foreach ($artifact in @('txn', 'publish')) {
        foreach ($point in @('after-create', 'mid-write', 'after-flush')) {
            Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
            $stageBeforeBytes = [IO.File]::ReadAllBytes($catalogPath)
            $stageFault = Invoke-GuardSweep -StageExit "${artifact}:$point"
            Assert-True ($stageFault.exitCode -eq 87 -and $null -eq $stageFault.result) "staging fault 未在确定点退出：artifact=$artifact point=$point exit=$($stageFault.exitCode) stderr=$($stageFault.stderr)"
            Assert-True (@(Get-StagingArtifacts).Count -eq 0) "staging fault 在进程退出后残留 staging：artifact=$artifact point=$point"
            Assert-True ([IO.File]::Exists($catalogPath)) "staging fault 导致 canonical 消失：artifact=$artifact point=$point"
            Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $stageBeforeBytes)) "staging fault 覆盖 canonical：artifact=$artifact point=$point"
            Assert-True (@(Get-TransactionArtifacts).Count -eq 0) "staging fault 在首次 identity binding 前留下最终事务产物：artifact=$artifact point=$point"
            $stageRecovery = Invoke-GuardSweep
            Assert-True ($stageRecovery.exitCode -eq 0 -and $stageRecovery.result.removedCount -eq 1) "staging fault 重启后未恢复：artifact=$artifact point=$point invocation=$($stageRecovery | ConvertTo-Json -Compress -Depth 8)"
            Assert-True (@(Get-TransactionArtifacts).Count -eq 0 -and @(Get-StagingArtifacts).Count -eq 0) "staging fault 重启后仍有事务残留：artifact=$artifact point=$point"
            $stageAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
            Assert-True ((@($stageAfter.plugins.name) -join ',') -ceq 'before,after') "staging fault 重启后未精确过滤：artifact=$artifact point=$point"
            [IO.File]::Delete($catalogPath)
        }
    }

    foreach ($durableArtifact in @('txn', 'publish')) {
        foreach ($durablePoint in @('after-clear', 'after-rename', 'after-second-open')) {
            Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
            $durableBeforeBytes = [IO.File]::ReadAllBytes($catalogPath)
            $durableFault = Invoke-GuardSweep -DurableRenameExit "${durableArtifact}:$durablePoint"
            Assert-True ($durableFault.exitCode -eq 89 -and $null -eq $durableFault.result) "durable rename 未在确定点退出：artifact=$durableArtifact point=$durablePoint exit=$($durableFault.exitCode) stderr=$($durableFault.stderr)"
            Assert-True ([IO.File]::Exists($catalogPath)) "durable rename 中断导致 canonical 消失：artifact=$durableArtifact point=$durablePoint"
            Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $durableBeforeBytes)) "durable rename 中断覆盖 canonical：artifact=$durableArtifact point=$durablePoint"
            if ($durablePoint -ceq 'after-clear') {
                Assert-True (@(Get-StagingArtifacts).Count -eq 1) "after-clear 未留下唯一可识别 staging：artifact=$durableArtifact"
            } else {
                Assert-True (@(Get-StagingArtifacts).Count -eq 0) "rename 后仍残留 staging：artifact=$durableArtifact point=$durablePoint"
            }
            $durableRecovery = Invoke-GuardSweep
            Assert-True ($durableRecovery.exitCode -eq 0 -and $durableRecovery.result.removedCount -eq 1) "durable rename 重启未收敛：artifact=$durableArtifact point=$durablePoint invocation=$($durableRecovery | ConvertTo-Json -Compress -Depth 8)"
            Assert-True (@(Get-TransactionArtifacts).Count -eq 0 -and @(Get-StagingArtifacts).Count -eq 0) "durable rename 重启残留 artifact：artifact=$durableArtifact point=$durablePoint"
            $durableAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
            Assert-True ((@($durableAfter.plugins.name) -join ',') -ceq 'before,after') "durable rename 重启未精确过滤：artifact=$durableArtifact point=$durablePoint"
            [IO.File]::Delete($catalogPath)
        }
    }

    foreach ($durableProbePoint in @('after-clear', 'after-rename', 'after-second-open')) {
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $durableProbe = Invoke-GuardSweepWithDurablePublicationProbe -Point $durableProbePoint
        Assert-True ($durableProbe.exitCode -eq 0 -and $durableProbe.result.removedCount -eq 1) "durable publication probe 未完成 Sweep：point=$durableProbePoint result=$($durableProbe | ConvertTo-Json -Compress -Depth 8)"
        Assert-True ($durableProbe.renameDenied -and $durableProbe.replaceDenied -and $durableProbe.deleteDenied -and $durableProbe.protectedUnchanged) "durable publication 句柄未拒绝真实 writer：point=$durableProbePoint"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0 -and @(Get-StagingArtifacts).Count -eq 0) "durable publication probe 残留 artifact：$durableProbePoint"
        [IO.File]::Delete($catalogPath)
    }

    foreach ($normalLeasePoint in @('normal-publish:before-quarantine-delete', 'normal-publish:before-txn-delete')) {
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $normalLeaseProbe = Invoke-GuardSweepWithCanonicalLeaseProbe -PausePoint $normalLeasePoint
        Assert-True ($normalLeaseProbe.exitCode -eq 0 -and $normalLeaseProbe.result.removedCount -eq 1) "normal publish lease probe 未完成 Sweep：point=$normalLeasePoint result=$($normalLeaseProbe | ConvertTo-Json -Compress -Depth 8)"
        Assert-True ($normalLeaseProbe.renameDenied -and $normalLeaseProbe.replaceDenied -and $normalLeaseProbe.deleteDenied -and $normalLeaseProbe.canonicalUnchanged) "normal publish canonical lease 未拒绝真实 writer：point=$normalLeasePoint"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0) "normal publish lease probe 残留 transaction：$normalLeasePoint"
        [IO.File]::Delete($catalogPath)
    }

    foreach ($restartLeasePoint in @('restart-publish:before-quarantine-delete', 'restart-publish:before-txn-delete')) {
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $restartLeaseInterrupted = Invoke-GuardSweep -InterruptAfterQuarantine
        Assert-True ($restartLeaseInterrupted.exitCode -eq 86 -and -not [IO.File]::Exists($catalogPath) -and @(Get-TransactionArtifacts).Count -eq 3) "restart publish lease probe 前置 transaction 失败：$restartLeasePoint"
        $restartLeaseProbe = Invoke-GuardSweepWithCanonicalLeaseProbe -PausePoint $restartLeasePoint
        Assert-True ($restartLeaseProbe.exitCode -eq 0 -and $restartLeaseProbe.result.ok -eq $true) "restart publish lease probe 未完成 Sweep：point=$restartLeasePoint result=$($restartLeaseProbe | ConvertTo-Json -Compress -Depth 8)"
        Assert-True ($restartLeaseProbe.renameDenied -and $restartLeaseProbe.replaceDenied -and $restartLeaseProbe.deleteDenied -and $restartLeaseProbe.canonicalUnchanged) "restart publish canonical lease 未拒绝真实 writer：point=$restartLeasePoint"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0) "restart publish lease probe 残留 transaction：$restartLeasePoint"
        [IO.File]::Delete($catalogPath)
    }

    foreach ($rollbackLeasePoint in @('rollback:before-publish-delete', 'rollback:before-txn-delete')) {
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $rollbackLeaseBeforeBytes = [IO.File]::ReadAllBytes($catalogPath)
        $rollbackLeaseProbe = Invoke-GuardSweepWithCanonicalLeaseProbe -PausePoint $rollbackLeasePoint -PublishFailure 'io'
        Assert-True ($rollbackLeaseProbe.exitCode -eq 2 -and $rollbackLeaseProbe.result.blocked[0].code -ceq 'catalog-publish-io-failure') "rollback lease probe 未保留原始 publish failure：point=$rollbackLeasePoint result=$($rollbackLeaseProbe | ConvertTo-Json -Compress -Depth 8)"
        Assert-True ($rollbackLeaseProbe.renameDenied -and $rollbackLeaseProbe.replaceDenied -and $rollbackLeaseProbe.deleteDenied -and $rollbackLeaseProbe.canonicalUnchanged) "rollback canonical lease 未拒绝真实 writer：point=$rollbackLeasePoint"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $rollbackLeaseBeforeBytes)) "rollback lease probe 未恢复原 canonical：$rollbackLeasePoint"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0) "rollback lease probe 残留 transaction：$rollbackLeasePoint"
        [IO.File]::Delete($catalogPath)
    }

    foreach ($vendorLeasePoint in @(
        'vendor-abort:before-quarantine-delete',
        'vendor-abort:before-publish-delete',
        'vendor-abort:before-txn-delete',
        'vendor-abort:before-abort-delete'
    )) {
        $vendorLeaseCatalog = New-TargetCatalog -ExtraEntries @([ordered]@{ id = "keep-$($vendorLeasePoint.Replace(':', '-'))"; name = "lease-$($vendorLeasePoint.Replace(':', '-'))"; payload = 'vendor-must-survive' })
        $vendorLeaseBytes = $utf8.GetBytes((($vendorLeaseCatalog | ConvertTo-Json -Depth 32) + "`n"))
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $vendorLeaseProbe = Invoke-GuardSweepWithCanonicalLeaseProbe -PausePoint $vendorLeasePoint -PostIsolationReplacementBytes $vendorLeaseBytes
        Assert-True ($vendorLeaseProbe.exitCode -eq 2 -and $vendorLeaseProbe.result.blocked[0].code -ceq 'catalog-publish-race') "vendor-abort lease probe 未保留 CAS 结果：point=$vendorLeasePoint result=$($vendorLeaseProbe | ConvertTo-Json -Compress -Depth 8)"
        Assert-True ($vendorLeaseProbe.renameDenied -and $vendorLeaseProbe.replaceDenied -and $vendorLeaseProbe.deleteDenied -and $vendorLeaseProbe.canonicalUnchanged) "vendor-abort canonical lease 未拒绝真实 writer：point=$vendorLeasePoint"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $vendorLeaseBytes)) "vendor-abort lease probe 覆盖了 vendor canonical：$vendorLeasePoint"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0) "vendor-abort lease probe 残留 transaction：$vendorLeasePoint"
        [IO.File]::Delete($catalogPath)
    }

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $unknownStageCanonicalBytes = [IO.File]::ReadAllBytes($catalogPath)
    $unknownStagePath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.stage-ffffffffffffffffffffffffffffffff.txn'
    $unknownStageBytes = $utf8.GetBytes("unknown staging object`n")
    [IO.File]::WriteAllBytes($unknownStagePath, $unknownStageBytes)
    $unknownStage = Invoke-GuardSweep
    Assert-Blocked -Invocation $unknownStage -ExitCode 2 -Code 'catalog-transaction-unknown-artifact' -Label 'unknown staging artifact'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($unknownStagePath))) -ceq (Get-BytesSha256 -Bytes $unknownStageBytes)) '未知 staging 被修改或误删'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $unknownStageCanonicalBytes)) '未知 staging 存在时 guard 仍覆盖了对应 canonical'
    [IO.File]::Delete($unknownStagePath)
    [IO.File]::Delete($catalogPath)

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $publishFailureBytes = [IO.File]::ReadAllBytes($catalogPath)
    $publishFailure = Invoke-GuardSweep -PublishFailure 'io'
    Assert-Blocked -Invocation $publishFailure -ExitCode 2 -Code 'catalog-publish-io-failure' -Label 'publish I/O failure'
    Assert-True ([IO.File]::Exists($catalogPath)) 'publish I/O failure 后 canonical 消失'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $publishFailureBytes)) 'publish I/O failure 未恢复原 canonical 字节'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 0) 'publish I/O failure 恢复后残留 transaction artifact'
    $publishFailureRetry = Invoke-GuardSweep
    Assert-True ($publishFailureRetry.exitCode -eq 0 -and $publishFailureRetry.result.removedCount -eq 1) 'publish I/O failure 后续 sweep 未收敛'
    [IO.File]::Delete($catalogPath)

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $interruptedBeforeBytes = [IO.File]::ReadAllBytes($catalogPath)
    $interrupted = Invoke-GuardSweep -InterruptAfterQuarantine
    Assert-True ($interrupted.exitCode -eq 86 -and $null -eq $interrupted.result) "隔离后中断未在确定点终止：exit=$($interrupted.exitCode) stderr=$($interrupted.stderr)"
    Assert-True (-not [IO.File]::Exists($catalogPath)) '隔离后中断 fixture 未形成 canonical 缺口'
    $interruptedArtifacts = @(Get-TransactionArtifacts)
    $expectedInterruptedLeaves = @(
        '.codex-catalog-guard-aaaaaaaaaaaaaaaa.publish'
        '.codex-catalog-guard-aaaaaaaaaaaaaaaa.quarantine'
        '.codex-catalog-guard-aaaaaaaaaaaaaaaa.txn'
    )
    Assert-True (($interruptedArtifacts.Name -join "`0") -ceq ($expectedInterruptedLeaves -join "`0")) '隔离后中断未保留确定命名的完整受管 transaction'
    $interruptedQuarantinePath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.quarantine'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($interruptedQuarantinePath))) -ceq (Get-BytesSha256 -Bytes $interruptedBeforeBytes)) 'quarantine 不等于已验证旧 canonical'
    $interruptedMarker = Get-Content -Raw -LiteralPath (Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.txn') | ConvertFrom-Json -Depth 16
    Assert-True ($interruptedMarker.schemaVersion -eq 2 -and $interruptedMarker.canonicalLeaf -ceq 'aaaaaaaaaaaaaaaa.json' -and $interruptedMarker.quarantineLeaf -ceq '.codex-catalog-guard-aaaaaaaaaaaaaaaa.quarantine' -and $interruptedMarker.publishLeaf -ceq '.codex-catalog-guard-aaaaaaaaaaaaaaaa.publish' -and @($interruptedMarker.txnIdentity).Count -eq 2 -and @($interruptedMarker.publishIdentity).Count -eq 2) 'transaction marker schema、路径或 artifact identity binding 漂移'
    Assert-True ($interruptedMarker.beforeSha256 -ceq (Get-BytesSha256 -Bytes $interruptedBeforeBytes) -and @($interruptedMarker.beforeIdentity).Count -eq 2) 'transaction marker 未绑定旧对象 hash/identity'
    $interruptedAudit = Invoke-GuardAudit -FixturePolicyPath $policyPath
    Assert-True ($interruptedAudit.exitCode -eq 2 -and $interruptedAudit.result.blocked[0].code -ceq 'catalog-transaction-pending') 'Audit 未对未解决 transaction 报红'
    $interruptedRecovery = Invoke-GuardSweep
    Assert-True ($interruptedRecovery.exitCode -eq 0 -and [IO.File]::Exists($catalogPath)) '后续 sweep 未恢复隔离后中断 transaction'
    $interruptedAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
    Assert-True ((@($interruptedAfter.plugins.name) -join ',') -ceq 'before,after') '中断恢复未发布过滤后的 catalog'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 0) '中断恢复后残留 transaction artifact'
    $interruptedHash = Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))
    $interruptedIdempotent = Invoke-GuardSweep
    Assert-True ($interruptedIdempotent.exitCode -eq 0 -and $interruptedIdempotent.result.removedCount -eq 0) 'transaction 清理后二次 sweep 非幂等'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 0 -and (Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath)) -ceq $interruptedHash)) 'transaction 二次清理改变 canonical 或重建 artifact'
    [IO.File]::Delete($catalogPath)

    foreach ($identityArtifactKind in @('txn', 'publish')) {
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $identityInterrupted = Invoke-GuardSweep -InterruptAfterQuarantine
        Assert-True ($identityInterrupted.exitCode -eq 86 -and @(Get-TransactionArtifacts).Count -eq 3) "identity replacement 前置 transaction 失败：$identityArtifactKind"
        $identityArtifactPath = Join-Path $catalogRoot ".codex-catalog-guard-aaaaaaaaaaaaaaaa.$identityArtifactKind"
        $identityReplacementBytes = Replace-FileWithSameBytes -Path $identityArtifactPath
        $identityReplacement = Invoke-GuardSweep
        Assert-Blocked -Invocation $identityReplacement -ExitCode 2 -Code 'catalog-transaction-conflict' -Label "same-byte $identityArtifactKind identity replacement"
        Assert-True ([IO.File]::Exists($identityArtifactPath)) "same-byte $identityArtifactKind replacement 被误删"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($identityArtifactPath))) -ceq (Get-BytesSha256 -Bytes $identityReplacementBytes)) "same-byte $identityArtifactKind replacement 内容被改写"
        foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }
        if ([IO.File]::Exists($catalogPath)) { [IO.File]::Delete($catalogPath) }
    }

    $abortIdentityVendor = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-abort-identity'; name = 'abort-identity'; payload = 'vendor-must-survive' })
    $abortIdentityVendorBytes = $utf8.GetBytes((($abortIdentityVendor | ConvertTo-Json -Depth 32) + "`n"))
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $abortIdentityInterrupted = Invoke-GuardSweep -PostIsolationReplacementBytes $abortIdentityVendorBytes -VendorAbortExit 'after-phase'
    Assert-True ($abortIdentityInterrupted.exitCode -eq 88 -and @(Get-TransactionArtifacts).Count -eq 4) 'vendor-abort identity replacement 前置 transaction 失败'
    $abortIdentityPath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.vendor-abort'
    $abortIdentityReplacementBytes = Replace-FileWithSameBytes -Path $abortIdentityPath
    $abortIdentityReplacement = Invoke-GuardSweep
    Assert-Blocked -Invocation $abortIdentityReplacement -ExitCode 2 -Code 'catalog-transaction-conflict' -Label 'same-byte vendor-abort identity replacement'
    Assert-True ([IO.File]::Exists($abortIdentityPath)) 'same-byte vendor-abort replacement 被误删'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($abortIdentityPath))) -ceq (Get-BytesSha256 -Bytes $abortIdentityReplacementBytes)) 'same-byte vendor-abort replacement 内容被改写'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $abortIdentityVendorBytes)) 'vendor-abort identity replacement 覆盖了 vendor canonical'
    foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }
    [IO.File]::Delete($catalogPath)

    $markerReplacementBytes = $utf8.GetBytes("replacement transaction marker must survive`n")
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $successMarkerReplacement = Invoke-GuardSweep -MarkerCleanupReplacementBytes $markerReplacementBytes
    Assert-Blocked -Invocation $successMarkerReplacement -ExitCode 2 -Code 'catalog-transaction-conflict' -Label 'success marker cleanup replacement'
    $successReplacementPath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.txn'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($successReplacementPath))) -ceq (Get-BytesSha256 -Bytes $markerReplacementBytes)) 'success cleanup 删除了 replacement marker'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 1) 'success cleanup marker replacement 后 artifact 状态异常'
    [IO.File]::Delete($successReplacementPath)
    [IO.File]::Delete($catalogPath)

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $rollbackBeforeBytes = [IO.File]::ReadAllBytes($catalogPath)
    $rollbackMarkerReplacement = Invoke-GuardSweep -PublishFailure 'io' -MarkerCleanupReplacementBytes $markerReplacementBytes
    Assert-Blocked -Invocation $rollbackMarkerReplacement -ExitCode 2 -Code 'catalog-transaction-conflict' -Label 'rollback marker cleanup replacement'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $rollbackBeforeBytes)) 'rollback marker replacement 路径未恢复旧 canonical'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($successReplacementPath))) -ceq (Get-BytesSha256 -Bytes $markerReplacementBytes)) 'rollback cleanup 删除了 replacement marker'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 1) 'rollback cleanup marker replacement 后 artifact 状态异常'
    [IO.File]::Delete($successReplacementPath)
    [IO.File]::Delete($catalogPath)

    $vendorMarkerReplacementCatalog = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-marker-vendor'; name = 'marker-vendor'; payload = 'vendor-must-survive' })
    $vendorMarkerReplacementBytes = $utf8.GetBytes((($vendorMarkerReplacementCatalog | ConvertTo-Json -Depth 32) + "`n"))
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $vendorMarkerReplacement = Invoke-GuardSweep -PostIsolationReplacementBytes $vendorMarkerReplacementBytes -MarkerCleanupReplacementBytes $markerReplacementBytes
    Assert-Blocked -Invocation $vendorMarkerReplacement -ExitCode 2 -Code 'catalog-transaction-conflict' -Label 'vendor-abort marker cleanup replacement'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $vendorMarkerReplacementBytes)) 'vendor-abort marker replacement 覆盖了 vendor canonical'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($successReplacementPath))) -ceq (Get-BytesSha256 -Bytes $markerReplacementBytes)) 'vendor-abort cleanup 删除了 replacement marker'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 2) 'vendor-abort marker replacement 后应只保留 replacement txn 与 abort marker'
    $vendorMarkerReplacementRetry = Invoke-GuardSweep
    Assert-Blocked -Invocation $vendorMarkerReplacementRetry -ExitCode 2 -Code 'catalog-transaction-conflict' -Label 'vendor-abort replacement marker restart'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 2 -and (Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($successReplacementPath)) -ceq (Get-BytesSha256 -Bytes $markerReplacementBytes))) 'vendor-abort restart 误删 replacement marker 或 abort marker'
    foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }
    [IO.File]::Delete($catalogPath)

    $casReplacement = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-cas-race'; name = 'vendor-cas-race'; payload = 'newer-vendor-object' })
    $casReplacementBytes = $utf8.GetBytes((($casReplacement | ConvertTo-Json -Depth 32) + "`n"))
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $casRace = Invoke-GuardSweep -PostIsolationReplacementBytes $casReplacementBytes
    Assert-Blocked -Invocation $casRace -ExitCode 2 -Code 'catalog-publish-race' -Label 'post-isolation CAS race'
    Assert-True ($casRace.result.pendingRetryCount -eq 1) 'CAS race 必须进入 pending retry'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $casReplacementBytes)) 'CAS race 的 vendor 新对象被 guard 旧内容覆盖'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 0) 'CAS race abort 后残留 transaction artifact'
    $casRetry = Invoke-GuardSweep
    Assert-True ($casRetry.exitCode -eq 0 -and $casRetry.result.removedCount -eq 1) 'CAS race 后续 sweep 未正确重试收敛'
    $casAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
    Assert-True ((@($casAfter.plugins.name) -join ',') -ceq 'before,after,vendor-cas-race') 'CAS race 重试未保留 vendor 新对象的非目标内容和顺序'
    [IO.File]::Delete($catalogPath)

    foreach ($vendorAbortPoint in @('after-phase', 'after-quarantine-delete', 'after-publish-delete', 'after-txn-delete', 'after-abort-delete')) {
        $vendorAbortReplacement = New-TargetCatalog -ExtraEntries @([ordered]@{ id = "keep-vendor-abort-$vendorAbortPoint"; name = "vendor-abort-$vendorAbortPoint"; payload = 'must-survive-abort' })
        $vendorAbortReplacementBytes = $utf8.GetBytes((($vendorAbortReplacement | ConvertTo-Json -Depth 32) + "`n"))
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $vendorAbortFault = Invoke-GuardSweep -PostIsolationReplacementBytes $vendorAbortReplacementBytes -VendorAbortExit $vendorAbortPoint
        Assert-True ($vendorAbortFault.exitCode -eq 88 -and $null -eq $vendorAbortFault.result) "vendor-abort 未在确定点退出：point=$vendorAbortPoint exit=$($vendorAbortFault.exitCode) stderr=$($vendorAbortFault.stderr)"
        Assert-True ([IO.File]::Exists($catalogPath)) "vendor-abort 中断导致 canonical 消失：point=$vendorAbortPoint"
        Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $vendorAbortReplacementBytes)) "vendor-abort 中断覆盖 vendor canonical：point=$vendorAbortPoint"
        $expectedArtifactCount = switch ($vendorAbortPoint) {
            'after-phase' { 4 }
            'after-quarantine-delete' { 3 }
            'after-publish-delete' { 2 }
            'after-txn-delete' { 1 }
            'after-abort-delete' { 0 }
        }
        Assert-True (@(Get-TransactionArtifacts).Count -eq $expectedArtifactCount) "vendor-abort 中断后的 transaction 数量错误：point=$vendorAbortPoint"
        if ($vendorAbortPoint -cne 'after-abort-delete') {
            $vendorAbortMarker = Get-Content -Raw -LiteralPath (Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.vendor-abort') | ConvertFrom-Json -Depth 16
            Assert-True ($vendorAbortMarker.phase -ceq 'vendor-abort' -and $vendorAbortMarker.vendorSha256 -ceq (Get-BytesSha256 -Bytes $vendorAbortReplacementBytes) -and @($vendorAbortMarker.vendorIdentity).Count -eq 2) "vendor-abort marker 未持久绑定 vendor：point=$vendorAbortPoint"
        }
        $vendorAbortRecovery = Invoke-GuardSweep
        Assert-True ($vendorAbortRecovery.exitCode -eq 0 -and $vendorAbortRecovery.result.removedCount -eq 1) "vendor-abort 重启后未收敛：point=$vendorAbortPoint invocation=$($vendorAbortRecovery | ConvertTo-Json -Compress -Depth 8)"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0) "vendor-abort 重启后残留 transaction：point=$vendorAbortPoint"
        $vendorAbortAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
        Assert-True ((@($vendorAbortAfter.plugins.name) -join ',') -ceq "before,after,vendor-abort-$vendorAbortPoint") "vendor-abort 重启未保留 vendor 非目标内容：point=$vendorAbortPoint"
        [IO.File]::Delete($catalogPath)
    }

    foreach ($vendorAbortStagePoint in @('after-create', 'mid-write', 'after-flush')) {
        $vendorAbortStageCatalog = New-TargetCatalog -ExtraEntries @([ordered]@{ id = "keep-abort-stage-$vendorAbortStagePoint"; name = "abort-stage-$vendorAbortStagePoint"; payload = 'vendor-must-survive' })
        $vendorAbortStageBytes = $utf8.GetBytes((($vendorAbortStageCatalog | ConvertTo-Json -Depth 32) + "`n"))
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $vendorAbortStageFault = Invoke-GuardSweep -PostIsolationReplacementBytes $vendorAbortStageBytes -StageExit "vendor-abort:$vendorAbortStagePoint"
        Assert-True ($vendorAbortStageFault.exitCode -eq 87 -and $null -eq $vendorAbortStageFault.result) "vendor-abort staging 未在确定点退出：point=$vendorAbortStagePoint exit=$($vendorAbortStageFault.exitCode) stderr=$($vendorAbortStageFault.stderr)"
        Assert-True ([IO.File]::Exists($catalogPath) -and (Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath)) -ceq (Get-BytesSha256 -Bytes $vendorAbortStageBytes))) "vendor-abort staging 中断覆盖 vendor canonical：point=$vendorAbortStagePoint"
        Assert-True (@(Get-StagingArtifacts).Count -eq 0 -and @(Get-TransactionArtifacts).Count -eq 3) "vendor-abort staging 中断 artifact 状态错误：point=$vendorAbortStagePoint"
        $vendorAbortStageRecovery = Invoke-GuardSweep
        Assert-True ($vendorAbortStageRecovery.exitCode -eq 0 -and $vendorAbortStageRecovery.result.removedCount -eq 1) "vendor-abort staging 重启未重建 durable abort：point=$vendorAbortStagePoint invocation=$($vendorAbortStageRecovery | ConvertTo-Json -Compress -Depth 8)"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0 -and @(Get-StagingArtifacts).Count -eq 0) "vendor-abort staging 重启残留 artifact：point=$vendorAbortStagePoint"
        [IO.File]::Delete($catalogPath)
    }

    foreach ($vendorAbortDurablePoint in @('after-clear', 'after-rename', 'after-second-open')) {
        $vendorAbortDurableCatalog = New-TargetCatalog -ExtraEntries @([ordered]@{ id = "keep-abort-durable-$vendorAbortDurablePoint"; name = "abort-durable-$vendorAbortDurablePoint"; payload = 'vendor-must-survive' })
        $vendorAbortDurableBytes = $utf8.GetBytes((($vendorAbortDurableCatalog | ConvertTo-Json -Depth 32) + "`n"))
        Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
        $vendorAbortDurableFault = Invoke-GuardSweep -PostIsolationReplacementBytes $vendorAbortDurableBytes -DurableRenameExit "vendor-abort:$vendorAbortDurablePoint"
        Assert-True ($vendorAbortDurableFault.exitCode -eq 89 -and $null -eq $vendorAbortDurableFault.result) "vendor-abort durable rename 未在确定点退出：point=$vendorAbortDurablePoint exit=$($vendorAbortDurableFault.exitCode) stderr=$($vendorAbortDurableFault.stderr)"
        Assert-True ([IO.File]::Exists($catalogPath) -and (Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath)) -ceq (Get-BytesSha256 -Bytes $vendorAbortDurableBytes))) "vendor-abort durable rename 覆盖 vendor canonical：point=$vendorAbortDurablePoint"
        $vendorAbortDurableRecovery = Invoke-GuardSweep
        Assert-True ($vendorAbortDurableRecovery.exitCode -eq 0 -and $vendorAbortDurableRecovery.result.removedCount -eq 1) "vendor-abort durable rename 重启未收敛：point=$vendorAbortDurablePoint invocation=$($vendorAbortDurableRecovery | ConvertTo-Json -Compress -Depth 8)"
        Assert-True (@(Get-TransactionArtifacts).Count -eq 0 -and @(Get-StagingArtifacts).Count -eq 0) "vendor-abort durable rename 重启残留 artifact：point=$vendorAbortDurablePoint"
        [IO.File]::Delete($catalogPath)
    }

    $vendorAbortOriginal = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-vendor-abort-original'; name = 'vendor-abort-original'; payload = 'original-vendor' })
    $vendorAbortOriginalBytes = $utf8.GetBytes((($vendorAbortOriginal | ConvertTo-Json -Depth 32) + "`n"))
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $vendorAbortInterrupted = Invoke-GuardSweep -PostIsolationReplacementBytes $vendorAbortOriginalBytes -VendorAbortExit 'after-phase'
    Assert-True ($vendorAbortInterrupted.exitCode -eq 88 -and @(Get-TransactionArtifacts).Count -eq 4) 'vendor-abort vendor 漂移前置中断未形成完整 transaction'
    $vendorAbortChanged = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-vendor-abort-changed'; name = 'vendor-abort-changed'; payload = 'replacement-vendor' })
    $vendorAbortChangedBytes = $utf8.GetBytes((($vendorAbortChanged | ConvertTo-Json -Depth 32) + "`n"))
    $vendorAbortChangedTemp = Join-Path $catalogRoot 'vendor-abort-changed.tmp'
    [IO.File]::WriteAllBytes($vendorAbortChangedTemp, $vendorAbortChangedBytes)
    [IO.File]::Move($vendorAbortChangedTemp, $catalogPath, $true)
    $vendorAbortConflict = Invoke-GuardSweep
    Assert-Blocked -Invocation $vendorAbortConflict -ExitCode 2 -Code 'catalog-transaction-conflict' -Label 'vendor-abort vendor identity/hash drift'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $vendorAbortChangedBytes)) 'vendor-abort reconcile 覆盖了漂移后的 vendor canonical'
    Assert-True (@(Get-TransactionArtifacts).Count -eq 4) 'vendor-abort vendor 漂移时误删 transaction'
    foreach ($artifact in @(Get-TransactionArtifacts)) { [IO.File]::Delete($artifact.FullName) }
    [IO.File]::Delete($catalogPath)

    $fingerprintReplacement = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-fingerprint-race'; name = 'vendor-fingerprint-race'; payload = 'postprocess-object' })
    $fingerprintReplacementBytes = $utf8.GetBytes((($fingerprintReplacement | ConvertTo-Json -Depth 32) + "`n"))
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $fingerprintRace = Invoke-GuardSweep -PostprocessReplacementBytes $fingerprintReplacementBytes
    Assert-Blocked -Invocation $fingerprintRace -ExitCode 2 -Code 'catalog-postprocess-identity-drift' -Label 'postprocess fingerprint race'
    Assert-True ($fingerprintRace.result.pendingRetryCount -eq 1) 'fingerprint race 必须进入 pending retry，不能写入成功缓存'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $fingerprintReplacementBytes)) 'fingerprint race 的 vendor 新对象被覆盖'
    $fingerprintRetry = Invoke-GuardSweep
    Assert-True ($fingerprintRetry.exitCode -eq 0 -and $fingerprintRetry.result.removedCount -eq 1) 'fingerprint race 后续 sweep 未正确重试收敛'
    $fingerprintAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
    Assert-True ((@($fingerprintAfter.plugins.name) -join ',') -ceq 'before,after,vendor-fingerprint-race') 'fingerprint race 重试未保留 vendor 新对象的非目标内容和顺序'
    [IO.File]::Delete($catalogPath)

    $unsupportedPath = Join-Path $catalogRoot 'catalog.json'
    Write-JsonFile -Path $unsupportedPath -Value (New-TargetCatalog)
    $unsupportedBytes = [IO.File]::ReadAllBytes($unsupportedPath)
    $unsupported = Invoke-GuardSweep
    Assert-True ($unsupported.exitCode -eq 0 -and $unsupported.result.scannedCount -eq 0) '非 hash JSON 文件必须完全忽略'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($unsupportedPath))) -ceq (Get-BytesSha256 -Bytes $unsupportedBytes)) '非 hash JSON 文件被修改'
    [IO.File]::Delete($unsupportedPath)

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'plugin_asdk_app_69418aad55e08191aa5e437b649ca2e4'; name = 'heygen'; duplicate = $true }))
    $duplicates = Invoke-GuardSweep
    Assert-True ($duplicates.exitCode -eq 0 -and $duplicates.result.removedCount -eq 2) '重复的精确 name/id 配对必须全部移除'
    $duplicateAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
    Assert-True ((@($duplicateAfter.plugins.name) -join ',') -ceq 'before,after') '移除重复目标后非目标顺序漂移'
    [IO.File]::Delete($catalogPath)

    [IO.File]::WriteAllBytes($fixturePolicyPath, [IO.File]::ReadAllBytes($policyPath))
    $managedDirectoryPath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.txn'
    [void][IO.Directory]::CreateDirectory($managedDirectoryPath)
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $managedDirectoryCanonicalBytes = [IO.File]::ReadAllBytes($catalogPath)
    $managedDirectory = Invoke-GuardSweep
    Assert-Blocked -Invocation $managedDirectory -ExitCode 2 -Code 'catalog-transaction-unknown-artifact' -Label 'managed-name directory artifact'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $managedDirectoryCanonicalBytes)) '受管名称目录存在时 canonical 被处理'
    Assert-True ([IO.Directory]::Exists($managedDirectoryPath)) '受管名称目录被 guard 误删'
    $managedDirectoryCheck = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath
    Assert-True ($managedDirectoryCheck.exitCode -eq 2 -and @($managedDirectoryCheck.result.drift) -ccontains 'catalog:blocked' -and $managedDirectoryCheck.result.catalog.blocked[0].code -ceq 'catalog-transaction-unknown-artifact') 'Check 未对受管名称目录报红'
    [IO.Directory]::Delete($managedDirectoryPath, $false)
    [IO.File]::Delete($catalogPath)

    $managedJunctionTarget = Join-Path $fixtureRoot 'managed-artifact-junction-target'
    [void][IO.Directory]::CreateDirectory($managedJunctionTarget)
    $managedJunctionSentinel = Join-Path $managedJunctionTarget 'sentinel.txt'
    [IO.File]::WriteAllText($managedJunctionSentinel, "managed junction target must survive`n", $utf8)
    $managedJunctionSentinelSha = Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($managedJunctionSentinel))
    $managedArtifactJunctionPath = Join-Path $catalogRoot '.codex-catalog-guard-aaaaaaaaaaaaaaaa.publish'
    [void](New-Item -ItemType Junction -Path $managedArtifactJunctionPath -Target $managedJunctionTarget -ErrorAction Stop)
    $managedArtifactJunctionCreated = $true
    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $managedJunctionCanonicalBytes = [IO.File]::ReadAllBytes($catalogPath)
    $managedJunction = Invoke-GuardSweep
    Assert-Blocked -Invocation $managedJunction -ExitCode 2 -Code 'catalog-transaction-unknown-artifact' -Label 'managed-name junction artifact'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($catalogPath))) -ceq (Get-BytesSha256 -Bytes $managedJunctionCanonicalBytes)) '受管名称 junction 存在时 canonical 被处理'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($managedJunctionSentinel))) -ceq $managedJunctionSentinelSha) '受管名称 junction target 被 guard 修改'
    $managedJunctionCheck = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath
    Assert-True ($managedJunctionCheck.exitCode -eq 2 -and @($managedJunctionCheck.result.drift) -ccontains 'catalog:blocked' -and $managedJunctionCheck.result.catalog.blocked[0].code -ceq 'catalog-transaction-unknown-artifact') 'Check 未对受管名称 junction 报红'
    Remove-Item -LiteralPath $managedArtifactJunctionPath -Force
    $managedArtifactJunctionCreated = $false
    [IO.File]::Delete($catalogPath)

    [IO.Directory]::Delete($catalogRoot, $false)
    $reparseTarget = Join-Path $fixtureRoot 'reparse-target'
    [void][IO.Directory]::CreateDirectory($reparseTarget)
    $reparseTargetFile = Join-Path $reparseTarget 'bbbbbbbbbbbbbbbb.json'
    Write-JsonFile -Path $reparseTargetFile -Value (New-TargetCatalog)
    $reparseBytes = [IO.File]::ReadAllBytes($reparseTargetFile)
    [void](New-Item -ItemType Junction -Path $catalogRoot -Target $reparseTarget -ErrorAction Stop)
    $junctionCreated = $true
    $reparse = Invoke-GuardSweep
    Assert-Blocked -Invocation $reparse -ExitCode 3 -Code 'reparse-point' -Label 'reparse catalog root'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($reparseTargetFile))) -ceq (Get-BytesSha256 -Bytes $reparseBytes)) 'reparse target 原文件字节被覆盖'
    Remove-Item -LiteralPath $catalogRoot -Force
    $junctionCreated = $false
    Assert-True ([IO.File]::Exists($reparseTargetFile)) '移除 junction 时误删 reparse target'
    [void][IO.Directory]::CreateDirectory($catalogRoot)

    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($pluginSentinel))) -ceq $pluginSentinelSha) '插件安装 sentinel 被 guard 修改'
    Assert-True ((Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($skillSentinel))) -ceq $skillSentinelSha) 'skill 安装 sentinel 被 guard 修改'

    $invalidPolicy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json -Depth 32 -AsHashtable
    $invalidPolicy['unexpected'] = $true
    Write-JsonFile -Path $fixturePolicyPath -Value $invalidPolicy
    $runtimeInvalidPolicy = Invoke-GuardAudit -FixturePolicyPath $fixturePolicyPath
    Assert-True ($runtimeInvalidPolicy.exitCode -eq 3 -and $runtimeInvalidPolicy.result.error.code -ceq 'policy-schema-drift') "runtime Audit 未拒绝非法 policy schema：$($runtimeInvalidPolicy | ConvertTo-Json -Compress -Depth 8)"
    $checkInvalidPolicy = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath
    Assert-True ($checkInvalidPolicy.exitCode -eq 2 -and $checkInvalidPolicy.result.catalog.blocked[0].code -ceq 'policy-schema-drift') "治理 Check 未复用 runtime policy validator：$($checkInvalidPolicy | ConvertTo-Json -Compress -Depth 8)"

    [IO.File]::WriteAllBytes($fixturePolicyPath, [IO.File]::ReadAllBytes($policyPath))
    $auditMalformedPath = Join-Path $catalogRoot 'cccccccccccccccc.json'
    [IO.File]::WriteAllBytes($auditMalformedPath, $malformedBytes)
    $runtimeMalformedAudit = Invoke-GuardAudit -FixturePolicyPath $fixturePolicyPath
    Assert-True ($runtimeMalformedAudit.exitCode -eq 2 -and $runtimeMalformedAudit.result.blocked[0].code -ceq 'malformed-json') "runtime Audit 未拒绝 malformed catalog：$($runtimeMalformedAudit | ConvertTo-Json -Compress -Depth 8)"
    $checkMalformedAudit = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath
    Assert-True ($checkMalformedAudit.exitCode -eq 2 -and $checkMalformedAudit.result.catalog.blocked[0].code -ceq 'malformed-json') "治理 Check 未复用 runtime catalog validator：$($checkMalformedAudit | ConvertTo-Json -Compress -Depth 8)"
    [IO.File]::Delete($auditMalformedPath)

    $statePath = Join-Path $fixtureRoot 'state\state.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $statePath))
    $strictHealthyState = New-WatchStateFixture -Status 'running' -PendingRetryCount 0 -LastSweepUtc ([DateTime]::UtcNow)
    $strictHealthyJson = $strictHealthyState | ConvertTo-Json -Compress -Depth 32
    $strictStateCases = [ordered]@{
        duplicateSchemaVersion = $strictHealthyJson.Replace('{"schemaVersion":2,', '{"schemaVersion":2,"schemaVersion":2,')
        duplicateStatus = $strictHealthyJson.Replace('"status":"running"', '"status":"running","status":"running"')
        stringInteger = $strictHealthyJson.Replace('{"schemaVersion":2,', '{"schemaVersion":"2",')
        stringBoolean = $strictHealthyJson.Replace('"ok":true', '"ok":"true"')
        invalidStartedUtc = $strictHealthyJson.Replace([string]$strictHealthyState.startedUtc, '2026-07-31T12:34:56+00:00')
        invalidCompletedUtc = $strictHealthyJson.Replace([string]$strictHealthyState.lastSweep.completedAtUtc, [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz'))
        unexpectedProperty = $strictHealthyJson.Replace('{"schemaVersion":2,', '{"unexpected":null,"schemaVersion":2,')
    }
    foreach ($strictStateCase in $strictStateCases.GetEnumerator()) {
        [IO.File]::WriteAllText($statePath, [string]$strictStateCase.Value, $utf8)
        $strictStateResult = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath -FixtureStatePath $statePath
        Assert-True ($strictStateResult.exitCode -eq 2 -and @($strictStateResult.result.drift) -ccontains 'watch-state:missing-or-unreadable') "严格 watch state 未拒绝 $($strictStateCase.Key)：$($strictStateResult | ConvertTo-Json -Compress -Depth 8)"
    }

    Write-JsonFile -Path $statePath -Value (New-WatchStateFixture -Status 'retrying' -PendingRetryCount 1 -LastSweepUtc ([DateTime]::UtcNow))
    $retryingState = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath -FixtureStatePath $statePath
    Assert-True ($retryingState.exitCode -eq 2 -and @($retryingState.result.drift) -ccontains 'watch-state:retrying' -and @($retryingState.result.drift) -ccontains 'watch-state:pending-retry') "retrying/pending state 未让 Check 变红：$($retryingState | ConvertTo-Json -Compress -Depth 8)"

    Write-JsonFile -Path $statePath -Value (New-WatchStateFixture -Status 'running' -PendingRetryCount 0 -LastSweepUtc ([DateTime]::UtcNow.AddMinutes(-3)))
    $staleState = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath -FixtureStatePath $statePath
    Assert-True ($staleState.exitCode -eq 2 -and @($staleState.result.drift) -ccontains 'watch-state:last-sweep-stale') "stale lastSweep 未让 Check 变红：$($staleState | ConvertTo-Json -Compress -Depth 8)"

    Write-JsonFile -Path $statePath -Value (New-WatchStateFixture -Status 'running' -PendingRetryCount 0 -LastSweepUtc ([DateTime]::UtcNow))
    $healthyState = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath -FixtureStatePath $statePath
    Assert-True ($healthyState.exitCode -eq 0 -and $healthyState.result.ok -eq $true -and $healthyState.result.driftCount -eq 0) "健康 watcher state 未恢复绿灯：$($healthyState | ConvertTo-Json -Compress -Depth 8)"

    $healthyResultState = New-WatchStateFixture -Status 'running' -PendingRetryCount 0 -LastSweepUtc ([DateTime]::UtcNow)
    $healthyResultState.lastSweep.scannedCount = 1
    $healthyResultState.lastSweep.results = [object[]]@([ordered]@{
        file = 'aaaaaaaaaaaaaaaa.json'
        state = 'clean'
        removedCount = 0
        beforeSha256 = ('a' * 64)
        afterSha256 = ('a' * 64)
        processedIdentity = @('00000001', '0000000000000001')
        processedSha256 = ('a' * 64)
    })
    Write-JsonFile -Path $statePath -Value $healthyResultState
    $healthyResultStateCheck = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath -FixtureStatePath $statePath
    Assert-True ($healthyResultStateCheck.exitCode -eq 0 -and $healthyResultStateCheck.result.ok -eq $true) "含 results[] 的健康 watcher state 未通过严格 parser：$($healthyResultStateCheck | ConvertTo-Json -Compress -Depth 8)"

    Write-JsonFile -Path $catalogPath -Value (New-TargetCatalog)
    $orphanBeforeBytes = [IO.File]::ReadAllBytes($catalogPath)
    $orphanInterrupted = Invoke-GuardSweep -InterruptAfterQuarantine
    Assert-True ($orphanInterrupted.exitCode -eq 86 -and -not [IO.File]::Exists($catalogPath)) 'orphan conflict 前置中断未形成 transaction'
    $orphanVendor = New-TargetCatalog -ExtraEntries @([ordered]@{ id = 'keep-orphan-vendor'; name = 'orphan-vendor'; payload = 'must-not-overwrite' })
    $orphanVendorBytes = $utf8.GetBytes((($orphanVendor | ConvertTo-Json -Depth 32) + "`n"))
    [IO.File]::WriteAllBytes($catalogPath, $orphanVendorBytes)
    $orphanRecovery = Invoke-GuardSweep
    Assert-True ($orphanRecovery.exitCode -eq 0 -and $orphanRecovery.result.removedCount -eq 1) "受支持 vendor canonical 未触发 orphan transaction durable abort 重建：invocation=$($orphanRecovery | ConvertTo-Json -Compress -Depth 8)"
    Assert-True (@(Get-TransactionArtifacts).Count -eq 0) 'orphan transaction 合法恢复后仍有 artifact'
    $orphanAfter = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
    Assert-True ((@($orphanAfter.plugins.name) -join ',') -ceq 'before,after,orphan-vendor') 'orphan transaction 合法恢复未保留 vendor canonical 非目标内容'
    $orphanCheck = Invoke-GovernanceFixtureCheck -FixturePolicyPath $fixturePolicyPath -FixtureStatePath $statePath
    Assert-True ($orphanCheck.exitCode -eq 0 -and $orphanCheck.result.ok -eq $true) 'orphan transaction 收敛后 Check 未恢复绿灯'

    Write-Output "PASS Test-CodexRemotePluginCatalogGuardHardening malformed=1 pair=1 schema=3 policySchemaParity=1 catalogSchemaParity=1 stateHealth=4 strictState=7 hardlink=1 hashRace=1 identityRace=1 stagingCrash=6 durableRenameCrash=6 durablePublicationProbe=3 canonicalLeaseProbe=10 publishIoRecovery=1 crashRecovery=1 vendorAbortCrash=5 vendorAbortStageCrash=3 vendorAbortDurableCrash=3 vendorAbortDrift=1 markerReplacement=3 artifactIdentityReplacement=3 artifactInPlaceRewrite=5 integrityAnchorMutation=$integrityMutationCount sealFailure=$sealFailureCount eaSameName=1 transientSharingRetry=1 transactionUnknown=3 caseVariantUnknown=5 transactionRecovery=2 transactionConflict=1 transactionIdempotent=1 casRace=1 fingerprintRace=1 reparse=2 unsupported=1 sentinel=2"
} finally {
    if ($managedArtifactJunctionCreated -and $null -ne $managedArtifactJunctionPath -and (Test-Path -LiteralPath $managedArtifactJunctionPath)) {
        Remove-Item -LiteralPath $managedArtifactJunctionPath -Force
    }
    if ($junctionCreated -and (Test-Path -LiteralPath $catalogRoot)) {
        Remove-Item -LiteralPath $catalogRoot -Force
    }
    Remove-FixtureWithManagedDelete
}
