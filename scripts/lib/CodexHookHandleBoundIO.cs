using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexHookGovernance
{
    public sealed class HandleBoundFileSnapshot
    {
        public HandleBoundFileSnapshot(string finalPath, byte[] bytes)
        {
            FinalPath = finalPath;
            Bytes = bytes;
        }

        public string FinalPath { get; }

        public byte[] Bytes { get; }
    }

    public sealed class HandlePathMismatchException : IOException
    {
        public HandlePathMismatchException(string expectedPath, string finalPath)
            : base("The opened file handle resolved to a different final path.")
        {
            ExpectedPath = expectedPath;
            FinalPath = finalPath;
        }

        public string ExpectedPath { get; }

        public string FinalPath { get; }
    }

    public static class HandleBoundFileReader
    {
        private const uint FileNameNormalized = 0x0;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle fileHandle,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        public static SafeFileHandle OpenVerifiedReadHandle(string expectedPath)
        {
            if (expectedPath == null)
            {
                throw new ArgumentNullException(nameof(expectedPath));
            }

            string lexicalPath = Path.GetFullPath(expectedPath);
            SafeFileHandle handle = File.OpenHandle(
                lexicalPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                FileOptions.SequentialScan);

            try
            {
                string finalPath = NormalizeFinalPath(GetFinalPath(handle));
                if (!string.Equals(lexicalPath, finalPath, StringComparison.OrdinalIgnoreCase))
                {
                    throw new HandlePathMismatchException(lexicalPath, finalPath);
                }
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public static HandleBoundFileSnapshot ReadAllBytes(string expectedPath)
        {
            string lexicalPath = Path.GetFullPath(expectedPath);
            SafeFileHandle handle = OpenVerifiedReadHandle(lexicalPath);
            using (FileStream stream = new FileStream(handle, FileAccess.Read))
            using (MemoryStream buffer = new MemoryStream())
            {
                stream.CopyTo(buffer);
                return new HandleBoundFileSnapshot(lexicalPath, buffer.ToArray());
            }
        }

        internal static string GetFinalPath(SafeFileHandle handle)
        {
            uint capacity = 512;
            while (true)
            {
                StringBuilder buffer = new StringBuilder(checked((int)capacity));
                uint result = GetFinalPathNameByHandleW(handle, buffer, capacity, FileNameNormalized);
                if (result == 0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                if (result < capacity)
                {
                    return buffer.ToString();
                }

                capacity = checked(result + 1);
            }
        }

        internal static string NormalizeFinalPath(string path)
        {
            const string uncPrefix = @"\\?\UNC\";
            const string devicePrefix = @"\\?\";

            if (path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase))
            {
                return @"\\" + path.Substring(uncPrefix.Length);
            }

            if (path.StartsWith(devicePrefix, StringComparison.OrdinalIgnoreCase))
            {
                return path.Substring(devicePrefix.Length);
            }

            return path;
        }
    }

    public sealed class VerifiedDirectoryChainGuard : IDisposable
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint DeleteAccess = 0x00010000;
        private const uint SynchronizeAccess = 0x00100000;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const int ErrorFileNotFound = 2;
        private const int ErrorPathNotFound = 3;
        private const int ErrorAlreadyExists = 183;

        private readonly List<SafeFileHandle> handles;
        private bool disposed;

        private VerifiedDirectoryChainGuard(string directoryPath, List<SafeFileHandle> handles)
        {
            DirectoryPath = directoryPath;
            this.handles = handles;
        }

        public string DirectoryPath { get; }

        public GuardedTempFile CreateTempFile(string tempPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(tempPath, "tempPath");
            SafeFileHandle handle = CreateFileW(
                lexicalPath,
                GenericWrite | DeleteAccess | SynchronizeAccess,
                FileShare.None,
                IntPtr.Zero,
                CreateNew,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to create a guarded temporary file.");
            }

            try
            {
                VerifyRegularFileHandle(handle, lexicalPath);
                return new GuardedTempFile(this, lexicalPath, handle);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public GuardedTargetFileLease AcquireTargetFileLease(string targetPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(targetPath, "targetPath");
            SafeFileHandle handle = CreateFileW(
                lexicalPath,
                GenericRead,
                // NTFS requires existing target handles to share DELETE for a
                // FileRenameInformationEx POSIX replacement. WRITE remains excluded.
                FileShare.Read | FileShare.Delete,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to acquire a guarded target file lease.");
            }

            try
            {
                VerifyRegularFileHandle(handle, lexicalPath);
                return new GuardedTargetFileLease(this, lexicalPath, handle);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(
            string pathName,
            IntPtr securityAttributes);

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFileTime
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public NativeFileTime CreationTime;
            public NativeFileTime LastAccessTime;
            public NativeFileTime LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle fileHandle,
            out ByHandleFileInformation fileInformation);

        public static VerifiedDirectoryChainGuard Acquire(
            string trustedRoot,
            string targetDirectory,
            bool createMissing)
        {
            return Acquire(trustedRoot, targetDirectory, createMissing, false);
        }

        public static VerifiedDirectoryChainGuard Acquire(
            string trustedRoot,
            string targetDirectory,
            bool createMissing,
            bool requireTargetCreation)
        {
            if (trustedRoot == null)
            {
                throw new ArgumentNullException(nameof(trustedRoot));
            }
            if (targetDirectory == null)
            {
                throw new ArgumentNullException(nameof(targetDirectory));
            }

            string rootPath = TrimDirectoryEnding(Path.GetFullPath(trustedRoot));
            string targetPath = TrimDirectoryEnding(Path.GetFullPath(targetDirectory));
            if (!IsWithin(targetPath, rootPath))
            {
                throw new IOException("The requested directory is outside the trusted root.");
            }

            string volumeRoot = Path.GetPathRoot(targetPath);
            if (string.IsNullOrEmpty(volumeRoot))
            {
                throw new IOException("The requested directory has no volume root.");
            }

            List<SafeFileHandle> openedHandles = new List<SafeFileHandle>();
            try
            {
                string current = volumeRoot;
                OpenAndHoldVerifiedDirectory(current, openedHandles);

                string relative = targetPath.Substring(volumeRoot.Length);
                string[] segments = relative.Split(
                    new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                    StringSplitOptions.RemoveEmptyEntries);
                for (int segmentIndex = 0; segmentIndex < segments.Length; segmentIndex++)
                {
                    string segment = segments[segmentIndex];
                    current = Path.Combine(current, segment);
                    bool isTarget = segmentIndex == segments.Length - 1;
                    SafeFileHandle handle;
                    int error;
                    if (TryOpenVerifiedDirectory(current, out handle, out error))
                    {
                        if (isTarget && requireTargetCreation)
                        {
                            handle.Dispose();
                            throw new IOException("The target directory already exists.");
                        }
                    }
                    else
                    {
                        bool belowTrustedRoot = IsWithin(current, rootPath) &&
                            !string.Equals(current, rootPath, StringComparison.OrdinalIgnoreCase);
                        if (!createMissing || !belowTrustedRoot ||
                            (error != ErrorFileNotFound && error != ErrorPathNotFound))
                        {
                            throw new Win32Exception(error, "Unable to open a verified directory in the path chain.");
                        }

                        if (!CreateDirectoryW(current, IntPtr.Zero))
                        {
                            int createError = Marshal.GetLastWin32Error();
                            if (isTarget && requireTargetCreation && createError == ErrorAlreadyExists)
                            {
                                throw new IOException("The target directory was created concurrently.");
                            }
                            if (createError != ErrorAlreadyExists)
                            {
                                throw new Win32Exception(createError, "Unable to create a directory in the verified path chain.");
                            }
                        }

                        if (!TryOpenVerifiedDirectory(current, out handle, out error))
                        {
                            throw new Win32Exception(error, "Unable to verify a newly created directory in the path chain.");
                        }
                    }
                    openedHandles.Add(handle);
                }

                return new VerifiedDirectoryChainGuard(targetPath, openedHandles);
            }
            catch
            {
                DisposeHandles(openedHandles);
                throw;
            }
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            DisposeHandles(handles);
        }

        private static void OpenAndHoldVerifiedDirectory(
            string path,
            List<SafeFileHandle> openedHandles)
        {
            SafeFileHandle handle;
            int error;
            if (!TryOpenVerifiedDirectory(path, out handle, out error))
            {
                throw new Win32Exception(error, "Unable to open a verified directory in the path chain.");
            }
            openedHandles.Add(handle);
        }

        private static bool TryOpenVerifiedDirectory(
            string expectedPath,
            out SafeFileHandle handle,
            out int error)
        {
            string lexicalPath = Path.GetFullPath(expectedPath);
            handle = CreateFileW(
                lexicalPath,
                GenericRead,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                error = Marshal.GetLastWin32Error();
                handle.Dispose();
                handle = null;
                return false;
            }

            try
            {
                ByHandleFileInformation fileInformation;
                if (!GetFileInformationByHandle(handle, out fileInformation))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if ((fileInformation.FileAttributes & FileAttributeReparsePoint) != 0)
                {
                    throw new IOException("A directory in the verified path chain is a reparse point.");
                }
                if ((fileInformation.FileAttributes & FileAttributeDirectory) == 0)
                {
                    throw new IOException("A path-chain entry is not a directory.");
                }
                string finalPath = HandleBoundFileReader.NormalizeFinalPath(
                    HandleBoundFileReader.GetFinalPath(handle));
                if (!string.Equals(
                    TrimDirectoryEnding(lexicalPath),
                    TrimDirectoryEnding(finalPath),
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new HandlePathMismatchException(lexicalPath, finalPath);
                }
                error = 0;
                return true;
            }
            catch
            {
                handle.Dispose();
                handle = null;
                throw;
            }
        }

        private static bool IsWithin(string candidate, string parent)
        {
            return string.Equals(candidate, parent, StringComparison.OrdinalIgnoreCase) ||
                candidate.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }

        internal void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException(nameof(VerifiedDirectoryChainGuard));
            }
        }

        internal string ValidateChildPath(string childPath, string parameterName)
        {
            ThrowIfDisposed();
            if (childPath == null)
            {
                throw new ArgumentNullException(parameterName);
            }

            string lexicalPath = Path.GetFullPath(childPath);
            string parent = TrimDirectoryEnding(Path.GetDirectoryName(lexicalPath));
            if (!string.Equals(parent, DirectoryPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The guarded file must be an immediate child of the guarded directory.");
            }

            string leaf = Path.GetFileName(lexicalPath);
            if (string.IsNullOrWhiteSpace(leaf) || leaf == "." || leaf == ".." ||
                leaf.Length > 255 || leaf.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                leaf.EndsWith(" ", StringComparison.Ordinal) || leaf.EndsWith(".", StringComparison.Ordinal))
            {
                throw new IOException("The guarded file name is an invalid file name or non-ADS leaf.");
            }
            if (IsReservedDeviceLeaf(leaf))
            {
                throw new IOException("The guarded file name is a reserved Windows device leaf.");
            }
            return lexicalPath;
        }

        private static bool IsReservedDeviceLeaf(string leaf)
        {
            int extensionIndex = leaf.IndexOf('.');
            string baseName = extensionIndex >= 0 ? leaf.Substring(0, extensionIndex) : leaf;
            string normalized = baseName.TrimEnd(' ').ToUpperInvariant();
            if (normalized == "CON" || normalized == "PRN" || normalized == "AUX" || normalized == "NUL")
            {
                return true;
            }
            if (normalized.Length == 4 &&
                (normalized.StartsWith("COM", StringComparison.Ordinal) ||
                 normalized.StartsWith("LPT", StringComparison.Ordinal)) &&
                normalized[3] >= '1' && normalized[3] <= '9')
            {
                return true;
            }
            return normalized == "COM¹" || normalized == "COM²" || normalized == "COM³" ||
                normalized == "LPT¹" || normalized == "LPT²" || normalized == "LPT³";
        }

        internal static void VerifyRegularFileHandle(SafeFileHandle handle, string expectedPath)
        {
            ByHandleFileInformation fileInformation;
            if (!GetFileInformationByHandle(handle, out fileInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if ((fileInformation.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                throw new IOException("The guarded file is a reparse point.");
            }
            if ((fileInformation.FileAttributes & FileAttributeDirectory) != 0)
            {
                throw new IOException("The guarded file is not a regular file.");
            }

            string finalPath = HandleBoundFileReader.NormalizeFinalPath(
                HandleBoundFileReader.GetFinalPath(handle));
            if (!string.Equals(
                Path.GetFullPath(expectedPath),
                Path.GetFullPath(finalPath),
                StringComparison.OrdinalIgnoreCase))
            {
                throw new HandlePathMismatchException(expectedPath, finalPath);
            }
        }

        private static string TrimDirectoryEnding(string path)
        {
            string root = Path.GetPathRoot(path);
            if (string.Equals(path, root, StringComparison.OrdinalIgnoreCase))
            {
                return root;
            }
            return path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static void DisposeHandles(List<SafeFileHandle> openedHandles)
        {
            for (int index = openedHandles.Count - 1; index >= 0; index--)
            {
                openedHandles[index].Dispose();
            }
            openedHandles.Clear();
        }
    }

    public sealed class GuardedTargetFileLease : IDisposable
    {
        private readonly VerifiedDirectoryChainGuard owner;
        private readonly SafeFileHandle handle;
        private readonly FileStream stream;
        private readonly byte[] snapshotBytes;
        private bool disposed;

        internal GuardedTargetFileLease(
            VerifiedDirectoryChainGuard owner,
            string originalPath,
            SafeFileHandle handle)
        {
            this.owner = owner;
            OriginalPath = originalPath;
            this.handle = handle;
            stream = new FileStream(handle, FileAccess.Read);
            try
            {
                snapshotBytes = ReadAllBytesFromHandleCore();
            }
            catch
            {
                stream.Dispose();
                throw;
            }
        }

        public string OriginalPath { get; }

        public byte[] SnapshotBytes
        {
            get
            {
                ThrowIfDisposed();
                owner.ThrowIfDisposed();
                return (byte[])snapshotBytes.Clone();
            }
        }

        public byte[] ReadAllBytesFromHandle()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            return ReadAllBytesFromHandleCore();
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            stream.Dispose();
        }

        private byte[] ReadAllBytesFromHandleCore()
        {
            stream.Position = 0;
            using (MemoryStream buffer = new MemoryStream())
            {
                stream.CopyTo(buffer);
                return buffer.ToArray();
            }
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException(nameof(GuardedTargetFileLease));
            }
        }
    }

    public sealed class GuardedTempFile : IDisposable
    {
        private const int FileRenameInformationEx = 65;
        private const uint FileRenameReplaceIfExists = 0x00000001;
        private const uint FileRenamePosixSemantics = 0x00000002;

        private readonly VerifiedDirectoryChainGuard owner;
        private readonly SafeFileHandle handle;
        private readonly FileStream stream;
        private string currentPath;
        private bool flushed;
        private bool renamed;
        private bool disposed;

        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock
        {
            public IntPtr Status;
            public UIntPtr Information;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(
            SafeFileHandle fileHandle,
            out IoStatusBlock ioStatusBlock,
            IntPtr fileInformation,
            uint length,
            int fileInformationClass);

        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);

        internal GuardedTempFile(
            VerifiedDirectoryChainGuard owner,
            string currentPath,
            SafeFileHandle handle)
        {
            this.owner = owner;
            this.currentPath = currentPath;
            this.handle = handle;
            stream = new FileStream(handle, FileAccess.Write);
        }

        public string CurrentPath { get { return currentPath; } }

        public void WriteAndFlush(byte[] bytes)
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            if (bytes == null)
            {
                throw new ArgumentNullException(nameof(bytes));
            }
            if (flushed)
            {
                throw new InvalidOperationException("The guarded temporary file was already written.");
            }

            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(true);
            flushed = true;
        }

        public void RenameTo(string targetPath, bool replaceIfExists)
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            if (!flushed)
            {
                throw new InvalidOperationException("The guarded temporary file must be flushed before rename.");
            }
            if (renamed)
            {
                throw new InvalidOperationException("The guarded temporary file was already renamed.");
            }

            string lexicalTarget = owner.ValidateChildPath(targetPath, nameof(targetPath));
            VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, currentPath);
            string targetLeaf = Path.GetFileName(lexicalTarget);
            byte[] targetNameBytes = Encoding.Unicode.GetBytes(targetLeaf);
            if (targetNameBytes.Length == 0)
            {
                throw new IOException("The guarded target leaf is empty.");
            }
            int rootDirectoryOffset = IntPtr.Size;
            int fileNameLengthOffset = checked(rootDirectoryOffset + IntPtr.Size);
            int fileNameOffset = checked(fileNameLengthOffset + sizeof(uint));
            int bufferLength = checked(fileNameOffset + targetNameBytes.Length);
            IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
            try
            {
                for (int index = 0; index < bufferLength; index++)
                {
                    Marshal.WriteByte(buffer, index, 0);
                }
                uint renameFlags = replaceIfExists
                    ? FileRenameReplaceIfExists | FileRenamePosixSemantics
                    : 0;
                Marshal.WriteInt32(buffer, 0, unchecked((int)renameFlags));
                Marshal.WriteIntPtr(buffer, rootDirectoryOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, fileNameLengthOffset, targetNameBytes.Length);
                Marshal.Copy(targetNameBytes, 0, IntPtr.Add(buffer, fileNameOffset), targetNameBytes.Length);

                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(
                    handle,
                    out ioStatusBlock,
                    buffer,
                    checked((uint)bufferLength),
                    FileRenameInformationEx);
                // This deliberately has no FileRenameInformation(10) fallback:
                // unsupported class-65 semantics must fail closed.
                if (status != 0)
                {
                    uint dosError = RtlNtStatusToDosError(status);
                    throw new Win32Exception(checked((int)dosError), "Unable to rename a guarded temporary file.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            currentPath = lexicalTarget;
            renamed = true;
            VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, currentPath);
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            stream.Dispose();
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException(nameof(GuardedTempFile));
            }
        }
    }
}
