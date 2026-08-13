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
}
