using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CodexSafeTreeDelete
{
    public interface IParallelPurgeLeafDeleter : IDisposable
    {
        void Delete(string filePath);

        void DeleteEmptyDirectories();
    }

    public sealed class FileDeleteLeafDeleter : IParallelPurgeLeafDeleter
    {
        public void Delete(string filePath)
        {
            File.Delete(filePath);
        }

        public void DeleteEmptyDirectories()
        {
        }

        public void Dispose()
        {
        }
    }

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

        public List<string> DeletedRelativePaths { get; set; }

        public bool UsedHostSafetyDeleter { get; set; }

        public ParallelPurgeResult()
        {
            Errors = new List<string>();
            DeletedRelativePaths = new List<string>();
        }
    }

    public sealed class ParallelPurgeCoordinator : IDisposable
    {
        private readonly string _targetRoot;
        private readonly string _journalRoot;
        private readonly string _allowedTargetRoot;
        private readonly string _allowedJournalRoot;
        private readonly ConcurrentBag<ThreadJournalOwner> _owners;
        private bool _disposed;

        public ParallelPurgeCoordinator(
            string targetRoot,
            string journalRoot,
            string allowedRoot,
            FileSystemCapabilities capabilities)
            : this(targetRoot, journalRoot, allowedRoot, allowedRoot, capabilities)
        {
        }

        public ParallelPurgeCoordinator(
            string targetRoot,
            string journalRoot,
            string allowedTargetRoot,
            string allowedJournalRoot,
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

            if (string.IsNullOrWhiteSpace(allowedTargetRoot))
            {
                throw new ArgumentException(
                    "allowedTargetRoot must be a non-empty path.",
                    nameof(allowedTargetRoot));
            }

            if (string.IsNullOrWhiteSpace(allowedJournalRoot))
            {
                throw new ArgumentException(
                    "allowedJournalRoot must be a non-empty path.",
                    nameof(allowedJournalRoot));
            }

            if (capabilities == null)
            {
                throw new ArgumentNullException(nameof(capabilities));
            }

            _allowedTargetRoot = Path.GetFullPath(allowedTargetRoot);
            _allowedJournalRoot = Path.GetFullPath(allowedJournalRoot);
            _targetRoot = ThreadJournalWriter.NormalizeAllowedJournalPath(
                targetRoot,
                _allowedTargetRoot,
                nameof(targetRoot));
            _journalRoot = ThreadJournalWriter.NormalizeAllowedJournalPath(
                journalRoot,
                _allowedJournalRoot,
                nameof(journalRoot));
            _owners = new ConcurrentBag<ThreadJournalOwner>();

            if (!Directory.Exists(_targetRoot))
            {
                throw new DirectoryNotFoundException(_targetRoot);
            }

            MaxDegreeOfParallelism = ResolveMaxDegreeOfParallelism(capabilities);
            GroupCommitSize = DefaultGroupCommitSize;
        }

        public const int DefaultGroupCommitSize = 32;

        public int MaxDegreeOfParallelism { get; }

        public int GroupCommitSize { get; set; }

        public JournalPerformanceReport LastJournalPerformance { get; private set; }

        public Action<string, string> AfterPendingFlushed { get; set; }

        public Func<string, IParallelPurgeLeafDeleter> CreateLeafDeleter { get; set; }

        public int FailAfterPendingFlushedCount { get; set; }

        private int _pendingHookCount;

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

        private static List<ParallelPurgeDirectoryGroup> GroupByTopLevelDirectoryForPurge(string targetRoot)
        {
            List<ParallelPurgeDirectoryGroup> raw = GroupByTopLevelDirectoryInternal(
                targetRoot,
                false);
            return raw;
        }

        private static List<ParallelPurgeDirectoryGroup> GroupByTopLevelDirectoryInternal(
            string targetRoot,
            bool rejectUnsafeKeys)
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
                    string rawKey = relative.Substring(0, sep);
                    if (IsSafeDirectoryKey(rawKey))
                    {
                        key = rawKey;
                    }
                    else if (rejectUnsafeKeys)
                    {
                        throw new ArgumentException(
                            "Top-level directory name may contain only letters, digits, dot, underscore, or hyphen.");
                    }
                    else
                    {
                        key = SanitizeDirectoryKey(rawKey);
                    }

                    topLevel = Path.Combine(root, rawKey);
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

        private static string SanitizeDirectoryKey(string directoryKey)
        {
            SHA256 hasher = SHA256.Create();
            try
            {
                byte[] hash = hasher.ComputeHash(Encoding.UTF8.GetBytes(directoryKey));
                StringBuilder builder = new StringBuilder(17);
                builder.Append('h');
                for (int i = 0; i < 8; i++)
                {
                    builder.Append(hash[i].ToString("x2"));
                }

                return builder.ToString();
            }
            finally
            {
                hasher.Dispose();
            }
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

            List<ParallelPurgeDirectoryGroup> groups = GroupByTopLevelDirectoryForPurge(_targetRoot);
            int fileCount = 0;
            for (int i = 0; i < groups.Count; i++)
            {
                fileCount += groups[i].Files.Count;
            }

            result.FileCount = fileCount;
            result.UsedHostSafetyDeleter = CreateLeafDeleter != null;
            ConcurrentBag<string> deletedRelativePaths = new ConcurrentBag<string>();

            if (!Directory.Exists(_journalRoot))
            {
                Directory.CreateDirectory(_journalRoot);
            }

            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = MaxDegreeOfParallelism;
            List<ParallelPurgeDirectoryGroup> parallelGroups = new List<ParallelPurgeDirectoryGroup>();
            List<ParallelPurgeDirectoryGroup> rootGroups = new List<ParallelPurgeDirectoryGroup>();
            for (int i = 0; i < groups.Count; i++)
            {
                if (string.Equals(groups[i].DirectoryKey, "root", StringComparison.OrdinalIgnoreCase))
                {
                    rootGroups.Add(groups[i]);
                }
                else
                {
                    parallelGroups.Add(groups[i]);
                }
            }

            try
            {
                Parallel.ForEach(parallelGroups, options, delegate(ParallelPurgeDirectoryGroup group)
                {
                    PurgeOneGroup(
                        group,
                        ref presentAfterPending,
                        errors,
                        ref deleted,
                        ref failed,
                        deletedRelativePaths,
                        ref totalFlushTimeMs,
                        ref flushCount,
                        ref slowFlushCount,
                        warningLock,
                        ref lastSlowFlushWarning);
                });
                for (int i = 0; i < rootGroups.Count; i++)
                {
                    PurgeOneGroup(
                        rootGroups[i],
                        ref presentAfterPending,
                        errors,
                        ref deleted,
                        ref failed,
                        deletedRelativePaths,
                        ref totalFlushTimeMs,
                        ref flushCount,
                        ref slowFlushCount,
                        warningLock,
                        ref lastSlowFlushWarning);
                }
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

                foreach (string relative in deletedRelativePaths)
                {
                    result.DeletedRelativePaths.Add(relative);
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

        private void PurgeOneGroup(
            ParallelPurgeDirectoryGroup group,
            ref int presentAfterPending,
            ConcurrentBag<string> errors,
            ref int deleted,
            ref int failed,
            ConcurrentBag<string> deletedRelativePaths,
            ref long totalFlushTimeMs,
            ref int flushCount,
            ref int slowFlushCount,
            object warningLock,
            ref string lastSlowFlushWarning)
        {
            ThreadJournalOwner owner = new ThreadJournalOwner(
                _journalRoot,
                group.DirectoryKey,
                _allowedJournalRoot);
            _owners.Add(owner);
            IParallelPurgeLeafDeleter deleter = null;
            try
            {
                deleter = CreateLeafDeleter != null
                    ? CreateLeafDeleter(group.TopLevelDirectory)
                    : new FileDeleteLeafDeleter();
                ThreadJournalWriter writer = owner.GetOrCreateThreadJournal();
                PurgeFilesInGroups(
                    deleter,
                    writer,
                    group.Files,
                    ref presentAfterPending,
                    errors,
                    ref deleted,
                    ref failed,
                    deletedRelativePaths);
                bool groupEmpty = true;
                for (int i = 0; i < group.Files.Count; i++)
                {
                    if (File.Exists(group.Files[i]))
                    {
                        groupEmpty = false;
                        break;
                    }
                }

                if (groupEmpty)
                {
                    deleter.DeleteEmptyDirectories();
                }
            }
            finally
            {
                if (deleter != null)
                {
                    try
                    {
                        deleter.Dispose();
                    }
                    catch (ObjectDisposedException)
                    {
                    }
                }

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
        }

        private void PurgeFilesInGroups(
            IParallelPurgeLeafDeleter deleter,
            ThreadJournalWriter writer,
            List<string> files,
            ref int presentAfterPending,
            ConcurrentBag<string> errors,
            ref int deleted,
            ref int failed,
            ConcurrentBag<string> deletedRelativePaths)
        {
            int batchSize = GroupCommitSize;
            if (batchSize < 1)
            {
                batchSize = 1;
            }

            List<string> batch = new List<string>(batchSize);
            for (int i = 0; i < files.Count; i++)
            {
                batch.Add(files[i]);
                if (batch.Count >= batchSize)
                {
                    PurgeBatch(
                        deleter,
                        writer,
                        batch,
                        ref presentAfterPending,
                        errors,
                        ref deleted,
                        ref failed,
                        deletedRelativePaths);
                    batch.Clear();
                }
            }

            if (batch.Count > 0)
            {
                PurgeBatch(
                    deleter,
                    writer,
                    batch,
                    ref presentAfterPending,
                    errors,
                    ref deleted,
                    ref failed,
                    deletedRelativePaths);
            }
        }

        private void PurgeBatch(
            IParallelPurgeLeafDeleter deleter,
            ThreadJournalWriter writer,
            List<string> batch,
            ref int presentAfterPending,
            ConcurrentBag<string> errors,
            ref int deleted,
            ref int failed,
            ConcurrentBag<string> deletedRelativePaths)
        {
            List<string> pendingLines = new List<string>(batch.Count);
            List<string> preparedPaths = new List<string>(batch.Count);
            List<string> commitLines = new List<string>(batch.Count);

            for (int i = 0; i < batch.Count; i++)
            {
                string filePath = batch[i];
                try
                {
                    if (!ThreadJournalWriter.IsUnderAllowedRoot(filePath, _allowedTargetRoot))
                    {
                        throw new InvalidOperationException(
                            "Refusing to delete a path outside the allowed root.");
                    }

                    string relative = filePath.Substring(_targetRoot.Length).TrimStart(
                        Path.DirectorySeparatorChar,
                        Path.AltDirectorySeparatorChar);
                    string relJson = relative.Replace('\\', '/');
                    string pending = "{\"op\":\"pending\",\"path\":\"" + EscapeJson(relJson) + "\"}";
                    writer.WriteEntry(pending);
                    pendingLines.Add(pending);
                    preparedPaths.Add(filePath);
                }
                catch (Exception ex)
                {
                    Interlocked.Increment(ref failed);
                    errors.Add(filePath + ": " + ex.Message);
                }
            }

            if (pendingLines.Count == 0)
            {
                return;
            }

            // All pending lines in this batch must be durable before any delete.
            writer.Flush();
            VerifyPendingVisible(writer.JournalFilePath, pendingLines);

            for (int i = 0; i < preparedPaths.Count; i++)
            {
                string filePath = preparedPaths[i];
                try
                {
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

                    if (FailAfterPendingFlushedCount > 0 &&
                        Interlocked.Increment(ref _pendingHookCount) >= FailAfterPendingFlushedCount)
                    {
                        throw new InvalidOperationException(
                            "forced-interrupt after pending flush");
                    }

                    deleter.Delete(filePath);

                    string relative = filePath.Substring(_targetRoot.Length).TrimStart(
                        Path.DirectorySeparatorChar,
                        Path.AltDirectorySeparatorChar);
                    string relJson = relative.Replace('\\', '/');
                    commitLines.Add("{\"op\":\"commit\",\"path\":\"" + EscapeJson(relJson) + "\"}");
                    deletedRelativePaths.Add(relJson);
                    Interlocked.Increment(ref deleted);
                }
                catch (Exception ex)
                {
                    Interlocked.Increment(ref failed);
                    errors.Add(filePath + ": " + ex.Message);
                }
            }

            if (commitLines.Count == 0)
            {
                return;
            }

            for (int i = 0; i < commitLines.Count; i++)
            {
                writer.WriteEntry(commitLines[i]);
            }

            // Successful deletes get a durable commit before this batch returns.
            writer.Flush();
        }

        private static void VerifyPendingVisible(string journalPath, IList<string> pendingLines)
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
                    for (int i = 0; i < pendingLines.Count; i++)
                    {
                        if (text.IndexOf(pendingLines[i], StringComparison.Ordinal) < 0)
                        {
                            throw new InvalidOperationException(
                                "pending entry was not visible on a second handle before delete.");
                        }
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
