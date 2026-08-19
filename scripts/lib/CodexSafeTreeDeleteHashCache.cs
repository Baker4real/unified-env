using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace CodexSafeTreeDelete
{
    public sealed class IdentityMismatchException : Exception
    {
        public FileIdentityV2 ExpectedIdentity { get; }

        public FileIdentityV2 ActualIdentity { get; }

        public IdentityMismatchException(
            FileIdentityV2 expectedIdentity,
            FileIdentityV2 actualIdentity)
            : base("File identity does not match the expected identity.")
        {
            ExpectedIdentity = expectedIdentity;
            ActualIdentity = actualIdentity;
        }
    }

    public sealed class SessionHashCache
    {
        private readonly Dictionary<FileIdentityV2, byte[]> _hashes =
            new Dictionary<FileIdentityV2, byte[]>();

        public bool TryGet(FileIdentityV2 identity, out byte[] hash)
        {
            if (identity == null)
            {
                throw new ArgumentNullException(nameof(identity));
            }

            byte[] stored;
            if (!_hashes.TryGetValue(identity, out stored))
            {
                hash = null;
                return false;
            }

            hash = (byte[])stored.Clone();
            return true;
        }

        public void Set(FileIdentityV2 identity, byte[] hash)
        {
            if (identity == null)
            {
                throw new ArgumentNullException(nameof(identity));
            }

            if (hash == null)
            {
                throw new ArgumentNullException(nameof(hash));
            }

            _hashes[identity] = (byte[])hash.Clone();
        }

        public void Clear()
        {
            _hashes.Clear();
        }

        public int Count
        {
            get { return _hashes.Count; }
        }
    }

    public sealed class PurgeFileLeaf
    {
        public string LiteralPath { get; }

        public string RelativePath { get; }

        public FileIdentityV2 Identity { get; }

        public PurgeFileLeaf(
            string literalPath,
            string relativePath,
            FileIdentityV2 identity)
        {
            if (string.IsNullOrWhiteSpace(literalPath))
            {
                throw new ArgumentException("literalPath must be a non-empty file path.", nameof(literalPath));
            }

            if (string.IsNullOrWhiteSpace(relativePath))
            {
                throw new ArgumentException("relativePath must be a non-empty relative path.", nameof(relativePath));
            }

            LiteralPath = literalPath;
            RelativePath = relativePath;
            Identity = identity ?? throw new ArgumentNullException(nameof(identity));
        }
    }

    public static class FileHashComputer
    {
        private const uint FileBegin = 0;
        private const int HashBufferSize = 81920;
        private const uint GenericRead = 0x80000000;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFilePointerEx(
            SafeFileHandle hFile,
            long liDistanceToMove,
            out long lpNewFilePointer,
            uint dwMoveMethod);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadFile(
            SafeFileHandle hFile,
            byte[] lpBuffer,
            int nNumberOfBytesToRead,
            out int lpNumberOfBytesRead,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        /// <summary>
        /// Computes the SHA-256 hash of the file referenced by <paramref name="handle"/>.
        /// </summary>
        /// <param name="handle">
        /// An open file handle. The file pointer may be at any position before this call.
        /// </param>
        /// <returns>The SHA-256 digest as a 32-byte array.</returns>
        /// <remarks>
        /// <para>
        /// Contract: this method seeks the handle to offset 0 before hashing, then
        /// seeks the handle back to offset 0 before returning. Callers do not need
        /// to restore the file pointer.
        /// </para>
        /// <para>
        /// This method is not thread-safe for concurrent calls on the same handle.
        /// </para>
        /// </remarks>
        public static byte[] ComputeHashFromHandle(SafeFileHandle handle)
        {
            if (handle == null || handle.IsInvalid || handle.IsClosed)
            {
                throw new ArgumentException("handle must be a valid file handle.", nameof(handle));
            }

            SeekFileBegin(handle);

            byte[] digest;
            using (IncrementalHash hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                byte[] buffer = new byte[HashBufferSize];
                while (true)
                {
                    int bytesRead;
                    if (!ReadFile(handle, buffer, buffer.Length, out bytesRead, IntPtr.Zero))
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "Failed to read file for SHA-256.");
                    }

                    if (bytesRead == 0)
                    {
                        break;
                    }

                    hasher.AppendData(buffer, 0, bytesRead);
                }

                digest = hasher.GetHashAndReset();
            }

            SeekFileBegin(handle);
            return digest;
        }

        /// <summary>
        /// Opens <paramref name="filePath"/> with an exclusive lock, verifies the
        /// current <see cref="FileIdentityV2"/>, then returns a cached or freshly
        /// computed SHA-256 digest.
        /// </summary>
        /// <param name="filePath">Path of the file to hash. Reparse points are not followed.</param>
        /// <param name="expectedIdentity">Identity captured by Plan (or an earlier exclusive open).</param>
        /// <param name="sessionCache">Session-scoped cache keyed by <see cref="FileIdentityV2"/>.</param>
        /// <returns>The SHA-256 digest as a 32-byte array.</returns>
        /// <exception cref="IdentityMismatchException">
        /// Thrown when the identity bound to the exclusive handle does not equal
        /// <paramref name="expectedIdentity"/>. The file contents are not read.
        /// </exception>
        /// <remarks>
        /// <para>
        /// The file is opened with <see cref="FileShare.None"/> and
        /// <c>FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS</c>.
        /// The exclusive handle remains open until this method returns.
        /// </para>
        /// <para>
        /// Identity is read from that same handle. A cache hit returns the stored
        /// digest without hashing. A cache miss hashes from the handle and stores
        /// the digest before returning.
        /// </para>
        /// </remarks>
        public static byte[] GetHashSafely(
            string filePath,
            FileIdentityV2 expectedIdentity,
            SessionHashCache sessionCache)
        {
            if (string.IsNullOrWhiteSpace(filePath))
            {
                throw new ArgumentException("filePath must be a non-empty file path.", nameof(filePath));
            }

            if (expectedIdentity == null)
            {
                throw new ArgumentNullException(nameof(expectedIdentity));
            }

            if (sessionCache == null)
            {
                throw new ArgumentNullException(nameof(sessionCache));
            }

            string fullPath = Path.GetFullPath(filePath);
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(fullPath),
                GenericRead,
                FileShare.None,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(
                    error,
                    "Failed to open path exclusively for hash reuse without following reparse points.");
            }

            using (handle)
            {
                FileIdentityV2 currentIdentity = FileIdentityReader.GetFileIdentityV2(handle);
                if (currentIdentity != expectedIdentity)
                {
                    throw new IdentityMismatchException(expectedIdentity, currentIdentity);
                }

                byte[] cachedHash;
                if (sessionCache.TryGet(currentIdentity, out cachedHash))
                {
                    return cachedHash;
                }

                byte[] hash = ComputeHashFromHandle(handle);
                sessionCache.Set(currentIdentity, hash);
                return hash;
            }
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

        private static void SeekFileBegin(SafeFileHandle handle)
        {
            long newPointer;
            if (!SetFilePointerEx(handle, 0, out newPointer, FileBegin))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Failed to seek file handle to offset 0.");
            }
        }
    }
}
