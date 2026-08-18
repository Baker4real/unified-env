[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (JournalPerformanceReport / #41):
# 1. ThreadJournalWriter.Flush — Stopwatch accumulates TotalFlushTimeMs and FlushCount
# 2. Pending-before-delete — after WriteEntry(pending)+Flush(true), a second handle must see pending
#    while the target file still exists (#39; each Flush hits disk via FlushFileBuffers)
# 3. Slow flush — single Flush >100ms is observable (SlowFlushCount / LastSlowFlushWarning)
# 4. JournalPerformanceReport.FromTotals — overhead formula uses literals (200ms / 2000ms = 10%)
# 5. ParallelPurgeCoordinator.Purge — aggregates writer flush time vs Purge wall clock
# Observable: public counters, report fields, warning text, second-handle pending bytes.
# Not production Purge. Not Event Log.

$projectRoot = Split-Path -Parent $PSScriptRoot
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$hashCacheSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteHashCache.cs'
$threadJournalSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteThreadJournal.cs'
$parallelPurgeSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteParallelPurge.cs'
$evidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue41-20260817'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$scaleJsonPath = Join-Path $evidenceHome 'scale-10000.json'
$reportExamplePath = Join-Path $evidenceHome 'journal-performance-report-example.json'
$report10kPath = Join-Path $evidenceHome 'journal-performance-report-10k.json'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-JournalTextFromSecondHandle {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $stream = [IO.File]::Open(
        $LiteralPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function New-FixtureFile {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$Text = 'x'
    )
    $parent = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
    [IO.File]::WriteAllText($LiteralPath, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-RemainingFiles {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
        return @()
    }
    return @(
        Get-ChildItem -LiteralPath $LiteralPath -Recurse -File |
            ForEach-Object { $_.FullName }
    )
}

function Remove-EmptyDirectories {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
        return
    }
    $dirs = @(
        Get-ChildItem -LiteralPath $LiteralPath -Recurse -Directory |
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

function New-OptimizeCapabilities {
    return [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $false, $true)
}

function Write-JsonArtifact {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)]$Record
    )
    [IO.File]::WriteAllText(
        $LiteralPath,
        ($Record | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
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
Assert-True (Test-Path -LiteralPath $parallelPurgeSourcePath -PathType Leaf) 'CodexSafeTreeDeleteParallelPurge.cs 必须存在'

[void][IO.Directory]::CreateDirectory($evidenceHome)
[void][IO.Directory]::CreateDirectory($fixtureRoot)

if (-not ('CodexSafeTreeDelete.ParallelPurgeCoordinator' -as [type])) {
    Add-Type -Path $identitySourcePath, $hashCacheSourcePath, $threadJournalSourcePath, $parallelPurgeSourcePath -ErrorAction Stop
}

$writerType = 'CodexSafeTreeDelete.ThreadJournalWriter' -as [type]
$reportType = 'CodexSafeTreeDelete.JournalPerformanceReport' -as [type]
Assert-True ($null -ne $writerType) 'ThreadJournalWriter 必须存在'
Assert-True ($null -ne $reportType) 'AC: JournalPerformanceReport 类必须存在'

# --- Slice 1: Flush counters accumulate ---
$counterPath = Join-Path $fixtureRoot 'counter.thread-41.jsonl'
$counterWriter = [CodexSafeTreeDelete.ThreadJournalWriter]::new($counterPath, 41, $evidenceHome)
try {
    Assert-True ($counterWriter.FlushCount -eq 0) '新 writer 的 FlushCount 必须是 0'
    Assert-True ($counterWriter.TotalFlushTimeMs -eq 0) '新 writer 的 TotalFlushTimeMs 必须是 0'
    Assert-True ($counterWriter.SlowFlushCount -eq 0) '新 writer 的 SlowFlushCount 必须是 0'
    Assert-True ([string]::IsNullOrEmpty($counterWriter.LastSlowFlushWarning)) '新 writer 不得有慢 flush 警告'

    $counterWriter.WriteEntry('{"op":"pending","path":"a.txt"}')
    $counterWriter.Flush()
    Assert-True ($counterWriter.FlushCount -eq 1) '第一次 Flush 后 FlushCount 必须是 1'
    $afterFirst = [int64]$counterWriter.TotalFlushTimeMs
    Assert-True ($afterFirst -ge 0) 'TotalFlushTimeMs 必须可累加且非负'

    $counterWriter.WriteEntry('{"op":"commit","path":"a.txt"}')
    $counterWriter.Flush()
    Assert-True ($counterWriter.FlushCount -eq 2) '第二次 Flush 后 FlushCount 必须是 2'
    Assert-True ($counterWriter.TotalFlushTimeMs -ge $afterFirst) 'TotalFlushTimeMs 必须单调累加'

    for ($i = 0; $i -lt 18; $i++) {
        $counterWriter.WriteEntry(('{"op":"extra","n":' + $i + '}'))
        $counterWriter.Flush()
    }
    Assert-True ($counterWriter.FlushCount -eq 20) '20 次 Flush 后 FlushCount 必须是 20'
    Assert-True ($counterWriter.TotalFlushTimeMs -ge 0) '20 次 Flush 后 TotalFlushTimeMs 必须仍非负'
    Assert-True ($counterWriter.SlowFlushCount -eq 0) '正常快 flush 不得记为慢 flush'
} finally {
    $counterWriter.Dispose()
}

# --- Slice 2: pending must be visible to a second handle before delete ---
$pendingTarget = Join-Path $fixtureRoot 'pending-before-delete.txt'
New-FixtureFile -LiteralPath $pendingTarget
$pendingJournalPath = Join-Path $fixtureRoot 'pending-vis.thread-41.jsonl'
$pendingLiteral = '{"op":"pending","path":"pending-before-delete.txt"}'
$commitLiteral = '{"op":"commit","path":"pending-before-delete.txt"}'
$pendingWriter = [CodexSafeTreeDelete.ThreadJournalWriter]::new($pendingJournalPath, 41, $evidenceHome)
try {
    $pendingWriter.WriteEntry($pendingLiteral)
    $pendingWriter.Flush()
    Assert-True ($pendingWriter.FlushCount -eq 1) 'pending Flush 必须计入 FlushCount'
    $pendingSeen = Read-JournalTextFromSecondHandle -LiteralPath $pendingJournalPath
    Assert-True ($pendingSeen.Contains($pendingLiteral)) 'AC/#39: pending Flush 后第二句柄必须能读到 pending'
    Assert-True (Test-Path -LiteralPath $pendingTarget -PathType Leaf) 'pending Flush 后、delete 前目标文件必须仍在'
    [IO.File]::Delete($pendingTarget)
    Assert-True (-not (Test-Path -LiteralPath $pendingTarget -PathType Leaf)) 'delete 必须发生在 pending 已对第二句柄可见之后'
    $pendingWriter.WriteEntry($commitLiteral)
    $pendingWriter.Flush()
    Assert-True ($pendingWriter.FlushCount -eq 2) 'commit Flush 必须计入 FlushCount'
    $commitSeen = Read-JournalTextFromSecondHandle -LiteralPath $pendingJournalPath
    Assert-True ($commitSeen.Contains($pendingLiteral)) 'commit Flush 后 pending 行必须仍在'
    Assert-True ($commitSeen.Contains($commitLiteral)) 'commit Flush 后第二句柄必须能读到 commit'
} finally {
    $pendingWriter.Dispose()
}

# --- Slice 3: overhead formula uses independent literals ---
$boundary = [CodexSafeTreeDelete.JournalPerformanceReport]::FromTotals(200, 4, 2000)
Assert-True ($boundary.TotalFlushTimeMs -eq 200) 'FromTotals 必须保留字面 TotalFlushTimeMs=200'
Assert-True ($boundary.FlushCount -eq 4) 'FromTotals 必须保留字面 FlushCount=4'
Assert-True ($boundary.OverheadPercent -eq 10) '200ms flush / 2000ms 操作必须得到 OverheadPercent=10'
Assert-True ($boundary.IsWithinTarget -eq $false) 'OverheadPercent=10 时 IsWithinTarget 必须为 false（阈值是 <10）'
Assert-True (-not [string]::IsNullOrWhiteSpace($boundary.Warning)) 'overhead ≥10% 必须有警告文案'
Assert-True ($boundary.Warning.ToLowerInvariant().Contains('parallel')) '警告必须建议降低并行度'
Assert-True ($boundary.Warning.ToLowerInvariant().Contains('disk')) '警告必须建议检查磁盘'

$under = [CodexSafeTreeDelete.JournalPerformanceReport]::FromTotals(199, 4, 2000)
Assert-True ($under.OverheadPercent -eq 9.95) '199ms / 2000ms 必须是 9.95%'
Assert-True ($under.IsWithinTarget -eq $true) '9.95% < 10 时 IsWithinTarget 必须为 true'
Assert-True ([string]::IsNullOrEmpty($under.Warning)) '低于目标时不得写 overhead 警告'

$five = [CodexSafeTreeDelete.JournalPerformanceReport]::FromTotals(100, 2, 2000)
Assert-True ($five.OverheadPercent -eq 5) '100ms / 2000ms 必须是 5%'
Assert-True ($five.IsWithinTarget -eq $true) '5% 必须在目标内'

$zeroOp = [CodexSafeTreeDelete.JournalPerformanceReport]::FromTotals(0, 0, 0)
Assert-True ($zeroOp.OverheadPercent -eq 0) '零操作时间且零 flush 时 overhead 必须是 0'
Assert-True ($zeroOp.IsWithinTarget -eq $true) '零开销必须视为在目标内'

Write-JsonArtifact -LiteralPath $reportExamplePath -Record ([ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue41-report-example'
    source = 'JournalPerformanceReport.FromTotals(200, 4, 2000)'
    TotalFlushTimeMs = [int64]$boundary.TotalFlushTimeMs
    FlushCount = [int]$boundary.FlushCount
    OverheadPercent = [double]$boundary.OverheadPercent
    IsWithinTarget = [bool]$boundary.IsWithinTarget
    Warning = [string]$boundary.Warning
    analysis = '200ms journal flush / 2000ms operation = 10% overhead; target is <10%, so this is out of target and must warn.'
})
Assert-True (Test-Path -LiteralPath $reportExamplePath -PathType Leaf) '必须写出性能报告示例'

# --- Slice 4: coordinator aggregates flush time and exposes the report ---
$smallTree = Join-Path $fixtureRoot 'small-tree'
$smallJournal = Join-Path $fixtureRoot 'small-journal'
[void][IO.Directory]::CreateDirectory($smallJournal)
$smallFiles = @(
    (Join-Path $smallTree 'dir-a\a1.txt'),
    (Join-Path $smallTree 'dir-a\a2.txt'),
    (Join-Path $smallTree 'dir-b\b1.txt'),
    (Join-Path $smallTree 'dir-c\c1.txt')
)
foreach ($path in $smallFiles) {
    New-FixtureFile -LiteralPath $path
}
$smallCoordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
    $smallTree,
    $smallJournal,
    $evidenceHome,
    (New-OptimizeCapabilities))
try {
    $smallResult = $smallCoordinator.Purge()
    $smallReport = $smallResult.JournalPerformance
    $lastReport = $smallCoordinator.LastJournalPerformance
} finally {
    $smallCoordinator.Dispose()
}
Assert-True ($smallResult.DeletedCount -eq 4) '小树必须删掉 4 个文件'
Assert-True ($smallResult.FailedCount -eq 0) '小树不得失败'
Assert-True ($null -ne $smallReport) 'AC: Purge 结果必须带 JournalPerformanceReport'
Assert-True ($null -ne $lastReport) 'AC: coordinator.LastJournalPerformance 必须可读'
Assert-True ([object]::ReferenceEquals($smallReport, $lastReport)) '结果上的报告与 LastJournalPerformance 必须是同一份'
Assert-True ($smallReport.FlushCount -eq 8) '4 个文件各 pending+commit 两次 Flush，FlushCount 必须是 8'
Assert-True ($smallReport.TotalFlushTimeMs -ge 0) '汇总 TotalFlushTimeMs 必须非负'
Assert-True ($smallResult.ElapsedMs -ge 0) 'Purge 墙钟必须入账'
if ($smallResult.ElapsedMs -gt 0) {
    $expectedOverhead = (100.0 * $smallReport.TotalFlushTimeMs) / $smallResult.ElapsedMs
    Assert-True ($smallReport.OverheadPercent -eq $expectedOverhead) 'overhead% 必须是 TotalFlushTimeMs / Purge 墙钟'
}
Assert-True ($smallReport.IsWithinTarget -eq ($smallReport.OverheadPercent -lt 10)) 'IsWithinTarget 必须是 OverheadPercent < 10'
if ($smallReport.OverheadPercent -ge 10) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($smallReport.Warning)) 'overhead ≥10% 时报告必须有警告'
    Assert-True ($smallReport.Warning.ToLowerInvariant().Contains('parallel')) '警告必须建议降低并行度'
    Assert-True ($smallReport.Warning.ToLowerInvariant().Contains('disk')) '警告必须建议检查磁盘'
} else {
    Assert-True ([string]::IsNullOrEmpty($smallReport.Warning)) 'overhead <10% 时不得写 overhead 警告'
}

# --- Slice 5: 10k+ fixture; record live hit-disk overhead; do not fake <10% ---
$scaleTree = Join-Path $fixtureRoot 'scale-10000-tree'
$scaleJournal = Join-Path $fixtureRoot 'scale-10000-journal'
[void][IO.Directory]::CreateDirectory($scaleJournal)
$scaleFileCount = 10000
$filesPerDir = 2500
for ($dirIndex = 0; $dirIndex -lt 4; $dirIndex++) {
    $dirPath = Join-Path $scaleTree ('dir-{0}' -f $dirIndex)
    [void][IO.Directory]::CreateDirectory($dirPath)
    for ($fileIndex = 0; $fileIndex -lt $filesPerDir; $fileIndex++) {
        $name = 'f-{0:D4}.txt' -f $fileIndex
        [IO.File]::WriteAllText((Join-Path $dirPath $name), 'x', [Text.UTF8Encoding]::new($false))
    }
}
$createdScale = @(Get-ChildItem -LiteralPath $scaleTree -Recurse -File).Count
Assert-True ($createdScale -eq $scaleFileCount) "10k 树必须写出 10000 个文件，实际为 $createdScale"

$scaleCoordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
    $scaleTree,
    $scaleJournal,
    $evidenceHome,
    (New-OptimizeCapabilities))
try {
    $scaleResult = $scaleCoordinator.Purge()
    $scaleReport = $scaleResult.JournalPerformance
} finally {
    $scaleCoordinator.Dispose()
}

$scaleRemaining = @(Get-RemainingFiles -LiteralPath $scaleTree)
Assert-True ($scaleResult.FileCount -eq $scaleFileCount) '10k 必须看到 10000 个文件'
Assert-True ($scaleResult.DeletedCount -eq $scaleFileCount) '10k 必须全部删除'
Assert-True ($scaleResult.FailedCount -eq 0) '10k 不得有失败'
Assert-True ($scaleRemaining.Count -eq 0) '10k 树不得剩余文件'
Assert-True ($null -ne $scaleReport) '10k 必须产出 JournalPerformanceReport'
Assert-True ($scaleReport.FlushCount -eq 20000) '10k 各 2 次 Flush，FlushCount 必须是 20000'
Assert-True ($scaleReport.TotalFlushTimeMs -ge 0) '10k TotalFlushTimeMs 必须入账'
Assert-True ($scaleResult.ElapsedMs -gt 0) '10k Purge 墙钟必须 >0'
$scaleExpectedOverhead = (100.0 * $scaleReport.TotalFlushTimeMs) / $scaleResult.ElapsedMs
Assert-True ($scaleReport.OverheadPercent -eq $scaleExpectedOverhead) '10k overhead% 必须用字面墙钟公式'
Assert-True ($scaleReport.IsWithinTarget -eq ($scaleReport.OverheadPercent -lt 10)) '10k IsWithinTarget 必须跟随 <10 规则'
if ($scaleReport.OverheadPercent -ge 10) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($scaleReport.Warning)) '10k overhead ≥10% 必须有警告，不得失败闭锁删除'
}

$scaleRecord = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue41-scale-10000'
    fileCount = [int]$scaleResult.FileCount
    elapsedMs = [int64]$scaleResult.ElapsedMs
    journalFileCount = [int]$scaleResult.JournalFileCount
    failedCount = [int]$scaleResult.FailedCount
    deletedCount = [int]$scaleResult.DeletedCount
    TotalFlushTimeMs = [int64]$scaleReport.TotalFlushTimeMs
    FlushCount = [int]$scaleReport.FlushCount
    OverheadPercent = [double]$scaleReport.OverheadPercent
    IsWithinTarget = [bool]$scaleReport.IsWithinTarget
    SlowFlushCount = [int]$scaleReport.SlowFlushCount
    Warning = [string]$scaleReport.Warning
    method = 'four top-level dirs x 2500 tiny files; ParallelPurgeCoordinator File.Delete on issue41 fixture tree only; not production Purge'
}
Write-JsonArtifact -LiteralPath $scaleJsonPath -Record $scaleRecord
Write-JsonArtifact -LiteralPath $report10kPath -Record ([ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue41-report-10k'
    TotalFlushTimeMs = [int64]$scaleReport.TotalFlushTimeMs
    FlushCount = [int]$scaleReport.FlushCount
    OverheadPercent = [double]$scaleReport.OverheadPercent
    IsWithinTarget = [bool]$scaleReport.IsWithinTarget
    SlowFlushCount = [int]$scaleReport.SlowFlushCount
    LastSlowFlushWarning = [string]$scaleReport.LastSlowFlushWarning
    Warning = [string]$scaleReport.Warning
    TotalOperationTimeMs = [int64]$scaleResult.ElapsedMs
    analysis = 'overhead% = TotalFlushTimeMs / Purge elapsedMs; target is <10%. Live number is recorded, not invented.'
})
Assert-True (Test-Path -LiteralPath $scaleJsonPath -PathType Leaf) '必须写出 scale-10000.json'
Assert-True (Test-Path -LiteralPath $report10kPath -PathType Leaf) '必须写出 10k 性能报告'

foreach ($leftover in $scaleRemaining) {
    [IO.File]::Delete($leftover)
}
Remove-EmptyDirectories -LiteralPath $scaleTree
Assert-True (-not (Test-Path -LiteralPath $scaleTree)) '测完必须删掉 10k 树，保留 journal/报告'

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteJournalPerformance'
    issue = 41
    slices = 5
    smallFlushCount = [int]$smallReport.FlushCount
    smallOverheadPercent = [double]$smallReport.OverheadPercent
    scaleFileCount = [int]$scaleResult.FileCount
    scaleElapsedMs = [int64]$scaleResult.ElapsedMs
    scaleTotalFlushTimeMs = [int64]$scaleReport.TotalFlushTimeMs
    scaleFlushCount = [int]$scaleReport.FlushCount
    scaleOverheadPercent = [double]$scaleReport.OverheadPercent
    scaleIsWithinTarget = [bool]$scaleReport.IsWithinTarget
    scaleSlowFlushCount = [int]$scaleReport.SlowFlushCount
}
