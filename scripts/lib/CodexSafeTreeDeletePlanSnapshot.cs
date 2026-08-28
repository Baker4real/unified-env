using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using CodexHookGovernance;

namespace CodexSafeTreeDelete
{
    public sealed class PlanTreeSnapshotEntry
    {
        public string RelativePath { get; set; }

        public string Kind { get; set; }

        public string Sha256Hex { get; set; }

        public string VolumeSerialNumber { get; set; }

        public string FileIndex { get; set; }

        public long LogicalBytes { get; set; }

        public long HashedBytes { get; set; }

        public string[] StreamNames { get; set; }

        public uint NumberOfLinks { get; set; }

        public bool StreamSetCaptured { get; set; }

        public FileIdentityV2 IdentityV2 { get; set; }

        public string CapturedKind { get; set; }
    }

    public sealed class PlanWalkerCheckpointEvent
    {
        public string Checkpoint { get; set; }

        public string Path { get; set; }

        public string RelativePath { get; set; }

        public string ObservedKind { get; set; }
    }

    public sealed class PlanTreeSnapshotTimings
    {
        public long TotalMs { get; set; }

        public long HashMs { get; set; }

        public long StreamSetMs { get; set; }
    }

    public sealed class PlanTreeSnapshotResult
    {
        public string RootVolumeSerialNumber { get; set; }

        public string RootFileIndex { get; set; }

        public List<PlanTreeSnapshotEntry> Entries { get; set; }

        public PlanTreeSnapshotTimings Timings { get; set; }
    }

    // #56 Wave A：Plan 阶段单遍 C# walker（docs/plans/2026-08-27-safe-tree-delete-
    // issue56-implementation.md §4.1）。与 PowerShell 三遍路径的合同对齐：
    // - file leaf：成功获取 safe lease 是该 leaf 的权威线性化点。lease 后先从同一句柄
    //   捕获 baseline {FileIdentityV2 稳定字段, streamNames, hardLinkCount}，触发
    //   after-file-baseline-captured-before-hash checkpoint，再 lease.ComputeSha256-
    //   FromHandle()（保留句柄复验），随后同句柄重捕获并逐项比较；capturedAtUtc 之外
    //   任一字段漂移均 throw，只有 pre/post 相等才输出 identity/hash/stream set。
    //   open 前同 kind 替换在 lease 线性化点之前，不伪称可检测（checkpoint 1 只证明
    //   file→directory/reparse 等 kind 漂移会在 open 时拒绝）。
    // - directory/'.' root：经 VerifiedDirectoryChainGuard 同句柄
    //   CaptureSafeTreeDeleteDirectoryStreamSet()（assembly-internal DTO，自包含
    //   FILE_STREAM_INFORMATION 解析与 pre/post identity/link 比对）。guard 句柄由
    //   VerifyDirectoryHandle 认证为普通目录（拒绝 reparse）——CapturedKind="directory"
    //   由此推导，与 PS 三遍的 per-path 观察为已知边界差异（记录于 plan §8）。
    // - junction：保留 per-path LeafStreamSetReader.CaptureLeafStreamSet(path) 重开
    //   （与 PS 第三遍同源）；SafeTreeDeleteReparseLeafLease 不暴露句柄；reparse data
    //   sha 仍走 ReparseDataSha256 现路径。
    // - 子项排序：稳定 OrderBy + CurrentCultureIgnoreCase，平局保持枚举序（复刻 PS
    //   Sort-Object Name；Apply walker 的 Array.Sort 不稳定，不能照搬）。
    // - timings：HashMs 含 junction reparse 哈希；StreamSetMs 含全部 stream-set 捕获
    //   （file leaf 的 FileIdentityV2 折算在内，单遍无法拆分）。
    public static class PlanTreeSnapshotBuilder
    {
        private const string SnapshotName = "safe-delete plan snapshot";

        public const string CheckpointAfterEntryObservedBeforeOpen =
            "after-entry-observed-before-open";

        public const string CheckpointAfterFileBaselineCapturedBeforeHash =
            "after-file-baseline-captured-before-hash";

        private sealed class WalkerTimings
        {
            public long HashMs;

            public long StreamSetMs;
        }

        public static PlanTreeSnapshotResult Build(
            string path,
            string capabilityRoot,
            bool allowHardLinks,
            bool allowInternalDirectoryJunctions,
            string internalDirectoryJunctionTargetRoot)
        {
            return BuildCore(
                path,
                capabilityRoot,
                allowHardLinks,
                allowInternalDirectoryJunctions,
                internalDirectoryJunctionTargetRoot,
                null);
        }

        public static PlanTreeSnapshotResult BuildForTest(
            string path,
            string capabilityRoot,
            bool allowHardLinks,
            bool allowInternalDirectoryJunctions,
            string internalDirectoryJunctionTargetRoot,
            Action<string, PlanWalkerCheckpointEvent> checkpoint)
        {
            if (checkpoint == null)
            {
                throw new ArgumentNullException(nameof(checkpoint));
            }

            return BuildCore(
                path,
                capabilityRoot,
                allowHardLinks,
                allowInternalDirectoryJunctions,
                internalDirectoryJunctionTargetRoot,
                checkpoint);
        }

        private static PlanTreeSnapshotResult BuildCore(
            string path,
            string capabilityRoot,
            bool allowHardLinks,
            bool allowInternalDirectoryJunctions,
            string internalDirectoryJunctionTargetRoot,
            Action<string, PlanWalkerCheckpointEvent> checkpoint)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("path must be a non-empty directory path.", nameof(path));
            }

            if (string.IsNullOrWhiteSpace(capabilityRoot))
            {
                throw new ArgumentException(
                    "capabilityRoot must be a non-empty directory path.",
                    nameof(capabilityRoot));
            }

            if (allowInternalDirectoryJunctions &&
                string.IsNullOrWhiteSpace(internalDirectoryJunctionTargetRoot))
            {
                throw new InvalidOperationException(
                    SnapshotName + " 允许内部 junction 时必须提供 target root。");
            }

            string fullPath = Path.GetFullPath(path);
            string capabilityRootPath = Path.GetFullPath(capabilityRoot);
            string junctionTargetRoot = allowInternalDirectoryJunctions
                ? Path.GetFullPath(internalDirectoryJunctionTargetRoot)
                : null;

            Stopwatch totalWatch = Stopwatch.StartNew();
            WalkerTimings timings = new WalkerTimings();
            List<PlanTreeSnapshotEntry> entries = new List<PlanTreeSnapshotEntry>();
            VerifiedDirectoryChainGuard rootGuard = VerifiedDirectoryChainGuard.Acquire(
                capabilityRootPath,
                fullPath,
                false);
            try
            {
                AddDirectoryNode(
                    fullPath,
                    ".",
                    rootGuard,
                    capabilityRootPath,
                    allowHardLinks,
                    allowInternalDirectoryJunctions,
                    junctionTargetRoot,
                    entries,
                    timings,
                    checkpoint);
                totalWatch.Stop();
                return new PlanTreeSnapshotResult
                {
                    RootVolumeSerialNumber = rootGuard.VolumeSerialNumber,
                    RootFileIndex = rootGuard.FileIndex,
                    Entries = entries,
                    Timings = new PlanTreeSnapshotTimings
                    {
                        TotalMs = totalWatch.ElapsedMilliseconds,
                        HashMs = timings.HashMs,
                        StreamSetMs = timings.StreamSetMs
                    }
                };
            }
            finally
            {
                rootGuard.Dispose();
            }
        }

        private static void AddDirectoryNode(
            string directoryPath,
            string relativePath,
            VerifiedDirectoryChainGuard directoryGuard,
            string capabilityRootPath,
            bool allowHardLinks,
            bool allowInternalDirectoryJunctions,
            string junctionTargetRoot,
            List<PlanTreeSnapshotEntry> entries,
            WalkerTimings timings,
            Action<string, PlanWalkerCheckpointEvent> checkpoint)
        {
            DirectoryInfo directoryInfo = new DirectoryInfo(directoryPath);
            if (!directoryInfo.Exists ||
                (directoryInfo.Attributes & FileAttributes.ReparsePoint) != 0 ||
                (directoryInfo.Attributes & FileAttributes.Directory) == 0)
            {
                throw new IOException(
                    SnapshotName + " snapshot 遇到非安全普通目录：" + directoryPath);
            }

            Stopwatch directoryStreamWatch = Stopwatch.StartNew();
            SafeTreeDeleteDirectoryStreamSet directoryStreamSet =
                directoryGuard.CaptureSafeTreeDeleteDirectoryStreamSet();
            directoryStreamWatch.Stop();
            timings.StreamSetMs += directoryStreamWatch.ElapsedMilliseconds;
            entries.Add(new PlanTreeSnapshotEntry
            {
                RelativePath = relativePath,
                Kind = "directory",
                Sha256Hex = null,
                VolumeSerialNumber = directoryGuard.VolumeSerialNumber,
                FileIndex = directoryGuard.FileIndex,
                LogicalBytes = 0L,
                HashedBytes = 0L,
                StreamNames = directoryStreamSet.StreamNames,
                NumberOfLinks = directoryStreamSet.NumberOfLinks,
                StreamSetCaptured = true,
                IdentityV2 = null,
                CapturedKind = "directory"
            });

            FileSystemInfo[] children = directoryInfo.GetFileSystemInfos();
            List<FileSystemInfo> sortedChildren = children
                .OrderBy(child => child.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();

            for (int index = 0; index < sortedChildren.Count; index++)
            {
                FileSystemInfo child = sortedChildren[index];
                string childPath = Path.Combine(directoryPath, child.Name);
                string childRelative = relativePath == "."
                    ? child.Name
                    : relativePath + "/" + child.Name;
                FileAttributes attributes = child.Attributes;
                bool childIsReparse = (attributes & FileAttributes.ReparsePoint) != 0;
                bool childIsDirectory = (attributes & FileAttributes.Directory) != 0;
                string observedKind = childIsReparse
                    ? "directory-junction"
                    : (childIsDirectory ? "directory" : "file");

                if (checkpoint != null)
                {
                    checkpoint(
                        CheckpointAfterEntryObservedBeforeOpen,
                        new PlanWalkerCheckpointEvent
                        {
                            Checkpoint = CheckpointAfterEntryObservedBeforeOpen,
                            Path = childPath,
                            RelativePath = childRelative,
                            ObservedKind = observedKind
                        });
                }

                if (childIsReparse)
                {
                    if (!allowInternalDirectoryJunctions || !childIsDirectory)
                    {
                        throw new IOException(
                            SnapshotName + " snapshot 包含未授权 reparse point：" + childPath);
                    }

                    SafeTreeDeleteReparseLeafLease junctionLease = null;
                    try
                    {
                        Stopwatch hashWatch = Stopwatch.StartNew();
                        junctionLease = directoryGuard.AcquireSafeTreeDeleteReparseLeafLease(childPath);
                        string junctionTarget = Path.GetFullPath(junctionLease.TargetPath);
                        if (!IsWithin(junctionTarget, junctionTargetRoot))
                        {
                            throw new IOException(
                                SnapshotName + " snapshot junction target 越界：" + childPath);
                        }

                        byte[] reparseSha256 = junctionLease.ReparseDataSha256;
                        hashWatch.Stop();
                        timings.HashMs += hashWatch.ElapsedMilliseconds;

                        LeafStreamSetV1 junctionStreamSet = CaptureStreamSet(childPath, timings);
                        entries.Add(new PlanTreeSnapshotEntry
                        {
                            RelativePath = childRelative,
                            Kind = "directory-junction",
                            Sha256Hex = Convert.ToHexString(reparseSha256).ToLowerInvariant(),
                            VolumeSerialNumber = junctionLease.VolumeSerialNumber,
                            FileIndex = junctionLease.FileIndex,
                            LogicalBytes = 0L,
                            HashedBytes = junctionLease.ReparseDataLength,
                            StreamNames = junctionStreamSet.StreamNames,
                            NumberOfLinks = junctionStreamSet.NumberOfLinks,
                            StreamSetCaptured = true,
                            IdentityV2 = junctionStreamSet.Identity,
                            CapturedKind = CapturedKindOf(junctionStreamSet)
                        });
                    }
                    finally
                    {
                        if (junctionLease != null)
                        {
                            junctionLease.Dispose();
                        }
                    }

                    continue;
                }

                if (childIsDirectory)
                {
                    VerifiedDirectoryChainGuard childGuard = VerifiedDirectoryChainGuard.Acquire(
                        capabilityRootPath,
                        childPath,
                        false);
                    try
                    {
                        AddDirectoryNode(
                            childPath,
                            childRelative,
                            childGuard,
                            capabilityRootPath,
                            allowHardLinks,
                            allowInternalDirectoryJunctions,
                            junctionTargetRoot,
                            entries,
                            timings,
                            checkpoint);
                    }
                    finally
                    {
                        childGuard.Dispose();
                    }

                    continue;
                }

                SafeTreeDeleteFileLease lease = directoryGuard.AcquireSafeTreeDeleteFileLease(
                    childPath,
                    allowHardLinks);
                try
                {
                    long length = lease.Length;
                    string volumeSerialNumber = lease.VolumeSerialNumber;
                    string fileIndex = lease.FileIndex;

                    Stopwatch baselineWatch = Stopwatch.StartNew();
                    LeafStreamSetV1 baseline = LeafStreamSetReader.CaptureLeafStreamSet(lease.Handle);
                    baselineWatch.Stop();
                    timings.StreamSetMs += baselineWatch.ElapsedMilliseconds;

                    if (checkpoint != null)
                    {
                        checkpoint(
                            CheckpointAfterFileBaselineCapturedBeforeHash,
                            new PlanWalkerCheckpointEvent
                            {
                                Checkpoint = CheckpointAfterFileBaselineCapturedBeforeHash,
                                Path = childPath,
                                RelativePath = childRelative,
                                ObservedKind = "file"
                            });
                    }

                    Stopwatch hashWatch = Stopwatch.StartNew();
                    byte[] sha256 = lease.ComputeSha256FromHandle();
                    hashWatch.Stop();
                    timings.HashMs += hashWatch.ElapsedMilliseconds;

                    Stopwatch postWatch = Stopwatch.StartNew();
                    LeafStreamSetV1 post = LeafStreamSetReader.CaptureLeafStreamSet(lease.Handle);
                    postWatch.Stop();
                    timings.StreamSetMs += postWatch.ElapsedMilliseconds;

                    AssertFileLeafMetadataStable(childPath, childRelative, baseline, post);

                    if (sha256 == null || sha256.Length != 32)
                    {
                        throw new InvalidOperationException(
                            SnapshotName + " 必须返回 32 字节 SHA-256。");
                    }

                    entries.Add(new PlanTreeSnapshotEntry
                    {
                        RelativePath = childRelative,
                        Kind = "file",
                        Sha256Hex = Convert.ToHexString(sha256).ToLowerInvariant(),
                        VolumeSerialNumber = volumeSerialNumber,
                        FileIndex = fileIndex,
                        LogicalBytes = length,
                        HashedBytes = length,
                        StreamNames = post.StreamNames,
                        NumberOfLinks = post.NumberOfLinks,
                        StreamSetCaptured = true,
                        IdentityV2 = post.Identity,
                        CapturedKind = CapturedKindOf(post)
                    });
                }
                finally
                {
                    lease.Dispose();
                }
            }
        }

        private static void AssertFileLeafMetadataStable(
            string childPath,
            string childRelative,
            LeafStreamSetV1 baseline,
            LeafStreamSetV1 post)
        {
            if (baseline == null || post == null)
            {
                throw new InvalidOperationException(
                    SnapshotName + " file leaf 捕获缺失：" + childPath);
            }
            if (!Equals(baseline.Identity, post.Identity))
            {
                throw new IOException(
                    SnapshotName + " file leaf metadata 漂移（pre/post identity）：" + childPath);
            }
            if (baseline.NumberOfLinks != post.NumberOfLinks)
            {
                throw new IOException(
                    SnapshotName + " file leaf metadata 漂移（pre/post hardlink 计数）：" + childPath);
            }
            if (!StreamNamesEqual(baseline.StreamNames, post.StreamNames))
            {
                throw new IOException(
                    SnapshotName + " file leaf metadata 漂移（pre/post 流集）：" + childRelative);
            }
        }

        private static bool StreamNamesEqual(string[] left, string[] right)
        {
            if (ReferenceEquals(left, right))
            {
                return true;
            }
            if (left == null || right == null || left.Length != right.Length)
            {
                return false;
            }
            for (int index = 0; index < left.Length; index++)
            {
                if (!string.Equals(left[index], right[index], StringComparison.Ordinal))
                {
                    return false;
                }
            }
            return true;
        }

        private static LeafStreamSetV1 CaptureStreamSet(string path, WalkerTimings timings)
        {
            Stopwatch streamWatch = Stopwatch.StartNew();
            LeafStreamSetV1 streamSet = LeafStreamSetReader.CaptureLeafStreamSet(path);
            streamWatch.Stop();
            timings.StreamSetMs += streamWatch.ElapsedMilliseconds;
            return streamSet;
        }

        private static string CapturedKindOf(LeafStreamSetV1 streamSet)
        {
            if (streamSet.IsReparsePoint)
            {
                return "directory-junction";
            }

            return streamSet.IsDirectory ? "directory" : "file";
        }

        private static bool IsWithin(string candidate, string parent)
        {
            string normalizedCandidate = Path.GetFullPath(candidate).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            string normalizedParent = Path.GetFullPath(parent).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            return string.Equals(
                    normalizedCandidate,
                    normalizedParent,
                    StringComparison.OrdinalIgnoreCase) ||
                normalizedCandidate.StartsWith(
                    normalizedParent + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase);
        }
    }
}
