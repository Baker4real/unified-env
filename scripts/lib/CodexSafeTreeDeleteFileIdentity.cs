using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexSafeTreeDelete
{
    public sealed class FileIdentityV2 : IEquatable<FileIdentityV2>
    {
        public ulong VolumeSerialNumber { get; set; }

        public byte[] FileId128 { get; set; }

        public long FileSize { get; set; }

        public DateTime LastWriteTimeUtc { get; set; }

        public DateTime CapturedAtUtc { get; set; }

        public bool Equals(FileIdentityV2 other)
        {
            if (other is null)
            {
                return false;
            }

            if (ReferenceEquals(this, other))
            {
                return true;
            }

            return VolumeSerialNumber == other.VolumeSerialNumber
                && FileSize == other.FileSize
                && LastWriteTimeUtc == other.LastWriteTimeUtc
                && FileId128ContentEquals(FileId128, other.FileId128);
        }

        public override bool Equals(object obj)
        {
            return obj is FileIdentityV2 other && Equals(other);
        }

        public override int GetHashCode()
        {
            if (FileId128 == null || FileId128.Length < 8)
            {
                throw new InvalidOperationException(
                    "FileIdentityV2.FileId128 must contain at least 8 bytes to compute a hash.");
            }

            unchecked
            {
                int hash = 17;
                hash = hash * 31 + VolumeSerialNumber.GetHashCode();
                hash = hash * 31 + FileSize.GetHashCode();
                hash = hash * 31 + LastWriteTimeUtc.GetHashCode();
                hash = hash * 31 + BitConverter.ToInt64(FileId128, 0).GetHashCode();
                return hash;
            }
        }

        public static bool operator ==(FileIdentityV2 left, FileIdentityV2 right)
        {
            if (ReferenceEquals(left, right))
            {
                return true;
            }

            if (left is null || right is null)
            {
                return false;
            }

            return left.Equals(right);
        }

        public static bool operator !=(FileIdentityV2 left, FileIdentityV2 right)
        {
            return !(left == right);
        }

        private static bool FileId128ContentEquals(byte[] left, byte[] right)
        {
            if (ReferenceEquals(left, right))
            {
                return true;
            }

            if (left is null || right is null)
            {
                return false;
            }

            return left.SequenceEqual(right);
        }
    }

    public static class FileIdentityReader
    {
        // FILE_INFO_BY_HANDLE_CLASS.FileIdInfo
        private const int FileIdInfo = 18;
        private const uint GenericRead = 0x80000000;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        // 16 scalar bytes: a managed byte[] is a pointer and cannot be the P/Invoke layout.
        [StructLayout(LayoutKind.Sequential)]
        private struct FILE_ID_128
        {
            public byte B0, B1, B2, B3, B4, B5, B6, B7;
            public byte B8, B9, B10, B11, B12, B13, B14, B15;

            public byte[] ToArray()
            {
                return new[]
                {
                    B0, B1, B2, B3, B4, B5, B6, B7,
                    B8, B9, B10, B11, B12, B13, B14, B15
                };
            }
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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

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

        public static FileIdentityV2 GetFileIdentityV2(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("path must be a non-empty file path.", nameof(path));
            }

            string fullPath = Path.GetFullPath(path);
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(fullPath),
                GenericRead,
                FileShare.ReadWrite | FileShare.Delete,
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
                    "Failed to open path for FILE_ID_INFO without following reparse points.");
            }

            using (handle)
            {
                return GetFileIdentityV2(handle);
            }
        }

        public static FileIdentityV2 GetFileIdentityV2(SafeFileHandle handle)
        {
            if (handle == null || handle.IsInvalid)
            {
                throw new ArgumentException("handle must be a valid file handle.", nameof(handle));
            }

            FILE_ID_INFO fileIdInfo = new FILE_ID_INFO();
            if (!GetFileInformationByHandleEx(
                handle,
                FileIdInfo,
                ref fileIdInfo,
                Marshal.SizeOf<FILE_ID_INFO>()))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(
                    error,
                    "Failed to get FILE_ID_INFO. This file system may not support 128-bit FileId.");
            }

            BY_HANDLE_FILE_INFORMATION fileInfo;
            if (!GetFileInformationByHandle(handle, out fileInfo))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "Failed to get file information.");
            }

            long fileSize = ((long)fileInfo.nFileSizeHigh << 32) | fileInfo.nFileSizeLow;
            long ftLastWriteTime =
                ((long)fileInfo.ftLastWriteTime.dwHighDateTime << 32) |
                fileInfo.ftLastWriteTime.dwLowDateTime;

            return new FileIdentityV2
            {
                VolumeSerialNumber = fileIdInfo.VolumeSerialNumber,
                FileId128 = fileIdInfo.FileId.ToArray(),
                FileSize = fileSize,
                LastWriteTimeUtc = DateTime.FromFileTimeUtc(ftLastWriteTime),
                CapturedAtUtc = DateTime.UtcNow
            };
        }
    }

    public sealed class FileSystemCapabilities
    {
        public string FileSystemType { get; set; }

        public bool IsRemote { get; set; }

        public bool SupportsFileId128 { get; set; }

        public bool RecommendHashReuse { get; set; }

        public bool RecommendParallel { get; set; }

        public int RecommendedMaxParallelism { get; set; }

        public bool DeletionAllowed { get; set; }

        // #40 2026-08-19 remeasure (reports/safe-tree-delete-parallelism-benchmark-20260819):
        // peak parallel efficiency (speedup/DOP) was 2 for all three fixture size classes.
        // Ticket assumed small=4 / min(4, ProcessorCount-2); dataSupportsTicketSuggestion=false.
        private const int SmallFilePeakEfficiencyDop = 2;
        private const int MediumFilePeakEfficiencyDop = 2;
        private const int LargeFilePeakEfficiencyDop = 2;
        private const long MediumFileSizeThresholdBytes = 10L * 1024L;
        private const long LargeFileSizeThresholdBytes = 1024L * 1024L;

        public static int RecommendOptimizeMaxParallelism()
        {
            // Size-unknown default follows the typical small-file peak, not wall-clock min (16).
            return RecommendMaxParallelismForTypicalFileBytes(1024);
        }

        public static int RecommendMaxParallelismForTypicalFileBytes(long typicalFileBytes)
        {
            if (typicalFileBytes <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(typicalFileBytes));
            }

            if (typicalFileBytes >= LargeFileSizeThresholdBytes)
            {
                return LargeFilePeakEfficiencyDop;
            }

            if (typicalFileBytes >= MediumFileSizeThresholdBytes)
            {
                return MediumFilePeakEfficiencyDop;
            }

            return SmallFilePeakEfficiencyDop;
        }

        public static FileSystemCapabilities FromDetection(
            string fileSystemType,
            bool isRemote,
            bool supportsFileId128)
        {
            if (string.IsNullOrWhiteSpace(fileSystemType))
            {
                throw new ArgumentException(
                    "fileSystemType must be a non-empty file system name.",
                    nameof(fileSystemType));
            }

            bool fatFamily = string.Equals(fileSystemType, "FAT32", StringComparison.OrdinalIgnoreCase)
                || string.Equals(fileSystemType, "exFAT", StringComparison.OrdinalIgnoreCase);
            bool localNtfsFamily = !isRemote
                && (string.Equals(fileSystemType, "NTFS", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(fileSystemType, "ReFS", StringComparison.OrdinalIgnoreCase));
            bool supports = supportsFileId128 && !fatFamily;
            bool optimize = localNtfsFamily && supports;

            return new FileSystemCapabilities
            {
                FileSystemType = fileSystemType,
                IsRemote = isRemote,
                SupportsFileId128 = supports,
                RecommendHashReuse = optimize,
                RecommendParallel = optimize,
                RecommendedMaxParallelism = optimize ? RecommendOptimizeMaxParallelism() : 1,
                DeletionAllowed = supports
            };
        }
    }

    public static class FileSystemDetector
    {
        public static FileSystemCapabilities DetectFileSystem(string targetPath)
        {
            if (string.IsNullOrWhiteSpace(targetPath))
            {
                throw new ArgumentException("targetPath must be a non-empty path.", nameof(targetPath));
            }

            string fullPath = Path.GetFullPath(targetPath);
            string root = Path.GetPathRoot(fullPath);
            if (string.IsNullOrEmpty(root))
            {
                throw new ArgumentException("targetPath must include a drive root.", nameof(targetPath));
            }

            DriveInfo driveInfo = new DriveInfo(root);
            return FileSystemCapabilities.FromDetection(
                driveInfo.DriveFormat,
                driveInfo.DriveType == DriveType.Network,
                TestFileIdSupport(fullPath));
        }

        public static bool TestFileIdSupport(string path)
        {
            try
            {
                FileIdentityReader.GetFileIdentityV2(path);
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    public sealed class LeafStreamSetV1
    {
        public FileIdentityV2 Identity { get; set; }

        public string[] StreamNames { get; set; }

        public uint NumberOfLinks { get; set; }

        public bool IsDirectory { get; set; }

        public bool IsReparsePoint { get; set; }
    }

    public static class LeafStreamSetReader
    {
        // FILE_INFO_BY_HANDLE_CLASS.FileStreamInfo
        private const int FileStreamInfo = 7;
        private const int ErrorMoreData = 234;
        private const int ErrorHandleEof = 38;
        private const int StreamHeaderLength = 24;
        private const uint GenericRead = 0x80000000;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;

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

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle hFile,
            out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle hFile,
            int fileInformationClass,
            IntPtr fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

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

        /// <summary>
        /// Captures the complete NTFS stream-set of one leaf from a single handle:
        /// raw FILE_STREAM_INFORMATION names (ordinal-sorted), the hard-link count,
        /// and the handle-bound <see cref="FileIdentityV2"/>. Reparse points are
        /// opened as reparse points, never followed.
        /// </summary>
        public static LeafStreamSetV1 CaptureLeafStreamSet(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("path must be a non-empty leaf path.", nameof(path));
            }

            string fullPath = Path.GetFullPath(path);
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(fullPath),
                GenericRead,
                FileShare.ReadWrite | FileShare.Delete,
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
                    "Failed to open leaf for stream-set capture without following reparse points.");
            }

            using (handle)
            {
                return CaptureLeafStreamSet(handle);
            }
        }

        public static LeafStreamSetV1 CaptureLeafStreamSet(SafeFileHandle handle)
        {
            if (handle == null || handle.IsInvalid)
            {
                throw new ArgumentException("handle must be a valid leaf handle.", nameof(handle));
            }

            BY_HANDLE_FILE_INFORMATION fileInfo;
            if (!GetFileInformationByHandle(handle, out fileInfo))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "Failed to get leaf file information.");
            }

            return new LeafStreamSetV1
            {
                Identity = FileIdentityReader.GetFileIdentityV2(handle),
                StreamNames = ReadStreamNames(handle),
                NumberOfLinks = fileInfo.nNumberOfLinks,
                IsDirectory = (fileInfo.dwFileAttributes & FileAttributeDirectory) != 0,
                IsReparsePoint = (fileInfo.dwFileAttributes & FileAttributeReparsePoint) != 0
            };
        }

        private static string[] ReadStreamNames(SafeFileHandle handle)
        {
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
                            "Unable to enumerate streams for the leaf stream-set handle.");
                    }

                    System.Collections.Generic.List<string> names =
                        new System.Collections.Generic.List<string>();
                    int offset = 0;
                    while (true)
                    {
                        if (offset < 0 || offset + StreamHeaderLength > bufferLength)
                        {
                            throw new IOException(
                                "The leaf stream enumeration returned an invalid record.");
                        }

                        int nextOffset = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 4);
                        if (nameLength < 0 || (nameLength & 1) != 0 ||
                            offset + StreamHeaderLength + nameLength > bufferLength)
                        {
                            throw new IOException(
                                "The leaf stream enumeration returned an invalid name.");
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
                                "The leaf stream enumeration returned a duplicate stream name.");
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
    }
}
