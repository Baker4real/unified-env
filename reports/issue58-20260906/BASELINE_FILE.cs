using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
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

    public sealed class StatusScanResult
    {
        public int Index;
        public bool Handled;
        public bool Archived;
        public string FallbackReason;
        // Plan snapshot for PowerShell fallback reuse (avoids a second read of plan.json).
        public string PlanSha256;
        public string PlanText;
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
                        // Approved plans continue through the PowerShell reference path
                        // (namespace handling, transaction semantics, tree materialization).
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
                 entry.RootDeletionPurpose == "retired-project-root") &&
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
            if (manifest.ValueKind != JsonValueKind.Object ||
                !HasExactProperties(manifest, new string[] { "schemaVersion", "rootIdentity", "entries" }))
            {
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
            foreach (JsonElement entryElement in entriesElement.EnumerateArray())
            {
                if (entryElement.ValueKind != JsonValueKind.Object ||
                    !HasExactProperties(entryElement, new string[] { "relativePath", "kind", "sha256", "identity" }))
                {
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
            foreach (char c in segment)
            {
                if (c == '"' || c == '<' || c == '>' || c == '|' || c == '\0' ||
                    (c >= '\x01' && c <= '\x1f'))
                {
                    return segment.IndexOf(c);
                }
            }
            return -1;
        }
    }
}
