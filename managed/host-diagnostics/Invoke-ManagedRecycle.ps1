#Requires -Version 7.4
<#
.SYNOPSIS
Move one file or directory tree to its volume's Recycle Bin against an exact, SHA-256-pinned manifest.
.DESCRIPTION
Check runs the preflight below read-only, needs no purpose or authorization and writes no evidence, so an
agent can tell whether a target is recyclable before asking the user. Plan scans the target and writes
<EvidenceRoot>/<run>/plan.json with the relative path and size of every entry, the bin facts, the purpose
and the user's authorization. Apply consumes that plan by SHA-256 within 30 minutes, reruns every preflight
check, rescans the target, recycles it with SHFileOperationW (FOF_ALLOWUNDO | FOF_WANTNUKEWARNING, no UI)
and compares the bin copy with the plan, recording the outcome once in result.json next to the plan. To find
the bin copy it reads every $I record in the user's bin; a record another process holds open is retried until
3 seconds into that walk, then skipped and listed in unreadableBinRecords, and the reason becomes
bin-record-unreadable instead of bin-record-missing when the target's record is not among the readable ones.
Output is one JSON object; exit 0 only for checked, planned or recycled.

Preflight fails closed on: paths that are not drive paths on a fixed NTFS volume, volume roots, protected
roots and their ancestors, system subtrees, reparse points on the path or inside the tree, hard links
(with -AllowInternalHardLinks only those with a name outside the target; Plan records the switch and Apply
rechecks with it), entries this process cannot open for DELETE (installers often leave Users with read and
execute only and the shell would then fail the move with 0x78; the refusal names them and says whether the
process was elevated), paths the shell cannot move (260 characters or more, in place or in the bin), the NoRecycleFiles policy,
NukeOnDelete, missing per-volume bin settings, and bin headroom (bin + target above 90% of MaxCapacity
would make Windows evict older bin items). Nothing is deleted permanently and the bin is never emptied;
both stay with the user. Agents use this entry only for targets the user explicitly authorized in the
current task, quoted in -Authorization.
.EXAMPLE
& 'D:/Codex/.codex/scripts/Invoke-ManagedRecycle.ps1' -Mode Check -TargetPath 'C:/Users/me/AppData/Local/pip/cache'
& 'D:/Codex/.codex/scripts/Invoke-ManagedRecycle.ps1' -Mode Plan -TargetPath 'C:/Users/me/AppData/Local/pip/cache' -Purpose 'pip cache' -Authorization '<user words>'
& 'D:/Codex/.codex/scripts/Invoke-ManagedRecycle.ps1' -Mode Apply -PlanPath '<planPath>' -ApprovedPlanSha256 '<planSha256>' -ConfirmRecycle
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Check', 'Plan', 'Apply')][string]$Mode,
    [string]$TargetPath,
    [string]$Purpose,
    [string]$Authorization,
    [string]$PlanPath,
    [string]$ApprovedPlanSha256,
    [switch]$ConfirmRecycle,
    [switch]$AllowInternalHardLinks,
    [string]$EvidenceRoot = 'D:/agents/run-evidence/managed-recycle'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$planTtlMinutes = 30
$maxEntries = 200000
$headroomRatio = 0.9
$maxShellPath = 259
$binReadSeconds = 3
$result = [ordered]@{ mode = $Mode; status = 'refused' }

function Save-Result([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $utf8.GetBytes(($result | ConvertTo-Json -Depth 8))
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
}

# Single exit: once Apply has accepted a plan, every outcome is recorded once next to it, so a retry needs a new plan.
function Complete {
    if ($result.Contains('resultPath') -and -not [IO.File]::Exists($result.resultPath)) { Save-Result $result.resultPath }
    $result | ConvertTo-Json -Depth 8 -Compress
    exit $(if ($result.status -in @('checked', 'planned', 'recycled')) { 0 } else { 1 })
}

function Stop-Refused([string]$Reason) {
    $result.status = 'refused'
    $result.reason = $Reason
    Complete
}

function Test-Within([string]$Path, [string]$Parent) {
    $Parent = $Parent.TrimEnd('\')
    $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-ReparseOnPath([string]$Path) {
    $current = $Path
    while ($current) {
        if ([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) { return $current }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    $null
}

function Get-ManifestSha256($Scan) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes([string]::Join("`n", $Scan.Lines))))
}

function Get-TopLevel($Scan) {
    $Scan.Top.GetEnumerator() | Sort-Object { $_.Value[0] } -Descending | Select-Object -First 15 |
        ForEach-Object { [ordered]@{ name = $_.Key; bytes = $_.Value[0]; files = $_.Value[1] } }
}

# Losing these is never a cache cleanup: volume roots, profile and program containers, the agent roots, and
# system subtrees. A target equal to or above a protected root is refused. Everything else still needs the
# user's explicit authorization.
function Get-Protection([string]$Full, [string]$Root, [string]$EvidenceFull) {
    if ($Full.Length -le $Root.Length) { return 'volume-root' }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $roots = @(
        (Split-Path -Parent $userProfile), $userProfile, (Join-Path $userProfile 'AppData'),
        (Join-Path $userProfile 'AppData\LocalLow'), (Join-Path $userProfile 'Downloads'),
        [Environment]::GetFolderPath('ApplicationData'), [Environment]::GetFolderPath('LocalApplicationData'),
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyVideos'), [Environment]::GetFolderPath('CommonApplicationData'),
        [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'),
        'D:\agents', 'D:\agents\projects', 'D:\agents\run-evidence', 'D:\agents\knowledge-base',
        'D:\Codex', 'D:\Codex\.codex', 'D:\WSL', $EvidenceFull
    )
    foreach ($item in $roots) {
        if ($item -and (Test-Within $item $Full)) { return 'protected-root' }
    }
    $subtrees = @(
        [Environment]::GetFolderPath('Windows'), (Join-Path $Root '$Recycle.Bin'),
        (Join-Path $Root 'System Volume Information'), $EvidenceFull
    )
    foreach ($item in $subtrees) {
        if ($item -and (Test-Within $Full $item)) { return 'protected-subtree' }
    }
    $null
}

function Get-BinFacts([string]$Root, [long]$TargetBytes) {
    $facts = [ordered]@{
        volumeGuid = [ManagedRecycle.Native]::VolumeGuid($Root)
        maxCapacityBytes = $null; nukeOnDelete = $null; binBytes = $null; binItems = $null
        headroomLimitBytes = $null; bytesAfterRecycle = $null
        volumeFreeBytes = [IO.DriveInfo]::new($Root).AvailableFreeSpace
    }
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($hive in @('HKCU:', 'HKLM:')) {
        $policy = Get-ItemProperty -LiteralPath "$hive\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name 'NoRecycleFiles' -ErrorAction SilentlyContinue
        if ($null -ne $policy -and [int]$policy.NoRecycleFiles -ne 0) { $problems.Add("no-recycle-files-policy: $hive") }
    }
    # Query before reading settings: a fresh profile (a CI runner) has no BitBucket settings for a volume until its bin
    # is first used, and the shell writes them on this query. Settings still missing afterwards stay a refusal.
    $query = [ManagedRecycle.Native]::QueryBin($Root)
    if ($query[0] -ne 0) { $problems.Add(('bin-query-failed: 0x{0:x}' -f $query[0])) }
    else { $facts.binBytes = $query[1]; $facts.binItems = $query[2] }
    if (-not $facts.volumeGuid) { $problems.Add('volume-guid-unavailable') }
    else {
        $settings = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$($facts.volumeGuid)" -ErrorAction SilentlyContinue
        if ($null -eq $settings -or $null -eq $settings.PSObject.Properties['MaxCapacity'] -or $null -eq $settings.PSObject.Properties['NukeOnDelete']) {
            $problems.Add('bin-settings-missing')
        }
        else {
            $facts.maxCapacityBytes = [long]$settings.MaxCapacity * 1MB
            $facts.nukeOnDelete = [int]$settings.NukeOnDelete
            if ($facts.nukeOnDelete -ne 0) { $problems.Add('nuke-on-delete') }
        }
    }
    if ($null -ne $facts.maxCapacityBytes -and $null -ne $facts.binBytes) {
        $facts.headroomLimitBytes = [long][math]::Floor($facts.maxCapacityBytes * $headroomRatio)
        $facts.bytesAfterRecycle = $facts.binBytes + $TargetBytes
        if ($facts.bytesAfterRecycle -gt $facts.headroomLimitBytes) { $problems.Add('bin-headroom-insufficient') }
    }
    [pscustomobject]@{ facts = $facts; problems = @($problems) }
}

function Get-UserBinDirectory([string]$Root) {
    Join-Path $Root ('$Recycle.Bin\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
}

# Every check Plan and Apply share. Fills $result and returns the scan, or refuses.
function Invoke-Preflight([string]$Path, [string]$EvidenceFull, [bool]$AllowInternalLinks) {
    if ([string]::IsNullOrWhiteSpace($Path)) { Stop-Refused 'target-required' }
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.IndexOfAny([char[]]'*?') -ge 0) { Stop-Refused 'target-not-fully-qualified' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($root.Length -ne 3 -or $root[1] -ne ':') { Stop-Refused 'target-not-drive-path' }
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    $result.target = $full
    $protection = Get-Protection $full $root $EvidenceFull
    if ($protection) { $result.protection = $protection; Stop-Refused 'protected-location' }
    if (-not ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full))) { Stop-Refused 'target-missing' }
    $drive = [IO.DriveInfo]::new($root)
    $format = try { $drive.DriveFormat } catch { $null }
    if ($drive.DriveType -ne [IO.DriveType]::Fixed -or $format -ne 'NTFS') { Stop-Refused 'volume-not-fixed-ntfs' }
    $reparse = Get-ReparseOnPath $full
    if ($reparse) { $result.reparsePoint = $reparse; Stop-Refused 'reparse-point-on-path' }
    $scan = try { [ManagedRecycle.Native]::Scan($full, $true, $AllowInternalLinks, $maxEntries) }
    catch {
        $inner = $_.Exception.InnerException
        $result.scanError = if ($inner) { $inner.Message } else { $_.Exception.Message }
        Stop-Refused 'scan-failed'
    }
    if ($scan.Truncated) { $result.maxEntries = $maxEntries; Stop-Refused 'target-too-large' }
    $result.kind = $scan.Kind
    $result.fileCount = $scan.Files
    $result.directoryCount = $scan.Directories
    $result.totalBytes = $scan.Bytes
    if ($AllowInternalLinks) { $result.internalHardLinkFiles = $scan.InternalLinkFiles }
    $binName = (Get-UserBinDirectory $root).Length + 9 + [IO.Path]::GetExtension($full).Length
    $tail = if ($scan.MaxRelativeLength -gt 0) { 1 + $scan.MaxRelativeLength } else { 0 }
    $result.longestPath = [math]::Max($full.Length, $binName) + $tail
    if ($result.longestPath -gt $maxShellPath) {
        # Name the entries over the limit: a shorter parent fixes the in-place side; only a shorter target name
        # or a narrower target fixes the bin side.
        $result.inPlaceLongestPath = $full.Length + $tail
        $result.inBinLongestPath = $binName + $tail
        $limit = $maxShellPath - [math]::Max($full.Length, $binName) - 1
        $tooLong = @($scan.Lines | ForEach-Object { $_.Split("`t")[1] } | Where-Object { $_ -and $_.Length -gt $limit } |
            Sort-Object Length -Descending)
        $result.tooLongCount = $tooLong.Count
        $result.tooLong = @($tooLong | Select-Object -First 20)
        Stop-Refused 'path-too-long'
    }
    if ($scan.ProblemCount -gt 0) {
        $result.problemCount = $scan.ProblemCount
        $result.problems = @($scan.Problems)
        Stop-Refused 'tree-not-recyclable'
    }
    if ($scan.DeleteDeniedCount -gt 0) {
        $result.deleteDeniedCount = $scan.DeleteDeniedCount
        $result.deleteDenied = @($scan.DeleteDenied)
        $result.elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        Stop-Refused 'delete-access-denied'
    }
    $bin = Get-BinFacts $root $scan.Bytes
    $result.bin = $bin.facts
    if ($bin.problems.Count -gt 0) { $result.problems = $bin.problems; Stop-Refused 'bin-not-ready' }
    [pscustomobject]@{ target = $full; root = $root; scan = $scan }
}

# The newest $I record in this user's bin on the volume whose original path is the target, with its $R twin.
# Explorer and scanners briefly hold new records open: a locked record is retried until $binReadSeconds into the
# walk, then skipped and listed in $result.unreadableBinRecords. A record that vanished was restored or emptied.
function Find-BinRecord([string]$Root, [string]$Original, [datetime]$NotBeforeUtc) {
    $bin = Get-UserBinDirectory $Root
    if (-not [IO.Directory]::Exists($bin)) { return $null }
    $best = $null
    $unreadable = [Collections.Generic.List[string]]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($binReadSeconds)
    foreach ($index in [IO.Directory]::EnumerateFiles($bin, '$I*')) {
        $bytes = $null
        while ($null -eq $bytes) {
            try { $bytes = [IO.File]::ReadAllBytes($index) }
            catch [IO.IOException] {
                if (-not [IO.File]::Exists($index)) { break }
                if ([DateTime]::UtcNow -ge $deadline) { $unreadable.Add($index); break }
                Start-Sleep -Milliseconds 200
            }
        }
        if ($null -eq $bytes -or $bytes.Length -lt 28) { continue }
        $version = [BitConverter]::ToInt64($bytes, 0)
        # Not $original: PowerShell names are case-insensitive, so that would overwrite the $Original parameter.
        $recorded = $null
        if ($version -eq 2) {
            $chars = [BitConverter]::ToInt32($bytes, 24)
            if ($chars -ge 1 -and 28 + $chars * 2 -le $bytes.Length) { $recorded = [Text.Encoding]::Unicode.GetString($bytes, 28, ($chars - 1) * 2) }
        }
        elseif ($version -eq 1 -and $bytes.Length -ge 544) {
            $recorded = [Text.Encoding]::Unicode.GetString($bytes, 24, 520).Split([char]0)[0]
        }
        if (-not $recorded -or -not $recorded.Equals($Original, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $deleted = [DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($bytes, 16))
        if ($deleted -lt $NotBeforeUtc -or ($null -ne $best -and $deleted -le $best.deletedUtc)) { continue }
        $name = [IO.Path]::GetFileName($index)
        $best = [ordered]@{
            indexPath = $index
            contentPath = Join-Path $bin ('$R' + $name.Substring(2))
            deletedUtc = $deleted
            indexBytes = [BitConverter]::ToInt64($bytes, 8)
        }
    }
    if ($unreadable.Count) { $result.unreadableBinRecords = @($unreadable) }
    $best
}

try {
    if (-not ('ManagedRecycle.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace ManagedRecycle
{
    public sealed class TreeScan
    {
        public string Kind;
        public List<string> Lines = new List<string>();
        public List<string> Problems = new List<string>();
        public int ProblemCount;
        public List<string> DeleteDenied = new List<string>();
        public int DeleteDeniedCount;
        public long Files;
        public long Directories;
        public long Bytes;
        public int MaxRelativeLength;
        public bool Truncated;
        public long InternalLinkFiles;
        public Dictionary<string, long[]> Top = new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
    }

    public static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SHFILEOPSTRUCTW
        {
            public IntPtr hwnd;
            public uint wFunc;
            public string pFrom;
            public string pTo;
            public ushort fFlags;
            [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
            public IntPtr hNameMappings;
            public string lpszProgressTitle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SHQUERYRBINFO
        {
            public uint cbSize;
            public long i64Size;
            public long i64NumItems;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHFileOperationW(ref SHFILEOPSTRUCTW op);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHQueryRecycleBinW(string root, ref SHQUERYRBINFO info);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, StringBuilder name, int size);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileNameW(string fileName, uint flags, ref uint length, StringBuilder linkName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool FindNextFileNameW(IntPtr find, ref uint length, StringBuilder linkName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FindClose(IntPtr find);

        // FO_DELETE with FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI | FOF_NO_CONNECTED_ELEMENTS
        // | FOF_WANTNUKEWARNING on a dedicated STA thread: recycle without UI, but ask instead of silently deleting
        // anything the bin cannot take. Returns { return code, aborted (0 or 1) }.
        public static int[] Recycle(string path)
        {
            int code = -1;
            bool aborted = false;
            Exception failure = null;
            var thread = new Thread(() =>
            {
                try
                {
                    var op = new SHFILEOPSTRUCTW();
                    op.wFunc = 3;
                    op.pFrom = path + "\0";
                    op.fFlags = (ushort)(0x0004 | 0x0010 | 0x0040 | 0x0400 | 0x2000 | 0x4000);
                    code = SHFileOperationW(ref op);
                    aborted = op.fAnyOperationsAborted;
                }
                catch (Exception e) { failure = e; }
            });
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            thread.Join();
            if (failure != null) throw failure;
            return new[] { code, aborted ? 1 : 0 };
        }

        public static long[] QueryBin(string root)
        {
            var info = new SHQUERYRBINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(SHQUERYRBINFO));
            int code = SHQueryRecycleBinW(root, ref info);
            return new long[] { code, info.i64Size, info.i64NumItems };
        }

        public static string VolumeGuid(string root)
        {
            var name = new StringBuilder(64);
            if (!GetVolumeNameForVolumeMountPointW(root, name, name.Capacity)) return null;
            string text = name.ToString();
            int open = text.IndexOf('{');
            int close = text.IndexOf('}');
            return open >= 0 && close > open ? text.Substring(open, close - open + 1) : null;
        }

        // Hard link count of the path itself; reparse points are opened, not followed. -1 when unreadable.
        public static long Links(string path)
        {
            using (var handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero))
            {
                if (handle.IsInvalid) return -1;
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(handle, out info)) return -1;
                return info.Links;
            }
        }

        // Every name of a file as a full path, or null when they cannot all be read. A name is at most 32767
        // characters, so the buffer never has to grow.
        public static List<string> LinkNames(string path)
        {
            const int capacity = 32768;
            var name = new StringBuilder(capacity);
            uint length = capacity;
            IntPtr find = FindFirstFileNameW(path, 0, ref length, name);
            if (find == new IntPtr(-1)) return null;
            string volume = Path.GetPathRoot(path).TrimEnd('\\');
            var names = new List<string>();
            try
            {
                do
                {
                    names.Add(volume + name.ToString());
                    length = capacity;
                }
                while (FindNextFileNameW(find, ref length, name));
                return Marshal.GetLastWin32Error() == 38 ? names : null;
            }
            finally { FindClose(find); }
        }

        // Exact manifest of a file or a directory tree: "D<tab>relative" and "F<tab>relative<tab>bytes" lines in
        // ordinal order. Reparse points are reported, never followed. With checkLinks every file needs one link;
        // with allowInternalLinks as well, a file may have more when every one of its names is inside root.
        public static TreeScan Scan(string root, bool checkLinks, bool allowInternalLinks, int maxEntries)
        {
            var scan = new TreeScan();
            string internalRoot = allowInternalLinks ? root : null;
            ProbeDelete(scan, root, ".");
            if ((File.GetAttributes(root) & FileAttributes.Directory) == 0)
            {
                scan.Kind = "file";
                long size = new FileInfo(root).Length;
                scan.Files = 1;
                scan.Bytes = size;
                scan.Lines.Add("F\t\t" + size);
                if (checkLinks) CheckLinks(scan, root, "", internalRoot);
                return scan;
            }
            scan.Kind = "directory";
            var options = new EnumerationOptions
            {
                RecurseSubdirectories = false,
                AttributesToSkip = 0,
                IgnoreInaccessible = false,
                ReturnSpecialDirectories = false
            };
            var pending = new Stack<string>();
            pending.Push(root);
            long entries = 0;
            while (pending.Count > 0)
            {
                foreach (var item in new DirectoryInfo(pending.Pop()).EnumerateFileSystemInfos("*", options))
                {
                    if (++entries > maxEntries) { scan.Truncated = true; return scan; }
                    string relative = Path.GetRelativePath(root, item.FullName);
                    string top = relative.Split(Path.DirectorySeparatorChar)[0];
                    if (relative.Length > scan.MaxRelativeLength) scan.MaxRelativeLength = relative.Length;
                    if ((item.Attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        AddProblem(scan, "reparse-point: " + relative);
                        continue;
                    }
                    ProbeDelete(scan, item.FullName, relative);
                    if ((item.Attributes & FileAttributes.Directory) != 0)
                    {
                        scan.Directories++;
                        scan.Lines.Add("D\t" + relative);
                        Tally(scan, top, 0, 0);
                        pending.Push(item.FullName);
                        continue;
                    }
                    long length = ((FileInfo)item).Length;
                    scan.Files++;
                    scan.Bytes += length;
                    scan.Lines.Add("F\t" + relative + "\t" + length);
                    Tally(scan, top, length, 1);
                    if (checkLinks) CheckLinks(scan, item.FullName, relative, internalRoot);
                }
            }
            scan.Lines.Sort(StringComparer.Ordinal);
            return scan;
        }

        // Records an entry this process cannot open for DELETE, directly or through FILE_DELETE_CHILD on its parent;
        // the shell would fail the recycle with 0x78. Other open failures (in use, gone) are left to the recycle.
        private static void ProbeDelete(TreeScan scan, string path, string relative)
        {
            using (var handle = CreateFileW(path, 0x00010000, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero))
            {
                if (!handle.IsInvalid || Marshal.GetLastWin32Error() != 5) return;
            }
            scan.DeleteDeniedCount++;
            if (scan.DeleteDenied.Count < 20) scan.DeleteDenied.Add(relative);
        }

        // internalRoot is null unless hard links whose names all stay inside it are allowed.
        private static void CheckLinks(TreeScan scan, string path, string relative, string internalRoot)
        {
            long links = Links(path);
            if (links < 0) { AddProblem(scan, "link-count-unreadable: " + relative); return; }
            if (links == 1) return;
            string count = " (" + links + " links)";
            if (internalRoot == null) { AddProblem(scan, "hard-link: " + relative + count); return; }
            List<string> names = LinkNames(path);
            if (names == null || names.Count != links) { AddProblem(scan, "hard-link-names-unreadable: " + relative + count); return; }
            foreach (string name in names)
            {
                if (!Within(name, internalRoot)) { AddProblem(scan, "hard-link-outside-target: " + relative + count); return; }
            }
            scan.InternalLinkFiles++;
        }

        private static bool Within(string path, string parent)
        {
            return path.Equals(parent, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase);
        }

        private static void AddProblem(TreeScan scan, string problem)
        {
            scan.ProblemCount++;
            if (scan.Problems.Count < 20) scan.Problems.Add(problem);
        }

        private static void Tally(TreeScan scan, string top, long bytes, long files)
        {
            long[] totals;
            if (!scan.Top.TryGetValue(top, out totals))
            {
                totals = new long[2];
                scan.Top[top] = totals;
            }
            totals[0] += bytes;
            totals[1] += files;
        }
    }
}
'@
    }

    if (-not [IO.Path]::IsPathFullyQualified($EvidenceRoot)) { Stop-Refused 'evidence-root-not-fully-qualified' }
    $evidenceFull = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\')
    if (-not $evidenceFull.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase) -or $evidenceFull.Length -le 3) {
        Stop-Refused 'evidence-root-not-on-d'
    }

    if ($Mode -eq 'Check') {
        $checked = Invoke-Preflight $TargetPath $evidenceFull $AllowInternalHardLinks.IsPresent
        $result.status = 'checked'
        $result.topLevel = @(Get-TopLevel $checked.scan)
        Complete
    }

    if ($Mode -eq 'Plan') {
        if ([string]::IsNullOrWhiteSpace($Purpose) -or [string]::IsNullOrWhiteSpace($Authorization)) {
            Stop-Refused 'purpose-and-authorization-required'
        }
        $checked = Invoke-Preflight $TargetPath $evidenceFull $AllowInternalHardLinks.IsPresent
        $runDir = Join-Path $evidenceFull ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory($runDir)
        if (Get-ReparseOnPath $runDir) { Stop-Refused 'evidence-path-has-reparse-point' }
        $topLevel = @(Get-TopLevel $checked.scan)
        $manifestSha256 = Get-ManifestSha256 $checked.scan
        $plan = [ordered]@{
            artifactType = 'managed-recycle-plan'
            schemaVersion = 1
            createdUtc = [DateTime]::UtcNow.ToString('o')
            createdUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            target = $checked.target
            kind = $checked.scan.Kind
            purpose = $Purpose
            authorization = $Authorization
            fileCount = $checked.scan.Files
            directoryCount = $checked.scan.Directories
            totalBytes = $checked.scan.Bytes
            allowInternalHardLinks = $AllowInternalHardLinks.IsPresent
            internalHardLinkFiles = $checked.scan.InternalLinkFiles
            manifestSha256 = $manifestSha256
            topLevel = $topLevel
            bin = $result.bin
            manifest = @($checked.scan.Lines)
        }
        $planPath = Join-Path $runDir 'plan.json'
        $bytes = $utf8.GetBytes(($plan | ConvertTo-Json -Depth 6))
        [IO.File]::WriteAllBytes($planPath, $bytes)
        $result.status = 'planned'
        $result.manifestSha256 = $manifestSha256
        $result.topLevel = $topLevel
        $result.planPath = $planPath
        $result.planSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        $result.expiresUtc = [DateTime]::UtcNow.AddMinutes($planTtlMinutes).ToString('o')
        Complete
    }

    if (-not $ConfirmRecycle) { Stop-Refused 'confirm-recycle-required' }
    if ([string]::IsNullOrWhiteSpace($PlanPath) -or [string]::IsNullOrWhiteSpace($ApprovedPlanSha256)) {
        Stop-Refused 'plan-path-and-sha256-required'
    }
    $planFull = [IO.Path]::GetFullPath($PlanPath)
    $result.planPath = $planFull
    if ([IO.Path]::GetFileName($planFull) -ne 'plan.json' -or
        -not ([string](Split-Path -Parent (Split-Path -Parent $planFull))).Equals($evidenceFull, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Refused 'plan-outside-evidence-root'
    }
    if (-not [IO.File]::Exists($planFull)) { Stop-Refused 'plan-missing' }
    $planBytes = [IO.File]::ReadAllBytes($planFull)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($planBytes)) -ne $ApprovedPlanSha256.Trim().ToUpperInvariant()) {
        Stop-Refused 'plan-sha256-mismatch'
    }
    $plan = $utf8.GetString($planBytes) | ConvertFrom-Json -AsHashtable
    if ($plan.artifactType -ne 'managed-recycle-plan' -or $plan.schemaVersion -ne 1) { Stop-Refused 'plan-schema-unsupported' }
    $ageMinutes = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$plan.createdUnixMs) / 60000
    if ($ageMinutes -lt 0 -or $ageMinutes -gt $planTtlMinutes) { Stop-Refused 'plan-expired' }
    $resultPath = Join-Path (Split-Path -Parent $planFull) 'result.json'
    if ([IO.File]::Exists($resultPath)) { Stop-Refused 'plan-already-applied' }

    $result.resultPath = $resultPath
    $result.purpose = $plan.purpose
    $result.authorization = $plan.authorization
    # The plan's setting, not this call's switch: the user authorized what the plan recorded.
    $checked = Invoke-Preflight $plan.target $evidenceFull ($plan['allowInternalHardLinks'] -eq $true)
    $result.manifestSha256 = Get-ManifestSha256 $checked.scan
    if ($result.manifestSha256 -ne $plan.manifestSha256) {
        $result.plannedManifestSha256 = $plan.manifestSha256
        Stop-Refused 'manifest-changed'
    }

    $startedUtc = [DateTime]::UtcNow
    $result.startedUtc = $startedUtc.ToString('o')
    $result.status = 'failed'
    $call = [ManagedRecycle.Native]::Recycle($checked.target)
    $result.returnCode = '0x{0:x}' -f $call[0]
    $result.aborted = $call[1] -eq 1
    $result.targetStillExists = [IO.File]::Exists($checked.target) -or [IO.Directory]::Exists($checked.target)
    $record = Find-BinRecord $checked.root $checked.target $startedUtc.AddMinutes(-1)
    if ($record) {
        $result.binRecord = [ordered]@{
            indexPath = $record.indexPath; contentPath = $record.contentPath
            deletedUtc = $record.deletedUtc.ToString('o'); indexBytes = $record.indexBytes
        }
    }
    if ($call[0] -ne 0 -or $result.aborted -or $result.targetStillExists) { $result.reason = 'recycle-call-failed' }
    elseif (-not $record) { $result.reason = if ($result.Contains('unreadableBinRecords')) { 'bin-record-unreadable' } else { 'bin-record-missing' } }
    else {
        $binScan = try { [ManagedRecycle.Native]::Scan($record.contentPath, $false, $false, $maxEntries) } catch { $null }
        $result.binManifestSha256 = if ($binScan -and -not $binScan.Truncated) { Get-ManifestSha256 $binScan } else { $null }
        if ($result.binManifestSha256 -ne $plan.manifestSha256) { $result.reason = 'bin-copy-differs' }
        else { $result.status = 'recycled' }
    }
    $after = [ManagedRecycle.Native]::QueryBin($checked.root)
    $result.binAfter = [ordered]@{ bytes = $after[1]; items = $after[2]; volumeFreeBytes = [IO.DriveInfo]::new($checked.root).AvailableFreeSpace }
    Complete
}
catch {
    $result.status = 'failed'
    $result.reason = 'unexpected-error'
    $result.error = $_.Exception.Message
    Complete
}
