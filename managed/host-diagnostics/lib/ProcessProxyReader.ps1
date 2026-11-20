function Initialize-ProxyReader {
    if ('HostDiagnostics.ProxyReader' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace HostDiagnostics {
    public static class ProxyReader {
        [StructLayout(LayoutKind.Sequential)] private struct BasicInfo {
            public IntPtr Reserved1, Peb, Reserved2a, Reserved2b, Pid, Reserved3;
        }
        [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern bool IsWow64Process(IntPtr handle, out bool wow64);
        [DllImport("kernel32.dll")] private static extern bool GetProcessTimes(IntPtr handle, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool ReadProcessMemory(IntPtr handle, IntPtr address, byte[] data, UIntPtr size, out UIntPtr read);
        [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(IntPtr handle, int kind, ref BasicInfo info, int size, out int returned);
        private static byte[] Read(IntPtr handle, long address, int size) {
            if (address <= 0) throw new InvalidOperationException("layout-unavailable");
            var data = new byte[size];
            if (!ReadProcessMemory(handle,new IntPtr(address),data,new UIntPtr((uint)size),out var count) || count.ToUInt64() != (ulong)size)
                throw new InvalidOperationException("memory-unavailable");
            return data;
        }
        private static long Pointer(IntPtr handle, long address) { return BitConverter.ToInt64(Read(handle,address,8),0); }
        public static Dictionary<string,string> ReadProxy(int pid, long expectedCreation) {
            if (IntPtr.Size != 8 || RuntimeInformation.OSArchitecture != Architecture.X64)
                throw new InvalidOperationException("unsupported-architecture");
            var handle = OpenProcess(0x410,false,pid);
            if (handle == IntPtr.Zero) throw new InvalidOperationException("process-unavailable");
            try {
                if (!GetProcessTimes(handle,out var creation,out _,out _,out _) || creation != expectedCreation)
                    throw new InvalidOperationException("identity-changed");
                if (!IsWow64Process(handle,out var wow64) || wow64) throw new InvalidOperationException("unsupported-architecture");
                var info = new BasicInfo();
                if (NtQueryInformationProcess(handle,0,ref info,Marshal.SizeOf<BasicInfo>(),out _) != 0 || info.Pid.ToInt64() != pid)
                    throw new InvalidOperationException("layout-unavailable");
                long parameters = Pointer(handle,info.Peb.ToInt64()+0x20);
                long environment = Pointer(handle,parameters+0x80);
                long length = Pointer(handle,parameters+0x3F0);
                if (length < 2 || length > 1024*1024 || length % 2 != 0) throw new InvalidOperationException("layout-unavailable");
                var entries = new UnicodeEncoding(false,false,true).GetString(Read(handle,environment,(int)length)).Split('\0');
                var selected = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in entries) {
                    int split = entry.IndexOf('=');
                    if (split <= 0) continue;
                    string key = entry.Substring(0,split).ToUpperInvariant();
                    if (key == "HTTP_PROXY" || key == "HTTPS_PROXY" || key == "ALL_PROXY" || key == "NO_PROXY")
                        selected[key] = entry.Substring(split+1);
                }
                return selected;
            } finally { CloseHandle(handle); }
        }
    }
}
'@ | Out-Null
}
