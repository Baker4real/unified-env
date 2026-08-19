[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (ParallelPurgeCoordinator / #39):
# 1. ParallelPurgeCoordinator — group by top-level directory, Parallel.ForEach, DOP from FileSystemCapabilities
# 2. Per-directory group-commit — durable pending batch → File.Delete → durable commit batch
#    (pending must be visible before any delete in the batch; commit only for successful deletes)
# 3. GetOrCreateThreadJournal — one writer per thread per top-level directory; independent journal files
# 4. Partial failure — one file error is recorded; other files still delete; no fake all-success
# Observable: fixture-tree file presence, journal literal lines, result counts. Not production Purge.

$projectRoot = Split-Path -Parent $PSScriptRoot
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$hashCacheSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteHashCache.cs'
$threadJournalSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteThreadJournal.cs'
$parallelPurgeSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteParallelPurge.cs'
$evidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue39-20260817'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$scaleJsonPath = Join-Path $evidenceHome 'scale-10000.json'

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

function New-SerialCapabilities {
    return [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('FAT32', $false, $false)
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
Assert-True (Test-Path -LiteralPath $parallelPurgeSourcePath -PathType Leaf) 'RED: CodexSafeTreeDeleteParallelPurge.cs 尚不存在'

[void][IO.Directory]::CreateDirectory($fixtureRoot)

if (-not ('CodexSafeTreeDelete.ParallelPurgeCoordinator' -as [type])) {
    Add-Type -Path $identitySourcePath, $hashCacheSourcePath, $threadJournalSourcePath, $parallelPurgeSourcePath -ErrorAction Stop
}

$coordinatorType = 'CodexSafeTreeDelete.ParallelPurgeCoordinator' -as [type]
Assert-True ($null -ne $coordinatorType) 'AC1: ParallelPurgeCoordinator 类必须存在'

$optimizeCaps = New-OptimizeCapabilities
$serialCaps = New-SerialCapabilities
Assert-True ($optimizeCaps.RecommendParallel -eq $true) 'NTFS 本地应推荐并行'
Assert-True ($optimizeCaps.RecommendedMaxParallelism -eq 2) 'optimize 时 RecommendedMaxParallelism 必须是 2（#40 20260819 峰值效率）'
Assert-True ($serialCaps.RecommendParallel -eq $false) 'FAT32 不应推荐并行'
Assert-True ($serialCaps.RecommendedMaxParallelism -eq 1) '非 optimize 时 RecommendedMaxParallelism 必须是 1'

$optimizeDop = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::ResolveMaxDegreeOfParallelism($optimizeCaps)
$serialDop = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::ResolveMaxDegreeOfParallelism($serialCaps)
Assert-True ($optimizeDop -eq 2) 'AC4: optimize 时 MaxDegreeOfParallelism 必须来自 RecommendedMaxParallelism=2'
Assert-True ($serialDop -eq 1) 'AC4: RecommendParallel=false 时必须串行 DOP=1'

$groupTree = Join-Path $fixtureRoot 'group-tree'
New-FixtureFile -LiteralPath (Join-Path $groupTree 'dir-a\nested\a2.txt')
New-FixtureFile -LiteralPath (Join-Path $groupTree 'dir-a\a1.txt')
New-FixtureFile -LiteralPath (Join-Path $groupTree 'dir-b\b1.txt')
New-FixtureFile -LiteralPath (Join-Path $groupTree 'loose.txt')
$groups = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::GroupByTopLevelDirectory($groupTree)
Assert-True ($groups.Count -eq 3) 'AC2: 必须按顶级子目录分组（dir-a / dir-b / root）'
$groupMap = @{}
foreach ($group in $groups) {
    $groupMap[$group.DirectoryKey] = @($group.Files)
}
Assert-True ($groupMap.ContainsKey('dir-a')) 'AC2: 必须有 dir-a 组'
Assert-True ($groupMap.ContainsKey('dir-b')) 'AC2: 必须有 dir-b 组'
Assert-True ($groupMap.ContainsKey('root')) 'AC2: 根下散文件归入 root 组'
Assert-True ($groupMap['dir-a'].Count -eq 2) 'AC2: dir-a 组含嵌套文件，仍是一组'
Assert-True ($groupMap['dir-b'].Count -eq 1) 'AC2: dir-b 组只有自己的文件'
Assert-True ($groupMap['root'].Count -eq 1) 'AC2: root 组只有 loose.txt'

$multiTree = Join-Path $fixtureRoot 'multi-tree'
$multiJournal = Join-Path $fixtureRoot 'multi-journal'
[void][IO.Directory]::CreateDirectory($multiJournal)
$multiFiles = @(
    (Join-Path $multiTree 'dir-a\a1.txt'),
    (Join-Path $multiTree 'dir-a\a2.txt'),
    (Join-Path $multiTree 'dir-b\b1.txt'),
    (Join-Path $multiTree 'dir-b\b2.txt'),
    (Join-Path $multiTree 'dir-c\c1.txt'),
    (Join-Path $multiTree 'dir-d\d1.txt')
)
foreach ($path in $multiFiles) {
    New-FixtureFile -LiteralPath $path
}
$coordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
    $multiTree,
    $multiJournal,
    $evidenceHome,
    $optimizeCaps)
try {
    Assert-True ($coordinator.MaxDegreeOfParallelism -eq 2) 'AC4: coordinator.MaxDegreeOfParallelism 必须是 2'
    $multiResult = $coordinator.Purge()
} finally {
    $coordinator.Dispose()
}
Assert-True ($multiResult.FileCount -eq 6) 'AC9: 必须看到 6 个文件'
Assert-True ($multiResult.DeletedCount -eq 6) 'AC9: 6 个文件都必须删掉'
Assert-True ($multiResult.FailedCount -eq 0) 'AC9: 并行删除不得有失败'
Assert-True ((@(Get-RemainingFiles -LiteralPath $multiTree)).Count -eq 0) 'AC9: 目录树上不得剩余文件'
Assert-True ($multiResult.FilesPresentAfterPending -eq 6) 'AC6: pending Flush 后、delete 前每个文件必须仍在且另一句柄已读到 pending'

$journalFiles = @(
    Get-ChildItem -LiteralPath $multiJournal -Filter '*.jsonl' -File |
        ForEach-Object { $_.FullName }
)
Assert-True ($journalFiles.Count -ge 4) 'AC10: 每个顶级目录/线程必须有独立 journal 文件'
Assert-True ($multiResult.JournalFileCount -eq $journalFiles.Count) 'AC10: result.JournalFileCount 必须等于落盘 journal 数'
$journalNames = @($journalFiles | ForEach-Object { Split-Path -Leaf $_ })
foreach ($key in @('dir-a', 'dir-b', 'dir-c', 'dir-d')) {
    $match = @($journalNames | Where-Object { $_ -like ($key + '.thread-*.jsonl') })
    Assert-True ($match.Count -ge 1) "AC5/AC10: $key 必须有独立 thread journal"
}

$allJournalText = ($journalFiles | ForEach-Object { Read-JournalTextFromSecondHandle -LiteralPath $_ }) -join ''
foreach ($rel in @('dir-a/a1.txt', 'dir-a/a2.txt', 'dir-b/b1.txt', 'dir-b/b2.txt', 'dir-c/c1.txt', 'dir-d/d1.txt')) {
    $pendingLiteral = '{"op":"pending","path":"' + $rel + '"}'
    $commitLiteral = '{"op":"commit","path":"' + $rel + '"}'
    Assert-True ($allJournalText.Contains($pendingLiteral)) "AC11: journal 必须含字面 pending $rel"
    Assert-True ($allJournalText.Contains($commitLiteral)) "AC11: journal 必须含字面 commit $rel"
}

foreach ($journalPath in $journalFiles) {
    $lines = @(
        (Read-JournalTextFromSecondHandle -LiteralPath $journalPath) -split "`n" |
            Where-Object { $_.Length -gt 0 }
    )
    $pendingSeen = @{}
    foreach ($line in $lines) {
        if ($line -like '{"op":"pending"*') {
            $pendingPath = ($line -replace '^\{"op":"pending","path":"', '' -replace '"\}$', '')
            Assert-True (-not $pendingSeen.ContainsKey($pendingPath)) "AC11: 同一路径不得重复 pending，$pendingPath"
            $pendingSeen[$pendingPath] = $true
        } elseif ($line -like '{"op":"commit"*') {
            $commitPath = ($line -replace '^\{"op":"commit","path":"', '' -replace '"\}$', '')
            Assert-True ($pendingSeen.ContainsKey($commitPath)) "AC11: commit 之前必须已有同一路径的 pending，$commitPath"
        } else {
            throw "AC11: journal 只能含 pending/commit 行，实际为 $line"
        }
    }
}

$failTree = Join-Path $fixtureRoot 'fail-tree'
$failJournal = Join-Path $fixtureRoot 'fail-journal'
[void][IO.Directory]::CreateDirectory($failJournal)
$okA = Join-Path $failTree 'dir-ok\ok.txt'
$okB = Join-Path $failTree 'dir-other\other.txt'
$lockedPath = Join-Path $failTree 'dir-lock\locked.txt'
New-FixtureFile -LiteralPath $okA
New-FixtureFile -LiteralPath $okB
New-FixtureFile -LiteralPath $lockedPath
$lockStream = [IO.File]::Open(
    $lockedPath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None)
$failResult = $null
try {
    $failCoordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
        $failTree,
        $failJournal,
        $evidenceHome,
        $optimizeCaps)
    try {
        $failResult = $failCoordinator.Purge()
    } finally {
        $failCoordinator.Dispose()
    }
} finally {
    $lockStream.Dispose()
}
Assert-True ($null -ne $failResult) 'AC7/AC12: 部分失败也必须返回汇总结果'
Assert-True ($failResult.FailedCount -eq 1) 'AC7: 锁住的那个文件必须记为失败'
Assert-True ($failResult.DeletedCount -eq 2) 'AC12: 其他两个文件仍必须删掉'
Assert-True ($failResult.Errors.Count -ge 1) 'AC7: 必须汇总错误，不得假装全成功'
Assert-True (-not (Test-Path -LiteralPath $okA -PathType Leaf)) 'AC12: dir-ok\ok.txt 必须已删'
Assert-True (-not (Test-Path -LiteralPath $okB -PathType Leaf)) 'AC12: dir-other\other.txt 必须已删'
Assert-True (Test-Path -LiteralPath $lockedPath -PathType Leaf) 'AC12: 锁住的文件必须仍在且未 commit 删除'
$failJournalText = @(
    Get-ChildItem -LiteralPath $failJournal -Filter '*.jsonl' -File |
        ForEach-Object { Read-JournalTextFromSecondHandle -LiteralPath $_.FullName }
) -join ''
Assert-True ($failJournalText.Contains('{"op":"pending","path":"dir-lock/locked.txt"}')) 'AC7: 失败文件必须已写 pending'
Assert-True (-not $failJournalText.Contains('{"op":"commit","path":"dir-lock/locked.txt"}')) 'AC7: 失败文件不得 commit'
Assert-True ($failJournalText.Contains('{"op":"commit","path":"dir-ok/ok.txt"}')) 'AC12: 成功文件仍须 commit'
Assert-True ($failJournalText.Contains('{"op":"commit","path":"dir-other/other.txt"}')) 'AC12: 另一成功文件仍须 commit'

$serialTree = Join-Path $fixtureRoot 'serial-tree'
$serialJournal = Join-Path $fixtureRoot 'serial-journal'
[void][IO.Directory]::CreateDirectory($serialJournal)
New-FixtureFile -LiteralPath (Join-Path $serialTree 'dir-a\s1.txt')
New-FixtureFile -LiteralPath (Join-Path $serialTree 'dir-b\s2.txt')
$serialCoordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
    $serialTree,
    $serialJournal,
    $evidenceHome,
    $serialCaps)
try {
    Assert-True ($serialCoordinator.MaxDegreeOfParallelism -eq 1) 'RecommendParallel=false 时实例 DOP 必须是 1'
    $serialResult = $serialCoordinator.Purge()
} finally {
    $serialCoordinator.Dispose()
}
Assert-True ($serialResult.DeletedCount -eq 2) '串行 DOP=1 仍必须删掉全部文件'
Assert-True ($serialResult.FailedCount -eq 0) '串行路径不得失败'
Assert-True ((@(Get-RemainingFiles -LiteralPath $serialTree)).Count -eq 0) '串行删除后不得剩文件'

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
    $optimizeCaps)
try {
    $scaleResult = $scaleCoordinator.Purge()
} finally {
    $scaleCoordinator.Dispose()
}

$scaleRemaining = @(Get-RemainingFiles -LiteralPath $scaleTree)
$scaleJournalFiles = @(
    Get-ChildItem -LiteralPath $scaleJournal -Filter '*.jsonl' -File |
        ForEach-Object { $_.FullName }
)
Assert-True ($scaleResult.FileCount -eq $scaleFileCount) 'AC13: 10k 必须看到 10000 个文件'
Assert-True ($scaleResult.DeletedCount -eq $scaleFileCount) 'AC13: 10k 必须全部删除'
Assert-True ($scaleResult.FailedCount -eq 0) 'AC13: 10k 不得有失败'
Assert-True ($scaleRemaining.Count -eq 0) 'AC13: 10k 树不得剩余文件'
Assert-True ($scaleJournalFiles.Count -ge 4) 'AC13: 10k 必须有每顶级目录的独立 journal'
Assert-True ($scaleResult.JournalFileCount -eq $scaleJournalFiles.Count) 'AC13: journal 文件数必须完整入账'

$scalePending = 0
$scaleCommit = 0
foreach ($journalPath in $scaleJournalFiles) {
    $lines = @(
        (Read-JournalTextFromSecondHandle -LiteralPath $journalPath) -split "`n" |
            Where-Object { $_.Length -gt 0 }
    )
    foreach ($line in $lines) {
        if ($line.StartsWith('{"op":"pending"')) { $scalePending++ }
        elseif ($line.StartsWith('{"op":"commit"')) { $scaleCommit++ }
    }
}
Assert-True ($scalePending -eq $scaleFileCount) "AC13: journal pending 必须是 10000，实际为 $scalePending"
Assert-True ($scaleCommit -eq $scaleFileCount) "AC13: journal commit 必须是 10000，实际为 $scaleCommit"

$scaleRecord = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue39-scale-10000'
    fileCount = [int]$scaleResult.FileCount
    elapsedMs = [int64]$scaleResult.ElapsedMs
    journalFileCount = [int]$scaleResult.JournalFileCount
    failedCount = [int]$scaleResult.FailedCount
    deletedCount = [int]$scaleResult.DeletedCount
    method = 'four top-level dirs x 2500 tiny files; ParallelPurgeCoordinator File.Delete on issue39 fixture tree only; not production Purge'
}
[IO.File]::WriteAllText(
    $scaleJsonPath,
    ($scaleRecord | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false))
Assert-True (Test-Path -LiteralPath $scaleJsonPath -PathType Leaf) 'AC13: 必须写出 scale-10000.json'

foreach ($leftover in $scaleRemaining) {
    [IO.File]::Delete($leftover)
}
Remove-EmptyDirectories -LiteralPath $scaleTree
Assert-True (-not (Test-Path -LiteralPath $scaleTree)) '测完必须删掉 10k 树，保留 journal/报告'

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteParallelPurgeCoordinator'
    issue = 39
    slices = 5
    scaleFileCount = [int]$scaleResult.FileCount
    scaleElapsedMs = [int64]$scaleResult.ElapsedMs
    scaleJournalFileCount = [int]$scaleResult.JournalFileCount
    scaleFailedCount = [int]$scaleResult.FailedCount
}
