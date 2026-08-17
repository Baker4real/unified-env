using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace CodexSafeTreeDelete
{
    public sealed class ThreadJournalWriter : IDisposable
    {
        // 2-arg ctor default only: keep #38 tests working. New callers inject allowedRoot.
        internal const string LegacyAllowedJournalRootForTests =
            @"D:\Codex\projects\统一环境\reports\safe-tree-delete-issue38-20260817";

        private readonly string _allowedJournalRoot;
        private FileStream _fileStream;
        private StreamWriter _streamWriter;
        private long _totalFlushTicks;
        private int _flushCount;
        private int _slowFlushCount;
        private string _lastSlowFlushWarning;
        private bool _disposed;

        public ThreadJournalWriter(string journalFilePath, int threadId)
            : this(journalFilePath, threadId, LegacyAllowedJournalRootForTests)
        {
        }

        public ThreadJournalWriter(string journalFilePath, int threadId, string allowedJournalRoot)
        {
            if (string.IsNullOrWhiteSpace(journalFilePath))
            {
                throw new ArgumentException("journalFilePath must be a non-empty path.", nameof(journalFilePath));
            }

            if (string.IsNullOrWhiteSpace(allowedJournalRoot))
            {
                throw new ArgumentException(
                    "allowedJournalRoot must be a non-empty path.",
                    nameof(allowedJournalRoot));
            }

            _allowedJournalRoot = Path.GetFullPath(allowedJournalRoot);
            string fullPath = NormalizeAllowedJournalPath(
                journalFilePath,
                _allowedJournalRoot,
                nameof(journalFilePath));
            JournalFilePath = fullPath;
            ThreadId = threadId;

            _fileStream = new FileStream(
                fullPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.Read,
                4096,
                FileOptions.None);
            _streamWriter = new StreamWriter(
                _fileStream,
                new UTF8Encoding(false),
                4096,
                true);
        }

        public string JournalFilePath { get; }

        public int ThreadId { get; }

        public long TotalFlushTimeMs
        {
            get { return _totalFlushTicks / TimeSpan.TicksPerMillisecond; }
        }

        public int FlushCount
        {
            get { return _flushCount; }
        }

        public int SlowFlushCount
        {
            get { return _slowFlushCount; }
        }

        public string LastSlowFlushWarning
        {
            get { return _lastSlowFlushWarning; }
        }

        public void WriteEntry(string entry)
        {
            ThrowIfDisposed();
            if (entry == null)
            {
                throw new ArgumentNullException(nameof(entry));
            }

            if (entry.Length == 0)
            {
                throw new ArgumentException("Journal entry must be non-empty.", nameof(entry));
            }

            if (entry.IndexOf('\n') >= 0 || entry.IndexOf('\r') >= 0)
            {
                throw new ArgumentException("Journal entry must be a single line.", nameof(entry));
            }

            _streamWriter.Write(entry);
            _streamWriter.Write('\n');
        }

        public void Flush()
        {
            ThrowIfDisposed();
            Stopwatch clock = Stopwatch.StartNew();
            _streamWriter.Flush();
            _fileStream.Flush(true);
            clock.Stop();
            _totalFlushTicks += clock.Elapsed.Ticks;
            _flushCount++;
            long elapsedMs = clock.ElapsedMilliseconds;
            if (elapsedMs > 100)
            {
                _slowFlushCount++;
                _lastSlowFlushWarning = string.Format(
                    CultureInfo.InvariantCulture,
                    "Slow journal flush: {0}ms exceeded 100ms threshold (thread {1}).",
                    elapsedMs,
                    ThreadId);
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            try
            {
                if (_streamWriter != null)
                {
                    _streamWriter.Flush();
                    _streamWriter.Dispose();
                    _streamWriter = null;
                }

                if (_fileStream != null)
                {
                    _fileStream.Flush(true);
                    _fileStream.Dispose();
                    _fileStream = null;
                }
            }
            finally
            {
                _disposed = true;
            }
        }

        internal static string NormalizeAllowedJournalPath(string path, string paramName)
        {
            return NormalizeAllowedJournalPath(path, LegacyAllowedJournalRootForTests, paramName);
        }

        internal static string NormalizeAllowedJournalPath(
            string path,
            string allowedJournalRoot,
            string paramName)
        {
            if (string.IsNullOrWhiteSpace(allowedJournalRoot))
            {
                throw new ArgumentException(
                    "allowedJournalRoot must be a non-empty path.",
                    nameof(allowedJournalRoot));
            }

            string fullPath = Path.GetFullPath(path);
            string allowedRoot = Path.GetFullPath(allowedJournalRoot);
            if (!IsUnderAllowedRoot(fullPath, allowedRoot))
            {
                throw new ArgumentException(
                    "Journal path must be under the injected allowed journal root.",
                    paramName);
            }

            return fullPath;
        }

        internal static bool IsUnderAllowedRoot(string fullPath, string allowedRoot)
        {
            if (fullPath.Equals(allowedRoot, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            char separator = Path.DirectorySeparatorChar;
            string prefix = allowedRoot.TrimEnd(separator) + separator;
            return fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }

        private void ThrowIfDisposed()
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(ThreadJournalWriter));
            }
        }
    }

    public sealed class JournalPerformanceReport
    {
        public const double TargetOverheadPercent = 10.0;

        public long TotalFlushTimeMs { get; private set; }

        public int FlushCount { get; private set; }

        public double OverheadPercent { get; private set; }

        public bool IsWithinTarget { get; private set; }

        public string Warning { get; private set; }

        public int SlowFlushCount { get; private set; }

        public string LastSlowFlushWarning { get; private set; }

        public static JournalPerformanceReport FromTotals(
            long totalFlushTimeMs,
            int flushCount,
            long totalOperationTimeMs)
        {
            return FromTotals(totalFlushTimeMs, flushCount, totalOperationTimeMs, 0, null);
        }

        public static JournalPerformanceReport FromTotals(
            long totalFlushTimeMs,
            int flushCount,
            long totalOperationTimeMs,
            int slowFlushCount,
            string lastSlowFlushWarning)
        {
            if (totalFlushTimeMs < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(totalFlushTimeMs));
            }

            if (flushCount < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(flushCount));
            }

            if (totalOperationTimeMs < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(totalOperationTimeMs));
            }

            if (slowFlushCount < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(slowFlushCount));
            }

            double overheadPercent = 0.0;
            if (totalOperationTimeMs > 0)
            {
                overheadPercent = (totalFlushTimeMs * 100.0) / totalOperationTimeMs;
            }

            bool withinTarget = overheadPercent < TargetOverheadPercent;
            string warning = null;
            if (!withinTarget)
            {
                warning = string.Format(
                    CultureInfo.InvariantCulture,
                    "Journal flush overhead is {0:0.###}% (>= 10%). Consider reducing parallelism or checking disk performance.",
                    overheadPercent);
            }

            JournalPerformanceReport report = new JournalPerformanceReport();
            report.TotalFlushTimeMs = totalFlushTimeMs;
            report.FlushCount = flushCount;
            report.OverheadPercent = overheadPercent;
            report.IsWithinTarget = withinTarget;
            report.Warning = warning;
            report.SlowFlushCount = slowFlushCount;
            report.LastSlowFlushWarning = lastSlowFlushWarning;
            return report;
        }
    }

    public sealed class ThreadJournalOwner : IDisposable
    {
        private readonly string _journalDirectory;
        private readonly string _directoryKey;
        private readonly string _allowedJournalRoot;
        private readonly ThreadLocal<ThreadJournalWriter> _threadJournals;
        private bool _disposed;

        public ThreadJournalOwner(string journalDirectory, string directoryKey)
            : this(journalDirectory, directoryKey, ThreadJournalWriter.LegacyAllowedJournalRootForTests)
        {
        }

        public ThreadJournalOwner(string journalDirectory, string directoryKey, string allowedJournalRoot)
        {
            if (string.IsNullOrWhiteSpace(journalDirectory))
            {
                throw new ArgumentException("journalDirectory must be a non-empty path.", nameof(journalDirectory));
            }

            if (string.IsNullOrWhiteSpace(directoryKey))
            {
                throw new ArgumentException("directoryKey must be a non-empty token.", nameof(directoryKey));
            }

            if (!IsSafeDirectoryKey(directoryKey))
            {
                throw new ArgumentException(
                    "directoryKey may contain only letters, digits, dot, underscore, or hyphen.",
                    nameof(directoryKey));
            }

            if (string.IsNullOrWhiteSpace(allowedJournalRoot))
            {
                throw new ArgumentException(
                    "allowedJournalRoot must be a non-empty path.",
                    nameof(allowedJournalRoot));
            }

            _allowedJournalRoot = Path.GetFullPath(allowedJournalRoot);
            string fullDirectory = ThreadJournalWriter.NormalizeAllowedJournalPath(
                journalDirectory,
                _allowedJournalRoot,
                nameof(journalDirectory));
            if (!Directory.Exists(fullDirectory))
            {
                throw new DirectoryNotFoundException(fullDirectory);
            }

            _journalDirectory = fullDirectory;
            _directoryKey = directoryKey;
            _threadJournals = new ThreadLocal<ThreadJournalWriter>(
                CreateWriterForCurrentThread,
                true);
        }

        public string JournalDirectory
        {
            get { return _journalDirectory; }
        }

        public string DirectoryKey
        {
            get { return _directoryKey; }
        }

        public IList<ThreadJournalWriter> Values
        {
            get
            {
                ThrowIfDisposed();
                return _threadJournals.Values;
            }
        }

        public ThreadJournalWriter GetOrCreateThreadJournal()
        {
            ThrowIfDisposed();
            return _threadJournals.Value;
        }

        public int[] GetOrCreateOnNewThreads(int threadCount, string entry, bool throwAfterWrite)
        {
            ThrowIfDisposed();
            if (threadCount < 1)
            {
                throw new ArgumentOutOfRangeException(nameof(threadCount));
            }

            int[] threadIds = new int[threadCount];
            Thread[] threads = new Thread[threadCount];
            Exception[] errors = new Exception[threadCount];
            for (int i = 0; i < threadCount; i++)
            {
                int index = i;
                threads[i] = new Thread(() =>
                {
                    try
                    {
                        ThreadJournalWriter writer = GetOrCreateThreadJournal();
                        writer.WriteEntry(entry);
                        writer.Flush();
                        threadIds[index] = writer.ThreadId;
                        if (throwAfterWrite)
                        {
                            throw new InvalidOperationException("work-failed");
                        }
                    }
                    catch (Exception ex)
                    {
                        errors[index] = ex;
                    }
                });
                threads[i].IsBackground = true;
                threads[i].Start();
            }

            for (int i = 0; i < threadCount; i++)
            {
                threads[i].Join();
            }

            for (int i = 0; i < threadCount; i++)
            {
                if (errors[i] != null)
                {
                    throw errors[i];
                }
            }

            return threadIds;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            List<Exception> errors = null;
            try
            {
                foreach (ThreadJournalWriter writer in _threadJournals.Values)
                {
                    try
                    {
                        writer.Dispose();
                    }
                    catch (Exception ex)
                    {
                        if (errors == null)
                        {
                            errors = new List<Exception>();
                        }

                        errors.Add(ex);
                    }
                }
            }
            finally
            {
                _threadJournals.Dispose();
                _disposed = true;
            }

            if (errors != null)
            {
                throw new AggregateException(errors);
            }
        }

        private ThreadJournalWriter CreateWriterForCurrentThread()
        {
            int threadId = Environment.CurrentManagedThreadId;
            string fileName = _directoryKey + ".thread-" + threadId.ToString() + ".jsonl";
            string journalFilePath = Path.Combine(_journalDirectory, fileName);
            return new ThreadJournalWriter(journalFilePath, threadId, _allowedJournalRoot);
        }

        private void ThrowIfDisposed()
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(ThreadJournalOwner));
            }
        }

        private static bool IsSafeDirectoryKey(string directoryKey)
        {
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
    }
}
