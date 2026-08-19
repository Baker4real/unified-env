using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using CodexHookGovernance;
using Microsoft.Win32.SafeHandles;

namespace CodexSafeTreeDelete
{
    public sealed class ApplyTreeSnapshotEntry
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
    }

    public sealed class ApplyTreeSnapshotResult
    {
        public string RootVolumeSerialNumber { get; set; }

        public string RootFileIndex { get; set; }

        public List<ApplyTreeSnapshotEntry> Entries { get; set; }
    }

    public sealed class ApplySessionHashCoordinator
    {
        private const uint GenericRead = 0x80000000;
        private const uint FileWriteAttributes = 0x0100;
        private const uint DeleteAccess = 0x00010000;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        private readonly Dictionary<string, FileIdentityV2> expectedIdentities;
        private readonly SessionHashCache sessionCache;
        private readonly bool reuseEnabled;

        public ApplySessionHashCoordinator(
            Dictionary<string, FileIdentityV2> expectedIdentities,
            SessionHashCache sessionCache,
            bool reuseEnabled)
        {
            this.expectedIdentities = expectedIdentities
                ?? throw new ArgumentNullException(nameof(expectedIdentities));
            this.sessionCache = sessionCache
                ?? throw new ArgumentNullException(nameof(sessionCache));
            this.reuseEnabled = reuseEnabled;
        }

        public bool TryReuseFile(
            string literalPath,
            string relativePath,
            bool allowHardLinks,
            out byte[] sha256,
            out string volumeSerialNumber,
            out string fileIndex,
            out long length,
            out LeafStreamSetV1 streamSet)
        {
            sha256 = null;
            volumeSerialNumber = null;
            fileIndex = null;
            length = 0L;
            streamSet = null;
            if (!reuseEnabled || sessionCache.Count == 0)
            {
                return false;
            }

            FileIdentityV2 expected = RequireExpected(relativePath);
            SafeFileHandle handle = OpenLeaseEquivalent(literalPath);
            try
            {
                VerifiedDirectoryChainGuard.VerifySafeTreeDeleteFile(
                    handle,
                    literalPath,
                    allowHardLinks);
                FileIdentityV2 current = FileIdentityReader.GetFileIdentityV2(handle);
                if (current != expected)
                {
                    throw WrapIdentityMismatch(relativePath, expected, current);
                }

                byte[] cached;
                if (!sessionCache.TryGet(current, out cached))
                {
                    return false;
                }

                string[] identity = VerifiedDirectoryChainGuard.ReadFileIdentity(handle);
                volumeSerialNumber = identity[0];
                fileIndex = identity[1];
                length = current.FileSize;
                sha256 = cached;
                streamSet = LeafStreamSetReader.CaptureLeafStreamSet(handle);
                return true;
            }
            finally
            {
                handle.Dispose();
            }
        }

        public byte[] HashFromLease(
            string relativePath,
            SafeTreeDeleteFileLease lease)
        {
            if (lease == null)
            {
                throw new ArgumentNullException(nameof(lease));
            }

            FileIdentityV2 expected = RequireExpected(relativePath);
            FileIdentityV2 current = FileIdentityReader.GetFileIdentityV2(lease.Handle);
            if (current != expected)
            {
                throw WrapIdentityMismatch(relativePath, expected, current);
            }

            byte[] cached;
            if (reuseEnabled && sessionCache.TryGet(current, out cached))
            {
                return cached;
            }

            byte[] hash = lease.ComputeSha256FromHandle();
            if (reuseEnabled)
            {
                sessionCache.Set(current, hash);
            }

            return hash;
        }

        private FileIdentityV2 RequireExpected(string relativePath)
        {
            FileIdentityV2 expected;
            if (!expectedIdentities.TryGetValue(relativePath, out expected) || expected == null)
            {
                throw new InvalidOperationException(
                    "safe-delete apply fileIdentitiesV2 缺少：" + relativePath);
            }

            return expected;
        }

        private static InvalidOperationException WrapIdentityMismatch(
            string relativePath,
            FileIdentityV2 expected,
            FileIdentityV2 actual)
        {
            return new InvalidOperationException(
                "safe-delete apply IdentityMismatch：" + relativePath,
                new IdentityMismatchException(expected, actual));
        }

        private static SafeFileHandle OpenLeaseEquivalent(string literalPath)
        {
            string fullPath = Path.GetFullPath(literalPath);
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(fullPath),
                GenericRead | FileWriteAttributes | DeleteAccess,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(
                    error,
                    "Unable to open the file for Apply hash-reuse identity verification.");
            }

            return handle;
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal))
            {
                return path;
            }

            if (path.StartsWith(@"\\", StringComparison.Ordinal))
            {
                return @"\\?\UNC\" + path.Substring(2);
            }

            return @"\\?\" + path;
        }
    }

    public static class ApplyTreeSnapshotBuilder
    {
        public static ApplyTreeSnapshotResult Build(
            string path,
            string capabilityRoot,
            bool allowHardLinks,
            bool allowInternalDirectoryJunctions,
            string internalDirectoryJunctionTargetRoot,
            ApplySessionHashCoordinator coordinator)
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

            if (coordinator == null)
            {
                throw new ArgumentNullException(nameof(coordinator));
            }

            if (allowInternalDirectoryJunctions &&
                string.IsNullOrWhiteSpace(internalDirectoryJunctionTargetRoot))
            {
                throw new InvalidOperationException(
                    "safe-delete apply snapshot 允许内部 junction 时必须提供 target root。");
            }

            string fullPath = Path.GetFullPath(path);
            string capabilityRootPath = Path.GetFullPath(capabilityRoot);
            string junctionTargetRoot = allowInternalDirectoryJunctions
                ? Path.GetFullPath(internalDirectoryJunctionTargetRoot)
                : null;

            List<ApplyTreeSnapshotEntry> entries = new List<ApplyTreeSnapshotEntry>();
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
                    coordinator,
                    entries);
                return new ApplyTreeSnapshotResult
                {
                    RootVolumeSerialNumber = rootGuard.VolumeSerialNumber,
                    RootFileIndex = rootGuard.FileIndex,
                    Entries = entries
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
            ApplySessionHashCoordinator coordinator,
            List<ApplyTreeSnapshotEntry> entries)
        {
            DirectoryInfo directoryInfo = new DirectoryInfo(directoryPath);
            if (!directoryInfo.Exists ||
                (directoryInfo.Attributes & FileAttributes.ReparsePoint) != 0 ||
                (directoryInfo.Attributes & FileAttributes.Directory) == 0)
            {
                throw new IOException(
                    "safe-delete apply snapshot 遇到非安全普通目录：" + directoryPath);
            }

            entries.Add(new ApplyTreeSnapshotEntry
            {
                RelativePath = relativePath,
                Kind = "directory",
                Sha256Hex = null,
                VolumeSerialNumber = directoryGuard.VolumeSerialNumber,
                FileIndex = directoryGuard.FileIndex,
                LogicalBytes = 0L,
                HashedBytes = 0L
            });

            FileSystemInfo[] children = directoryInfo.GetFileSystemInfos();
            Array.Sort(
                children,
                (left, right) => string.Compare(
                    left.Name,
                    right.Name,
                    StringComparison.CurrentCultureIgnoreCase));

            for (int index = 0; index < children.Length; index++)
            {
                FileSystemInfo child = children[index];
                string childPath = Path.Combine(directoryPath, child.Name);
                string childRelative = relativePath == "."
                    ? child.Name
                    : relativePath + "/" + child.Name;
                FileAttributes attributes = child.Attributes;

                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    if (!allowInternalDirectoryJunctions ||
                        (attributes & FileAttributes.Directory) == 0)
                    {
                        throw new IOException(
                            "safe-delete apply snapshot 包含未授权 reparse point：" + childPath);
                    }

                    SafeTreeDeleteReparseLeafLease junctionLease = null;
                    try
                    {
                        junctionLease = directoryGuard.AcquireSafeTreeDeleteReparseLeafLease(childPath);
                        string junctionTarget = Path.GetFullPath(junctionLease.TargetPath);
                        if (!IsWithin(junctionTarget, junctionTargetRoot))
                        {
                            throw new IOException(
                                "safe-delete apply snapshot junction target 越界：" + childPath);
                        }

                        entries.Add(new ApplyTreeSnapshotEntry
                        {
                            RelativePath = childRelative,
                            Kind = "directory-junction",
                            Sha256Hex = Convert.ToHexString(junctionLease.ReparseDataSha256)
                                .ToLowerInvariant(),
                            VolumeSerialNumber = junctionLease.VolumeSerialNumber,
                            FileIndex = junctionLease.FileIndex,
                            LogicalBytes = 0L,
                            HashedBytes = junctionLease.ReparseDataLength
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

                if ((attributes & FileAttributes.Directory) != 0)
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
                            coordinator,
                            entries);
                    }
                    finally
                    {
                        childGuard.Dispose();
                    }

                    continue;
                }

                byte[] sha256;
                string volumeSerialNumber;
                string fileIndex;
                long length;
                long hashedBytes;
                LeafStreamSetV1 streamSet;
                if (coordinator.TryReuseFile(
                    childPath,
                    childRelative,
                    allowHardLinks,
                    out sha256,
                    out volumeSerialNumber,
                    out fileIndex,
                    out length,
                    out streamSet))
                {
                    hashedBytes = 0L;
                }
                else
                {
                    SafeTreeDeleteFileLease lease = directoryGuard.AcquireSafeTreeDeleteFileLease(
                        childPath,
                        allowHardLinks);
                    try
                    {
                        length = lease.Length;
                        volumeSerialNumber = lease.VolumeSerialNumber;
                        fileIndex = lease.FileIndex;
                        sha256 = coordinator.HashFromLease(childRelative, lease);
                        hashedBytes = length;
                        streamSet = LeafStreamSetReader.CaptureLeafStreamSet(lease.Handle);
                    }
                    finally
                    {
                        lease.Dispose();
                    }
                }

                if (sha256 == null || sha256.Length != 32)
                {
                    throw new InvalidOperationException(
                        "safe-delete apply snapshot 必须返回 32 字节 SHA-256。");
                }

                entries.Add(new ApplyTreeSnapshotEntry
                {
                    RelativePath = childRelative,
                    Kind = "file",
                    Sha256Hex = Convert.ToHexString(sha256).ToLowerInvariant(),
                    VolumeSerialNumber = volumeSerialNumber,
                    FileIndex = fileIndex,
                    LogicalBytes = length,
                    HashedBytes = hashedBytes,
                    StreamNames = streamSet == null ? null : streamSet.StreamNames,
                    NumberOfLinks = streamSet == null ? 0u : streamSet.NumberOfLinks,
                    StreamSetCaptured = streamSet != null,
                    IdentityV2 = streamSet == null ? null : streamSet.Identity
                });
            }
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
