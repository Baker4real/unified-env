using System;
using System.ComponentModel;
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

        private static string GetFinalPath(SafeFileHandle handle)
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

        private static string NormalizeFinalPath(string path)
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
}
