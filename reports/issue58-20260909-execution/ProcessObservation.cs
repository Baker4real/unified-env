using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Issue58N1 {
    public static class ProcessMetrics {
        [StructLayout(LayoutKind.Sequential)] public struct IoCounters { public ulong ReadOperations,WriteOperations,OtherOperations,ReadBytes,WriteBytes,OtherBytes; }
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessIoCounters(IntPtr process,out IoCounters counters);
        public static IoCounters Io(Process process) { IoCounters result; if(!GetProcessIoCounters(process.Handle,out result)) throw new Win32Exception(); return result; }
    }
    public sealed class TaskJob : IDisposable {
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, IntPtr info, uint size, out uint returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint length);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int cls, IntPtr info, int size, out int returned);
        IntPtr handle;
        public TaskJob() { handle=CreateJobObject(IntPtr.Zero,null); if(handle==IntPtr.Zero) throw new Win32Exception(); }
        public void Assign(Process process) { if(!AssignProcessToJobObject(handle,process.Handle)) throw new Win32Exception(); }
        public static string Image(Process process) {
            var text=new StringBuilder(32768); uint length=32768;
            if(!QueryFullProcessImageName(process.Handle,0,text,ref length)) throw new Win32Exception();
            return text.ToString();
        }
        public static int Parent(Process process) {
            IntPtr buffer=Marshal.AllocHGlobal(IntPtr.Size*6);
            try {
                int returned;
                if(NtQueryInformationProcess(process.Handle,0,buffer,IntPtr.Size*6,out returned)!=0) throw new InvalidOperationException("parent-observation-unavailable");
                return checked((int)Marshal.ReadIntPtr(buffer,IntPtr.Size*5).ToInt64());
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        public int[] Pids() {
            IntPtr buffer=Marshal.AllocHGlobal(65536);
            try {
                uint returned;
                if(!QueryInformationJobObject(handle,3,buffer,65536,out returned)) throw new Win32Exception();
                int count=Marshal.ReadInt32(buffer,4);
                if(count<0 || count>(65536-8)/IntPtr.Size) throw new InvalidDataException("job-pid-list-overflow");
                var ids=new int[count];
                for(int i=0;i<count;i++) ids[i]=checked((int)Marshal.ReadIntPtr(buffer,8+i*IntPtr.Size).ToInt64());
                return ids;
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        public void TerminateVerifiedMembers() { if(!TerminateJobObject(handle,124)) throw new Win32Exception(); }
        public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
    }

    public sealed class WriteObservation : IDisposable {
        readonly List<FileSystemWatcher> watchers=new List<FileSystemWatcher>();
        readonly ConcurrentQueue<string> errors=new ConcurrentQueue<string>();
        long events, overflow, changed, created, deleted, renamed;
        public long EventCount { get { return Interlocked.Read(ref events); } }
        public long OverflowCount { get { return Interlocked.Read(ref overflow); } }
        public string[] Errors { get { return errors.ToArray(); } }
        public int WatcherCount { get { return watchers.Count; } }
        public long[] KindCounts { get { return new[]{Interlocked.Read(ref changed),Interlocked.Read(ref created),Interlocked.Read(ref deleted),Interlocked.Read(ref renamed)}; } }
        public DateTime StartedAtUtc { get; private set; }
        public WriteObservation(string evidence, string policy) {
            StartedAtUtc=DateTime.UtcNow;
            Add(evidence,"*",true);
            Add(Path.GetDirectoryName(evidence),Path.GetFileName(evidence),false);
            Add(Path.GetDirectoryName(policy),Path.GetFileName(policy),false);
        }
        void Add(string path,string filter,bool recursive) {
            try {
                var watcher=new FileSystemWatcher(path,filter);
                watcher.IncludeSubdirectories=recursive;
                watcher.InternalBufferSize=65536;
                watcher.NotifyFilter=NotifyFilters.FileName|NotifyFilters.DirectoryName|NotifyFilters.LastWrite|NotifyFilters.Size|NotifyFilters.Attributes|NotifyFilters.Security|NotifyFilters.CreationTime;
                watcher.Changed+=(s,e)=>{Interlocked.Increment(ref events);Interlocked.Increment(ref changed);};
                watcher.Created+=(s,e)=>{Interlocked.Increment(ref events);Interlocked.Increment(ref created);};
                watcher.Deleted+=(s,e)=>{Interlocked.Increment(ref events);Interlocked.Increment(ref deleted);};
                watcher.Renamed+=(s,e)=>{Interlocked.Increment(ref events);Interlocked.Increment(ref renamed);};
                watcher.Error+=(s,e)=>{
                    if(e.GetException() is InternalBufferOverflowException) Interlocked.Increment(ref overflow);
                    errors.Enqueue(e.GetException().GetType().Name);
                };
                watcher.EnableRaisingEvents=true;
                watchers.Add(watcher);
            } catch(Exception e) { errors.Enqueue(e.GetType().Name); }
        }
        public void SimulateOverflowForTest() { Interlocked.Increment(ref overflow); }
        public void Dispose() { foreach(var watcher in watchers) watcher.Dispose(); }
    }
}
