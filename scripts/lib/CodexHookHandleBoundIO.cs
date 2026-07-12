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
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
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
                FileShare.Read | FileShare.Write,
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
}
