[CmdletBinding()]
param()

# 完整 ProductionSmoke 会在 .scratch/safe-tree-delete-tests-productionsmoke-* 下
# 创建一次性 fixture，并经 live invoke-safe-tree-delete.cmd 在
# D:\agents\run-evidence\safe-tree-delete\ 留下新 operation。这是 live 链的固有
# 依赖，不是对 leftover 或 #22 候选的写入。隔离：capability 目标只在项目
# .scratch 专用前缀；harness 证据写到 SAFE_TREE_DELETE_SMOKE_EVIDENCE_ROOT 或
# 同一 scratch 树，不改写 reports/safe-tree-delete-issue55-20260816/ 与
# reports/safe-tree-delete-issue21-20260816/ 历史快照（含 leaf-delete-failed.json）。
# 本票 fixture 事后受管 resume Purge；禁止 Purge/Restore leftover 0ab1e1b6；
# 不读写 #22 的 Status/Archive 候选。
#
# #55：真实 .cmd → 宿主 .ps1 → 生产脚本 的 smoke seam。成功 / 超时 / 失败
# 都要收口进程树；leaf-delete-failed 必须打到生产 JSON；Status 用 pre/post
# manifest+USN 证明只读零写入，代际绑定用 operations[].operationId（Status
# 合同无 generationId）。超时是 harness taskkill 合同，不是 wrapper 参数。
# #21（#89 起改在 fixture 副本上证明）：用部署工具测试 seam（-ShimPathForTest/
# -StateRootForTest/-ProjectRootForTest/-MutexNameForTest）把当前源码生成的 gate shim
# 装到 scratch，配指向它的 fixture .cmd（生产 .cmd 写死 live .ps1 路径）；变异（撤
# LASTEXITCODE 转发）只作用于这对副本。撤转发后 .cmd→.ps1 链对 leaf-delete-failed
# 返回 0 且 JSON 仍为该 refusal；从 backup 字节恢复后返回非零。宿主 live .ps1/.cmd
# 全程不被打开改写，套件首尾各校验一次 SHA-256 并写进 evidence。
# 不要在 Purge 开始前对 quarantine 持 FileShare.Read：那会卡在 locked
# preflight。正确窗口是 transaction 进入 purging 后再争用。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]$PSVersionTable.PSEdition -cne 'Core') {
    throw '本机 shell 必须是 PowerShell Core'
}
if ([int]$PSVersionTable.PSVersion.Major -lt 7) {
    throw '本机 shell 必须是 PowerShell 7+'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteClosure.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteGateShimInstall.ps1')
$reportsRoot = Join-Path $projectRoot 'reports'
$scratchCapabilityRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.scratch'))
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'productionsmoke'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$policyPath = Join-Path $projectRoot 'managed\safe-tree-delete\policy.json'
$frozenIssue55Dir = Join-Path $reportsRoot 'safe-tree-delete-issue55-20260816'
$frozenIssue21Dir = Join-Path $reportsRoot 'safe-tree-delete-issue21-20260816'
$frozenLeafDeleteFailedPath = Join-Path $frozenIssue55Dir 'leaf-delete-failed.json'
$harnessEvidenceRoot = if (-not [string]::IsNullOrWhiteSpace($env:SAFE_TREE_DELETE_SMOKE_EVIDENCE_ROOT)) {
    [string]$env:SAFE_TREE_DELETE_SMOKE_EVIDENCE_ROOT
} else {
    Join-Path $scratchRoot 'harness'
}
$issue55Dir = Join-Path $harnessEvidenceRoot 'issue55'
$issue21Dir = Join-Path $harnessEvidenceRoot 'issue21'
# #89：live .ps1 的期望值不再手写 pin；运行时由部署工具的同一份生成逻辑
# （scripts\lib\CodexSafeTreeDeleteGateShimInstall.ps1）从当前仓库算出，见下方 identity。
$fixtureRoot = Join-Path $scratchRoot 'production-smoke'
$payloadPath = Join-Path $fixtureRoot 'readonly-payload.txt'
$batchParent = Join-Path $scratchRoot 'batch-smoke'
$batchA = Join-Path $batchParent 'old-a'
$batchB = Join-Path $batchParent 'old-b'
$failFixtureRoot = Join-Path $scratchRoot 'issue55-livefail'
$failPayloadPath = Join-Path $failFixtureRoot 'issue55-locked-payload.txt'
$issue21FailFixtureRoot = Join-Path $scratchRoot 'issue21-livefail'
$issue21FailPayloadPath = Join-Path $issue21FailFixtureRoot 'issue21-locked-payload.txt'
$liveWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$sourceWrapper = Join-Path $projectRoot 'scripts\invoke-codex-safe-tree-delete.cmd'
$livePowerShellWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
$sourcePowerShellWrapper = Join-Path $projectRoot 'scripts\invoke-codex-safe-tree-delete-host.ps1'
$pwshExe = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$taskkillExe = Join-Path $env:SystemRoot 'System32\taskkill.exe'
$forbiddenLeftoverQuarantine = Join-Path $reportsRoot '.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine'
$forbiddenLeftoverTransaction = Join-Path $evidenceRoot '20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$suiteStartedAtUtc = [datetimeoffset]::UtcNow
$invocationRecords = [Collections.Generic.List[object]]::new()
$lockProcess = $null
$releaseSignalPath = Join-Path $issue55Dir 'lock-release.signal'
$lockAcquiredPath = Join-Path $issue55Dir 'lock-acquired.txt'
$lockHolderPath = Join-Path $issue55Dir 'lock-holder.ps1'
$lockLogPath = Join-Path $issue55Dir 'lock-holder.log'
$failApply = $null
$plan = $null
$purge = $null
$batch = $null
$batchParentPurge = $null
$unconfirmedArchive = $null
$status = $null
$statusBinding = $null
$timeoutRemaining = @()
$leafDeleteFailedObtained = $false
$revertForwardingProved = $false
$fixtureShimRestoreFailed = $false
$livePs1Sha256Final = $null
$liveCmdSha256Final = $null
$liveWrappersUntouched = $false
$newInflightQuarantine = $null
$leftoverUntouched = $false
$inflightCleanupError = $null
$revertEvidence = $null
$frozenLeafDeleteFailedSha256AtStart = $null

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-LowerSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-WrapperCaptureText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return '' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.UTF8Encoding]::new($false).GetString($bytes, 3, $bytes.Length - 3)
    }
    $oemCodePage = [int][Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    $oem = [Text.Encoding]::GetEncoding($oemCodePage)
    return $oem.GetString($bytes)
}

function Write-Issue55Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    foreach ($frozenRoot in @($frozenIssue55Dir, $frozenIssue21Dir)) {
        $frozenFull = [IO.Path]::GetFullPath($frozenRoot)
        $prefix = if ($frozenFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
            $frozenFull
        } else {
            $frozenFull + [IO.Path]::DirectorySeparatorChar
        }
        if ($fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.Equals($frozenFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "ProductionSmoke 禁止写入历史快照：$fullPath"
        }
    }
    [IO.File]::WriteAllText(
        $Path,
        ($Document | ConvertTo-Json -Depth 16),
        $utf8)
}

function ConvertTo-UsnSlim {
    param([Parameter(Mandatory)][object]$Capture)
    return [ordered]@{
        Root = [string]$Capture.Root
        CapturedAtUtc = [string]$Capture.CapturedAtUtc
        FileCount = [int]$Capture.FileCount
        DirectoryCount = [int]$Capture.DirectoryCount
        ErrorCount = [int]$Capture.ErrorCount
        DigestSha256 = [string]$Capture.DigestSha256
    }
}

function Get-UsnCaptureDiff {
    param(
        [Parameter(Mandatory)][object]$Pre,
        [Parameter(Mandatory)][object]$Post
    )
    $preMap = @{}
    foreach ($entry in @($Pre.Entries)) {
        $preMap[[string]$entry.RelativePath] = $entry
    }
    $postMap = @{}
    foreach ($entry in @($Post.Entries)) {
        $postMap[[string]$entry.RelativePath] = $entry
    }
    $changed = [Collections.Generic.List[object]]::new()
    foreach ($key in @($preMap.Keys)) {
        if (-not $postMap.ContainsKey($key)) {
            $changed.Add([ordered]@{ relativePath = $key; change = 'removed' })
            continue
        }
        $left = $preMap[$key]
        $right = $postMap[$key]
        if ([long]$left.Usn -ne [long]$right.Usn -or
            [long]$left.Length -ne [long]$right.Length -or
            [string]$left.FileId128Hex -cne [string]$right.FileId128Hex -or
            [bool]$left.IsDirectory -ne [bool]$right.IsDirectory) {
            $changed.Add([ordered]@{
                relativePath = $key
                change = 'modified'
                preUsn = [long]$left.Usn
                postUsn = [long]$right.Usn
                preLength = [long]$left.Length
                postLength = [long]$right.Length
                preFileId = [string]$left.FileId128Hex
                postFileId = [string]$right.FileId128Hex
                postReason = [int]$right.Reason
            })
        }
    }
    foreach ($key in @($postMap.Keys)) {
        if (-not $preMap.ContainsKey($key)) {
            $changed.Add([ordered]@{ relativePath = $key; change = 'added' })
        }
    }
    return @($changed)
}

function Get-ProcessTree {
    param(
        [Parameter(Mandatory)][int]$RootId,
        # 被测 wrapper 实际派生进程的最早创建时刻（wrapper 启动前记录的 UTC）。
        # Win32_Process 的 ParentProcessId 只是快照值：无关进程的已退出父进程
        # 持有的 PID 被 wrapper 进程复用后，会以陈旧父链被误认成后代。真后代
        # 必然晚于其父（及 wrapper 启动时刻）创建，据此把归属判据收窄到
        # 「创建序可证明的 wrapper 子树」；不放宽任何收口断言。
        [Parameter(Mandatory)][datetimeoffset]$EarliestDescendantUtc
    )
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $byParent = @{}
    foreach ($item in $all) {
        $parentId = [int]$item.ParentProcessId
        if (-not $byParent.ContainsKey($parentId)) {
            $byParent[$parentId] = [Collections.Generic.List[object]]::new()
        }
        $byParent[$parentId].Add($item)
    }
    $cutoffUtc = $EarliestDescendantUtc.UtcDateTime.AddSeconds(-5)
    $nodes = [Collections.Generic.List[object]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $seen = [Collections.Generic.HashSet[int]]::new()
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        if (-not $seen.Add($id)) { continue }
        $match = @($all | Where-Object { [int]$_.ProcessId -eq $id } | Select-Object -First 1)
        $parentCreatedUtc = $null
        if ($match.Count -eq 1) {
            if ($null -ne $match[0].CreationDate) {
                $parentCreatedUtc = [datetimeoffset]::new([datetime]$match[0].CreationDate).UtcDateTime
            }
            $nodes.Add([pscustomobject][ordered]@{
                processId = [int]$match[0].ProcessId
                parentProcessId = [int]$match[0].ParentProcessId
                name = [string]$match[0].Name
                commandLine = [string]$match[0].CommandLine
                creationDateUtc = $parentCreatedUtc
                isRoot = ([int]$match[0].ProcessId -eq $RootId)
            })
        }
        if ($byParent.ContainsKey($id)) {
            foreach ($child in $byParent[$id]) {
                if ($null -eq $child.CreationDate) { continue }
                $childCreatedUtc = [datetimeoffset]::new([datetime]$child.CreationDate).UtcDateTime
                if ($childCreatedUtc -lt $cutoffUtc) { continue }
                if ($null -ne $parentCreatedUtc -and
                    $childCreatedUtc -lt $parentCreatedUtc.AddSeconds(-2)) { continue }
                $queue.Enqueue([int]$child.ProcessId)
            }
        }
    }
    return @($nodes)
}

function Get-RemainingTrackedProcesses {
    param([Parameter(Mandatory)][object[]]$TrackedNodes)
    # 「仍在运行」= 采样时归属到 wrapper 子树的同一进程实例仍在运行。tracked
    # PID 可能在收口检查前退出并被无关进程复用；同名 + 创建时间一致才算同一
    # 实例。StartTime 不可读（权限）时保守视为同一实例：宁可误报也不漏报。
    $remaining = [Collections.Generic.List[object]]::new()
    foreach ($node in @($TrackedNodes)) {
        $alive = Get-Process -Id ([int]$node.processId) -ErrorAction SilentlyContinue
        if ($null -eq $alive -or $alive.HasExited) { continue }
        $sameInstance = $true
        if ($null -ne $node.name) {
            $trackedName = ([string]$node.name) -replace '\.exe$', ''
            if ($trackedName -ne ([string]$alive.Name)) { $sameInstance = $false }
        }
        if ($sameInstance -and $null -ne $node.creationDateUtc) {
            try {
                $aliveStartUtc = ([datetime]$alive.StartTime).ToUniversalTime()
                if ([math]::Abs(($aliveStartUtc - [datetime]$node.creationDateUtc).TotalSeconds) -gt 2) {
                    $sameInstance = $false
                }
            } catch {
                # StartTime 读取失败：保守保持 sameInstance = true。
            }
        }
        if ($sameInstance) {
            $remaining.Add([pscustomobject][ordered]@{
                processId = [int]$alive.Id
                name = [string]$alive.Name
            })
        }
    }
    return @($remaining)
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$RootId)
    if (-not [IO.File]::Exists($taskkillExe)) {
        throw "taskkill 不存在：$taskkillExe"
    }
    $taskkillArgs = @('/F', '/T', '/PID', "$RootId")
    & $taskkillExe @taskkillArgs | Out-Null
    return $(if (Test-Path Variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 })
}

if (-not ('CodexIssue55.UsnSnapshot' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexIssue55
{
    public sealed class UsnEntry
    {
        public string RelativePath;
        public bool IsDirectory;
        public long Length;
        public long Usn;
        public int Reason;
        public int MajorVersion;
        public long LastWriteTimeUtcTicks;
        public uint FileAttributes;
        public string FileId128Hex;
        public int Win32Error;
    }

    public sealed class CaptureResult
    {
        public string Root;
        public string CapturedAtUtc;
        public int FileCount;
        public int DirectoryCount;
        public int ErrorCount;
        public string DigestSha256;
        public UsnEntry[] Entries;
    }

    public static class UsnSnapshot
    {
        private const uint GenericRead = 0x80000000;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FsctlReadFileUsnData = 0x000900EB;
        private const int FileIdInfo = 18;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILE_ID_128
        {
            public ulong Low;
            public ulong High;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILE_ID_INFO
        {
            public ulong VolumeSerialNumber;
            public FILE_ID_128 FileId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint dwFileAttributes;
            public FILETIME ftCreationTime;
            public FILETIME ftLastAccessTime;
            public FILETIME ftLastWriteTime;
            public uint dwVolumeSerialNumber;
            public uint nFileSizeHigh;
            public uint nFileSizeLow;
            public uint nNumberOfLinks;
            public uint nFileIndexHigh;
            public uint nFileIndexLow;
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

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint controlCode,
            IntPtr inputBuffer,
            uint inputBufferSize,
            IntPtr outputBuffer,
            uint outputBufferSize,
            out uint bytesReturned,
            IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle hFile,
            int fileInformationClass,
            ref FILE_ID_INFO fileInformation,
            int bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle hFile,
            out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal))
            {
                return path;
            }

            return @"\\?\" + path;
        }

        public static CaptureResult Capture(string root)
        {
            if (string.IsNullOrWhiteSpace(root))
            {
                throw new ArgumentException("root must be a non-empty path.", nameof(root));
            }

            string fullRoot = Path.GetFullPath(root);
            var entries = new List<UsnEntry>();
            bool isDirectory = Directory.Exists(fullRoot);
            CaptureOne(fullRoot, ".", isDirectory, entries);
            if (isDirectory)
            {
                Walk(fullRoot, "", entries);
            }
            entries.Sort((left, right) => string.CompareOrdinal(left.RelativePath, right.RelativePath));

            int files = 0;
            int directories = 0;
            int errors = 0;
            var digest = new StringBuilder();
            foreach (UsnEntry entry in entries)
            {
                if (entry.IsDirectory)
                {
                    directories += 1;
                }
                else
                {
                    files += 1;
                }

                if (entry.Win32Error != 0)
                {
                    errors += 1;
                }

                digest.Append(entry.RelativePath);
                digest.Append('|');
                digest.Append(entry.IsDirectory ? 'd' : 'f');
                digest.Append('|');
                digest.Append(entry.Length);
                digest.Append('|');
                digest.Append(entry.Usn);
                digest.Append('|');
                digest.Append(entry.FileId128Hex ?? string.Empty);
                digest.Append('|');
                digest.Append(entry.LastWriteTimeUtcTicks);
                digest.Append('|');
                digest.Append(entry.FileAttributes);
                digest.Append('\n');
            }

            string digestSha256;
            using (SHA256 sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(digest.ToString()));
                digestSha256 = BitConverter.ToString(hash).Replace("-", string.Empty).ToLowerInvariant();
            }

            return new CaptureResult
            {
                Root = fullRoot,
                CapturedAtUtc = DateTimeOffset.UtcNow.ToString("o"),
                FileCount = files,
                DirectoryCount = directories,
                ErrorCount = errors,
                DigestSha256 = digestSha256,
                Entries = entries.ToArray()
            };
        }

        private static void Walk(string directory, string relative, List<UsnEntry> entries)
        {
            foreach (string child in Directory.EnumerateFileSystemEntries(directory))
            {
                string name = Path.GetFileName(child);
                string childRelative = string.IsNullOrEmpty(relative) ? name : (relative + "/" + name);
                FileAttributes attributes = File.GetAttributes(child);
                bool isDirectory = (attributes & FileAttributes.Directory) != 0;
                bool isReparse = (attributes & FileAttributes.ReparsePoint) != 0;
                CaptureOne(child, childRelative, isDirectory, entries);
                if (isDirectory && !isReparse)
                {
                    Walk(child, childRelative, entries);
                }
            }
        }

        private static void CaptureOne(string path, string relative, bool isDirectory, List<UsnEntry> entries)
        {
            var entry = new UsnEntry
            {
                RelativePath = relative,
                IsDirectory = isDirectory,
                FileId128Hex = string.Empty
            };

            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(path),
                GenericRead,
                FileShare.ReadWrite | FileShare.Delete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                entry.Win32Error = Marshal.GetLastWin32Error();
                handle.Dispose();
                entries.Add(entry);
                return;
            }

            using (handle)
            {
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(handle, out info))
                {
                    entry.Win32Error = Marshal.GetLastWin32Error();
                    entries.Add(entry);
                    return;
                }

                entry.FileAttributes = info.dwFileAttributes;
                entry.Length = ((long)info.nFileSizeHigh << 32) | info.nFileSizeLow;
                long writeTime = ((long)info.ftLastWriteTime.dwHighDateTime << 32) |
                    info.ftLastWriteTime.dwLowDateTime;
                entry.LastWriteTimeUtcTicks = DateTime.FromFileTimeUtc(writeTime).Ticks;

                FILE_ID_INFO fileIdInfo = new FILE_ID_INFO();
                if (GetFileInformationByHandleEx(
                    handle,
                    FileIdInfo,
                    ref fileIdInfo,
                    Marshal.SizeOf(typeof(FILE_ID_INFO))))
                {
                    byte[] idBytes = new byte[16];
                    Buffer.BlockCopy(BitConverter.GetBytes(fileIdInfo.FileId.Low), 0, idBytes, 0, 8);
                    Buffer.BlockCopy(BitConverter.GetBytes(fileIdInfo.FileId.High), 0, idBytes, 8, 8);
                    entry.FileId128Hex = BitConverter.ToString(idBytes).Replace("-", string.Empty).ToLowerInvariant();
                }

                IntPtr buffer = Marshal.AllocHGlobal(4096);
                try
                {
                    uint bytesReturned;
                    if (!DeviceIoControl(
                        handle,
                        FsctlReadFileUsnData,
                        IntPtr.Zero,
                        0,
                        buffer,
                        4096,
                        out bytesReturned,
                        IntPtr.Zero))
                    {
                        entry.Win32Error = Marshal.GetLastWin32Error();
                        entries.Add(entry);
                        return;
                    }

                    int major = Marshal.ReadInt16(buffer, 4);
                    entry.MajorVersion = major;
                    if (major >= 3)
                    {
                        entry.Usn = Marshal.ReadInt64(buffer, 40);
                        entry.Reason = Marshal.ReadInt32(buffer, 56);
                    }
                    else
                    {
                        entry.Usn = Marshal.ReadInt64(buffer, 24);
                        entry.Reason = Marshal.ReadInt32(buffer, 40);
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }

            entries.Add(entry);
        }
    }
}
'@
}

function Invoke-LiveSafeDeleteTracked {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][int]$ExpectedExitCode,
        # #89：issue21 场景经 fixture .cmd 调用；缺省仍是宿主 live .cmd。
        [string]$WrapperPath = $liveWrapper,
        [switch]$AllowTimeout,
        [switch]$RequireJson
    )

    foreach ($argument in $Arguments) {
        if ([string]$argument -ceq $forbiddenLeftoverTransaction) {
            throw "禁止对本票 leftover transaction 发 Purge/Restore/Resume：$forbiddenLeftoverTransaction"
        }
        if ([string]$argument -ceq $forbiddenLeftoverQuarantine) {
            throw "禁止把 leftover quarantine 当作 fixture：$forbiddenLeftoverQuarantine"
        }
    }

    $stdoutPath = Join-Path $issue55Dir ("{0}.stdout.txt" -f $Name)
    $stderrPath = Join-Path $issue55Dir ("{0}.stderr.txt" -f $Name)
    $metaPath = Join-Path $issue55Dir ("{0}.meta.json" -f $Name)
    if ([IO.File]::Exists($stdoutPath)) { [IO.File]::Delete($stdoutPath) }
    if ([IO.File]::Exists($stderrPath)) { [IO.File]::Delete($stderrPath) }

    $startedAtUtc = [datetimeoffset]::UtcNow
    $proc = Start-Process -FilePath $WrapperPath `
        -ArgumentList @($Arguments) `
        -WorkingDirectory $projectRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow `
        -PassThru
    Assert-True ($null -ne $proc) "未能启动 live wrapper：$Name"
    $trackedNodes = @([pscustomobject][ordered]@{
        processId = [int]$proc.Id
        name = $null
        creationDateUtc = $null
    })
    $trackedPids = @([int]$proc.Id)
    $treeLive = @()
    $treeDeadline = [datetime]::UtcNow.AddMilliseconds(400)
    while ([datetime]::UtcNow -lt $treeDeadline -and -not $proc.HasExited) {
        $treeLive = @(Get-ProcessTree -RootId ([int]$proc.Id) -EarliestDescendantUtc $startedAtUtc)
        if ($treeLive.Count -gt 0) { $trackedNodes = @($treeLive) }
        $trackedPids = @($treeLive | ForEach-Object { [int]$_.processId } | Select-Object -Unique)
        if ($trackedPids.Count -gt 1) { break }
        Start-Sleep -Milliseconds 20
    }
    $timedOut = $false
    $taskkillExit = $null
    try {
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $timedOut = $true
            $taskkillExit = Stop-ProcessTree -RootId ([int]$proc.Id)
            [void]$proc.WaitForExit(15000)
        }
    } finally {
        $proc.Refresh()
    }

    $endedAtUtc = [datetimeoffset]::UtcNow
    $remaining = @(Get-RemainingTrackedProcesses -TrackedNodes $trackedNodes)
    if ($timedOut) {
        $deadline = [datetime]::UtcNow.AddSeconds(8)
        while ([datetime]::UtcNow -lt $deadline -and $remaining.Count -gt 0) {
            Start-Sleep -Milliseconds 50
            $remaining = @(Get-RemainingTrackedProcesses -TrackedNodes $trackedNodes)
        }
    }

    $exitCode = $null
    try {
        if ($proc.HasExited) { $exitCode = [int]$proc.ExitCode }
    } catch {
        $exitCode = $null
    }

    $stdout = Get-WrapperCaptureText -Path $stdoutPath
    $stderr = Get-WrapperCaptureText -Path $stderrPath

    $document = $null
    $jsonError = $null
    if ($RequireJson -and -not $timedOut -and -not [string]::IsNullOrWhiteSpace($stdout)) {
        try {
            $document = $stdout | ConvertFrom-Json -Depth 32 -DateKind String
        } catch {
            $jsonError = [string]$_.Exception.Message
        }
    }

    $record = [ordered]@{
        name = $Name
        invokedVia = $WrapperPath
        arguments = @($Arguments)
        startedAtUtc = $startedAtUtc.ToString('o')
        endedAtUtc = $endedAtUtc.ToString('o')
        wallClockMs = [math]::Round(($endedAtUtc - $startedAtUtc).TotalMilliseconds, 1)
        timeoutMs = $TimeoutMs
        expectedExitCode = $ExpectedExitCode
        actualExitCode = $exitCode
        timedOut = $timedOut
        allowTimeout = [bool]$AllowTimeout
        processId = [int]$proc.Id
        trackedPids = @($trackedPids)
        remainingDescendantCount = $remaining.Count
        remainingDescendants = @($remaining)
        taskkillExit = $taskkillExit
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        stdoutSha256 = if ([IO.File]::Exists($stdoutPath)) { Get-LowerSha256 -Path $stdoutPath } else { $null }
        stderrBytes = if ([IO.File]::Exists($stderrPath)) { [long](Get-Item -LiteralPath $stderrPath).Length } else { 0 }
        jsonError = $jsonError
        lastExitCodeCheckedImmediately = $true
    }
    $invocationRecords.Add([pscustomobject]$record)
    Write-Issue55Json -Path $metaPath -Document $record

    if ($remaining.Count -gt 0) {
        throw ("live wrapper 进程树未收口：{0} remaining={1}" -f $Name, $remaining.Count)
    }
    if ($timedOut -and -not $AllowTimeout) {
        throw ("live wrapper 超时（非预期）：{0} timeoutMs={1} stdout={2}" -f $Name, $TimeoutMs, $stdoutPath)
    }
    if (-not $timedOut -and $exitCode -ne $ExpectedExitCode) {
        throw ("live wrapper 退出码非预期：{0} expected={1} actual={2} stdout={3}" -f `
            $Name, $ExpectedExitCode, $exitCode, $stdout)
    }
    if ($RequireJson -and -not $timedOut -and $null -eq $document) {
        throw ("live wrapper 未给出可解析 JSON：{0} jsonError={1} stdout={2}" -f $Name, $jsonError, $stdout)
    }

    return [pscustomobject][ordered]@{
        name = $Name
        exitCode = $exitCode
        timedOut = $timedOut
        raw = $stdout
        stderr = $stderr
        document = $document
        processId = [int]$proc.Id
        wallClockMs = $record.wallClockMs
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        stdoutSha256 = $record.stdoutSha256
        remainingDescendantCount = $remaining.Count
    }
}

$issue55Full = [IO.Path]::GetFullPath($issue55Dir)
$issue21Full = [IO.Path]::GetFullPath($issue21Dir)
$frozenIssue55Full = [IO.Path]::GetFullPath($frozenIssue55Dir)
$frozenIssue21Full = [IO.Path]::GetFullPath($frozenIssue21Dir)
Assert-True (
    -not $issue55Full.Equals($frozenIssue55Full, [StringComparison]::OrdinalIgnoreCase) -and
    -not $issue55Full.StartsWith($frozenIssue55Full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
) 'issue55 harness 目录不得落在历史 issue55 快照内'
Assert-True (
    -not $issue21Full.Equals($frozenIssue21Full, [StringComparison]::OrdinalIgnoreCase) -and
    -not $issue21Full.StartsWith($frozenIssue21Full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
) 'issue21 harness 目录不得落在历史 issue21 快照内'
Assert-True ([IO.File]::Exists($frozenLeafDeleteFailedPath)) (
    "历史 leaf-delete-failed.json 必须仍在：$frozenLeafDeleteFailedPath")
$frozenLeafDeleteFailedSha256AtStart = Get-LowerSha256 -Path $frozenLeafDeleteFailedPath
[void][IO.Directory]::CreateDirectory($issue55Dir)
[void][IO.Directory]::CreateDirectory($issue21Dir)

Assert-True ([IO.File]::Exists($liveWrapper)) 'live safe-delete wrapper 必须存在'
Assert-True ([IO.File]::Exists($sourceWrapper)) 'source safe-delete wrapper 必须存在'
Assert-True ([IO.File]::Exists($livePowerShellWrapper)) 'live PowerShell safe-delete wrapper 必须存在'
Assert-True ([IO.File]::Exists($sourcePowerShellWrapper)) 'source PowerShell safe-delete wrapper 必须存在'
Assert-True ([IO.File]::Exists($pwshExe)) '受管 pwsh 必须存在'

$gateShimDrift = Get-CodexSafeTreeDeleteGateShimDrift -ProjectRoot $projectRoot -LiveShimPath $livePowerShellWrapper
$identity = [ordered]@{
    artifactType = 'unified-environment.safe-tree-delete.issue55.source-identity'
    schemaVersion = 1
    generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    runtime = [ordered]@{
        psEdition = [string]$PSVersionTable.PSEdition
        psVersion = [string]$PSVersionTable.PSVersion
        processPath = [string](Get-Process -Id $PID).Path
        pwshExe = $pwshExe
    }
    wrappers = [ordered]@{
        liveCmd = $liveWrapper
        sourceCmd = $sourceWrapper
        liveCmdSha256 = Get-LowerSha256 -Path $liveWrapper
        sourceCmdSha256 = Get-LowerSha256 -Path $sourceWrapper
        livePs1 = $livePowerShellWrapper
        livePs1Sha256 = [string]$gateShimDrift.liveSha256
        expectedPs1Sha256 = [string]$gateShimDrift.expectedSha256
        expectedPs1Source = $gateShimDrift.expectedSource
        sourcePs1 = $sourcePowerShellWrapper
        sourcePs1Sha256 = Get-LowerSha256 -Path $sourcePowerShellWrapper
    }
    forbiddenLeftover = [ordered]@{
        quarantinePath = $forbiddenLeftoverQuarantine
        transactionPath = $forbiddenLeftoverTransaction
        quarantineExistsAtStart = [IO.Directory]::Exists($forbiddenLeftoverQuarantine)
        transactionExistsAtStart = [IO.File]::Exists($forbiddenLeftoverTransaction)
        transactionSha256AtStart = $(
            if ([IO.File]::Exists($forbiddenLeftoverTransaction)) {
                Get-LowerSha256 -Path $forbiddenLeftoverTransaction
            } else {
                $null
            })
        note = '属 #45/#50 清空集。本票不得 Resume/Purge/Restore。'
    }
    frozenSnapshots = [ordered]@{
        issue55Dir = $frozenIssue55Dir
        issue21Dir = $frozenIssue21Dir
        leafDeleteFailedPath = $frozenLeafDeleteFailedPath
        leafDeleteFailedSha256AtStart = $frozenLeafDeleteFailedSha256AtStart
        harnessEvidenceRoot = $harnessEvidenceRoot
        note = '历史 issue55/issue21 快照只读。本票 harness 证据只写 harnessEvidenceRoot。'
    }
}
$identity.wrappers.cmdEqual = (
    [string]$identity.wrappers.liveCmdSha256 -ceq [string]$identity.wrappers.sourceCmdSha256)
# #89：ps1Equal = live .ps1 等于部署工具按生产规则从当前仓库生成的 gate shim 安装字节
# （不是转发包装）；期望值来源记录在 expectedPs1Source。
$identity.wrappers.ps1Equal = [bool]$gateShimDrift.equal
Write-Issue55Json -Path (Join-Path $issue55Dir 'identity.json') -Document $identity
Assert-True ([bool]$identity.wrappers.cmdEqual) 'live/source wrapper SHA-256 必须一致'
Assert-True ([bool]$identity.wrappers.ps1Equal) (
    'live PowerShell wrapper 身份断言失败（在任何 live 操作之前闭锁）：' + [string]$gateShimDrift.driftMessage)

$lockHolderText = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TransactionPath,
    [Parameter(Mandatory)][string]$PayloadPath,
    [Parameter(Mandatory)][string]$AcquiredMarkerPath,
    [Parameter(Mandatory)][string]$ReleaseSignalPath,
    [Parameter(Mandatory)][string]$LogPath,
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-LockLog {
    param([string]$Message)
    $line = '{0} {1}' -f [datetimeoffset]::UtcNow.ToString('o'), $Message
    [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

Write-LockLog 'lock-holder-start'
$deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
$stream = $null
try {
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ReleaseSignalPath) {
            Write-LockLog 'release-before-acquire'
            exit 3
        }
        if (Test-Path -LiteralPath $TransactionPath) {
            try {
                $raw = [IO.File]::ReadAllText($TransactionPath)
                $tx = $raw | ConvertFrom-Json -Depth 8 -DateKind String
                if ([string]$tx.status -ceq 'purging') {
                    Write-LockLog 'saw-purging'
                    $stream = [IO.File]::Open(
                        $PayloadPath,
                        [IO.FileMode]::Open,
                        [IO.FileAccess]::Read,
                        [IO.FileShare]::Read)
                    [IO.File]::WriteAllText(
                        $AcquiredMarkerPath,
                        [datetimeoffset]::UtcNow.ToString('o'),
                        [Text.UTF8Encoding]::new($false))
                    Write-LockLog 'acquired'
                    while (-not (Test-Path -LiteralPath $ReleaseSignalPath)) {
                        if ([datetime]::UtcNow -ge $deadline) {
                            Write-LockLog 'timeout-holding'
                            exit 4
                        }
                        Start-Sleep -Milliseconds 50
                    }
                    Write-LockLog 'released'
                    exit 0
                }
            } catch {
                Write-LockLog ('parse-or-open-retry: ' + $_.Exception.Message)
            }
        }
        Start-Sleep -Milliseconds 5
    }
    Write-LockLog 'timeout-waiting-purging'
    exit 2
} finally {
    if ($null -ne $stream) {
        $stream.Dispose()
    }
}
'@
[IO.File]::WriteAllText($lockHolderPath, $lockHolderText, $utf8)

try {
    $preUsn = [CodexIssue55.UsnSnapshot]::Capture($evidenceRoot)
    $prePolicyUsn = [CodexIssue55.UsnSnapshot]::Capture($policyPath)
    Write-Issue55Json -Path (Join-Path $issue55Dir 'status-pre-usn.json') -Document ([ordered]@{
        evidence = (ConvertTo-UsnSlim -Capture $preUsn)
        policy = (ConvertTo-UsnSlim -Capture $prePolicyUsn)
    })

    $status = Invoke-LiveSafeDeleteTracked -Name 'status-zero-write' -Arguments @(
        '-Mode', 'Status'
        '-Json'
    ) -TimeoutMs 900000 -ExpectedExitCode 0 -RequireJson

    $postUsn = [CodexIssue55.UsnSnapshot]::Capture($evidenceRoot)
    $postPolicyUsn = [CodexIssue55.UsnSnapshot]::Capture($policyPath)
    $evidenceDiff = @(Get-UsnCaptureDiff -Pre $preUsn -Post $postUsn)
    $policyDiff = @(Get-UsnCaptureDiff -Pre $prePolicyUsn -Post $postPolicyUsn)
    Write-Issue55Json -Path (Join-Path $issue55Dir 'status-post-usn.json') -Document ([ordered]@{
        evidence = (ConvertTo-UsnSlim -Capture $postUsn)
        policy = (ConvertTo-UsnSlim -Capture $postPolicyUsn)
        evidenceChangedCount = $evidenceDiff.Count
        policyChangedCount = $policyDiff.Count
        evidenceChanged = @($evidenceDiff | Select-Object -First 32)
        policyChanged = @($policyDiff)
    })

    $generationIds = @()
    $operationIds = @()
    if ($null -ne $status.document -and
        $status.document.PSObject.Properties.Name -contains 'operations') {
        $generationIds = @(
            $status.document.operations |
                ForEach-Object {
                    if ($_.PSObject.Properties.Name -contains 'generationId') {
                        [string]$_.generationId
                    }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        $operationIds = @(
            $status.document.operations |
                ForEach-Object {
                    if ($_.PSObject.Properties.Name -contains 'operationId') {
                        [string]$_.operationId
                    }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
    }
    $statusBinding = [ordered]@{
        artifactType = 'unified-environment.safe-tree-delete.issue55.status-generation-binding'
        schemaVersion = 1
        statusCapturedAtUtc = $(if ($status.document.PSObject.Properties.Name -contains 'capturedAtUtc') { [string]$status.document.capturedAtUtc } else { $null })
        policySha256 = $(if ($status.document.PSObject.Properties.Name -contains 'policySha256') { [string]$status.document.policySha256 } else { $null })
        complete = $(if ($status.document.PSObject.Properties.Name -contains 'complete') { [bool]$status.document.complete } else { $null })
        operationCount = $(if ($status.document.PSObject.Properties.Name -contains 'operations') { @($status.document.operations).Count } else { 0 })
        operationIdCount = @($operationIds).Count
        generationIdCount = @($generationIds).Count
        bindingField = 'operations[].operationId'
        bindingNote = 'Status 合同用 operationId（run 目录名 {timestampZ}-{guid}）绑定代际；operations[] 无 generationId。generationIdCount 只观测该缺口，不把缺失字段当成绑定成功。'
        operationIdSample = @($operationIds | Select-Object -First 3)
        stdoutSha256 = [string]$status.stdoutSha256
        preDigestSha256 = [string]$preUsn.DigestSha256
        postDigestSha256 = [string]$postUsn.DigestSha256
        preCapturedAtUtc = [string]$preUsn.CapturedAtUtc
        postCapturedAtUtc = [string]$postUsn.CapturedAtUtc
        zeroWrite = ([string]$preUsn.DigestSha256 -ceq [string]$postUsn.DigestSha256)
        policyPreDigestSha256 = [string]$prePolicyUsn.DigestSha256
        policyPostDigestSha256 = [string]$postPolicyUsn.DigestSha256
        policyZeroWrite = ([string]$prePolicyUsn.DigestSha256 -ceq [string]$postPolicyUsn.DigestSha256)
    }
    Write-Issue55Json -Path (Join-Path $issue55Dir 'status-generation-binding.json') -Document $statusBinding
    Assert-True ([bool]$statusBinding.zeroWrite) (
        "Status 证据根 USN/manifest 发生写入 pre=$($preUsn.DigestSha256) post=$($postUsn.DigestSha256)")
    Assert-True ([bool]$statusBinding.policyZeroWrite) 'Status 不得写入生产 policy.json'
    Assert-True ($status.remainingDescendantCount -eq 0) 'Status 成功路径进程树必须收口'
    Assert-True ($status.exitCode -eq 0) 'Status 只读观测必须 exit 0'
    Assert-True ([int]$statusBinding.operationIdCount -gt 0) (
        'Status 代际绑定必须从 operations[].operationId 收集到非空唯一 id')
    Assert-True ([int]$statusBinding.operationIdCount -eq [int]$statusBinding.operationCount) (
        ("Status operationIdCount({0}) 必须等于 operationCount({1})" -f `
            $statusBinding.operationIdCount, $statusBinding.operationCount))

    $unconfirmedArchive = Invoke-LiveSafeDeleteTracked -Name 'archive-unconfirmed' -Arguments @(
        '-Mode', 'Archive'
        '-Json'
    ) -TimeoutMs 120000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($unconfirmedArchive.exitCode -eq 0) `
        '缺确认 Archive 必须保持 exit 0，不得被 wrapper 改成非零'
    Assert-True (
        $unconfirmedArchive.document.archived -eq $false -and
        [string]$unconfirmedArchive.document.refusalReason -ceq 'confirm-archive-required') `
        '缺确认 Archive 必须返回 confirm-archive-required'

    $timeoutProcStdout = Join-Path $issue55Dir 'timeout-status.stdout.txt'
    $timeoutProcStderr = Join-Path $issue55Dir 'timeout-status.stderr.txt'
    if ([IO.File]::Exists($timeoutProcStdout)) { [IO.File]::Delete($timeoutProcStdout) }
    if ([IO.File]::Exists($timeoutProcStderr)) { [IO.File]::Delete($timeoutProcStderr) }
    $timeoutStartedAtUtc = [datetimeoffset]::UtcNow
    $timeoutProc = Start-Process -FilePath $liveWrapper `
        -ArgumentList @('-Mode', 'Status', '-Json') `
        -WorkingDirectory $projectRoot `
        -RedirectStandardOutput $timeoutProcStdout `
        -RedirectStandardError $timeoutProcStderr `
        -NoNewWindow `
        -PassThru
    Assert-True ($null -ne $timeoutProc) '超时路径必须启动 live Status'
    $sawPwsh = $false
    $treeAtKill = @()
    $childDeadline = [datetime]::UtcNow.AddSeconds(30)
    while ([datetime]::UtcNow -lt $childDeadline -and -not $timeoutProc.HasExited) {
        $tree = @(Get-ProcessTree -RootId ([int]$timeoutProc.Id) -EarliestDescendantUtc $timeoutStartedAtUtc)
        $pwshNodes = @($tree | Where-Object { [string]$_.name -match 'pwsh' -and -not $_.isRoot })
        if ($pwshNodes.Count -gt 0) {
            $sawPwsh = $true
            $treeAtKill = $tree
            break
        }
        Start-Sleep -Milliseconds 20
    }
    Assert-True ($sawPwsh) '超时路径必须先观察到 wrapper 子 pwsh，再强制收口'
    Assert-True (-not $timeoutProc.HasExited) '超时路径必须在 Status 仍运行时触发'
    Start-Sleep -Milliseconds 250
    Assert-True (-not $timeoutProc.HasExited) '250ms 后 Status 仍应运行，才能证明超时收口'
    $taskkillExit = Stop-ProcessTree -RootId ([int]$timeoutProc.Id)
    [void]$timeoutProc.WaitForExit(15000)
    $timeoutEndedAtUtc = [datetimeoffset]::UtcNow
    $trackedTimeoutPids = @($treeAtKill | ForEach-Object { [int]$_.processId } | Select-Object -Unique)
    $timeoutRemaining = @(Get-RemainingTrackedProcesses -TrackedNodes $treeAtKill)
    $orphanDeadline = [datetime]::UtcNow.AddSeconds(8)
    while ([datetime]::UtcNow -lt $orphanDeadline -and $timeoutRemaining.Count -gt 0) {
        Start-Sleep -Milliseconds 50
        $timeoutRemaining = @(Get-RemainingTrackedProcesses -TrackedNodes $treeAtKill)
    }
    $timeoutExit = $null
    try {
        if ($timeoutProc.HasExited) { $timeoutExit = [int]$timeoutProc.ExitCode }
    } catch {
        $timeoutExit = $null
    }
    $timeoutDrill = [ordered]@{
        artifactType = 'unified-environment.safe-tree-delete.issue55.timeout-process-tree'
        schemaVersion = 1
        invokedVia = $liveWrapper
        arguments = @('-Mode', 'Status', '-Json')
        startedAtUtc = $timeoutStartedAtUtc.ToString('o')
        endedAtUtc = $timeoutEndedAtUtc.ToString('o')
        wallClockMs = [math]::Round(($timeoutEndedAtUtc - $timeoutStartedAtUtc).TotalMilliseconds, 1)
        timeoutMs = 250
        expectedOutcome = 'timeout-then-process-tree-closed'
        sawPwshChild = $sawPwsh
        processId = [int]$timeoutProc.Id
        treeAtKill = @($treeAtKill)
        taskkillExit = $taskkillExit
        actualExitCode = $timeoutExit
        remainingDescendantCount = $timeoutRemaining.Count
        remainingDescendants = @($timeoutRemaining)
        stdoutPath = $timeoutProcStdout
        stderrPath = $timeoutProcStderr
    }
    Write-Issue55Json -Path (Join-Path $issue55Dir 'timeout-drill.json') -Document $timeoutDrill
    Assert-True ($timeoutRemaining.Count -eq 0) (
        "超时路径留下孤儿进程：$($timeoutRemaining | ConvertTo-Json -Compress)")
    $invocationRecords.Add([pscustomobject]$timeoutDrill)

    $entryTokens = $null
    $entryParseErrors = $null
    $entryAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot 'scripts\Invoke-CodexSafeTreeDelete.ps1'),
        [ref]$entryTokens,
        [ref]$entryParseErrors)
    $entryParamNames = @()
    if ($null -ne $entryAst.ParamBlock) {
        $entryParamNames = @(
            $entryAst.ParamBlock.Parameters |
                ForEach-Object { [string]$_.Name.VariablePath.UserPath }
        )
    }
    $wrapperTokens = $null
    $wrapperParseErrors = $null
    $wrapperAst = [Management.Automation.Language.Parser]::ParseFile(
        $livePowerShellWrapper,
        [ref]$wrapperTokens,
        [ref]$wrapperParseErrors)
    $liveWrapperParamNames = @()
    if ($null -ne $wrapperAst.ParamBlock) {
        $liveWrapperParamNames = @(
            $wrapperAst.ParamBlock.Parameters |
                ForEach-Object { [string]$_.Name.VariablePath.UserPath }
        )
    }
    $timeoutParamNames = @(
        @($entryParamNames + $liveWrapperParamNames) |
            Where-Object { $_ -match '(?i)timeout' } |
            Select-Object -Unique
    )
    $timeoutContract = [ordered]@{
        artifactType = 'unified-environment.safe-tree-delete.issue55.timeout-contract'
        schemaVersion = 1
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        note = '超时是 harness 合同，不是 wrapper 合同。禁止给 live wrapper 或 CodexSafeTreeDelete.ps1 加 timeout 参数。'
        wrapperHasTimeoutParameter = ($timeoutParamNames.Count -gt 0)
        wrapperTimeoutParameterNames = @($timeoutParamNames)
        productionEntryParamNames = @($entryParamNames)
        liveWrapperParamNames = @($liveWrapperParamNames)
        liveWrapper = $liveWrapper
        liveWrapperSha256 = [string]$identity.wrappers.liveCmdSha256
        livePs1Sha256 = [string]$identity.wrappers.livePs1Sha256
        unexpectedTimeoutFailsSmoke = $true
        unexpectedTimeoutPreservesStdoutStderrMeta = $true
        harnessAllowTimeoutNeverPassedOnTrackedCalls = $true
        controlledDrill = [ordered]@{
            method = 'taskkill /F /T'
            timeoutMs = 250
            evidence = 'timeout-drill.json'
            proves = 'process-tree-closed'
            remainingDescendantCount = $timeoutRemaining.Count
            taskkillExit = $taskkillExit
            stdoutPath = $timeoutProcStdout
            stderrPath = $timeoutProcStderr
        }
    }
    Write-Issue55Json -Path (Join-Path $issue55Dir 'timeout-contract.json') -Document $timeoutContract
    Assert-True (-not [bool]$timeoutContract.wrapperHasTimeoutParameter) (
        'live wrapper / 生产入口不得出现 timeout 参数；超时是 harness 合同')
    Assert-True ($timeoutRemaining.Count -eq 0) '受控 timeout drill 必须证明进程树收口'

    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [IO.File]::WriteAllText($payloadPath, 'production-smoke', $utf8)
    [IO.File]::SetAttributes($payloadPath, [IO.FileAttributes]::ReadOnly)

    $plan = Invoke-LiveSafeDeleteTracked -Name 'success-plan' -Arguments @(
        '-Mode', 'Plan'
        '-TargetPath', $fixtureRoot
        '-CapabilityRoot', $scratchCapabilityRoot
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($plan.document.planned -eq $true) 'live Plan 必须成功'
    Assert-True ([IO.Directory]::Exists($fixtureRoot)) 'live Plan 必须保持目标不变'

    $apply = Invoke-LiveSafeDeleteTracked -Name 'success-apply' -Arguments @(
        '-Mode', 'Apply'
        '-PlanPath', [string]$plan.document.planPath
        '-ApprovedPlanSha256', [string]$plan.document.planSha256
        '-ConfirmApply'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($apply.document.quarantined -eq $true) 'live Apply 必须完成可恢复隔离'
    Assert-True (-not [IO.Directory]::Exists($fixtureRoot)) 'live Apply 后原目标必须不存在'
    Assert-True ([IO.Directory]::Exists([string]$apply.document.quarantinePath)) 'live Apply 必须保留 quarantine'

    $purge = Invoke-LiveSafeDeleteTracked -Name 'success-purge' -Arguments @(
        '-Mode', 'Purge'
        '-TransactionPath', [string]$apply.document.transactionPath
        '-ApprovedTransactionSha256', [string]$apply.document.transactionSha256
        '-ConfirmPurge'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($purge.document.purged -eq $true) 'live Purge 必须成功'
    Assert-True (-not [IO.Directory]::Exists([string]$apply.document.quarantinePath)) 'live Purge 后 quarantine 必须不存在'

    foreach ($path in @($batchA, $batchB)) {
        [void][IO.Directory]::CreateDirectory($path)
        [IO.File]::WriteAllText((Join-Path $path 'payload.txt'), $path, $utf8)
    }

    $batchPrePlan = Invoke-LiveSafeDeleteTracked -Name 'batch-pre-plan' -Arguments @(
        '-Mode', 'Plan'
        '-TargetPath', $batchA
        '-CapabilityRoot', $scratchCapabilityRoot
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    $batchPreApply = Invoke-LiveSafeDeleteTracked -Name 'batch-pre-apply' -Arguments @(
        '-Mode', 'Apply'
        '-PlanPath', [string]$batchPrePlan.document.planPath
        '-ApprovedPlanSha256', [string]$batchPrePlan.document.planSha256
        '-ConfirmApply'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($batchPreApply.document.quarantined -eq $true) 'live batch smoke 必须制造 recoverable quarantine'

    $batch = Invoke-LiveSafeDeleteTracked -Name 'batch-purge' -Arguments @(
        '-Mode', 'BatchPurge'
        '-TargetPaths', ('{0}::{1}' -f $batchA, $batchB)
        '-CapabilityRoot', $scratchCapabilityRoot
        '-ConfirmApply'
        '-ConfirmPurge'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($batch.document.completed -eq $true) 'live BatchPurge 必须成功'
    Assert-True ($batch.document.purgedCount -eq 2) 'live BatchPurge 必须清理两个目标'
    Assert-True ($batch.document.recoveredCount -eq 1) 'live BatchPurge 必须恢复一个 quarantine'
    Assert-True (-not [IO.Directory]::Exists($batchA)) 'live BatchPurge 后 batchA 不得存在'
    Assert-True (-not [IO.Directory]::Exists($batchB)) 'live BatchPurge 后 batchB 不得存在'
    Assert-True (-not [IO.Directory]::Exists([string]$batchPreApply.document.quarantinePath)) 'live BatchPurge 后 recoverable quarantine 不得存在'

    $batchParentPlan = Invoke-LiveSafeDeleteTracked -Name 'batch-parent-plan' -Arguments @(
        '-Mode', 'Plan'
        '-TargetPath', $batchParent
        '-CapabilityRoot', $scratchCapabilityRoot
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    $batchParentApply = Invoke-LiveSafeDeleteTracked -Name 'batch-parent-apply' -Arguments @(
        '-Mode', 'Apply'
        '-PlanPath', [string]$batchParentPlan.document.planPath
        '-ApprovedPlanSha256', [string]$batchParentPlan.document.planSha256
        '-ConfirmApply'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    $batchParentPurge = Invoke-LiveSafeDeleteTracked -Name 'batch-parent-purge' -Arguments @(
        '-Mode', 'Purge'
        '-TransactionPath', [string]$batchParentApply.document.transactionPath
        '-ApprovedTransactionSha256', [string]$batchParentApply.document.transactionSha256
        '-ConfirmPurge'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($batchParentPurge.document.purged -eq $true) 'live smoke 必须受管清理 batch 父目录'
    Assert-True (-not [IO.Directory]::Exists($batchParent)) 'live smoke 不得遗留新的 batch 父目录'

    [void][IO.Directory]::CreateDirectory($issue21FailFixtureRoot)
    [IO.File]::WriteAllText($issue21FailPayloadPath, 'issue21-revert-forwarding-leaf-delete-failed', $utf8)

    # #89：issue21 变异只作用于 fixture 副本。部署工具测试 seam 把当前源码生成的
    # gate shim 装到 scratch（state/mutex/入口委托全部 fixture 化），fixture .cmd 镜像
    # 生产 .cmd（LF、无 BOM、exit /b 转发）但指向 fixture shim；宿主 live .ps1/.cmd
    # 全程不被打开改写，首尾 SHA-256 校验见 identity 与 summary。
    $issue21DeployRoot = Join-Path $scratchRoot 'issue21-deploy'
    $issue21StateRoot = Join-Path $issue21DeployRoot 'state'
    $issue21ShimPath = Join-Path $issue21DeployRoot 'invoke-safe-tree-delete.ps1'
    $issue21CmdPath = Join-Path $issue21DeployRoot 'invoke-safe-tree-delete.cmd'
    $issue21MutexName = 'Local\CodexSafeTreeDeleteSmokeIssue21-{0}' -f [guid]::NewGuid().ToString('N')
    [void][IO.Directory]::CreateDirectory($issue21StateRoot)
    # BootstrapGate 的 shim cutover 要求 shim 已存在（备份后原子替换）：先放占位 shim。
    [IO.File]::WriteAllText($issue21ShimPath, @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& 'D:\agents\projects\统一环境\scripts\Invoke-CodexSafeTreeDelete.ps1' @args
exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })
'@, $utf8)
    & (Join-Path $projectRoot 'scripts\Deploy-CodexSafeTreeDelete.ps1') `
        -Mode BootstrapGate `
        -DeploymentId ('smoke-issue21-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)) `
        -PreviousClosureSha256 (Get-CodexSafeTreeDeleteClosure -ProjectRoot $projectRoot).closureSha256 `
        -StateRootForTest $issue21StateRoot `
        -ShimPathForTest $issue21ShimPath `
        -ProjectRootForTest $projectRoot `
        -MutexNameForTest $issue21MutexName | Out-Null
    [IO.File]::WriteAllText($issue21CmdPath, (
        "@echo off`n" +
        ('"{0}" -NoLogo -NoProfile -NonInteractive -File "{1}" %*' -f $pwshExe, $issue21ShimPath) + "`n" +
        "exit /b %ERRORLEVEL%`n"), $utf8)

    $failPlan = Invoke-LiveSafeDeleteTracked -Name 'issue21-fail-plan' -WrapperPath $issue21CmdPath -Arguments @(
        '-Mode', 'Plan'
        '-TargetPath', $issue21FailFixtureRoot
        '-CapabilityRoot', $scratchCapabilityRoot
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($failPlan.document.planned -eq $true) 'issue21 负向路径 Plan 必须成功'

    $failApply = Invoke-LiveSafeDeleteTracked -Name 'issue21-fail-apply' -WrapperPath $issue21CmdPath -Arguments @(
        '-Mode', 'Apply'
        '-PlanPath', [string]$failPlan.document.planPath
        '-ApprovedPlanSha256', [string]$failPlan.document.planSha256
        '-ConfirmApply'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($failApply.document.quarantined -eq $true) 'issue21 负向路径 Apply 必须隔离'
    $failQuarantinePath = [string]$failApply.document.quarantinePath
    $failQuarantinePayload = Join-Path $failQuarantinePath 'issue21-locked-payload.txt'
    Assert-True ([IO.File]::Exists($failQuarantinePayload)) "issue21 quarantine payload 必须存在：$failQuarantinePayload"
    $newInflightQuarantine = $failQuarantinePath

    $issue21ReleaseSignalPath = Join-Path $issue21Dir 'lock-release.signal'
    $issue21LockAcquiredPath = Join-Path $issue21Dir 'lock-acquired.txt'
    $issue21LockLogPath = Join-Path $issue21Dir 'lock-holder.log'
    if ([IO.File]::Exists($issue21ReleaseSignalPath)) { [IO.File]::Delete($issue21ReleaseSignalPath) }
    if ([IO.File]::Exists($issue21LockAcquiredPath)) { [IO.File]::Delete($issue21LockAcquiredPath) }
    if ([IO.File]::Exists($issue21LockLogPath)) { [IO.File]::Delete($issue21LockLogPath) }

    $lockArgs = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $lockHolderPath
        '-TransactionPath', [string]$failApply.document.transactionPath
        '-PayloadPath', $failQuarantinePayload
        '-AcquiredMarkerPath', $issue21LockAcquiredPath
        '-ReleaseSignalPath', $issue21ReleaseSignalPath
        '-LogPath', $issue21LockLogPath
        '-TimeoutSeconds', '120'
    )
    $lockProcess = Start-Process -FilePath $pwshExe `
        -ArgumentList $lockArgs `
        -WorkingDirectory $issue21Dir `
        -PassThru -NoNewWindow

    $fixtureShimBackupPath = Join-Path $issue21Dir 'invoke-safe-tree-delete.ps1.fixture-backup'
    $originalFixtureShimBytes = [IO.File]::ReadAllBytes($issue21ShimPath)
    [IO.File]::WriteAllBytes($fixtureShimBackupPath, $originalFixtureShimBytes)
    $fixtureShimShaBeforeMutate = Get-LowerSha256 -Path $issue21ShimPath
    $fixtureBackupSha = Get-LowerSha256 -Path $fixtureShimBackupPath
    Assert-True ($fixtureBackupSha -ceq $fixtureShimShaBeforeMutate) (
        "fixture shim backup SHA 必须与原件一致 backup=$fixtureBackupSha original=$fixtureShimShaBeforeMutate")

    $revertedSha = $null
    $issue21FailPurge = $null
    $revertEvidence = $null
    try {
        $originalText = $utf8.GetString($originalFixtureShimBytes)
        $exitPattern = 'exit \$\(if \(Test-Path Variable:LASTEXITCODE\) \{ \$LASTEXITCODE \} else \{ 0 \}\)'
        Assert-True ([regex]::IsMatch($originalText, $exitPattern)) (
            '变异前 fixture shim 必须含 LASTEXITCODE 转发行')
        # gate shim 的转发行在 try 块内、带缩进：按整行（含缩进与行尾）精确移除。
        $forwardLinePattern = '(?m)^[ \t]*' + $exitPattern + '[ \t]*\r?\n?'
        $forwardLineCount = [regex]::Matches($originalText, $forwardLinePattern).Count
        Assert-True ($forwardLineCount -eq 1) "fixture shim 转发行必须恰好一处（实际 $forwardLineCount）"
        $revertedText = [regex]::Replace($originalText, $forwardLinePattern, '')
        Assert-True ($revertedText.Contains('Invoke-CodexSafeTreeDelete.ps1')) (
            '撤转发后仍须调用同一生产脚本')
        Assert-True (-not [regex]::IsMatch($revertedText, 'LASTEXITCODE')) (
            '撤转发后不得残留 LASTEXITCODE')
        [IO.File]::WriteAllText($issue21ShimPath, $revertedText, $utf8)
        $revertedSha = Get-LowerSha256 -Path $issue21ShimPath
        Assert-True ($revertedSha -cne $fixtureShimShaBeforeMutate) '撤转发后 fixture shim SHA 必须变化'

        $issue21FailPurge = Invoke-LiveSafeDeleteTracked -Name 'issue21-fail-purge-revert-forwarding' -WrapperPath $issue21CmdPath -Arguments @(
            '-Mode', 'Purge'
            '-TransactionPath', [string]$failApply.document.transactionPath
            '-ApprovedTransactionSha256', [string]$failApply.document.transactionSha256
            '-ConfirmPurge'
            '-Json'
        ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson

        $issue21Metrics = $null
        if ($null -ne $issue21FailPurge.document -and
            $issue21FailPurge.document.PSObject.Properties.Name -contains 'metrics') {
            $issue21Metrics = $issue21FailPurge.document.metrics
        }
        $revertEvidence = [ordered]@{
            artifactType = 'unified-environment.safe-tree-delete.issue21.revert-forwarding'
            schemaVersion = 2
            invokedVia = $issue21CmdPath
            mutatedFile = $issue21ShimPath
            mutationScope = 'fixture-copy-only'
            installSeam = 'Deploy-CodexSafeTreeDelete -Mode BootstrapGate 测试 seam（StateRootForTest/ShimPathForTest/ProjectRootForTest/MutexNameForTest）'
            fixtureStateRoot = $issue21StateRoot
            fixtureMutexName = $issue21MutexName
            fixtureShimPath = $issue21ShimPath
            fixtureCmdPath = $issue21CmdPath
            backupPath = $fixtureShimBackupPath
            backupSha256 = $fixtureBackupSha
            fixtureShimSha256BeforeMutate = $fixtureShimShaBeforeMutate
            revertedPs1Sha256 = $revertedSha
            livePs1Sha256 = [string]$identity.wrappers.livePs1Sha256
            liveCmdSha256 = [string]$identity.wrappers.liveCmdSha256
            liveWrappersTouched = $false
            lockStrategy = 'watch-transaction-status-purging-then-FileShare.Read'
            lockAcquiredMarkerExists = [IO.File]::Exists($issue21LockAcquiredPath)
            exitCode = [int]$issue21FailPurge.exitCode
            purged = $(if ($null -ne $issue21FailPurge.document -and $issue21FailPurge.document.PSObject.Properties.Name -contains 'purged') { [bool]$issue21FailPurge.document.purged } else { $null })
            refusalReason = $(if ($null -ne $issue21FailPurge.document -and $issue21FailPurge.document.PSObject.Properties.Name -contains 'refusalReason') { [string]$issue21FailPurge.document.refusalReason } else { $null })
            recoverable = $(if ($null -ne $issue21FailPurge.document -and $issue21FailPurge.document.PSObject.Properties.Name -contains 'recoverable') { [bool]$issue21FailPurge.document.recoverable } else { $null })
            purgeResumable = $(if ($null -ne $issue21FailPurge.document -and $issue21FailPurge.document.PSObject.Properties.Name -contains 'purgeResumable') { [bool]$issue21FailPurge.document.purgeResumable } else { $null })
            metricsPresent = ($null -ne $issue21Metrics)
            remainingDescendantCount = [int]$issue21FailPurge.remainingDescendantCount
            stdoutPath = [string]$issue21FailPurge.stdoutPath
            transactionPath = [string]$failApply.document.transactionPath
            quarantinePath = $failQuarantinePath
            wrapperForwardingAbsent = $true
            provesAssertionWouldFailWithoutForwarding = $true
        }
        $revertEvidence.productionJsonObtained = (
            $revertEvidence.purged -eq $false -and
            [string]$revertEvidence.refusalReason -ceq 'leaf-delete-failed' -and
            [bool]$revertEvidence.metricsPresent)
        $revertEvidence.wrapperSwallowedNonzero = (
            [bool]$revertEvidence.productionJsonObtained -and
            [int]$revertEvidence.exitCode -eq 0)
        Write-Issue55Json -Path (Join-Path $issue21Dir 'revert-forwarding.json') -Document $revertEvidence
        Assert-True ([bool]$revertEvidence.lockAcquiredMarkerExists) `
            'issue21 撤转发路径必须在 purging 之后真正持锁'
        Assert-True ([bool]$revertEvidence.productionJsonObtained) `
            '撤转发后生产 JSON 仍须是 purged=false + leaf-delete-failed + metrics'
        Assert-True ([int]$revertEvidence.exitCode -eq 0) `
            '撤转发后经 fixture .cmd 的 wrapper 必须对 leaf-delete-failed 返回 0（证明断言会红）'
        Assert-True ($issue21FailPurge.remainingDescendantCount -eq 0) 'issue21 撤转发路径进程树必须收口'
        $revertForwardingProved = $true
    } finally {
        try {
            if (-not [IO.File]::Exists($fixtureShimBackupPath)) {
                throw "backup 不存在：$fixtureShimBackupPath"
            }
            [IO.File]::WriteAllBytes(
                $issue21ShimPath,
                [IO.File]::ReadAllBytes($fixtureShimBackupPath))
            $fixtureShimSha256Restored = Get-LowerSha256 -Path $issue21ShimPath
            if ($fixtureShimSha256Restored -cne $fixtureShimShaBeforeMutate) {
                throw ("fixture shim 恢复后 SHA 与变异前不一致 restored=$fixtureShimSha256Restored before=$fixtureShimShaBeforeMutate")
            }
        } catch {
            $fixtureShimRestoreFailed = $true
            throw ("fixture shim 未能从 backup 恢复：$($_.Exception.Message)")
        }
        if ($null -ne $revertEvidence) {
            $revertEvidence.restoredPs1Sha256 = $fixtureShimSha256Restored
            $revertEvidence.wrapperRestored = $true
            Write-Issue55Json -Path (Join-Path $issue21Dir 'revert-forwarding.json') -Document $revertEvidence
        }
    }

    # 恢复转发后（锁仍持有、quarantine 仍是 leaf-delete-failed 状态）：同一 refusal
    # 必须返回非零，证明转发恢复生效。
    $forwardedTransactionSha = Get-LowerSha256 -Path ([string]$failApply.document.transactionPath)
    $issue21ForwardedPurge = Invoke-LiveSafeDeleteTracked -Name 'issue21-fail-purge-forwarded' -WrapperPath $issue21CmdPath -Arguments @(
        '-Mode', 'Purge'
        '-TransactionPath', [string]$failApply.document.transactionPath
        '-ApprovedTransactionSha256', $forwardedTransactionSha
        '-ConfirmPurge'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 1 -RequireJson
    Assert-True ([string]$issue21ForwardedPurge.document.refusalReason -ceq 'leaf-delete-failed') `
        '恢复转发后生产 JSON 仍须是 leaf-delete-failed refusal'
    Assert-True ($issue21ForwardedPurge.document.purged -eq $false) '恢复转发后 purged 仍须为 false'
    Assert-True ($issue21ForwardedPurge.remainingDescendantCount -eq 0) '恢复转发路径进程树必须收口'
    $revertEvidence.forwardedExitCode = [int]$issue21ForwardedPurge.exitCode
    $revertEvidence.forwardedRefusalReason = [string]$issue21ForwardedPurge.document.refusalReason
    Write-Issue55Json -Path (Join-Path $issue21Dir 'revert-forwarding.json') -Document $revertEvidence

    [IO.File]::WriteAllText($issue21ReleaseSignalPath, [datetimeoffset]::UtcNow.ToString('o'), $utf8)
    if ($null -ne $lockProcess -and -not $lockProcess.HasExited) {
        [void]$lockProcess.WaitForExit(15000)
    }
    if ($null -ne $lockProcess -and $lockProcess.HasExited) {
        $lockProcess = $null
    }
    $resumeSha = Get-LowerSha256 -Path ([string]$failApply.document.transactionPath)
    $issue21Resume = Invoke-LiveSafeDeleteTracked -Name 'issue21-fail-purge-resume' -WrapperPath $issue21CmdPath -Arguments @(
        '-Mode', 'Purge'
        '-TransactionPath', [string]$failApply.document.transactionPath
        '-ApprovedTransactionSha256', $resumeSha
        '-ConfirmPurge'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($issue21Resume.document.purged -eq $true) 'issue21 fixture 必须受管 resume Purge 清掉'
    Assert-True (-not [IO.Directory]::Exists($failQuarantinePath)) 'issue21 fixture quarantine 必须已清掉'
    Assert-True (-not [IO.Directory]::Exists($issue21FailFixtureRoot)) 'issue21 fixture 原目标必须不存在'
    $newInflightQuarantine = $null

    [void][IO.Directory]::CreateDirectory($failFixtureRoot)
    [IO.File]::WriteAllText($failPayloadPath, 'issue55-production-leaf-delete-failed', $utf8)

    $failPlan = Invoke-LiveSafeDeleteTracked -Name 'fail-plan' -Arguments @(
        '-Mode', 'Plan'
        '-TargetPath', $failFixtureRoot
        '-CapabilityRoot', $scratchCapabilityRoot
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($failPlan.document.planned -eq $true) '负向路径 Plan 必须成功'

    $failApply = Invoke-LiveSafeDeleteTracked -Name 'fail-apply' -Arguments @(
        '-Mode', 'Apply'
        '-PlanPath', [string]$failPlan.document.planPath
        '-ApprovedPlanSha256', [string]$failPlan.document.planSha256
        '-ConfirmApply'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($failApply.document.quarantined -eq $true) '负向路径 Apply 必须隔离'
    $failQuarantinePath = [string]$failApply.document.quarantinePath
    $failQuarantinePayload = Join-Path $failQuarantinePath 'issue55-locked-payload.txt'
    Assert-True ([IO.File]::Exists($failQuarantinePayload)) "负向路径 quarantine payload 必须存在：$failQuarantinePayload"
    $newInflightQuarantine = $failQuarantinePath

    if ([IO.File]::Exists($releaseSignalPath)) { [IO.File]::Delete($releaseSignalPath) }
    if ([IO.File]::Exists($lockAcquiredPath)) { [IO.File]::Delete($lockAcquiredPath) }
    if ([IO.File]::Exists($lockLogPath)) { [IO.File]::Delete($lockLogPath) }

    $lockArgs = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $lockHolderPath
        '-TransactionPath', [string]$failApply.document.transactionPath
        '-PayloadPath', $failQuarantinePayload
        '-AcquiredMarkerPath', $lockAcquiredPath
        '-ReleaseSignalPath', $releaseSignalPath
        '-LogPath', $lockLogPath
        '-TimeoutSeconds', '120'
    )
    $lockProcess = Start-Process -FilePath $pwshExe `
        -ArgumentList $lockArgs `
        -WorkingDirectory $issue55Dir `
        -PassThru -NoNewWindow

    $failPurge = Invoke-LiveSafeDeleteTracked -Name 'fail-purge-leaf-delete' -Arguments @(
        '-Mode', 'Purge'
        '-TransactionPath', [string]$failApply.document.transactionPath
        '-ApprovedTransactionSha256', [string]$failApply.document.transactionSha256
        '-ConfirmPurge'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 1 -RequireJson

    $metrics = $null
    if ($null -ne $failPurge.document -and
        $failPurge.document.PSObject.Properties.Name -contains 'metrics') {
        $metrics = $failPurge.document.metrics
    }
    $leafEvidence = [ordered]@{
        artifactType = 'unified-environment.safe-tree-delete.issue55.production-purge-leaf-delete-failed'
        schemaVersion = 1
        invokedVia = $liveWrapper
        lockStrategy = 'watch-transaction-status-purging-then-FileShare.Read'
        lockAcquiredMarkerExists = [IO.File]::Exists($lockAcquiredPath)
        exitCode = [int]$failPurge.exitCode
        purged = $(if ($null -ne $failPurge.document -and $failPurge.document.PSObject.Properties.Name -contains 'purged') { [bool]$failPurge.document.purged } else { $null })
        refusalReason = $(if ($null -ne $failPurge.document -and $failPurge.document.PSObject.Properties.Name -contains 'refusalReason') { [string]$failPurge.document.refusalReason } else { $null })
        recoverable = $(if ($null -ne $failPurge.document -and $failPurge.document.PSObject.Properties.Name -contains 'recoverable') { [bool]$failPurge.document.recoverable } else { $null })
        purgeResumable = $(if ($null -ne $failPurge.document -and $failPurge.document.PSObject.Properties.Name -contains 'purgeResumable') { [bool]$failPurge.document.purgeResumable } else { $null })
        metricsPresent = ($null -ne $metrics)
        remainingDescendantCount = [int]$failPurge.remainingDescendantCount
        stdoutPath = [string]$failPurge.stdoutPath
        transactionPath = [string]$failApply.document.transactionPath
        quarantinePath = $failQuarantinePath
    }
    $leafEvidence.productionJsonObtained = (
        $leafEvidence.purged -eq $false -and
        [string]$leafEvidence.refusalReason -ceq 'leaf-delete-failed' -and
        [bool]$leafEvidence.metricsPresent -and
        [int]$leafEvidence.exitCode -ne 0)
    Write-Issue55Json -Path (Join-Path $issue55Dir 'leaf-delete-failed.json') -Document $leafEvidence
    Assert-True ([bool]$leafEvidence.lockAcquiredMarkerExists) `
        'leaf-delete-failed 必须在 purging 之后真正持锁，不能只靠 suite exit 0'
    Assert-True ([bool]$leafEvidence.productionJsonObtained) `
        '必须经真实受管 wrapper 打出 purged=false + leaf-delete-failed + metrics + 非零退出码'
    Assert-True ($failPurge.remainingDescendantCount -eq 0) '失败路径进程树必须收口'
    $leafDeleteFailedObtained = $true

    [IO.File]::WriteAllText($releaseSignalPath, [datetimeoffset]::UtcNow.ToString('o'), $utf8)
    if ($null -ne $lockProcess -and -not $lockProcess.HasExited) {
        [void]$lockProcess.WaitForExit(15000)
    }
    $resumeSha = Get-LowerSha256 -Path ([string]$failApply.document.transactionPath)
    $failResume = Invoke-LiveSafeDeleteTracked -Name 'fail-purge-resume' -Arguments @(
        '-Mode', 'Purge'
        '-TransactionPath', [string]$failApply.document.transactionPath
        '-ApprovedTransactionSha256', $resumeSha
        '-ConfirmPurge'
        '-Json'
    ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
    Assert-True ($failResume.document.purged -eq $true) '负向路径事后必须受管 resume Purge 清掉本票 fixture'
    Assert-True (-not [IO.Directory]::Exists($failQuarantinePath)) '本票负向 fixture quarantine 必须已清掉'
    Assert-True (-not [IO.Directory]::Exists($failFixtureRoot)) '本票负向 fixture 原目标必须不存在'
    $newInflightQuarantine = $null
} finally {
    if (-not [IO.File]::Exists($releaseSignalPath)) {
        [IO.File]::WriteAllText($releaseSignalPath, [datetimeoffset]::UtcNow.ToString('o'), $utf8)
    }
    $issue21ReleaseSignalForFinally = Join-Path $issue21Dir 'lock-release.signal'
    if (-not [IO.File]::Exists($issue21ReleaseSignalForFinally)) {
        [IO.File]::WriteAllText($issue21ReleaseSignalForFinally, [datetimeoffset]::UtcNow.ToString('o'), $utf8)
    }
    if ($null -ne $lockProcess -and -not $lockProcess.HasExited) {
        [void]$lockProcess.WaitForExit(5000)
        if (-not $lockProcess.HasExited) {
            [void](Stop-ProcessTree -RootId ([int]$lockProcess.Id))
        }
    }
    if ($null -ne $newInflightQuarantine) {
        try {
            if ($null -eq $failApply -or $null -eq $failApply.document) {
                throw 'Apply 文档缺失，无法 resume 本票 inflight quarantine'
            }
            $inflightTransactionPath = [string]$failApply.document.transactionPath
            if (-not [IO.File]::Exists($inflightTransactionPath)) {
                throw "inflight transaction 不存在：$inflightTransactionPath"
            }
            $inflightResumeSha = Get-LowerSha256 -Path $inflightTransactionPath
            $failFinallyResume = Invoke-LiveSafeDeleteTracked -Name 'fail-purge-finally-resume' -Arguments @(
                '-Mode', 'Purge'
                '-TransactionPath', $inflightTransactionPath
                '-ApprovedTransactionSha256', $inflightResumeSha
                '-ConfirmPurge'
                '-Json'
            ) -TimeoutMs 180000 -ExpectedExitCode 0 -RequireJson
            if ($failFinallyResume.document.purged -ne $true) {
                throw 'finally resume 未返回 purged=true'
            }
            if ([IO.Directory]::Exists([string]$newInflightQuarantine)) {
                throw "finally resume 后 quarantine 仍在：$newInflightQuarantine"
            }
            $newInflightQuarantine = $null
        } catch {
            $inflightCleanupError = [string]$_.Exception.Message
        }
    }
    $leftoverStillPresent = [IO.Directory]::Exists($forbiddenLeftoverQuarantine)
    $leftoverTransactionPresent = [IO.File]::Exists($forbiddenLeftoverTransaction)
    $leftoverTransactionSha = if ($leftoverTransactionPresent) {
        Get-LowerSha256 -Path $forbiddenLeftoverTransaction
    } else {
        $null
    }
    $leftoverUntouched = (
        [bool]$identity.forbiddenLeftover.quarantineExistsAtStart -eq $leftoverStillPresent -and
        [bool]$identity.forbiddenLeftover.transactionExistsAtStart -eq $leftoverTransactionPresent -and
        [string]$identity.forbiddenLeftover.transactionSha256AtStart -ceq [string]$leftoverTransactionSha)
    $livePs1Sha256Final = Get-LowerSha256 -Path $livePowerShellWrapper
    $liveCmdSha256Final = Get-LowerSha256 -Path $liveWrapper
    $liveWrappersUntouched = (
        [string]$livePs1Sha256Final -ceq [string]$identity.wrappers.livePs1Sha256 -and
        [string]$liveCmdSha256Final -ceq [string]$identity.wrappers.liveCmdSha256)
    $summary = [ordered]@{
        ok = (
            [bool]$leafDeleteFailedObtained -and
            [bool]$revertForwardingProved -and
            -not [bool]$fixtureShimRestoreFailed -and
            [bool]$liveWrappersUntouched)
        suite = 'CodexSafeTreeDeleteProductionSmoke'
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        startedAtUtc = $suiteStartedAtUtc.ToString('o')
        wallClockSeconds = [math]::Round(([datetimeoffset]::UtcNow - $suiteStartedAtUtc).TotalSeconds, 3)
        vssUsed = $false
        sla49Untouched = $true
        leftover0ab1e1b6Untouched = $leftoverUntouched
        leftover0ab1e1b6StillPresent = $leftoverStillPresent
        leftover0ab1e1b6TransactionSha256 = $leftoverTransactionSha
        leftover0ab1e1b6TransactionSha256AtStart = [string]$identity.forbiddenLeftover.transactionSha256AtStart
        inflightCleanupError = $inflightCleanupError
        newInflightQuarantine = $newInflightQuarantine
        leafDeleteFailedObtained = $leafDeleteFailedObtained
        revertForwardingProved = $revertForwardingProved
        fixtureShimRestoreFailed = $fixtureShimRestoreFailed
        liveWrappersUntouched = $liveWrappersUntouched
        livePs1Sha256AtStart = [string]$identity.wrappers.livePs1Sha256
        livePs1Sha256AtEnd = $livePs1Sha256Final
        liveCmdSha256AtStart = [string]$identity.wrappers.liveCmdSha256
        liveCmdSha256AtEnd = $liveCmdSha256Final
        expectedLivePs1Sha256 = [string]$identity.wrappers.expectedPs1Sha256
        expectedLivePs1Source = $identity.wrappers.expectedPs1Source
        invocationCount = $invocationRecords.Count
        evidenceDirectory = $issue55Dir
        issue21EvidenceDirectory = $issue21Dir
        statusOperationCount = $(if ($null -ne $statusBinding) { [int]$statusBinding.operationCount } else { $null })
        statusOperationIdCount = $(if ($null -ne $statusBinding) { [int]$statusBinding.operationIdCount } else { $null })
        statusGenerationIdCount = $(if ($null -ne $statusBinding) { [int]$statusBinding.generationIdCount } else { $null })
        statusZeroWrite = $(if ($null -ne $statusBinding) { [bool]$statusBinding.zeroWrite } else { $null })
        timeoutIsHarnessContract = $true
        timeoutContractPath = (Join-Path $issue55Dir 'timeout-contract.json')
        harnessEvidenceRoot = $harnessEvidenceRoot
        frozenLeafDeleteFailedPath = $frozenLeafDeleteFailedPath
        frozenLeafDeleteFailedSha256AtStart = $frozenLeafDeleteFailedSha256AtStart
        frozenLeafDeleteFailedSha256AtEnd = $(
            if ([IO.File]::Exists($frozenLeafDeleteFailedPath)) {
                Get-LowerSha256 -Path $frozenLeafDeleteFailedPath
            } else {
                $null
            })
        frozenSnapshotsUntouched = $false
    }
    $summary.frozenSnapshotsUntouched = (
        [string]$summary.frozenLeafDeleteFailedSha256AtStart -ceq [string]$summary.frozenLeafDeleteFailedSha256AtEnd)
    Write-Issue55Json -Path (Join-Path $issue55Dir 'invocations.json') -Document @($invocationRecords)
    Write-Issue55Json -Path (Join-Path $issue55Dir 'summary.json') -Document $summary
}

if (-not $leftoverUntouched) {
    throw 'issue55 leftover 0ab1e1b6 的 quarantine/transaction 前后状态不一致；本票不得触碰 #45/#50 清空集。'
}
if ($null -ne $inflightCleanupError) {
    throw "issue55 本票 inflight quarantine 未能 resume 清理：$inflightCleanupError"
}
if ($null -ne $newInflightQuarantine) {
    throw "issue55 本票 fixture quarantine 仍在：$newInflightQuarantine"
}
if (-not $leafDeleteFailedObtained) {
    throw 'issue55 未取得生产 leaf-delete-failed JSON。已保留原始证据并停止后续关闭动作。'
}
if (-not $revertForwardingProved) {
    throw 'issue21 未证明临时撤转发后 wrapper 对 leaf-delete-failed 返回 0。'
}
if (-not $liveWrappersUntouched) {
    throw ("套件运行期间宿主 live wrapper 字节发生变化：" +
        "live .ps1 start=$($identity.wrappers.livePs1Sha256) end=$livePs1Sha256Final；" +
        "live .cmd start=$($identity.wrappers.liveCmdSha256) end=$liveCmdSha256Final")
}
if (-not [IO.File]::Exists($frozenLeafDeleteFailedPath)) {
    throw "历史 leaf-delete-failed.json 丢失：$frozenLeafDeleteFailedPath"
}
$frozenLeafDeleteFailedSha256AtEnd = Get-LowerSha256 -Path $frozenLeafDeleteFailedPath
if ([string]$frozenLeafDeleteFailedSha256AtEnd -cne [string]$frozenLeafDeleteFailedSha256AtStart) {
    throw ("历史 leaf-delete-failed.json 被改写 start=$frozenLeafDeleteFailedSha256AtStart end=$frozenLeafDeleteFailedSha256AtEnd")
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteProductionSmoke'
    planPath = [string]$plan.document.planPath
    transactionPath = [string]$purge.document.transactionPath
    transactionSha256 = [string]$purge.document.transactionSha256
    batchRecoveredCount = [int]$batch.document.recoveredCount
    batchParentPurged = [bool]$batchParentPurge.document.purged
    unconfirmedArchiveExitCode = [int]$unconfirmedArchive.exitCode
    unconfirmedArchiveRefusalReason = [string]$unconfirmedArchive.document.refusalReason
    statusZeroWrite = [bool]$statusBinding.zeroWrite
    statusPolicyZeroWrite = [bool]$statusBinding.policyZeroWrite
    statusStdoutSha256 = [string]$status.stdoutSha256
    statusOperationCount = [int]$statusBinding.operationCount
    statusOperationIdCount = [int]$statusBinding.operationIdCount
    statusGenerationIdCount = [int]$statusBinding.generationIdCount
    timeoutTreeClosed = ($timeoutRemaining.Count -eq 0)
    timeoutIsHarnessContract = $true
    leafDeleteFailed = $true
    revertForwardingProved = $true
    revertForwardingExitCode = 0
    revertForwardingForwardedExitCode = 1
    livePs1Sha256Final = $livePs1Sha256Final
    liveCmdSha256Final = $liveCmdSha256Final
    liveWrappersUntouched = $true
    fixtureShimRestored = $true
    leftover0ab1e1b6Untouched = $leftoverUntouched
    newInflightQuarantine = $newInflightQuarantine
    evidenceDirectory = $issue55Dir
    issue21EvidenceDirectory = $issue21Dir
    harnessEvidenceRoot = $harnessEvidenceRoot
    frozenLeafDeleteFailedSha256 = $frozenLeafDeleteFailedSha256AtEnd
    frozenSnapshotsUntouched = $true
}
