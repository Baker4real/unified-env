[CmdletBinding()]
param(
    [switch]$SmokeOnly,
    [switch]$SkipBenchmark,
    [string]$EvidenceHome,
    [int]$SampleCount = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #40 / ParallelismDegreeBenchmark):
# 1. ParallelPurgeCoordinator — constructor-injected allowedRoot + FileSystemCapabilities; Purge() on fixture trees only
# 2. FileSystemCapabilities.RecommendParallel + RecommendedMaxParallelism — one capabilities object per DOP 1/2/4/8/16
# Observable: wall-clock, Process.TotalProcessorTime, per-run JSON, tree files gone after Purge.
# Live writes go to .scratch/safe-tree-delete-tests-parallelismbenchmark-* by default.
# Must not overwrite reports/safe-tree-delete-parallelism-benchmark/ or
# reports/safe-tree-delete-issue40-20260817/raw/ historical evidence.
# -EvidenceHome overrides the live write root.
# Not production Purge. Not ThreadJournal / ParallelPurge source edits.

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$hashCacheSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteHashCache.cs'
$threadJournalSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteThreadJournal.cs'
$parallelPurgeSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteParallelPurge.cs'
$frozenEvidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue40-20260817'
$frozenRawRoot = Join-Path $frozenEvidenceHome 'raw'
$frozenAnalysisPath = Join-Path $frozenEvidenceHome 'analysis.json'
$historicalEvidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-parallelism-benchmark'
$defaultEvidenceHome = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'parallelismbenchmark'
if ([string]::IsNullOrWhiteSpace($EvidenceHome)) {
    $evidenceHome = $defaultEvidenceHome
} else {
    $evidenceHome = [IO.Path]::GetFullPath($EvidenceHome)
}
$workRoot = Join-Path $evidenceHome 'work'
$rawRoot = Join-Path $evidenceHome 'raw'
$forbiddenQuarantine = Join-Path $projectRoot 'reports\.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine'
$forbiddenTx = 'D:\agents\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json'

$degrees = @(1, 2, 4, 8, 16)
$directoryCount = 32
$requiredFreeBytes = 3GB
$peakBytes = 2GB + 64MB

$scenarios = @(
    [ordered]@{
        id = 'small-10k-1kb'
        label = '10k x 1KB'
        fileCount = 10000
        bytesPerFile = 1024
        sizeClass = 'small'
    }
    [ordered]@{
        id = 'medium-5k-10kb'
        label = '5k x 10KB'
        fileCount = 5000
        bytesPerFile = 10240
        sizeClass = 'medium'
    }
    [ordered]@{
        id = 'large-1k-1mb'
        label = '1k x 1MB'
        fileCount = 1000
        bytesPerFile = 1048576
        sizeClass = 'large'
    }
)

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-PathIsUnderRoot {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Root
    )
    $full = [IO.Path]::GetFullPath($LiteralPath)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        ($full.TrimEnd('\') -eq $rootFull.TrimEnd('\'))
}

function Assert-AllowedFixturePath {
    param([Parameter(Mandatory)][string]$LiteralPath)
    Assert-True (Test-PathIsUnderRoot -LiteralPath $LiteralPath -Root $evidenceHome) "夹具路径必须在本次 evidenceHome 下：$LiteralPath"
    Assert-True (-not (Test-PathIsUnderRoot -LiteralPath $LiteralPath -Root $frozenEvidenceHome)) "禁止覆盖 #40 历史证据：$LiteralPath"
    Assert-True (-not (Test-PathIsUnderRoot -LiteralPath $LiteralPath -Root $historicalEvidenceHome)) "禁止覆盖历史 parallelism-benchmark 证据：$LiteralPath"
    $full = [IO.Path]::GetFullPath($LiteralPath)
    Assert-True ($full -ne [IO.Path]::GetFullPath($forbiddenQuarantine)) '禁止碰生产 leftover quarantine'
    Assert-True ($full -ne [IO.Path]::GetFullPath($forbiddenTx)) '禁止碰生产 leftover transaction.json'
}

function New-DopCapabilities {
    param([Parameter(Mandatory)][int]$Degree)
    $caps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $false, $true)
    $caps.RecommendParallel = $true
    $caps.RecommendedMaxParallelism = $Degree
    return $caps
}

function Get-FlushMetricAvailability {
    $resultType = [CodexSafeTreeDelete.ParallelPurgeResult]
    $resultProp = $resultType.GetProperty('JournalPerformance')
    if ($null -ne $resultProp) {
        return [ordered]@{
            available = [bool]$true
            memberKind = 'result-JournalPerformance'
            isStatic = [bool]$false
            verified = [bool]$true
            reason = 'ParallelPurgeResult.JournalPerformance 汇总 ThreadJournalWriter.TotalFlushTimeMs（#41）'
        }
    }
    $type = [CodexSafeTreeDelete.ThreadJournalWriter]
    $flags = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static'
    $prop = $type.GetProperty('TotalFlushTimeMs', $flags)
    $field = $type.GetField('TotalFlushTimeMs', $flags)
    if ($null -ne $prop) {
        return [ordered]@{
            available = [bool]$true
            memberKind = 'property'
            isStatic = [bool]$prop.GetGetMethod($true).IsStatic
            verified = [bool]$prop.GetGetMethod($true).IsStatic
            reason = $(if ($prop.GetGetMethod($true).IsStatic) { 'static TotalFlushTimeMs' } else { 'instance TotalFlushTimeMs; coordinator 未暴露汇总值，本票不改 ThreadJournal/coordinator' })
        }
    }
    if ($null -ne $field) {
        return [ordered]@{
            available = [bool]$true
            memberKind = 'field'
            isStatic = [bool]$field.IsStatic
            verified = [bool]$field.IsStatic
            reason = $(if ($field.IsStatic) { 'static TotalFlushTimeMs' } else { 'instance TotalFlushTimeMs; coordinator 未暴露汇总值，本票不改 ThreadJournal/coordinator' })
        }
    }
    return [ordered]@{
        available = [bool]$false
        memberKind = $null
        isStatic = [bool]$false
        verified = [bool]$false
        reason = 'ThreadJournalWriter 无 TotalFlushTimeMs；flush% 标未验证'
    }
}

function Read-StaticFlushMs {
    param($Availability)
    if (-not $Availability.verified) { return $null }
    if ($Availability.memberKind -eq 'result-JournalPerformance') { return $null }
    $type = [CodexSafeTreeDelete.ThreadJournalWriter]
    if ($Availability.memberKind -eq 'property') {
        $prop = $type.GetProperty('TotalFlushTimeMs')
        if ($null -eq $prop) { return $null }
        return [int64]$prop.GetValue($null)
    }
    if ($Availability.memberKind -eq 'field') {
        $field = $type.GetField('TotalFlushTimeMs')
        if ($null -eq $field) { return $null }
        return [int64]$field.GetValue($null)
    }
    return $null
}

function Remove-EmptyDirectories {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
        return
    }
    $dirs = @(
        Get-ChildItem -LiteralPath $LiteralPath -Recurse -Directory -Force |
            Sort-Object { $_.FullName.Length } -Descending
    )
    foreach ($dir in $dirs) {
        if (@(Get-ChildItem -LiteralPath $dir.FullName -Force).Count -eq 0) {
            [IO.Directory]::Delete($dir.FullName)
        }
    }
    if (@(Get-ChildItem -LiteralPath $LiteralPath -Force).Count -eq 0) {
        [IO.Directory]::Delete($LiteralPath)
    }
}

function Remove-FixtureFilesThenEmptyDirs {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
        return
    }
    Assert-AllowedFixturePath -LiteralPath $LiteralPath
    $files = [CodexSafeTreeDeleteIssue40.FixtureTrees]::DeleteFiles($LiteralPath)
    Remove-EmptyDirectories -LiteralPath $LiteralPath
    return $files
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)]$Value
    )
    Assert-AllowedFixturePath -LiteralPath $LiteralPath
    $parent = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
    [IO.File]::WriteAllText(
        $LiteralPath,
        ($Value | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
}

function Get-RawJsonPath {
    param(
        [Parameter(Mandatory)][string]$ScenarioId,
        [Parameter(Mandatory)][int]$Degree,
        [int]$SampleIndex = 0
    )
    $name = if ($SampleIndex -gt 0) {
        '{0}-dop{1:D2}-s{2}.json' -f $ScenarioId, $Degree, $SampleIndex
    } else {
        '{0}-dop{1:D2}.json' -f $ScenarioId, $Degree
    }
    $path = Join-Path $rawRoot $name
    Assert-True (-not (Test-PathIsUnderRoot -LiteralPath $path -Root $frozenRawRoot)) (
        "live raw 不得指向 #40 历史 raw: $path"
    )
    Assert-True (-not (Test-PathIsUnderRoot -LiteralPath $path -Root $historicalEvidenceHome)) (
        "live raw 不得指向历史 parallelism-benchmark: $path"
    )
    return $path
}

$script:frozenEvidenceHashes = [ordered]@{}

function Snapshot-ProtectedEvidenceFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-True (Test-Path -LiteralPath $Root -PathType Container) "$Label 目录必须存在且不得作为本测试写入目标"
    $files = @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            Where-Object { $_.Extension -in @('.json', '.md') -and $_.DirectoryName -notmatch '\\work(\\|$)' }
    )
    foreach ($file in $files) {
        $script:frozenEvidenceHashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}

function Snapshot-FrozenIssue40Evidence {
    $script:frozenEvidenceHashes.Clear()
    Snapshot-ProtectedEvidenceFiles -Root $frozenEvidenceHome -Label '#40 历史证据'
    Snapshot-ProtectedEvidenceFiles -Root $historicalEvidenceHome -Label '历史 parallelism-benchmark'
    Assert-True ($script:frozenEvidenceHashes.Count -gt 0) '必须快照到受保护的历史证据文件'
}

function Assert-FrozenIssue40EvidenceUnchanged {
    foreach ($path in @($script:frozenEvidenceHashes.Keys)) {
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "禁止删除历史证据: $path"
        $after = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Assert-True ($after -ceq $script:frozenEvidenceHashes[$path]) "禁止覆盖历史证据: $path"
    }
}

$runtimeEdition = [string]$PSVersionTable.PSEdition
$runtimeMajor = [int]$PSVersionTable.PSVersion.Major
$runtimeMinor = [int]$PSVersionTable.PSVersion.Minor
Assert-True ($runtimeEdition -ceq 'Core') "本测试要求 PowerShell Core，实际为 $runtimeEdition"
Assert-True (
    $runtimeMajor -gt 7 -or
    ($runtimeMajor -eq 7 -and $runtimeMinor -ge 6)
) "本测试要求 PowerShell 7.6+，实际为 $($PSVersionTable.PSVersion)"

Assert-True (Test-Path -LiteralPath $identitySourcePath -PathType Leaf) 'CodexSafeTreeDeleteFileIdentity.cs 必须存在'
Assert-True (Test-Path -LiteralPath $hashCacheSourcePath -PathType Leaf) 'CodexSafeTreeDeleteHashCache.cs 必须存在'
Assert-True (Test-Path -LiteralPath $threadJournalSourcePath -PathType Leaf) 'CodexSafeTreeDeleteThreadJournal.cs 必须存在'
Assert-True (Test-Path -LiteralPath $parallelPurgeSourcePath -PathType Leaf) 'ParallelPurgeCoordinator 源必须存在（#39）'

$evidenceHomeFull = [IO.Path]::GetFullPath($evidenceHome).TrimEnd('\')
$historicalFull = [IO.Path]::GetFullPath($historicalEvidenceHome).TrimEnd('\')
$frozenFull = [IO.Path]::GetFullPath($frozenEvidenceHome).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($EvidenceHome)) {
    $scratchPrefix = [IO.Path]::GetFullPath((Join-Path $projectRoot '.scratch')).TrimEnd('\') + '\safe-tree-delete-tests-'
    Assert-True ($evidenceHomeFull.StartsWith($scratchPrefix, [StringComparison]::OrdinalIgnoreCase)) (
        "默认 live evidenceHome 必须位于项目 .scratch/safe-tree-delete-tests-* 下：$evidenceHomeFull")
}
Assert-True ($evidenceHomeFull -ne $historicalFull) 'evidenceHome 不得指向历史 parallelism-benchmark 目录'
Assert-True ($evidenceHomeFull -ne $frozenFull) 'evidenceHome 不得指向 #40 历史证据目录'
Assert-True (-not (Test-PathIsUnderRoot -LiteralPath $evidenceHome -Root $frozenEvidenceHome)) (
    '本测试运行根不得落在 #40 历史证据目录内'
)
Assert-True (-not (Test-PathIsUnderRoot -LiteralPath $evidenceHome -Root $historicalEvidenceHome)) (
    '本测试运行根不得落在历史 parallelism-benchmark 目录内'
)
Assert-True (-not (Test-PathIsUnderRoot -LiteralPath $rawRoot -Root $frozenRawRoot)) (
    '本测试 raw 根不得落在 #40 历史 raw 内'
)
if (-not $SmokeOnly -and -not $SkipBenchmark) {
    Assert-True ($SampleCount -ge 2) "每组至少 2 次取样，实际 SampleCount=$SampleCount"
}
Snapshot-FrozenIssue40Evidence
[void][IO.Directory]::CreateDirectory($evidenceHome)
[void][IO.Directory]::CreateDirectory($workRoot)
[void][IO.Directory]::CreateDirectory($rawRoot)
Assert-AllowedFixturePath -LiteralPath $evidenceHome
Assert-AllowedFixturePath -LiteralPath $rawRoot

if (-not ('CodexSafeTreeDelete.ParallelPurgeCoordinator' -as [type])) {
    Add-Type -Path $identitySourcePath, $hashCacheSourcePath, $threadJournalSourcePath, $parallelPurgeSourcePath -ErrorAction Stop
}
if (-not ('CodexSafeTreeDeleteIssue40.FixtureTrees' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

namespace CodexSafeTreeDeleteIssue40
{
    public static class FixtureTrees
    {
        public static int CreateTree(string root, int fileCount, int bytesPerFile, int directoryCount)
        {
            if (fileCount < 1) throw new ArgumentOutOfRangeException("fileCount");
            if (bytesPerFile < 1) throw new ArgumentOutOfRangeException("bytesPerFile");
            if (directoryCount < 1) throw new ArgumentOutOfRangeException("directoryCount");

            byte[] payload = new byte[bytesPerFile];
            for (int i = 0; i < payload.Length; i++)
            {
                payload[i] = (byte)((i * 31 + 7) & 0xFF);
            }

            int created = 0;
            for (int i = 0; i < fileCount; i++)
            {
                int dirIndex = i % directoryCount;
                string dirPath = Path.Combine(root, "d" + dirIndex.ToString("D2"));
                Directory.CreateDirectory(dirPath);
                string filePath = Path.Combine(dirPath, "f" + i.ToString("D5") + ".bin");
                File.WriteAllBytes(filePath, payload);
                created++;
            }
            return created;
        }

        public static int CopyTree(string sourceRoot, string destRoot)
        {
            int copied = 0;
            foreach (string file in Directory.EnumerateFiles(sourceRoot, "*", SearchOption.AllDirectories))
            {
                string rel = file.Substring(sourceRoot.Length).TrimStart(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar);
                string dest = Path.Combine(destRoot, rel);
                string destDir = Path.GetDirectoryName(dest);
                Directory.CreateDirectory(destDir);
                File.Copy(file, dest, false);
                copied++;
            }
            return copied;
        }

        public static int DeleteFiles(string root)
        {
            if (!Directory.Exists(root))
            {
                return 0;
            }

            int deleted = 0;
            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                File.Delete(file);
                deleted++;
            }
            return deleted;
        }

        public static int CountFiles(string root)
        {
            if (!Directory.Exists(root))
            {
                return 0;
            }

            int count = 0;
            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                count++;
            }
            return count;
        }
    }
}
'@ -ErrorAction Stop
}

$coordinatorType = 'CodexSafeTreeDelete.ParallelPurgeCoordinator' -as [type]
Assert-True ($null -ne $coordinatorType) 'ParallelPurgeCoordinator 必须可编译加载'

foreach ($degree in $degrees) {
    $caps = New-DopCapabilities -Degree $degree
    Assert-True ($caps.RecommendParallel -eq $true) "DOP $degree capabilities 必须 RecommendParallel=true"
    Assert-True ($caps.RecommendedMaxParallelism -eq $degree) "必须能把 RecommendedMaxParallelism 设为 $degree"
    $resolved = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::ResolveMaxDegreeOfParallelism($caps)
    Assert-True ($resolved -eq $degree) "ResolveMaxDegreeOfParallelism 必须尊重注入的 $degree"
}

$drive = [IO.DriveInfo]::new('D:')
$freeBytes = [int64]$drive.AvailableFreeSpace
$processorCount = [Environment]::ProcessorCount
$flushMeta = Get-FlushMetricAvailability

$preflight = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue40-preflight'
    measuredAtUtc = [DateTime]::UtcNow.ToString('o')
    processorCount = $processorCount
    driveFormat = [string]$drive.DriveFormat
    dFreeBytes = $freeBytes
    requiredFreeBytes = [int64]$requiredFreeBytes
    peakBytesEstimate = [int64]$peakBytes
    directoryCount = $directoryCount
    degrees = $degrees
    sampleCount = [int]$SampleCount
    flushMetric = $flushMeta
    evidenceHome = $evidenceHome
    historicalEvidenceHome = $historicalEvidenceHome
    frozenEvidenceHome = $frozenEvidenceHome
    frozenRawRoot = $frozenRawRoot
}
Write-JsonFile -LiteralPath (Join-Path $evidenceHome 'preflight.json') -Value $preflight

Assert-True ($freeBytes -ge $requiredFreeBytes) ("D: 可用空间不足，BLOCKED。需要 {0} bytes，实际 {1}" -f $requiredFreeBytes, $freeBytes)

$smokeTree = Join-Path $workRoot 'smoke-tree'
$smokeJournal = Join-Path $workRoot 'smoke-journal'
Remove-FixtureFilesThenEmptyDirs -LiteralPath $smokeTree | Out-Null
Remove-FixtureFilesThenEmptyDirs -LiteralPath $smokeJournal | Out-Null
[void][IO.Directory]::CreateDirectory($smokeJournal)
$smokeCreated = [CodexSafeTreeDeleteIssue40.FixtureTrees]::CreateTree($smokeTree, 32, 64, 32)
Assert-True ($smokeCreated -eq 32) "smoke 树必须写出 32 个文件，实际为 $smokeCreated"
$smokeCaps = New-DopCapabilities -Degree 4
$smokeCoordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
    $smokeTree,
    $smokeJournal,
    $evidenceHome,
    $smokeCaps)
try {
    Assert-True ($smokeCoordinator.MaxDegreeOfParallelism -eq 4) '注入 DOP=4 时实例 MaxDegreeOfParallelism 必须是 4'
    $smokeResult = $smokeCoordinator.Purge()
} finally {
    $smokeCoordinator.Dispose()
}
Assert-True ($smokeResult.DeletedCount -eq 32) 'smoke Purge 必须删掉 32 个文件'
Assert-True ($smokeResult.FailedCount -eq 0) 'smoke Purge 不得失败'
Assert-True (([CodexSafeTreeDeleteIssue40.FixtureTrees]::CountFiles($smokeTree)) -eq 0) 'smoke 树不得剩文件'
Remove-FixtureFilesThenEmptyDirs -LiteralPath $smokeTree | Out-Null

$smokeRecord = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue40-smoke'
    fileCount = [int]$smokeResult.FileCount
    deletedCount = [int]$smokeResult.DeletedCount
    failedCount = [int]$smokeResult.FailedCount
    elapsedMs = [int64]$smokeResult.ElapsedMs
    maxDegreeOfParallelism = 4
}
Write-JsonFile -LiteralPath (Join-Path $evidenceHome 'smoke.json') -Value $smokeRecord

if ($SmokeOnly) {
    Assert-FrozenIssue40EvidenceUnchanged
    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteParallelismBenchmark'
        issue = 40
        mode = 'SmokeOnly'
        processorCount = $processorCount
        dFreeBytes = $freeBytes
        flushVerified = [bool]$flushMeta.verified
        wroteToFrozenIssue40Raw = $false
    }
    return
}

function Invoke-ScenarioDegree {
    param(
        [Parameter(Mandatory)]$Scenario,
        [Parameter(Mandatory)][int]$Degree,
        [Parameter(Mandatory)][int]$SampleIndex,
        [Parameter(Mandatory)][string]$TemplateRoot,
        $FlushAvailability
    )

    $runTree = Join-Path $workRoot ('{0}-dop{1:D2}-s{2}-tree' -f $Scenario.id, $Degree, $SampleIndex)
    $runJournal = Join-Path $workRoot ('{0}-dop{1:D2}-s{2}-journal' -f $Scenario.id, $Degree, $SampleIndex)
    Remove-FixtureFilesThenEmptyDirs -LiteralPath $runTree | Out-Null
    Remove-FixtureFilesThenEmptyDirs -LiteralPath $runJournal | Out-Null
    [void][IO.Directory]::CreateDirectory($runJournal)
    Assert-AllowedFixturePath -LiteralPath $runTree
    Assert-AllowedFixturePath -LiteralPath $runJournal

    $copied = [CodexSafeTreeDeleteIssue40.FixtureTrees]::CopyTree($TemplateRoot, $runTree)
    Assert-True ($copied -eq [int]$Scenario.fileCount) ("{0} DOP{1} 复制文件数必须是 {2}，实际为 {3}" -f $Scenario.id, $Degree, $Scenario.fileCount, $copied)

    $caps = New-DopCapabilities -Degree $Degree
    $flushBefore = Read-StaticFlushMs -Availability $FlushAvailability
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $cpuBefore = $process.TotalProcessorTime
    $wall = [Diagnostics.Stopwatch]::StartNew()
    $coordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
        $runTree,
        $runJournal,
        $evidenceHome,
        $caps)
    try {
        Assert-True ($coordinator.MaxDegreeOfParallelism -eq $Degree) ("coordinator DOP 必须是 {0}" -f $Degree)
        $result = $coordinator.Purge()
    } finally {
        $coordinator.Dispose()
    }
    $wall.Stop()
    $process.Refresh()
    $cpuAfter = $process.TotalProcessorTime
    $flushAfter = Read-StaticFlushMs -Availability $FlushAvailability

    $wallMs = [int64]$wall.ElapsedMilliseconds
    $cpuMs = [int64]($cpuAfter - $cpuBefore).TotalMilliseconds
    $cpuRatio = if ($wallMs -gt 0) { [math]::Round($cpuMs / $wallMs, 4) } else { $null }
    $flushMs = $null
    $flushPercent = $null
    $flushStatus = 'unverified'
    if ($FlushAvailability.memberKind -eq 'result-JournalPerformance' -and $null -ne $result.JournalPerformance) {
        $flushMs = [int64]$result.JournalPerformance.TotalFlushTimeMs
        $flushPercent = [math]::Round([double]$result.JournalPerformance.OverheadPercent, 3)
        $flushStatus = 'measured'
    } elseif ($FlushAvailability.verified -and $null -ne $flushBefore -and $null -ne $flushAfter) {
        $flushMs = [int64]($flushAfter - $flushBefore)
        if ($flushMs -lt 0) { $flushMs = [int64]0 }
        $flushPercent = if ($wallMs -gt 0) { [math]::Round(100.0 * $flushMs / $wallMs, 3) } else { $null }
        $flushStatus = 'measured'
    }

    $remaining = [CodexSafeTreeDeleteIssue40.FixtureTrees]::CountFiles($runTree)
    Assert-True ($result.FileCount -eq [int]$Scenario.fileCount) ("{0} DOP{1} fileCount 必须是 {2}" -f $Scenario.id, $Degree, $Scenario.fileCount)
    Assert-True ($result.DeletedCount -eq [int]$Scenario.fileCount) ("{0} DOP{1} 必须全部删除" -f $Scenario.id, $Degree)
    Assert-True ($result.FailedCount -eq 0) ("{0} DOP{1} 不得有失败" -f $Scenario.id, $Degree)
    Assert-True ($remaining -eq 0) ("{0} DOP{1} 树不得剩余文件" -f $Scenario.id, $Degree)

    $record = [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue40-raw'
        scenarioId = [string]$Scenario.id
        label = [string]$Scenario.label
        sizeClass = [string]$Scenario.sizeClass
        fileCount = [int]$Scenario.fileCount
        bytesPerFile = [int]$Scenario.bytesPerFile
        directoryCount = $directoryCount
        degree = $Degree
        sampleIndex = [int]$SampleIndex
        wallClockMs = $wallMs
        coordinatorElapsedMs = [int64]$result.ElapsedMs
        totalProcessorTimeMs = $cpuMs
        cpuUtilizationRatio = $cpuRatio
        processorCount = $processorCount
        journalFileCount = [int]$result.JournalFileCount
        deletedCount = [int]$result.DeletedCount
        failedCount = [int]$result.FailedCount
        flushTimeMs = $flushMs
        flushOverheadPercent = $flushPercent
        flushCount = $(if ($flushStatus -eq 'measured' -and $null -ne $result.JournalPerformance) { [int]$result.JournalPerformance.FlushCount } else { $null })
        flushStatus = $flushStatus
        flushReason = [string]$FlushAvailability.reason
        measuredAtUtc = [DateTime]::UtcNow.ToString('o')
        targetRoot = $runTree
        journalRoot = $runJournal
        method = 'ParallelPurgeCoordinator File.Delete on issue40 fixture tree only; capabilities RecommendedMaxParallelism injected; not production Purge; every sample recorded'
    }
    Write-JsonFile -LiteralPath (Get-RawJsonPath -ScenarioId $Scenario.id -Degree $Degree -SampleIndex $SampleIndex) -Value $record
    Remove-EmptyDirectories -LiteralPath $runTree
    return $record
}

function New-AggregateRecord {
    param(
        [Parameter(Mandatory)]$Scenario,
        [Parameter(Mandatory)][int]$Degree,
        [Parameter(Mandatory)]$Samples
    )
    $n = @($Samples).Count
    Assert-True ($n -ge 1) ("{0} DOP{1} 必须至少有 1 条取样" -f $Scenario.id, $Degree)
    $wallValues = @($Samples | ForEach-Object { [int64]$_.wallClockMs })
    $cpuValues = @($Samples | ForEach-Object { [int64]$_.totalProcessorTimeMs })
    $cpuRatioValues = @($Samples | ForEach-Object { [double]$_.cpuUtilizationRatio })
    $flushValues = @($Samples | Where-Object { $null -ne $_.flushTimeMs } | ForEach-Object { [int64]$_.flushTimeMs })
    $flushPctValues = @($Samples | Where-Object { $null -ne $_.flushOverheadPercent } | ForEach-Object { [double]$_.flushOverheadPercent })
    $coordValues = @($Samples | ForEach-Object { [int64]$_.coordinatorElapsedMs })
    $mean = {
        param([double[]]$Values)
        if ($Values.Count -eq 0) { return $null }
        return [math]::Round((($Values | Measure-Object -Average).Average), 3)
    }
    $wallMean = [int64][math]::Round((& $mean $wallValues), 0)
    $flushStatus = [string]$Samples[0].flushStatus
    $flushMs = $null
    $flushPct = $null
    if ($flushValues.Count -eq $n) {
        $flushMs = [int64][math]::Round((& $mean $flushValues), 0)
        $flushPct = [math]::Round((& $mean $flushPctValues), 3)
    }
    return [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue40-raw-aggregate'
        scenarioId = [string]$Scenario.id
        label = [string]$Scenario.label
        sizeClass = [string]$Scenario.sizeClass
        fileCount = [int]$Scenario.fileCount
        bytesPerFile = [int]$Scenario.bytesPerFile
        directoryCount = $directoryCount
        degree = $Degree
        sampleCount = [int]$n
        sampleWallClockMs = @($wallValues)
        wallClockMs = $wallMean
        coordinatorElapsedMs = [int64][math]::Round((& $mean $coordValues), 0)
        totalProcessorTimeMs = [int64][math]::Round((& $mean $cpuValues), 0)
        cpuUtilizationRatio = [math]::Round((& $mean $cpuRatioValues), 4)
        processorCount = $processorCount
        journalFileCount = [int]$Samples[0].journalFileCount
        deletedCount = [int]$Samples[0].deletedCount
        failedCount = [int]$Samples[0].failedCount
        flushTimeMs = $flushMs
        flushOverheadPercent = $flushPct
        flushCount = $Samples[0].flushCount
        flushStatus = $flushStatus
        flushReason = [string]$Samples[0].flushReason
        aggregation = 'arithmetic-mean-of-all-recorded-samples'
        measuredAtUtc = [DateTime]::UtcNow.ToString('o')
        method = 'aggregate of recorded ParallelPurgeCoordinator samples; no discarded runs'
    }
}

function Get-ScenarioAnalysis {
    param([Parameter(Mandatory)]$Rows)
    $sorted = @($Rows | Sort-Object { [int]$_.degree })
    $dop1 = [int64]($sorted | Where-Object { [int]$_.degree -eq 1 } | Select-Object -First 1).wallClockMs
    $best = $sorted | Sort-Object { [int64]$_.wallClockMs }, { [int]$_.degree } | Select-Object -First 1
    $bestMs = [int64]$best.wallClockMs
    $threshold = [int64][math]::Ceiling($bestMs * 1.10)
    $knee = @($sorted | Where-Object { [int64]$_.wallClockMs -le $threshold } | Select-Object -First 1)
    $points = foreach ($row in $sorted) {
        $wall = [int64]$row.wallClockMs
        $speedup = if ($wall -gt 0) { [math]::Round($dop1 / $wall, 3) } else { $null }
        $efficiency = if ($null -ne $speedup) { [math]::Round($speedup / [int]$row.degree, 3) } else { $null }
        [ordered]@{
            degree = [int]$row.degree
            wallClockMs = $wall
            speedupVsDop1 = $speedup
            parallelEfficiency = $efficiency
            cpuUtilizationRatio = $row.cpuUtilizationRatio
            flushStatus = [string]$row.flushStatus
            flushOverheadPercent = $row.flushOverheadPercent
        }
    }
    $diminishing = $null
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $prev = [int64]$sorted[$i - 1].wallClockMs
        $cur = [int64]$sorted[$i].wallClockMs
        if ($prev -le 0) { continue }
        $gain = ($prev - $cur) / $prev
        if ($gain -lt 0.10) {
            $diminishing = [ordered]@{
                afterDegree = [int]$sorted[$i - 1].degree
                nextDegree = [int]$sorted[$i].degree
                incrementalGain = [math]::Round($gain, 4)
                rule = 'first step whose wall-clock improvement vs previous DOP is < 10%'
            }
            break
        }
    }
    $peakEff = $null
    foreach ($point in $points) {
        if ($null -eq $peakEff -or [double]$point.parallelEfficiency -gt [double]$peakEff.parallelEfficiency) {
            $peakEff = $point
        } elseif ([double]$point.parallelEfficiency -eq [double]$peakEff.parallelEfficiency -and [int]$point.degree -lt [int]$peakEff.degree) {
            $peakEff = $point
        }
    }
    $efficiencyDrop = $null
    foreach ($point in $points) {
        if ([int]$point.degree -le [int]$peakEff.degree) { continue }
        if ([double]$point.parallelEfficiency -lt 0.85) {
            $efficiencyDrop = [ordered]@{
                afterDegree = [int]$peakEff.degree
                nextDegree = [int]$point.degree
                nextEfficiency = [double]$point.parallelEfficiency
                rule = 'first DOP after peak efficiency whose parallelEfficiency < 0.85'
            }
            break
        }
    }
    return [ordered]@{
        scenarioId = [string]$sorted[0].scenarioId
        label = [string]$sorted[0].label
        sizeClass = [string]$sorted[0].sizeClass
        dop1WallClockMs = $dop1
        bestDegree = [int]$best.degree
        bestWallClockMs = $bestMs
        conservativeKneeDegree = [int]$knee.degree
        conservativeKneeRule = 'smallest DOP whose wall-clock is within 10% of the best measured wall-clock'
        peakEfficiencyDegree = [int]$peakEff.degree
        peakParallelEfficiency = [double]$peakEff.parallelEfficiency
        diminishingReturns = $diminishing
        efficiencyDrop = $efficiencyDrop
        points = @($points)
    }
}

$allRows = @()
$allSamples = @()
if (-not $SkipBenchmark) {
    foreach ($scenario in $scenarios) {
        $templateRoot = Join-Path $workRoot ('{0}-template' -f $scenario.id)
        Remove-FixtureFilesThenEmptyDirs -LiteralPath $templateRoot | Out-Null
        $created = [CodexSafeTreeDeleteIssue40.FixtureTrees]::CreateTree(
            $templateRoot,
            [int]$scenario.fileCount,
            [int]$scenario.bytesPerFile,
            $directoryCount)
        Assert-True ($created -eq [int]$scenario.fileCount) ("{0} 模板必须写出 {1} 个文件，实际为 {2}" -f $scenario.id, $scenario.fileCount, $created)

        foreach ($degree in $degrees) {
            $samples = @()
            for ($sampleIndex = 1; $sampleIndex -le $SampleCount; $sampleIndex++) {
                $sample = Invoke-ScenarioDegree `
                    -Scenario $scenario `
                    -Degree $degree `
                    -SampleIndex $sampleIndex `
                    -TemplateRoot $templateRoot `
                    -FlushAvailability $flushMeta
                $samples += $sample
                $allSamples += $sample
            }
            Assert-True ($samples.Count -eq $SampleCount) ("{0} DOP{1} 必须记录 {2} 次取样" -f $scenario.id, $degree, $SampleCount)
            $row = New-AggregateRecord -Scenario $scenario -Degree $degree -Samples $samples
            Write-JsonFile -LiteralPath (Get-RawJsonPath -ScenarioId $scenario.id -Degree $degree) -Value $row
            $allRows += $row
        }

        Remove-FixtureFilesThenEmptyDirs -LiteralPath $templateRoot | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $templateRoot)) ("测完必须删掉 {0} 模板树" -f $scenario.id)
    }
} else {
    foreach ($scenario in $scenarios) {
        foreach ($degree in $degrees) {
            $path = Get-RawJsonPath -ScenarioId $scenario.id -Degree $degree
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "SkipBenchmark 需要已有 $path"
            $allRows += (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json)
            $sampleIndex = 1
            while ($true) {
                $samplePath = Get-RawJsonPath -ScenarioId $scenario.id -Degree $degree -SampleIndex $sampleIndex
                if (-not (Test-Path -LiteralPath $samplePath -PathType Leaf)) { break }
                $allSamples += (Get-Content -LiteralPath $samplePath -Raw -Encoding utf8 | ConvertFrom-Json)
                $sampleIndex++
            }
        }
    }
}

$analyses = @()
foreach ($scenario in $scenarios) {
    $rows = @($allRows | Where-Object { $_.scenarioId -eq $scenario.id })
    Assert-True ($rows.Count -eq $degrees.Count) ("{0} 必须有 {1} 条 DOP 记录" -f $scenario.id, $degrees.Count)
    $analyses += Get-ScenarioAnalysis -Rows $rows
}

$smallAnalysis = $analyses | Where-Object { $_.sizeClass -eq 'small' } | Select-Object -First 1
$mediumAnalysis = $analyses | Where-Object { $_.sizeClass -eq 'medium' } | Select-Object -First 1
$largeAnalysis = $analyses | Where-Object { $_.sizeClass -eq 'large' } | Select-Object -First 1
$smallKnee = [int]$smallAnalysis.conservativeKneeDegree
$mediumKnee = [int]$mediumAnalysis.conservativeKneeDegree
$largeKnee = [int]$largeAnalysis.conservativeKneeDegree
$smallPeak = [int]$smallAnalysis.peakEfficiencyDegree
$mediumPeak = [int]$mediumAnalysis.peakEfficiencyDegree
$largePeak = [int]$largeAnalysis.peakEfficiencyDegree

$ticketSuggestion = [ordered]@{
    small = '4'
    medium = '2-4'
    large = '1-2'
    typicalSmallFormula = 'min(4, ProcessorCount-2)'
}
$formulaValue = [math]::Min(4, [math]::Max(1, $processorCount - 2))
$dataSupportsTypicalFour = ($smallPeak -eq 4)
$dataSupportsTicket = (
    $smallPeak -eq 4 -and
    $mediumPeak -ge 2 -and $mediumPeak -le 4 -and
    $largePeak -ge 1 -and $largePeak -le 2
)
$wallClockPlateaued = ($smallKnee -lt 16 -or $mediumKnee -lt 16 -or $largeKnee -lt 16)
$optimizeDefault = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $false, $true)
$fromDetectionValue = [int]$optimizeDefault.RecommendedMaxParallelism
$fromDetectionMatchesPeaks = (
    $fromDetectionValue -eq $smallPeak -and
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendOptimizeMaxParallelism() -eq $smallPeak -and
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendMaxParallelismForTypicalFileBytes(1024) -eq $smallPeak -and
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendMaxParallelismForTypicalFileBytes(10240) -eq $mediumPeak -and
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendMaxParallelismForTypicalFileBytes(1048576) -eq $largePeak
)
$ticketMismatchNote = if ($dataSupportsTicket) {
    '本机峰值效率与票面建议一致'
} else {
    '与票面假设不符 + 数据支撑：票面小文件 4 / min(4, ProcessorCount-2)，本机三场景峰值效率以实测 DOP 为准'
}

$recommendation = [ordered]@{
    decisionRule = 'peak parallel efficiency (speedup / DOP) per size class; FromDetection unknown-size default = typical small-file peak; wall-clock-within-10% is reported separately'
    typicalSmallFilePeakEfficiency = $smallPeak
    mediumPeakEfficiency = $mediumPeak
    largePeakEfficiency = $largePeak
    typicalSmallFileKnee = $smallKnee
    mediumKnee = $mediumKnee
    largeKnee = $largeKnee
    hostFormulaMin4ProcessorMinus2 = $formulaValue
    fromDetectionValue = $fromDetectionValue
    fromDetectionReason = ('本机小/中/大峰值效率 DOP={0}/{1}/{2}。FromDetection 未知规模时取典型小文件峰值 {0}，不取墙钟最快 {3}，也不再钉票面 4。{4}' -f @(
        $smallPeak
        $mediumPeak
        $largePeak
        [int]$smallAnalysis.bestDegree
        $ticketMismatchNote
    ))
    dataSupportsTypicalFour = [bool]$dataSupportsTypicalFour
    dataSupportsTicketSuggestion = [bool]$dataSupportsTicket
    fromDetectionMatchesMeasuredPeaks = [bool]$fromDetectionMatchesPeaks
    wallClockPlateauedInRange = [bool]$wallClockPlateaued
    ticketSuggestion = $ticketSuggestion
    sampleCount = [int]$SampleCount
    flushVerified = [bool]$flushMeta.verified
    flushNote = 'JournalPerformance.TotalFlushTimeMs 是线程 flush 时间求和，DOP>1 时可超过墙钟 100%'
}

$analysisDoc = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue40-analysis'
    measuredAtUtc = [DateTime]::UtcNow.ToString('o')
    processorCount = $processorCount
    flushMetric = $flushMeta
    scenarios = $analyses
    recommendation = $recommendation
}
Write-JsonFile -LiteralPath (Join-Path $evidenceHome 'analysis.json') -Value $analysisDoc

function Format-MermaidLine {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)]$Points
    )
    $xs = @($Points | ForEach-Object { [string]$_.degree })
    $ys = @($Points | ForEach-Object { [string]$_.wallClockMs })
    $maxY = [int64]1
    foreach ($point in @($Points)) {
        $wall = [int64]$point.wallClockMs
        if ($wall -gt $maxY) { $maxY = $wall }
    }
    $axisMax = [int64]([math]::Max(1, [math]::Ceiling($maxY * 1.15)))
    $nl = "`n"
    return @(
        '```mermaid'
        'xychart-beta'
        ('    title "{0}"' -f $Title)
        ('    x-axis [{0}]' -f ($xs -join ', '))
        ('    y-axis "ms" 0 --> {0}' -f $axisMax)
        ('    line [{0}]' -f ($ys -join ', '))
        '```'
    ) -join $nl
}

function Format-ScenarioTable {
    param([Parameter(Mandatory)]$Analysis)
    $lines = @(
        '| DOP | wall-clock ms | speedup vs 1 | efficiency | CPU ratio | flush% |'
        '| ---: | ---: | ---: | ---: | ---: | ---: |'
    )
    foreach ($p in $Analysis.points) {
        $flush = if ($p.flushStatus -eq 'measured') { [string]$p.flushOverheadPercent } else { '未验证' }
        $lines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f @(
            $p.degree
            $p.wallClockMs
            $p.speedupVsDop1
            $p.parallelEfficiency
            $p.cpuUtilizationRatio
            $flush
        ))
    }
    return ($lines -join "`n")
}

$reportLines = @(
    '# Safe-tree-delete #40 并行度基准'
    ''
    '夹具树只打 `ParallelPurgeCoordinator`，新跑默认写入 `.scratch/safe-tree-delete-tests-*/`。不得覆盖 `reports/safe-tree-delete-parallelism-benchmark/` 与 `reports/safe-tree-delete-issue40-20260817/raw/` 历史证据。不是生产 Purge。不是 GitHub 关单授权。'
    ''
    ('- 测量时间（UTC）：{0}' -f $analysisDoc.measuredAtUtc)
    ('- ProcessorCount：{0}' -f $processorCount)
    ('- D: 预检可用：{0} bytes' -f $freeBytes)
    ('- 顶级目录数：{0}（目录级并行，供 DOP 16 饱和）' -f $directoryCount)
    ('- 每组取样次数：{0}（全部落盘，算术平均后画曲线）' -f $SampleCount)
    ('- flush 指标：{0}' -f $flushMeta.reason)
    ''
    '## 收益递减与推荐'
    ''
    '决策规则：生产推荐取各场景并行效率（speedup/DOP）峰值。墙钟 10% 膝点与 <10% 增量台阶一并报告。未知规模的 `FromDetection` 取典型小文件峰值，不取无上界墙钟最小，也不再钉票面 4。'
    ''
    ('- 小文件峰值效率 DOP：{0}；墙钟最佳 / 10%膝点：{1} / {2}' -f $smallPeak, $smallAnalysis.bestDegree, $smallKnee)
    ('- 中等峰值效率 DOP：{0}；墙钟最佳 / 10%膝点：{1} / {2}' -f $mediumPeak, $mediumAnalysis.bestDegree, $mediumKnee)
    ('- 大文件峰值效率 DOP：{0}；墙钟最佳 / 10%膝点：{1} / {2}' -f $largePeak, $largeAnalysis.bestDegree, $largeKnee)
    ('- 票面建议：小 4 / 中 2-4 / 大 1-2；按峰值效率，{0}票面建议。' -f $(if ($dataSupportsTicket) { '支持' } else { '不支持' }))
    ('- `min(4, ProcessorCount-2)` 在本机 = {0}。' -f $formulaValue)
    ('- `FromDetection` optimize 当前值：{0}；是否对齐本机峰值：{1}。' -f $fromDetectionValue, $fromDetectionMatchesPeaks)
    ('- {0}' -f $ticketMismatchNote)
    ''
)
foreach ($analysis in $analyses) {
    $reportLines += ('## {0}' -f $analysis.label)
    $reportLines += ''
    $reportLines += ('墙钟最佳 DOP：{0}（{1} ms）。10%膝点：{2}。峰值效率 DOP：{3}（{4}）。' -f $analysis.bestDegree, $analysis.bestWallClockMs, $analysis.conservativeKneeDegree, $analysis.peakEfficiencyDegree, $analysis.peakParallelEfficiency)
    if ($null -ne $analysis.diminishingReturns) {
        $reportLines += ('收益递减：在 {0} → {1} 时增量 {2}。' -f @(
            $analysis.diminishingReturns.afterDegree
            $analysis.diminishingReturns.nextDegree
            $analysis.diminishingReturns.incrementalGain
        ))
    } else {
        $reportLines += '收益递减：在 1→16 范围内没有出现 <10% 的增量台阶（或 DOP1 已是最佳）。'
    }
    $reportLines += ''
    $reportLines += (Format-ScenarioTable -Analysis $analysis)
    $reportLines += ''
    $reportLines += (Format-MermaidLine -Title ($analysis.label + ' wall-clock ms') -Points $analysis.points)
    $reportLines += ''
}

$reportPath = Join-Path $evidenceHome 'REPORT.md'
Assert-AllowedFixturePath -LiteralPath $reportPath
[IO.File]::WriteAllText($reportPath, (($reportLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

$curveDoc = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue40-curve'
    measuredAtUtc = $analysisDoc.measuredAtUtc
    processorCount = $processorCount
    sampleCount = [int]$SampleCount
    aggregation = 'arithmetic-mean-of-all-recorded-samples'
    decisionRule = 'x = DOP, y = mean wall-clock ms; peakEfficiencyDegree is the recommended size-class DOP'
    scenarios = @(
        foreach ($analysis in $analyses) {
            [ordered]@{
                scenarioId = [string]$analysis.scenarioId
                label = [string]$analysis.label
                sizeClass = [string]$analysis.sizeClass
                peakEfficiencyDegree = [int]$analysis.peakEfficiencyDegree
                bestWallClockDegree = [int]$analysis.bestDegree
                conservativeKneeDegree = [int]$analysis.conservativeKneeDegree
                diminishingReturns = $analysis.diminishingReturns
                efficiencyDrop = $analysis.efficiencyDrop
                points = @($analysis.points)
            }
        }
    )
}
Write-JsonFile -LiteralPath (Join-Path $evidenceHome 'curve.json') -Value $curveDoc

$payloadLeft = @(Get-ChildItem -LiteralPath $workRoot -Recurse -File -Filter '*.bin' -ErrorAction SilentlyContinue)
Assert-True ($payloadLeft.Count -eq 0) ("测完不得剩夹具 payload，实际为 {0}" -f $payloadLeft.Count)
Assert-True ($optimizeDefault.RecommendParallel -eq $true) 'NTFS 本地 FromDetection 必须仍推荐并行'
# 推荐合同钉 #40 2026-08-19 复测结论 2/2/2（scripts/lib/CodexSafeTreeDeleteFileIdentity.cs 常量、
# 性能 spec「操作者指南」）。本机实测峰值（$smallPeak 等）随机器状态浮动（#42 当轮测得 2、
# 2026-08-19 回归轮测得 4），只作为证据记录进 analysis.json 的 fromDetectionMatchesMeasuredPeaks，
# 不再作为断言口径。
Assert-True ($optimizeDefault.RecommendedMaxParallelism -eq 2) (
    "FromDetection optimize 必须等于 #40 复测钉定的 2（本机实测小文件峰值 DOP=$smallPeak 仅记录，不作合同），实际为 $fromDetectionValue"
)
$fatCaps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('FAT32', $false, $false)
$netCaps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $true, $true)
Assert-True ($fatCaps.RecommendParallel -eq $false) 'FAT32 RecommendParallel 必须仍为 false'
Assert-True ($fatCaps.RecommendedMaxParallelism -eq 1) 'FAT32 RecommendedMaxParallelism 必须仍为 1'
Assert-True ($netCaps.RecommendParallel -eq $false) '网络卷 RecommendParallel 必须仍为 false'
Assert-True ($netCaps.RecommendedMaxParallelism -eq 1) '网络卷 RecommendedMaxParallelism 必须仍为 1'
$recommendType = [CodexSafeTreeDelete.FileSystemCapabilities]
$optimizeMethod = $recommendType.GetMethod('RecommendOptimizeMaxParallelism')
$sizeMethod = $recommendType.GetMethod('RecommendMaxParallelismForTypicalFileBytes')
Assert-True ($null -ne $optimizeMethod) '必须有 RecommendOptimizeMaxParallelism'
Assert-True ($null -ne $sizeMethod) '必须有 RecommendMaxParallelismForTypicalFileBytes'
Assert-True (
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendOptimizeMaxParallelism() -eq 2
) "典型小文件推荐必须是 #40 复测钉定的 2（本机实测 $smallPeak 仅记录）"
Assert-True (
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendMaxParallelismForTypicalFileBytes(1024) -eq 2
) "1KB 必须推荐 #40 复测钉定的 2（本机实测 $smallPeak 仅记录）"
Assert-True (
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendMaxParallelismForTypicalFileBytes(10240) -eq 2
) "10KB 必须推荐 #40 复测钉定的 2（本机实测 $mediumPeak 仅记录）"
Assert-True (
    [CodexSafeTreeDelete.FileSystemCapabilities]::RecommendMaxParallelismForTypicalFileBytes(1048576) -eq 2
) "1MB 必须推荐 #40 复测钉定的 2（本机实测 $largePeak 仅记录）"

foreach ($scenario in $scenarios) {
    foreach ($degree in $degrees) {
        Assert-True (Test-Path -LiteralPath (Get-RawJsonPath -ScenarioId $scenario.id -Degree $degree) -PathType Leaf) '每个场景×DOP 必须有聚合 JSON'
        $expectedSamples = if ($SkipBenchmark) { 1 } else { $SampleCount }
        if (-not $SkipBenchmark) {
            for ($sampleIndex = 1; $sampleIndex -le $SampleCount; $sampleIndex++) {
                Assert-True (
                    Test-Path -LiteralPath (Get-RawJsonPath -ScenarioId $scenario.id -Degree $degree -SampleIndex $sampleIndex) -PathType Leaf
                ) ("每个场景×DOP 必须有第 {0} 次取样 JSON" -f $sampleIndex)
            }
        } else {
            Assert-True ($expectedSamples -ge 1) 'SkipBenchmark 至少能读到聚合记录'
        }
    }
}
Assert-True (Test-Path -LiteralPath $reportPath -PathType Leaf) '必须写出 REPORT.md'
Assert-True (Test-Path -LiteralPath (Join-Path $evidenceHome 'analysis.json') -PathType Leaf) '必须写出 analysis.json'
Assert-True (Test-Path -LiteralPath (Join-Path $evidenceHome 'curve.json') -PathType Leaf) '必须写出 curve.json'
Assert-FrozenIssue40EvidenceUnchanged

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteParallelismBenchmark'
    issue = 40
    mode = $(if ($SkipBenchmark) { 'SkipBenchmark' } else { 'All' })
    evidenceHome = $evidenceHome
    processorCount = $processorCount
    sampleCount = [int]$SampleCount
    smallKnee = $smallKnee
    mediumKnee = $mediumKnee
    largeKnee = $largeKnee
    smallPeak = $smallPeak
    mediumPeak = $mediumPeak
    largePeak = $largePeak
    fromDetectionValue = $fromDetectionValue
    fromDetectionMatchesMeasuredPeaks = [bool]$fromDetectionMatchesPeaks
    dataSupportsTicketSuggestion = [bool]$dataSupportsTicket
    flushVerified = [bool]$flushMeta.verified
    rawCount = $allRows.Count
    sampleRawCount = $allSamples.Count
    wroteToFrozenIssue40Raw = $false
    wroteToHistoricalParallelismBenchmark = $false
}
