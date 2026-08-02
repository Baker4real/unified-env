[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Sweep', 'Watch')]
    [string]$Mode = 'Watch',
    [string]$PolicyPath,
    [string]$FixtureRoot,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$liveCatalogRoot = 'D:\Codex\.codex\cache\remote_plugin_catalog'
$liveStateRoot = 'D:\Codex\.codex\catalog-guard\state'
$liveLogPath = 'D:\Codex\.codex\logs\remote-plugin-catalog-guard.jsonl'
$testModeEnvironment = 'CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'
$fixtureMarkerName = '.remote-plugin-catalog-guard-fixture'
$fixtureMarkerValue = "fixture-v1`n"
$expectedTargets = [ordered]@{
    heygen = 'plugin_asdk_app_69418aad55e08191aa5e437b649ca2e4'
    hyperframes = 'Plugin_d72b815ecf6481919e3beede9c71ef08'
    remotion = 'plugins~Plugin_efd07789186881918253a50acfc32762'
    superpowers = 'plugins~Plugin_60aea7460bd4819199fd97a9553a5e12'
}
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:fixturePostIsolationMutationConsumed = $false
$script:fixturePostprocessMutationConsumed = $false
$script:fixtureMarkerCleanupReplacementConsumed = $false
$script:fixtureTransientSharingFailureConsumed = $false
$managedTransactionArtifactPattern = '^\.codex-catalog-guard-([0-9a-f]{16})\.(txn|publish|quarantine|vendor-abort)$'
$managedStagingArtifactPattern = '^\.codex-catalog-guard-([0-9a-f]{16})\.stage-([0-9a-f]{32})\.(txn|publish|vendor-abort)$'
$managedTransactionArtifactPrefix = '.codex-catalog-guard-'
$durableStagedFileSource = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexCatalogGuard
{
    public sealed class DurableStagedFile : IDisposable
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint DeleteAccess = 0x00010000;
        private const uint SynchronizeAccess = 0x00100000;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint FileFlagWriteThrough = 0x80000000;
        private const uint FileFlagDeleteOnClose = 0x04000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const int FileRenameInformationEx = 65;
        private const int FileDispositionInformationEx = 64;
        private const int FileDispositionInformation = 13;
        private const uint FileDispositionDelete = 0x00000001;
        private const uint FileDispositionPosixSemantics = 0x00000002;
        private const string IntegrityEaName = "CodexCatalogGuardV1";
        private static readonly byte[] IntegrityMagic = Encoding.ASCII.GetBytes("CDXCGV4!");

        private readonly SafeFileHandle handle;
        private readonly FileStream stream;
        private string currentPath;
        private bool flushed;
        private bool published;
        private bool renamePending;
        private bool deleteOnCloseCleared;
        private bool integritySealed;
        private bool disposed;
        private readonly string stableVolumeSerialNumber;
        private readonly string stableFileIndex;

        public sealed class IntegritySnapshot
        {
            public byte[] Bytes { get; private set; }
            public string Sha256 { get; private set; }
            public string Kind { get; private set; }
            public string VolumeSerialNumber { get; private set; }
            public string FileIndex { get; private set; }

            internal IntegritySnapshot(byte[] bytes, string sha256, string kind, string volumeSerialNumber, string fileIndex)
            {
                Bytes = bytes;
                Sha256 = sha256;
                Kind = kind;
                VolumeSerialNumber = volumeSerialNumber;
                FileIndex = fileIndex;
            }
        }

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

        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(
            SafeFileHandle fileHandle,
            out IoStatusBlock ioStatusBlock,
            IntPtr fileInformation,
            uint length,
            int fileInformationClass);

        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);

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

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FlushFileBuffers(SafeFileHandle fileHandle);

        private DurableStagedFile(string path, SafeFileHandle fileHandle)
        {
            currentPath = path;
            handle = fileHandle;
            stream = new FileStream(handle, FileAccess.ReadWrite);
            ByHandleFileInformation information = GetInformation();
            stableVolumeSerialNumber = information.VolumeSerialNumber.ToString("x8");
            stableFileIndex = information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8");
        }

        public static DurableStagedFile Create(string stagingPath)
        {
            if (stagingPath == null) { throw new ArgumentNullException(nameof(stagingPath)); }
            string lexicalPath = Path.GetFullPath(stagingPath);
            SafeFileHandle fileHandle = CreateFileW(
                ToExtendedPath(lexicalPath),
                GenericRead | GenericWrite | DeleteAccess | SynchronizeAccess,
                FileShare.Read,
                IntPtr.Zero,
                CreateNew,
                FileAttributeNormal | FileFlagWriteThrough | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (fileHandle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                fileHandle.Dispose();
                throw new Win32Exception(error, "Unable to create a durable staged file.");
            }
            try
            {
                DurableStagedFile file = new DurableStagedFile(lexicalPath, fileHandle);
                file.VerifyCurrentPath();
                SetLegacyDeleteDisposition(fileHandle, true);
                return file;
            }
            catch
            {
                fileHandle.Dispose();
                throw;
            }
        }

        public string VolumeSerialNumber
        {
            get { ThrowIfDisposed(); return stableVolumeSerialNumber; }
        }

        public string FileIndex
        {
            get
            {
                ThrowIfDisposed();
                return stableFileIndex;
            }
        }

        public string CurrentPath
        {
            get { ThrowIfDisposed(); return currentPath; }
        }

        public void Write(byte[] bytes, int offset, int count)
        {
            ThrowIfDisposed();
            if (bytes == null) { throw new ArgumentNullException(nameof(bytes)); }
            if (published || flushed) { throw new InvalidOperationException("The staged file is no longer writable."); }
            stream.Write(bytes, offset, count);
        }

        public void Flush()
        {
            ThrowIfDisposed();
            if (published || flushed) { throw new InvalidOperationException("The staged file was already flushed."); }
            stream.Flush(true);
            flushed = true;
        }

        public void SealIntegrityAnchor(string kind, string sha256, string injectedFailure)
        {
            ThrowIfDisposed();
            if (!flushed || published || renamePending || deleteOnCloseCleared || integritySealed)
            {
                throw new InvalidOperationException("The durable staged integrity state is invalid.");
            }
            if (!string.IsNullOrEmpty(injectedFailure) &&
                !string.Equals(injectedFailure, "nt-set-ea", StringComparison.Ordinal) &&
                !string.Equals(injectedFailure, "flush-file-buffers", StringComparison.Ordinal))
            {
                throw new ArgumentException("Unsupported injected integrity failure.", nameof(injectedFailure));
            }
            byte kindCode = GetKindCode(kind);
            byte[] expectedSha = ParseSha256(sha256);
            byte[] actualBytes = ReadAllBytesFromHandle();
            byte[] actualSha = SHA256.HashData(actualBytes);
            if (!CryptographicOperations.FixedTimeEquals(expectedSha, actualSha))
            {
                throw new InvalidDataException("The durable staged content does not match its integrity anchor.");
            }

            byte[] anchor = new byte[IntegrityMagic.Length + 2 + expectedSha.Length];
            Buffer.BlockCopy(IntegrityMagic, 0, anchor, 0, IntegrityMagic.Length);
            anchor[IntegrityMagic.Length] = 1;
            anchor[IntegrityMagic.Length + 1] = kindCode;
            Buffer.BlockCopy(expectedSha, 0, anchor, IntegrityMagic.Length + 2, expectedSha.Length);
            if (string.Equals(injectedFailure, "nt-set-ea", StringComparison.Ordinal))
            {
                throw new Win32Exception(5, "Injected NtSetEaFile failure while sealing a catalog transaction artifact.");
            }
            SetExtendedAttribute(handle, IntegrityEaName, anchor);
            if (string.Equals(injectedFailure, "flush-file-buffers", StringComparison.Ordinal))
            {
                throw new Win32Exception(5, "Injected FlushFileBuffers failure after sealing a catalog transaction artifact.");
            }
            if (!FlushFileBuffers(handle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "FlushFileBuffers failed after sealing a catalog transaction artifact.");
            }
            IntegritySnapshot verification = ReadIntegritySnapshotFromHandle(handle, currentPath);
            if (!string.Equals(verification.Kind, kind, StringComparison.Ordinal) ||
                !string.Equals(verification.Sha256, sha256, StringComparison.Ordinal))
            {
                throw new InvalidDataException("The durable staged integrity anchor verification failed.");
            }
            integritySealed = true;
        }

        public static IntegritySnapshot ReadIntegritySnapshot(string path)
        {
            if (path == null) { throw new ArgumentNullException(nameof(path)); }
            string lexicalPath = Path.GetFullPath(path);
            SafeFileHandle fileHandle = CreateFileW(
                ToExtendedPath(lexicalPath),
                GenericRead | SynchronizeAccess,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (fileHandle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                fileHandle.Dispose();
                throw new Win32Exception(error, "CreateFileW failed while opening an anchored catalog transaction artifact.");
            }
            try { return ReadIntegritySnapshotFromHandle(fileHandle, lexicalPath); }
            finally { fileHandle.Dispose(); }
        }

        public void BeginRenameTo(string targetPath, bool replaceIfExists)
        {
            ThrowIfDisposed();
            if (!flushed) { throw new InvalidOperationException("The staged file must be flushed before rename."); }
            if (published) { throw new InvalidOperationException("The staged file was already published."); }
            if (renamePending) { throw new InvalidOperationException("The staged file already has a pending rename."); }
            if (!deleteOnCloseCleared) { throw new InvalidOperationException("The staged file delete-on-close state is still active."); }
            if (replaceIfExists) { throw new InvalidOperationException("Durable staging only permits no-replace publication."); }

            string lexicalTarget = Path.GetFullPath(targetPath);
            if (!string.Equals(Path.GetDirectoryName(currentPath), Path.GetDirectoryName(lexicalTarget), StringComparison.OrdinalIgnoreCase) ||
                string.Equals(currentPath, lexicalTarget, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The durable staged target must be a distinct sibling.");
            }
            VerifyCurrentPath();
            RenameHandleNoReplace(lexicalTarget);
            currentPath = lexicalTarget;
            renamePending = true;
            VerifyCurrentPath();
        }

        public void VerifyPendingPublication()
        {
            ThrowIfDisposed();
            if (!renamePending || published) { throw new InvalidOperationException("The staged file has no pending publication."); }
            VerifyCurrentPath();
        }

        public void ClearDeleteOnCloseForPublication()
        {
            ThrowIfDisposed();
            if (renamePending || published || deleteOnCloseCleared || !flushed || !integritySealed) { throw new InvalidOperationException("The staged publication state is invalid."); }
            VerifyCurrentPath();
            ClearDeleteOnClose(handle);
            deleteOnCloseCleared = true;
            VerifyCurrentPath();
        }

        public void FinalizePublication()
        {
            ThrowIfDisposed();
            if (!renamePending || published || !deleteOnCloseCleared) { throw new InvalidOperationException("The staged publication is not durable."); }
            VerifyCurrentPath();
            renamePending = false;
            published = true;
        }

        public void RenameTo(string targetPath, bool replaceIfExists)
        {
            ClearDeleteOnCloseForPublication();
            BeginRenameTo(targetPath, replaceIfExists);
            VerifyPendingPublication();
            FinalizePublication();
        }

        public void RenamePublishedTo(string targetPath, bool replaceIfExists)
        {
            ThrowIfDisposed();
            if (!published || renamePending) { throw new InvalidOperationException("The staged file is not durably published."); }
            if (replaceIfExists) { throw new InvalidOperationException("Durable publication only permits no-replace rename."); }
            string lexicalTarget = Path.GetFullPath(targetPath);
            if (!string.Equals(Path.GetDirectoryName(currentPath), Path.GetDirectoryName(lexicalTarget), StringComparison.OrdinalIgnoreCase) ||
                string.Equals(currentPath, lexicalTarget, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The durable published target must be a distinct sibling.");
            }
            VerifyCurrentPath();
            RenameHandleNoReplace(lexicalTarget);
            currentPath = lexicalTarget;
            VerifyCurrentPath();
        }

        public byte[] ReadAllBytesFromHandle()
        {
            ThrowIfDisposed();
            VerifyCurrentPath();
            stream.Position = 0;
            using (MemoryStream copy = new MemoryStream())
            {
                stream.CopyTo(copy);
                return copy.ToArray();
            }
        }

        public void DeleteWithPosixSemantics()
        {
            ThrowIfDisposed();
            VerifyCurrentPath();
            SetDisposition(FileDispositionDelete | FileDispositionPosixSemantics);
        }

        public void VerifyCurrentPath()
        {
            ThrowIfDisposed();
            ByHandleFileInformation information = VerifyRegularFileHandle(handle, currentPath);
            string volumeSerialNumber = information.VolumeSerialNumber.ToString("x8");
            string fileIndex = information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8");
            if (!string.Equals(volumeSerialNumber, stableVolumeSerialNumber, StringComparison.Ordinal) ||
                !string.Equals(fileIndex, stableFileIndex, StringComparison.Ordinal))
            {
                throw new IOException("The durable staged handle identity changed.");
            }
        }

        private static ByHandleFileInformation VerifyRegularFileHandle(SafeFileHandle fileHandle, string expectedPath)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(fileHandle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if ((information.FileAttributes & FileAttributeReparsePoint) != 0 ||
                (information.FileAttributes & FileAttributeDirectory) != 0 ||
                (information.NumberOfLinks != 1 && information.NumberOfLinks != 0))
            {
                throw new IOException("The durable staged object is not a unique regular file.");
            }
            string finalPath = NormalizeFinalPath(GetFinalPath(fileHandle));
            if (!string.Equals(Path.GetFullPath(expectedPath), Path.GetFullPath(finalPath), StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The durable staged handle no longer resolves to its expected path.");
            }
            return information;
        }

        private static IntegritySnapshot ReadIntegritySnapshotFromHandle(SafeFileHandle fileHandle, string expectedPath)
        {
            ByHandleFileInformation information = VerifyRegularFileHandle(fileHandle, expectedPath);
            long length = RandomAccess.GetLength(fileHandle);
            if (length < 0 || length > int.MaxValue) { throw new InvalidDataException("The catalog transaction artifact length is invalid."); }
            byte[] bytes = new byte[checked((int)length)];
            int totalRead = 0;
            while (totalRead < bytes.Length)
            {
                int count = RandomAccess.Read(fileHandle, bytes.AsSpan(totalRead), totalRead);
                if (count <= 0) { throw new EndOfStreamException("The catalog transaction artifact ended during handle-bound read."); }
                totalRead = checked(totalRead + count);
            }

            byte[] anchor = GetExtendedAttribute(fileHandle, IntegrityEaName, 128);
            int expectedAnchorLength = IntegrityMagic.Length + 2 + 32;
            if (anchor.Length != expectedAnchorLength)
            {
                throw new InvalidDataException("The catalog transaction integrity anchor length is invalid.");
            }
            for (int index = 0; index < IntegrityMagic.Length; index++)
            {
                if (anchor[index] != IntegrityMagic[index])
                {
                    throw new InvalidDataException("The catalog transaction integrity anchor magic is invalid.");
                }
            }
            if (anchor[IntegrityMagic.Length] != 1)
            {
                throw new InvalidDataException("The catalog transaction integrity anchor version is invalid.");
            }
            string kind = GetKindName(anchor[IntegrityMagic.Length + 1]);
            byte[] anchoredSha = new byte[32];
            Buffer.BlockCopy(anchor, IntegrityMagic.Length + 2, anchoredSha, 0, anchoredSha.Length);
            byte[] actualSha = SHA256.HashData(bytes);
            if (!CryptographicOperations.FixedTimeEquals(anchoredSha, actualSha))
            {
                throw new InvalidDataException("The catalog transaction default stream no longer matches its NTFS integrity anchor.");
            }
            return new IntegritySnapshot(
                bytes,
                Convert.ToHexString(anchoredSha).ToLowerInvariant(),
                kind,
                information.VolumeSerialNumber.ToString("x8"),
                information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8"));
        }

        private static void SetExtendedAttribute(SafeFileHandle fileHandle, string name, byte[] value)
        {
            byte[] nameBytes = Encoding.ASCII.GetBytes(name);
            if (nameBytes.Length == 0 || nameBytes.Length > byte.MaxValue || value.Length > ushort.MaxValue)
            {
                throw new InvalidDataException("The catalog transaction integrity anchor is too large.");
            }
            byte[] buffer = new byte[checked(8 + nameBytes.Length + 1 + value.Length)];
            buffer[5] = checked((byte)nameBytes.Length);
            buffer[6] = (byte)(value.Length & 0xff);
            buffer[7] = (byte)((value.Length >> 8) & 0xff);
            Buffer.BlockCopy(nameBytes, 0, buffer, 8, nameBytes.Length);
            Buffer.BlockCopy(value, 0, buffer, 9 + nameBytes.Length, value.Length);
            IoStatusBlock ioStatusBlock;
            int status = NtSetEaFile(fileHandle, out ioStatusBlock, buffer, checked((uint)buffer.Length));
            ThrowForNtStatus(status, "NtSetEaFile failed while sealing a catalog transaction artifact.");
        }

        private static byte[] GetExtendedAttribute(SafeFileHandle fileHandle, string name, int maximumValueLength)
        {
            byte[] nameBytes = Encoding.ASCII.GetBytes(name);
            if (nameBytes.Length == 0 || nameBytes.Length > byte.MaxValue || maximumValueLength < 0 || maximumValueLength > ushort.MaxValue)
            {
                throw new InvalidDataException("The catalog transaction integrity anchor query is invalid.");
            }
            byte[] eaList = new byte[checked(5 + nameBytes.Length + 1)];
            eaList[4] = checked((byte)nameBytes.Length);
            Buffer.BlockCopy(nameBytes, 0, eaList, 5, nameBytes.Length);
            byte[] output = new byte[checked(8 + nameBytes.Length + 1 + maximumValueLength)];
            IoStatusBlock ioStatusBlock;
            int status = NtQueryEaFile(
                fileHandle,
                out ioStatusBlock,
                output,
                checked((uint)output.Length),
                true,
                eaList,
                checked((uint)eaList.Length),
                IntPtr.Zero,
                true);
            ThrowForNtStatus(status, "NtQueryEaFile failed while reading a catalog transaction integrity anchor.");
            int returnedNameLength = output[5];
            int valueLength = output[6] | (output[7] << 8);
            int valueOffset = checked(9 + returnedNameLength);
            if (returnedNameLength != nameBytes.Length || valueLength > maximumValueLength || valueOffset + valueLength > output.Length)
            {
                throw new InvalidDataException("The catalog transaction integrity anchor response is invalid.");
            }
            string returnedName = Encoding.ASCII.GetString(output, 8, returnedNameLength);
            if (!string.Equals(returnedName, name, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("The catalog transaction integrity anchor name is invalid.");
            }
            byte[] value = new byte[valueLength];
            Buffer.BlockCopy(output, valueOffset, value, 0, valueLength);
            return value;
        }

        private static void ThrowForNtStatus(int status, string message)
        {
            if (status >= 0) { return; }
            throw new Win32Exception(checked((int)RtlNtStatusToDosError(status)), message);
        }

        private static byte[] ParseSha256(string sha256)
        {
            if (sha256 == null || sha256.Length != 64) { throw new ArgumentException("SHA-256 must be 64 lowercase hexadecimal characters.", nameof(sha256)); }
            byte[] bytes;
            try { bytes = Convert.FromHexString(sha256); }
            catch (FormatException) { throw new ArgumentException("SHA-256 must be hexadecimal.", nameof(sha256)); }
            if (!string.Equals(Convert.ToHexString(bytes).ToLowerInvariant(), sha256, StringComparison.Ordinal))
            {
                throw new ArgumentException("SHA-256 must be lowercase hexadecimal.", nameof(sha256));
            }
            return bytes;
        }

        private static byte GetKindCode(string kind)
        {
            if (string.Equals(kind, "txn", StringComparison.Ordinal)) { return 1; }
            if (string.Equals(kind, "publish", StringComparison.Ordinal)) { return 2; }
            if (string.Equals(kind, "vendor-abort", StringComparison.Ordinal)) { return 3; }
            throw new ArgumentException("Unsupported catalog transaction artifact kind.", nameof(kind));
        }

        private static string GetKindName(byte kind)
        {
            if (kind == 1) { return "txn"; }
            if (kind == 2) { return "publish"; }
            if (kind == 3) { return "vendor-abort"; }
            throw new InvalidDataException("The catalog transaction integrity anchor kind is invalid.");
        }

        public void Dispose()
        {
            if (disposed) { return; }
            disposed = true;
            stream.Dispose();
        }

        private void RenameHandleNoReplace(string targetPath)
        {
            string targetLeaf = Path.GetFileName(targetPath);
            byte[] targetNameBytes = Encoding.Unicode.GetBytes(targetLeaf);
            int rootDirectoryOffset = IntPtr.Size;
            int fileNameLengthOffset = checked(rootDirectoryOffset + IntPtr.Size);
            int fileNameOffset = checked(fileNameLengthOffset + sizeof(uint));
            int bufferLength = checked(fileNameOffset + targetNameBytes.Length);
            IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
            try
            {
                for (int index = 0; index < bufferLength; index++) { Marshal.WriteByte(buffer, index, 0); }
                Marshal.WriteInt32(buffer, 0, 0);
                Marshal.WriteIntPtr(buffer, rootDirectoryOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, fileNameLengthOffset, targetNameBytes.Length);
                Marshal.Copy(targetNameBytes, 0, IntPtr.Add(buffer, fileNameOffset), targetNameBytes.Length);
                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(handle, out ioStatusBlock, buffer, checked((uint)bufferLength), FileRenameInformationEx);
                if (status != 0)
                {
                    uint error = RtlNtStatusToDosError(status);
                    throw new Win32Exception(checked((int)error), "Unable to publish a durable staged file.");
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static void ClearDeleteOnClose(SafeFileHandle fileHandle)
        {
            SetLegacyDeleteDisposition(fileHandle, false);
        }

        private static void SetLegacyDeleteDisposition(SafeFileHandle fileHandle, bool deleteFile)
        {
            IntPtr buffer = Marshal.AllocHGlobal(1);
            try
            {
                Marshal.WriteByte(buffer, 0, deleteFile ? (byte)1 : (byte)0);
                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(fileHandle, out ioStatusBlock, buffer, 1, FileDispositionInformation);
                if (status != 0)
                {
                    uint error = RtlNtStatusToDosError(status);
                    throw new Win32Exception(checked((int)error), "Unable to update durable staged file delete-on-close state.");
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private void SetDisposition(uint flags)
        {
            IntPtr buffer = Marshal.AllocHGlobal(sizeof(uint));
            try
            {
                Marshal.WriteInt32(buffer, unchecked((int)flags));
                IoStatusBlock ioStatusBlock;
                int status = NtSetInformationFile(handle, out ioStatusBlock, buffer, sizeof(uint), FileDispositionInformationEx);
                if (status != 0)
                {
                    uint error = RtlNtStatusToDosError(status);
                    throw new Win32Exception(checked((int)error), "Unable to update durable staged file disposition.");
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private ByHandleFileInformation GetInformation()
        {
            ThrowIfDisposed();
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return information;
        }

        private static string GetFinalPath(SafeFileHandle fileHandle)
        {
            uint capacity = 512;
            while (true)
            {
                StringBuilder buffer = new StringBuilder(checked((int)capacity));
                uint result = GetFinalPathNameByHandleW(fileHandle, buffer, capacity, 0);
                if (result == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                if (result < capacity) { return buffer.ToString(); }
                capacity = checked(result + 1);
            }
        }

        private static string NormalizeFinalPath(string path)
        {
            const string uncPrefix = @"\\?\UNC\";
            const string devicePrefix = @"\\?\";
            if (path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase)) { return @"\\" + path.Substring(uncPrefix.Length); }
            if (path.StartsWith(devicePrefix, StringComparison.OrdinalIgnoreCase)) { return path.Substring(devicePrefix.Length); }
            return path;
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) { return path; }
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) { return @"\\?\UNC\" + path.Substring(2); }
            return @"\\?\" + path;
        }

        private void ThrowIfDisposed()
        {
            if (disposed) { throw new ObjectDisposedException(nameof(DurableStagedFile)); }
        }
    }
}
'@

class CatalogGuardFailure : Exception {
    [string]$FailureCode

    CatalogGuardFailure([string]$failureCode, [string]$message) : base($message) {
        $this.FailureCode = $failureCode
    }
}

function Throw-CatalogGuardFailure {
    param([string]$Code, [string]$Message)
    throw [CatalogGuardFailure]::new($Code, $Message)
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function New-CrossSessionCurrentUserOptions {
    $options = [Threading.NamedWaitHandleOptions]::new()
    $options.CurrentUserOnly = $true
    $options.CurrentSessionOnly = $false
    return $options
}

function Assert-NoReparsePath {
    param([string]$Path, [switch]$RequireLeaf)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetPathRoot($fullPath) -ine 'D:\') {
        Throw-CatalogGuardFailure 'path-outside-d' '受管路径必须位于 D 盘。'
    }
    $current = [IO.Path]::GetPathRoot($fullPath)
    $segments = $fullPath.Substring($current.Length).Split(@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if (-not [IO.File]::Exists($current) -and -not [IO.Directory]::Exists($current)) { continue }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-CatalogGuardFailure 'reparse-point' '受管路径包含 reparse point。'
        }
    }
    if ($RequireLeaf -and -not [IO.File]::Exists($fullPath) -and -not [IO.Directory]::Exists($fullPath)) {
        Throw-CatalogGuardFailure 'missing-path' '受管路径不存在。'
    }
    return $fullPath
}

function Assert-UniqueJsonProperties {
    param([Text.Json.JsonElement]$Element, [string]$Path = '$')

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) {
                Throw-CatalogGuardFailure 'malformed-json' "JSON 包含重复属性：$Path。"
            }
            Assert-UniqueJsonProperties -Element $property.Value -Path "$Path.$($property.Name)"
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-UniqueJsonProperties -Element $item -Path "$Path[$index]"
            $index++
        }
    }
}

function Read-StrictJsonDocument {
    param([string]$Text)

    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 128
    try {
        $document = [Text.Json.JsonDocument]::Parse($Text, $options)
        Assert-UniqueJsonProperties -Element $document.RootElement
        return $document
    } catch [CatalogGuardFailure] {
        throw
    } catch {
        Throw-CatalogGuardFailure 'malformed-json' 'JSON 解析失败。'
    }
}

function Resolve-PolicyPath {
    $defaultPath = Join-Path $PSScriptRoot 'policy.json'
    if ([string]::IsNullOrWhiteSpace($PolicyPath)) { return $defaultPath }
    if ([Environment]::GetEnvironmentVariable($testModeEnvironment) -cne '1') {
        Throw-CatalogGuardFailure 'policy-override-denied' '生产模式禁止覆盖 policy 路径。'
    }
    $fullPolicyPath = [IO.Path]::GetFullPath($PolicyPath)
    $expectedSource = 'D:\Codex\projects\统一环境\managed\remote-plugin-catalog-guard\policy.json'
    if ($fullPolicyPath.Equals($expectedSource, [StringComparison]::OrdinalIgnoreCase)) { return $expectedSource }
    if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
        Throw-CatalogGuardFailure 'policy-override-denied' 'fixture policy 路径不在 allowlist。'
    }
    $fullFixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
    $reportsRoot = 'D:\Codex\projects\统一环境\reports'
    $relative = [IO.Path]::GetRelativePath($reportsRoot, $fullFixtureRoot)
    $marker = Join-Path $fullFixtureRoot $fixtureMarkerName
    if (
        $relative -notmatch '^catalog-guard-tests-[0-9a-f]{32}\\\.codex$' -or
        -not [IO.File]::Exists($marker) -or
        [IO.File]::ReadAllText($marker, $utf8Strict) -cne $fixtureMarkerValue -or
        -not $fullPolicyPath.Equals((Join-Path $fullFixtureRoot 'policy.json'), [StringComparison]::OrdinalIgnoreCase)
    ) {
        Throw-CatalogGuardFailure 'policy-override-denied' 'fixture policy 路径不在 allowlist。'
    }
    return (Assert-NoReparsePath -Path $fullPolicyPath -RequireLeaf)
}

function Read-Policy {
    param([string]$Path)

    $fullPath = Assert-NoReparsePath -Path $Path -RequireLeaf
    $text = [IO.File]::ReadAllText($fullPath, $utf8Strict)
    $document = Read-StrictJsonDocument -Text $text
    try {
        $rootNames = @($document.RootElement.EnumerateObject() | ForEach-Object Name)
        $expectedRootNames = @('schemaVersion', 'catalogRoot', 'fileNamePattern', 'mutexName', 'stopEventName', 'scanIntervalSeconds', 'debounceMilliseconds', 'retryDelaysMilliseconds', 'targets')
        if (($rootNames -join "`0") -cne ($expectedRootNames -join "`0")) {
            Throw-CatalogGuardFailure 'policy-schema-drift' 'policy 根属性发生漂移。'
        }
    } finally {
        $document.Dispose()
    }
    $policy = $text | ConvertFrom-Json -Depth 32
    if ($policy.schemaVersion -ne 2 -or $policy.catalogRoot -cne $liveCatalogRoot -or $policy.fileNamePattern -cne '^[0-9a-f]{16}\.json$') {
        Throw-CatalogGuardFailure 'policy-schema-drift' 'policy 固定 schema 或 catalog capability 漂移。'
    }
    if ($policy.mutexName -cne 'CodexRemotePluginCatalogGuardV2' -or $policy.stopEventName -cne 'CodexRemotePluginCatalogGuardStopV2') {
        Throw-CatalogGuardFailure 'policy-schema-drift' 'policy 同步对象 identity 漂移。'
    }
    if ($policy.scanIntervalSeconds -lt 5 -or $policy.scanIntervalSeconds -gt 300 -or $policy.debounceMilliseconds -lt 100 -or $policy.debounceMilliseconds -gt 5000) {
        Throw-CatalogGuardFailure 'policy-schema-drift' 'policy 扫描节奏越出允许范围。'
    }
    $retryDelays = @($policy.retryDelaysMilliseconds)
    if ($retryDelays.Count -lt 1 -or @($retryDelays | Where-Object { $_ -lt 100 -or $_ -gt 60000 }).Count -ne 0) {
        Throw-CatalogGuardFailure 'policy-schema-drift' 'policy 重试节奏越出允许范围。'
    }
    $actualTargets = [ordered]@{}
    foreach ($target in @($policy.targets)) {
        if ($target.name -isnot [string] -or $target.id -isnot [string] -or $actualTargets.Contains($target.name)) {
            Throw-CatalogGuardFailure 'policy-schema-drift' 'policy target 形状或唯一性非法。'
        }
        $actualTargets[$target.name] = $target.id
    }
    if (($actualTargets.Count -ne $expectedTargets.Count) -or @($expectedTargets.Keys | Where-Object { -not $actualTargets.Contains($_) -or $actualTargets[$_] -cne $expectedTargets[$_] }).Count -ne 0) {
        Throw-CatalogGuardFailure 'policy-target-drift' 'policy 不再严格等于四组固定 name/id。'
    }
    return $policy
}

function Resolve-HandleIoSource {
    $deployed = Join-Path $PSScriptRoot 'CodexHookHandleBoundIO.cs'
    if ([IO.File]::Exists($deployed)) { return (Assert-NoReparsePath -Path $deployed -RequireLeaf) }
    if ([Environment]::GetEnvironmentVariable($testModeEnvironment) -ceq '1') {
        $source = 'D:\Codex\projects\统一环境\scripts\lib\CodexHookHandleBoundIO.cs'
        return (Assert-NoReparsePath -Path $source -RequireLeaf)
    }
    $canonicalSourceRoot = 'D:\Codex\projects\统一环境\managed\remote-plugin-catalog-guard'
    if ([IO.Path]::GetFullPath($PSScriptRoot).Equals($canonicalSourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $source = 'D:\Codex\projects\统一环境\scripts\lib\CodexHookHandleBoundIO.cs'
        return (Assert-NoReparsePath -Path $source -RequireLeaf)
    }
    Throw-CatalogGuardFailure 'runtime-dependency-missing' 'handle-bound runtime 依赖不存在。'
}

function Resolve-RuntimeScope {
    param([object]$Policy)

    if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $catalogRoot = Assert-NoReparsePath -Path $liveCatalogRoot -RequireLeaf
        return [pscustomobject][ordered]@{
            fixture = $false
            catalogRoot = $catalogRoot
            statePath = Join-Path $liveStateRoot 'state.json'
            logPath = $liveLogPath
            mutexName = [string]$Policy.mutexName
            stopEventName = [string]$Policy.stopEventName
        }
    }
    if ([Environment]::GetEnvironmentVariable($testModeEnvironment) -cne '1') {
        Throw-CatalogGuardFailure 'fixture-mode-denied' 'FixtureRoot 仅允许受控测试进程。'
    }
    $fullRoot = [IO.Path]::GetFullPath($FixtureRoot)
    $reportsRoot = 'D:\Codex\projects\统一环境\reports'
    $relative = [IO.Path]::GetRelativePath($reportsRoot, $fullRoot)
    if ($relative -notmatch '^catalog-guard-tests-[0-9a-f]{32}\\\.codex$') {
        Throw-CatalogGuardFailure 'fixture-root-denied' 'FixtureRoot 不符合固定 reports fixture 形状。'
    }
    $marker = Join-Path $fullRoot $fixtureMarkerName
    if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker, $utf8Strict) -cne $fixtureMarkerValue) {
        Throw-CatalogGuardFailure 'fixture-marker-invalid' 'FixtureRoot 缺少精确 marker。'
    }
    [void](Assert-NoReparsePath -Path $fullRoot -RequireLeaf)
    $catalogRoot = Assert-NoReparsePath -Path (Join-Path $fullRoot 'cache\remote_plugin_catalog') -RequireLeaf
    $scopeHash = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($fullRoot.ToLowerInvariant())
    return [pscustomobject][ordered]@{
        fixture = $true
        catalogRoot = $catalogRoot
        statePath = Join-Path $fullRoot 'state\state.json'
        logPath = Join-Path $fullRoot 'logs\guard.jsonl'
        mutexName = "CodexRemotePluginCatalogGuardFixture$($scopeHash.Substring(0, 24))"
        stopEventName = "CodexRemotePluginCatalogGuardFixtureStop$($scopeHash.Substring(0, 24))"
    }
}

function New-ParentDirectory {
    param([string]$Path)
    $parent = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [void](Assert-NoReparsePath -Path $parent -RequireLeaf)
}

function Write-AtomicText {
    param([string]$Path, [string]$Text)
    New-ParentDirectory -Path $Path
    $temp = Join-Path (Split-Path -Parent $Path) (".catalog-guard-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllText($temp, $Text, $utf8NoBom)
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Write-GuardLog {
    param([object]$Scope, [string]$Event, [hashtable]$Fields = @{})
    New-ParentDirectory -Path $Scope.logPath
    $record = [ordered]@{ schemaVersion = 1; timestampUtc = [DateTime]::UtcNow.ToString('o'); event = $Event }
    foreach ($key in @($Fields.Keys | Sort-Object)) { $record[$key] = $Fields[$key] }
    $line = ($record | ConvertTo-Json -Compress -Depth 16) + "`n"
    [IO.File]::AppendAllText($Scope.logPath, $line, $utf8NoBom)
}

function Get-SafeCatalogMetadata {
    param([string]$CatalogRoot, [string]$Path)
    $directoryGuard = $null
    $lease = $null
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CatalogRoot, $CatalogRoot, $false)
        $lease = $directoryGuard.AcquireTargetFileLease($Path)
        $item = [IO.FileInfo]::new($Path)
        $item.Refresh()
        return [pscustomobject][ordered]@{
            identity = "$($lease.VolumeSerialNumber):$($lease.FileIndex)"
            length = $item.Length
            lastWriteTicks = $item.LastWriteTimeUtc.Ticks
        }
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
}

function Get-SafeCatalogSnapshot {
    param([string]$CatalogRoot, [string]$Path)
    $directoryGuard = $null
    $lease = $null
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CatalogRoot, $CatalogRoot, $false)
        $lease = $directoryGuard.AcquireTargetFileLease($Path)
        [byte[]]$bytes = $lease.SnapshotBytes
        $bytesHash = Get-Sha256Hex -Bytes $bytes
        $handleHash = [Convert]::ToHexString($lease.ComputeSha256FromHandle()).ToLowerInvariant()
        if ($bytesHash -cne $handleHash) {
            Throw-CatalogGuardFailure 'catalog-hash-drift' 'catalog 在读取期间发生哈希漂移。'
        }
        return [pscustomobject][ordered]@{
            bytes = $bytes
            sha256 = $bytesHash
            identity = @([string]$lease.VolumeSerialNumber, [string]$lease.FileIndex)
        }
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
}

function New-CatalogReadLeaseSnapshot {
    param([object]$DirectoryGuard, [string]$Path)

    $lease = $null
    try {
        $lease = $DirectoryGuard.AcquireReadOnlyFileLease($Path)
        [byte[]]$bytes = $lease.SnapshotBytes
        $snapshot = [pscustomobject][ordered]@{
            bytes = $bytes
            sha256 = Get-Sha256Hex -Bytes $bytes
            identity = @([string]$lease.VolumeSerialNumber, [string]$lease.FileIndex)
            lease = $lease
        }
        $handleHash = [Convert]::ToHexString($lease.ComputeSha256FromHandle()).ToLowerInvariant()
        if ($snapshot.sha256 -cne $handleHash) {
            Throw-CatalogGuardFailure 'catalog-hash-drift' 'catalog lease 在读取期间发生哈希漂移。'
        }
        $lease = $null
        return $snapshot
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
    }
}

function Get-OptionalCatalogReadLeaseSnapshot {
    param([object]$DirectoryGuard, [string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try { return New-CatalogReadLeaseSnapshot -DirectoryGuard $DirectoryGuard -Path $Path } catch {
        if (-not [IO.File]::Exists($Path)) { return $null }
        throw
    }
}

function Assert-CatalogReadLeaseSnapshot {
    param([object]$LeaseSnapshot, [string]$ExpectedSha256, [string[]]$ExpectedIdentity)
    [byte[]]$bytes = $LeaseSnapshot.lease.ReadAllBytesFromHandle()
    $snapshot = [pscustomobject][ordered]@{
        sha256 = Get-Sha256Hex -Bytes $bytes
        identity = @([string]$LeaseSnapshot.lease.VolumeSerialNumber, [string]$LeaseSnapshot.lease.FileIndex)
    }
    Assert-CatalogTransactionSnapshot -Snapshot $snapshot -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
    $handleHash = [Convert]::ToHexString($LeaseSnapshot.lease.ComputeSha256FromHandle()).ToLowerInvariant()
    if ($handleHash -cne $ExpectedSha256) {
        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'canonical lease hash 已漂移。'
    }
}

function Invoke-FixturePrewriteMutation {
    param([object]$Scope, [string]$Path)
    if (-not $Scope.fixture) { return }
    $mutation = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MUTATION')
    if ([string]::IsNullOrWhiteSpace($mutation)) { return }
    switch ($mutation) {
        'hash-drift' {
            [IO.File]::AppendAllText($Path, " `n", $utf8NoBom)
        }
        'identity-drift' {
            $replacement = "$Path.fixture-replacement"
            [IO.File]::WriteAllBytes($replacement, [IO.File]::ReadAllBytes($Path))
            [IO.File]::Move($replacement, $Path, $true)
        }
        default { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture mutation 非法。' }
    }
}

function Get-FixtureMutationBytes {
    param([object]$Scope, [string]$EnvironmentName)
    if (-not $Scope.fixture) { return $null }
    $encoded = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($encoded)) { return $null }
    try { [byte[]]$bytes = [Convert]::FromBase64String($encoded) } catch {
        Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture mutation bytes 非法。'
    }
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 16777216) {
        Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture mutation bytes 越界。'
    }
    return $bytes
}

function Invoke-FixturePostIsolationMutation {
    param([object]$Scope, [string]$Path)
    if ($script:fixturePostIsolationMutationConsumed) { return }
    [byte[]]$bytes = Get-FixtureMutationBytes -Scope $Scope -EnvironmentName 'CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_POST_ISOLATION_BYTES_BASE64'
    if ($null -eq $bytes) { return }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $script:fixturePostIsolationMutationConsumed = $true
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-FixturePostprocessMutation {
    param([object]$Scope, [string]$Path)
    if ($script:fixturePostprocessMutationConsumed) { return }
    [byte[]]$bytes = Get-FixtureMutationBytes -Scope $Scope -EnvironmentName 'CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_POSTPROCESS_BYTES_BASE64'
    if ($null -eq $bytes) { return }
    $replacement = Join-Path $Scope.catalogRoot (".codex-catalog-guard-postprocess-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllBytes($replacement, $bytes)
        [IO.File]::Move($replacement, $Path, $true)
        $script:fixturePostprocessMutationConsumed = $true
    } finally {
        if ([IO.File]::Exists($replacement)) { [IO.File]::Delete($replacement) }
    }
}

function Invoke-FixtureMarkerCleanupReplacement {
    param([object]$Scope, [object]$DirectoryGuard, [string]$Path)
    if ($script:fixtureMarkerCleanupReplacementConsumed) { return }
    [byte[]]$bytes = Get-FixtureMutationBytes -Scope $Scope -EnvironmentName 'CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MARKER_CLEANUP_REPLACEMENT_BASE64'
    if ($null -eq $bytes) { return }
    $replacement = Join-Path $Scope.catalogRoot (".codex-catalog-guard-marker-replacement-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    $replacementFile = $null
    try {
        $replacementFile = $DirectoryGuard.CreateTempFile($replacement)
        $replacementFile.WriteAndFlush($bytes)
        $replacementFile.RenameTo($Path, $true)
        $script:fixtureMarkerCleanupReplacementConsumed = $true
    } finally {
        if ($null -ne $replacementFile) { $replacementFile.Dispose() }
        if ([IO.File]::Exists($replacement)) { [IO.File]::Delete($replacement) }
    }
}

function Get-CatalogTransactionInventory {
    param([object]$Scope)

    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $unknown = [Collections.Generic.List[object]]::new()
    $directoryGuard = $null
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($Scope.catalogRoot, $Scope.catalogRoot, $false)
        $paths = @([IO.Directory]::EnumerateFileSystemEntries($Scope.catalogRoot, "$managedTransactionArtifactPrefix*", [IO.SearchOption]::TopDirectoryOnly) | Sort-Object)
    } finally {
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
    foreach ($path in $paths) {
        $leaf = [IO.Path]::GetFileName($path)
        $canonicalLeaf = if ($leaf -match '^\.codex-catalog-guard-([0-9a-f]{16})(?:\.|$)') { "$(([string]$Matches[1]).ToLowerInvariant()).json" } else { $null }
        try {
            $attributes = [IO.File]::GetAttributes($path)
            $isRegularFile =
                ($attributes -band [IO.FileAttributes]::Directory) -eq 0 -and
                ($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
        } catch {
            $isRegularFile = $false
        }
        if (-not $isRegularFile) {
            $unknown.Add([pscustomobject][ordered]@{ file = $leaf; code = 'catalog-transaction-unknown-artifact'; canonicalLeaf = $canonicalLeaf })
            continue
        }
        $isStage = $false
        if ($leaf -cmatch $managedTransactionArtifactPattern) {
            $stem = [string]$Matches[1]
            $kind = [string]$Matches[2]
        } elseif ($leaf -cmatch $managedStagingArtifactPattern) {
            $stem = [string]$Matches[1]
            $kind = [string]$Matches[3]
            $isStage = $true
        } else {
            $unknown.Add([pscustomobject][ordered]@{ file = $leaf; code = 'catalog-transaction-unknown-artifact'; canonicalLeaf = $canonicalLeaf })
            continue
        }
        if (-not $groups.ContainsKey($stem)) {
            $groups[$stem] = [pscustomobject][ordered]@{
                stem = $stem
                canonicalLeaf = "$stem.json"
                txnPath = $null
                publishPath = $null
                quarantinePath = $null
                vendorAbortPath = $null
                stageTxnPath = $null
                stagePublishPath = $null
                stageVendorAbortPath = $null
                stageConflict = $false
            }
        }
        if ($isStage) {
            $propertyName = if ($kind -ceq 'vendor-abort') { 'stageVendorAbortPath' } else { "stage$([char]::ToUpperInvariant($kind[0]))$($kind.Substring(1))Path" }
            if ($null -ne $groups[$stem].$propertyName) { $groups[$stem].stageConflict = $true } else { $groups[$stem].$propertyName = $path }
        } else {
            $propertyName = if ($kind -ceq 'vendor-abort') { 'vendorAbortPath' } else { "${kind}Path" }
            $groups[$stem].$propertyName = $path
        }
    }
    return [pscustomobject][ordered]@{ groups = @($groups.Values | Sort-Object stem); unknown = @($unknown) }
}

function Get-CatalogTransactionAuditBlocks {
    param([object]$Scope)

    $inventory = Get-CatalogTransactionInventory -Scope $Scope
    $blocked = [Collections.Generic.List[object]]::new()
    foreach ($entry in $inventory.unknown) {
        $blocked.Add([pscustomobject][ordered]@{ file = $entry.file; code = $entry.code })
    }
    foreach ($group in $inventory.groups) {
        $code = 'catalog-transaction-pending'
        if ($null -ne $group.vendorAbortPath) {
            try { [void](Read-VendorAbortDefinition -Scope $Scope -Stem $group.stem -AbortPath $group.vendorAbortPath) } catch {
                $code = Get-GuardFailureCode -Exception $_.Exception
            }
        } elseif ($null -eq $group.txnPath) {
            $code = 'catalog-transaction-unknown-artifact'
        } else {
            try { [void](Read-CatalogTransactionDefinition -Scope $Scope -Stem $group.stem -TxnPath $group.txnPath) } catch {
                $code = Get-GuardFailureCode -Exception $_.Exception
            }
        }
        $blocked.Add([pscustomobject][ordered]@{ file = $group.canonicalLeaf; code = $code })
    }
    return @($blocked)
}

function Invoke-FixtureAfterQuarantineFault {
    param([object]$Scope)
    if (-not $Scope.fixture) { return }

    $interrupt = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_INTERRUPT_AFTER_QUARANTINE')
    if (-not [string]::IsNullOrWhiteSpace($interrupt)) {
        if ($interrupt -cne '1') { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture interrupt 值非法。' }
        [Environment]::Exit(86)
    }
}

function Invoke-FixturePublishFailure {
    param([object]$Scope)
    if (-not $Scope.fixture) { return }
    $publishFailure = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_PUBLISH_FAILURE')
    if ([string]::IsNullOrWhiteSpace($publishFailure)) { return }
    if ($publishFailure -cne 'io') { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture publish failure 值非法。' }
    Throw-CatalogGuardFailure 'catalog-publish-io-failure' 'fixture 注入 publish I/O failure。'
}

function Invoke-FixtureStagingFault {
    param(
        [object]$Scope,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind,
        [ValidateSet('after-create', 'mid-write', 'after-flush')][string]$Point
    )
    if (-not $Scope.fixture) { return }
    $fault = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_STAGE_EXIT')
    if ([string]::IsNullOrWhiteSpace($fault)) { return }
    $allowed = @(
        'txn:after-create', 'txn:mid-write', 'txn:after-flush',
        'publish:after-create', 'publish:mid-write', 'publish:after-flush',
        'vendor-abort:after-create', 'vendor-abort:mid-write', 'vendor-abort:after-flush'
    )
    if ($fault -cnotin $allowed) { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture staging fault 值非法。' }
    if ($fault -ceq "${ArtifactKind}:$Point") { [Environment]::Exit(87) }
}

function Invoke-FixtureVendorAbortFault {
    param(
        [object]$Scope,
        [ValidateSet('after-phase', 'after-quarantine-delete', 'after-publish-delete', 'after-txn-delete', 'after-abort-delete')][string]$Point
    )
    if (-not $Scope.fixture) { return }
    $fault = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_VENDOR_ABORT_EXIT')
    if ([string]::IsNullOrWhiteSpace($fault)) { return }
    $allowed = @('after-phase', 'after-quarantine-delete', 'after-publish-delete', 'after-txn-delete', 'after-abort-delete')
    if ($fault -cnotin $allowed) { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture vendor-abort fault 值非法。' }
    if ($fault -ceq $Point) { [Environment]::Exit(88) }
}

function Invoke-FixtureDurablePublicationPoint {
    param(
        [object]$Scope,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind,
        [ValidateSet('after-clear', 'after-rename', 'after-second-open')][string]$Point
    )
    if (-not $Scope.fixture) { return }
    $fault = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DURABLE_RENAME_EXIT')
    $pause = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DURABLE_RENAME_PAUSE')
    if ([string]::IsNullOrWhiteSpace($fault) -and [string]::IsNullOrWhiteSpace($pause)) { return }
    $allowed = foreach ($kind in @('txn', 'publish', 'vendor-abort')) {
        foreach ($name in @('after-clear', 'after-rename', 'after-second-open')) { "${kind}:$name" }
    }
    if (-not [string]::IsNullOrWhiteSpace($fault) -and $fault -cnotin $allowed) { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture durable rename fault 值非法。' }
    if (-not [string]::IsNullOrWhiteSpace($pause) -and $pause -cnotin $allowed) { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture durable rename pause 值非法。' }
    if ($fault -ceq "${ArtifactKind}:$Point") { [Environment]::Exit(89) }
    if ($pause -cne "${ArtifactKind}:$Point") { return }

    $stateRoot = Split-Path -Parent $Scope.statePath
    [void][IO.Directory]::CreateDirectory($stateRoot)
    $readyPath = Join-Path $stateRoot 'durable-publication.ready'
    $releasePath = Join-Path $stateRoot 'durable-publication.release'
    [IO.File]::WriteAllText($readyPath, "$pause`n", $utf8NoBom)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($releasePath) -and $stopwatch.ElapsedMilliseconds -lt 30000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not [IO.File]::Exists($releasePath) -or [IO.File]::ReadAllText($releasePath, $utf8Strict).Trim() -cne $pause) {
        Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture durable publication release 超时或内容非法。'
    }
    [IO.File]::Delete($releasePath)
    [IO.File]::Delete($readyPath)
}

function Invoke-FixtureCanonicalLeasePoint {
    param([object]$Scope, [string]$Point)
    if (-not $Scope.fixture) { return }
    $pause = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_CANONICAL_LEASE_PAUSE')
    if ([string]::IsNullOrWhiteSpace($pause)) { return }
    $allowed = @(
        'normal-publish:before-quarantine-delete',
        'normal-publish:before-txn-delete',
        'restart-publish:before-quarantine-delete',
        'restart-publish:before-txn-delete',
        'rollback:before-publish-delete',
        'rollback:before-txn-delete',
        'vendor-abort:before-quarantine-delete',
        'vendor-abort:before-publish-delete',
        'vendor-abort:before-txn-delete',
        'vendor-abort:before-abort-delete'
    )
    if ($pause -cnotin $allowed) { Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture canonical lease pause 值非法。' }
    if ($pause -cne $Point) { return }

    $stateRoot = Split-Path -Parent $Scope.statePath
    [void][IO.Directory]::CreateDirectory($stateRoot)
    $readyPath = Join-Path $stateRoot 'canonical-lease.ready'
    $releasePath = Join-Path $stateRoot 'canonical-lease.release'
    [IO.File]::WriteAllText($readyPath, "$Point`n", $utf8NoBom)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($releasePath) -and $stopwatch.ElapsedMilliseconds -lt 30000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not [IO.File]::Exists($releasePath) -or [IO.File]::ReadAllText($releasePath, $utf8Strict).Trim() -cne $Point) {
        Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture canonical lease release 超时或内容非法。'
    }
    [IO.File]::Delete($releasePath)
    [IO.File]::Delete($readyPath)
}

function New-DurableStagedArtifactFile {
    param(
        [object]$Scope,
        [string]$FinalPath,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind
    )
    $finalLeaf = [IO.Path]::GetFileName($FinalPath)
    if ($finalLeaf -cnotmatch '^\.codex-catalog-guard-([0-9a-f]{16})\.(txn|publish|vendor-abort)$' -or [string]$Matches[2] -cne $ArtifactKind) {
        Throw-CatalogGuardFailure 'unsupported-catalog-path' 'staging 最终名称非法。'
    }
    $stem = [string]$Matches[1]
    $stageLeaf = ".codex-catalog-guard-$stem.stage-$([guid]::NewGuid().ToString('N')).$ArtifactKind"
    $stagePath = Join-Path ([IO.Path]::GetDirectoryName($FinalPath)) $stageLeaf
    $file = $null
    try {
        $file = [CodexCatalogGuard.DurableStagedFile]::Create($stagePath)
        Invoke-FixtureStagingFault -Scope $Scope -ArtifactKind $ArtifactKind -Point 'after-create'
        $result = $file
        $file = $null
        return $result
    } catch {
        if ($null -ne $file) { $file.Dispose() }
        throw
    }
}

function Write-DurableStagedArtifactFile {
    param(
        [object]$Scope,
        [object]$File,
        [byte[]]$Bytes,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind
    )
    if ($Bytes.Length -eq 0) { Throw-CatalogGuardFailure 'catalog-transaction-invalid' 'staging 内容为空。' }
    $firstCount = [Math]::Max(1, [int][Math]::Floor($Bytes.Length / 2))
    $File.Write($Bytes, 0, $firstCount)
    Invoke-FixtureStagingFault -Scope $Scope -ArtifactKind $ArtifactKind -Point 'mid-write'
    if ($firstCount -lt $Bytes.Length) { $File.Write($Bytes, $firstCount, $Bytes.Length - $firstCount) }
    $File.Flush()
    Invoke-FixtureStagingFault -Scope $Scope -ArtifactKind $ArtifactKind -Point 'after-flush'
    $sealFailure = $null
    if ($Scope.fixture) {
        $configuredSealFailure = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_SEAL_FAILURE')
        if (-not [string]::IsNullOrWhiteSpace($configuredSealFailure)) {
            $allowedSealFailures = foreach ($kind in @('txn', 'publish', 'vendor-abort')) {
                foreach ($point in @('nt-set-ea', 'flush-file-buffers')) { "${kind}:$point" }
            }
            if ($configuredSealFailure -cnotin $allowedSealFailures) {
                Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture integrity seal failure 值非法。'
            }
            if ($configuredSealFailure.StartsWith("${ArtifactKind}:", [StringComparison]::Ordinal)) {
                $sealFailure = $configuredSealFailure.Substring($ArtifactKind.Length + 1)
            }
        }
    }
    $File.SealIntegrityAnchor($ArtifactKind, (Get-Sha256Hex -Bytes $Bytes), $sealFailure)
}

function Complete-DurableStagedArtifactPublication {
    param(
        [object]$Scope,
        [object]$File,
        [string]$FinalPath,
        [byte[]]$Bytes,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind
    )
    $File.ClearDeleteOnCloseForPublication()
    Invoke-FixtureDurablePublicationPoint -Scope $Scope -ArtifactKind $ArtifactKind -Point 'after-clear'
    $File.BeginRenameTo($FinalPath, $false)
    Invoke-FixtureDurablePublicationPoint -Scope $Scope -ArtifactKind $ArtifactKind -Point 'after-rename'
    $File.VerifyPendingPublication()
    Invoke-FixtureDurablePublicationPoint -Scope $Scope -ArtifactKind $ArtifactKind -Point 'after-second-open'
    $File.FinalizePublication()
    $publishedSnapshot = [pscustomobject][ordered]@{
        sha256 = Get-Sha256Hex -Bytes $File.ReadAllBytesFromHandle()
        identity = @([string]$File.VolumeSerialNumber, [string]$File.FileIndex)
    }
    Assert-CatalogTransactionSnapshot -Snapshot $publishedSnapshot -ExpectedSha256 (Get-Sha256Hex -Bytes $Bytes) -ExpectedIdentity $publishedSnapshot.identity
    return $publishedSnapshot
}

function Publish-DurableStagedArtifact {
    param(
        [object]$Scope,
        [object]$DirectoryGuard,
        [string]$FinalPath,
        [byte[]]$Bytes,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind
    )
    $file = $null
    try {
        $file = New-DurableStagedArtifactFile -Scope $Scope -FinalPath $FinalPath -ArtifactKind $ArtifactKind
        Write-DurableStagedArtifactFile -Scope $Scope -File $file -Bytes $Bytes -ArtifactKind $ArtifactKind
        [void](Complete-DurableStagedArtifactPublication -Scope $Scope -File $file -FinalPath $FinalPath -Bytes $Bytes -ArtifactKind $ArtifactKind)
        $result = $file
        $file = $null
        return $result
    } finally {
        if ($null -ne $file) { $file.Dispose() }
    }
}

function New-CatalogTransactionDefinition {
    param(
        [string]$CatalogRoot,
        [string]$CanonicalLeaf,
        [string]$BeforeSha256,
        [string[]]$BeforeIdentity,
        [string]$AfterSha256,
        [string[]]$TxnIdentity,
        [string[]]$PublishIdentity
    )
    $stem = [IO.Path]::GetFileNameWithoutExtension($CanonicalLeaf)
    if ($CanonicalLeaf -cne "$stem.json" -or $stem -cnotmatch '^[0-9a-f]{16}$') {
        Throw-CatalogGuardFailure 'unsupported-catalog-path' '事务 canonical 名称非法。'
    }
    $txnLeaf = ".codex-catalog-guard-$stem.txn"
    $publishLeaf = ".codex-catalog-guard-$stem.publish"
    $quarantineLeaf = ".codex-catalog-guard-$stem.quarantine"
    $vendorAbortLeaf = ".codex-catalog-guard-$stem.vendor-abort"
    $hasBindings = @($TxnIdentity).Count -eq 2 -and @($PublishIdentity).Count -eq 2
    if ((@($TxnIdentity).Count -ne 0 -or @($PublishIdentity).Count -ne 0) -and -not $hasBindings) {
        Throw-CatalogGuardFailure 'catalog-transaction-invalid' '事务 identity binding 不完整。'
    }
    $markerBytes = $null
    if ($hasBindings) {
        $marker = [ordered]@{
            schemaVersion = 2
            canonicalLeaf = $CanonicalLeaf
            quarantineLeaf = $quarantineLeaf
            publishLeaf = $publishLeaf
            beforeSha256 = $BeforeSha256
            beforeIdentity = @($BeforeIdentity)
            afterSha256 = $AfterSha256
            txnIdentity = @($TxnIdentity)
            publishIdentity = @($PublishIdentity)
        }
        $markerBytes = $utf8NoBom.GetBytes(($marker | ConvertTo-Json -Depth 8) + "`n")
    }
    return [pscustomobject][ordered]@{
        stem = $stem
        canonicalLeaf = $CanonicalLeaf
        canonicalPath = Join-Path $CatalogRoot $CanonicalLeaf
        txnLeaf = $txnLeaf
        txnPath = Join-Path $CatalogRoot $txnLeaf
        publishLeaf = $publishLeaf
        publishPath = Join-Path $CatalogRoot $publishLeaf
        quarantineLeaf = $quarantineLeaf
        quarantinePath = Join-Path $CatalogRoot $quarantineLeaf
        vendorAbortLeaf = $vendorAbortLeaf
        vendorAbortPath = Join-Path $CatalogRoot $vendorAbortLeaf
        beforeSha256 = $BeforeSha256
        beforeIdentity = @($BeforeIdentity)
        afterSha256 = $AfterSha256
        txnIdentity = @($TxnIdentity)
        publishIdentity = @($PublishIdentity)
        markerBytes = $markerBytes
    }
}

function New-VendorAbortDefinition {
    param([object]$Transaction, [object]$VendorSnapshot, [string[]]$VendorAbortIdentity)

    if (
        @($Transaction.txnIdentity).Count -ne 2 -or
        @($Transaction.publishIdentity).Count -ne 2 -or
        $Transaction.txnSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $VendorSnapshot.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        @($VendorSnapshot.identity).Count -ne 2 -or
        @($VendorAbortIdentity).Count -ne 2
    ) {
        Throw-CatalogGuardFailure 'catalog-transaction-invalid' 'vendor-abort 缺少 handle-bound binding。'
    }
    $marker = [ordered]@{
        schemaVersion = 2
        phase = 'vendor-abort'
        canonicalLeaf = $Transaction.canonicalLeaf
        txnLeaf = $Transaction.txnLeaf
        publishLeaf = $Transaction.publishLeaf
        quarantineLeaf = $Transaction.quarantineLeaf
        vendorAbortLeaf = $Transaction.vendorAbortLeaf
        beforeSha256 = $Transaction.beforeSha256
        beforeIdentity = @($Transaction.beforeIdentity)
        afterSha256 = $Transaction.afterSha256
        publishIdentity = @($Transaction.publishIdentity)
        txnSha256 = $Transaction.txnSha256
        txnIdentity = @($Transaction.txnIdentity)
        vendorSha256 = $VendorSnapshot.sha256
        vendorIdentity = @($VendorSnapshot.identity)
        vendorAbortIdentity = @($VendorAbortIdentity)
    }
    return [pscustomobject][ordered]@{
        stem = $Transaction.stem
        canonicalLeaf = $Transaction.canonicalLeaf
        canonicalPath = $Transaction.canonicalPath
        txnLeaf = $Transaction.txnLeaf
        txnPath = $Transaction.txnPath
        publishLeaf = $Transaction.publishLeaf
        publishPath = $Transaction.publishPath
        quarantineLeaf = $Transaction.quarantineLeaf
        quarantinePath = $Transaction.quarantinePath
        vendorAbortLeaf = $Transaction.vendorAbortLeaf
        vendorAbortPath = $Transaction.vendorAbortPath
        beforeSha256 = $Transaction.beforeSha256
        beforeIdentity = @($Transaction.beforeIdentity)
        afterSha256 = $Transaction.afterSha256
        publishIdentity = @($Transaction.publishIdentity)
        txnSha256 = $Transaction.txnSha256
        txnIdentity = @($Transaction.txnIdentity)
        vendorSha256 = $VendorSnapshot.sha256
        vendorIdentity = @($VendorSnapshot.identity)
        vendorAbortIdentity = @($VendorAbortIdentity)
        markerBytes = $utf8NoBom.GetBytes(($marker | ConvertTo-Json -Depth 8) + "`n")
    }
}

function Publish-DurableVendorAbortPhase {
    param([object]$Scope, [object]$Transaction, [object]$VendorSnapshot)

    $file = $null
    try {
        $file = New-DurableStagedArtifactFile -Scope $Scope -FinalPath $Transaction.vendorAbortPath -ArtifactKind 'vendor-abort'
        $identity = @([string]$file.VolumeSerialNumber, [string]$file.FileIndex)
        $definition = New-VendorAbortDefinition -Transaction $Transaction -VendorSnapshot $VendorSnapshot -VendorAbortIdentity $identity
        Write-DurableStagedArtifactFile -Scope $Scope -File $file -Bytes $definition.markerBytes -ArtifactKind 'vendor-abort'
        [void](Complete-DurableStagedArtifactPublication -Scope $Scope -File $file -FinalPath $definition.vendorAbortPath -Bytes $definition.markerBytes -ArtifactKind 'vendor-abort')
        $definition | Add-Member -NotePropertyName vendorAbortSha256 -NotePropertyValue (Get-Sha256Hex -Bytes $file.ReadAllBytesFromHandle())
        Assert-CatalogTransactionSnapshot -Snapshot ([pscustomobject]@{ sha256 = $definition.vendorAbortSha256; identity = @($definition.vendorAbortIdentity) }) -ExpectedSha256 (Get-Sha256Hex -Bytes $definition.markerBytes) -ExpectedIdentity $definition.vendorAbortIdentity
        return [pscustomobject][ordered]@{ definition = $definition; file = $file }
    } catch {
        if ($null -ne $file) { $file.Dispose() }
        throw
    }
}

function Read-StrictTransactionIdentity {
    param([Text.Json.JsonElement]$Element, [string]$Name)

    $identityElement = $Element.GetProperty($Name)
    if ($identityElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw "$Name 非 array。" }
    $values = @($identityElement.EnumerateArray())
    if ($values.Count -ne 2) { throw "$Name 长度非法。" }
    $identity = [Collections.Generic.List[string]]::new()
    foreach ($value in $values) {
        if ($value.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw "$Name 元素非 string。" }
        $text = $value.GetString()
        if ($text -cnotmatch '^[0-9a-f]+$') { throw "$Name 元素非法。" }
        $identity.Add($text)
    }
    return @($identity)
}

function Get-AnchoredTransactionSnapshot {
    param(
        [string]$Path,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind
    )
    try {
        $snapshot = [CodexCatalogGuard.DurableStagedFile]::ReadIntegritySnapshot($Path)
    } catch {
        Throw-CatalogGuardFailure 'catalog-transaction-conflict' "受管 $ArtifactKind artifact 的 NTFS integrity anchor 无效。"
    }
    if ([string]$snapshot.Kind -cne $ArtifactKind) {
        Throw-CatalogGuardFailure 'catalog-transaction-conflict' "受管 $ArtifactKind artifact 的 NTFS integrity kind 不匹配。"
    }
    return [pscustomobject][ordered]@{
        bytes = [byte[]]$snapshot.Bytes
        sha256 = [string]$snapshot.Sha256
        identity = @([string]$snapshot.VolumeSerialNumber, [string]$snapshot.FileIndex)
    }
}

function Get-OptionalAnchoredTransactionSnapshot {
    param(
        [string]$Path,
        [ValidateSet('txn', 'publish', 'vendor-abort')][string]$ArtifactKind
    )
    if (-not [IO.File]::Exists($Path)) { return $null }
    try { return Get-AnchoredTransactionSnapshot -Path $Path -ArtifactKind $ArtifactKind } catch {
        if (-not [IO.File]::Exists($Path)) { return $null }
        throw
    }
}

function Read-VendorAbortDefinition {
    param([object]$Scope, [string]$Stem, [string]$AbortPath)

    try {
        $snapshot = Get-AnchoredTransactionSnapshot -Path $AbortPath -ArtifactKind 'vendor-abort'
        $text = $utf8Strict.GetString($snapshot.bytes)
        $document = Read-StrictJsonDocument -Text $text
        try {
            $root = $document.RootElement
            if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'vendor-abort marker root 非 object。' }
            $names = @($root.EnumerateObject() | ForEach-Object Name)
            $expectedNames = @(
                'schemaVersion', 'phase', 'canonicalLeaf', 'txnLeaf', 'publishLeaf', 'quarantineLeaf', 'vendorAbortLeaf',
                'beforeSha256', 'beforeIdentity', 'afterSha256', 'publishIdentity', 'txnSha256', 'txnIdentity', 'vendorSha256', 'vendorIdentity', 'vendorAbortIdentity'
            )
            if (($names -join "`0") -cne ($expectedNames -join "`0")) { throw 'vendor-abort marker 属性漂移。' }
            $schemaVersionElement = $root.GetProperty('schemaVersion')
            $schemaVersion = 0
            if ($schemaVersionElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $schemaVersionElement.TryGetInt32([ref]$schemaVersion) -or $schemaVersion -ne 2) {
                throw 'vendor-abort schemaVersion 非精确整数 2。'
            }
            foreach ($name in @('phase', 'canonicalLeaf', 'txnLeaf', 'publishLeaf', 'quarantineLeaf', 'vendorAbortLeaf', 'beforeSha256', 'afterSha256', 'txnSha256', 'vendorSha256')) {
                if ($root.GetProperty($name).ValueKind -ne [Text.Json.JsonValueKind]::String) { throw "vendor-abort $name 非 string。" }
            }
            $canonicalLeaf = "$Stem.json"
            $txnLeaf = ".codex-catalog-guard-$Stem.txn"
            $publishLeaf = ".codex-catalog-guard-$Stem.publish"
            $quarantineLeaf = ".codex-catalog-guard-$Stem.quarantine"
            $vendorAbortLeaf = ".codex-catalog-guard-$Stem.vendor-abort"
            $phase = $root.GetProperty('phase').GetString()
            $markerCanonicalLeaf = $root.GetProperty('canonicalLeaf').GetString()
            $markerTxnLeaf = $root.GetProperty('txnLeaf').GetString()
            $markerPublishLeaf = $root.GetProperty('publishLeaf').GetString()
            $markerQuarantineLeaf = $root.GetProperty('quarantineLeaf').GetString()
            $markerVendorAbortLeaf = $root.GetProperty('vendorAbortLeaf').GetString()
            $beforeSha256 = $root.GetProperty('beforeSha256').GetString()
            $afterSha256 = $root.GetProperty('afterSha256').GetString()
            $txnSha256 = $root.GetProperty('txnSha256').GetString()
            $vendorSha256 = $root.GetProperty('vendorSha256').GetString()
            if (
                $phase -cne 'vendor-abort' -or
                $markerCanonicalLeaf -cne $canonicalLeaf -or
                $markerTxnLeaf -cne $txnLeaf -or
                $markerPublishLeaf -cne $publishLeaf -or
                $markerQuarantineLeaf -cne $quarantineLeaf -or
                $markerVendorAbortLeaf -cne $vendorAbortLeaf -or
                $beforeSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $afterSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $txnSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $vendorSha256 -cnotmatch '^[0-9a-f]{64}$'
            ) {
                throw 'vendor-abort marker 值非法。'
            }
            $beforeIdentity = Read-StrictTransactionIdentity -Element $root -Name 'beforeIdentity'
            $publishIdentity = Read-StrictTransactionIdentity -Element $root -Name 'publishIdentity'
            $txnIdentity = Read-StrictTransactionIdentity -Element $root -Name 'txnIdentity'
            $vendorIdentity = Read-StrictTransactionIdentity -Element $root -Name 'vendorIdentity'
            $vendorAbortIdentity = Read-StrictTransactionIdentity -Element $root -Name 'vendorAbortIdentity'
        } finally {
            $document.Dispose()
        }
        $result = [pscustomobject][ordered]@{
            stem = $Stem
            canonicalLeaf = $canonicalLeaf
            canonicalPath = Join-Path $Scope.catalogRoot $canonicalLeaf
            txnLeaf = $txnLeaf
            txnPath = Join-Path $Scope.catalogRoot $txnLeaf
            publishLeaf = $publishLeaf
            publishPath = Join-Path $Scope.catalogRoot $publishLeaf
            quarantineLeaf = $quarantineLeaf
            quarantinePath = Join-Path $Scope.catalogRoot $quarantineLeaf
            vendorAbortLeaf = $vendorAbortLeaf
            vendorAbortPath = Join-Path $Scope.catalogRoot $vendorAbortLeaf
            beforeSha256 = $beforeSha256
            beforeIdentity = @($beforeIdentity)
            afterSha256 = $afterSha256
            publishIdentity = @($publishIdentity)
            txnSha256 = $txnSha256
            txnIdentity = @($txnIdentity)
            vendorSha256 = $vendorSha256
            vendorIdentity = @($vendorIdentity)
            vendorAbortSha256 = $snapshot.sha256
            vendorAbortIdentity = @($vendorAbortIdentity)
        }
        if (-not (Test-CatalogSnapshotIdentity -Snapshot $snapshot -ExpectedIdentity $vendorAbortIdentity)) {
            Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'vendor-abort marker identity 与首次 staging binding 不匹配。'
        }
        return $result
    } catch [CatalogGuardFailure] {
        if ($_.Exception.FailureCode -in @('catalog-transaction-invalid', 'catalog-transaction-conflict')) { throw }
        Throw-CatalogGuardFailure 'catalog-transaction-invalid' '受管 vendor-abort marker 无效。'
    } catch {
        Throw-CatalogGuardFailure 'catalog-transaction-invalid' '受管 vendor-abort marker 无效。'
    }
}

function Read-CatalogTransactionDefinition {
    param([object]$Scope, [string]$Stem, [string]$TxnPath)

    try {
        $snapshot = Get-AnchoredTransactionSnapshot -Path $TxnPath -ArtifactKind 'txn'
        $text = $utf8Strict.GetString($snapshot.bytes)
        $document = Read-StrictJsonDocument -Text $text
        try {
            $root = $document.RootElement
            if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'transaction marker root 非 object。' }
            $names = @($root.EnumerateObject() | ForEach-Object Name)
            $expectedNames = @('schemaVersion', 'canonicalLeaf', 'quarantineLeaf', 'publishLeaf', 'beforeSha256', 'beforeIdentity', 'afterSha256', 'txnIdentity', 'publishIdentity')
            if (($names -join "`0") -cne ($expectedNames -join "`0")) { throw 'transaction marker 属性漂移。' }
            $schemaVersionElement = $root.GetProperty('schemaVersion')
            $schemaVersion = 0
            if ($schemaVersionElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $schemaVersionElement.TryGetInt32([ref]$schemaVersion) -or $schemaVersion -ne 2) {
                throw 'transaction marker schemaVersion 非精确整数 2。'
            }
            foreach ($name in @('canonicalLeaf', 'quarantineLeaf', 'publishLeaf', 'beforeSha256', 'afterSha256')) {
                if ($root.GetProperty($name).ValueKind -ne [Text.Json.JsonValueKind]::String) { throw "transaction marker $name 非 string。" }
            }
            $canonicalLeaf = $root.GetProperty('canonicalLeaf').GetString()
            $quarantineLeaf = $root.GetProperty('quarantineLeaf').GetString()
            $publishLeaf = $root.GetProperty('publishLeaf').GetString()
            $beforeSha256 = $root.GetProperty('beforeSha256').GetString()
            $afterSha256 = $root.GetProperty('afterSha256').GetString()
            $beforeIdentity = Read-StrictTransactionIdentity -Element $root -Name 'beforeIdentity'
            $txnIdentity = Read-StrictTransactionIdentity -Element $root -Name 'txnIdentity'
            $publishIdentity = Read-StrictTransactionIdentity -Element $root -Name 'publishIdentity'
        } finally {
            $document.Dispose()
        }
        $definition = New-CatalogTransactionDefinition -CatalogRoot $Scope.catalogRoot -CanonicalLeaf "$Stem.json" -BeforeSha256 $beforeSha256 -BeforeIdentity $beforeIdentity -AfterSha256 $afterSha256 -TxnIdentity $txnIdentity -PublishIdentity $publishIdentity
        if (
            $canonicalLeaf -cne $definition.canonicalLeaf -or
            $quarantineLeaf -cne $definition.quarantineLeaf -or
            $publishLeaf -cne $definition.publishLeaf -or
            $beforeSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $afterSha256 -cnotmatch '^[0-9a-f]{64}$'
        ) {
            throw 'transaction marker 值非法。'
        }
        if (-not (Test-CatalogSnapshotIdentity -Snapshot $snapshot -ExpectedIdentity $definition.txnIdentity)) {
            Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'transaction marker identity 与首次 staging binding 不匹配。'
        }
        $definition | Add-Member -NotePropertyName txnSha256 -NotePropertyValue $snapshot.sha256
        return $definition
    } catch [CatalogGuardFailure] {
        if ($_.Exception.FailureCode -in @('catalog-transaction-invalid', 'catalog-transaction-conflict')) { throw }
        Throw-CatalogGuardFailure 'catalog-transaction-invalid' '受管 transaction marker 无效。'
    } catch {
        Throw-CatalogGuardFailure 'catalog-transaction-invalid' '受管 transaction marker 无效。'
    }
}

function Get-OptionalCatalogSnapshot {
    param([string]$CatalogRoot, [string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try { return Get-SafeCatalogSnapshot -CatalogRoot $CatalogRoot -Path $Path } catch {
        if (-not [IO.File]::Exists($Path)) { return $null }
        throw
    }
}

function Test-CatalogSnapshotIdentity {
    param([object]$Snapshot, [string[]]$ExpectedIdentity)
    return (
        $null -ne $Snapshot -and
        @($ExpectedIdentity).Count -eq 2 -and
        [string]$Snapshot.identity[0] -ceq [string]$ExpectedIdentity[0] -and
        [string]$Snapshot.identity[1] -ceq [string]$ExpectedIdentity[1]
    )
}

function Assert-CatalogTransactionSnapshot {
    param([object]$Snapshot, [string]$ExpectedSha256, [string[]]$ExpectedIdentity)
    if ($null -eq $Snapshot -or $Snapshot.sha256 -cne $ExpectedSha256) {
        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'transaction 文件内容不匹配。'
    }
    if ($null -ne $ExpectedIdentity -and -not (Test-CatalogSnapshotIdentity -Snapshot $Snapshot -ExpectedIdentity $ExpectedIdentity)) {
        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'transaction 文件身份不匹配。'
    }
}

function Get-NativeWin32ErrorCode {
    param([Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [ComponentModel.Win32Exception]) { return [int]$current.NativeErrorCode }
        $current = $current.InnerException
    }
    return $null
}

function Open-GuardedTransactionFileWithRetry {
    param([object]$Scope, [object]$DirectoryGuard, [string]$Path)

    $sharingRetryDelaysMilliseconds = @(25, 50, 100, 200, 400)
    for ($attempt = 0; ; $attempt++) {
        $fixtureBlocker = $null
        try {
            if ($Scope.fixture -and -not $script:fixtureTransientSharingFailureConsumed) {
                $configuredArtifact = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_TRANSIENT_SHARING_FAILURE')
                if (-not [string]::IsNullOrWhiteSpace($configuredArtifact)) {
                    if ($configuredArtifact -cnotin @('txn', 'publish', 'quarantine', 'vendor-abort')) {
                        Throw-CatalogGuardFailure 'fixture-mutation-invalid' 'fixture transient sharing failure 值非法。'
                    }
                    if ([IO.Path]::GetFileName($Path).EndsWith(".$configuredArtifact", [StringComparison]::Ordinal)) {
                        $fixtureBlocker = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                        $script:fixtureTransientSharingFailureConsumed = $true
                    }
                }
            }
            try {
                return $DirectoryGuard.AcquirePreparedTempFile($Path)
            } finally {
                if ($null -ne $fixtureBlocker) { $fixtureBlocker.Dispose() }
            }
        } catch {
            $nativeErrorCode = Get-NativeWin32ErrorCode -Exception $_.Exception
            if ($nativeErrorCode -notin @(32, 33) -or $attempt -ge $sharingRetryDelaysMilliseconds.Count) { throw }
            $delayMilliseconds = $sharingRetryDelaysMilliseconds[$attempt]
            Write-GuardLog -Scope $Scope -Event 'transaction-sharing-retry' -Fields @{
                file = [IO.Path]::GetFileName($Path)
                nativeErrorCode = $nativeErrorCode
                attempt = $attempt + 1
                delayMilliseconds = $delayMilliseconds
            }
            [Threading.Thread]::Sleep($delayMilliseconds)
        }
    }
}

function Remove-GuardedTransactionFile {
    param(
        [object]$Scope,
        [object]$DirectoryGuard,
        [string]$Path,
        [string]$ExpectedSha256,
        [string[]]$ExpectedIdentity
    )
    $file = $null
    try {
        $file = Open-GuardedTransactionFileWithRetry -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $Path
        $snapshot = [pscustomobject][ordered]@{
            sha256 = Get-Sha256Hex -Bytes $file.ReadAllBytesFromHandle()
            identity = @([string]$file.VolumeSerialNumber, [string]$file.FileIndex)
        }
        Assert-CatalogTransactionSnapshot -Snapshot $snapshot -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
        $file.DeleteWithPosixSemantics()
    } finally {
        if ($null -ne $file) { $file.Dispose() }
    }
}

function Rename-GuardedTransactionFileNoReplace {
    param(
        [object]$Scope,
        [object]$DirectoryGuard,
        [string]$Path,
        [string]$TargetPath,
        [string]$ExpectedSha256,
        [string[]]$ExpectedIdentity
    )
    $file = $null
    try {
        $file = Open-GuardedTransactionFileWithRetry -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $Path
        $snapshot = [pscustomobject][ordered]@{
            sha256 = Get-Sha256Hex -Bytes $file.ReadAllBytesFromHandle()
            identity = @([string]$file.VolumeSerialNumber, [string]$file.FileIndex)
        }
        Assert-CatalogTransactionSnapshot -Snapshot $snapshot -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
        $file.RenameTo($TargetPath, $false)
        return [pscustomobject][ordered]@{ identity = @([string]$file.VolumeSerialNumber, [string]$file.FileIndex); sha256 = $snapshot.sha256 }
    } finally {
        if ($null -ne $file) { $file.Dispose() }
    }
}

function Move-GuardedTransactionFileNoReplaceLeased {
    param(
        [object]$Scope,
        [object]$DirectoryGuard,
        [string]$Path,
        [string]$TargetPath,
        [string]$ExpectedSha256,
        [string[]]$ExpectedIdentity
    )
    $file = $null
    try {
        $file = Open-GuardedTransactionFileWithRetry -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $Path
        $snapshot = [pscustomobject][ordered]@{
            sha256 = Get-Sha256Hex -Bytes $file.ReadAllBytesFromHandle()
            identity = @([string]$file.VolumeSerialNumber, [string]$file.FileIndex)
        }
        Assert-CatalogTransactionSnapshot -Snapshot $snapshot -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
        $file.RenameTo($TargetPath, $false)
        $result = [pscustomobject][ordered]@{ file = $file; identity = @($snapshot.identity); sha256 = $snapshot.sha256 }
        $file = $null
        return $result
    } finally {
        if ($null -ne $file) { $file.Dispose() }
    }
}

function Assert-GuardedLeasedFileSnapshot {
    param([object]$File, [string]$ExpectedSha256, [string[]]$ExpectedIdentity)
    $snapshot = [pscustomobject][ordered]@{
        sha256 = Get-Sha256Hex -Bytes $File.ReadAllBytesFromHandle()
        identity = @([string]$File.VolumeSerialNumber, [string]$File.FileIndex)
    }
    Assert-CatalogTransactionSnapshot -Snapshot $snapshot -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
}

function Assert-VendorAbortTransactionDefinition {
    param([object]$Transaction, [object]$VendorAbort)

    if (
        $Transaction.canonicalLeaf -cne $VendorAbort.canonicalLeaf -or
        $Transaction.txnLeaf -cne $VendorAbort.txnLeaf -or
        $Transaction.publishLeaf -cne $VendorAbort.publishLeaf -or
        $Transaction.quarantineLeaf -cne $VendorAbort.quarantineLeaf -or
        $Transaction.beforeSha256 -cne $VendorAbort.beforeSha256 -or
        $Transaction.afterSha256 -cne $VendorAbort.afterSha256 -or
        -not (Test-CatalogSnapshotIdentity -Snapshot ([pscustomobject]@{ identity = @($Transaction.beforeIdentity) }) -ExpectedIdentity $VendorAbort.beforeIdentity) -or
        $Transaction.txnSha256 -cne $VendorAbort.txnSha256 -or
        -not (Test-CatalogSnapshotIdentity -Snapshot ([pscustomobject]@{ identity = @($Transaction.txnIdentity) }) -ExpectedIdentity $VendorAbort.txnIdentity)
    ) {
        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'vendor-abort 与原始 transaction marker 不匹配。'
    }
}

function Complete-VendorAbortTransaction {
    param(
        [object]$Scope,
        [object]$Policy,
        [object]$DirectoryGuard,
        [object]$VendorAbort,
        [object]$CanonicalLeaseSnapshot
    )

    $ownsCanonicalLease = $null -eq $CanonicalLeaseSnapshot
    if ($ownsCanonicalLease) {
        $CanonicalLeaseSnapshot = Get-OptionalCatalogReadLeaseSnapshot -DirectoryGuard $DirectoryGuard -Path $VendorAbort.canonicalPath
    }
    try {
        if ($null -eq $CanonicalLeaseSnapshot) {
            Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'vendor-abort canonical 已消失。'
        }
        Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $CanonicalLeaseSnapshot -ExpectedSha256 $VendorAbort.vendorSha256 -ExpectedIdentity $VendorAbort.vendorIdentity
        try { [void](Convert-Catalog -Bytes $CanonicalLeaseSnapshot.bytes -Policy $Policy) } catch {
            Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'vendor-abort canonical 不再是受支持 vendor catalog。'
        }

        $quarantine = Get-OptionalCatalogSnapshot -CatalogRoot $Scope.catalogRoot -Path $VendorAbort.quarantinePath
        $publish = Get-OptionalAnchoredTransactionSnapshot -Path $VendorAbort.publishPath -ArtifactKind 'publish'
        $txnExists = [IO.File]::Exists($VendorAbort.txnPath)
        if ($null -ne $quarantine) {
            Assert-CatalogTransactionSnapshot -Snapshot $quarantine -ExpectedSha256 $VendorAbort.beforeSha256 -ExpectedIdentity $VendorAbort.beforeIdentity
        }
        if ($null -ne $publish) {
            Assert-CatalogTransactionSnapshot -Snapshot $publish -ExpectedSha256 $VendorAbort.afterSha256 -ExpectedIdentity $VendorAbort.publishIdentity
        }
        if ($txnExists) {
            $transaction = Read-CatalogTransactionDefinition -Scope $Scope -Stem $VendorAbort.stem -TxnPath $VendorAbort.txnPath
            Assert-VendorAbortTransactionDefinition -Transaction $transaction -VendorAbort $VendorAbort
        }
        if (
            ($null -ne $quarantine -and ($null -eq $publish -or -not $txnExists)) -or
            ($null -ne $publish -and -not $txnExists)
        ) {
            Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'vendor-abort artifact 不是合法单调清理状态。'
        }

        if ($null -ne $quarantine) {
            Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $CanonicalLeaseSnapshot -ExpectedSha256 $VendorAbort.vendorSha256 -ExpectedIdentity $VendorAbort.vendorIdentity
            Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'vendor-abort:before-quarantine-delete'
            Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $VendorAbort.quarantinePath -ExpectedSha256 $VendorAbort.beforeSha256 -ExpectedIdentity $VendorAbort.beforeIdentity
            Invoke-FixtureVendorAbortFault -Scope $Scope -Point 'after-quarantine-delete'
        }
        if ($null -ne $publish) {
            Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $CanonicalLeaseSnapshot -ExpectedSha256 $VendorAbort.vendorSha256 -ExpectedIdentity $VendorAbort.vendorIdentity
            Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'vendor-abort:before-publish-delete'
            Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $VendorAbort.publishPath -ExpectedSha256 $VendorAbort.afterSha256 -ExpectedIdentity $VendorAbort.publishIdentity
            Invoke-FixtureVendorAbortFault -Scope $Scope -Point 'after-publish-delete'
        }
        if ($txnExists) {
            Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $CanonicalLeaseSnapshot -ExpectedSha256 $VendorAbort.vendorSha256 -ExpectedIdentity $VendorAbort.vendorIdentity
            Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'vendor-abort:before-txn-delete'
            Invoke-FixtureMarkerCleanupReplacement -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $VendorAbort.txnPath
            Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $VendorAbort.txnPath -ExpectedSha256 $VendorAbort.txnSha256 -ExpectedIdentity $VendorAbort.txnIdentity
            Invoke-FixtureVendorAbortFault -Scope $Scope -Point 'after-txn-delete'
        }
        Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $CanonicalLeaseSnapshot -ExpectedSha256 $VendorAbort.vendorSha256 -ExpectedIdentity $VendorAbort.vendorIdentity
        Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'vendor-abort:before-abort-delete'
        Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $DirectoryGuard -Path $VendorAbort.vendorAbortPath -ExpectedSha256 $VendorAbort.vendorAbortSha256 -ExpectedIdentity $VendorAbort.vendorAbortIdentity
        Invoke-FixtureVendorAbortFault -Scope $Scope -Point 'after-abort-delete'
    } finally {
        if ($ownsCanonicalLease -and $null -ne $CanonicalLeaseSnapshot) { $CanonicalLeaseSnapshot.lease.Dispose() }
    }
}

function Invoke-CatalogTransactionReconciliation {
    param([object]$Scope, [object]$Policy)

    $inventory = Get-CatalogTransactionInventory -Scope $Scope
    $blocked = [Collections.Generic.List[object]]::new()
    $blockedLeaves = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $inventory.unknown) {
        $blocked.Add([pscustomobject][ordered]@{ file = $entry.file; code = $entry.code })
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.canonicalLeaf)) { [void]$blockedLeaves.Add([string]$entry.canonicalLeaf) }
    }

    foreach ($group in $inventory.groups) {
        $directoryGuard = $null
        $canonicalLeaseSnapshot = $null
        $movedCanonicalFile = $null
        try {
            $stagePaths = @($group.stageTxnPath, $group.stagePublishPath, $group.stageVendorAbortPath | Where-Object { $null -ne $_ })
            if ($group.stageConflict -or $stagePaths.Count -gt 1) {
                Throw-CatalogGuardFailure 'catalog-transaction-unknown-artifact' 'transaction 包含重复或冲突 staging。'
            }
            if ($stagePaths.Count -eq 1) {
                $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($Scope.catalogRoot, $Scope.catalogRoot, $false)
                if ($null -ne $group.stageTxnPath) {
                    if ($null -ne $group.txnPath -or $null -ne $group.publishPath -or $null -ne $group.quarantinePath -or $null -ne $group.vendorAbortPath) {
                        Throw-CatalogGuardFailure 'catalog-transaction-unknown-artifact' 'txn staging 与最终 transaction artifact 冲突。'
                    }
                    try { $stageTransaction = Read-CatalogTransactionDefinition -Scope $Scope -Stem $group.stem -TxnPath $group.stageTxnPath } catch {
                        Throw-CatalogGuardFailure 'catalog-transaction-unknown-artifact' 'txn staging 无法通过 self-binding 校验。'
                    }
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $group.stageTxnPath -ExpectedSha256 $stageTransaction.txnSha256 -ExpectedIdentity $stageTransaction.txnIdentity
                    continue
                }
                if ($null -ne $group.stagePublishPath) {
                    if ($null -eq $group.txnPath -or $null -ne $group.publishPath -or $null -ne $group.quarantinePath -or $null -ne $group.vendorAbortPath) {
                        Throw-CatalogGuardFailure 'catalog-transaction-unknown-artifact' 'publish staging 缺少唯一 self-bound transaction marker。'
                    }
                    $stageTransaction = Read-CatalogTransactionDefinition -Scope $Scope -Stem $group.stem -TxnPath $group.txnPath
                    $stagePublish = Get-AnchoredTransactionSnapshot -Path $group.stagePublishPath -ArtifactKind 'publish'
                    Assert-CatalogTransactionSnapshot -Snapshot $stagePublish -ExpectedSha256 $stageTransaction.afterSha256 -ExpectedIdentity $stageTransaction.publishIdentity
                    $canonicalLeaseSnapshot = New-CatalogReadLeaseSnapshot -DirectoryGuard $directoryGuard -Path $stageTransaction.canonicalPath
                    Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $stageTransaction.beforeSha256 -ExpectedIdentity $stageTransaction.beforeIdentity
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $group.stagePublishPath -ExpectedSha256 $stageTransaction.afterSha256 -ExpectedIdentity $stageTransaction.publishIdentity
                    Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $stageTransaction.beforeSha256 -ExpectedIdentity $stageTransaction.beforeIdentity
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $stageTransaction.txnPath -ExpectedSha256 $stageTransaction.txnSha256 -ExpectedIdentity $stageTransaction.txnIdentity
                    continue
                }
                if ($null -eq $group.txnPath -or $null -eq $group.publishPath -or $null -eq $group.quarantinePath -or $null -ne $group.vendorAbortPath) {
                    Throw-CatalogGuardFailure 'catalog-transaction-unknown-artifact' 'vendor-abort staging 缺少完整 transaction。'
                }
                try { $stageVendorAbort = Read-VendorAbortDefinition -Scope $Scope -Stem $group.stem -AbortPath $group.stageVendorAbortPath } catch {
                    Throw-CatalogGuardFailure 'catalog-transaction-unknown-artifact' 'vendor-abort staging 无法通过 self-binding 校验。'
                }
                [void](Rename-GuardedTransactionFileNoReplace -Scope $Scope -DirectoryGuard $directoryGuard -Path $group.stageVendorAbortPath -TargetPath $stageVendorAbort.vendorAbortPath -ExpectedSha256 $stageVendorAbort.vendorAbortSha256 -ExpectedIdentity $stageVendorAbort.vendorAbortIdentity)
                Complete-VendorAbortTransaction -Scope $Scope -Policy $Policy -DirectoryGuard $directoryGuard -VendorAbort $stageVendorAbort
                continue
            }
            if ($null -ne $group.vendorAbortPath) {
                $vendorAbort = Read-VendorAbortDefinition -Scope $Scope -Stem $group.stem -AbortPath $group.vendorAbortPath
                $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($Scope.catalogRoot, $Scope.catalogRoot, $false)
                Complete-VendorAbortTransaction -Scope $Scope -Policy $Policy -DirectoryGuard $directoryGuard -VendorAbort $vendorAbort
                continue
            }
            if ($null -eq $group.txnPath) {
                Throw-CatalogGuardFailure 'catalog-transaction-unknown-artifact' 'transaction artifact 缺少受管 marker。'
            }
            $transaction = Read-CatalogTransactionDefinition -Scope $Scope -Stem $group.stem -TxnPath $group.txnPath
            $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($Scope.catalogRoot, $Scope.catalogRoot, $false)
            $canonicalLeaseSnapshot = Get-OptionalCatalogReadLeaseSnapshot -DirectoryGuard $directoryGuard -Path $transaction.canonicalPath
            $canonical = $canonicalLeaseSnapshot
            $quarantine = Get-OptionalCatalogSnapshot -CatalogRoot $Scope.catalogRoot -Path $transaction.quarantinePath
            $publish = Get-OptionalAnchoredTransactionSnapshot -Path $transaction.publishPath -ArtifactKind 'publish'
            if ($null -ne $quarantine) {
                Assert-CatalogTransactionSnapshot -Snapshot $quarantine -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
            }
            if ($null -ne $publish) {
                Assert-CatalogTransactionSnapshot -Snapshot $publish -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
            }

            $canonicalIsBefore =
                $null -ne $canonical -and
                $canonical.sha256 -ceq $transaction.beforeSha256 -and
                (Test-CatalogSnapshotIdentity -Snapshot $canonical -ExpectedIdentity $transaction.beforeIdentity)
            $canonicalIsAfter =
                $null -ne $canonical -and
                $canonical.sha256 -ceq $transaction.afterSha256 -and
                (Test-CatalogSnapshotIdentity -Snapshot $canonical -ExpectedIdentity $transaction.publishIdentity)
            if ($null -ne $quarantine -and $null -ne $publish -and $null -ne $canonical -and -not $canonicalIsBefore -and -not $canonicalIsAfter) {
                try { [void](Convert-Catalog -Bytes $canonical.bytes -Policy $Policy) } catch {
                    Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'orphan transaction canonical 不是受支持 vendor catalog。'
                }
                $vendorAbortPhase = Publish-DurableVendorAbortPhase -Scope $Scope -Transaction $transaction -VendorSnapshot $canonical
                $vendorAbort = $vendorAbortPhase.definition
                $vendorAbortPhase.file.Dispose()
                Complete-VendorAbortTransaction -Scope $Scope -Policy $Policy -DirectoryGuard $directoryGuard -VendorAbort $vendorAbort -CanonicalLeaseSnapshot $canonicalLeaseSnapshot
                continue
            }

            if ($null -ne $quarantine) {
                if ($null -eq $canonical) {
                    if ($null -ne $publish) {
                        $moved = Move-GuardedTransactionFileNoReplaceLeased -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.publishPath -TargetPath $transaction.canonicalPath -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
                        $movedCanonicalFile = $moved.file
                        Assert-GuardedLeasedFileSnapshot -File $movedCanonicalFile -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
                        Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'restart-publish:before-quarantine-delete'
                        Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.quarantinePath -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
                        Assert-GuardedLeasedFileSnapshot -File $movedCanonicalFile -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
                        Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'restart-publish:before-txn-delete'
                        Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
                    } else {
                        $moved = Move-GuardedTransactionFileNoReplaceLeased -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.quarantinePath -TargetPath $transaction.canonicalPath -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
                        $movedCanonicalFile = $moved.file
                        Assert-GuardedLeasedFileSnapshot -File $movedCanonicalFile -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
                        Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
                    }
                } else {
                    if ($null -ne $publish -or -not $canonicalIsAfter) {
                        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'orphan transaction 与现有 canonical 冲突。'
                    }
                    Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.quarantinePath -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
                    Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
                }
            } else {
                if ($null -eq $canonical) {
                    Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'transaction 缺少 canonical 与 quarantine。'
                }
                if ($null -ne $publish) {
                    if (-not $canonicalIsBefore) {
                        Throw-CatalogGuardFailure 'catalog-transaction-conflict' '未隔离 transaction 与现有 canonical 冲突。'
                    }
                    Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.publishPath -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
                    Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
                } else {
                    if (-not $canonicalIsBefore -and -not $canonicalIsAfter) {
                        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'transaction cleanup 与现有 canonical 冲突。'
                    }
                    if ($canonicalIsBefore) {
                        Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $transaction.beforeSha256 -ExpectedIdentity $transaction.beforeIdentity
                    } else {
                        Assert-CatalogReadLeaseSnapshot -LeaseSnapshot $canonicalLeaseSnapshot -ExpectedSha256 $transaction.afterSha256 -ExpectedIdentity $transaction.publishIdentity
                    }
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
                }
            }
        } catch {
            if (
                $Scope.fixture -and
                [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS') -ceq '1'
            ) {
                [Console]::Error.WriteLine($_.Exception.ToString())
            }
            $blocked.Add([pscustomobject][ordered]@{ file = $group.canonicalLeaf; code = Get-GuardFailureCode -Exception $_.Exception })
            [void]$blockedLeaves.Add($group.canonicalLeaf)
        } finally {
            if ($null -ne $movedCanonicalFile) { $movedCanonicalFile.Dispose() }
            if ($null -ne $canonicalLeaseSnapshot) { $canonicalLeaseSnapshot.lease.Dispose() }
            if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
        }
    }
    return [pscustomobject][ordered]@{ blocked = @($blocked); blockedLeaves = $blockedLeaves }
}

function Set-SafeCatalogBytes {
    param(
        [object]$Scope,
        [object]$Policy,
        [string]$CatalogRoot,
        [string]$Path,
        [string[]]$ExpectedIdentity,
        [string]$ExpectedSha256,
        [byte[]]$Bytes
    )
    $canonicalLeaf = [IO.Path]::GetFileName($Path)
    $afterSha256 = Get-Sha256Hex -Bytes $Bytes
    $transaction = New-CatalogTransactionDefinition -CatalogRoot $CatalogRoot -CanonicalLeaf $canonicalLeaf -BeforeSha256 $ExpectedSha256 -BeforeIdentity $ExpectedIdentity -AfterSha256 $afterSha256 -TxnIdentity @() -PublishIdentity @()
    $directoryGuard = $null
    $sourceFile = $null
    $markerFile = $null
    $publishFile = $null
    $vendorAbortFile = $null
    $canonicalLeaseSnapshot = $null
    $restoredCanonicalFile = $null
    $markerCreated = $false
    $publishCreated = $false
    $isolated = $false
        $published = $false
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CatalogRoot, $CatalogRoot, $false)
        $publishFile = New-DurableStagedArtifactFile -Scope $Scope -FinalPath $transaction.publishPath -ArtifactKind 'publish'
        Write-DurableStagedArtifactFile -Scope $Scope -File $publishFile -Bytes $Bytes -ArtifactKind 'publish'
        $publishIdentity = @([string]$publishFile.VolumeSerialNumber, [string]$publishFile.FileIndex)

        $markerFile = New-DurableStagedArtifactFile -Scope $Scope -FinalPath $transaction.txnPath -ArtifactKind 'txn'
        $txnIdentity = @([string]$markerFile.VolumeSerialNumber, [string]$markerFile.FileIndex)
        $transaction = New-CatalogTransactionDefinition -CatalogRoot $CatalogRoot -CanonicalLeaf $canonicalLeaf -BeforeSha256 $ExpectedSha256 -BeforeIdentity $ExpectedIdentity -AfterSha256 $afterSha256 -TxnIdentity $txnIdentity -PublishIdentity $publishIdentity
        Write-DurableStagedArtifactFile -Scope $Scope -File $markerFile -Bytes $transaction.markerBytes -ArtifactKind 'txn'
        [void](Complete-DurableStagedArtifactPublication -Scope $Scope -File $markerFile -FinalPath $transaction.txnPath -Bytes $transaction.markerBytes -ArtifactKind 'txn')
        $transaction | Add-Member -NotePropertyName txnSha256 -NotePropertyValue (Get-Sha256Hex -Bytes $markerFile.ReadAllBytesFromHandle())
        Assert-CatalogTransactionSnapshot -Snapshot ([pscustomobject]@{ sha256 = $transaction.txnSha256; identity = @($transaction.txnIdentity) }) -ExpectedSha256 (Get-Sha256Hex -Bytes $transaction.markerBytes) -ExpectedIdentity $transaction.txnIdentity
        $markerCreated = $true
        $markerFile.Dispose()
        $markerFile = $null

        [void](Complete-DurableStagedArtifactPublication -Scope $Scope -File $publishFile -FinalPath $transaction.publishPath -Bytes $Bytes -ArtifactKind 'publish')
        $transaction | Add-Member -NotePropertyName publishSha256 -NotePropertyValue (Get-Sha256Hex -Bytes $publishFile.ReadAllBytesFromHandle())
        Assert-CatalogTransactionSnapshot -Snapshot ([pscustomobject]@{ sha256 = $transaction.publishSha256; identity = @($transaction.publishIdentity) }) -ExpectedSha256 $afterSha256 -ExpectedIdentity $transaction.publishIdentity
        $publishCreated = $true

        $sourceFile = $directoryGuard.AcquirePreparedTempFile($Path)
        [byte[]]$currentBytes = $sourceFile.ReadAllBytesFromHandle()
        $currentHash = Get-Sha256Hex -Bytes $currentBytes
        $currentIdentity = @([string]$sourceFile.VolumeSerialNumber, [string]$sourceFile.FileIndex)
        if ($currentHash -cne $ExpectedSha256) {
            Throw-CatalogGuardFailure 'catalog-hash-drift' 'catalog 临写前哈希漂移。'
        }
        if ($currentIdentity[0] -cne $ExpectedIdentity[0] -or $currentIdentity[1] -cne $ExpectedIdentity[1]) {
            Throw-CatalogGuardFailure 'catalog-identity-drift' 'catalog 临写前身份漂移。'
        }
        try {
            $sourceFile.RenameTo($transaction.quarantinePath, $false)
            $isolated = $true
        } catch {
            if ([IO.File]::Exists($transaction.quarantinePath) -and -not [IO.File]::Exists($Path)) { $isolated = $true }
            throw
        } finally {
            $sourceFile.Dispose()
            $sourceFile = $null
        }

        Invoke-FixtureAfterQuarantineFault -Scope $Scope
        Invoke-FixturePostIsolationMutation -Scope $Scope -Path $Path
        $publishError = $null
        try {
            Invoke-FixturePublishFailure -Scope $Scope
            $publishFile.RenamePublishedTo($Path, $false)
            $published = $true
        } catch {
            $publishError = $_
            if (-not [IO.File]::Exists($transaction.publishPath) -and [IO.File]::Exists($Path)) {
                try {
                    $possiblePublished = Get-SafeCatalogSnapshot -CatalogRoot $CatalogRoot -Path $Path
                    if ($possiblePublished.sha256 -ceq $afterSha256 -and (Test-CatalogSnapshotIdentity -Snapshot $possiblePublished -ExpectedIdentity $transaction.publishIdentity)) { $published = $true }
                } catch {}
            }
            if (-not $published -and [IO.File]::Exists($Path)) {
                $canonicalLeaseSnapshot = Get-OptionalCatalogReadLeaseSnapshot -DirectoryGuard $directoryGuard -Path $Path
                if ($null -ne $canonicalLeaseSnapshot) {
                    $replacement = $canonicalLeaseSnapshot
                    if (Test-CatalogSnapshotIdentity -Snapshot $replacement -ExpectedIdentity $ExpectedIdentity) {
                        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'publish 失败后 canonical 身份异常。'
                    }
                    try { [void](Convert-Catalog -Bytes $replacement.bytes -Policy $Policy) } catch {
                        Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'publish 失败后的 canonical 不是受支持 vendor catalog。'
                    }
                    $publishFile.Dispose()
                    $publishFile = $null
                    $vendorAbortPhase = Publish-DurableVendorAbortPhase -Scope $Scope -Transaction $transaction -VendorSnapshot $replacement
                    $vendorAbort = $vendorAbortPhase.definition
                    $vendorAbortFile = $vendorAbortPhase.file
                    $vendorAbortFile.Dispose()
                    $vendorAbortFile = $null
                    Invoke-FixtureVendorAbortFault -Scope $Scope -Point 'after-phase'
                    Complete-VendorAbortTransaction -Scope $Scope -Policy $Policy -DirectoryGuard $directoryGuard -VendorAbort $vendorAbort -CanonicalLeaseSnapshot $canonicalLeaseSnapshot
                    Throw-CatalogGuardFailure 'catalog-publish-race' 'catalog 发布前目标路径已由受支持 vendor 写入者重建。'
                }
            }
            if (-not $published) {
                try {
                    $restored = Move-GuardedTransactionFileNoReplaceLeased -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.quarantinePath -TargetPath $Path -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
                    $restoredCanonicalFile = $restored.file
                } catch {
                    if ([IO.File]::Exists($Path)) { Throw-CatalogGuardFailure 'catalog-transaction-conflict' 'publish 回滚时 canonical 被其他写入者抢占。' }
                    throw
                }
                Assert-GuardedLeasedFileSnapshot -File $restoredCanonicalFile -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
                Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'rollback:before-publish-delete'
                $publishFile.DeleteWithPosixSemantics()
                $publishFile.Dispose()
                $publishFile = $null
                Assert-GuardedLeasedFileSnapshot -File $restoredCanonicalFile -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
                Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'rollback:before-txn-delete'
                Invoke-FixtureMarkerCleanupReplacement -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath
                Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
                $restoredCanonicalFile.Dispose()
                $restoredCanonicalFile = $null
                throw $publishError
            }
        }

        $publishedHash = Get-Sha256Hex -Bytes $publishFile.ReadAllBytesFromHandle()
        if ($publishedHash -cne $afterSha256) {
            Throw-CatalogGuardFailure 'catalog-postwrite-drift' 'catalog 原子替换后哈希不一致。'
        }
        $publishedIdentity = @([string]$publishFile.VolumeSerialNumber, [string]$publishFile.FileIndex)
        $publishFile.VerifyCurrentPath()
        if ((Get-Sha256Hex -Bytes $publishFile.ReadAllBytesFromHandle()) -cne $afterSha256) { Throw-CatalogGuardFailure 'catalog-postwrite-drift' 'canonical lease 在清理 quarantine 前漂移。' }
        Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'normal-publish:before-quarantine-delete'
        Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.quarantinePath -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity
        $publishFile.VerifyCurrentPath()
        if ((Get-Sha256Hex -Bytes $publishFile.ReadAllBytesFromHandle()) -cne $afterSha256) { Throw-CatalogGuardFailure 'catalog-postwrite-drift' 'canonical lease 在清理 marker 前漂移。' }
        Invoke-FixtureCanonicalLeasePoint -Scope $Scope -Point 'normal-publish:before-txn-delete'
        Invoke-FixtureMarkerCleanupReplacement -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath
        Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
        $publishFile.Dispose()
        $publishFile = $null
        return [pscustomobject][ordered]@{
            identity = @($publishedIdentity)
            sha256 = $publishedHash
        }
    } catch {
        if (-not $isolated -and $null -ne $directoryGuard) {
            if ($null -ne $sourceFile) { $sourceFile.Dispose(); $sourceFile = $null }
            if ($null -ne $publishFile) {
                try { $publishFile.DeleteWithPosixSemantics() } catch {}
                $publishFile.Dispose()
                $publishFile = $null
            } elseif ($publishCreated -and [IO.File]::Exists($transaction.publishPath)) {
                try {
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.publishPath -ExpectedSha256 $transaction.publishSha256 -ExpectedIdentity $transaction.publishIdentity
                } catch {}
            }
            if ($null -ne $markerFile) {
                try { $markerFile.DeleteWithPosixSemantics() } catch {}
                $markerFile.Dispose()
                $markerFile = $null
            } elseif ($markerCreated -and [IO.File]::Exists($transaction.txnPath)) {
                try {
                    Remove-GuardedTransactionFile -Scope $Scope -DirectoryGuard $directoryGuard -Path $transaction.txnPath -ExpectedSha256 $transaction.txnSha256 -ExpectedIdentity $transaction.txnIdentity
                } catch {}
            }
        }
        throw
    } finally {
        if ($null -ne $sourceFile) { $sourceFile.Dispose() }
        if ($null -ne $markerFile) { $markerFile.Dispose() }
        if ($null -ne $publishFile) { $publishFile.Dispose() }
        if ($null -ne $vendorAbortFile) { $vendorAbortFile.Dispose() }
        if ($null -ne $canonicalLeaseSnapshot) { $canonicalLeaseSnapshot.lease.Dispose() }
        if ($null -ne $restoredCanonicalFile) { $restoredCanonicalFile.Dispose() }
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
}

function Get-GuardFailureCode {
    param([Exception]$Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [CatalogGuardFailure]) { return $current.FailureCode }
        if ($current -is [ComponentModel.Win32Exception] -and $current.NativeErrorCode -in @(32, 33)) { return 'catalog-busy' }
        $current = $current.InnerException
    }
    $text = $Exception.ToString()
    if ($text -match 'hard link|more than one hard') { return 'hard-link' }
    if ($text -match 'reparse') { return 'reparse-point' }
    if ($text -match 'different final path|identity') { return 'catalog-identity-drift' }
    if ($text -match 'sharing violation|being used by another process') { return 'catalog-busy' }
    return 'catalog-io-failure'
}

function Convert-Catalog {
    param([byte[]]$Bytes, [object]$Policy)

    try { $text = $utf8Strict.GetString($Bytes) } catch { Throw-CatalogGuardFailure 'malformed-json' 'catalog 不是严格 UTF-8。' }
    $document = Read-StrictJsonDocument -Text $text
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            Throw-CatalogGuardFailure 'catalog-schema-drift' 'catalog 根必须是 object。'
        }
        $rootProperties = @($document.RootElement.EnumerateObject())
        $rootNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $rootProperties) { [void]$rootNames.Add($property.Name) }
        $hasFetchedAt = $rootNames.Contains('fetched_at')
        $supportedRoot =
            $rootNames.Contains('schema_version') -and
            $rootNames.Contains('plugins') -and
            (($rootProperties.Count -eq 2 -and -not $hasFetchedAt) -or ($rootProperties.Count -eq 3 -and $hasFetchedAt))
        if (-not $supportedRoot) {
            Throw-CatalogGuardFailure 'catalog-schema-drift' 'catalog 根路径或属性集合漂移。'
        }
        $schemaVersion = 0
        $schemaElement = $document.RootElement.GetProperty('schema_version')
        $pluginsElement = $document.RootElement.GetProperty('plugins')
        if (-not $schemaElement.TryGetInt32([ref]$schemaVersion) -or $schemaVersion -ne 1 -or $pluginsElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
            Throw-CatalogGuardFailure 'catalog-schema-drift' 'catalog schema_version 或 plugins 路径漂移。'
        }
        if ($hasFetchedAt) {
            $fetchedAtElement = $document.RootElement.GetProperty('fetched_at')
            if ($fetchedAtElement.ValueKind -ne [Text.Json.JsonValueKind]::String) {
                Throw-CatalogGuardFailure 'catalog-schema-drift' 'catalog fetched_at 必须是 UTC 时间字符串。'
            }
            $fetchedAt = $fetchedAtElement.GetString()
            $fetchedAtMatch = [Text.RegularExpressions.Regex]::Match(
                $fetchedAt,
                "^(?<seconds>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.(?<fraction>[0-9]{1,9}))?Z\z",
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)
            if (-not $fetchedAtMatch.Success) {
                Throw-CatalogGuardFailure 'catalog-schema-drift' 'catalog fetched_at 格式漂移。'
            }
            $fetchedAtFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            $normalizedFetchedAt = $fetchedAtMatch.Groups['seconds'].Value + 'Z'
            if ($fetchedAtMatch.Groups['fraction'].Success) {
                $fraction = $fetchedAtMatch.Groups['fraction'].Value
                $parseableFraction = $fraction.Substring(0, [Math]::Min(7, $fraction.Length))
                $normalizedFetchedAt = $fetchedAtMatch.Groups['seconds'].Value + '.' + $parseableFraction + 'Z'
                $fetchedAtFormat = "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'"
            }
            $parsedFetchedAt = [DateTimeOffset]::MinValue
            $fetchedAtStyle = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
            if (-not [DateTimeOffset]::TryParseExact($normalizedFetchedAt, $fetchedAtFormat, [Globalization.CultureInfo]::InvariantCulture, $fetchedAtStyle, [ref]$parsedFetchedAt)) {
                Throw-CatalogGuardFailure 'catalog-schema-drift' 'catalog fetched_at 格式漂移。'
            }
        }
    } finally {
        $document.Dispose()
    }

    $node = [Text.Json.Nodes.JsonNode]::Parse($text)
    $plugins = $node.AsObject()['plugins'].AsArray()
    $targetsById = @{}
    foreach ($target in @($Policy.targets)) { $targetsById[[string]$target.id] = [string]$target.name }
    $removeIndexes = [Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $plugins.Count; $index++) {
        $entry = $plugins[$index]
        if ($null -eq $entry -or $entry.GetType().FullName -cne 'System.Text.Json.Nodes.JsonObject') {
            Throw-CatalogGuardFailure 'catalog-schema-drift' 'plugins[] 包含非 object。'
        }
        $entryObject = $entry.AsObject()
        if (-not $entryObject.ContainsKey('name') -or -not $entryObject.ContainsKey('id')) {
            Throw-CatalogGuardFailure 'catalog-schema-drift' 'plugins[] 缺少 name 或 id。'
        }
        try {
            $name = $entryObject['name'].GetValue[string]()
            $id = $entryObject['id'].GetValue[string]()
        } catch {
            Throw-CatalogGuardFailure 'catalog-schema-drift' 'plugins[] name 或 id 不是 string。'
        }
        $nameIsTarget = $expectedTargets.Contains($name)
        $idIsTarget = $targetsById.Contains($id)
        if ($nameIsTarget -and $expectedTargets[$name] -cne $id) {
            Throw-CatalogGuardFailure 'target-pair-mismatch' '目标 name 对应了异常 id。'
        }
        if ($idIsTarget -and $targetsById[$id] -cne $name) {
            Throw-CatalogGuardFailure 'target-pair-mismatch' '目标 id 对应了异常 name。'
        }
        if ($nameIsTarget -and $idIsTarget) { $removeIndexes.Add($index) }
    }
    for ($position = $removeIndexes.Count - 1; $position -ge 0; $position--) {
        $plugins.RemoveAt($removeIndexes[$position])
    }
    $pluginCount = $plugins.Count
    if ($removeIndexes.Count -eq 0) {
        $nonTargetBytes = $utf8NoBom.GetBytes($plugins.ToJsonString())
        return [pscustomobject][ordered]@{ changed = $false; removedCount = 0; pluginCount = $pluginCount; nonTargetContentSha256 = Get-Sha256Hex -Bytes $nonTargetBytes; bytes = $null }
    }
    $serializerOptions = [Text.Json.JsonSerializerOptions]::new()
    $serializerOptions.WriteIndented = $true
    $afterText = $node.ToJsonString($serializerOptions) + "`n"
    $nonTargetBytes = $utf8NoBom.GetBytes($plugins.ToJsonString())
    return [pscustomobject][ordered]@{ changed = $true; removedCount = $removeIndexes.Count; pluginCount = $pluginCount; nonTargetContentSha256 = Get-Sha256Hex -Bytes $nonTargetBytes; bytes = $utf8NoBom.GetBytes($afterText) }
}

function Get-CatalogAudit {
    param([object]$Scope, [object]$Policy, [string]$ResolvedPolicyPath)

    $files = [Collections.Generic.List[object]]::new()
    $blocked = [Collections.Generic.List[object]]::new()
    try {
        foreach ($transactionBlock in @(Get-CatalogTransactionAuditBlocks -Scope $Scope)) { $blocked.Add($transactionBlock) }
    } catch {
        $blocked.Add([pscustomobject][ordered]@{ file = $null; code = Get-GuardFailureCode -Exception $_.Exception })
    }
    $directoryGuard = $null
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($Scope.catalogRoot, $Scope.catalogRoot, $false)
        $paths = @([IO.Directory]::EnumerateFiles($Scope.catalogRoot, '*.json', [IO.SearchOption]::TopDirectoryOnly) | Sort-Object)
    } catch {
        $blocked.Add([pscustomobject][ordered]@{ file = $null; code = Get-GuardFailureCode -Exception $_.Exception })
        $paths = @()
    } finally {
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
    foreach ($path in $paths) {
        $leaf = [IO.Path]::GetFileName($path)
        if ($leaf -cnotmatch $Policy.fileNamePattern) { continue }
        try {
            $snapshot = Get-SafeCatalogSnapshot -CatalogRoot $Scope.catalogRoot -Path $path
            $conversion = Convert-Catalog -Bytes $snapshot.bytes -Policy $Policy
            $files.Add([pscustomobject][ordered]@{
                file = $leaf
                sha256 = $snapshot.sha256
                identity = @($snapshot.identity)
                pluginCount = $conversion.pluginCount
                targetCount = $conversion.removedCount
                pairMismatchCount = 0
                nonTargetContentSha256 = $conversion.nonTargetContentSha256
            })
        } catch {
            $blocked.Add([pscustomobject][ordered]@{ file = $leaf; code = Get-GuardFailureCode -Exception $_.Exception })
        }
    }
    $pluginCount = 0
    $targetCount = 0
    foreach ($file in $files) {
        $pluginCount += [int]$file.pluginCount
        $targetCount += [int]$file.targetCount
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $blocked.Count -eq 0 -and $targetCount -eq 0
        mode = 'Audit'
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        policyValid = $true
        policySchemaVersion = [int]$Policy.schemaVersion
        policySha256 = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($ResolvedPolicyPath))
        fileCount = $files.Count
        pluginCount = $pluginCount
        targetCount = $targetCount
        pairMismatchCount = 0
        files = @($files)
        blocked = @($blocked)
    }
}

function Invoke-CatalogFile {
    param([object]$Scope, [object]$Policy, [string]$Path)

    $leaf = [IO.Path]::GetFileName($Path)
    if ($leaf -cnotmatch $Policy.fileNamePattern -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)) -ine $Scope.catalogRoot) {
        Throw-CatalogGuardFailure 'unsupported-catalog-path' 'catalog path 不在受支持 capability 内。'
    }
    $snapshot = Get-SafeCatalogSnapshot -CatalogRoot $Scope.catalogRoot -Path $Path
    $conversion = Convert-Catalog -Bytes $snapshot.bytes -Policy $Policy
    if (-not $conversion.changed) {
        return [pscustomobject][ordered]@{ file = $leaf; state = 'clean'; removedCount = 0; beforeSha256 = $snapshot.sha256; afterSha256 = $snapshot.sha256; processedIdentity = @($snapshot.identity); processedSha256 = $snapshot.sha256 }
    }
    Write-GuardLog -Scope $Scope -Event 'catalog-rewrite-start' -Fields @{ file = $leaf; beforeSha256 = $snapshot.sha256; removedCount = $conversion.removedCount }
    Invoke-FixturePrewriteMutation -Scope $Scope -Path $Path
    $published = Set-SafeCatalogBytes -Scope $Scope -Policy $Policy -CatalogRoot $Scope.catalogRoot -Path $Path -ExpectedIdentity $snapshot.identity -ExpectedSha256 $snapshot.sha256 -Bytes $conversion.bytes
    $afterSha = Get-Sha256Hex -Bytes $conversion.bytes
    Write-GuardLog -Scope $Scope -Event 'catalog-rewrite-complete' -Fields @{ file = $leaf; afterSha256 = $afterSha; removedCount = $conversion.removedCount }
    return [pscustomobject][ordered]@{ file = $leaf; state = 'modified'; removedCount = $conversion.removedCount; beforeSha256 = $snapshot.sha256; afterSha256 = $afterSha; processedIdentity = @($published.identity); processedSha256 = $published.sha256 }
}

function Invoke-CatalogSweep {
    param(
        [object]$Scope,
        [object]$Policy,
        [Collections.IDictionary]$Fingerprints,
        [Collections.IDictionary]$RetryState,
        [Collections.IDictionary]$Metrics,
        [switch]$Force
    )

    $results = [Collections.Generic.List[object]]::new()
    $blocked = [Collections.Generic.List[object]]::new()
    $skippedUnchangedCount = 0
    $blockedTransactionLeaves = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        $transactionReconciliation = Invoke-CatalogTransactionReconciliation -Scope $Scope -Policy $Policy
        foreach ($transactionBlock in @($transactionReconciliation.blocked)) { $blocked.Add($transactionBlock) }
        foreach ($blockedLeaf in $transactionReconciliation.blockedLeaves) { [void]$blockedTransactionLeaves.Add([string]$blockedLeaf) }
    } catch {
        $blocked.Add([pscustomobject][ordered]@{ file = $null; code = Get-GuardFailureCode -Exception $_.Exception })
    }
    $directoryGuard = $null
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($Scope.catalogRoot, $Scope.catalogRoot, $false)
        $paths = @([IO.Directory]::EnumerateFiles($Scope.catalogRoot, '*.json', [IO.SearchOption]::TopDirectoryOnly) | Sort-Object)
    } catch {
        $code = Get-GuardFailureCode -Exception $_.Exception
        $blocked.Add([pscustomobject][ordered]@{ file = $null; code = $code })
        Write-GuardLog -Scope $Scope -Event 'catalog-root-blocked' -Fields @{ code = $code }
        $paths = @()
    } finally {
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
    $presentLeaves = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $paths) {
        $leaf = [IO.Path]::GetFileName($path)
        if ($leaf -cnotmatch $Policy.fileNamePattern) { continue }
        [void]$presentLeaves.Add($leaf)
        if ($blockedTransactionLeaves.Contains($leaf)) { continue }
        try {
            if ($null -ne $Metrics) { $Metrics.metadataProbeCount = [int64]$Metrics.metadataProbeCount + 1 }
            $metadata = Get-SafeCatalogMetadata -CatalogRoot $Scope.catalogRoot -Path $path
            $fingerprint = "$($metadata.identity):$($metadata.length):$($metadata.lastWriteTicks)"
            $retryDue = $false
            if ($null -ne $RetryState -and $RetryState.ContainsKey($leaf)) {
                $retryDue = [DateTime]::UtcNow -ge [DateTime]$RetryState[$leaf].dueUtc
            }
            $knownUnchanged = $null -ne $Fingerprints -and $Fingerprints.ContainsKey($leaf) -and $Fingerprints[$leaf] -ceq $fingerprint
            if (-not $Force -and $knownUnchanged -and -not $retryDue) {
                $skippedUnchangedCount++
                continue
            }
            if ($null -ne $RetryState -and $RetryState.ContainsKey($leaf) -and -not $retryDue -and -not $Force) {
                continue
            }
            if ($null -ne $Metrics) { $Metrics.contentReadCount = [int64]$Metrics.contentReadCount + 1 }
            $fileResult = Invoke-CatalogFile -Scope $Scope -Policy $Policy -Path $path
            $results.Add($fileResult)
            if ($null -ne $Metrics -and $fileResult.state -ceq 'modified') {
                $Metrics.rewriteCount = [int64]$Metrics.rewriteCount + 1
            }
            Invoke-FixturePostprocessMutation -Scope $Scope -Path $path
            $afterMetadata = Get-SafeCatalogMetadata -CatalogRoot $Scope.catalogRoot -Path $path
            if ($null -ne $Metrics) { $Metrics.metadataProbeCount = [int64]$Metrics.metadataProbeCount + 1 }
            $afterSnapshot = Get-SafeCatalogSnapshot -CatalogRoot $Scope.catalogRoot -Path $path
            if ($null -ne $Metrics) { $Metrics.contentReadCount = [int64]$Metrics.contentReadCount + 1 }
            $processedIdentity = "$($fileResult.processedIdentity[0]):$($fileResult.processedIdentity[1])"
            $afterSnapshotIdentity = "$($afterSnapshot.identity[0]):$($afterSnapshot.identity[1])"
            if ($afterMetadata.identity -cne $processedIdentity -or $afterSnapshotIdentity -cne $processedIdentity) {
                Throw-CatalogGuardFailure 'catalog-postprocess-identity-drift' 'catalog 处理后对象身份漂移。'
            }
            if ($afterSnapshot.sha256 -cne $fileResult.processedSha256) {
                Throw-CatalogGuardFailure 'catalog-postprocess-hash-drift' 'catalog 处理后内容漂移。'
            }
            if ($null -ne $Fingerprints) {
                $Fingerprints[$leaf] = "$($afterMetadata.identity):$($afterMetadata.length):$($afterMetadata.lastWriteTicks)"
            }
            if ($null -ne $RetryState) { [void]$RetryState.Remove($leaf) }
        } catch {
            $code = Get-GuardFailureCode -Exception $_.Exception
            if (
                $Scope.fixture -and
                [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS') -ceq '1'
            ) {
                [Console]::Error.WriteLine($_.Exception.ToString())
            }
            $blocked.Add([pscustomobject][ordered]@{ file = $leaf; code = $code })
            Write-GuardLog -Scope $Scope -Event 'catalog-blocked' -Fields @{ file = $leaf; code = $code }
            if ($null -ne $Fingerprints) { [void]$Fingerprints.Remove($leaf) }
            if ($null -ne $RetryState) {
                $attempt = if ($RetryState.ContainsKey($leaf)) { [int]$RetryState[$leaf].attempt + 1 } else { 0 }
                $delayIndex = [Math]::Min($attempt, @($Policy.retryDelaysMilliseconds).Count - 1)
                $RetryState[$leaf] = [pscustomobject][ordered]@{
                    attempt = $attempt
                    dueUtc = [DateTime]::UtcNow.AddMilliseconds([int]$Policy.retryDelaysMilliseconds[$delayIndex])
                }
            }
        }
    }
    if ($null -ne $Fingerprints) {
        foreach ($cachedLeaf in @($Fingerprints.Keys)) {
            if (-not $presentLeaves.Contains([string]$cachedLeaf)) {
                [void]$Fingerprints.Remove($cachedLeaf)
                if ($null -ne $RetryState) { [void]$RetryState.Remove($cachedLeaf) }
            }
        }
    }
    $pendingRetryCount = if ($null -ne $RetryState) { $RetryState.Count } else { 0 }
    $removedCount = 0
    foreach ($resultEntry in $results) { $removedCount += [int]$resultEntry.removedCount }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $blocked.Count -eq 0 -and $pendingRetryCount -eq 0
        mode = 'Sweep'
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        scannedCount = $results.Count + $blocked.Count
        changedCount = @($results | Where-Object state -ceq 'modified').Count
        removedCount = $removedCount
        blockedCount = $blocked.Count
        pendingRetryCount = $pendingRetryCount
        skippedUnchangedCount = $skippedUnchangedCount
        results = @($results)
        blocked = @($blocked)
    }
}

function Get-NextWatchSweepDelayMilliseconds {
    param([Collections.IDictionary]$RetryState, [int]$DefaultMilliseconds)
    $delay = $DefaultMilliseconds
    $now = [DateTime]::UtcNow
    foreach ($retry in $RetryState.Values) {
        $candidate = [Math]::Max(100, [int][Math]::Ceiling(([DateTime]$retry.dueUtc - $now).TotalMilliseconds))
        if ($candidate -lt $delay) { $delay = $candidate }
    }
    return $delay
}

function Write-WatchState {
    param([object]$Scope, [object]$Result, [string]$StartedUtc, [string]$Status, [Collections.IDictionary]$Metrics)
    $state = [ordered]@{
        schemaVersion = 2
        pid = $PID
        startedUtc = $StartedUtc
        heartbeatUtc = [DateTime]::UtcNow.ToString('o')
        status = $Status
        catalogRoot = $Scope.catalogRoot
        metrics = [ordered]@{
            metadataProbeCount = [int64]$Metrics.metadataProbeCount
            contentReadCount = [int64]$Metrics.contentReadCount
            rewriteCount = [int64]$Metrics.rewriteCount
        }
        lastSweep = $Result
    }
    Write-AtomicText -Path $Scope.statePath -Text (($state | ConvertTo-Json -Depth 32) + "`n")
}

function Invoke-Watch {
    param([object]$Scope, [object]$Policy)

    $created = $false
    $waitHandleOptions = New-CrossSessionCurrentUserOptions
    $mutex = [Threading.Mutex]::new($false, $Scope.mutexName, $waitHandleOptions, [ref]$created)
    $mutexHeld = $false
    $stopEvent = $null
    $watcher = $null
    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $fingerprints = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $retryState = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $metrics = [ordered]@{ metadataProbeCount = [int64]0; contentReadCount = [int64]0; rewriteCount = [int64]0 }
    try {
        try { $mutexHeld = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
        if (-not $mutexHeld) { return 23 }
        $eventCreated = $false
        $stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $Scope.stopEventName, $waitHandleOptions, [ref]$eventCreated)
        if (-not $eventCreated) { $stopEvent.Reset() | Out-Null }
        Write-GuardLog -Scope $Scope -Event 'watch-start' -Fields @{ pid = $PID }
        $lastResult = Invoke-CatalogSweep -Scope $Scope -Policy $Policy -Fingerprints $fingerprints -RetryState $retryState -Metrics $metrics -Force
        Write-WatchState -Scope $Scope -Result $lastResult -StartedUtc $startedUtc -Status $(if ($lastResult.ok) { 'running' } else { 'retrying' }) -Metrics $metrics
        $watcher = [IO.FileSystemWatcher]::new($Scope.catalogRoot, '*.json')
        $watcher.IncludeSubdirectories = $false
        $watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size -bor [IO.NotifyFilters]::CreationTime
        $scanIntervalMilliseconds = [int]$Policy.scanIntervalSeconds * 1000
        if ($Scope.fixture) {
            $testInterval = [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_SCAN_INTERVAL_MILLISECONDS')
            $parsedTestInterval = 0
            if (-not [string]::IsNullOrWhiteSpace($testInterval)) {
                if (-not [int]::TryParse($testInterval, [ref]$parsedTestInterval) -or $parsedTestInterval -lt 500 -or $parsedTestInterval -gt 5000) {
                    Throw-CatalogGuardFailure 'fixture-interval-invalid' 'fixture scan interval 越界。'
                }
                $scanIntervalMilliseconds = $parsedTestInterval
            }
        }
        $nextPeriodic = [DateTime]::UtcNow.AddMilliseconds($scanIntervalMilliseconds)
        while (-not $stopEvent.WaitOne(0)) {
            $remaining = [Math]::Max(100, [Math]::Min(1000, [int]($nextPeriodic - [DateTime]::UtcNow).TotalMilliseconds))
            $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, $remaining)
            $shouldSweep = -not $change.TimedOut -or [DateTime]::UtcNow -ge $nextPeriodic
            if (-not $shouldSweep) { continue }
            if (-not $change.TimedOut) { [Threading.Thread]::Sleep([int]$Policy.debounceMilliseconds) }
            $lastResult = Invoke-CatalogSweep -Scope $Scope -Policy $Policy -Fingerprints $fingerprints -RetryState $retryState -Metrics $metrics
            Write-WatchState -Scope $Scope -Result $lastResult -StartedUtc $startedUtc -Status $(if ($lastResult.ok) { 'running' } else { 'retrying' }) -Metrics $metrics
            $nextDelay = Get-NextWatchSweepDelayMilliseconds -RetryState $retryState -DefaultMilliseconds $scanIntervalMilliseconds
            $nextPeriodic = [DateTime]::UtcNow.AddMilliseconds($nextDelay)
        }
        Write-GuardLog -Scope $Scope -Event 'watch-stop' -Fields @{ pid = $PID }
        Write-WatchState -Scope $Scope -Result $lastResult -StartedUtc $startedUtc -Status 'stopped' -Metrics $metrics
        return 0
    } finally {
        if ($null -ne $watcher) { $watcher.Dispose() }
        if ($null -ne $stopEvent) { $stopEvent.Dispose() }
        if ($mutexHeld) { try { [void]$mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

$exitCode = 0
try {
    $resolvedPolicyPath = Resolve-PolicyPath
    $policy = Read-Policy -Path $resolvedPolicyPath
    $scope = Resolve-RuntimeScope -Policy $policy
    $handleIoSource = Resolve-HandleIoSource
    if (-not ('CodexHookGovernance.VerifiedDirectoryChainGuard' -as [type])) {
        Add-Type -Path $handleIoSource -ErrorAction Stop
    }
    if (-not ('CodexCatalogGuard.DurableStagedFile' -as [type])) {
        Add-Type -TypeDefinition $durableStagedFileSource -Language CSharp -ErrorAction Stop
    }
    if ($Mode -ceq 'Audit') {
        $result = Get-CatalogAudit -Scope $scope -Policy $policy -ResolvedPolicyPath $resolvedPolicyPath
        if ($Json) { $result | ConvertTo-Json -Compress -Depth 32 } else { $result }
        if (-not $result.ok) { $exitCode = 2 }
    } elseif ($Mode -ceq 'Sweep') {
        $sweepFingerprints = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        $sweepRetryState = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $sweepMetrics = [ordered]@{ metadataProbeCount = [int64]0; contentReadCount = [int64]0; rewriteCount = [int64]0 }
        $result = Invoke-CatalogSweep -Scope $scope -Policy $policy -Fingerprints $sweepFingerprints -RetryState $sweepRetryState -Metrics $sweepMetrics -Force
        if ($Json) { $result | ConvertTo-Json -Compress -Depth 32 } else { $result }
        if (-not $result.ok) { $exitCode = 2 }
    } else {
        $exitCode = Invoke-Watch -Scope $scope -Policy $policy
    }
} catch {
    $code = Get-GuardFailureCode -Exception $_.Exception
    if (
        [Environment]::GetEnvironmentVariable($testModeEnvironment) -ceq '1' -and
        [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS') -ceq '1'
    ) {
        [Console]::Error.WriteLine($_.Exception.ToString())
    }
    if ($Json) {
        [pscustomobject][ordered]@{ schemaVersion = 1; ok = $false; mode = $Mode; error = [ordered]@{ code = $code } } | ConvertTo-Json -Compress -Depth 8
    } else {
        [Console]::Error.WriteLine("catalog guard failed: $code")
    }
    $exitCode = 3
}
exit $exitCode
