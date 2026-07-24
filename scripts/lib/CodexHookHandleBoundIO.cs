using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexHookGovernance
{
    public sealed class HandleBoundFileSnapshot
    {
        public HandleBoundFileSnapshot(
            string finalPath,
            byte[] bytes,
            string volumeSerialNumber,
            string fileIndex,
            string securityDescriptorSddl)
        {
            FinalPath = finalPath;
            Bytes = bytes;
            VolumeSerialNumber = volumeSerialNumber;
            FileIndex = fileIndex;
            SecurityDescriptorSddl = securityDescriptorSddl;
        }

        public string FinalPath { get; }

        public byte[] Bytes { get; }

        public string VolumeSerialNumber { get; }

        public string FileIndex { get; }

        public string SecurityDescriptorSddl { get; }
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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle fileHandle,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle fileHandle,
            out ByHandleFileInformation fileInformation);

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
                ByHandleFileInformation fileInformation;
                if (!GetFileInformationByHandle(handle, out fileInformation))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                stream.CopyTo(buffer);
                return new HandleBoundFileSnapshot(
                    lexicalPath,
                    buffer.ToArray(),
                    fileInformation.VolumeSerialNumber.ToString("x8"),
                    fileInformation.FileIndexHigh.ToString("x8") +
                        fileInformation.FileIndexLow.ToString("x8"),
                    GuardedAclTargetLease.GetSecurityDescriptorSddlForHandle(handle, lexicalPath));
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
        private const uint ReadControl = 0x00020000;
        private const uint WriteDac = 0x00040000;
        private const uint DeleteAccess = 0x00010000;
        private const uint FileWriteAttributes = 0x00000100;
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
        private const int FileDispositionInformationEx = 64;
        private const int FileRenameInformationEx = 65;
        private const int FileNamesInformation = 12;
        private const uint FileDispositionDelete = 0x00000001;
        private const uint FileDispositionPosixSemantics = 0x00000002;
        private const int StatusNoMoreFiles = unchecked((int)0x80000006);

        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock
        {
            public IntPtr Status;
            public UIntPtr Information;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQueryDirectoryFile(
            SafeFileHandle fileHandle,
            IntPtr eventHandle,
            IntPtr apcRoutine,
            IntPtr apcContext,
            out IoStatusBlock ioStatusBlock,
            IntPtr fileInformation,
            uint length,
            int fileInformationClass,
            [MarshalAs(UnmanagedType.U1)] bool returnSingleEntry,
            IntPtr fileName,
            [MarshalAs(UnmanagedType.U1)] bool restartScan);

        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(
            SafeFileHandle fileHandle,
            out IoStatusBlock ioStatusBlock,
            IntPtr fileInformation,
            uint length,
            int fileInformationClass);

        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);

        private readonly List<SafeFileHandle> handles;
        private bool disposed;

        private VerifiedDirectoryChainGuard(
            string directoryPath,
            List<SafeFileHandle> handles,
            string volumeSerialNumber,
            string fileIndex)
        {
            DirectoryPath = directoryPath;
            this.handles = handles;
            VolumeSerialNumber = volumeSerialNumber;
            FileIndex = fileIndex;
        }

        public string DirectoryPath { get; private set; }

        public string VolumeSerialNumber { get; }

        public string FileIndex { get; }

        public void DeleteEmptyDirectory()
        {
            ThrowIfDisposed();
            SafeFileHandle directoryHandle = handles[handles.Count - 1];
            VerifyDirectoryHandle(directoryHandle, DirectoryPath);
            AssertDirectoryEmpty(directoryHandle);

            IntPtr disposition = Marshal.AllocHGlobal(sizeof(uint));
            try
            {
                Marshal.WriteInt32(
                    disposition,
                    unchecked((int)(FileDispositionDelete | FileDispositionPosixSemantics)));
                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(
                    directoryHandle,
                    out ioStatusBlock,
                    disposition,
                    sizeof(uint),
                    FileDispositionInformationEx);
                if (status != 0)
                {
                    uint dosError = RtlNtStatusToDosError(status);
                    throw new Win32Exception(
                        checked((int)dosError),
                        "Unable to delete the verified empty directory.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(disposition);
            }

            disposed = true;
            DisposeHandles(handles);
            if (Directory.Exists(DirectoryPath))
            {
                throw new IOException("The verified empty directory path still exists after handle-bound deletion.");
            }
        }

        public string RenameToSibling(string targetPath)
        {
            ThrowIfDisposed();
            string lexicalTarget = ValidateSiblingDirectoryPath(targetPath, nameof(targetPath));
            SafeFileHandle directoryHandle = handles[handles.Count - 1];
            VerifyDirectoryHandle(directoryHandle, DirectoryPath);

            string targetLeaf = Path.GetFileName(lexicalTarget);
            byte[] targetNameBytes = Encoding.Unicode.GetBytes(targetLeaf);
            int rootDirectoryOffset = IntPtr.Size;
            int fileNameLengthOffset = checked(rootDirectoryOffset + IntPtr.Size);
            int fileNameOffset = checked(fileNameLengthOffset + sizeof(uint));
            int bufferLength = checked(fileNameOffset + targetNameBytes.Length);
            IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
            string sourcePath = DirectoryPath;
            try
            {
                for (int index = 0; index < bufferLength; index++)
                {
                    Marshal.WriteByte(buffer, index, 0);
                }
                Marshal.WriteInt32(buffer, 0, 0);
                Marshal.WriteIntPtr(buffer, rootDirectoryOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, fileNameLengthOffset, targetNameBytes.Length);
                Marshal.Copy(targetNameBytes, 0, IntPtr.Add(buffer, fileNameOffset), targetNameBytes.Length);

                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(
                    directoryHandle,
                    out ioStatusBlock,
                    buffer,
                    checked((uint)bufferLength),
                    FileRenameInformationEx);
                if (status != 0)
                {
                    uint dosError = RtlNtStatusToDosError(status);
                    throw new Win32Exception(checked((int)dosError), "Unable to rename the verified directory to quarantine.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            DirectoryPath = lexicalTarget;
            VerifyDirectoryHandle(directoryHandle, DirectoryPath);
            if (Directory.Exists(sourcePath) || !Directory.Exists(DirectoryPath))
            {
                throw new IOException("The verified directory quarantine rename did not reach the expected path state.");
            }
            return DirectoryPath;
        }

        public GuardedTempFile CreateTempFile(string tempPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(tempPath, "tempPath");
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(lexicalPath),
                GenericRead | GenericWrite | ReadControl | WriteDac | DeleteAccess | SynchronizeAccess,
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
                return new GuardedTempFile(this, lexicalPath, handle, false);
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
                GenericRead | FileWriteAttributes | DeleteAccess,
                // NTFS requires existing target handles to share DELETE for a
                // FileRenameInformationEx POSIX replacement. Write data remains
                // excluded; FILE_WRITE_ATTRIBUTES is required to delete a
                // read-only file with FileDispositionInformationEx.
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

        // The caller already holds this directory with a deny-DELETE share.
        // Open only an immediate child so recursive capability deletion never
        // has to re-open the protected ancestor chain (which would otherwise
        // conflict with the caller's own DELETE lease).
        public VerifiedDirectoryChainGuard AcquireChildDirectoryForEmptyDelete(string childDirectoryPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(childDirectoryPath, "childDirectoryPath");
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(lexicalPath),
                GenericRead | DeleteAccess,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to acquire a guarded child directory delete lease.");
            }

            try
            {
                VerifyDirectoryHandle(handle, lexicalPath);
                string[] identity = GetFileIdentity(handle);
                return new VerifiedDirectoryChainGuard(
                    lexicalPath,
                    new List<SafeFileHandle> { handle },
                    identity[0],
                    identity[1]);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public GuardedTempFile AcquirePreparedTempFile(string tempPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(tempPath, "tempPath");
            SafeFileHandle handle = CreateFileW(
                lexicalPath,
                GenericRead | GenericWrite | DeleteAccess | SynchronizeAccess,
                FileShare.None,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to acquire a guarded prepared temporary file.");
            }
            try
            {
                VerifyRegularFileHandle(handle, lexicalPath);
                return new GuardedTempFile(this, lexicalPath, handle, true);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public GuardedReadOnlyFileLease AcquireReadOnlyFileLease(string targetPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(targetPath, "targetPath");
            SafeFileHandle handle = CreateFileW(
                lexicalPath,
                GenericRead,
                // This lease protects an approved input object. It must prevent
                // writes, delete, and class-65 POSIX replacement for its lifetime.
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to acquire a guarded read-only file lease.");
            }

            try
            {
                VerifyRegularFileHandle(handle, lexicalPath);
                string[] identity = GetFileIdentity(handle);
                return new GuardedReadOnlyFileLease(
                    this,
                    lexicalPath,
                    handle,
                    identity[0],
                    identity[1]);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public GuardedAclTargetLease AcquireAclTargetLease(string targetPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(targetPath, "targetPath");
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(lexicalPath),
                ReadControl | WriteDac | SynchronizeAccess,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to acquire a guarded ACL target lease.");
            }

            try
            {
                bool isDirectory = VerifyAclTargetHandle(handle, lexicalPath);
                string[] identity = GetFileIdentity(handle);
                return new GuardedAclTargetLease(
                    this,
                    lexicalPath,
                    handle,
                    isDirectory,
                    identity[0],
                    identity[1],
                    GuardedAclTargetLease.GetSecurityDescriptorSddlForHandle(handle, lexicalPath));
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) { return path; }
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) { return @"\\?\UNC\" + path.Substring(2); }
            return @"\\?\" + path;
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
            return Acquire(trustedRoot, targetDirectory, createMissing, false, false);
        }

        public static VerifiedDirectoryChainGuard Acquire(
            string trustedRoot,
            string targetDirectory,
            bool createMissing,
            bool requireTargetCreation)
        {
            return Acquire(trustedRoot, targetDirectory, createMissing, requireTargetCreation, false);
        }

        public static VerifiedDirectoryChainGuard AcquireForEmptyDelete(
            string trustedRoot,
            string targetDirectory)
        {
            return Acquire(trustedRoot, targetDirectory, false, false, true);
        }

        private static VerifiedDirectoryChainGuard Acquire(
            string trustedRoot,
            string targetDirectory,
            bool createMissing,
            bool requireTargetCreation,
            bool targetDeleteAccess)
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
                    if (TryOpenVerifiedDirectory(current, isTarget && targetDeleteAccess, out handle, out error))
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

                        if (!TryOpenVerifiedDirectory(current, isTarget && targetDeleteAccess, out handle, out error))
                        {
                            throw new Win32Exception(error, "Unable to verify a newly created directory in the path chain.");
                        }
                    }
                    openedHandles.Add(handle);
                }

                string[] identity = GetFileIdentity(openedHandles[openedHandles.Count - 1]);
                return new VerifiedDirectoryChainGuard(
                    targetPath,
                    openedHandles,
                    identity[0],
                    identity[1]);
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
            if (!TryOpenVerifiedDirectory(path, false, out handle, out error))
            {
                throw new Win32Exception(error, "Unable to open a verified directory in the path chain.");
            }
            openedHandles.Add(handle);
        }

        private static bool TryOpenVerifiedDirectory(
            string expectedPath,
            bool requireDeleteAccess,
            out SafeFileHandle handle,
            out int error)
        {
            string lexicalPath = Path.GetFullPath(expectedPath);
            handle = CreateFileW(
                lexicalPath,
                GenericRead | (requireDeleteAccess ? DeleteAccess : 0),
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

        private static void VerifyDirectoryHandle(SafeFileHandle handle, string expectedPath)
        {
            ByHandleFileInformation fileInformation;
            if (!GetFileInformationByHandle(handle, out fileInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if ((fileInformation.FileAttributes & FileAttributeReparsePoint) != 0 ||
                (fileInformation.FileAttributes & FileAttributeDirectory) == 0)
            {
                throw new IOException("The guarded directory is not a regular directory.");
            }
            string finalPath = HandleBoundFileReader.NormalizeFinalPath(
                HandleBoundFileReader.GetFinalPath(handle));
            if (!string.Equals(
                TrimDirectoryEnding(Path.GetFullPath(expectedPath)),
                TrimDirectoryEnding(Path.GetFullPath(finalPath)),
                StringComparison.OrdinalIgnoreCase))
            {
                throw new HandlePathMismatchException(expectedPath, finalPath);
            }
        }

        private static void AssertDirectoryEmpty(SafeFileHandle handle)
        {
            const int bufferLength = 65536;
            IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
            try
            {
                bool restartScan = true;
                while (true)
                {
                    IoStatusBlock ioStatusBlock;
                    int status = NtQueryDirectoryFile(
                        handle,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        out ioStatusBlock,
                        buffer,
                        bufferLength,
                        FileNamesInformation,
                        false,
                        IntPtr.Zero,
                        restartScan);
                    restartScan = false;
                    if (status == StatusNoMoreFiles)
                    {
                        return;
                    }
                    if (status != 0)
                    {
                        uint dosError = RtlNtStatusToDosError(status);
                        throw new Win32Exception(
                            checked((int)dosError),
                            "Unable to enumerate the verified directory handle.");
                    }

                    int returnedLength = checked((int)ioStatusBlock.Information.ToUInt64());
                    int offset = 0;
                    while (offset < returnedLength)
                    {
                        int nameLength = Marshal.ReadInt32(buffer, offset + 8);
                        if (nameLength < 0 || (nameLength & 1) != 0 || offset + 12 + nameLength > returnedLength)
                        {
                            throw new IOException("The verified directory enumeration returned an invalid record.");
                        }
                        string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 12), nameLength / 2);
                        if (!string.Equals(name, ".", StringComparison.Ordinal) &&
                            !string.Equals(name, "..", StringComparison.Ordinal))
                        {
                            throw new IOException("The verified directory is not empty.");
                        }
                        int nextOffset = Marshal.ReadInt32(buffer, offset);
                        if (nextOffset == 0)
                        {
                            break;
                        }
                        if (nextOffset < 12 || offset + nextOffset > returnedLength)
                        {
                            throw new IOException("The verified directory enumeration returned an invalid offset.");
                        }
                        offset += nextOffset;
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
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

        private string ValidateSiblingDirectoryPath(string targetPath, string parameterName)
        {
            if (targetPath == null)
            {
                throw new ArgumentNullException(parameterName);
            }

            string lexicalTarget = Path.GetFullPath(targetPath);
            string sourceParent = TrimDirectoryEnding(Path.GetDirectoryName(DirectoryPath));
            string targetParent = TrimDirectoryEnding(Path.GetDirectoryName(lexicalTarget));
            if (!string.Equals(sourceParent, targetParent, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(DirectoryPath, lexicalTarget, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The quarantine directory must be a distinct sibling of the guarded directory.");
            }

            string leaf = Path.GetFileName(lexicalTarget);
            if (string.IsNullOrWhiteSpace(leaf) || leaf == "." || leaf == ".." ||
                leaf.Length > 255 || leaf.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                leaf.EndsWith(" ", StringComparison.Ordinal) || leaf.EndsWith(".", StringComparison.Ordinal) ||
                IsReservedDeviceLeaf(leaf))
            {
                throw new IOException("The quarantine directory name is an invalid or reserved Windows leaf.");
            }
            if (Directory.Exists(lexicalTarget) || File.Exists(lexicalTarget))
            {
                throw new IOException("The quarantine target already exists.");
            }
            return lexicalTarget;
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
            if (fileInformation.NumberOfLinks != 1)
            {
                throw new IOException("The guarded file is a hard link.");
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

        internal static string[] GetFileIdentity(SafeFileHandle handle)
        {
            ByHandleFileInformation fileInformation;
            if (!GetFileInformationByHandle(handle, out fileInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return new[]
            {
                fileInformation.VolumeSerialNumber.ToString("x8"),
                fileInformation.FileIndexHigh.ToString("x8") +
                    fileInformation.FileIndexLow.ToString("x8")
            };
        }

        internal static bool VerifyAclTargetHandle(SafeFileHandle handle, string expectedPath)
        {
            ByHandleFileInformation fileInformation;
            if (!GetFileInformationByHandle(handle, out fileInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if ((fileInformation.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                throw new IOException("The guarded ACL target is a reparse point.");
            }

            bool isDirectory = (fileInformation.FileAttributes & FileAttributeDirectory) != 0;
            if (!isDirectory && fileInformation.NumberOfLinks != 1)
            {
                throw new IOException("The guarded ACL target is a hard link.");
            }

            string finalPath = HandleBoundFileReader.NormalizeFinalPath(
                HandleBoundFileReader.GetFinalPath(handle));
            if (!string.Equals(
                TrimDirectoryEnding(Path.GetFullPath(expectedPath)),
                TrimDirectoryEnding(Path.GetFullPath(finalPath)),
                StringComparison.OrdinalIgnoreCase))
            {
                throw new HandlePathMismatchException(expectedPath, finalPath);
            }
            return isDirectory;
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

    public sealed class GuardedAclTargetLease : IDisposable
    {
        private const uint SeFileObject = 1;
        private const uint OwnerSecurityInformation = 0x00000001;
        private const uint GroupSecurityInformation = 0x00000002;
        private const uint DaclSecurityInformation = 0x00000004;
        private const uint ProtectedDaclSecurityInformation = 0x80000000;
        private const uint UnprotectedDaclSecurityInformation = 0x20000000;
        private const uint SddlRevision1 = 1;
        private const ushort SeDaclProtected = 0x1000;

        private readonly VerifiedDirectoryChainGuard owner;
        private readonly SafeFileHandle handle;
        private bool disposed;

        internal GuardedAclTargetLease(
            VerifiedDirectoryChainGuard owner,
            string originalPath,
            SafeFileHandle handle,
            bool isDirectory,
            string volumeSerialNumber,
            string fileIndex,
            string securityDescriptorSddl)
        {
            this.owner = owner;
            OriginalPath = originalPath;
            this.handle = handle;
            IsDirectory = isDirectory;
            VolumeSerialNumber = volumeSerialNumber;
            FileIndex = fileIndex;
            SecurityDescriptorSddl = securityDescriptorSddl;
        }

        public string OriginalPath { get; }
        public bool IsDirectory { get; }
        public string VolumeSerialNumber { get; }
        public string FileIndex { get; }

        public string SecurityDescriptorSddl { get; }

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern uint GetSecurityInfo(
            SafeFileHandle handle,
            uint objectType,
            uint securityInformation,
            out IntPtr ownerSid,
            out IntPtr groupSid,
            out IntPtr dacl,
            out IntPtr sacl,
            out IntPtr securityDescriptor);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern uint SetSecurityInfo(
            SafeFileHandle handle,
            uint objectType,
            uint securityInformation,
            IntPtr ownerSid,
            IntPtr groupSid,
            IntPtr dacl,
            IntPtr sacl);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
            IntPtr securityDescriptor,
            uint requestedStringSdRevision,
            uint securityInformation,
            out IntPtr stringSecurityDescriptor,
            out uint stringSecurityDescriptorLength);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
            string stringSecurityDescriptor,
            uint stringSdRevision,
            out IntPtr securityDescriptor,
            out uint securityDescriptorSize);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorOwner(IntPtr securityDescriptor, out IntPtr ownerSid, [MarshalAs(UnmanagedType.Bool)] out bool ownerDefaulted);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorGroup(IntPtr securityDescriptor, out IntPtr groupSid, [MarshalAs(UnmanagedType.Bool)] out bool groupDefaulted);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorDacl(IntPtr securityDescriptor, [MarshalAs(UnmanagedType.Bool)] out bool daclPresent, out IntPtr dacl, [MarshalAs(UnmanagedType.Bool)] out bool daclDefaulted);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorControl(IntPtr securityDescriptor, out ushort control, out uint revision);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr memory);

        public string GetSecurityDescriptorSddl()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            VerifiedDirectoryChainGuard.VerifyAclTargetHandle(handle, OriginalPath);
            uint sections = OwnerSecurityInformation | GroupSecurityInformation | DaclSecurityInformation;
            IntPtr ownerSid;
            IntPtr groupSid;
            IntPtr dacl;
            IntPtr sacl;
            IntPtr descriptor;
            uint error = GetSecurityInfo(handle, SeFileObject, sections, out ownerSid, out groupSid, out dacl, out sacl, out descriptor);
            if (error != 0)
            {
                throw new Win32Exception(checked((int)error), "Unable to read the guarded ACL target security descriptor.");
            }
            try
            {
                IntPtr sddl;
                uint sddlLength;
                if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor, SddlRevision1, sections, out sddl, out sddlLength))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                try
                {
                    return Marshal.PtrToStringUni(sddl);
                }
                finally
                {
                    LocalFree(sddl);
                }
            }
            finally
            {
                LocalFree(descriptor);
            }
        }

        internal static string GetSecurityDescriptorSddlForHandle(SafeFileHandle targetHandle, string originalPath)
        {
            VerifiedDirectoryChainGuard.VerifyAclTargetHandle(targetHandle, originalPath);
            uint sections = OwnerSecurityInformation | GroupSecurityInformation | DaclSecurityInformation;
            IntPtr ownerSid;
            IntPtr groupSid;
            IntPtr dacl;
            IntPtr sacl;
            IntPtr descriptor;
            uint error = GetSecurityInfo(targetHandle, SeFileObject, sections, out ownerSid, out groupSid, out dacl, out sacl, out descriptor);
            if (error != 0)
            {
                throw new Win32Exception(checked((int)error), "Unable to read the guarded ACL target security descriptor.");
            }
            try
            {
                IntPtr sddl;
                uint sddlLength;
                if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor, SddlRevision1, sections, out sddl, out sddlLength))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                try { return Marshal.PtrToStringUni(sddl); }
                finally { LocalFree(sddl); }
            }
            finally { LocalFree(descriptor); }
        }

        internal static void SetSecurityDescriptorSddlForHandle(
            SafeFileHandle targetHandle,
            string originalPath,
            string expectedCurrentSddl,
            string sddl)
        {
            if (sddl == null) { throw new ArgumentNullException(nameof(sddl)); }
            VerifiedDirectoryChainGuard.VerifyAclTargetHandle(targetHandle, originalPath);
            string currentSddl = GetSecurityDescriptorSddlForHandle(targetHandle, originalPath);
            if (expectedCurrentSddl != null && !string.Equals(currentSddl, expectedCurrentSddl, StringComparison.Ordinal))
            {
                throw new IOException("The guarded ACL target security descriptor changed before the handle-bound write.");
            }
            RawSecurityDescriptor currentDescriptor = new RawSecurityDescriptor(currentSddl);
            RawSecurityDescriptor desiredDescriptor = new RawSecurityDescriptor(sddl);
            string currentOwner = currentDescriptor.Owner == null ? string.Empty : currentDescriptor.Owner.Value;
            string desiredOwner = desiredDescriptor.Owner == null ? string.Empty : desiredDescriptor.Owner.Value;
            string currentGroup = currentDescriptor.Group == null ? string.Empty : currentDescriptor.Group.Value;
            string desiredGroup = desiredDescriptor.Group == null ? string.Empty : desiredDescriptor.Group.Value;
            if (!string.Equals(currentOwner, desiredOwner, StringComparison.Ordinal) ||
                !string.Equals(currentGroup, desiredGroup, StringComparison.Ordinal))
            {
                throw new IOException("The guarded ACL target owner or group changed outside this lease.");
            }

            IntPtr descriptor;
            uint descriptorSize;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SddlRevision1, out descriptor, out descriptorSize))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try
            {
                IntPtr ownerSid;
                IntPtr groupSid;
                IntPtr dacl;
                bool ownerDefaulted;
                bool groupDefaulted;
                bool daclPresent;
                bool daclDefaulted;
                ushort control;
                uint revision;
                if (!GetSecurityDescriptorOwner(descriptor, out ownerSid, out ownerDefaulted) ||
                    !GetSecurityDescriptorGroup(descriptor, out groupSid, out groupDefaulted) ||
                    !GetSecurityDescriptorDacl(descriptor, out daclPresent, out dacl, out daclDefaulted) ||
                    !GetSecurityDescriptorControl(descriptor, out control, out revision))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                uint sections = DaclSecurityInformation;
                if ((control & SeDaclProtected) != 0) { sections |= ProtectedDaclSecurityInformation; }
                else { sections |= UnprotectedDaclSecurityInformation; }
                uint error = SetSecurityInfo(targetHandle, SeFileObject, sections, ownerSid, groupSid, daclPresent ? dacl : IntPtr.Zero, IntPtr.Zero);
                if (error != 0) { throw new Win32Exception(checked((int)error), "Unable to write the guarded ACL target security descriptor."); }
            }
            finally { LocalFree(descriptor); }

            if (!string.Equals(GetSecurityDescriptorSddlForHandle(targetHandle, originalPath), sddl, StringComparison.Ordinal))
            {
                throw new IOException("The guarded ACL target security descriptor changed after the handle-bound write.");
            }
        }

        public void SetSecurityDescriptorSddl(string sddl)
        {
            SetSecurityDescriptorSddl(null, sddl);
        }

        public void SetSecurityDescriptorSddl(string expectedCurrentSddl, string sddl)
        {
            if (sddl == null)
            {
                throw new ArgumentNullException(nameof(sddl));
            }
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            VerifiedDirectoryChainGuard.VerifyAclTargetHandle(handle, OriginalPath);

            string currentSddl = GetSecurityDescriptorSddl();
            if (expectedCurrentSddl != null && !string.Equals(currentSddl, expectedCurrentSddl, StringComparison.Ordinal))
            {
                throw new IOException("The guarded ACL target security descriptor changed before the handle-bound write.");
            }
            RawSecurityDescriptor currentDescriptor = new RawSecurityDescriptor(currentSddl);
            RawSecurityDescriptor desiredDescriptor = new RawSecurityDescriptor(sddl);
            string currentOwner = currentDescriptor.Owner == null ? string.Empty : currentDescriptor.Owner.Value;
            string desiredOwner = desiredDescriptor.Owner == null ? string.Empty : desiredDescriptor.Owner.Value;
            string currentGroup = currentDescriptor.Group == null ? string.Empty : currentDescriptor.Group.Value;
            string desiredGroup = desiredDescriptor.Group == null ? string.Empty : desiredDescriptor.Group.Value;
            if (!string.Equals(currentOwner, desiredOwner, StringComparison.Ordinal) ||
                !string.Equals(currentGroup, desiredGroup, StringComparison.Ordinal))
            {
                throw new IOException("The guarded ACL target owner or group changed outside this lease.");
            }

            IntPtr descriptor;
            uint descriptorSize;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SddlRevision1, out descriptor, out descriptorSize))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try
            {
                IntPtr ownerSid;
                IntPtr groupSid;
                IntPtr dacl;
                bool ownerDefaulted;
                bool groupDefaulted;
                bool daclPresent;
                bool daclDefaulted;
                ushort control;
                uint revision;
                if (!GetSecurityDescriptorOwner(descriptor, out ownerSid, out ownerDefaulted) ||
                    !GetSecurityDescriptorGroup(descriptor, out groupSid, out groupDefaulted) ||
                    !GetSecurityDescriptorDacl(descriptor, out daclPresent, out dacl, out daclDefaulted) ||
                    !GetSecurityDescriptorControl(descriptor, out control, out revision))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (!daclPresent)
                {
                    throw new IOException("The guarded ACL target SDDL has no DACL.");
                }
                uint sections = DaclSecurityInformation;
                sections |= (control & SeDaclProtected) != 0
                    ? ProtectedDaclSecurityInformation
                    : UnprotectedDaclSecurityInformation;
                uint error = SetSecurityInfo(handle, SeFileObject, sections, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
                if (error != 0)
                {
                    throw new Win32Exception(checked((int)error), "Unable to write the guarded ACL target security descriptor.");
                }
                VerifiedDirectoryChainGuard.VerifyAclTargetHandle(handle, OriginalPath);
            }
            finally
            {
                LocalFree(descriptor);
            }
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            handle.Dispose();
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException(nameof(GuardedAclTargetLease));
            }
        }
    }

    public sealed class GuardedReadOnlyFileLease : IDisposable
    {
        private readonly VerifiedDirectoryChainGuard owner;
        private readonly SafeFileHandle handle;
        private readonly FileStream stream;
        private readonly byte[] snapshotBytes;
        private bool disposed;

        internal GuardedReadOnlyFileLease(
            VerifiedDirectoryChainGuard owner,
            string originalPath,
            SafeFileHandle handle,
            string volumeSerialNumber,
            string fileIndex)
        {
            this.owner = owner;
            OriginalPath = originalPath;
            this.handle = handle;
            VolumeSerialNumber = volumeSerialNumber;
            FileIndex = fileIndex;
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

        public string VolumeSerialNumber { get; }

        public string FileIndex { get; }

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
            VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, OriginalPath);
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
                throw new ObjectDisposedException(nameof(GuardedReadOnlyFileLease));
            }
        }
    }

    public sealed class GuardedTargetFileLease : IDisposable
    {
        private const int FileDispositionInformationEx = 64;
        private const uint FileDispositionDelete = 0x00000001;
        private const uint FileDispositionPosixSemantics = 0x00000002;
        private const uint FileDispositionIgnoreReadonlyAttribute = 0x00000010;

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

        public string VolumeSerialNumber
        {
            get
            {
                ThrowIfDisposed();
                return VerifiedDirectoryChainGuard.GetFileIdentity(handle)[0];
            }
        }

        public string FileIndex
        {
            get
            {
                ThrowIfDisposed();
                return VerifiedDirectoryChainGuard.GetFileIdentity(handle)[1];
            }
        }

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

        public void DeleteWithPosixSemantics()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, OriginalPath);
            IntPtr buffer = Marshal.AllocHGlobal(sizeof(uint));
            try
            {
                Marshal.WriteInt32(
                    buffer,
                    unchecked((int)(
                        FileDispositionDelete
                        | FileDispositionPosixSemantics
                        | FileDispositionIgnoreReadonlyAttribute)));
                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(
                    handle,
                    out ioStatusBlock,
                    buffer,
                    sizeof(uint),
                    FileDispositionInformationEx);
                if (status != 0)
                {
                    uint dosError = RtlNtStatusToDosError(status);
                    throw new Win32Exception(checked((int)dosError), "Unable to delete a guarded target file.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
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
        private const int FileDispositionInformationEx = 64;
        private const uint FileRenameReplaceIfExists = 0x00000001;
        private const uint FileRenamePosixSemantics = 0x00000002;
        private const uint FileDispositionDelete = 0x00000001;
        private const uint FileDispositionPosixSemantics = 0x00000002;

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
            SafeFileHandle handle,
            bool alreadyFlushed)
        {
            this.owner = owner;
            this.currentPath = currentPath;
            this.handle = handle;
            stream = new FileStream(handle, FileAccess.ReadWrite);
            flushed = alreadyFlushed;
        }

        public string CurrentPath { get { return currentPath; } }

        public string VolumeSerialNumber
        {
            get
            {
                ThrowIfDisposed();
                return VerifiedDirectoryChainGuard.GetFileIdentity(handle)[0];
            }
        }

        public string FileIndex
        {
            get
            {
                ThrowIfDisposed();
                return VerifiedDirectoryChainGuard.GetFileIdentity(handle)[1];
            }
        }

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

        public byte[] ReadAllBytesFromHandle()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            if (!stream.CanRead)
            {
                throw new InvalidOperationException("The guarded temporary file is not readable.");
            }
            stream.Position = 0;
            using (MemoryStream copy = new MemoryStream())
            {
                stream.CopyTo(copy);
                return copy.ToArray();
            }
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

        public string GetSecurityDescriptorSddl()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            return GuardedAclTargetLease.GetSecurityDescriptorSddlForHandle(handle, currentPath);
        }

        public void SetSecurityDescriptorSddl(string expectedCurrentSddl, string sddl)
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            GuardedAclTargetLease.SetSecurityDescriptorSddlForHandle(handle, currentPath, expectedCurrentSddl, sddl);
        }

        public void DeleteWithPosixSemantics()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            if (renamed)
            {
                throw new InvalidOperationException("The guarded temporary file was already renamed or deleted.");
            }
            VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, currentPath);
            IntPtr buffer = Marshal.AllocHGlobal(sizeof(uint));
            try
            {
                Marshal.WriteInt32(buffer, unchecked((int)(FileDispositionDelete | FileDispositionPosixSemantics)));
                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(handle, out ioStatusBlock, buffer, sizeof(uint), FileDispositionInformationEx);
                if (status != 0)
                {
                    uint dosError = RtlNtStatusToDosError(status);
                    throw new Win32Exception(checked((int)dosError), "Unable to delete a guarded temporary file.");
                }
                renamed = true;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
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
