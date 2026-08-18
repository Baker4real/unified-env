using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CodexSafeTreeDelete
{
    public sealed class ParallelPurgeDirectoryGroup
    {
        public ParallelPurgeDirectoryGroup(string directoryKey, string topLevelDirectory)
        {
            DirectoryKey = directoryKey;
            TopLevelDirectory = topLevelDirectory;
            Files = new List<string>();
        }

        public string DirectoryKey { get; }

        public string TopLevelDirectory { get; }

        public List<string> Files { get; }
    }

    public sealed class ParallelPurgeResult
    {
        public int FileCount { get; set; }

        public int DeletedCount { get; set; }

        public int FailedCount { get; set; }

        public int JournalFileCount { get; set; }

        public int FilesPresentAfterPending { get; set; }

        public long ElapsedMs { get; set; }

        public JournalPerformanceReport JournalPerformance { get; set; }

        public List<string> Errors { get; set; }

        public ParallelPurgeResult()
        {
            Errors = new List<string>();
        }
    }

    public sealed class ParallelPurgeCoordinator : IDisposable
    {
        private readonly string _targetRoot;
        private readonly string _journalRoot;
        private readonly string _allowedRoot;
        private readonly ConcurrentBag<ThreadJournalOwner> _owners;
        private bool _disposed;

        public ParallelPurgeCoordinator(
            string targetRoot,
            string journalRoot,
            string allowedRoot,
            FileSystemCapabilities capabilities)
        {
            if (string.IsNullOrWhiteSpace(targetRoot))
            {
                throw new ArgumentException("targetRoot must be a non-empty path.", nameof(targetRoot));
            }

            if (string.IsNullOrWhiteSpace(journalRoot))
            {
                throw new ArgumentException("journalRoot must be a non-empty path.", nameof(journalRoot));
            }

            if (string.IsNullOrWhiteSpace(allowedRoot))
            {
                throw new ArgumentException("allowedRoot must be a non-empty path.", nameof(allowedRoot));
            }

            if (capabilities == null)
            {
                throw new ArgumentNullException(nameof(capabilities));
            }

            _allowedRoot = Path.GetFullPath(allowedRoot);
            _targetRoot = ThreadJournalWriter.NormalizeAllowedJournalPath(
                targetRoot,
                _allowedRoot,
                nameof(targetRoot));
            _journalRoot = ThreadJournalWriter.NormalizeAllowedJournalPath(
                journalRoot,
                _allowedRoot,
                nameof(journalRoot));
            _owners = new ConcurrentBag<ThreadJournalOwner>();

            if (!Directory.Exists(_targetRoot))
            {
                throw new DirectoryNotFoundException(_targetRoot);
            }

            MaxDegreeOfParallelism = ResolveMaxDegreeOfParallelism(capabilities);
        }

        public int MaxDegreeOfParallelism { get; }

        public JournalPerformanceReport LastJournalPerformance { get; private set; }

        public Action<string, string> AfterPendingFlushed { get; set; }

        public static int ResolveMaxDegreeOfParallelism(FileSystemCapabilities capabilities)
        {
            if (capabilities == null)
            {
                throw new ArgumentNullException(nameof(capabilities));
            }

            if (!capabilities.RecommendParallel)
            {
                return 1;
            }

            int dop = capabilities.RecommendedMaxParallelism;
            if (dop < 1)
            {
                return 1;
            }

            return dop;
        }

        public static List<ParallelPurgeDirectoryGroup> GroupByTopLevelDirectory(string targetRoot)
        {
            if (string.IsNullOrWhiteSpace(targetRoot))
            {
                throw new ArgumentException("targetRoot must be a non-empty path.", nameof(targetRoot));
            }

            string root = Path.GetFullPath(targetRoot);
            if (!Directory.Exists(root))
            {
                throw new DirectoryNotFoundException(root);
            }

            Dictionary<string, ParallelPurgeDirectoryGroup> map =
                new Dictionary<string, ParallelPurgeDirectoryGroup>(StringComparer.OrdinalIgnoreCase);

            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                string fullFile = Path.GetFullPath(file);
                string relative = fullFile.Substring(root.Length).TrimStart(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar);
                if (relative.Length == 0)
                {
                    continue;
                }

                int sep = IndexOfDirSep(relative);
                string key;
                string topLevel;
                if (sep < 0)
                {
                    key = "root";
                    topLevel = root;
                }
                else
                {
                    key = relative.Substring(0, sep);
                    if (!IsSafeDirectoryKey(key))
                    {
                        throw new ArgumentException(
                            "Top-level directory name may contain only letters, digits, dot, underscore, or hyphen.");
                    }

                    topLevel = Path.Combine(root, key);
                }

                ParallelPurgeDirectoryGroup group;
                if (!map.TryGetValue(key, out group))
                {
                    group = new ParallelPurgeDirectoryGroup(key, topLevel);
                    map[key] = group;
                }

                group.Files.Add(fullFile);
            }

            List<ParallelPurgeDirectoryGroup> groups = new List<ParallelPurgeDirectoryGroup>();
            foreach (KeyValuePair<string, ParallelPurgeDirectoryGroup> pair in map)
            {
                groups.Add(pair.Value);
            }

            return groups;
        }

        public ParallelPurgeResult Purge()
        {
            ThrowIfDisposed();
            Stopwatch clock = Stopwatch.StartNew();
            ParallelPurgeResult result = new ParallelPurgeResult();
            ConcurrentBag<string> errors = new ConcurrentBag<string>();
            int deleted = 0;
            int failed = 0;
            int presentAfterPending = 0;
            long totalFlushTimeMs = 0;
            int flushCount = 0;
            int slowFlushCount = 0;
            string lastSlowFlushWarning = null;
            object warningLock = new object();

            List<ParallelPurgeDirectoryGroup> groups = GroupByTopLevelDirectory(_targetRoot);
            int fileCount = 0;
            for (int i = 0; i < groups.Count; i++)
            {
                fileCount += groups[i].Files.Count;
            }

            result.FileCount = fileCount;

            if (!Directory.Exists(_journalRoot))
            {
                Directory.CreateDirectory(_journalRoot);
            }

            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = MaxDegreeOfParallelism;

            try
            {
                Parallel.ForEach(groups, options, delegate(ParallelPurgeDirectoryGroup group)
                {
                    ThreadJournalOwner owner = new ThreadJournalOwner(
                        _journalRoot,
                        group.DirectoryKey,
                        _allowedRoot);
                    _owners.Add(owner);
                    try
                    {
                        ThreadJournalWriter writer = owner.GetOrCreateThreadJournal();
                        for (int i = 0; i < group.Files.Count; i++)
                        {
                            string filePath = group.Files[i];
                            try
                            {
                                PurgeOneFile(writer, filePath, ref presentAfterPending);
                                Interlocked.Increment(ref deleted);
                            }
                            catch (Exception ex)
                            {
                                Interlocked.Increment(ref failed);
                                errors.Add(filePath + ": " + ex.Message);
                            }
                        }
                    }
                    finally
                    {
                        try
                        {
                            foreach (ThreadJournalWriter tracked in owner.Values)
                            {
                                Interlocked.Add(ref totalFlushTimeMs, tracked.TotalFlushTimeMs);
                                Interlocked.Add(ref flushCount, tracked.FlushCount);
                                Interlocked.Add(ref slowFlushCount, tracked.SlowFlushCount);
                                string warning = tracked.LastSlowFlushWarning;
                                if (!string.IsNullOrEmpty(warning))
                                {
                                    lock (warningLock)
                                    {
                                        lastSlowFlushWarning = warning;
                                    }
                                }
                            }
                        }
                        catch (ObjectDisposedException)
                        {
                        }

                        owner.Dispose();
                    }
                });
            }
            finally
            {
                DisposeOwners();
                clock.Stop();
                result.DeletedCount = deleted;
                result.FailedCount = failed;
                result.FilesPresentAfterPending = presentAfterPending;
                result.ElapsedMs = clock.ElapsedMilliseconds;
                result.JournalFileCount = CountJournalFiles();
                result.JournalPerformance = JournalPerformanceReport.FromTotals(
                    totalFlushTimeMs,
                    flushCount,
                    result.ElapsedMs,
                    slowFlushCount,
                    lastSlowFlushWarning);
                LastJournalPerformance = result.JournalPerformance;
                foreach (string error in errors)
                {
                    result.Errors.Add(error);
                }
            }

            return result;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            try
            {
                DisposeOwners();
            }
            finally
            {
                _disposed = true;
            }
        }

        private void PurgeOneFile(
            ThreadJournalWriter writer,
            string filePath,
            ref int presentAfterPending)
        {
            if (!ThreadJournalWriter.IsUnderAllowedRoot(filePath, _allowedRoot))
            {
                throw new InvalidOperationException(
                    "Refusing to delete a path outside the allowed root.");
            }

            string relative = filePath.Substring(_targetRoot.Length).TrimStart(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            string relJson = relative.Replace('\\', '/');
            string pending = "{\"op\":\"pending\",\"path\":\"" + EscapeJson(relJson) + "\"}";
            string commit = "{\"op\":\"commit\",\"path\":\"" + EscapeJson(relJson) + "\"}";

            writer.WriteEntry(pending);
            writer.Flush();
            VerifyPendingVisible(writer.JournalFilePath, pending);
            if (!File.Exists(filePath))
            {
                throw new InvalidOperationException(
                    "target file was missing after pending flush and before delete.");
            }

            Interlocked.Increment(ref presentAfterPending);

            Action<string, string> hook = AfterPendingFlushed;
            if (hook != null)
            {
                hook(writer.JournalFilePath, filePath);
            }

            File.Delete(filePath);

            writer.WriteEntry(commit);
            writer.Flush();
        }

        private static void VerifyPendingVisible(string journalPath, string pendingLine)
        {
            FileStream stream = new FileStream(
                journalPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite);
            try
            {
                StreamReader reader = new StreamReader(
                    stream,
                    new UTF8Encoding(false),
                    false,
                    1024,
                    true);
                try
                {
                    string text = reader.ReadToEnd();
                    if (text.IndexOf(pendingLine, StringComparison.Ordinal) < 0)
                    {
                        throw new InvalidOperationException(
                            "pending entry was not visible on a second handle before delete.");
                    }
                }
                finally
                {
                    reader.Dispose();
                }
            }
            finally
            {
                stream.Dispose();
            }
        }

        private void DisposeOwners()
        {
            ThreadJournalOwner owner;
            while (_owners.TryTake(out owner))
            {
                try
                {
                    owner.Dispose();
                }
                catch (ObjectDisposedException)
                {
                }
            }
        }

        private int CountJournalFiles()
        {
            if (!Directory.Exists(_journalRoot))
            {
                return 0;
            }

            string[] files = Directory.GetFiles(_journalRoot, "*.jsonl", SearchOption.TopDirectoryOnly);
            return files.Length;
        }

        private void ThrowIfDisposed()
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(ParallelPurgeCoordinator));
            }
        }

        private static int IndexOfDirSep(string relative)
        {
            for (int i = 0; i < relative.Length; i++)
            {
                char c = relative[i];
                if (c == Path.DirectorySeparatorChar || c == Path.AltDirectorySeparatorChar)
                {
                    return i;
                }
            }

            return -1;
        }

        private static bool IsSafeDirectoryKey(string directoryKey)
        {
            if (string.IsNullOrEmpty(directoryKey))
            {
                return false;
            }

            for (int i = 0; i < directoryKey.Length; i++)
            {
                char c = directoryKey[i];
                if (char.IsLetterOrDigit(c) || c == '.' || c == '_' || c == '-')
                {
                    continue;
                }

                return false;
            }

            return true;
        }

        private static string EscapeJson(string value)
        {
            return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }
    }
}
