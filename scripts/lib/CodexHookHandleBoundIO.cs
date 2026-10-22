using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
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
        private const uint FileNameOpened = 0x8;

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
            return GetFinalPath(handle, FileNameNormalized);
        }

        internal static string GetOpenedFinalPath(SafeFileHandle handle)
        {
            return GetFinalPath(handle, FileNameOpened);
        }

        private static string GetFinalPath(SafeFileHandle handle, uint flags)
        {
            uint capacity = 512;
            while (true)
            {
                StringBuilder buffer = new StringBuilder(checked((int)capacity));
                uint result = GetFinalPathNameByHandleW(handle, buffer, capacity, flags);
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

    // #56 §4.1：directory guard 同句柄 stream-set 捕获的返回 DTO。assembly-internal，
    // 自包含（string[] + link 计数），不公开 SafeFileHandle。
    internal sealed class SafeTreeDeleteDirectoryStreamSet
    {
        internal SafeTreeDeleteDirectoryStreamSet(string[] streamNames, uint numberOfLinks)
        {
            StreamNames = streamNames;
            NumberOfLinks = numberOfLinks;
        }

        internal string[] StreamNames { get; private set; }

        internal uint NumberOfLinks { get; private set; }
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
        private const int ErrorAccessDenied = 5;
        private const int ErrorHandleEof = 38;
        private const int ErrorAlreadyExists = 183;
        private const int ErrorMoreData = 234;
        private const int FileDispositionInformation = 13;
        private const int FileDispositionInformationEx = 64;
        private const int FileRenameInformationEx = 65;
        private const int FileNamesInformation = 12;
        private const int FileStreamInfo = 7;
        private const uint FsctlGetReparsePoint = 0x000900A8;
        private const uint IoReparseTagMountPoint = 0xA0000003;
        private const uint FileDispositionDelete = 0x00000001;
        private const uint FileDispositionPosixSemantics = 0x00000002;
        private const uint FileDispositionIgnoreReadonlyAttribute = 0x00000010;
        private const int AlternateDataStreamWriteMask = 0x00000116;
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

        public void DeleteEmptyDirectoryRejectingAlternateDataStreams()
        {
            DeleteEmptyDirectoryRejectingAlternateDataStreams(
                delegate { },
                delegate { },
                delegate { },
                delegate(string ignored) { },
                null);
        }

        public void DeleteEmptyDirectoryRejectingAlternateDataStreams(
            Action<string, string> publishFreezeIntent,
            Action<string> publishCommitIntent,
            Action anchorCommitIntent,
            Action<string> publishAbortIntent,
            Action<string> checkpointForTest)
        {
            if (publishFreezeIntent == null)
            {
                throw new ArgumentNullException(nameof(publishFreezeIntent));
            }
            if (publishCommitIntent == null)
            {
                throw new ArgumentNullException(nameof(publishCommitIntent));
            }
            if (anchorCommitIntent == null)
            {
                throw new ArgumentNullException(nameof(anchorCommitIntent));
            }
            if (publishAbortIntent == null)
            {
                throw new ArgumentNullException(nameof(publishAbortIntent));
            }
            DeleteEmptyDirectoryRejectingAlternateDataStreamsCore(
                publishFreezeIntent,
                publishCommitIntent,
                anchorCommitIntent,
                publishAbortIntent,
                checkpointForTest,
                null,
                null);
        }

        public void ResumeEmptyDirectoryRejectingAlternateDataStreams(
            string originalSddl,
            string frozenSddl,
            Action<string> publishCommitIntent,
            Action anchorCommitIntent,
            Action<string> publishAbortIntent,
            Action<string> checkpointForTest)
        {
            if (originalSddl == null) { throw new ArgumentNullException(nameof(originalSddl)); }
            if (frozenSddl == null) { throw new ArgumentNullException(nameof(frozenSddl)); }
            if (publishCommitIntent == null) { throw new ArgumentNullException(nameof(publishCommitIntent)); }
            if (anchorCommitIntent == null) { throw new ArgumentNullException(nameof(anchorCommitIntent)); }
            if (publishAbortIntent == null) { throw new ArgumentNullException(nameof(publishAbortIntent)); }
            DeleteEmptyDirectoryRejectingAlternateDataStreamsCore(
                null,
                publishCommitIntent,
                anchorCommitIntent,
                publishAbortIntent,
                checkpointForTest,
                originalSddl,
                frozenSddl);
        }

        private void DeleteEmptyDirectoryRejectingAlternateDataStreamsCore(
            Action<string, string> publishFreezeIntent,
            Action<string> publishCommitIntent,
            Action anchorCommitIntent,
            Action<string> publishAbortIntent,
            Action<string> checkpointForTest,
            string preparedOriginalSddl,
            string preparedFrozenSddl)
        {
            ThrowIfDisposed();
            SafeFileHandle directoryHandle = handles[handles.Count - 1];
            VerifyDirectoryHandle(directoryHandle, DirectoryPath);
            AssertDirectoryEmpty(directoryHandle);
            string currentSddl = GuardedAclTargetLease.GetSecurityDescriptorSddlForHandle(
                directoryHandle,
                DirectoryPath);
            bool resumingPreparedFreeze = preparedOriginalSddl != null;
            bool preparedFreezeAlreadyApplied = false;
            string originalSddl;
            string frozenSddl;
            if (resumingPreparedFreeze)
            {
                originalSddl = preparedOriginalSddl;
                frozenSddl = preparedFrozenSddl;
                preparedFreezeAlreadyApplied = IsValidAlternateDataStreamWriteFreeze(
                    originalSddl,
                    frozenSddl,
                    currentSddl);
                if (!preparedFreezeAlreadyApplied &&
                    !SecurityDescriptorsHaveEquivalentDacl(originalSddl, currentSddl))
                {
                    throw new IOException(
                        "The prepared directory write freeze no longer matches the current DACL.");
                }
            }
            else
            {
                originalSddl = currentSddl;
                frozenSddl = AddAlternateDataStreamWriteFreeze(originalSddl);
                publishFreezeIntent(originalSddl, frozenSddl);
                if (checkpointForTest != null)
                {
                    checkpointForTest("before-stream-freeze");
                }
            }

            bool aclChanged = resumingPreparedFreeze
                ? !preparedFreezeAlreadyApplied
                : !string.Equals(originalSddl, frozenSddl, StringComparison.Ordinal);
            string appliedFrozenSddl = currentSddl;
            bool deletePending = false;
            bool commitAuthorized = false;
            bool commitPublicationStarted = false;
            try
            {
                if (aclChanged)
                {
                    appliedFrozenSddl = GuardedAclTargetLease.SetSecurityDescriptorSddlForHandleAndReadBack(
                        directoryHandle,
                        DirectoryPath,
                        currentSddl,
                        frozenSddl);
                }
                AssertAlternateDataStreamWriteFreeze(directoryHandle);
                if (checkpointForTest != null)
                {
                    checkpointForTest("after-stream-freeze");
                }
                AssertDirectoryEmpty(directoryHandle);
                AssertNoAlternateDataStreams(directoryHandle);
                AssertAlternateDataStreamWriteFreeze(directoryHandle);
                AssertDirectoryEmpty(directoryHandle);
                AssertNoAlternateDataStreams(directoryHandle);
                commitPublicationStarted = true;
                publishCommitIntent(appliedFrozenSddl);
                anchorCommitIntent();
                commitAuthorized = true;
                if (checkpointForTest != null)
                {
                    checkpointForTest("after-commit-intent");
                }
                SetDirectoryDeletePending(directoryHandle, true);
                deletePending = true;
                if (checkpointForTest != null)
                {
                    checkpointForTest("after-delete-pending");
                }
            }
            catch (Exception operationException)
            {
                if (!commitAuthorized && !commitPublicationStarted)
                {
                    List<Exception> recoveryExceptions = new List<Exception>();
                    string restoredSddl = originalSddl;
                    try
                    {
                        if (deletePending)
                        {
                            SetDirectoryDeletePending(directoryHandle, false);
                        }
                        if (aclChanged || resumingPreparedFreeze)
                        {
                            restoredSddl = GuardedAclTargetLease.SetSecurityDescriptorSddlForHandleAndReadBack(
                                directoryHandle,
                                DirectoryPath,
                                appliedFrozenSddl,
                                originalSddl);
                        }
                        if (!SecurityDescriptorsHaveEquivalentDacl(originalSddl, restoredSddl))
                        {
                            throw new IOException(
                                "The guarded directory DACL was not restored to its original effective state.");
                        }
                    }
                    catch (Exception exception)
                    {
                        recoveryExceptions.Add(exception);
                    }
                    if (recoveryExceptions.Count == 0)
                    {
                        try
                        {
                            publishAbortIntent(restoredSddl);
                        }
                        catch (Exception exception)
                        {
                            recoveryExceptions.Add(exception);
                        }
                    }
                    if (recoveryExceptions.Count != 0)
                    {
                        recoveryExceptions.Insert(0, operationException);
                        throw new AggregateException(
                            "Unable to roll back and journal the guarded directory write freeze.",
                            recoveryExceptions);
                    }
                }
                throw;
            }

            disposed = true;
            DisposeHandles(handles);
            if (Directory.Exists(DirectoryPath))
            {
                throw new IOException("The verified stream-free directory path still exists after handle-bound deletion.");
            }
        }

        public void DeleteEmptyDirectoryWithAuthorizedAlternateDataStreamCommit(
            string originalSddl,
            string requestedFrozenSddl,
            string appliedFrozenSddl,
            Action<string> checkpointForTest)
        {
            if (originalSddl == null) { throw new ArgumentNullException(nameof(originalSddl)); }
            if (requestedFrozenSddl == null) { throw new ArgumentNullException(nameof(requestedFrozenSddl)); }
            if (appliedFrozenSddl == null) { throw new ArgumentNullException(nameof(appliedFrozenSddl)); }
            ThrowIfDisposed();
            SafeFileHandle directoryHandle = handles[handles.Count - 1];
            VerifyDirectoryHandle(directoryHandle, DirectoryPath);
            AssertDirectoryEmpty(directoryHandle);
            string currentSddl = GuardedAclTargetLease.GetSecurityDescriptorSddlForHandle(
                directoryHandle,
                DirectoryPath);
            if (!IsValidAlternateDataStreamWriteFreeze(
                    originalSddl,
                    requestedFrozenSddl,
                    appliedFrozenSddl) ||
                !SecurityDescriptorsHaveEquivalentDacl(appliedFrozenSddl, currentSddl))
            {
                throw new IOException(
                    "The authorized directory write freeze no longer matches the current DACL.");
            }
            AssertAlternateDataStreamWriteFreeze(directoryHandle);
            AssertDirectoryEmpty(directoryHandle);
            AssertNoAlternateDataStreams(directoryHandle);
            AssertAlternateDataStreamWriteFreeze(directoryHandle);
            AssertDirectoryEmpty(directoryHandle);
            AssertNoAlternateDataStreams(directoryHandle);
            SetDirectoryDeletePending(directoryHandle, true);
            if (checkpointForTest != null)
            {
                checkpointForTest("after-delete-pending");
            }
            disposed = true;
            DisposeHandles(handles);
            if (Directory.Exists(DirectoryPath))
            {
                throw new IOException(
                    "The authorized stream-free directory path still exists after handle-bound deletion.");
            }
        }

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
                ToExtendedPath(lexicalPath),
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

        public SafeTreeDeleteFileLease AcquireSafeTreeDeleteFileLease(
            string targetPath,
            bool allowHardLinks)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(targetPath, "targetPath");
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(lexicalPath),
                GenericRead | FileWriteAttributes | DeleteAccess,
                // This dedicated destructive lease intentionally refuses
                // share-write and share-delete for its full lifetime.
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
                    "Unable to acquire a safe-tree-delete file lease.");
            }

            try
            {
                uint numberOfLinks = VerifySafeTreeDeleteFileHandle(
                    handle,
                    lexicalPath,
                    allowHardLinks);
                string[] identity = GetFileIdentity(handle);
                return new SafeTreeDeleteFileLease(
                    this,
                    lexicalPath,
                    handle,
                    allowHardLinks,
                    identity[0],
                    identity[1],
                    numberOfLinks);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public SafeTreeDeleteReparseLeafLease AcquireSafeTreeDeleteReparseLeafLease(
            string targetPath)
        {
            ThrowIfDisposed();
            string lexicalPath = ValidateChildPath(targetPath, "targetPath");
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(lexicalPath),
                GenericRead | FileWriteAttributes | DeleteAccess,
                // Opening the reparse point itself and refusing write/delete
                // sharing makes the captured junction payload immutable.
                FileShare.Read,
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
                    "Unable to acquire a safe-tree-delete reparse-leaf lease.");
            }

            try
            {
                uint reparseTag;
                string targetPathFromReparseData;
                byte[] reparseData;
                VerifySafeTreeDeleteMountPointHandle(
                    handle,
                    lexicalPath,
                    out reparseTag,
                    out targetPathFromReparseData,
                    out reparseData);
                string[] identity = GetFileIdentity(handle);
                using (SHA256 sha256 = SHA256.Create())
                {
                    return new SafeTreeDeleteReparseLeafLease(
                        this,
                        lexicalPath,
                        handle,
                        identity[0],
                        identity[1],
                        reparseTag,
                        targetPathFromReparseData,
                        reparseData,
                        sha256.ComputeHash(reparseData));
                }
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
                GenericRead | ReadControl | WriteDac | DeleteAccess,
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
                ToExtendedPath(lexicalPath),
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
                ToExtendedPath(lexicalPath),
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
        private static extern bool DeleteFileW(string fileName);

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

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle fileHandle,
            int fileInformationClass,
            IntPtr fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint ioControlCode,
            IntPtr inputBuffer,
            uint inputBufferSize,
            IntPtr outputBuffer,
            uint outputBufferSize,
            out uint bytesReturned,
            IntPtr overlapped);

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
                OpenAndHoldVerifiedDirectory(current, rootPath, openedHandles);

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
                    if (TryOpenVerifiedDirectory(current, requireDeleteAccess: isTarget && targetDeleteAccess, shareWrite: !isTarget, out handle, out error))
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
                            throw CreateChainOpenException(error, current, rootPath, "Unable to open a verified directory in the path chain");
                        }

                        if (!CreateDirectoryW(ToExtendedPath(current), IntPtr.Zero))
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

                        if (!TryOpenVerifiedDirectory(current, requireDeleteAccess: isTarget && targetDeleteAccess, shareWrite: !isTarget, out handle, out error))
                        {
                            throw CreateChainOpenException(error, current, rootPath, "Unable to verify a newly created directory in the path chain");
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
            string trustedRootPath,
            List<SafeFileHandle> openedHandles)
        {
            SafeFileHandle handle;
            int error;
            if (!TryOpenVerifiedDirectory(path, requireDeleteAccess: false, shareWrite: true, out handle, out error))
            {
                throw CreateChainOpenException(error, path, trustedRootPath, "Unable to open a verified directory in the path chain");
            }
            openedHandles.Add(handle);
        }

        private static Win32Exception CreateChainOpenException(
            int error,
            string failedPath,
            string trustedRootPath,
            string operation)
        {
            return new Win32Exception(
                error,
                operation +
                " at '" + TrimDirectoryEnding(Path.GetFullPath(failedPath)) +
                "' (" + DescribeChainFailureLevel(failedPath, trustedRootPath) +
                ", Win32 error " + error + ").");
        }

        private static string DescribeChainFailureLevel(string failedPath, string trustedRootPath)
        {
            string failed = TrimDirectoryEnding(Path.GetFullPath(failedPath));
            string root = TrimDirectoryEnding(Path.GetFullPath(trustedRootPath));
            if (string.Equals(failed, root, StringComparison.OrdinalIgnoreCase))
            {
                return "relative path '.' below the trusted root '" + root + "'";
            }

            string rootPrefix = WithTrailingSeparator(root);
            if (failed.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
            {
                return "relative path '" + failed.Substring(rootPrefix.Length) +
                    "' below the trusted root '" + root + "'";
            }

            string failedPrefix = WithTrailingSeparator(failed);
            if (root.StartsWith(failedPrefix, StringComparison.OrdinalIgnoreCase))
            {
                int levels = root.Substring(failedPrefix.Length).Split(
                    new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                    StringSplitOptions.RemoveEmptyEntries).Length;
                return levels + (levels == 1 ? " level above" : " levels above") +
                    " the trusted root '" + root + "'";
            }

            return "outside the trusted root '" + root + "'";
        }

        private static string WithTrailingSeparator(string path)
        {
            return path.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal)
                ? path
                : path + Path.DirectorySeparatorChar;
        }

        private static bool TryOpenVerifiedDirectory(
            string expectedPath,
            bool requireDeleteAccess,
            bool shareWrite,
            out SafeFileHandle handle,
            out int error)
        {
            string lexicalPath = Path.GetFullPath(expectedPath);
            handle = CreateFileW(
                ToExtendedPath(lexicalPath),
                GenericRead | (requireDeleteAccess ? ReadControl | WriteDac | DeleteAccess : 0),
                shareWrite ? (FileShare.Read | FileShare.Write) : FileShare.Read,
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

        private static void AssertNoAlternateDataStreams(SafeFileHandle handle)
        {
            const int bufferLength = 4096;
            IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
            try
            {
                if (GetFileInformationByHandleEx(
                    handle,
                    FileStreamInfo,
                    buffer,
                    bufferLength))
                {
                    throw new IOException("The verified directory contains an NTFS alternate data stream.");
                }
                int error = Marshal.GetLastWin32Error();
                if (error != ErrorHandleEof)
                {
                    throw new Win32Exception(error, "Unable to enumerate streams for the verified directory handle.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        // #56 §4.1：directory guard 同句柄 stream-set 捕获 seam。实现顺序固定：
        // ThrowIfDisposed → VerifyDirectoryHandle → 前置 identity/link → 同句柄流枚举
        // （ordinal 排序、重名拒绝）→ 后置 identity/link → 与 guard identity/前置 link 对比；
        // 任一漂移 throw。自包含 FILE_STREAM_INFORMATION 解析，不依赖
        // CodexSafeTreeDeleteFileIdentity.cs。
        internal SafeTreeDeleteDirectoryStreamSet CaptureSafeTreeDeleteDirectoryStreamSet()
        {
            ThrowIfDisposed();
            SafeFileHandle directoryHandle = handles[handles.Count - 1];
            VerifyDirectoryHandle(directoryHandle, DirectoryPath);

            ByHandleFileInformation preInformation;
            if (!GetFileInformationByHandle(directoryHandle, out preInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            string[] preIdentity = ReadFileIdentity(directoryHandle);

            string[] streamNames = ReadDirectoryStreamNames(directoryHandle);

            ByHandleFileInformation postInformation;
            if (!GetFileInformationByHandle(directoryHandle, out postInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            string[] postIdentity = ReadFileIdentity(directoryHandle);

            if (!string.Equals(preIdentity[0], postIdentity[0], StringComparison.Ordinal) ||
                !string.Equals(preIdentity[1], postIdentity[1], StringComparison.Ordinal))
            {
                throw new IOException(
                    "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: directory stream-set capture identity.");
            }
            if (preInformation.NumberOfLinks != postInformation.NumberOfLinks)
            {
                throw new IOException(
                    "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: directory stream-set capture link count.");
            }
            if (!string.Equals(preIdentity[0], VolumeSerialNumber, StringComparison.Ordinal) ||
                !string.Equals(preIdentity[1], FileIndex, StringComparison.Ordinal))
            {
                throw new IOException(
                    "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: directory stream-set capture guard identity.");
            }
            return new SafeTreeDeleteDirectoryStreamSet(streamNames, preInformation.NumberOfLinks);
        }

        private static string[] ReadDirectoryStreamNames(SafeFileHandle handle)
        {
            const int StreamHeaderLength = 24;
            int bufferLength = 4096;
            while (true)
            {
                IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
                try
                {
                    for (int index = 0; index < bufferLength; index++)
                    {
                        Marshal.WriteByte(buffer, index, 0);
                    }

                    if (!GetFileInformationByHandleEx(
                        handle,
                        FileStreamInfo,
                        buffer,
                        checked((uint)bufferLength)))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == ErrorHandleEof)
                        {
                            return new string[0];
                        }
                        if (error == ErrorMoreData && bufferLength < 1024 * 1024)
                        {
                            bufferLength = checked(bufferLength * 2);
                            continue;
                        }
                        throw new Win32Exception(
                            error,
                            "Unable to enumerate streams for the directory stream-set handle.");
                    }

                    List<string> names = new List<string>();
                    int offset = 0;
                    while (true)
                    {
                        if (offset < 0 || offset + StreamHeaderLength > bufferLength)
                        {
                            throw new IOException(
                                "The directory stream enumeration returned an invalid record.");
                        }
                        int nextOffset = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 4);
                        if (nameLength < 0 || (nameLength & 1) != 0 ||
                            offset + StreamHeaderLength + nameLength > bufferLength)
                        {
                            throw new IOException(
                                "The directory stream enumeration returned an invalid name.");
                        }
                        names.Add(Marshal.PtrToStringUni(
                            IntPtr.Add(buffer, offset + StreamHeaderLength),
                            nameLength / 2));
                        if (nextOffset == 0)
                        {
                            break;
                        }
                        offset = checked(offset + nextOffset);
                    }

                    names.Sort(StringComparer.Ordinal);
                    for (int index = 1; index < names.Count; index++)
                    {
                        if (string.Equals(names[index - 1], names[index], StringComparison.Ordinal))
                        {
                            throw new IOException(
                                "The directory stream enumeration returned a duplicate stream name.");
                        }
                    }
                    return names.ToArray();
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        private static string AddAlternateDataStreamWriteFreeze(string sddl)
        {
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor(sddl);
            if (descriptor.DiscretionaryAcl == null)
            {
                throw new IOException("The verified directory security descriptor has no DACL.");
            }

            SecurityIdentifier world = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
            if (descriptor.DiscretionaryAcl.Count != 0)
            {
                CommonAce firstAce = descriptor.DiscretionaryAcl[0] as CommonAce;
                if (firstAce != null &&
                    firstAce.AceQualifier == AceQualifier.AccessDenied &&
                    firstAce.SecurityIdentifier.Equals(world) &&
                    (firstAce.AccessMask & AlternateDataStreamWriteMask) == AlternateDataStreamWriteMask &&
                    (firstAce.AceFlags & AceFlags.InheritOnly) == 0)
                {
                    return sddl;
                }
            }

            descriptor.DiscretionaryAcl.InsertAce(
                0,
                new CommonAce(
                    AceFlags.None,
                    AceQualifier.AccessDenied,
                    AlternateDataStreamWriteMask,
                    world,
                    false,
                    null));
            return descriptor.GetSddlForm(
                AccessControlSections.Owner |
                AccessControlSections.Group |
                AccessControlSections.Access);
        }

        public static bool IsValidAlternateDataStreamWriteFreeze(
            string originalSddl,
            string requestedFrozenSddl,
            string appliedFrozenSddl)
        {
            if (originalSddl == null || requestedFrozenSddl == null || appliedFrozenSddl == null)
            {
                return false;
            }
            try
            {
                string expectedFrozenSddl = AddAlternateDataStreamWriteFreeze(originalSddl);
                RawSecurityDescriptor applied = new RawSecurityDescriptor(appliedFrozenSddl);
                if (applied.DiscretionaryAcl == null || applied.DiscretionaryAcl.Count == 0)
                {
                    return false;
                }
                CommonAce firstAce = applied.DiscretionaryAcl[0] as CommonAce;
                SecurityIdentifier world = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
                return firstAce != null &&
                    firstAce.AceQualifier == AceQualifier.AccessDenied &&
                    firstAce.SecurityIdentifier.Equals(world) &&
                    (firstAce.AccessMask & AlternateDataStreamWriteMask) == AlternateDataStreamWriteMask &&
                    (firstAce.AceFlags & AceFlags.InheritOnly) == 0 &&
                    SecurityDescriptorsHaveEquivalentDacl(expectedFrozenSddl, requestedFrozenSddl) &&
                    SecurityDescriptorsHaveEquivalentDacl(requestedFrozenSddl, appliedFrozenSddl);
            }
            catch (ArgumentException)
            {
                return false;
            }
        }

        public static bool SecurityDescriptorsHaveEquivalentDacl(string expectedSddl, string actualSddl)
        {
            if (expectedSddl == null) { throw new ArgumentNullException(nameof(expectedSddl)); }
            if (actualSddl == null) { throw new ArgumentNullException(nameof(actualSddl)); }
            RawSecurityDescriptor expected = new RawSecurityDescriptor(expectedSddl);
            RawSecurityDescriptor actual = new RawSecurityDescriptor(actualSddl);
            if (!Equals(expected.Owner, actual.Owner) ||
                !Equals(expected.Group, actual.Group) ||
                ((expected.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0) !=
                ((actual.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0))
            {
                return false;
            }
            if (expected.DiscretionaryAcl == null || actual.DiscretionaryAcl == null)
            {
                return expected.DiscretionaryAcl == null && actual.DiscretionaryAcl == null;
            }
            if (expected.DiscretionaryAcl.BinaryLength != actual.DiscretionaryAcl.BinaryLength)
            {
                return false;
            }
            byte[] expectedBytes = new byte[expected.DiscretionaryAcl.BinaryLength];
            byte[] actualBytes = new byte[actual.DiscretionaryAcl.BinaryLength];
            expected.DiscretionaryAcl.GetBinaryForm(expectedBytes, 0);
            actual.DiscretionaryAcl.GetBinaryForm(actualBytes, 0);
            return CryptographicOperations.FixedTimeEquals(expectedBytes, actualBytes);
        }

        private static void AssertAlternateDataStreamWriteFreeze(SafeFileHandle handle)
        {
            string directoryPath = DirectoryPathForHandle(handle);
            string sddl = GuardedAclTargetLease.GetSecurityDescriptorSddlForHandle(handle, directoryPath);
            string frozenSddl = AddAlternateDataStreamWriteFreeze(sddl);
            if (!string.Equals(sddl, frozenSddl, StringComparison.Ordinal))
            {
                throw new IOException("The verified directory alternate-data-stream write freeze is missing.");
            }

            string probePath = directoryPath + ":codex-safe-delete-freeze-" + Guid.NewGuid().ToString("N");
            SafeFileHandle probeHandle = CreateFileW(
                ToExtendedPath(probePath),
                GenericWrite,
                FileShare.Read | FileShare.Write | FileShare.Delete,
                IntPtr.Zero,
                CreateNew,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (probeHandle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                probeHandle.Dispose();
                if (error == ErrorAccessDenied)
                {
                    return;
                }
                throw new Win32Exception(
                    error,
                    "The verified directory write freeze did not produce the required access-denied result.");
            }

            probeHandle.Dispose();
            if (!DeleteFileW(ToExtendedPath(probePath)))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The ineffective write-freeze probe created an alternate data stream that could not be removed.");
            }
            throw new IOException("The verified directory alternate-data-stream write freeze is not effective.");
        }

        private static string DirectoryPathForHandle(SafeFileHandle handle)
        {
            return HandleBoundFileReader.NormalizeFinalPath(HandleBoundFileReader.GetFinalPath(handle));
        }

        private static void SetDirectoryDeletePending(SafeFileHandle handle, bool deletePending)
        {
            IntPtr disposition = Marshal.AllocHGlobal(1);
            try
            {
                Marshal.WriteByte(disposition, deletePending ? (byte)1 : (byte)0);
                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(
                    handle,
                    out ioStatusBlock,
                    disposition,
                    1,
                    FileDispositionInformation);
                if (status != 0)
                {
                    uint dosError = RtlNtStatusToDosError(status);
                    throw new Win32Exception(
                        checked((int)dosError),
                        deletePending
                            ? "Unable to mark the verified directory delete-pending."
                            : "Unable to cancel delete-pending for the verified directory.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(disposition);
            }
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

        public static uint VerifySafeTreeDeleteFile(
            SafeFileHandle handle,
            string expectedPath,
            bool allowHardLinks)
        {
            return VerifySafeTreeDeleteFileHandle(handle, expectedPath, allowHardLinks);
        }

        public static string[] ReadFileIdentity(SafeFileHandle handle)
        {
            return GetFileIdentity(handle);
        }

        internal static uint VerifySafeTreeDeleteFileHandle(
            SafeFileHandle handle,
            string expectedPath,
            bool allowHardLinks)
        {
            ByHandleFileInformation fileInformation;
            if (!GetFileInformationByHandle(handle, out fileInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if ((fileInformation.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                throw new IOException("The safe-tree-delete file is a reparse point.");
            }
            if ((fileInformation.FileAttributes & FileAttributeDirectory) != 0)
            {
                throw new IOException("The safe-tree-delete file is not a regular file.");
            }
            if (fileInformation.NumberOfLinks == 0)
            {
                throw new IOException("The safe-tree-delete file has an invalid hard-link count.");
            }
            if (!allowHardLinks && fileInformation.NumberOfLinks != 1)
            {
                throw new IOException("The safe-tree-delete file is a hard link not authorized by policy.");
            }

            AssertOpenedPathMatches(handle, expectedPath, false);
            AssertRegularFileHasNoAlternateDataStreams(handle);
            return fileInformation.NumberOfLinks;
        }

        internal static void VerifySafeTreeDeleteMountPointHandle(
            SafeFileHandle handle,
            string expectedPath,
            out uint reparseTag,
            out string targetPath,
            out byte[] reparseData)
        {
            ByHandleFileInformation fileInformation;
            if (!GetFileInformationByHandle(handle, out fileInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if ((fileInformation.FileAttributes & FileAttributeReparsePoint) == 0 ||
                (fileInformation.FileAttributes & FileAttributeDirectory) == 0)
            {
                throw new IOException(
                    "The safe-tree-delete reparse leaf is not a directory reparse point.");
            }

            AssertOpenedPathMatches(handle, expectedPath, true);
            AssertNoAlternateDataStreams(handle);
            reparseData = ReadReparseData(handle);
            reparseTag = ReadUInt32(reparseData, 0);
            if (reparseTag != IoReparseTagMountPoint)
            {
                throw new IOException(
                    "The safe-tree-delete reparse leaf is not a mount-point junction.");
            }
            targetPath = ParseMountPointTarget(reparseData);
        }

        private static void AssertOpenedPathMatches(
            SafeFileHandle handle,
            string expectedPath,
            bool trimDirectoryEnding)
        {
            string lexicalPath = Path.GetFullPath(expectedPath);
            string openedPath = Path.GetFullPath(
                HandleBoundFileReader.NormalizeFinalPath(
                    HandleBoundFileReader.GetOpenedFinalPath(handle)));
            if (trimDirectoryEnding)
            {
                lexicalPath = TrimDirectoryEnding(lexicalPath);
                openedPath = TrimDirectoryEnding(openedPath);
            }
            if (!string.Equals(lexicalPath, openedPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new HandlePathMismatchException(expectedPath, openedPath);
            }
        }

        private static void AssertRegularFileHasNoAlternateDataStreams(SafeFileHandle handle)
        {
            const int fileStreamInformationHeaderLength = 24;
            int bufferLength = 4096;
            while (true)
            {
                IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
                try
                {
                    for (int index = 0; index < bufferLength; index++)
                    {
                        Marshal.WriteByte(buffer, index, 0);
                    }
                    if (!GetFileInformationByHandleEx(
                        handle,
                        FileStreamInfo,
                        buffer,
                        checked((uint)bufferLength)))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == ErrorMoreData && bufferLength < 1024 * 1024)
                        {
                            bufferLength = checked(bufferLength * 2);
                            continue;
                        }
                        throw new Win32Exception(
                            error,
                            "Unable to enumerate streams for the safe-tree-delete file handle.");
                    }

                    int offset = 0;
                    int defaultStreamCount = 0;
                    while (true)
                    {
                        if (offset < 0 || offset + fileStreamInformationHeaderLength > bufferLength)
                        {
                            throw new IOException(
                                "The safe-tree-delete file stream enumeration returned an invalid record.");
                        }
                        int nextOffset = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 4);
                        if (nameLength < 0 || (nameLength & 1) != 0 ||
                            offset + fileStreamInformationHeaderLength + nameLength > bufferLength)
                        {
                            throw new IOException(
                                "The safe-tree-delete file stream enumeration returned an invalid name.");
                        }
                        string streamName = Marshal.PtrToStringUni(
                            IntPtr.Add(buffer, offset + fileStreamInformationHeaderLength),
                            nameLength / 2);
                        if (!string.Equals(streamName, "::$DATA", StringComparison.Ordinal))
                        {
                            throw new IOException(
                                "The safe-tree-delete file contains an NTFS alternate data stream.");
                        }
                        defaultStreamCount++;
                        if (nextOffset == 0)
                        {
                            break;
                        }
                        if (nextOffset < fileStreamInformationHeaderLength ||
                            (nextOffset & 7) != 0 ||
                            offset + nextOffset > bufferLength)
                        {
                            throw new IOException(
                                "The safe-tree-delete file stream enumeration returned an invalid offset.");
                        }
                        offset += nextOffset;
                    }
                    if (defaultStreamCount != 1)
                    {
                        throw new IOException(
                            "The safe-tree-delete file stream enumeration did not return exactly one default stream.");
                    }
                    return;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        private static byte[] ReadReparseData(SafeFileHandle handle)
        {
            const int maximumReparseDataBufferSize = 16 * 1024;
            IntPtr buffer = Marshal.AllocHGlobal(maximumReparseDataBufferSize);
            try
            {
                uint bytesReturned;
                if (!DeviceIoControl(
                    handle,
                    FsctlGetReparsePoint,
                    IntPtr.Zero,
                    0,
                    buffer,
                    maximumReparseDataBufferSize,
                    out bytesReturned,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Unable to read the safe-tree-delete reparse leaf payload.");
                }
                if (bytesReturned < 16 || bytesReturned > maximumReparseDataBufferSize)
                {
                    throw new IOException("The reparse leaf returned an invalid payload length.");
                }
                byte[] bytes = new byte[checked((int)bytesReturned)];
                Marshal.Copy(buffer, bytes, 0, bytes.Length);
                int declaredLength = ReadUInt16(bytes, 4);
                if (declaredLength < 8 || declaredLength + 8 != bytes.Length)
                {
                    throw new IOException("The reparse leaf payload length does not match its header.");
                }
                return bytes;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static string ParseMountPointTarget(byte[] reparseData)
        {
            const int pathBufferOffset = 16;
            int reparseDataLength = ReadUInt16(reparseData, 4);
            int pathBufferLength = checked(reparseDataLength - 8);
            int substituteNameOffset = ReadUInt16(reparseData, 8);
            int substituteNameLength = ReadUInt16(reparseData, 10);
            int printNameOffset = ReadUInt16(reparseData, 12);
            int printNameLength = ReadUInt16(reparseData, 14);
            ValidateReparseNameRange(
                substituteNameOffset,
                substituteNameLength,
                pathBufferLength,
                "substitute");
            ValidateReparseNameRange(
                printNameOffset,
                printNameLength,
                pathBufferLength,
                "print");
            string substituteName = Encoding.Unicode.GetString(
                reparseData,
                checked(pathBufferOffset + substituteNameOffset),
                substituteNameLength);
            if (string.IsNullOrWhiteSpace(substituteName) || substituteName.IndexOf('\0') >= 0)
            {
                throw new IOException("The mount-point junction target is empty or malformed.");
            }
            return NormalizeMountPointTarget(substituteName);
        }

        private static void ValidateReparseNameRange(
            int offset,
            int length,
            int pathBufferLength,
            string name)
        {
            if ((offset & 1) != 0 || (length & 1) != 0 ||
                offset < 0 || length < 0 || offset > pathBufferLength - length)
            {
                throw new IOException(
                    "The mount-point junction " + name + " name range is invalid.");
            }
        }

        private static string NormalizeMountPointTarget(string substituteName)
        {
            const string ntPrefix = @"\??\";
            const string extendedPrefix = @"\\?\";
            string target = substituteName;
            if (target.StartsWith(ntPrefix + "UNC\\", StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(
                    @"\\" + target.Substring((ntPrefix + "UNC\\").Length));
            }
            if (target.StartsWith(ntPrefix, StringComparison.OrdinalIgnoreCase))
            {
                string remainder = target.Substring(ntPrefix.Length);
                if (remainder.Length >= 3 && char.IsLetter(remainder[0]) &&
                    remainder[1] == ':' && remainder[2] == '\\')
                {
                    return Path.GetFullPath(remainder);
                }
                if (remainder.StartsWith("Volume{", StringComparison.OrdinalIgnoreCase))
                {
                    return Path.GetFullPath(extendedPrefix + remainder);
                }
                throw new IOException("The mount-point junction uses an unsupported NT target path.");
            }
            if (target.StartsWith(extendedPrefix + "UNC\\", StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(
                    @"\\" + target.Substring((extendedPrefix + "UNC\\").Length));
            }
            if (target.StartsWith(extendedPrefix, StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(target);
            }
            throw new IOException("The mount-point junction target is not an absolute NT path.");
        }

        private static ushort ReadUInt16(byte[] bytes, int offset)
        {
            if (bytes == null || offset < 0 || offset > bytes.Length - sizeof(ushort))
            {
                throw new IOException("The reparse leaf payload is truncated.");
            }
            return checked((ushort)(bytes[offset] | (bytes[offset + 1] << 8)));
        }

        private static uint ReadUInt32(byte[] bytes, int offset)
        {
            if (bytes == null || offset < 0 || offset > bytes.Length - sizeof(uint))
            {
                throw new IOException("The reparse leaf payload is truncated.");
            }
            return (uint)(
                bytes[offset] |
                (bytes[offset + 1] << 8) |
                (bytes[offset + 2] << 16) |
                (bytes[offset + 3] << 24));
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

        internal static void DeleteSafeTreeDeleteLeafHandle(
            SafeFileHandle handle,
            string failureMessage)
        {
            IntPtr buffer = Marshal.AllocHGlobal(sizeof(uint));
            try
            {
                Marshal.WriteInt32(
                    buffer,
                    unchecked((int)(
                        FileDispositionDelete |
                        FileDispositionPosixSemantics |
                        FileDispositionIgnoreReadonlyAttribute)));
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
                    throw new Win32Exception(checked((int)dosError), failureMessage);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
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

    public sealed class SafeTreeDeleteFileLease : IDisposable
    {
        private readonly VerifiedDirectoryChainGuard owner;
        private readonly SafeFileHandle handle;
        private readonly FileStream stream;
        private readonly bool allowHardLinks;
        private byte[] snapshotBytes;
        private bool disposed;

        internal SafeTreeDeleteFileLease(
            VerifiedDirectoryChainGuard owner,
            string originalPath,
            SafeFileHandle handle,
            bool allowHardLinks,
            string volumeSerialNumber,
            string fileIndex,
            uint numberOfLinks)
        {
            this.owner = owner;
            OriginalPath = originalPath;
            this.handle = handle;
            this.allowHardLinks = allowHardLinks;
            VolumeSerialNumber = volumeSerialNumber;
            FileIndex = fileIndex;
            NumberOfLinks = numberOfLinks;
            stream = new FileStream(handle, FileAccess.Read);
        }

        public string OriginalPath { get; }

        public string VolumeSerialNumber { get; }

        public string FileIndex { get; }

        /// <summary>
        /// The live lease handle. Callers must not dispose it; the lease owns it.
        /// </summary>
        public SafeFileHandle Handle
        {
            get
            {
                ThrowIfDisposed();
                return handle;
            }
        }

        public uint NumberOfLinks { get; }

        public long Length
        {
            get
            {
                VerifyCurrentHandle();
                return stream.Length;
            }
        }

        public byte[] SnapshotBytes
        {
            get
            {
                VerifyCurrentHandle();
                if (snapshotBytes == null)
                {
                    snapshotBytes = ReadAllBytesFromHandleCore();
                }
                return (byte[])snapshotBytes.Clone();
            }
        }

        public byte[] ComputeSha256FromHandle()
        {
            VerifyCurrentHandle();
            stream.Position = 0;
            using (SHA256 sha256 = SHA256.Create())
            {
                return sha256.ComputeHash(stream);
            }
        }

        public byte[] ReadAllBytesFromHandle()
        {
            VerifyCurrentHandle();
            return ReadAllBytesFromHandleCore();
        }

        public void DeleteWithPosixSemantics()
        {
            VerifyCurrentHandle();
            VerifiedDirectoryChainGuard.DeleteSafeTreeDeleteLeafHandle(
                handle,
                "Unable to delete the safe-tree-delete file leaf.");
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

        private void VerifyCurrentHandle()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            VerifiedDirectoryChainGuard.VerifySafeTreeDeleteFileHandle(
                handle,
                OriginalPath,
                allowHardLinks);
            AssertIdentityUnchanged();
        }

        private void AssertIdentityUnchanged()
        {
            string[] identity = VerifiedDirectoryChainGuard.GetFileIdentity(handle);
            if (!string.Equals(identity[0], VolumeSerialNumber, StringComparison.Ordinal) ||
                !string.Equals(identity[1], FileIndex, StringComparison.Ordinal))
            {
                throw new IOException("The safe-tree-delete file handle identity changed.");
            }
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
                throw new ObjectDisposedException(nameof(SafeTreeDeleteFileLease));
            }
        }
    }

    public sealed class SafeTreeDeleteReparseLeafLease : IDisposable
    {
        private readonly VerifiedDirectoryChainGuard owner;
        private readonly SafeFileHandle handle;
        private readonly byte[] reparseData;
        private readonly byte[] reparseDataSha256;
        private bool disposed;

        internal SafeTreeDeleteReparseLeafLease(
            VerifiedDirectoryChainGuard owner,
            string originalPath,
            SafeFileHandle handle,
            string volumeSerialNumber,
            string fileIndex,
            uint reparseTag,
            string targetPath,
            byte[] reparseData,
            byte[] reparseDataSha256)
        {
            this.owner = owner;
            OriginalPath = originalPath;
            this.handle = handle;
            VolumeSerialNumber = volumeSerialNumber;
            FileIndex = fileIndex;
            ReparseTag = reparseTag;
            TargetPath = targetPath;
            this.reparseData = (byte[])reparseData.Clone();
            this.reparseDataSha256 = (byte[])reparseDataSha256.Clone();
        }

        public string OriginalPath { get; }

        public string VolumeSerialNumber { get; }

        public string FileIndex { get; }

        public uint ReparseTag { get; }

        public string TargetPath { get; }

        public int ReparseDataLength
        {
            get
            {
                ThrowIfDisposed();
                return reparseData.Length;
            }
        }

        public byte[] ReparseDataSha256
        {
            get
            {
                ThrowIfDisposed();
                return (byte[])reparseDataSha256.Clone();
            }
        }

        public byte[] ComputeReparseDataSha256FromHandle()
        {
            byte[] currentReparseData;
            CaptureCurrentState(out currentReparseData);
            using (SHA256 sha256 = SHA256.Create())
            {
                return sha256.ComputeHash(currentReparseData);
            }
        }

        public string ReadTargetPathFromHandle()
        {
            byte[] ignored;
            return CaptureCurrentState(out ignored);
        }

        public void DeleteWithPosixSemantics()
        {
            byte[] currentReparseData;
            string currentTargetPath = CaptureCurrentState(out currentReparseData);
            using (SHA256 sha256 = SHA256.Create())
            {
                byte[] currentSha256 = sha256.ComputeHash(currentReparseData);
                if (!CryptographicOperations.FixedTimeEquals(
                    currentSha256,
                    reparseDataSha256))
                {
                    throw new IOException("The mount-point junction reparse payload changed.");
                }
            }
            if (!string.Equals(currentTargetPath, TargetPath, StringComparison.OrdinalIgnoreCase) ||
                !CryptographicOperations.FixedTimeEquals(currentReparseData, reparseData))
            {
                throw new IOException("The mount-point junction target changed.");
            }
            VerifiedDirectoryChainGuard.DeleteSafeTreeDeleteLeafHandle(
                handle,
                "Unable to delete the safe-tree-delete mount-point junction leaf.");
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

        private string CaptureCurrentState(out byte[] currentReparseData)
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            uint currentTag;
            string currentTargetPath;
            VerifiedDirectoryChainGuard.VerifySafeTreeDeleteMountPointHandle(
                handle,
                OriginalPath,
                out currentTag,
                out currentTargetPath,
                out currentReparseData);
            if (currentTag != ReparseTag)
            {
                throw new IOException("The mount-point junction reparse tag changed.");
            }
            string[] identity = VerifiedDirectoryChainGuard.GetFileIdentity(handle);
            if (!string.Equals(identity[0], VolumeSerialNumber, StringComparison.Ordinal) ||
                !string.Equals(identity[1], FileIndex, StringComparison.Ordinal))
            {
                throw new IOException("The mount-point junction handle identity changed.");
            }
            return currentTargetPath;
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException(nameof(SafeTreeDeleteReparseLeafLease));
            }
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
            string actualSddl = SetSecurityDescriptorSddlForHandleAndReadBack(
                targetHandle,
                originalPath,
                expectedCurrentSddl,
                sddl);
            string expectedPostWriteSddl = sddl;
            RawSecurityDescriptor expectedDescriptor = new RawSecurityDescriptor(sddl);
            if ((expectedDescriptor.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0 &&
                expectedDescriptor.DiscretionaryAcl != null)
            {
                // Windows materializes inherited ACEs as explicit when protecting a DACL.
                for (int index = 0; index < expectedDescriptor.DiscretionaryAcl.Count; index++)
                {
                    GenericAce ace = expectedDescriptor.DiscretionaryAcl[index];
                    ace.AceFlags &= ~AceFlags.Inherited;
                }
                expectedPostWriteSddl = expectedDescriptor.GetSddlForm(
                    AccessControlSections.Owner |
                    AccessControlSections.Group |
                    AccessControlSections.Access);
            }
            if (!string.Equals(actualSddl, expectedPostWriteSddl, StringComparison.Ordinal))
            {
                throw new IOException("The guarded ACL target security descriptor changed after the handle-bound write.");
            }
        }

        internal static string SetSecurityDescriptorSddlForHandleAndReadBack(
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
            if (desiredDescriptor.SystemAcl != null ||
                (desiredDescriptor.ControlFlags & ControlFlags.SystemAclPresent) != 0)
            {
                throw new IOException("The guarded ACL target SDDL must not include a SACL.");
            }
            string currentOwner = currentDescriptor.Owner == null ? string.Empty : currentDescriptor.Owner.Value;
            string desiredOwner = desiredDescriptor.Owner == null ? string.Empty : desiredDescriptor.Owner.Value;
            string currentGroup = currentDescriptor.Group == null ? string.Empty : currentDescriptor.Group.Value;
            string desiredGroup = desiredDescriptor.Group == null ? string.Empty : desiredDescriptor.Group.Value;
            if (!string.Equals(currentOwner, desiredOwner, StringComparison.Ordinal) ||
                !string.Equals(currentGroup, desiredGroup, StringComparison.Ordinal))
            {
                throw new IOException("The guarded ACL target owner or group changed outside this lease.");
            }
            bool desiredDaclProtected =
                (desiredDescriptor.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0;

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
                sections |= desiredDaclProtected
                    ? ProtectedDaclSecurityInformation
                    : UnprotectedDaclSecurityInformation;
                uint error = SetSecurityInfo(
                    targetHandle,
                    SeFileObject,
                    sections,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    dacl,
                    IntPtr.Zero);
                if (error != 0) { throw new Win32Exception(checked((int)error), "Unable to write the guarded ACL target security descriptor."); }
            }
            finally { LocalFree(descriptor); }

            return GetSecurityDescriptorSddlForHandle(targetHandle, originalPath);
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
            SetSecurityDescriptorSddlForHandle(handle, OriginalPath, expectedCurrentSddl, sddl);
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
        private byte[] snapshotBytes;
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
                if (snapshotBytes == null)
                {
                    VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, OriginalPath);
                    snapshotBytes = ReadAllBytesFromHandleCore();
                }
                return (byte[])snapshotBytes.Clone();
            }
        }

        public byte[] ComputeSha256FromHandle()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, OriginalPath);
            stream.Position = 0;
            using (SHA256 sha256 = SHA256.Create())
            {
                return sha256.ComputeHash(stream);
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
        private byte[] snapshotBytes;
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
                if (snapshotBytes == null)
                {
                    VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, OriginalPath);
                    snapshotBytes = ReadAllBytesFromHandleCore();
                }
                return (byte[])snapshotBytes.Clone();
            }
        }

        public byte[] ComputeSha256FromHandle()
        {
            ThrowIfDisposed();
            owner.ThrowIfDisposed();
            VerifiedDirectoryChainGuard.VerifyRegularFileHandle(handle, OriginalPath);
            stream.Position = 0;
            using (SHA256 sha256 = SHA256.Create())
            {
                return sha256.ComputeHash(stream);
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
