using System;
using System.Collections.Generic;
using System.IO;
using CodexHookGovernance;

// #56 §4.1 prefactor：HostSafetyParallelPurge* adapter 自 CodexHookHandleBoundIO.cs
// 原样移出（类型清单与行为零变化），使 HandleBoundIO 恢复 BCL-only standalone Add-Type，
// 供 remote catalog guard 单文件部署/加载；本文件进入 safe-delete 两份 loader 的
// base/default source 集。
namespace CodexSafeTreeDelete
{
    public sealed class HostSafetyParallelPurgeLeafSpec
    {
        public string LiteralPath { get; set; }

        public string RelativePath { get; set; }

        public FileIdentityV2 Identity { get; set; }

        public string VolumeSerialNumber { get; set; }

        public string FileIndex { get; set; }

        public string Sha256Hex { get; set; }
    }

    public sealed class HostSafetyParallelPurgeDirectorySpec
    {
        public string LiteralPath { get; set; }

        public string RelativePath { get; set; }

        public string VolumeSerialNumber { get; set; }

        public string FileIndex { get; set; }
    }

    public sealed class HostSafetyParallelPurgeLeafDeleter : IParallelPurgeLeafDeleter
    {
        private readonly string _capabilityRoot;
        private readonly string _treeRoot;
        private readonly string _topLevelDirectory;
        private readonly bool _allowHardLinks;
        private readonly Dictionary<string, HostSafetyParallelPurgeLeafSpec> _specs;
        private readonly List<HostSafetyParallelPurgeDirectorySpec> _directories;
        private readonly SessionHashCache _sessionCache;
        private readonly object _cacheLock;
        private readonly Dictionary<string, CodexHookGovernance.VerifiedDirectoryChainGuard> _guards;
        private CodexHookGovernance.VerifiedDirectoryChainGuard _topGuard;
        private bool _disposed;

        public HostSafetyParallelPurgeLeafDeleter(
            string capabilityRoot,
            string treeRoot,
            string topLevelDirectory,
            bool allowHardLinks,
            Dictionary<string, HostSafetyParallelPurgeLeafSpec> specs,
            List<HostSafetyParallelPurgeDirectorySpec> directories,
            SessionHashCache sessionCache,
            object cacheLock)
        {
            if (string.IsNullOrWhiteSpace(capabilityRoot))
            {
                throw new ArgumentException(
                    "capabilityRoot must be a non-empty path.",
                    nameof(capabilityRoot));
            }

            if (string.IsNullOrWhiteSpace(treeRoot))
            {
                throw new ArgumentException("treeRoot must be a non-empty path.", nameof(treeRoot));
            }

            if (string.IsNullOrWhiteSpace(topLevelDirectory))
            {
                throw new ArgumentException(
                    "topLevelDirectory must be a non-empty path.",
                    nameof(topLevelDirectory));
            }

            if (specs == null)
            {
                throw new ArgumentNullException(nameof(specs));
            }

            _capabilityRoot = Path.GetFullPath(capabilityRoot);
            _treeRoot = Path.GetFullPath(treeRoot);
            _topLevelDirectory = Path.GetFullPath(topLevelDirectory);
            _allowHardLinks = allowHardLinks;
            _specs = specs;
            _directories = directories ?? new List<HostSafetyParallelPurgeDirectorySpec>();
            _sessionCache = sessionCache;
            _cacheLock = cacheLock ?? new object();
            _guards = new Dictionary<string, CodexHookGovernance.VerifiedDirectoryChainGuard>(
                StringComparer.OrdinalIgnoreCase);
            _topGuard = CodexHookGovernance.VerifiedDirectoryChainGuard.AcquireForEmptyDelete(
                _capabilityRoot,
                _topLevelDirectory);
            _guards.Add(_topLevelDirectory, _topGuard);
        }

        public static Func<string, IParallelPurgeLeafDeleter> CreateFactory(
            string capabilityRoot,
            string treeRoot,
            bool allowHardLinks,
            Dictionary<string, HostSafetyParallelPurgeLeafSpec> specs,
            List<HostSafetyParallelPurgeDirectorySpec> directories,
            SessionHashCache sessionCache,
            object cacheLock)
        {
            return delegate(string topLevelDirectory)
            {
                return new HostSafetyParallelPurgeLeafDeleter(
                    capabilityRoot,
                    treeRoot,
                    topLevelDirectory,
                    allowHardLinks,
                    specs,
                    directories,
                    sessionCache,
                    cacheLock);
            };
        }

        public void Delete(string filePath)
        {
            ThrowIfDisposed();
            if (string.IsNullOrWhiteSpace(filePath))
            {
                throw new ArgumentException("filePath must be a non-empty path.", nameof(filePath));
            }

            string fullPath = Path.GetFullPath(filePath);
            HostSafetyParallelPurgeLeafSpec spec;
            if (!_specs.TryGetValue(fullPath, out spec) || spec == null)
            {
                throw new InvalidOperationException(
                    "safe-delete parallel purge missing HostSafety leaf spec: " + fullPath);
            }

            string parent = Path.GetDirectoryName(fullPath);
            if (string.IsNullOrEmpty(parent))
            {
                throw new InvalidOperationException(
                    "safe-delete parallel purge leaf has no parent directory: " + fullPath);
            }

            CodexHookGovernance.VerifiedDirectoryChainGuard guard = GetOrAcquireGuard(parent);
            CodexHookGovernance.SafeTreeDeleteFileLease lease = guard.AcquireSafeTreeDeleteFileLease(
                fullPath,
                _allowHardLinks);
            try
            {
                FileIdentityV2 current = FileIdentityReader.GetFileIdentityV2(lease.Handle);
                if (spec.Identity != null && current != spec.Identity)
                {
                    throw new IdentityMismatchException(spec.Identity, current);
                }

                if (!string.Equals(
                        lease.VolumeSerialNumber,
                        spec.VolumeSerialNumber,
                        StringComparison.Ordinal) ||
                    !string.Equals(lease.FileIndex, spec.FileIndex, StringComparison.Ordinal))
                {
                    throw new IOException(
                        "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: parallel purge handle identity.");
                }

                byte[] hash = GetOrComputeHash(current, lease);
                string actualHex = BitConverter.ToString(hash).Replace("-", string.Empty).ToLowerInvariant();
                if (!string.Equals(actualHex, spec.Sha256Hex, StringComparison.Ordinal))
                {
                    throw new IOException(
                        "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: parallel purge content hash.");
                }

                lease.DeleteWithPosixSemantics();
            }
            finally
            {
                lease.Dispose();
            }
        }

        public void DeleteEmptyDirectories()
        {
            ThrowIfDisposed();
            if (string.Equals(_topLevelDirectory, _treeRoot, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            List<HostSafetyParallelPurgeDirectorySpec> owned =
                new List<HostSafetyParallelPurgeDirectorySpec>();
            for (int i = 0; i < _directories.Count; i++)
            {
                HostSafetyParallelPurgeDirectorySpec directory = _directories[i];
                if (directory == null || string.IsNullOrWhiteSpace(directory.LiteralPath))
                {
                    continue;
                }

                string full = Path.GetFullPath(directory.LiteralPath);
                if (IsUnderOrEqual(full, _topLevelDirectory))
                {
                    owned.Add(directory);
                }
            }

            owned.Sort(delegate(
                HostSafetyParallelPurgeDirectorySpec left,
                HostSafetyParallelPurgeDirectorySpec right)
            {
                return right.LiteralPath.Length.CompareTo(left.LiteralPath.Length);
            });

            for (int i = 0; i < owned.Count; i++)
            {
                HostSafetyParallelPurgeDirectorySpec directory = owned[i];
                string full = Path.GetFullPath(directory.LiteralPath);
                if (!Directory.Exists(full))
                {
                    continue;
                }

                CodexHookGovernance.VerifiedDirectoryChainGuard guard = GetOrAcquireGuard(full);
                if (!string.Equals(
                        guard.VolumeSerialNumber,
                        directory.VolumeSerialNumber,
                        StringComparison.Ordinal) ||
                    !string.Equals(guard.FileIndex, directory.FileIndex, StringComparison.Ordinal))
                {
                    throw new IOException(
                        "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: parallel purge empty directory.");
                }

                guard.DeleteEmptyDirectory();
                _guards.Remove(full);
                if (string.Equals(full, _topLevelDirectory, StringComparison.OrdinalIgnoreCase))
                {
                    _topGuard = null;
                }
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            DisposeGuards();
        }

        private CodexHookGovernance.VerifiedDirectoryChainGuard GetOrAcquireGuard(string parentPath)
        {
            string fullParent = Path.GetFullPath(parentPath);
            CodexHookGovernance.VerifiedDirectoryChainGuard existing;
            if (_guards.TryGetValue(fullParent, out existing))
            {
                return existing;
            }

            if (!IsUnderOrEqual(fullParent, _topLevelDirectory))
            {
                throw new InvalidOperationException(
                    "parallel purge parent is outside the group's top-level directory: " + fullParent);
            }

            string ancestor = Path.GetDirectoryName(fullParent);
            if (string.IsNullOrEmpty(ancestor))
            {
                throw new InvalidOperationException(
                    "parallel purge parent has no ancestor: " + fullParent);
            }

            CodexHookGovernance.VerifiedDirectoryChainGuard parentGuard = GetOrAcquireGuard(ancestor);
            CodexHookGovernance.VerifiedDirectoryChainGuard child =
                parentGuard.AcquireChildDirectoryForEmptyDelete(fullParent);
            _guards.Add(fullParent, child);
            return child;
        }

        private static bool IsUnderOrEqual(string path, string parent)
        {
            if (string.Equals(path, parent, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            string prefix = parent.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                + Path.DirectorySeparatorChar;
            return path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }

        private void DisposeGuards()
        {
            List<string> keys = new List<string>(_guards.Keys);
            keys.Sort(StringComparer.OrdinalIgnoreCase);
            keys.Reverse();
            for (int i = 0; i < keys.Count; i++)
            {
                try
                {
                    _guards[keys[i]].Dispose();
                }
                catch (ObjectDisposedException)
                {
                }
            }

            _guards.Clear();
        }

        private byte[] GetOrComputeHash(
            FileIdentityV2 current,
            CodexHookGovernance.SafeTreeDeleteFileLease lease)
        {
            byte[] cached = null;
            if (_sessionCache != null)
            {
                lock (_cacheLock)
                {
                    if (_sessionCache.TryGet(current, out cached))
                    {
                        return cached;
                    }
                }
            }

            byte[] computed = lease.ComputeSha256FromHandle();
            if (_sessionCache != null)
            {
                lock (_cacheLock)
                {
                    byte[] raced;
                    if (_sessionCache.TryGet(current, out raced)
                        )
                    {
                        return raced;
                    }

                    _sessionCache.Set(current, computed);
                }
            }

            return computed;
        }

        private void ThrowIfDisposed()
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(HostSafetyParallelPurgeLeafDeleter));
            }
        }
    }
}
