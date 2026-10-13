using System;
using System.Buffers;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Enumeration;
using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace CodexSafeTreeDelete
{
    // Moved verbatim from the former inline Add-Type block in CodexSafeTreeDelete.ps1 so the
    // batch-compiled safe-tree-delete assembly can reuse it from the Status fast scanner.
    public static class StatusJsonTopLevelReader {
        public static Dictionary<string, JsonElement> ReadWanted(string jsonText, string[] names) {
            if (jsonText == null) {
                throw new ArgumentNullException("jsonText");
            }
            if (names == null) {
                throw new ArgumentNullException("names");
            }

            HashSet<string> wanted = new HashSet<string>(names, StringComparer.Ordinal);
            byte[] utf8 = Encoding.UTF8.GetBytes(jsonText);
            Utf8JsonReader reader = new Utf8JsonReader(utf8, new JsonReaderOptions {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 128
            });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) {
                throw new InvalidOperationException("safe-delete Status JSON 必须是 object。");
            }

            Dictionary<string, JsonElement> map = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            while (reader.Read()) {
                if (reader.TokenType == JsonTokenType.EndObject) {
                    break;
                }
                if (reader.TokenType != JsonTokenType.PropertyName) {
                    throw new InvalidOperationException("safe-delete Status JSON 属性名非法。");
                }

                string name = reader.GetString();
                if (!reader.Read()) {
                    throw new InvalidOperationException("safe-delete Status JSON 截断。");
                }
                if (wanted.Contains(name)) {
                    if (map.ContainsKey(name)) {
                        throw new InvalidOperationException("safe-delete Status JSON 顶层属性重复。");
                    }
                    using (JsonDocument valueDoc = JsonDocument.ParseValue(ref reader)) {
                        map[name] = valueDoc.RootElement.Clone();
                    }
                } else {
                    reader.Skip();
                }
            }

            return map;
        }
    }

    /// <summary>
    /// Deterministic validation failure whose message is reproduced verbatim from the
    /// PowerShell reference implementation. Archived records turn these into fallbacks;
    /// the active rejected-plan flow turns them into final per-record outcomes.
    /// </summary>
    internal sealed class StatusScanUserException : Exception
    {
        public StatusScanUserException(string message) : base(message) { }
    }

    /// <summary>
    /// Hands the record back to the PowerShell reference path. Used whenever the C# replica
    /// cannot prove the exact PowerShell outcome (unusual JSON types, IO errors, deep nesting).
    /// </summary>
    internal sealed class StatusScanFallbackException : Exception
    {
        public StatusScanFallbackException(string reason) : base(reason) { }
    }

    public sealed class StatusScanPolicyEntry
    {
        public string Id { get; set; }
        public string CapabilityRoot { get; set; }
        public long MinimumDescendantDepth { get; set; }
        public string RootDeletionPurpose { get; set; }
        public bool AllowHardLinks { get; set; }
        public bool AllowInternalDirectoryJunctions { get; set; }
        public List<string> DeniedExactPaths { get; set; }
    }

    public sealed class StatusScanPolicy
    {
        public string Path { get; set; }
        public string Sha256 { get; set; }
        public List<StatusScanPolicyEntry> Entries { get; set; }
    }

    public sealed class StatusScanRunInput
    {
        public int Index { get; set; }
        public string Name { get; set; }
        public string FullName { get; set; }
        public bool IsContainer { get; set; }
        public bool IsReparsePoint { get; set; }
    }

    public sealed class StatusPlanValidationReceipt
    {
        private readonly string planSha256;
        private readonly string planText;
        private readonly string planPath;

        internal StatusPlanValidationReceipt(string planSha256, string planText, string planPath)
        {
            this.planSha256 = planSha256;
            this.planText = planText;
            this.planPath = planPath;
        }

        public bool MatchesSnapshot(string sha256, string text)
        {
            // issue #58 N4: PowerShell's method binder deep-copies large string
            // arguments (~2 UTF-16 copies per argument before the method body runs;
            // a 109M-char plan snapshot cost ~12s per call). Receipt gates on big
            // snapshots must therefore run inside C# on the same instances the
            // scanner validated; the reference shortcut keeps that O(1).
            return (ReferenceEquals(planSha256, sha256) ||
                    string.Equals(planSha256, sha256, StringComparison.Ordinal)) &&
                (ReferenceEquals(planText, text) ||
                    string.Equals(planText, text, StringComparison.Ordinal));
        }

        // issue #58 N4: short-argument content binding for the marshaling-free gate;
        // the plan SHA-256 is the content identity the whole approval chain relies on.
        public bool MatchesPlanSha256(string sha256)
        {
            return string.Equals(planSha256, sha256, StringComparison.Ordinal);
        }

        public bool MatchesPlanPath(string path)
        {
            return string.Equals(planPath, path, StringComparison.OrdinalIgnoreCase);
        }
    }

    public sealed class StatusScanResult
    {
        public int Index;
        public bool Handled;
        public bool Archived;
        public string FallbackReason;
        public bool RequiresRebuiltTargetIdentity;
        public string[] ExpectedTargetRootIdentity;
        public string CapabilityRoot;
        // The canonical approved-plan checks completed before handing the record to the
        // PowerShell resolver. The resolver may reuse only the matching plan snapshot.
        public StatusPlanValidationReceipt ApprovedPlanValidation { get; internal set; }
        // Plan snapshot for PowerShell fallback reuse (avoids a second read of plan.json).
        public string PlanSha256;
        public string PlanText;
        // issue #58 N3: precomputed treeManifest SHA for planned (no-transaction) fallback ops,
        // spread across scan workers instead of the single fallback worker owning the tree
        // scan; null when not computed (transaction present, or streaming SHA fell back).
        public string PlanManifestSha256;
        // issue #58 N4: plan field values from the same JsonDocument the receipt validation
        // parsed, so the receipt-gated fallback fast path never re-parses multi-MB plan text.
        // Normalized with AssertDPath where applicable; any null entry makes the fast path
        // decline to the reference resolver (which owns full semantics).
        public string ReceiptPlanTargetPath;
        public string ReceiptPlanQuarantinePath;
        public string ReceiptPlanCapabilityRoot;
        public string ReceiptPlanPolicySha256;
        // Operation payload (mirrors Resolve-CodexSafeTreeDeleteStatusOperation output shape).
        public string OperationId;
        public string RunDirectory;
        public string Lifecycle;
        public string[] SafeActions;
        public string TargetPath;
        public string QuarantinePath;
        public bool HasNamespace;
        public bool TargetPresent;
        public bool QuarantinePresent;
        public string TargetEntryType;
        public string QuarantineEntryType;
        public bool NamespaceAbsent;
        public bool LogicalCompletion;
        public bool PolicyCompatible;
        public bool SchemaCompatible;
        public bool HasPlanSchemaVersion;
        public long PlanSchemaVersion;
        public bool HasTransactionSchemaVersion;
        public long TransactionSchemaVersion;
        public string TransactionStatus;
        public string TransactionUpdatedAtUtc;
        public string JournalStatus;
        public string[] Errors;
        // Metrics (mirrors the PowerShell metrics observer for the same reads).
        public long BytesHashed;
        public long LogicalBytes;
        public long PlanTransactionReadMs;
        public long TerminalArchiveAuthMs;
        public long Sha256Ms;

        // issue #58 N4: marshaling-free receipt gate. The PowerShell resolvers hand
        // back only this object reference (property reads are copy-free, while a
        // 109M-char string argument would be deep-copied by the method binder); the
        // receipt/snapshot compare runs here on the same instances the scanner
        // validated.
        public bool ValidateReceiptAgainstOwnSnapshot()
        {
            StatusPlanValidationReceipt receipt = ApprovedPlanValidation;
            return receipt != null &&
                receipt.MatchesSnapshot(PlanSha256, PlanText);
        }
    }

    internal sealed class StatusScanFileSnapshot
    {
        public byte[] Bytes;
        public string Sha256;
        public string IdentityVolume;
        public string IdentityIndex;
        public string Text;
        public long ReadMs;
        public long HashMs;
    }

    /// <summary>Local replica of the governance HandlePathMismatchException signal.</summary>
    internal sealed class StatusScanPathMismatchException : Exception
    {
        public StatusScanPathMismatchException() : base(
            "The opened file handle resolved to a different final path.") { }
    }

    public static class StatusScanCoordinator
    {
        private const uint InvalidFileAttributes = 0xFFFFFFFF;
        private const uint FileAttributeReparsePoint = 0x400;
        private const uint FileNameNormalized = 0x0;
        private const int ErrorFileNotFound = 2;
        private const int ErrorPathNotFound = 3;
        private static readonly char[] InvalidFileNameChars = Path.GetInvalidFileNameChars();

        private static readonly Regex LowerHex64 = new Regex("^[0-9a-f]{64}$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex LowerHex8 = new Regex("^[0-9a-f]{8}$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex LowerHex16 = new Regex("^[0-9a-f]{16}$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex ReservedName = new Regex("^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", RegexOptions.Compiled);

        // Producer-canonical property-name sets. The fast path only decides documents whose
        // keys match these exactly (ordinal); anything else falls back because PowerShell's
        // property-set checks and member access are case-insensitive while this replica is not.
        private static readonly string[] PlanCanonicalNames = new string[] {
            "artifactType", "schemaVersion", "generationId", "createdAtUtc", "expiresAtUtc",
            "policyPath", "policySha256", "policyEntryId", "targetPath", "capabilityRoot",
            "treeManifest", "summary", "fileIdentitiesV2", "leafStreamSetV1"
        };
        private static readonly string[] PlanRequiredNames = new string[] {
            "artifactType", "schemaVersion", "generationId", "createdAtUtc", "expiresAtUtc",
            "policyPath", "policySha256", "policyEntryId", "targetPath", "capabilityRoot",
            "treeManifest", "summary"
        };
        private static readonly string[] ManifestCanonicalNames = new string[] {
            "schemaVersion", "rootIdentity", "entries"
        };
        private static readonly string[] ManifestEntryCanonicalNames = new string[] {
            "relativePath", "kind", "sha256", "identity"
        };
        private static readonly string[] TransactionV1CanonicalNames = new string[] {
            "artifactType", "schemaVersion", "generationId", "planPath", "planSha256",
            "targetPath", "quarantinePath", "status", "updatedAtUtc"
        };
        private static readonly string[] TransactionV2CanonicalNames = new string[] {
            "artifactType", "schemaVersion", "generationId", "planPath", "planSha256",
            "targetPath", "quarantinePath", "directoryCommitAnchors", "status", "updatedAtUtc"
        };
        private static readonly string[] TransactionV3CanonicalNames = new string[] {
            "artifactType", "schemaVersion", "generationId", "planPath", "planSha256",
            "targetPath", "quarantinePath", "directoryCommitAnchors", "status", "updatedAtUtc",
            "quarantineTimeAnchor", "restoreJournalAnchors"
        };

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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFileAttributesW(string fileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle fileHandle,
            System.Text.StringBuilder filePath,
            uint filePathLength,
            uint flags);

        /// <summary>
        /// Replicates CodexHookGovernance.HandleBoundFileReader.OpenVerifiedReadHandle without
        /// taking an assembly dependency on the cached native library: open read-only with the
        /// lexical path and verify the final path still matches.
        /// </summary>
        private static SafeFileHandle OpenVerifiedReadHandleLocal(string lexicalPath)
        {
            SafeFileHandle handle = File.OpenHandle(
                lexicalPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                FileOptions.SequentialScan);
            try
            {
                uint capacity = 512;
                while (true)
                {
                    System.Text.StringBuilder buffer = new System.Text.StringBuilder(checked((int)capacity));
                    uint result = GetFinalPathNameByHandleW(handle, buffer, capacity, FileNameNormalized);
                    if (result == 0)
                    {
                        throw new StatusScanFallbackException("final-path-query-failed");
                    }
                    if (result < capacity)
                    {
                        string finalPath = NormalizeFinalPath(buffer.ToString());
                        if (!string.Equals(lexicalPath, finalPath, StringComparison.OrdinalIgnoreCase))
                        {
                            throw new StatusScanPathMismatchException();
                        }
                        return handle;
                    }
                    capacity = checked(result + 1);
                }
            }
            catch (Exception)
            {
                handle.Dispose();
                throw;
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

        public static List<StatusScanResult> Scan(
            List<StatusScanRunInput> runs,
            StatusScanPolicy policy,
            string evidenceRoot,
            int maxDegreeOfParallelism)
        {
            if (runs == null) { throw new ArgumentNullException("runs"); }
            if (policy == null) { throw new ArgumentNullException("policy"); }
            if (string.IsNullOrWhiteSpace(evidenceRoot)) { throw new ArgumentNullException("evidenceRoot"); }

            string fullEvidenceRoot = AssertDPath(evidenceRoot, "safe-delete status evidence root");
            StatusScanResult[] results = new StatusScanResult[runs.Count];
            int dop = maxDegreeOfParallelism < 1 ? 1 : maxDegreeOfParallelism;
            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = dop;

            Parallel.For(0, runs.Count, options, delegate(int index)
            {
                StatusScanResult result = new StatusScanResult();
                result.Index = index;
                try
                {
                    ScanOne(runs[index], policy, fullEvidenceRoot, result);
                }
                catch (StatusScanFallbackException fallback)
                {
                    result.Handled = false;
                    result.FallbackReason = fallback.Message;
                }
                catch (StatusScanUserException user)
                {
                    // This archive rejection is already the reference path's complete
                    // per-operation result. Keep the exact error and avoid re-reading the
                    // same three archive files through PowerShell; other user exceptions
                    // still fall back because their reference state may require more context.
                    if (string.Equals(
                            user.Message,
                            "safe-delete terminal archive 引用越出 operation run。",
                            StringComparison.Ordinal))
                    {
                        FinishRejectedOutcome(
                            result, runs[index], new string[] { user.Message },
                            null, null, null, null, "unknown", "unknown",
                            false, 0L, false, 0L, null, null, "not-evaluated");
                        results[index] = result;
                        return;
                    }
                    // Only the archived flow lets user exceptions escape per-record; it always
                    // falls back so PowerShell reproduces the exact message.
                    result.Handled = false;
                    result.FallbackReason = "validation-failure:" + user.Message;
                }
                catch (Exception ex)
                {
                    result.Handled = false;
                    result.FallbackReason = "unexpected:" + ex.GetType().Name;
                }
                results[index] = result;
            });

            List<StatusScanResult> list = new List<StatusScanResult>(results.Length);
            for (int i = 0; i < results.Length; i++)
            {
                if (results[i] == null)
                {
                    StatusScanResult missing = new StatusScanResult();
                    missing.Index = i;
                    missing.Handled = false;
                    missing.FallbackReason = "missing-result";
                    results[i] = missing;
                }
                list.Add(results[i]);
            }
            return list;
        }

        // ---------------------------------------------------------------- #80 scope prefilter

        private const int ScopeClaimInitialBytes = 4096;
        private const int ScopeClaimMaxBytes = 65536;

        /// <summary>
        /// Status 范围查询的枚举阶段预筛（语义与前提见 PowerShell 侧
        /// Select-CodexSafeTreeDeleteStatusScopeRunItems）。返回与 runs 等长的保留标记：只有能证明
        /// 在范围外的规范形态记录得到 false。只读；任何异常都按保留处理。
        /// </summary>
        public static bool[] SelectScopeCandidates(
            List<StatusScanRunInput> runs,
            string[] scopeTargets,
            string evidenceRoot,
            int maxDegreeOfParallelism)
        {
            if (runs == null) { throw new ArgumentNullException("runs"); }
            if (scopeTargets == null) { throw new ArgumentNullException("scopeTargets"); }
            if (string.IsNullOrWhiteSpace(evidenceRoot)) { throw new ArgumentNullException("evidenceRoot"); }

            string fullEvidenceRoot = AssertDPath(evidenceRoot, "safe-delete status evidence root");
            string[] targets = (string[])scopeTargets.Clone();
            bool[] keep = new bool[runs.Count];
            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = maxDegreeOfParallelism < 1 ? 1 : maxDegreeOfParallelism;
            Parallel.For(0, runs.Count, options, delegate(int index)
            {
                bool keepRun = true;
                try
                {
                    keepRun = !IsScopeClaimOutside(runs[index], targets, fullEvidenceRoot);
                }
                catch (Exception)
                {
                    keepRun = true;
                }
                keep[index] = keepRun;
            });
            return keep;
        }

        private static bool IsScopeClaimOutside(
            StatusScanRunInput run, string[] scopeTargets, string fullEvidenceRoot)
        {
            // 规范形态判定与 ScanOne、参考路径相同；不满足的记录由完整认证报告为 manual-review。
            if (run == null || !run.IsContainer || run.IsReparsePoint)
            {
                return false;
            }
            string runDirectory = AssertDPath(run.FullName, "safe-delete status run");
            AssertCapabilityPath(runDirectory, fullEvidenceRoot, runDirectory, "safe-delete status run");
            // 与完整认证选同一份文件：有 terminal-archive.json 时走 archived 认证，否则读 plan.json。
            string claimPath = Path.Combine(runDirectory, "terminal-archive.json");
            if (!File.Exists(claimPath))
            {
                claimPath = Path.Combine(runDirectory, "plan.json");
                if (!File.Exists(claimPath))
                {
                    return false;
                }
            }
            string claim = ReadScopeClaim(claimPath);
            if (claim == null)
            {
                return false;
            }
            string fullClaim = AssertDPathQuiet(claim);
            if (fullClaim == null)
            {
                return false;
            }
            foreach (string target in scopeTargets)
            {
                if (PathEqual(claim, target) || PathEqual(fullClaim, target))
                {
                    return false;
                }
            }
            return true;
        }

        // 读文件开头至多 ScopeClaimMaxBytes 字节，取顶层对象里第一个属性名（按 ordinal）为
        // targetPath 的 JSON string。读不到、读不全或任何解析错误都返回 null。
        private static string ReadScopeClaim(string path)
        {
            string lexicalPath = Path.GetFullPath(path);
            using (SafeFileHandle handle = OpenVerifiedReadHandleLocal(lexicalPath))
            using (FileStream stream = new FileStream(handle, FileAccess.Read, 1))
            {
                long fileLength = stream.Length;
                int limit = (int)Math.Min(fileLength, (long)ScopeClaimMaxBytes);
                byte[] buffer = new byte[limit];
                int length = 0;
                int want = Math.Min(limit, ScopeClaimInitialBytes);
                while (true)
                {
                    while (length < want)
                    {
                        int read = stream.Read(buffer, length, want - length);
                        if (read <= 0)
                        {
                            return null;
                        }
                        length += read;
                    }
                    bool needMore;
                    string claim = TryReadScopeClaim(buffer, length, length == fileLength, out needMore);
                    if (!needMore)
                    {
                        return claim;
                    }
                    if (length >= limit)
                    {
                        return null;
                    }
                    want = (int)Math.Min((long)limit, (long)want * 2);
                }
            }
        }

        private static string TryReadScopeClaim(
            byte[] buffer, int length, bool isFinalBlock, out bool needMore)
        {
            needMore = false;
            int offset = length >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF ? 3 : 0;
            JsonReaderOptions readerOptions = new JsonReaderOptions {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 128
            };
            Utf8JsonReader reader = new Utf8JsonReader(
                new ReadOnlySpan<byte>(buffer, offset, length - offset),
                isFinalBlock,
                new JsonReaderState(readerOptions));
            try
            {
                if (!reader.Read())
                {
                    needMore = !isFinalBlock;
                    return null;
                }
                if (reader.TokenType != JsonTokenType.StartObject)
                {
                    return null;
                }
                while (reader.Read())
                {
                    if (reader.TokenType != JsonTokenType.PropertyName)
                    {
                        // 顶层对象已结束，没有 targetPath。
                        return null;
                    }
                    bool isTargetPath = reader.ValueTextEquals("targetPath");
                    if (!reader.Read())
                    {
                        needMore = !isFinalBlock;
                        return null;
                    }
                    if (isTargetPath)
                    {
                        return reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
                    }
                    if (!reader.TrySkip())
                    {
                        needMore = !isFinalBlock;
                        return null;
                    }
                }
                needMore = !isFinalBlock;
                return null;
            }
            catch (Exception)
            {
                needMore = false;
                return null;
            }
        }

        private static void ScanOne(
            StatusScanRunInput run,
            StatusScanPolicy policy,
            string fullEvidenceRoot,
            StatusScanResult result)
        {
            if (!run.IsContainer || run.IsReparsePoint)
            {
                throw new StatusScanFallbackException("run-not-container");
            }
            string runDirectory = AssertDPath(run.FullName, "safe-delete status run");
            AssertCapabilityPath(runDirectory, fullEvidenceRoot, runDirectory, "safe-delete status run");

            string archivePath = Path.Combine(runDirectory, "terminal-archive.json");
            string planPath = Path.Combine(runDirectory, "plan.json");
            if (File.Exists(archivePath))
            {
                ScanArchived(run, policy, fullEvidenceRoot, runDirectory, result);
                return;
            }
            if (!File.Exists(planPath))
            {
                throw new StatusScanFallbackException("missing-plan");
            }
            ScanActive(run, policy, runDirectory, result);
        }

        // ---------------------------------------------------------------- archived fast path

        private static void ScanArchived(
            StatusScanRunInput run,
            StatusScanPolicy policy,
            string fullEvidenceRoot,
            string runDirectory,
            StatusScanResult result)
        {
            string archivePath = ResolveManagedFilePath(
                runDirectory, fullEvidenceRoot, "terminal-archive.json", "safe-delete status terminal archive");
            string planPath = ResolveManagedFilePath(
                runDirectory, fullEvidenceRoot, "plan.json", "safe-delete status archive plan");
            string transactionPath = ResolveManagedFilePath(
                runDirectory, fullEvidenceRoot, "transaction.json", "safe-delete status archive transaction");

            StatusScanFileSnapshot archiveSnapshot = ReadFileChecked(
                archivePath, "safe-delete status terminal archive", true, result);
            StatusScanFileSnapshot planSnapshot = ReadFileChecked(
                planPath, "safe-delete status archive plan", false, result);
            StatusScanFileSnapshot transactionSnapshot = ReadFileChecked(
                transactionPath, "safe-delete status archive transaction", false, result);

            int archiveDepth = AssertStrictJsonText(archiveSnapshot.Text);
            if (archiveDepth > 28)
            {
                // ConvertFrom-Json -Depth 32 in the reference path decides this case.
                throw new StatusScanFallbackException("archive-depth-limit");
            }

            using (JsonDocument archiveDocument = ParseJsonDocument(archiveSnapshot.Text))
            {
                JsonElement archive = archiveDocument.RootElement;
                if (archive.ValueKind != JsonValueKind.Object)
                {
                    throw new StatusScanFallbackException("archive-not-object");
                }
                AssertExactProperties(archive, new string[] {
                    "artifactType", "schemaVersion", "generationId",
                    "planPath", "planSha256", "planIdentity",
                    "transactionPath", "transactionSha256", "transactionIdentity",
                    "transactionSchemaVersion", "transactionStatus", "transactionUpdatedAtUtc",
                    "targetPath", "quarantinePath", "quarantineAbsent",
                    "restoreJournalAnchorCount", "archivedAtUtc"
                }, "safe-delete terminal archive");

                foreach (string stringProperty in new string[] {
                        "artifactType", "generationId", "planPath", "planSha256",
                        "transactionPath", "transactionSha256", "transactionStatus",
                        "transactionUpdatedAtUtc", "targetPath", "quarantinePath", "archivedAtUtc"})
                {
                    if (!IsStringProperty(archive, stringProperty))
                    {
                        throw new StatusScanUserException(
                            "safe-delete terminal archive " + stringProperty + " 必须是 JSON string。");
                    }
                }

                DateTimeOffset archivedAtUtc;
                long archiveSchemaVersion = RequireInt64(archive, "schemaVersion");
                long archiveTransactionSchemaVersion = RequireInt64(archive, "transactionSchemaVersion");
                long archiveRestoreJournalAnchorCount = RequireInt64(archive, "restoreJournalAnchorCount");
                if (GetString(archive, "artifactType") != "env-governance.codex-safe-tree-delete-terminal-archive" ||
                    archiveSchemaVersion != 1L ||
                    archiveTransactionSchemaVersion < 1L || archiveTransactionSchemaVersion > 3L ||
                    !IsBoolPropertyTrue(archive, "quarantineAbsent") ||
                    archiveRestoreJournalAnchorCount != 0L ||
                    GetString(archive, "transactionStatus") != "purged" ||
                    !DateTimeOffset.TryParseExact(
                        GetString(archive, "archivedAtUtc"),
                        "o",
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.RoundtripKind,
                        out archivedAtUtc))
                {
                    throw new StatusScanUserException("safe-delete terminal archive schema 或判据声明非法。");
                }

                if (!PathEqual(GetString(archive, "planPath"), planPath) ||
                    !PathEqual(GetString(archive, "transactionPath"), transactionPath))
                {
                    throw new StatusScanUserException("safe-delete terminal archive 引用越出 operation run。");
                }
                if (GetString(archive, "planSha256") != planSnapshot.Sha256 ||
                    GetString(archive, "transactionSha256") != transactionSnapshot.Sha256)
                {
                    throw new StatusScanUserException("safe-delete terminal archive 与当前受管 evidence 内容不一致。");
                }
                string[] archivePlanIdentity = RequireIdentityArray(archive, "planIdentity");
                string[] archiveTransactionIdentity = RequireIdentityArray(archive, "transactionIdentity");
                AssertDirectoryTreeIdentity(
                    archivePlanIdentity,
                    new string[] { planSnapshot.IdentityVolume, planSnapshot.IdentityIndex },
                    "safe-delete terminal archive plan");
                AssertDirectoryTreeIdentity(
                    archiveTransactionIdentity,
                    new string[] { transactionSnapshot.IdentityVolume, transactionSnapshot.IdentityIndex },
                    "safe-delete terminal archive transaction");

                Dictionary<string, JsonElement> planBindings = StatusJsonTopLevelReader.ReadWanted(
                    planSnapshot.Text,
                    new string[] { "artifactType", "schemaVersion", "generationId", "targetPath", "policySha256" });
                string planArtifactType = BindingString(planBindings, "artifactType", "safe-delete status archive plan");
                long planSchemaVersion = BindingInt64(planBindings, "schemaVersion", "safe-delete status archive plan");
                string planGenerationId = BindingString(planBindings, "generationId", "safe-delete status archive plan");
                string planTargetPath = BindingString(planBindings, "targetPath", "safe-delete status archive plan");
                string planPolicySha256 = BindingString(planBindings, "policySha256", "safe-delete status archive plan");
                Guid planGuid;
                if (planArtifactType != "env-governance.codex-safe-tree-delete-plan" ||
                    planSchemaVersion != 1L ||
                    !Guid.TryParseExact(planGenerationId, "D", out planGuid) ||
                    !LowerHex64.IsMatch(planPolicySha256))
                {
                    throw new StatusScanUserException("safe-delete status archive plan artifact/schema 非法。");
                }
                string expectedTargetPath = AssertDPath(planTargetPath, "safe-delete status archive plan target");
                string expectedQuarantinePath = DeriveQuarantinePath(expectedTargetPath, planGenerationId);

                Dictionary<string, JsonElement> transactionBindings = StatusJsonTopLevelReader.ReadWanted(
                    transactionSnapshot.Text,
                    new string[] {
                        "schemaVersion", "status", "updatedAtUtc", "generationId",
                        "planPath", "planSha256", "targetPath", "quarantinePath",
                        "restoreJournalAnchors"
                    });
                long transactionSchemaVersion = BindingInt64(
                    transactionBindings, "schemaVersion", "safe-delete status archive transaction");
                if (transactionSchemaVersion < 1L || transactionSchemaVersion > 3L)
                {
                    throw new StatusScanUserException(
                        "safe-delete status archive transaction schemaVersion 必须是 JSON integer 1、2 或 3。");
                }

                string transactionStatus;
                string transactionUpdatedAtUtc;
                string sourceTargetPath;
                string sourceQuarantinePath;
                long liveRestoreJournalAnchorCount;
                if (transactionSchemaVersion == 1L)
                {
                    if (AssertStrictJsonText(transactionSnapshot.Text) > 28)
                    {
                        throw new StatusScanFallbackException("v1-transaction-depth-limit");
                    }
                    using (JsonDocument transactionDocument = ParseJsonDocument(transactionSnapshot.Text))
                    {
                        ObservedV1Transaction observed = ReadObservedV1Transaction(
                            transactionDocument.RootElement,
                            transactionPath,
                            planPath,
                            planSnapshot.Sha256,
                            planArtifactType,
                            planSchemaVersion,
                            planGenerationId,
                            expectedTargetPath,
                            expectedQuarantinePath);
                        transactionStatus = observed.Status;
                        transactionUpdatedAtUtc = observed.UpdatedAtUtc;
                        sourceTargetPath = observed.TargetPath;
                        sourceQuarantinePath = observed.QuarantinePath;
                    }
                    liveRestoreJournalAnchorCount = 0L;
                }
                else
                {
                    transactionStatus = BindingString(
                        transactionBindings, "status", "safe-delete status archive transaction");
                    transactionUpdatedAtUtc = BindingString(
                        transactionBindings, "updatedAtUtc", "safe-delete status archive transaction");
                    string transactionGenerationId = BindingString(
                        transactionBindings, "generationId", "safe-delete status archive transaction");
                    string transactionPlanPath = BindingString(
                        transactionBindings, "planPath", "safe-delete status archive transaction");
                    string transactionPlanSha256 = BindingString(
                        transactionBindings, "planSha256", "safe-delete status archive transaction");
                    sourceTargetPath = BindingString(
                        transactionBindings, "targetPath", "safe-delete status archive transaction");
                    sourceQuarantinePath = BindingString(
                        transactionBindings, "quarantinePath", "safe-delete status archive transaction");
                    if (transactionGenerationId != planGenerationId ||
                        transactionPlanSha256 != planSnapshot.Sha256 ||
                        !PathEqual(transactionPlanPath, planPath) ||
                        !PathEqual(sourceTargetPath, expectedTargetPath) ||
                        !PathEqual(sourceQuarantinePath, expectedQuarantinePath))
                    {
                        throw new StatusScanUserException(
                            "safe-delete terminal archive 与当前受管 evidence 内容不一致。");
                    }
                    liveRestoreJournalAnchorCount = BindingArrayCount(
                        transactionBindings, "restoreJournalAnchors");
                }

                if (GetString(archive, "generationId") != planGenerationId ||
                    archiveTransactionSchemaVersion != transactionSchemaVersion ||
                    GetString(archive, "transactionUpdatedAtUtc") != transactionUpdatedAtUtc ||
                    !PathEqual(GetString(archive, "targetPath"), sourceTargetPath) ||
                    !PathEqual(GetString(archive, "quarantinePath"), sourceQuarantinePath))
                {
                    throw new StatusScanUserException("safe-delete terminal archive 与当前受管 evidence 内容不一致。");
                }
                if (transactionStatus != "purged")
                {
                    throw new StatusScanUserException("safe-delete terminal archive transaction status 已漂移。");
                }
                if (liveRestoreJournalAnchorCount != 0L)
                {
                    throw new StatusScanUserException("safe-delete terminal archive Restore journal anchors 已出现。");
                }

                NamespaceState quarantineState = ProbeNamespace(sourceQuarantinePath);
                if (quarantineState.Present)
                {
                    throw new StatusScanUserException("safe-delete terminal archive quarantine 已重新出现。");
                }
                NamespaceState targetState = ProbeNamespace(sourceTargetPath);

                result.Handled = true;
                result.Archived = true;
                result.OperationId = run.Name;
                result.RunDirectory = run.FullName;
                result.Lifecycle = "terminal";
                result.SafeActions = new string[0];
                result.TargetPath = sourceTargetPath;
                result.QuarantinePath = sourceQuarantinePath;
                result.HasNamespace = true;
                result.TargetPresent = targetState.Present;
                result.QuarantinePresent = false;
                result.TargetEntryType = targetState.EntryType;
                result.QuarantineEntryType = "absent";
                result.NamespaceAbsent = !targetState.Present;
                result.LogicalCompletion = true;
                result.PolicyCompatible = string.Equals(
                    planPolicySha256, policy.Sha256, StringComparison.Ordinal);
                result.SchemaCompatible = transactionSchemaVersion == 2L || transactionSchemaVersion == 3L;
                result.HasPlanSchemaVersion = true;
                result.PlanSchemaVersion = planSchemaVersion;
                result.HasTransactionSchemaVersion = true;
                result.TransactionSchemaVersion = transactionSchemaVersion;
                result.TransactionStatus = transactionStatus;
                result.TransactionUpdatedAtUtc = transactionUpdatedAtUtc;
                result.JournalStatus = "archived";
                result.Errors = new string[0];
            }
        }

        // ---------------------------------------------------------------- active fast path

        private sealed class ObservedV1Transaction
        {
            public string TargetPath;
            public string QuarantinePath;
            public string Status;
            public string UpdatedAtUtc;
        }

        private sealed class NamespaceState
        {
            public bool Present;
            public string EntryType;
        }

        private sealed class PlanApprovalOutcome
        {
            public bool Approved;
            public string Error;
        }

        private static void ScanActive(
            StatusScanRunInput run,
            StatusScanPolicy policy,
            string runDirectory,
            StatusScanResult result)
        {
            string planPath = Path.Combine(runDirectory, "plan.json");
            string transactionPath = Path.Combine(runDirectory, "transaction.json");

            StatusScanFileSnapshot planSnapshot;
            try
            {
                planSnapshot = ReadFileChecked(
                    planPath, "safe-delete status unarchived plan", false, result);
            }
            catch (Exception)
            {
                throw new StatusScanFallbackException("plan-read-failed");
            }
            result.PlanSha256 = planSnapshot.Sha256;
            result.PlanText = planSnapshot.Text;

            int planDepth;
            try
            {
                planDepth = AssertStrictJsonText(planSnapshot.Text);
            }
            catch (StatusScanUserException strictError)
            {
                // Reference order: strict JSON validation precedes every field access, so the
                // operation only carries this single error.
                FinishRejectedOutcome(
                    result, run, new string[] { strictError.Message },
                    null, null, null, null, "unknown", "unknown", false, 0L, false, 0L, null, null, "not-evaluated");
                return;
            }
            if (planDepth > 120)
            {
                throw new StatusScanFallbackException("plan-depth-limit");
            }
            using (JsonDocument planDocument = ParseJsonDocument(planSnapshot.Text))
            {
                JsonElement plan = planDocument.RootElement;
                if (plan.ValueKind != JsonValueKind.Object)
                {
                    throw new StatusScanFallbackException("plan-not-object");
                }
                // MED-1a/1b boundary: the fast path only decides producer-canonical plan
                // documents. PowerShell property-set checks and PSCustomObject member access
                // are case-insensitive, and missing required properties surface as StrictMode
                // PropertyNotFoundException inside the rejection catch — both diverge from
                // this ordinal replica, so such inputs fall back to the reference path.
                if (!HasCanonicalPlanShape(plan))
                {
                    throw new StatusScanFallbackException("plan-shape-non-canonical");
                }
                long planSchemaVersion;
                if (!TryGetInt64(plan, "schemaVersion", out planSchemaVersion))
                {
                    throw new StatusScanFallbackException("plan-schema-version-unsupported");
                }
                if (planSchemaVersion < (long)int.MinValue || planSchemaVersion > (long)int.MaxValue)
                {
                    // MED-2: [int]$plan.schemaVersion in the reference reader throws a cast
                    // error before any comparison; that message class is PowerShell-owned.
                    throw new StatusScanFallbackException("plan-schema-version-out-of-int32");
                }

                string planApprovalError;
                try
                {
                    PlanApprovalOutcome approval = ValidateApprovedPlanDeterministic(
                        plan, planPath, policy);
                    if (approval.Approved)
                    {
                        if (TryBuildApprovedMissingTransactionOutcome(
                                plan, run, policy, transactionPath, result))
                        {
                            return;
                        }
                        if (TryBuildApprovedTerminalOutcome(
                                plan, run, policy, planPath, transactionPath, planSnapshot, result))
                        {
                            return;
                        }
                        // Approved plans continue through the PowerShell reference path for
                        // non-terminal states, namespace handling, transaction semantics, and
                        // tree materialization.
                        // Its manifest structure has already been validated against this exact
                        // snapshot and can be reused without a second O(n) PowerShell walk.
                        result.ApprovedPlanValidation = new StatusPlanValidationReceipt(
                            planSnapshot.Sha256, planSnapshot.Text, planPath);
                        // issue #58 N3: planned (no-transaction) fallback ops need the plan
                        // treeManifest SHA for the drift compare; computing it here spreads the
                        // streaming re-normalization across scan workers instead of the single
                        // fallback worker that owns the tree scan. Only the manifest SHA value
                        // is shared; the fallback resolver recomputes nothing semantically new.
                        if (!File.Exists(transactionPath))
                        {
                            try
                            {
                                result.PlanManifestSha256 =
                                    StatusPlanManifestSha256.ComputeFromPlanText(planSnapshot.Text);
                            }
                            catch (StatusFastPathFallbackException)
                            {
                                result.PlanManifestSha256 = null;
                            }
                        }
                        // 并行 fallback 分派的路由提示：参考路径对该记录至多扫 target 或
                        // quarantine 一棵树。尽力而为，缺失只损失并行度，语义由参考路径自重放。
                        // N4：同一次 JsonDocument 解析顺带导出 receipt 快路径所需 plan 字段
                        // （AssertDPath 规范化）；任一项失败仅该项为 null，worker 自行回退。
                        try
                        {
                            string routeTargetPath = GetString(plan, "targetPath");
                            string routeGenerationId = GetString(plan, "generationId");
                            if (!string.IsNullOrEmpty(routeTargetPath) &&
                                !string.IsNullOrEmpty(routeGenerationId))
                            {
                                result.TargetPath = routeTargetPath;
                                result.QuarantinePath = DeriveQuarantinePath(
                                    routeTargetPath, routeGenerationId);
                                result.ReceiptPlanTargetPath = AssertDPath(
                                    routeTargetPath, "safe-delete target");
                                result.ReceiptPlanCapabilityRoot = AssertDPath(
                                    GetString(plan, "capabilityRoot"), "safe-delete capability root");
                                result.ReceiptPlanQuarantinePath = DeriveQuarantinePath(
                                    result.ReceiptPlanTargetPath, routeGenerationId);
                                result.ReceiptPlanPolicySha256 = GetString(plan, "policySha256");
                            }
                        }
                        catch (Exception)
                        {
                        }
                        throw new StatusScanFallbackException("plan-approved");
                    }
                    planApprovalError = approval.Error;
                }
                catch (StatusScanUserException user)
                {
                    planApprovalError = user.Message;
                }
                BuildRejectedPlanOutcome(
                    run, plan, planSnapshot, planApprovalError, planPath, transactionPath, result,
                    planSchemaVersion, true);
            }
        }

        private static bool TryBuildApprovedTerminalOutcome(
            JsonElement plan,
            StatusScanRunInput run,
            StatusScanPolicy policy,
            string planPath,
            string transactionPath,
            StatusScanFileSnapshot planSnapshot,
            StatusScanResult result)
        {
            if (!File.Exists(transactionPath))
            {
                return false;
            }

            try
            {
                StatusScanFileSnapshot transactionSnapshot = ReadFileChecked(
                    transactionPath,
                    "safe-delete status approved transaction",
                    false,
                    result);
                if (AssertStrictJsonText(transactionSnapshot.Text) > 60)
                {
                    return false;
                }

                using (JsonDocument transactionDocument = ParseJsonDocument(transactionSnapshot.Text))
                {
                    JsonElement transaction = transactionDocument.RootElement;
                    if (transaction.ValueKind != JsonValueKind.Object)
                    {
                        return false;
                    }
                    long transactionSchemaVersion;
                    if (!TryGetInt64(transaction, "schemaVersion", out transactionSchemaVersion) ||
                        transactionSchemaVersion < 2L || transactionSchemaVersion > 3L ||
                        !HasCanonicalTransactionShape(transaction, transactionSchemaVersion))
                    {
                        return false;
                    }
                    ValidateStrictTransactionDocument(transaction, transactionSchemaVersion);

                    if (GetString(transaction, "status") != "purged")
                    {
                        return false;
                    }
                    JsonElement restoreAnchors;
                    if (!transaction.TryGetProperty("directoryCommitAnchors", out JsonElement directoryAnchors) ||
                        directoryAnchors.ValueKind != JsonValueKind.Array ||
                        directoryAnchors.GetArrayLength() != 0 ||
                        (transactionSchemaVersion == 3L &&
                            (!transaction.TryGetProperty("restoreJournalAnchors", out restoreAnchors) ||
                             restoreAnchors.ValueKind != JsonValueKind.Array ||
                             restoreAnchors.GetArrayLength() != 0)))
                    {
                        return false;
                    }

                    string generationId = GetString(plan, "generationId");
                    string targetPath = GetString(plan, "targetPath");
                    string quarantinePath = DeriveQuarantinePath(targetPath, generationId);
                    if (GetString(transaction, "generationId") != generationId ||
                        !PathEqual(GetString(transaction, "planPath"), planPath) ||
                        GetString(transaction, "planSha256") != planSnapshot.Sha256 ||
                        !PathEqual(GetString(transaction, "targetPath"), targetPath) ||
                        !PathEqual(GetString(transaction, "quarantinePath"), quarantinePath))
                    {
                        return false;
                    }

                    string capabilityRoot = AssertDPathQuiet(GetStringOrNull(plan, "capabilityRoot"));
                    StatusScanPolicyEntry policyEntry = null;
                    foreach (StatusScanPolicyEntry candidate in policy.Entries)
                    {
                        if (string.Equals(candidate.CapabilityRoot, capabilityRoot, StringComparison.OrdinalIgnoreCase))
                        {
                            policyEntry = candidate;
                            break;
                        }
                    }
                    if (policyEntry == null ||
                        policyEntry.RootDeletionPurpose == "empty-project-state")
                    {
                        return false;
                    }

                    NamespaceState quarantineState = ProbeNamespace(quarantinePath);
                    NamespaceState targetState = ProbeNamespace(targetPath);
                    if (quarantineState.Present ||
                        (targetState.Present && targetState.EntryType != "directory"))
                    {
                        return false;
                    }

                    bool requiresRebuiltTargetIdentity =
                        targetState.Present &&
                        policyEntry.RootDeletionPurpose == "rebuildable-build-output";
                    if (requiresRebuiltTargetIdentity && transactionSchemaVersion != 2L)
                    {
                        return false;
                    }
                    if (transactionSchemaVersion == 2L)
                    {
                        foreach (string journalPath in Directory.EnumerateFiles(
                                run.FullName,
                                "directory-delete-*-freeze.json",
                                SearchOption.TopDirectoryOnly))
                        {
                            return false;
                        }
                        foreach (string journalPath in Directory.EnumerateFiles(
                                run.FullName,
                                "directory-delete-*-commit.json",
                                SearchOption.TopDirectoryOnly))
                        {
                            return false;
                        }
                    }
                    string[] expectedTargetRootIdentity = null;
                    if (requiresRebuiltTargetIdentity)
                    {
                        if (!plan.TryGetProperty("treeManifest", out JsonElement treeManifest) ||
                            treeManifest.ValueKind != JsonValueKind.Object ||
                            !treeManifest.TryGetProperty("rootIdentity", out JsonElement rootIdentity) ||
                            rootIdentity.ValueKind != JsonValueKind.Array ||
                            rootIdentity.GetArrayLength() != 2)
                        {
                            return false;
                        }
                        expectedTargetRootIdentity = new string[2];
                        int identityIndex = 0;
                        foreach (JsonElement identityPart in rootIdentity.EnumerateArray())
                        {
                            if (identityPart.ValueKind != JsonValueKind.String)
                            {
                                return false;
                            }
                            expectedTargetRootIdentity[identityIndex++] = identityPart.GetString();
                        }
                    }

                    result.Handled = true;
                    result.Archived = false;
                    result.OperationId = run.Name;
                    result.RunDirectory = run.FullName;
                    result.Lifecycle = requiresRebuiltTargetIdentity
                        ? "rebuildable-terminal-identity-pending"
                        : "terminal";
                    result.SafeActions = new string[0];
                    result.TargetPath = targetPath;
                    result.QuarantinePath = quarantinePath;
                    result.HasNamespace = true;
                    result.TargetPresent = targetState.Present;
                    result.QuarantinePresent = false;
                    result.TargetEntryType = targetState.EntryType;
                    result.QuarantineEntryType = quarantineState.EntryType;
                    result.NamespaceAbsent = !targetState.Present;
                    result.LogicalCompletion = !requiresRebuiltTargetIdentity;
                    result.PolicyCompatible = string.Equals(
                        GetString(plan, "policySha256"), policy.Sha256, StringComparison.Ordinal);
                    result.SchemaCompatible = true;
                    result.HasPlanSchemaVersion = true;
                    result.PlanSchemaVersion = 1L;
                    result.HasTransactionSchemaVersion = true;
                    result.TransactionSchemaVersion = transactionSchemaVersion;
                    result.TransactionStatus = GetString(transaction, "status");
                    result.TransactionUpdatedAtUtc = GetString(transaction, "updatedAtUtc");
                    result.JournalStatus = "not-applicable";
                    result.Errors = new string[0];
                    result.RequiresRebuiltTargetIdentity = requiresRebuiltTargetIdentity;
                    result.ExpectedTargetRootIdentity = expectedTargetRootIdentity;
                    result.CapabilityRoot = capabilityRoot;
                    return true;
                }
            }
            catch (Exception)
            {
                // Any ambiguity keeps the existing PowerShell reference path authoritative.
                return false;
            }
        }

        private static bool TryBuildApprovedMissingTransactionOutcome(
            JsonElement plan,
            StatusScanRunInput run,
            StatusScanPolicy policy,
            string transactionPath,
            StatusScanResult result)
        {
            if (File.Exists(transactionPath))
            {
                return false;
            }

            string targetPath = CoerceStringForPath(plan, "targetPath", "safe-delete target");
            string quarantinePath = DeriveQuarantinePath(targetPath, GetString(plan, "generationId"));
            NamespaceState targetState = ProbeNamespace(targetPath);
            NamespaceState quarantineState = ProbeNamespace(quarantinePath);
            if (targetState.Present || quarantineState.Present)
            {
                return false;
            }

            result.Handled = true;
            result.Archived = false;
            result.OperationId = run.Name;
            result.RunDirectory = run.FullName;
            // issue #58 N4 取证：此分支刻意不应用参考路径 :4214 的 policy 漂移覆盖
            // （inconsistent + 单错误）。冻结基线 cold-run-stdout.json 对该分支的 23 个
            // 生产 op 编码的即本形状；纯 PS 参考解析器（仅 FAST_SCAN=0 诊断可达）产出
            // manual-review + 双错误，与基线分叉。方向待 issue owner 裁决，见
            // reports/issue58-20260908/IMPLEMENTATION.md N4 段。Status slice 41 钉住两侧。
            result.Lifecycle = "inconsistent";
            result.SafeActions = new string[] { "manual-review" };
            result.TargetPath = targetPath;
            result.QuarantinePath = quarantinePath;
            result.HasNamespace = true;
            result.TargetPresent = false;
            result.QuarantinePresent = quarantineState.Present;
            result.TargetEntryType = targetState.EntryType;
            result.QuarantineEntryType = quarantineState.EntryType;
            result.NamespaceAbsent = true;
            result.LogicalCompletion = false;
            result.PolicyCompatible = string.Equals(
                GetString(plan, "policySha256"), policy.Sha256, StringComparison.Ordinal);
            result.SchemaCompatible = true;
            result.HasPlanSchemaVersion = true;
            result.PlanSchemaVersion = 1L;
            result.JournalStatus = "not-started";
            result.Errors = new string[] {
                "planned operation 的 target/quarantine namespace 不一致。" };
            return true;
        }

        private static void BuildRejectedPlanOutcome(
            StatusScanRunInput run,
            JsonElement plan,
            StatusScanFileSnapshot planSnapshot,
            string planApprovalError,
            string planPath,
            string transactionPath,
            StatusScanResult result,
            long planSchemaVersion,
            bool hasPlanSchemaVersion)
        {
            List<string> errors = new List<string>();
            string targetPath = null;
            string quarantinePath = null;
            string transactionStatus = null;
            string transactionUpdatedAtUtc = null;
            long transactionSchemaVersion = 0L;
            bool hasTransactionSchemaVersion = false;
            string targetEntryType = "unknown";
            string quarantineEntryType = "unknown";
            bool? targetPresent = null;
            bool? quarantinePresent = null;

            if (!File.Exists(transactionPath))
            {
                errors.Add(planApprovalError);
                FinishRejectedOutcome(
                    result, run, errors.ToArray(), targetPath, quarantinePath, targetPresent,
                    quarantinePresent, targetEntryType, quarantineEntryType,
                    hasPlanSchemaVersion, planSchemaVersion,
                    hasTransactionSchemaVersion, transactionSchemaVersion,
                    transactionStatus, transactionUpdatedAtUtc, "not-evaluated");
                return;
            }

            StatusScanFileSnapshot transactionSnapshot;
            try
            {
                transactionSnapshot = ReadFileChecked(
                    transactionPath, "safe-delete status observed transaction after plan rejection",
                    false, result);
            }
            catch (Exception)
            {
                throw new StatusScanFallbackException("transaction-read-failed");
            }

            int transactionDepth;
            try
            {
                transactionDepth = AssertStrictJsonText(transactionSnapshot.Text);
            }
            catch (StatusScanUserException strictError)
            {
                FinishRejectedOutcome(
                    result, run, new string[] { strictError.Message },
                    null, null, null, null, "unknown", "unknown",
                    hasPlanSchemaVersion, planSchemaVersion,
                    false, 0L, null, null, "not-evaluated");
                return;
            }
            if (transactionDepth > 60)
            {
                throw new StatusScanFallbackException("transaction-depth-limit");
            }

            using (JsonDocument transactionDocument = ParseJsonDocument(transactionSnapshot.Text))
            {
                JsonElement transaction = transactionDocument.RootElement;
                if (transaction.ValueKind != JsonValueKind.Object)
                {
                    throw new StatusScanFallbackException("transaction-not-object");
                }
                long parsedTransactionSchemaVersion;
                if (!TryGetInt64(transaction, "schemaVersion", out parsedTransactionSchemaVersion))
                {
                    throw new StatusScanFallbackException("transaction-schema-version-unsupported");
                }
                transactionSchemaVersion = parsedTransactionSchemaVersion;
                hasTransactionSchemaVersion = true;

                // MED-1b boundary: same canonical-shape rule as the plan document; the
                // reference exact-property checks and member access are case-insensitive.
                if (!HasCanonicalTransactionShape(transaction, transactionSchemaVersion))
                {
                    throw new StatusScanFallbackException("transaction-shape-non-canonical");
                }

                if (transactionSchemaVersion < 1L || transactionSchemaVersion > 3L)
                {
                    errors.Add(planApprovalError);
                    FinishRejectedOutcome(
                        result, run, errors.ToArray(), targetPath, quarantinePath, targetPresent,
                        quarantinePresent, targetEntryType, quarantineEntryType,
                        hasPlanSchemaVersion, planSchemaVersion,
                        hasTransactionSchemaVersion, transactionSchemaVersion,
                        transactionStatus, transactionUpdatedAtUtc, "not-evaluated");
                    return;
                }

                if (!IsStringProperty(plan, "targetPath") || !IsStringProperty(plan, "generationId"))
                {
                    errors.Add(planApprovalError);
                    FinishRejectedOutcome(
                        result, run, errors.ToArray(), targetPath, quarantinePath, targetPresent,
                        quarantinePresent, targetEntryType, quarantineEntryType,
                        hasPlanSchemaVersion, planSchemaVersion,
                        hasTransactionSchemaVersion, transactionSchemaVersion,
                        transactionStatus, transactionUpdatedAtUtc, "not-evaluated");
                    return;
                }
                string observedTargetPath = GetString(plan, "targetPath");
                string planGenerationId = GetString(plan, "generationId");
                string observedQuarantinePath = DeriveQuarantinePath(observedTargetPath, planGenerationId);

                try
                {
                    if (transactionSchemaVersion == 1L)
                    {
                        ObservedV1Transaction observed = ReadObservedV1Transaction(
                            transaction,
                            transactionPath,
                            planPath,
                            planSnapshot.Sha256,
                            GetStringOrEmpty(plan, "artifactType"),
                            GetInt64OrMinusOne(plan, "schemaVersion"),
                            planGenerationId,
                            observedTargetPath,
                            observedQuarantinePath);
                        targetPath = observed.TargetPath;
                        quarantinePath = observed.QuarantinePath;
                        transactionStatus = observed.Status;
                        transactionUpdatedAtUtc = observed.UpdatedAtUtc;
                    }
                    else
                    {
                        ValidateStrictTransactionDocument(transaction, transactionSchemaVersion);
                        if (GetStringOrEmpty(plan, "artifactType") != "env-governance.codex-safe-tree-delete-plan" ||
                            GetInt64OrMinusOne(plan, "schemaVersion") != 1L)
                        {
                            throw new StatusScanUserException(
                                "safe-delete observed transaction 的 plan artifact/schema 非法。");
                        }
                        Guid observedPlanGenerationId;
                        if (!Guid.TryParseExact(planGenerationId, "D", out observedPlanGenerationId))
                        {
                            throw new StatusScanUserException(
                                "safe-delete observed transaction 的 plan generationId 非法。");
                        }
                        if (GetString(transaction, "generationId") != planGenerationId ||
                            !PathEqual(GetString(transaction, "planPath"), planPath) ||
                            GetString(transaction, "planSha256") != planSnapshot.Sha256 ||
                            !PathEqual(GetString(transaction, "targetPath"), observedTargetPath) ||
                            !PathEqual(GetString(transaction, "quarantinePath"), observedQuarantinePath))
                        {
                            throw new StatusScanUserException(
                                "safe-delete observed transaction 与受管 plan 不一致：" + transactionPath);
                        }
                        targetPath = GetString(transaction, "targetPath");
                        quarantinePath = GetString(transaction, "quarantinePath");
                        transactionStatus = GetString(transaction, "status");
                        transactionUpdatedAtUtc = GetString(transaction, "updatedAtUtc");
                    }
                }
                catch (StatusScanUserException user)
                {
                    // Reference behavior: observed-transaction validation failures surface as
                    // the single recorded error without the read-only observation message, and
                    // journalStatus keeps its initial 'not-evaluated' value.
                    FinishRejectedOutcome(
                        result, run, new string[] { user.Message },
                        null, null, null, null, "unknown", "unknown",
                        hasPlanSchemaVersion, planSchemaVersion,
                        hasTransactionSchemaVersion, transactionSchemaVersion,
                        null, null, "not-evaluated");
                    return;
                }

                NamespaceState targetState = ProbeNamespace(targetPath);
                NamespaceState quarantineState = ProbeNamespace(quarantinePath);
                targetPresent = targetState.Present;
                quarantinePresent = quarantineState.Present;
                targetEntryType = targetState.EntryType;
                quarantineEntryType = quarantineState.EntryType;
                errors.Add("plan 当前语义拒绝：" + planApprovalError);
                if (transactionSchemaVersion == 1L)
                {
                    errors.Add(
                        "transaction v1 仅支持 Status 只读观测；Purge/Restore 不可恢复且继续拒绝。");
                }
                else
                {
                    errors.Add(
                        "plan 被当前 policy 拒绝；transaction 仅支持 Status 只读观测，Apply/Purge/Restore 继续拒绝。");
                }
                FinishRejectedOutcome(
                    result, run, errors.ToArray(), targetPath, quarantinePath, targetPresent,
                    quarantinePresent, targetEntryType, quarantineEntryType,
                    hasPlanSchemaVersion, planSchemaVersion,
                    hasTransactionSchemaVersion, transactionSchemaVersion,
                    transactionStatus, transactionUpdatedAtUtc, "unavailable");
            }
        }

        private static void FinishRejectedOutcome(
            StatusScanResult result,
            StatusScanRunInput run,
            string[] errors,
            string targetPath,
            string quarantinePath,
            bool? targetPresent,
            bool? quarantinePresent,
            string targetEntryType,
            string quarantineEntryType,
            bool hasPlanSchemaVersion,
            long planSchemaVersion,
            bool hasTransactionSchemaVersion,
            long transactionSchemaVersion,
            string transactionStatus,
            string transactionUpdatedAtUtc,
            string journalStatus)
        {
            result.Handled = true;
            result.Archived = false;
            result.OperationId = run.Name;
            result.RunDirectory = run.FullName;
            result.Lifecycle = "manual-review";
            result.SafeActions = new string[] { "manual-review" };
            result.TargetPath = targetPath;
            result.QuarantinePath = quarantinePath;
            result.HasNamespace = targetPresent.HasValue;
            result.TargetPresent = targetPresent.HasValue && targetPresent.Value;
            result.QuarantinePresent = quarantinePresent.HasValue && quarantinePresent.Value;
            result.TargetEntryType = targetEntryType;
            result.QuarantineEntryType = quarantineEntryType;
            result.NamespaceAbsent = targetPresent.HasValue && !targetPresent.Value;
            result.LogicalCompletion = false;
            result.PolicyCompatible = false;
            result.SchemaCompatible = false;
            result.HasPlanSchemaVersion = hasPlanSchemaVersion;
            result.PlanSchemaVersion = planSchemaVersion;
            result.HasTransactionSchemaVersion = hasTransactionSchemaVersion;
            result.TransactionSchemaVersion = transactionSchemaVersion;
            result.TransactionStatus = transactionStatus;
            result.TransactionUpdatedAtUtc = transactionUpdatedAtUtc;
            result.JournalStatus = journalStatus;
            result.Errors = errors;
        }

        /// <summary>
        /// Replicates Read-CodexSafeTreeDeleteApprovedPlan's validation order for the
        /// Status read-only flags (AllowMissingTarget, AllowExpiredPlan, AllowPolicyShaDrift).
        /// Returns the first deterministic rejection message, or Approved when every check
        /// passes (the PowerShell path then owns the deeper semantics).
        /// </summary>
        private static PlanApprovalOutcome ValidateApprovedPlanDeterministic(
            JsonElement plan,
            string planPath,
            StatusScanPolicy policy)
        {
            // Read-CodexSafeTreeDeleteApprovedPlan opens with the managed plan path
            // capability walk before trusting the document.
            string planReparseError = AssertNoReparseAncestor(planPath, "safe-delete approved plan");
            if (planReparseError != null)
            {
                return new PlanApprovalOutcome { Approved = false, Error = planReparseError };
            }

            string[] required = new string[] {
                "artifactType", "schemaVersion", "generationId", "createdAtUtc", "expiresAtUtc",
                "policyPath", "policySha256", "policyEntryId", "targetPath", "capabilityRoot",
                "treeManifest", "summary"
            };
            string[] optional = new string[] { "fileIdentitiesV2", "leafStreamSetV1" };
            if (!HasPropertySubset(plan, required, optional))
            {
                return new PlanApprovalOutcome { Approved = false, Error = "safe-delete plan 属性集合非法。" };
            }
            if (GetStringOrEmpty(plan, "artifactType") != "env-governance.codex-safe-tree-delete-plan" ||
                GetInt64OrMinusOne(plan, "schemaVersion") != 1L)
            {
                return new PlanApprovalOutcome { Approved = false, Error = "safe-delete plan artifact/schema 非法。" };
            }
            string generationId = CoerceStringForGuid(plan, "generationId");
            Guid generationGuid;
            if (!Guid.TryParseExact(generationId, "D", out generationGuid))
            {
                return new PlanApprovalOutcome { Approved = false, Error = "safe-delete plan generationId 非法。" };
            }
            DateTimeOffset expiresAt;
            string expiresAtRaw = GetStringOrNull(plan, "expiresAtUtc");
            if (expiresAtRaw == null ||
                !DateTimeOffset.TryParseExact(
                    expiresAtRaw, "o", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out expiresAt))
            {
                return new PlanApprovalOutcome { Approved = false, Error = "safe-delete plan 已过期或时间非法。" };
            }

            // LoadedPolicy branch: the policy path comparison stays case-sensitive.
            if (GetStringOrEmpty(plan, "policyPath") != policy.Path)
            {
                return new PlanApprovalOutcome { Approved = false, Error = "safe-delete policy 自计划生成后已漂移。" };
            }

            // Resolve-CodexSafeTreeDeleteTarget with RequireExisting=false.
            string targetError = ResolveTargetDeterministic(plan, policy);
            if (targetError != null)
            {
                return new PlanApprovalOutcome { Approved = false, Error = targetError };
            }

            if (GetStringOrEmpty(plan, "policyEntryId") != FindPolicyEntryIdForTarget(plan, policy))
            {
                return new PlanApprovalOutcome { Approved = false, Error = "safe-delete plan policy entry 漂移。" };
            }

            string manifestError = ValidateTreeManifestDeterministic(plan, "safe-delete approved plan");
            if (manifestError != null)
            {
                return new PlanApprovalOutcome { Approved = false, Error = manifestError };
            }

            string treePolicyError = ValidateTargetTreePolicyDeterministic(plan, policy);
            if (treePolicyError != null)
            {
                return new PlanApprovalOutcome { Approved = false, Error = treePolicyError };
            }

            return new PlanApprovalOutcome { Approved = true };
        }

        private static string ResolveTargetDeterministic(JsonElement plan, StatusScanPolicy policy)
        {
            string fullTarget = CoerceStringForPath(plan, "targetPath", "safe-delete target");
            string fullRoot = CoerceStringForPath(plan, "capabilityRoot", "safe-delete capability root");

            StatusScanPolicyEntry entry = null;
            int entryCount = 0;
            foreach (StatusScanPolicyEntry candidate in policy.Entries)
            {
                if (string.Equals(candidate.CapabilityRoot, fullRoot, StringComparison.OrdinalIgnoreCase))
                {
                    entryCount++;
                    entry = candidate;
                }
            }
            if (entryCount != 1) { return "safe-delete capability root 不在受管 allowlist。"; }
            if (!PathWithin(fullTarget, fullRoot))
            {
                return "safe-delete target 必须位于 capability root 内。";
            }
            bool targetIsRoot = string.Equals(fullTarget, fullRoot, StringComparison.OrdinalIgnoreCase);
            if ((entry.RootDeletionPurpose == "empty-project-state" ||
                 entry.RootDeletionPurpose == "retired-project-root" ||
                 entry.RootDeletionPurpose == "retired-evidence-root") &&
                !targetIsRoot)
            {
                return "safe-delete root 删除用途只允许精确 capability root。";
            }
            if ((entry.AllowHardLinks || entry.AllowInternalDirectoryJunctions) && !targetIsRoot)
            {
                return "safe-delete link-aware 能力只允许精确 capability root。";
            }
            string relative = fullTarget.Substring(fullRoot.Length).TrimStart('\\', '/');
            int depth = 0;
            foreach (string segment in relative.Split(
                new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries))
            {
                depth++;
            }
            if (depth < entry.MinimumDescendantDepth)
            {
                return "safe-delete target 未达到策略要求的最小后代深度。";
            }
            foreach (string deniedPath in entry.DeniedExactPaths)
            {
                if (string.Equals(fullTarget, deniedPath, StringComparison.OrdinalIgnoreCase) ||
                    PathWithin(fullTarget, deniedPath))
                {
                    return "safe-delete target 命中 denylist。";
                }
            }
            // Assert-CodexHookCapabilityPath(target, root, allowed={target}): within-root,
            // ADS and exact-allowlist checks passed by construction; the remaining
            // reparse-ancestor walk is reproduced here.
            string reparseError = AssertNoReparseAncestor(fullTarget, "safe-delete target");
            if (reparseError != null) { return reparseError; }
            return null;
        }

        private static string FindPolicyEntryIdForTarget(JsonElement plan, StatusScanPolicy policy)
        {
            string fullRoot = AssertDPathQuiet(GetStringOrNull(plan, "capabilityRoot"));
            if (fullRoot == null) { return "\u0000no-entry"; }
            foreach (StatusScanPolicyEntry candidate in policy.Entries)
            {
                if (string.Equals(candidate.CapabilityRoot, fullRoot, StringComparison.OrdinalIgnoreCase))
                {
                    return candidate.Id;
                }
            }
            return "\u0000no-entry";
        }

        private static string ValidateTargetTreePolicyDeterministic(JsonElement plan, StatusScanPolicy policy)
        {
            StatusScanPolicyEntry entry = null;
            string fullRoot = AssertDPathQuiet(GetStringOrNull(plan, "capabilityRoot"));
            if (fullRoot != null)
            {
                foreach (StatusScanPolicyEntry candidate in policy.Entries)
                {
                    if (string.Equals(candidate.CapabilityRoot, fullRoot, StringComparison.OrdinalIgnoreCase))
                    {
                        entry = candidate;
                        break;
                    }
                }
            }
            JsonElement manifest;
            if (!plan.TryGetProperty("treeManifest", out manifest) ||
                manifest.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            JsonElement entries;
            if (!manifest.TryGetProperty("entries", out entries) || entries.ValueKind != JsonValueKind.Array)
            {
                return null;
            }
            bool junctionFound = false;
            bool fileFound = false;
            foreach (JsonElement entryElement in entries.EnumerateArray())
            {
                if (entryElement.ValueKind != JsonValueKind.Object) { continue; }
                string kind = GetStringOrNull(entryElement, "kind");
                if (kind == "directory-junction") { junctionFound = true; }
                if (kind == "file") { fileFound = true; }
            }
            if (entry != null && !entry.AllowInternalDirectoryJunctions && junctionFound)
            {
                return "safe-delete tree manifest 包含未授权的 directory junction。";
            }
            if (entry != null && entry.RootDeletionPurpose == "empty-project-state" && fileFound)
            {
                return "safe-delete 空项目状态树不得包含文件。";
            }
            return null;
        }

        private static string ValidateTreeManifestDeterministic(JsonElement plan, string scope)
        {
            JsonElement manifest;
            if (!plan.TryGetProperty("treeManifest", out manifest))
            {
                return scope + " manifest 属性集合非法。";
            }
            string[] manifestNames = new string[] { "schemaVersion", "rootIdentity", "entries" };
            if (manifest.ValueKind != JsonValueKind.Object)
            {
                return scope + " manifest 属性集合非法。";
            }
            if (!HasExactProperties(manifest, manifestNames))
            {
                if (HasAllPropertiesOrdinalIgnoreCase(manifest, manifestNames))
                {
                    throw new StatusScanFallbackException("manifest-shape-non-canonical");
                }
                return scope + " manifest 属性集合非法。";
            }
            long manifestSchemaVersion;
            if (!TryGetInt64(manifest, "schemaVersion", out manifestSchemaVersion))
            {
                throw new StatusScanFallbackException("manifest-schema-version-unsupported");
            }
            if (manifestSchemaVersion < (long)int.MinValue || manifestSchemaVersion > (long)int.MaxValue)
            {
                // MED-2: [int]$Manifest.schemaVersion in the reference manifest reader throws
                // a cast error before the 1/2 membership check.
                throw new StatusScanFallbackException("manifest-schema-version-out-of-int32");
            }
            if (!HasOnlyCanonicalPropertyNames(manifest, ManifestCanonicalNames))
            {
                throw new StatusScanFallbackException("manifest-shape-non-canonical");
            }
            if (manifestSchemaVersion != 1 && manifestSchemaVersion != 2)
            {
                return scope + " manifest schemaVersion 非法。";
            }
            string[] rootIdentity = RequireIdentityArray(manifest, "rootIdentity");
            AssertDirectoryTreeIdentity(rootIdentity, rootIdentity, scope + " manifest root");

            JsonElement entriesElement;
            if (!manifest.TryGetProperty("entries", out entriesElement) ||
                entriesElement.ValueKind != JsonValueKind.Array)
            {
                return scope + " manifest entry 属性集合非法。";
            }
            Dictionary<string, ManifestEntryScan> entriesByPath =
                new Dictionary<string, ManifestEntryScan>(StringComparer.OrdinalIgnoreCase);
            string rootEntryKind = null;
            string[] rootEntryIdentity = null;
            string[] manifestEntryNames = new string[] { "relativePath", "kind", "sha256", "identity" };
            foreach (JsonElement entryElement in entriesElement.EnumerateArray())
            {
                if (entryElement.ValueKind != JsonValueKind.Object)
                {
                    return scope + " manifest entry 属性集合非法。";
                }
                if (!HasExactProperties(entryElement, manifestEntryNames))
                {
                    if (HasAllPropertiesOrdinalIgnoreCase(entryElement, manifestEntryNames))
                    {
                        throw new StatusScanFallbackException("manifest-entry-shape-non-canonical");
                    }
                    return scope + " manifest entry 属性集合非法。";
                }
                if (!HasOnlyCanonicalPropertyNames(entryElement, ManifestEntryCanonicalNames))
                {
                    throw new StatusScanFallbackException("manifest-entry-shape-non-canonical");
                }
                if (!IsStringProperty(entryElement, "relativePath") || !IsStringProperty(entryElement, "kind"))
                {
                    throw new StatusScanFallbackException("manifest-entry-string-coercion");
                }
                string relativePath = GetString(entryElement, "relativePath");
                string kind = GetString(entryElement, "kind");
                if (relativePath != ".")
                {
                    if (string.IsNullOrWhiteSpace(relativePath) ||
                        relativePath.StartsWith("/") ||
                        relativePath.EndsWith("/") ||
                        relativePath.Contains("\\") ||
                        relativePath.Contains(":"))
                    {
                        return scope + " manifest entry relativePath 非法。";
                    }
                    foreach (string segment in relativePath.Split('/'))
                    {
                        if (string.IsNullOrWhiteSpace(segment) ||
                            segment == "." || segment == ".." ||
                            IndexOfAnyInvalidFileNameChar(segment) >= 0 ||
                            segment.EndsWith(" ") || segment.EndsWith("."))
                        {
                            return scope + " manifest entry relativePath 含不安全路径段。";
                        }
                    }
                }
                if (kind != "directory" && kind != "file" &&
                    (manifestSchemaVersion != 2 || kind != "directory-junction"))
                {
                    return scope + " manifest entry kind 非法。";
                }
                bool shaIsNull = entryElement.TryGetProperty("sha256", out JsonElement shaElement) &&
                    shaElement.ValueKind == JsonValueKind.Null;
                string sha256 = null;
                if (kind == "directory")
                {
                    if (!shaIsNull)
                    {
                        return scope + " manifest directory 不得声明 SHA-256。";
                    }
                }
                else
                {
                    if (!IsStringProperty(entryElement, "sha256") ||
                        !LowerHex64.IsMatch(GetString(entryElement, "sha256")))
                    {
                        return scope + " manifest leaf SHA-256 非法。";
                    }
                    sha256 = GetString(entryElement, "sha256");
                }
                string[] identity = RequireIdentityArray(entryElement, "identity");
                AssertDirectoryTreeIdentity(identity, identity, scope + " manifest entry");
                if (entriesByPath.ContainsKey(relativePath))
                {
                    return scope + " manifest relativePath 重复。";
                }
                entriesByPath.Add(relativePath, new ManifestEntryScan { Kind = kind, Sha256 = sha256 });
                if (relativePath == ".")
                {
                    rootEntryKind = kind;
                    rootEntryIdentity = identity;
                }
            }
            if (!entriesByPath.ContainsKey("."))
            {
                return scope + " manifest 缺少根目录条目。";
            }
            if (rootEntryKind != "directory")
            {
                return scope + " manifest 根目录 kind 非法。";
            }
            AssertDirectoryTreeIdentity(rootIdentity, rootEntryIdentity, scope + " manifest root");
            foreach (string relativePath in entriesByPath.Keys)
            {
                if (relativePath == ".") { continue; }
                string parent = GetRelativeParent(relativePath);
                ManifestEntryScan parentEntry;
                if (!entriesByPath.TryGetValue(parent, out parentEntry) || parentEntry.Kind != "directory")
                {
                    return scope + " manifest entry 缺少安全目录父级。";
                }
            }
            return null;
        }

        private sealed class ManifestEntryScan
        {
            public string Kind;
            public string Sha256;
        }

        private static string GetRelativeParent(string relativePath)
        {
            int lastSlash = relativePath.LastIndexOf('/');
            if (lastSlash < 0) { return "."; }
            return relativePath.Substring(0, lastSlash);
        }

        // ---------------------------------------------------------------- shared helpers

        private static ObservedV1Transaction ReadObservedV1Transaction(
            JsonElement document,
            string transactionPath,
            string planPath,
            string planSha256,
            string planArtifactType,
            long planSchemaVersion,
            string planGenerationId,
            string expectedTargetPath,
            string expectedQuarantinePath)
        {
            if (document.ValueKind != JsonValueKind.Object)
            {
                throw new StatusScanFallbackException("v1-transaction-not-object");
            }
            long schemaVersion;
            if (!TryGetInt64(document, "schemaVersion", out schemaVersion) || schemaVersion != 1L)
            {
                throw new StatusScanUserException(
                    "safe-delete observed transaction schemaVersion 必须是 JSON integer 1。");
            }
            if (planArtifactType != "env-governance.codex-safe-tree-delete-plan" ||
                planSchemaVersion != 1L ||
                planGenerationId == null)
            {
                throw new StatusScanUserException("safe-delete observed transaction v1 的 plan artifact/schema 非法。");
            }
            Guid planGenerationGuid;
            if (!Guid.TryParseExact(planGenerationId, "D", out planGenerationGuid))
            {
                throw new StatusScanUserException("safe-delete observed transaction v1 的 plan generationId 非法。");
            }
            AssertExactProperties(document, new string[] {
                "artifactType", "schemaVersion", "generationId", "planPath", "planSha256",
                "targetPath", "quarantinePath", "status", "updatedAtUtc"
            }, "safe-delete observed transaction v1");
            foreach (string stringProperty in new string[] {
                    "artifactType", "generationId", "planPath", "planSha256",
                    "targetPath", "quarantinePath", "status", "updatedAtUtc"})
            {
                if (!IsStringProperty(document, stringProperty))
                {
                    throw new StatusScanUserException(
                        "safe-delete observed transaction v1 " + stringProperty + " 必须是 JSON string。");
                }
            }
            DateTimeOffset updatedAtUtc;
            if (!DateTimeOffset.TryParseExact(
                    GetString(document, "updatedAtUtc"),
                    "o",
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out updatedAtUtc))
            {
                throw new StatusScanUserException("safe-delete observed transaction v1 updatedAtUtc 非法。");
            }
            string status = GetString(document, "status");
            if (GetString(document, "artifactType") != "env-governance.codex-safe-tree-delete-transaction" ||
                (status != "prepared" && status != "quarantined" && status != "purging" &&
                 status != "purged" && status != "restored" && status != "rolled-back"))
            {
                throw new StatusScanUserException("safe-delete observed transaction v1 状态或 schema 非法。");
            }
            if (GetString(document, "generationId") != planGenerationId ||
                !PathEqual(GetString(document, "planPath"), planPath) ||
                GetString(document, "planSha256") != planSha256 ||
                !PathEqual(GetString(document, "targetPath"), expectedTargetPath) ||
                !PathEqual(GetString(document, "quarantinePath"), expectedQuarantinePath))
            {
                throw new StatusScanUserException(
                    "safe-delete observed transaction v1 与受管 plan 不一致：" + transactionPath);
            }
            return new ObservedV1Transaction
            {
                TargetPath = GetString(document, "targetPath"),
                QuarantinePath = GetString(document, "quarantinePath"),
                Status = status,
                UpdatedAtUtc = GetString(document, "updatedAtUtc")
            };
        }

        private static void ValidateStrictTransactionDocument(JsonElement document, long schemaVersion)
        {
            string[] transactionNames;
            if (schemaVersion == 3L)
            {
                transactionNames = new string[] {
                    "artifactType", "schemaVersion", "generationId", "planPath", "planSha256",
                    "targetPath", "quarantinePath", "directoryCommitAnchors", "status", "updatedAtUtc",
                    "quarantineTimeAnchor", "restoreJournalAnchors" };
            }
            else
            {
                transactionNames = new string[] {
                    "artifactType", "schemaVersion", "generationId", "planPath", "planSha256",
                    "targetPath", "quarantinePath", "directoryCommitAnchors", "status", "updatedAtUtc" };
            }
            if (!HasExactProperties(document, transactionNames))
            {
                throw new StatusScanUserException("safe-delete transaction 属性集合非法。");
            }
            foreach (string stringProperty in new string[] {
                    "artifactType", "generationId", "planPath", "planSha256",
                    "targetPath", "quarantinePath", "status", "updatedAtUtc"})
            {
                if (!IsStringProperty(document, stringProperty))
                {
                    throw new StatusScanUserException(
                        "safe-delete transaction " + stringProperty + " 必须是 JSON string。");
                }
            }
            DateTimeOffset updatedAtUtc;
            if (!DateTimeOffset.TryParseExact(
                    GetString(document, "updatedAtUtc"),
                    "o",
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out updatedAtUtc))
            {
                throw new StatusScanUserException("safe-delete transaction updatedAtUtc 非法。");
            }
            string status = GetString(document, "status");
            if (GetString(document, "artifactType") != "env-governance.codex-safe-tree-delete-transaction" ||
                (status != "prepared" && status != "quarantined" && status != "purging" &&
                 status != "purged" && status != "restored" && status != "rolled-back"))
            {
                throw new StatusScanUserException("safe-delete transaction 状态或 schema 非法。");
            }
            JsonElement anchors;
            if (!document.TryGetProperty("directoryCommitAnchors", out anchors) ||
                anchors.ValueKind != JsonValueKind.Array)
            {
                throw new StatusScanUserException(
                    "safe-delete transaction directoryCommitAnchors 必须是 JSON array。");
            }
            if (status == "prepared" && anchors.GetArrayLength() != 0)
            {
                throw new StatusScanUserException(
                    "safe-delete prepared transaction 不得包含 directory commit anchor。");
            }
            if (schemaVersion == 3L)
            {
                JsonElement restoreAnchors;
                if (!document.TryGetProperty("restoreJournalAnchors", out restoreAnchors) ||
                    restoreAnchors.ValueKind != JsonValueKind.Array)
                {
                    throw new StatusScanUserException(
                        "safe-delete transaction v3 restoreJournalAnchors 必须是 JSON array。");
                }
                JsonElement timeAnchor;
                bool timeAnchorIsNull = document.TryGetProperty("quarantineTimeAnchor", out timeAnchor) &&
                    timeAnchor.ValueKind == JsonValueKind.Null;
                if ((status == "quarantined" || status == "purging" || status == "purged" ||
                     status == "restored") && timeAnchorIsNull)
                {
                    throw new StatusScanUserException(
                        "safe-delete transaction v3 非 prepared 状态缺少 quarantine-time anchor。");
                }
                if (status == "restored" && restoreAnchors.GetArrayLength() != 1)
                {
                    throw new StatusScanUserException(
                        "safe-delete restored transaction v3 必须绑定一个 Restore journal anchor。");
                }
                if (restoreAnchors.GetArrayLength() != 0 && status != "restored")
                {
                    throw new StatusScanUserException(
                        "safe-delete transaction v3 Restore anchors 与状态不一致。");
                }
            }
        }

        private static string DeriveQuarantinePath(string targetPath, string generationId)
        {
            string parent = Path.GetDirectoryName(targetPath);
            if (string.IsNullOrEmpty(parent))
            {
                throw new StatusScanFallbackException("quarantine-parent-empty");
            }
            return Path.Combine(parent, ".codex-safe-delete-" + generationId + ".quarantine");
        }

        // issue #58 N3: v2 transaction strict-document replica
        // (ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument, schemaVersion 2 branch).
        // Returns true only when the strict conversion is guaranteed to accept the document;
        // every other input returns false so the caller falls back and PowerShell owns the
        // exact error message. Duplicate-free input is a caller prerequisite (strict JSON
        // text validation runs before this in both paths).
        public static bool TestStatusTransactionV2StrictShape(string transactionText)
        {
            if (transactionText == null)
            {
                return false;
            }
            try
            {
                using (JsonDocument document = JsonDocument.Parse(transactionText, new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 32
                }))
                {
                    JsonElement transaction = document.RootElement;
                    if (transaction.ValueKind != JsonValueKind.Object)
                    {
                        return false;
                    }
                    if (!transaction.TryGetProperty("schemaVersion", out JsonElement schemaElement) ||
                        schemaElement.ValueKind != JsonValueKind.Number ||
                        !schemaElement.TryGetInt64(out long schemaVersion) ||
                        schemaVersion != 2L)
                    {
                        return false;
                    }
                    if (!HasCanonicalTransactionShape(transaction, 2L))
                    {
                        return false;
                    }
                    foreach (string name in new string[] {
                        "artifactType", "generationId", "planPath", "planSha256",
                        "targetPath", "quarantinePath", "status", "updatedAtUtc" })
                    {
                        if (!transaction.TryGetProperty(name, out JsonElement value) ||
                            value.ValueKind != JsonValueKind.String)
                        {
                            return false;
                        }
                    }
                    if (!DateTimeOffset.TryParseExact(
                            transaction.GetProperty("updatedAtUtc").GetString(), "o",
                            CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind,
                            out DateTimeOffset updatedAt))
                    {
                        return false;
                    }
                    string status = transaction.GetProperty("status").GetString();
                    if (transaction.GetProperty("artifactType").GetString() !=
                            "env-governance.codex-safe-tree-delete-transaction" ||
                        (status != "prepared" && status != "quarantined" && status != "purging" &&
                            status != "purged" && status != "restored" && status != "rolled-back"))
                    {
                        return false;
                    }
                    JsonElement anchors = transaction.GetProperty("directoryCommitAnchors");
                    if (anchors.ValueKind != JsonValueKind.Array)
                    {
                        return false;
                    }
                    if (status == "prepared" && anchors.GetArrayLength() != 0)
                    {
                        return false;
                    }
                    return true;
                }
            }
            catch (Exception)
            {
                return false;
            }
        }


        private static StatusScanFileSnapshot ReadFileChecked(
            string path, string name, bool terminalArchiveSegment, StatusScanResult metrics)
        {
            StatusScanFileSnapshot snapshot = new StatusScanFileSnapshot();
            byte[] bytes;
            string identityVolume;
            string identityIndex;
            string lexicalPath = Path.GetFullPath(path);
            SafeFileHandle handle = null;
            Stopwatch readWatch = Stopwatch.StartNew();
            try
            {
                try
                {
                    handle = OpenVerifiedReadHandleLocal(lexicalPath);
                }
                catch (StatusScanPathMismatchException)
                {
                    throw new StatusScanUserException(name + " final path 与 lexical path 不一致。");
                }
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new StatusScanFallbackException("identity-query-failed");
                }
                using (FileStream stream = new FileStream(handle, FileAccess.Read))
                using (MemoryStream buffer = new MemoryStream())
                {
                    stream.CopyTo(buffer);
                    bytes = buffer.ToArray();
                }
                handle.Dispose();
                handle = null;
                identityVolume = information.VolumeSerialNumber.ToString("x8", CultureInfo.InvariantCulture);
                identityIndex = information.FileIndexHigh.ToString("x8", CultureInfo.InvariantCulture) +
                    information.FileIndexLow.ToString("x8", CultureInfo.InvariantCulture);
            }
            catch (StatusScanUserException)
            {
                throw;
            }
            catch (StatusScanFallbackException)
            {
                throw;
            }
            catch (Exception)
            {
                // Read/identity failures fall back so PowerShell reproduces the exact message.
                throw new StatusScanFallbackException("read-failed");
            }
            finally
            {
                if (handle != null) { handle.Dispose(); }
            }
            readWatch.Stop();
            Stopwatch hashWatch = Stopwatch.StartNew();
            string sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
            hashWatch.Stop();

            string text;
            try
            {
                UTF8Encoding utf8 = new UTF8Encoding(false, true);
                bool hasBom = bytes.Length >= 3 &&
                    bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;
                text = hasBom ? utf8.GetString(bytes, 3, bytes.Length - 3) : utf8.GetString(bytes);
            }
            catch (Exception ex)
            {
                throw new StatusScanUserException(name + " 不是严格 UTF-8：" + ex.Message);
            }

            snapshot.Bytes = bytes;
            snapshot.Sha256 = sha256;
            snapshot.IdentityVolume = identityVolume;
            snapshot.IdentityIndex = identityIndex;
            snapshot.Text = text;
            snapshot.ReadMs = readWatch.ElapsedMilliseconds;
            snapshot.HashMs = hashWatch.ElapsedMilliseconds;
            metrics.BytesHashed += bytes.Length;
            // Reference metrics observer semantics: 'hash-read' events carry zero logical
            // bytes; logicalBytes only accumulates from tree materialization events.
            metrics.Sha256Ms += hashWatch.ElapsedMilliseconds;
            if (terminalArchiveSegment)
            {
                metrics.TerminalArchiveAuthMs += readWatch.ElapsedMilliseconds;
            }
            else
            {
                metrics.PlanTransactionReadMs += readWatch.ElapsedMilliseconds;
            }
            return snapshot;
        }

        private static JsonDocument ParseJsonDocument(string text)
        {
            try
            {
                JsonDocumentOptions options = new JsonDocumentOptions();
                options.AllowTrailingCommas = false;
                options.CommentHandling = JsonCommentHandling.Disallow;
                options.MaxDepth = 128;
                return JsonDocument.Parse(text, options);
            }
            catch (JsonException)
            {
                throw new StatusScanFallbackException("json-parse-failed");
            }
        }

        /// <returns>The maximum observed nesting depth, for ConvertFrom-Json depth parity.</returns>
        private static int AssertStrictJsonText(string jsonText)
        {
            JsonDocument document;
            try
            {
                JsonDocumentOptions options = new JsonDocumentOptions();
                options.AllowTrailingCommas = false;
                options.CommentHandling = JsonCommentHandling.Disallow;
                options.MaxDepth = 128;
                document = JsonDocument.Parse(jsonText, options);
            }
            catch (JsonException ex)
            {
                throw new StatusScanUserException("严格 JSON 词法校验失败：" + ex.Message);
            }
            try
            {
                return WalkUniqueProperties(document.RootElement, "$", 0);
            }
            finally
            {
                document.Dispose();
            }
        }

        private static int WalkUniqueProperties(JsonElement element, string path, int depth)
        {
            int maxDepth = depth;
            if (element.ValueKind == JsonValueKind.Object)
            {
                HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (JsonProperty property in element.EnumerateObject())
                {
                    if (!seen.Add(property.Name))
                    {
                        throw new StatusScanUserException("重复 JSON 属性：" + path + "." + property.Name);
                    }
                    int childDepth = WalkUniqueProperties(
                        property.Value, path + "." + property.Name, depth + 1);
                    if (childDepth > maxDepth) { maxDepth = childDepth; }
                }
            }
            else if (element.ValueKind == JsonValueKind.Array)
            {
                int index = 0;
                foreach (JsonElement item in element.EnumerateArray())
                {
                    int childDepth = WalkUniqueProperties(
                        item,
                        path + "[" + index.ToString(CultureInfo.InvariantCulture) + "]",
                        depth + 1);
                    if (childDepth > maxDepth) { maxDepth = childDepth; }
                    index++;
                }
            }
            return maxDepth;
        }

        private static string ResolveManagedFilePath(
            string runDirectory,
            string fullEvidenceRoot,
            string fileName,
            string name)
        {
            string fullRun = AssertDPath(runDirectory, name + " run");
            string parent = Path.GetDirectoryName(fullRun);
            if (parent == null || !PathEqual(parent, fullEvidenceRoot))
            {
                throw new StatusScanUserException(name + " 必须位于 evidence root 的直接 operation run 下。");
            }
            string fullPath = AssertDPath(Path.Combine(fullRun, fileName), name);
            if (fullPath.Substring(2).Contains(":"))
            {
                throw new StatusScanUserException(name + " 不得包含 NTFS alternate data stream。");
            }
            if (!PathWithin(fullPath, parent) ||
                string.Equals(fullPath, fullRun, StringComparison.OrdinalIgnoreCase))
            {
                throw new StatusScanUserException(name + " 越出 operation run。");
            }
            return fullPath;
        }

        private static string AssertDPath(string value, string name)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new StatusScanUserException(name + " 必须是 JSON string。");
            }
            if (!Path.IsPathFullyQualified(value))
            {
                throw new StatusScanUserException(name + " 必须是 D 盘绝对路径：" + value);
            }
            if (value.Length > 2)
            {
                string rest = value.Substring(2);
                for (int i = 0; i < rest.Length; i++)
                {
                    char c = rest[i];
                    if (c == ':' || c == '*' || c == '?' || c == '<' || c == '>' || c == '"' || c == '|' ||
                        c < '\x20')
                    {
                        throw new StatusScanUserException(name + " 包含 ADS、通配符或非法字符：" + value);
                    }
                }
            }
            string fullPath = Path.GetFullPath(value);
            if (!string.Equals(Path.GetPathRoot(fullPath), "D:\\", StringComparison.OrdinalIgnoreCase))
            {
                throw new StatusScanUserException(name + " 必须位于 D:\\：" + fullPath);
            }
            foreach (string segment in fullPath.Substring(3).Split(
                new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries))
            {
                if (segment.EndsWith(".", StringComparison.Ordinal) ||
                    segment.EndsWith(" ", StringComparison.Ordinal) ||
                    ReservedName.IsMatch(Path.GetFileNameWithoutExtension(segment)))
                {
                    throw new StatusScanUserException(name + " 包含 Windows 保留路径片段：" + segment);
                }
            }
            return fullPath;
        }

        private static string AssertDPathQuiet(string value)
        {
            try
            {
                return AssertDPath(value, "safe-delete capability root");
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static void AssertCapabilityPath(
            string path, string capabilityRoot, string allowedExactPath, string name)
        {
            string fullPath = AssertDPath(path, name);
            string fullRoot = AssertDPath(capabilityRoot, name + " capability root");
            if (!PathWithin(fullPath, fullRoot))
            {
                throw new StatusScanUserException(name + " 超出 capability root。");
            }
            if (fullPath.Substring(2).Contains(":"))
            {
                throw new StatusScanUserException(name + " 不得包含 NTFS alternate data stream。");
            }
            if (!string.Equals(fullPath, AssertDPath(allowedExactPath, name + " allowed exact path"),
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new StatusScanUserException(name + " 不在 exact-path capability allowlist。");
            }
            string reparseError = AssertNoReparseAncestor(fullPath, name);
            if (reparseError != null)
            {
                throw new StatusScanUserException(reparseError);
            }
        }

        private static string AssertNoReparseAncestor(string fullPath, string name)
        {
            string root = Path.GetPathRoot(fullPath);
            uint rootAttributes = GetFileAttributesW(root);
            if (rootAttributes == InvalidFileAttributes)
            {
                throw new StatusScanFallbackException("root-attributes-unavailable");
            }
            if ((rootAttributes & FileAttributeReparsePoint) != 0)
            {
                return name + " 祖先包含 reparse point。";
            }
            string currentPath = root;
            foreach (string segment in fullPath.Substring(root.Length).Split(
                new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries))
            {
                currentPath = Path.Combine(currentPath, segment);
                uint attributes = GetFileAttributesW(currentPath);
                if (attributes == InvalidFileAttributes)
                {
                    // The reference walk (Assert-CodexHookNoReparseAncestor) only stops on a
                    // genuinely missing entry (Test-Path returns false); every other attribute
                    // query failure makes Get-Item -ErrorAction Stop throw, so the outcome is
                    // not provable here and the record falls back to the reference path.
                    int win32Error = Marshal.GetLastWin32Error();
                    if (win32Error == ErrorFileNotFound || win32Error == ErrorPathNotFound)
                    {
                        break;
                    }
                    throw new StatusScanFallbackException("ancestor-attribute-query-failed");
                }
                if ((attributes & FileAttributeReparsePoint) != 0)
                {
                    return name + " 祖先或 final path 包含 reparse point。";
                }
            }
            return null;
        }

        private static bool PathWithin(string path, string parentPath)
        {
            string candidate = Path.GetFullPath(path).TrimEnd('\\', '/');
            string parent = Path.GetFullPath(parentPath).TrimEnd('\\', '/');
            return string.Equals(candidate, parent, StringComparison.OrdinalIgnoreCase) ||
                candidate.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase);
        }

        private static bool PathEqual(string left, string right)
        {
            return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
        }

        private static NamespaceState ProbeNamespace(string path)
        {
            FileAttributes attributes;
            try
            {
                attributes = File.GetAttributes(path);
            }
            catch (FileNotFoundException)
            {
                return new NamespaceState { Present = false, EntryType = "absent" };
            }
            catch (DirectoryNotFoundException)
            {
                return new NamespaceState { Present = false, EntryType = "absent" };
            }
            catch (Exception)
            {
                // Unexpected probe failures fall back so PowerShell reproduces the outcome.
                throw new StatusScanFallbackException("namespace-probe-failed");
            }
            string entryType;
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                entryType = "reparse-point";
            }
            else if ((attributes & FileAttributes.Directory) != 0)
            {
                entryType = "directory";
            }
            else
            {
                // Reference entryType 'file' requires Get-Item to hand back a FileInfo; raw
                // attribute bits cannot prove that (the reference also keeps an 'other'
                // bucket for entries that are neither FileInfo nor DirectoryInfo). The
                // non-directory, non-reparse bucket therefore falls back instead of
                // guessing the classification.
                throw new StatusScanFallbackException("namespace-entry-type-other");
            }
            return new NamespaceState { Present = true, EntryType = entryType };
        }

        private static void AssertDirectoryTreeIdentity(string[] expected, string[] actual, string scope)
        {
            if (expected == null || expected.Length != 2 ||
                !LowerHex8.IsMatch(expected[0]) || !LowerHex16.IsMatch(expected[1]))
            {
                throw new StatusScanUserException(scope + " expected identity 非法。");
            }
            if (actual == null || actual.Length != 2 ||
                !LowerHex8.IsMatch(actual[0]) || !LowerHex16.IsMatch(actual[1]))
            {
                throw new StatusScanUserException(scope + " observed identity 非法。");
            }
            if (!string.Equals(expected[0], actual[0], StringComparison.Ordinal) ||
                !string.Equals(expected[1], actual[1], StringComparison.Ordinal))
            {
                throw new StatusScanUserException(
                    "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: " + scope + " 身份漂移。");
            }
        }

        private static string[] RequireIdentityArray(JsonElement element, string name)
        {
            JsonElement identity;
            if (!element.TryGetProperty(name, out identity) || identity.ValueKind != JsonValueKind.Array ||
                identity.GetArrayLength() != 2)
            {
                return null;
            }
            string[] values = new string[2];
            int index = 0;
            foreach (JsonElement item in identity.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String)
                {
                    values[index] = item.GetString();
                }
                else if (item.ValueKind == JsonValueKind.Number && item.TryGetInt64(out long numeric))
                {
                    values[index] = numeric.ToString(CultureInfo.InvariantCulture);
                }
                else
                {
                    return null;
                }
                index++;
            }
            return values;
        }

        private static void AssertExactProperties(JsonElement element, string[] names, string scope)
        {
            if (!HasExactProperties(element, names))
            {
                throw new StatusScanUserException(scope + " 属性集合非法。");
            }
        }

        private static bool HasExactProperties(JsonElement element, string[] names)
        {
            if (element.ValueKind != JsonValueKind.Object) { return false; }
            int count = 0;
            foreach (JsonProperty property in element.EnumerateObject())
            {
                count++;
                if (count > names.Length) { return false; }
            }
            if (count != names.Length) { return false; }
            foreach (string name in names)
            {
                if (!element.TryGetProperty(name, out JsonElement unused)) { return false; }
            }
            return true;
        }

        private static bool HasPropertySubset(JsonElement element, string[] required, string[] optional)
        {
            if (element.ValueKind != JsonValueKind.Object) { return false; }
            int count = 0;
            foreach (JsonProperty property in element.EnumerateObject())
            {
                count++;
                bool known = false;
                foreach (string name in required) { if (name == property.Name) { known = true; break; } }
                if (!known)
                {
                    foreach (string name in optional) { if (name == property.Name) { known = true; break; } }
                }
                if (!known) { return false; }
            }
            if (count < required.Length) { return false; }
            foreach (string name in required)
            {
                if (!element.TryGetProperty(name, out JsonElement unused)) { return false; }
            }
            return true;
        }

        private static bool HasOnlyCanonicalPropertyNames(JsonElement element, string[] canonical)
        {
            if (element.ValueKind != JsonValueKind.Object) { return false; }
            foreach (JsonProperty property in element.EnumerateObject())
            {
                bool known = false;
                foreach (string name in canonical)
                {
                    if (string.Equals(name, property.Name, StringComparison.Ordinal)) { known = true; break; }
                }
                if (!known) { return false; }
            }
            return true;
        }

        private static bool HasAllPropertiesOrdinalIgnoreCase(JsonElement element, string[] names)
        {
            if (element.ValueKind != JsonValueKind.Object) { return false; }
            foreach (string name in names)
            {
                bool found = false;
                foreach (JsonProperty property in element.EnumerateObject())
                {
                    if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) { return false; }
            }
            return true;
        }

        private static bool HasCanonicalPlanShape(JsonElement plan)
        {
            if (!HasOnlyCanonicalPropertyNames(plan, PlanCanonicalNames)) { return false; }
            foreach (string required in PlanRequiredNames)
            {
                if (!plan.TryGetProperty(required, out JsonElement unused)) { return false; }
            }
            return true;
        }

        private static bool HasCanonicalTransactionShape(JsonElement transaction, long schemaVersion)
        {
            string[] canonical;
            if (schemaVersion == 1L)
            {
                canonical = TransactionV1CanonicalNames;
            }
            else if (schemaVersion == 2L)
            {
                canonical = TransactionV2CanonicalNames;
            }
            else if (schemaVersion == 3L)
            {
                canonical = TransactionV3CanonicalNames;
            }
            else
            {
                return true;
            }
            if (!HasOnlyCanonicalPropertyNames(transaction, canonical)) { return false; }
            foreach (string name in canonical)
            {
                if (!transaction.TryGetProperty(name, out JsonElement unused)) { return false; }
            }
            return true;
        }

        private static bool IsStringProperty(JsonElement element, string name)
        {
            JsonElement value;
            return element.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.String;
        }

        private static bool IsBoolPropertyTrue(JsonElement element, string name)
        {
            JsonElement value;
            return element.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.True;
        }

        private static string GetString(JsonElement element, string name)
        {
            return element.GetProperty(name).GetString();
        }

        private static string GetStringOrNull(JsonElement element, string name)
        {
            JsonElement value;
            if (!element.TryGetProperty(name, out value) || value.ValueKind != JsonValueKind.String)
            {
                return null;
            }
            return value.GetString();
        }

        private static string GetStringOrEmpty(JsonElement element, string name)
        {
            JsonElement value;
            if (!element.TryGetProperty(name, out value)) { return string.Empty; }
            if (value.ValueKind == JsonValueKind.String) { return value.GetString(); }
            return string.Empty;
        }

        private static string CoerceStringForGuid(JsonElement element, string name)
        {
            JsonElement value;
            if (!element.TryGetProperty(name, out value)) { return string.Empty; }
            switch (value.ValueKind)
            {
                case JsonValueKind.String: return value.GetString();
                case JsonValueKind.Null: return string.Empty;
                case JsonValueKind.Number:
                    long numeric;
                    if (value.TryGetInt64(out numeric))
                    {
                        return numeric.ToString(CultureInfo.InvariantCulture);
                    }
                    throw new StatusScanFallbackException("guid-coercion-unsupported");
                default:
                    throw new StatusScanFallbackException("guid-coercion-unsupported");
            }
        }

        /// <summary>Coerces a plan string property exactly like [string]$plan.X at the call site.</summary>
        private static string CoerceStringForPath(JsonElement element, string name, string pathName)
        {
            JsonElement value;
            if (!element.TryGetProperty(name, out value))
            {
                return AssertDPath(string.Empty, pathName);
            }
            switch (value.ValueKind)
            {
                case JsonValueKind.String:
                    return AssertDPath(value.GetString(), pathName);
                case JsonValueKind.Null:
                    return AssertDPath(string.Empty, pathName);
                case JsonValueKind.Number:
                    long numeric;
                    if (value.TryGetInt64(out numeric))
                    {
                        return AssertDPath(numeric.ToString(CultureInfo.InvariantCulture), pathName);
                    }
                    throw new StatusScanFallbackException("path-coercion-unsupported");
                default:
                    throw new StatusScanFallbackException("path-coercion-unsupported");
            }
        }

        private static long RequireInt64(JsonElement element, string name)
        {
            long numeric;
            if (!TryGetInt64(element, name, out numeric))
            {
                throw new StatusScanFallbackException("int64-coercion-unsupported");
            }
            return numeric;
        }

        private static long GetInt64OrMinusOne(JsonElement element, string name)
        {
            JsonElement value;
            if (!element.TryGetProperty(name, out value) ||
                value.ValueKind != JsonValueKind.Number ||
                !value.TryGetInt64(out long numeric))
            {
                return -1L;
            }
            return numeric;
        }

        private static bool TryGetInt64(JsonElement element, string name, out long value)
        {
            value = 0L;
            JsonElement property;
            if (!element.TryGetProperty(name, out property) ||
                property.ValueKind != JsonValueKind.Number)
            {
                return false;
            }
            return property.TryGetInt64(out value);
        }

        private static string BindingString(
            Dictionary<string, JsonElement> map, string name, string scope)
        {
            JsonElement element;
            if (!map.TryGetValue(name, out element))
            {
                throw new StatusScanUserException(scope + " 缺少 " + name + "。");
            }
            if (element.ValueKind != JsonValueKind.String)
            {
                throw new StatusScanUserException(scope + " " + name + " 必须是 JSON string。");
            }
            return element.GetString();
        }

        private static long BindingInt64(
            Dictionary<string, JsonElement> map, string name, string scope)
        {
            JsonElement element;
            if (!map.TryGetValue(name, out element))
            {
                throw new StatusScanUserException(scope + " 缺少 " + name + "。");
            }
            long value = 0L;
            if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt64(out value))
            {
                throw new StatusScanUserException(scope + " " + name + " 必须是 JSON integer。");
            }
            return value;
        }

        private static long BindingArrayCount(Dictionary<string, JsonElement> map, string name)
        {
            JsonElement element;
            if (!map.TryGetValue(name, out element))
            {
                return 0L;
            }
            if (element.ValueKind == JsonValueKind.Null)
            {
                return 0L;
            }
            if (element.ValueKind != JsonValueKind.Array)
            {
                throw new StatusScanUserException("safe-delete Status " + name + " 必须是 JSON array。");
            }
            return element.GetArrayLength();
        }

        private static int IndexOfAnyInvalidFileNameChar(string segment)
        {
            return segment.IndexOfAny(InvalidFileNameChars);
        }
    }

    // ===== issue #58: Status 树快照 / manifest SHA 快速路径 =====
    // 与 Get-CodexHookCapabilityDirectoryTreeSnapshot（CodexHostSafety.ps1:789-955）逐一同构的
    // C# 单次遍历：entry schema、walk 顺序（深度优先、兄弟按 Sort-Object Name 语义排序）、
    // reparse/junction 政策、handle/identity/SHA 校验全部等价。任何无法证明与 PS 参考路径
    // 逐字节等价的情形（IO 错误、非规范名称、排序并列、异常 reparse 载荷等）一律抛
    // StatusFastPathFallbackException，由 PowerShell 参考路径重放并产出精确的原生错误消息。

    public sealed class StatusFastPathFallbackException : Exception
    {
        public StatusFastPathFallbackException(string reason) : base(reason) { }
    }

    public sealed class StatusTreeSnapshotEntry
    {
        public string RelativePath;
        public string Kind;
        public string Sha256;
        public string IdentityVolume;
        public string IdentityIndex;
    }

    public sealed class StatusTreeSnapshotResult
    {
        public StatusTreeSnapshotEntry[] Entries;
        public string RootIdentityVolume;
        public string RootIdentityIndex;
        public string ManifestSha256;
        public long FileContentBytes;
        public long ReparseDataBytes;

        // issue #58：逐 entry 的 PS 物化（[pscustomobject][ordered]）在数万 entry 的树上
        // 是 wrapper 内最大 CPU 项；这里用 SMA 直建同形状 PSObject（四个 note property、
        // identity 为 string[2]、sha256 允许 null），与参考路径 schema 逐属性一致。
        public PSObject[] MaterializeEntries()
        {
            StatusTreeSnapshotEntry[] entries = Entries;
            PSObject[] result = new PSObject[entries.Length];
            for (int i = 0; i < entries.Length; i++)
            {
                StatusTreeSnapshotEntry entry = entries[i];
                PSObject obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("relativePath", entry.RelativePath));
                obj.Properties.Add(new PSNoteProperty("kind", entry.Kind));
                obj.Properties.Add(new PSNoteProperty("sha256", entry.Sha256));
                obj.Properties.Add(new PSNoteProperty(
                    "identity",
                    new string[2] { entry.IdentityVolume, entry.IdentityIndex }));
                result[i] = obj;
            }
            return result;
        }
    }

    internal static class StatusCanonicalJson
    {
        // PowerShell 7 ConvertTo-Json 的字符串转义规则（本机 7.6.5 实测）：只有 '"'、'\'、
        // \b \t \n \f \r 走短转义，其余控制字符走小写 \u00xx，非 ASCII（含代理项对）原样输出。
        internal static void WriteJsonString(StringBuilder builder, string value)
        {
            builder.Append('"');
            foreach (char c in value)
            {
                switch (c)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\t': builder.Append("\\t"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\r': builder.Append("\\r"); break;
                    default:
                        if (c < 0x20)
                        {
                            builder.Append("\\u");
                            builder.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(c);
                        }
                        break;
                }
            }
            builder.Append('"');
        }

        internal static string HashUtf8(string text)
        {
            using (SHA256 sha256 = SHA256.Create())
            {
                return Convert.ToHexString(sha256.ComputeHash(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
            }
        }
    }

    public static class StatusTreeSnapshotScanner
    {
        private const uint GenericRead = 0x80000000;
        private const uint FileWriteAttributesAccess = 0x00000100;
        private const uint DeleteAccess = 0x00010000;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x80;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileAttributeDirectory = 0x10;
        private const uint FileAttributeReparsePoint = 0x400;
        private const uint FileNameNormalized = 0x0;
        private const int ErrorMoreData = 234;
        private const int ErrorHandleEof = 38;
        private const uint FsctlGetReparsePoint = 0x000900A8;
        private const uint IoReparseTagMountPoint = 0xA0000003;
        private const int FileStreamInformationClass = 7;
        private const int MaximumReparseDataBufferSize = 16 * 1024;

        private static readonly Regex ReservedSegmentName = new Regex(
            "^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", RegexOptions.Compiled);
        private static readonly char[] InvalidFileNameChars = Path.GetInvalidFileNameChars();

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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle fileHandle,
            out ByHandleFileInformation fileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle fileHandle,
            int fileInformationClass,
            IntPtr fileInformation,
            uint bufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle fileHandle,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint ioControlCode,
            IntPtr inBuffer,
            uint inBufferSize,
            IntPtr outBuffer,
            uint outBufferSize,
            out uint bytesReturned,
            IntPtr overlapped);

        private struct ChildItem
        {
            public string Name;
            public uint Attributes;
        }

        [ThreadStatic]
        private static string currentStage;

        private sealed class SiblingNameComparer : IComparer<ChildItem>
        {
            internal static readonly SiblingNameComparer Instance = new SiblingNameComparer();
            // Sort-Object -Property Name（不带 -CaseSensitive）的实测语义 = 当前 culture 忽略大小写。
            private static readonly StringComparer CultureComparer =
                StringComparer.Create(CultureInfo.CurrentCulture, true);

            public int Compare(ChildItem left, ChildItem right)
            {
                int result = CultureComparer.Compare(left.Name, right.Name);
                if (result == 0 && !string.Equals(left.Name, right.Name, StringComparison.Ordinal))
                {
                    // culture 并列但 ordinal 不等（PS 排序稳定性无法复刻）→ 交还参考路径。
                    throw new StatusFastPathFallbackException("sibling-name-collation-tie");
                }
                return result;
            }
        }

        private sealed class ScanContext
        {
            internal bool AllowHardLinks;
            internal bool AllowInternalDirectoryJunctions;
            internal string JunctionTargetRoot;
            internal List<StatusTreeSnapshotEntry> Entries = new List<StatusTreeSnapshotEntry>();
            internal List<PendingFile> PendingFiles = new List<PendingFile>();
            internal long FileContentBytes;
            internal long ReparseDataBytes;
        }

        // issue #58：冷盘单文件 lease 是 IO 延迟bound（实测 ~1.5-5ms/entry，队列深度 1；
        // node_modules 类树目录小批次 <8 文件使目录级并行失效，68K 树串行实测 104s）。
        // 文件核验+哈希改为全树一批并行填充：串行 DFS 只追加 skeleton entry（位置固定，
        // 条目顺序不变），walk 结束后一次性 Parallel.ForEach。目录句柄窗口不再覆盖填充段；
        // 补偿不变量：rootGuard 由 PS 调用方全程持有，每文件 open 仍有 reparse/finalpath/
        // identity 双验，漂移一律 fail-closed 回退 PS 重放（参考路径产出精确错误）。
        private sealed class PendingFile
        {
            internal StatusTreeSnapshotEntry Entry;
            internal string Path;
            internal long SizeBytes;
            internal Exception Failure;
        }

        public static StatusTreeSnapshotResult Scan(
            string rootPath,
            bool allowHardLinks,
            bool allowInternalDirectoryJunctions,
            string junctionTargetRoot)
        {
            try
            {
                return ScanCore(rootPath, allowHardLinks, allowInternalDirectoryJunctions, junctionTargetRoot);
            }
            catch (StatusFastPathFallbackException)
            {
                throw;
            }
            catch (Exception ex)
            {
                int? code = (ex as Win32Exception)?.NativeErrorCode;
                throw new StatusFastPathFallbackException(
                    "tree-scan-" + ex.GetType().Name +
                    (code.HasValue ? ("-" + code.Value.ToString(CultureInfo.InvariantCulture)) : "") +
                    ":" + ex.Message + " @" + (currentStage ?? "?"));
            }
        }

        private static StatusTreeSnapshotResult ScanCore(
            string rootPath,
            bool allowHardLinks,
            bool allowInternalDirectoryJunctions,
            string junctionTargetRoot)
        {
            if (string.IsNullOrEmpty(rootPath))
            {
                throw new StatusFastPathFallbackException("empty-root");
            }
            ScanContext context = new ScanContext();
            context.AllowHardLinks = allowHardLinks;
            context.AllowInternalDirectoryJunctions = allowInternalDirectoryJunctions;
            if (allowInternalDirectoryJunctions)
            {
                if (string.IsNullOrWhiteSpace(junctionTargetRoot))
                {
                    throw new StatusFastPathFallbackException("junction-root-missing");
                }
                context.JunctionTargetRoot = TrimDirectoryEnding(Path.GetFullPath(junctionTargetRoot));
            }
            string normalizedRoot = TrimDirectoryEnding(Path.GetFullPath(rootPath));
            WalkDirectory(context, normalizedRoot, ".");
            FillPendingFiles(context, context.PendingFiles);

            string rootVolume = context.Entries[0].IdentityVolume;
            string rootIndex = context.Entries[0].IdentityIndex;
            StringBuilder full = new StringBuilder();
            full.Append("{\"schemaVersion\":2,\"rootIdentity\":[");
            StatusCanonicalJson.WriteJsonString(full, rootVolume);
            full.Append(',');
            StatusCanonicalJson.WriteJsonString(full, rootIndex);
            full.Append("],\"entries\":[");
            bool firstEntry = true;
            foreach (StatusTreeSnapshotEntry entry in context.Entries)
            {
                if (!firstEntry)
                {
                    full.Append(',');
                }
                firstEntry = false;
                AppendManifestEntry(full, entry);
            }
            full.Append("]}");

            StatusTreeSnapshotResult result = new StatusTreeSnapshotResult();
            result.Entries = context.Entries.ToArray();
            result.RootIdentityVolume = rootVolume;
            result.RootIdentityIndex = rootIndex;
            result.ManifestSha256 = StatusCanonicalJson.HashUtf8(full.ToString());
            result.FileContentBytes = context.FileContentBytes;
            result.ReparseDataBytes = context.ReparseDataBytes;
            return result;
        }

        private static void WalkDirectory(ScanContext context, string directoryPath, string relativePath)
        {
            SafeFileHandle handle = OpenVerifiedDirectory(directoryPath);
            try
            {
                string volume;
                string index;
                GetIdentityFromHandle(handle, out volume, out index);
                AppendEntry(context, relativePath, "directory", null, volume, index);
                List<ChildItem> children = EnumerateChildren(directoryPath);
                children.Sort(SiblingNameComparer.Instance);
                foreach (ChildItem child in children)
                {
                    AssertCanonicalChildName(child.Name);
                    string childPath = CombinePath(directoryPath, child.Name);
                    string childRelative = string.Equals(relativePath, ".", StringComparison.Ordinal)
                        ? child.Name
                        : relativePath + "/" + child.Name;
                    bool isReparse = (child.Attributes & FileAttributeReparsePoint) != 0;
                    bool isDirectory = (child.Attributes & FileAttributeDirectory) != 0;
                    if (isReparse)
                    {
                        if (!context.AllowInternalDirectoryJunctions || !isDirectory)
                        {
                            // 参考路径在此抛精确错误；回退由 PS 重放该错误。
                            throw new StatusFastPathFallbackException("unauthorized-reparse-point");
                        }
                        ProcessJunction(context, childPath, childRelative);
                        continue;
                    }
                    if (isDirectory)
                    {
                        WalkDirectory(context, childPath, childRelative);
                        continue;
                    }
                    QueueFile(context, childPath, childRelative);
                }
            }
            finally
            {
                handle.Dispose();
            }
        }

        private static void QueueFile(
            ScanContext context,
            string filePath,
            string relativePath)
        {
            StatusTreeSnapshotEntry entry = new StatusTreeSnapshotEntry();
            entry.RelativePath = relativePath;
            entry.Kind = "file";
            context.Entries.Add(entry);
            PendingFile file = new PendingFile();
            file.Entry = entry;
            file.Path = filePath;
            context.PendingFiles.Add(file);
        }

        private static void FillPendingFiles(ScanContext context, List<PendingFile> pendingFiles)
        {
            if (pendingFiles.Count == 0)
            {
                return;
            }
            if (pendingFiles.Count < 8)
            {
                foreach (PendingFile file in pendingFiles)
                {
                    FillFile(context, file);
                }
            }
            else
            {
                System.Threading.Tasks.Parallel.ForEach(
                    pendingFiles,
                    new System.Threading.Tasks.ParallelOptions
                    {
                        MaxDegreeOfParallelism = Math.Min(32, Math.Max(4, Environment.ProcessorCount * 2))
                    },
                    file => FillFile(context, file));
            }
            // 失败按 DFS 序抛首个，保持回退原因确定性；一切异常最终由 Scan() 包成 typed fallback。
            foreach (PendingFile file in pendingFiles)
            {
                if (file.Failure != null)
                {
                    throw file.Failure;
                }
                context.FileContentBytes += file.SizeBytes;
            }
            pendingFiles.Clear();
        }

        private static void FillFile(ScanContext context, PendingFile file)
        {
            try
            {
                currentStage = "file-open:" + file.Path;
                SafeFileHandle handle = CreateFileW(
                    ToExtendedPath(file.Path),
                    GenericRead | FileWriteAttributesAccess | DeleteAccess,
                    FileShare.Read,
                    IntPtr.Zero,
                    OpenExisting,
                    FileAttributeNormal | FileFlagOpenReparsePoint,
                    IntPtr.Zero);
                if (handle.IsInvalid)
                {
                    int openError = Marshal.GetLastWin32Error();
                    handle.Dispose();
                    throw new Win32Exception(openError);
                }
                try
                {
                    currentStage = "file-verify";
                    ByHandleFileInformation info = VerifyFileHandle(handle, file.Path, context.AllowHardLinks);
                    string volume = info.VolumeSerialNumber.ToString("x8", CultureInfo.InvariantCulture);
                    string index = info.FileIndexHigh.ToString("x8", CultureInfo.InvariantCulture) +
                        info.FileIndexLow.ToString("x8", CultureInfo.InvariantCulture);
                    // ComputeSha256FromHandle 语义：哈希前整柄重验 + identity 不变断言。
                    ByHandleFileInformation verifyInfo = VerifyFileHandle(handle, file.Path, context.AllowHardLinks);
                    string verifyVolume = verifyInfo.VolumeSerialNumber.ToString("x8", CultureInfo.InvariantCulture);
                    string verifyIndex = verifyInfo.FileIndexHigh.ToString("x8", CultureInfo.InvariantCulture) +
                        verifyInfo.FileIndexLow.ToString("x8", CultureInfo.InvariantCulture);
                    if (!string.Equals(volume, verifyVolume, StringComparison.Ordinal) ||
                        !string.Equals(index, verifyIndex, StringComparison.Ordinal))
                    {
                        throw new StatusFastPathFallbackException("file-identity-drift");
                    }
                    currentStage = "file-hash";
                    byte[] hash = HashHandleContents(handle);
                    file.Entry.Sha256 = Convert.ToHexString(hash).ToLowerInvariant();
                    file.Entry.IdentityVolume = volume;
                    file.Entry.IdentityIndex = index;
                    file.SizeBytes = ((long)info.FileSizeHigh << 32) | info.FileSizeLow;
                }
                finally
                {
                    handle.Dispose();
                }
            }
            catch (Exception ex)
            {
                file.Failure = ex;
            }
        }

        private static void ProcessJunction(ScanContext context, string junctionPath, string relativePath)
        {
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(junctionPath),
                GenericRead | FileWriteAttributesAccess | DeleteAccess,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int openError = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(openError);
            }
            try
            {
                ByHandleFileInformation info = GetInfo(handle);
                if ((info.FileAttributes & FileAttributeReparsePoint) == 0 ||
                    (info.FileAttributes & FileAttributeDirectory) == 0)
                {
                    throw new StatusFastPathFallbackException("junction-not-a-directory-reparse-point");
                }
                AssertFinalPathMatches(handle, junctionPath, true);
                AssertDirectoryHasNoAlternateDataStreams(handle);
                byte[] reparseData = ReadReparseData(handle);
                uint reparseTag = ReadUInt32(reparseData, 0);
                if (reparseTag != IoReparseTagMountPoint)
                {
                    throw new StatusFastPathFallbackException("junction-not-mount-point");
                }
                string targetPath = ParseMountPointTarget(reparseData);
                AssertJunctionTarget(targetPath, context.JunctionTargetRoot);
                byte[] reparseHash;
                using (SHA256 sha256 = SHA256.Create())
                {
                    reparseHash = sha256.ComputeHash(reparseData);
                }
                string volume = info.VolumeSerialNumber.ToString("x8", CultureInfo.InvariantCulture);
                string index = info.FileIndexHigh.ToString("x8", CultureInfo.InvariantCulture) +
                    info.FileIndexLow.ToString("x8", CultureInfo.InvariantCulture);
                AppendEntry(context, relativePath, "directory-junction",
                    Convert.ToHexString(reparseHash).ToLowerInvariant(), volume, index);
                context.ReparseDataBytes += reparseData.Length;
            }
            finally
            {
                handle.Dispose();
            }
        }

        private static void AppendEntry(
            ScanContext context,
            string relativePath,
            string kind,
            string sha256,
            string volume,
            string index)
        {
            StatusTreeSnapshotEntry entry = new StatusTreeSnapshotEntry();
            entry.RelativePath = relativePath;
            entry.Kind = kind;
            entry.Sha256 = sha256;
            entry.IdentityVolume = volume;
            entry.IdentityIndex = index;
            context.Entries.Add(entry);
        }

        // manifest JSON 在全部条目（含并行填充的文件 sha/identity）就绪后串行拼装，
        // 属性序与条目序和参考 ConvertTo-Json 输出逐字节一致。
        private static void AppendManifestEntry(StringBuilder builder, StatusTreeSnapshotEntry entry)
        {
            builder.Append("{\"relativePath\":");
            StatusCanonicalJson.WriteJsonString(builder, entry.RelativePath);
            builder.Append(",\"kind\":");
            StatusCanonicalJson.WriteJsonString(builder, entry.Kind);
            builder.Append(",\"sha256\":");
            if (entry.Sha256 == null)
            {
                builder.Append("null");
            }
            else
            {
                StatusCanonicalJson.WriteJsonString(builder, entry.Sha256);
            }
            builder.Append(",\"identity\":[");
            StatusCanonicalJson.WriteJsonString(builder, entry.IdentityVolume);
            builder.Append(',');
            StatusCanonicalJson.WriteJsonString(builder, entry.IdentityIndex);
            builder.Append("]}");
        }

        private static SafeFileHandle OpenVerifiedDirectory(string directoryPath)
        {
            SafeFileHandle handle = CreateFileW(
                ToExtendedPath(directoryPath),
                GenericRead,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int openError = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(openError);
            }
            try
            {
                ByHandleFileInformation info = GetInfo(handle);
                if ((info.FileAttributes & FileAttributeReparsePoint) != 0 ||
                    (info.FileAttributes & FileAttributeDirectory) == 0)
                {
                    throw new StatusFastPathFallbackException("not-a-plain-directory");
                }
                AssertFinalPathMatches(handle, directoryPath, true);
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        private static ByHandleFileInformation VerifyFileHandle(
            SafeFileHandle handle,
            string filePath,
            bool allowHardLinks)
        {
            ByHandleFileInformation info = GetInfo(handle);
            if ((info.FileAttributes & FileAttributeReparsePoint) != 0 ||
                (info.FileAttributes & FileAttributeDirectory) != 0 ||
                info.NumberOfLinks == 0 ||
                (!allowHardLinks && info.NumberOfLinks != 1))
            {
                throw new StatusFastPathFallbackException("file-handle-verification");
            }
            AssertFinalPathMatches(handle, filePath, false);
            AssertFileHasNoAlternateDataStreams(handle);
            return info;
        }

        private static ByHandleFileInformation GetInfo(SafeFileHandle handle)
        {
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return info;
        }

        private static void GetIdentityFromHandle(SafeFileHandle handle, out string volume, out string index)
        {
            ByHandleFileInformation info = GetInfo(handle);
            volume = info.VolumeSerialNumber.ToString("x8", CultureInfo.InvariantCulture);
            index = info.FileIndexHigh.ToString("x8", CultureInfo.InvariantCulture) +
                info.FileIndexLow.ToString("x8", CultureInfo.InvariantCulture);
        }

        private static byte[] HashHandleContents(SafeFileHandle handle)
        {
            const int bufferSize = 1024 * 1024;
            byte[] buffer = ArrayPool<byte>.Shared.Rent(bufferSize);
            IncrementalHash incremental = null;
            try
            {
                incremental = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                long offset = 0L;
                while (true)
                {
                    int read = RandomAccess.Read(handle, buffer.AsSpan(0, bufferSize), offset);
                    if (read == 0)
                    {
                        break;
                    }
                    incremental.AppendData(buffer, 0, read);
                    offset += read;
                }
                return incremental.GetHashAndReset();
            }
            finally
            {
                try
                {
                    if (incremental != null) incremental.Dispose();
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(buffer, true);
                }
            }
        }

        private static List<ChildItem> EnumerateChildren(string directoryPath)
        {
            EnumerationOptions options = new EnumerationOptions
            {
                RecurseSubdirectories = false,
                AttributesToSkip = 0,
                ReturnSpecialDirectories = false,
                IgnoreInaccessible = false,
                BufferSize = 65536
            };
            FileSystemEnumerable<ChildItem> enumerable = new FileSystemEnumerable<ChildItem>(
                ToExtendedPath(directoryPath),
                (ref FileSystemEntry entry) => new ChildItem
                {
                    Name = entry.FileName.ToString(),
                    Attributes = (uint)entry.Attributes
                },
                options);
            List<ChildItem> children = new List<ChildItem>();
            foreach (ChildItem child in enumerable)
            {
                children.Add(child);
            }
            return children;
        }

        private static void AssertCanonicalChildName(string name)
        {
            // 等效 Assert-CodexHookDPath 的 segment 级校验（祖先段在各自入栈时已校验，
            // 根路径由调用方 PS 校验）；命中即回退，由参考路径抛出精确消息。
            if (name.Length == 0 ||
                name.IndexOfAny(InvalidFileNameChars) >= 0 ||
                name.EndsWith(".", StringComparison.Ordinal) ||
                name.EndsWith(" ", StringComparison.Ordinal) ||
                ReservedSegmentName.IsMatch(Path.GetFileNameWithoutExtension(name)))
            {
                throw new StatusFastPathFallbackException("non-canonical-child-name");
            }
        }

        private static void AssertJunctionTarget(string targetPath, string junctionTargetRoot)
        {
            // 等效 Assert-CodexHookDPath + Test-CodexHookPathWithin（target root 已由 PS 校验）。
            if (string.IsNullOrWhiteSpace(targetPath) || !Path.IsPathFullyQualified(targetPath))
            {
                throw new StatusFastPathFallbackException("junction-target-not-absolute");
            }
            if (targetPath.Length > 2)
            {
                string tail = targetPath.Substring(2);
                if (tail.IndexOfAny(new char[] { ':', '*', '?', '<', '>', '"', '|' }) >= 0 ||
                    tail.IndexOfAny(EnumerableRange0To1F()) >= 0)
                {
                    throw new StatusFastPathFallbackException("junction-target-illegal-char");
                }
            }
            string fullTarget = Path.GetFullPath(targetPath);
            if (!string.Equals(Path.GetPathRoot(fullTarget), "D:\\", StringComparison.OrdinalIgnoreCase))
            {
                throw new StatusFastPathFallbackException("junction-target-not-on-d");
            }
            foreach (string segment in fullTarget.Substring(3).Split(
                new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries))
            {
                if (segment.EndsWith(".", StringComparison.Ordinal) ||
                    segment.EndsWith(" ", StringComparison.Ordinal) ||
                    ReservedSegmentName.IsMatch(Path.GetFileNameWithoutExtension(segment)))
                {
                    throw new StatusFastPathFallbackException("junction-target-reserved-segment");
                }
            }
            if (!PathWithin(fullTarget, junctionTargetRoot))
            {
                throw new StatusFastPathFallbackException("junction-target-out-of-root");
            }
        }

        private static char[] EnumerableRange0To1F()
        {
            char[] chars = new char[32];
            for (int i = 0; i < 32; i++) { chars[i] = (char)i; }
            return chars;
        }

        private static bool PathWithin(string path, string parentPath)
        {
            string candidate = TrimDirectoryEnding(Path.GetFullPath(path));
            string parent = TrimDirectoryEnding(Path.GetFullPath(parentPath));
            return candidate.Equals(parent, StringComparison.OrdinalIgnoreCase) ||
                candidate.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase);
        }

        private static string CombinePath(string parent, string name)
        {
            if (parent.EndsWith("\\", StringComparison.Ordinal))
            {
                return parent + name;
            }
            return parent + "\\" + name;
        }

        private static string TrimDirectoryEnding(string path)
        {
            return path.TrimEnd('\\', '/');
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) { return path; }
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) { return @"\\?\UNC\" + path.Substring(2); }
            return @"\\?\" + path;
        }

        private static void AssertFinalPathMatches(SafeFileHandle handle, string lexicalPath, bool trimDirectoryEnding)
        {
            string openedPath = GetFinalPath(handle);
            string expected = Path.GetFullPath(lexicalPath);
            string actual = Path.GetFullPath(openedPath);
            if (trimDirectoryEnding)
            {
                expected = TrimDirectoryEnding(expected);
                actual = TrimDirectoryEnding(actual);
            }
            if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
            {
                throw new StatusFastPathFallbackException("final-path-mismatch");
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
                    return NormalizeFinalPath(buffer.ToString());
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

        private static void AssertFileHasNoAlternateDataStreams(SafeFileHandle handle)
        {
            const int headerLength = 24;
            int bufferLength = 4096;
            while (true)
            {
                IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
                try
                {
                    if (!GetFileInformationByHandleEx(
                            handle, FileStreamInformationClass, buffer, checked((uint)bufferLength)))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == ErrorMoreData && bufferLength < 1024 * 1024)
                        {
                            bufferLength = checked(bufferLength * 2);
                            continue;
                        }
                        throw new Win32Exception(error);
                    }
                    int offset = 0;
                    int defaultStreamCount = 0;
                    while (true)
                    {
                        if (offset < 0 || offset + headerLength > bufferLength)
                        {
                            throw new StatusFastPathFallbackException("stream-record-invalid");
                        }
                        int nextOffset = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 4);
                        if (nameLength < 0 || (nameLength & 1) != 0 ||
                            offset + headerLength + nameLength > bufferLength)
                        {
                            throw new StatusFastPathFallbackException("stream-name-invalid");
                        }
                        string streamName = Marshal.PtrToStringUni(
                            IntPtr.Add(buffer, offset + headerLength), nameLength / 2);
                        if (!string.Equals(streamName, "::$DATA", StringComparison.Ordinal))
                        {
                            throw new StatusFastPathFallbackException("alternate-data-stream");
                        }
                        defaultStreamCount++;
                        if (nextOffset == 0)
                        {
                            break;
                        }
                        if (nextOffset < headerLength || (nextOffset & 7) != 0 ||
                            offset + nextOffset > bufferLength)
                        {
                            throw new StatusFastPathFallbackException("stream-offset-invalid");
                        }
                        offset += nextOffset;
                    }
                    if (defaultStreamCount != 1)
                    {
                        throw new StatusFastPathFallbackException("default-stream-count");
                    }
                    return;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        private static void AssertDirectoryHasNoAlternateDataStreams(SafeFileHandle handle)
        {
            const int bufferLength = 4096;
            IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
            try
            {
                if (GetFileInformationByHandleEx(
                        handle, FileStreamInformationClass, buffer, bufferLength))
                {
                    throw new StatusFastPathFallbackException("directory-alternate-data-stream");
                }
                int error = Marshal.GetLastWin32Error();
                if (error != ErrorHandleEof)
                {
                    throw new Win32Exception(error);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static byte[] ReadReparseData(SafeFileHandle handle)
        {
            IntPtr buffer = Marshal.AllocHGlobal(MaximumReparseDataBufferSize);
            try
            {
                uint bytesReturned;
                if (!DeviceIoControl(
                        handle,
                        FsctlGetReparsePoint,
                        IntPtr.Zero,
                        0,
                        buffer,
                        MaximumReparseDataBufferSize,
                        out bytesReturned,
                        IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (bytesReturned < 16 || bytesReturned > MaximumReparseDataBufferSize)
                {
                    throw new StatusFastPathFallbackException("reparse-payload-length");
                }
                byte[] bytes = new byte[checked((int)bytesReturned)];
                Marshal.Copy(buffer, bytes, 0, bytes.Length);
                int declaredLength = bytes[4] | (bytes[5] << 8);
                if (declaredLength < 8 || declaredLength + 8 != bytes.Length)
                {
                    throw new StatusFastPathFallbackException("reparse-payload-header");
                }
                return bytes;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static string ParseMountPointTarget(byte[] reparseData)
        {
            const int pathBufferOffset = 16;
            int reparseDataLength = ReadUInt16(reparseData, 4);
            int pathBufferLength = checked(reparseDataLength - 8);
            int substituteNameOffset = ReadUInt16(reparseData, 8);
            int substituteNameLength = ReadUInt16(reparseData, 10);
            int printNameOffset = ReadUInt16(reparseData, 12);
            int printNameLength = ReadUInt16(reparseData, 14);
            ValidateReparseNameRange(substituteNameOffset, substituteNameLength, pathBufferLength);
            ValidateReparseNameRange(printNameOffset, printNameLength, pathBufferLength);
            string substituteName = Encoding.Unicode.GetString(
                reparseData,
                checked(pathBufferOffset + substituteNameOffset),
                substituteNameLength);
            if (string.IsNullOrWhiteSpace(substituteName) || substituteName.IndexOf('\0') >= 0)
            {
                throw new StatusFastPathFallbackException("junction-target-malformed");
            }
            return NormalizeMountPointTarget(substituteName);
        }

        private static void ValidateReparseNameRange(int offset, int length, int pathBufferLength)
        {
            if ((offset & 1) != 0 || (length & 1) != 0 ||
                offset < 0 || length < 0 || offset > pathBufferLength - length)
            {
                throw new StatusFastPathFallbackException("reparse-name-range");
            }
        }

        private static string NormalizeMountPointTarget(string substituteName)
        {
            const string ntPrefix = @"\??\";
            const string extendedPrefix = @"\\?\";
            string target = substituteName;
            if (target.StartsWith(ntPrefix + "UNC\\", StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(@"\\" + target.Substring((ntPrefix + "UNC\\").Length));
            }
            if (target.StartsWith(ntPrefix, StringComparison.OrdinalIgnoreCase))
            {
                string remainder = target.Substring(ntPrefix.Length);
                if (remainder.Length >= 3 && char.IsLetter(remainder[0]) &&
                    remainder[1] == ':' && remainder[2] == '\\')
                {
                    return Path.GetFullPath(remainder);
                }
                if (remainder.StartsWith("Volume{", StringComparison.OrdinalIgnoreCase))
                {
                    return Path.GetFullPath(extendedPrefix + remainder);
                }
                throw new StatusFastPathFallbackException("junction-target-unsupported-nt-path");
            }
            if (target.StartsWith(extendedPrefix + "UNC\\", StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(@"\\" + target.Substring((extendedPrefix + "UNC\\").Length));
            }
            if (target.StartsWith(extendedPrefix, StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(target);
            }
            throw new StatusFastPathFallbackException("junction-target-not-absolute-nt");
        }

        private static ushort ReadUInt16(byte[] bytes, int offset)
        {
            if (bytes == null || offset < 0 || offset > bytes.Length - sizeof(ushort))
            {
                throw new StatusFastPathFallbackException("reparse-payload-truncated");
            }
            return checked((ushort)(bytes[offset] | (bytes[offset + 1] << 8)));
        }

        private static uint ReadUInt32(byte[] bytes, int offset)
        {
            if (bytes == null || offset < 0 || offset > bytes.Length - sizeof(uint))
            {
                throw new StatusFastPathFallbackException("reparse-payload-truncated");
            }
            return (uint)(
                bytes[offset] |
                (bytes[offset + 1] << 8) |
                (bytes[offset + 2] << 16) |
                (bytes[offset + 3] << 24));
        }
    }

    // plan 文本流式提取 treeManifest 并按 ConvertTo-Json -Compress 规则重规范化后直接算 SHA-256，
    // 替代 Get-CodexSafeTreeDeleteManifestSha256 里 60MB 级 manifest 的 ConvertTo-Json 序列化。
    public static class StatusPlanManifestSha256
    {
        private static readonly Regex CanonicalInteger = new Regex(
            "^(0|-?[1-9][0-9]*)$", RegexOptions.Compiled);

        public static string ComputeFromPlanText(string planText)
        {
            try
            {
                return ComputeCore(planText);
            }
            catch (StatusFastPathFallbackException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new StatusFastPathFallbackException("plan-manifest-" + ex.GetType().Name);
            }
        }

        private static string ComputeCore(string planText)
        {
            if (planText == null)
            {
                throw new StatusFastPathFallbackException("null-plan-text");
            }
            byte[] utf8 = Encoding.UTF8.GetBytes(planText);
            Utf8JsonReader reader = new Utf8JsonReader(utf8, new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 128
            });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            {
                throw new StatusFastPathFallbackException("plan-not-object");
            }
            StringBuilder manifestJson = new StringBuilder();
            int found = 0;
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndObject)
                {
                    break;
                }
                if (reader.TokenType != JsonTokenType.PropertyName)
                {
                    throw new StatusFastPathFallbackException("plan-property-expected");
                }
                string name = reader.GetString();
                if (!reader.Read())
                {
                    throw new StatusFastPathFallbackException("plan-truncated");
                }
                if (string.Equals(name, "treeManifest", StringComparison.OrdinalIgnoreCase))
                {
                    // PS 属性访问大小写不敏感：唯一大小写不敏感命中才等价；大小写变体重复回退。
                    found++;
                    if (found > 1)
                    {
                        throw new StatusFastPathFallbackException("treeManifest-duplicated");
                    }
                    WriteCanonicalValue(ref reader, manifestJson, 0);
                }
                else
                {
                    reader.Skip();
                }
            }
            if (found != 1)
            {
                throw new StatusFastPathFallbackException("treeManifest-missing");
            }
            return StatusCanonicalJson.HashUtf8(manifestJson.ToString());
        }

        private static void WriteCanonicalValue(ref Utf8JsonReader reader, StringBuilder builder, int depth)
        {
            depth++;
            if (depth > 100)
            {
                throw new StatusFastPathFallbackException("manifest-depth");
            }
            switch (reader.TokenType)
            {
                case JsonTokenType.StartObject:
                {
                    builder.Append('{');
                    HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
                    bool firstProperty = true;
                    while (reader.Read())
                    {
                        if (reader.TokenType == JsonTokenType.EndObject)
                        {
                            builder.Append('}');
                            return;
                        }
                        if (reader.TokenType != JsonTokenType.PropertyName)
                        {
                            throw new StatusFastPathFallbackException("manifest-property-expected");
                        }
                        string propertyName = reader.GetString();
                        if (!seen.Add(propertyName))
                        {
                            throw new StatusFastPathFallbackException("manifest-duplicate-property");
                        }
                        if (!firstProperty)
                        {
                            builder.Append(',');
                        }
                        firstProperty = false;
                        StatusCanonicalJson.WriteJsonString(builder, propertyName);
                        builder.Append(':');
                        if (!reader.Read())
                        {
                            throw new StatusFastPathFallbackException("manifest-truncated");
                        }
                        WriteCanonicalValue(ref reader, builder, depth);
                    }
                    throw new StatusFastPathFallbackException("manifest-truncated");
                }
                case JsonTokenType.StartArray:
                {
                    builder.Append('[');
                    bool firstElement = true;
                    while (reader.Read())
                    {
                        if (reader.TokenType == JsonTokenType.EndArray)
                        {
                            builder.Append(']');
                            return;
                        }
                        if (!firstElement)
                        {
                            builder.Append(',');
                        }
                        firstElement = false;
                        WriteCanonicalValue(ref reader, builder, depth);
                    }
                    throw new StatusFastPathFallbackException("manifest-truncated");
                }
                case JsonTokenType.String:
                    StatusCanonicalJson.WriteJsonString(builder, reader.GetString());
                    return;
                case JsonTokenType.Number:
                    AppendCanonicalInteger(ref reader, builder);
                    return;
                case JsonTokenType.True:
                    builder.Append("true");
                    return;
                case JsonTokenType.False:
                    builder.Append("false");
                    return;
                case JsonTokenType.Null:
                    builder.Append("null");
                    return;
                default:
                    throw new StatusFastPathFallbackException("manifest-token-" + reader.TokenType);
            }
        }

        private static void AppendCanonicalInteger(ref Utf8JsonReader reader, StringBuilder builder)
        {
            if (reader.HasValueSequence)
            {
                throw new StatusFastPathFallbackException("manifest-number-sequence");
            }
            string raw = Encoding.UTF8.GetString(reader.ValueSpan.ToArray());
            long ignored;
            if (!CanonicalInteger.IsMatch(raw) ||
                !long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out ignored))
            {
                // 非规范整数（小数/指数/超 Int64）的 PS 往返序列化不保证逐字节等价 → 回退。
                throw new StatusFastPathFallbackException("manifest-number-format");
            }
            builder.Append(raw);
        }
    }
}
