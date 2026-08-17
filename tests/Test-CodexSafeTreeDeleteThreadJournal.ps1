[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (ThreadJournalWriter lifecycle / #38):
# 1. ThreadJournalWriter — create-only FileStream + WriteEntry + durable Flush + Dispose
# 2. ThreadJournalOwner.GetOrCreateThreadJournal — current-thread writer; one owner per directory
# 3. ThreadLocal.Values (trackAllValues) — contains every worker thread's writer
# 4. Owner.Dispose in finally — releases every writer even when work throws
# Observable: journal bytes, exclusive-open lock probe, distinct instances/paths. Not Purge.

$projectRoot = Split-Path -Parent $PSScriptRoot
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$hashCacheSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteHashCache.cs'
$threadJournalSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteThreadJournal.cs'
$evidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue38-20260817'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$pendingLiteral = '{"op":"pending","path":"leaf.txt"}'
$commitLiteral = '{"op":"commit","path":"leaf.txt"}'
$expectedFlushedText = "{0}`n{1}`n" -f $pendingLiteral, $commitLiteral

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-ExclusiveOpen {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $stream = [IO.File]::Open(
        $LiteralPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    try {
        return $true
    } finally {
        $stream.Dispose()
    }
}

function Test-ExclusiveOpenBlocked {
    param([Parameter(Mandatory)][string]$LiteralPath)

    try {
        $stream = [IO.File]::Open(
            $LiteralPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
        $stream.Dispose()
        return $false
    } catch [IO.IOException] {
        return $true
    }
}

function Test-WorkFailedException {
    param([Parameter(Mandatory)]$ErrorRecord)

    $current = $ErrorRecord.Exception
    while ($null -ne $current) {
        if ([string]$current.Message -eq 'work-failed') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
Assert-True (Test-Path -LiteralPath $threadJournalSourcePath -PathType Leaf) 'RED: CodexSafeTreeDeleteThreadJournal.cs 尚不存在'

[void][IO.Directory]::CreateDirectory($fixtureRoot)

if (-not ('CodexSafeTreeDelete.ThreadJournalWriter' -as [type])) {
    Add-Type -Path $identitySourcePath, $hashCacheSourcePath, $threadJournalSourcePath -ErrorAction Stop
}

$directPath = Join-Path $fixtureRoot 'direct.thread-42.jsonl'
$writer = [CodexSafeTreeDelete.ThreadJournalWriter]::new($directPath, 42)
try {
    Assert-True ($writer.ThreadId -eq 42) '构造函数必须保存传入的 threadId'
    Assert-True ($writer.JournalFilePath -ceq $directPath) '构造函数必须保存 journalFilePath'
    Assert-True (Test-ExclusiveOpenBlocked -LiteralPath $directPath) '打开中的 writer 必须挡住 FileShare.None'

    $writer.WriteEntry($pendingLiteral)
    $writer.WriteEntry($commitLiteral)
    $writer.Flush()

    $flushed = Read-JournalTextFromSecondHandle -LiteralPath $directPath
    Assert-True ($flushed -ceq $expectedFlushedText) (
        "Flush 后另一句柄必须读到完整条目，实际为: $flushed")
} finally {
    $writer.Dispose()
}

Assert-True (Test-ExclusiveOpen -LiteralPath $directPath) 'Dispose 后必须能以 FileShare.None 打开'

$recreateFailed = $false
try {
    $ignored = [CodexSafeTreeDelete.ThreadJournalWriter]::new($directPath, 42)
    $ignored.Dispose()
} catch [IO.IOException] {
    $recreateFailed = $true
}
Assert-True $recreateFailed '同一路径第二次创建必须失败（create-only）'

$dirA = Join-Path $fixtureRoot 'dir-a'
$dirB = Join-Path $fixtureRoot 'dir-b'
[void][IO.Directory]::CreateDirectory($dirA)
[void][IO.Directory]::CreateDirectory($dirB)

$ownerA = [CodexSafeTreeDelete.ThreadJournalOwner]::new($dirA, 'dir-a')
$ownerB = [CodexSafeTreeDelete.ThreadJournalOwner]::new($dirB, 'dir-b')
try {
    $sameThreadFirst = $ownerA.GetOrCreateThreadJournal()
    $sameThreadSecond = $ownerA.GetOrCreateThreadJournal()
    Assert-True ([object]::ReferenceEquals($sameThreadFirst, $sameThreadSecond)) `
        '同一线程对同一 owner 必须复用同一个 writer'
    Assert-True ($sameThreadFirst.ThreadId -eq [Environment]::CurrentManagedThreadId) `
        'GetOrCreateThreadJournal 必须绑定当前线程'
    $sameThreadFirst.WriteEntry($pendingLiteral)
    $sameThreadFirst.Flush()
    Assert-True (
        (Read-JournalTextFromSecondHandle -LiteralPath $sameThreadFirst.JournalFilePath) -ceq ($pendingLiteral + "`n")
    ) '当前线程 writer Flush 后必须可读到字面条目'

    $crossDirectory = $ownerB.GetOrCreateThreadJournal()
    Assert-True (-not [object]::ReferenceEquals($sameThreadFirst, $crossDirectory)) `
        '跨目录必须是不同 writer 实例'
    Assert-True ($sameThreadFirst.JournalFilePath -cne $crossDirectory.JournalFilePath) `
        '跨目录必须写入不同 journal 文件'
    $crossDirectory.WriteEntry($commitLiteral)
    $crossDirectory.Flush()
    Assert-True (
        (Read-JournalTextFromSecondHandle -LiteralPath $crossDirectory.JournalFilePath) -ceq ($commitLiteral + "`n")
    ) '跨目录 writer 必须有自己的完整条目'
} finally {
    $ownerA.Dispose()
    $ownerB.Dispose()
}

$multiRoot = Join-Path $fixtureRoot 'multi'
[void][IO.Directory]::CreateDirectory($multiRoot)
$multiOwner = [CodexSafeTreeDelete.ThreadJournalOwner]::new($multiRoot, 'dir-multi')
try {
    $workerIds = $multiOwner.GetOrCreateOnNewThreads(4, $pendingLiteral, $false)
    Assert-True ($workerIds.Length -eq 4) '必须启动 4 个工作线程'
    $uniqueWorkerIds = @($workerIds | Select-Object -Unique)
    Assert-True ($uniqueWorkerIds.Count -eq 4) '每个工作线程必须有独立 threadId'

    $tracked = @($multiOwner.Values)
    Assert-True ($tracked.Count -eq 4) 'ThreadLocal.Values 必须包含全部 4 个线程的 writer'
    $trackedPaths = @($tracked | ForEach-Object { $_.JournalFilePath } | Select-Object -Unique)
    $trackedIds = @($tracked | ForEach-Object { $_.ThreadId } | Select-Object -Unique)
    Assert-True ($trackedPaths.Count -eq 4) '每个线程必须有独立 journal 文件'
    Assert-True ($trackedIds.Count -eq 4) 'Values 中的 threadId 必须互不相同'
    foreach ($trackedWriter in $tracked) {
        Assert-True (
            (Read-JournalTextFromSecondHandle -LiteralPath $trackedWriter.JournalFilePath) -ceq ($pendingLiteral + "`n")
        ) "线程 $($trackedWriter.ThreadId) 的 journal 必须有完整字面条目"
        Assert-True (Test-ExclusiveOpenBlocked -LiteralPath $trackedWriter.JournalFilePath) `
            '工作线程 writer 在 Dispose 前必须仍持有句柄'
    }
} finally {
    $multiOwner.Dispose()
}

$afterMulti = @(
    Get-ChildItem -LiteralPath $multiRoot -Filter '*.jsonl' -File |
        ForEach-Object { $_.FullName }
)
Assert-True ($afterMulti.Count -eq 4) '四个线程 Dispose 后 journal 文件必须仍在'
foreach ($journalPath in $afterMulti) {
    Assert-True (Test-ExclusiveOpen -LiteralPath $journalPath) '多线程 Dispose 后句柄必须关闭'
}

$throwRoot = Join-Path $fixtureRoot 'throw'
[void][IO.Directory]::CreateDirectory($throwRoot)
$throwOwner = [CodexSafeTreeDelete.ThreadJournalOwner]::new($throwRoot, 'dir-throw')
$workFailed = $false
$throwPath = $null
try {
    try {
        $throwWriter = $throwOwner.GetOrCreateThreadJournal()
        $throwPath = $throwWriter.JournalFilePath
        $throwWriter.WriteEntry($pendingLiteral)
        $throwWriter.Flush()
        throw 'work-failed'
    } finally {
        $throwOwner.Dispose()
    }
} catch {
    if (Test-WorkFailedException -ErrorRecord $_) {
        $workFailed = $true
    } else {
        throw
    }
}
Assert-True $workFailed '工作抛错必须到达调用方'
Assert-True (-not [string]::IsNullOrWhiteSpace($throwPath)) '抛错前必须已经创建 journal'
Assert-True (Test-ExclusiveOpen -LiteralPath $throwPath) 'finally Dispose 后即使工作抛错也必须关闭句柄'
Assert-True (
    (Read-JournalTextFromSecondHandle -LiteralPath $throwPath) -ceq ($pendingLiteral + "`n")
) '抛错路径 Flush 过的条目必须仍完整可读'

$workerThrowRoot = Join-Path $fixtureRoot 'worker-throw'
[void][IO.Directory]::CreateDirectory($workerThrowRoot)
$workerThrowOwner = [CodexSafeTreeDelete.ThreadJournalOwner]::new($workerThrowRoot, 'dir-wthrow')
$workerFailed = $false
try {
    try {
        [void]$workerThrowOwner.GetOrCreateOnNewThreads(3, $pendingLiteral, $true)
    } catch {
        if (Test-WorkFailedException -ErrorRecord $_) {
            $workerFailed = $true
        } else {
            throw
        }
    }
} finally {
    $workerThrowOwner.Dispose()
}
Assert-True $workerFailed '工作线程抛错必须被看见'
$workerThrowFiles = @(
    Get-ChildItem -LiteralPath $workerThrowRoot -Filter '*.jsonl' -File |
        ForEach-Object { $_.FullName }
)
Assert-True ($workerThrowFiles.Count -eq 3) '抛错的工作线程仍必须留下各自 journal'
foreach ($journalPath in $workerThrowFiles) {
    Assert-True (Test-ExclusiveOpen -LiteralPath $journalPath) '工作线程抛错后 finally Dispose 必须关闭句柄'
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteThreadJournal'
    issue = 38
    slices = 6
}
