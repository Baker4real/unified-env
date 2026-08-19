[CmdletBinding()]
param(
    [switch]$SkipTenK,
    [string]$OutputFile,
    [string]$WorkFolder = 'work'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = (Resolve-Path (Join-Path $evidenceHome '..\..')).Path
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$hashCacheSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteHashCache.cs'
$threadJournalSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteThreadJournal.cs'
$parallelPurgeSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteParallelPurge.cs'
$workRoot = Join-Path $evidenceHome $WorkFolder
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $profileJsonPath = Join-Path $evidenceHome 'flush-profile.json'
} else {
    $profileJsonPath = Join-Path $evidenceHome $OutputFile
}

function New-OptimizeCapabilities {
    param([int]$Degree = 2)
    $caps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $false, $true)
    $caps.RecommendParallel = $true
    $caps.RecommendedMaxParallelism = $Degree
    return $caps
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

if (-not ('CodexSafeTreeDelete.ParallelPurgeCoordinator' -as [type])) {
    Add-Type -Path $identitySourcePath, $hashCacheSourcePath, $threadJournalSourcePath, $parallelPurgeSourcePath -ErrorAction Stop
}

[void][IO.Directory]::CreateDirectory($workRoot)

$microJournalRoot = Join-Path $workRoot 'micro-journal'
if (Test-Path -LiteralPath $microJournalRoot) {
    Get-ChildItem -LiteralPath $microJournalRoot -File | ForEach-Object { [IO.File]::Delete($_.FullName) }
} else {
    [void][IO.Directory]::CreateDirectory($microJournalRoot)
}

$entryCount = 2000
$oneLinePath = Join-Path $microJournalRoot 'oneline.jsonl'
$oneLineWriter = [CodexSafeTreeDelete.ThreadJournalWriter]::new($oneLinePath, 1, $evidenceHome)
$oneLineClock = [Diagnostics.Stopwatch]::StartNew()
$oneLineFlushCount = 0
$oneLineFlushMs = 0L
try {
    for ($i = 0; $i -lt $entryCount; $i++) {
        $oneLineWriter.WriteEntry(('{"op":"pending","path":"f-' + $i + '.txt"}'))
        $oneLineWriter.Flush()
    }
    $oneLineFlushCount = [int]$oneLineWriter.FlushCount
    $oneLineFlushMs = [int64]$oneLineWriter.TotalFlushTimeMs
} finally {
    $oneLineWriter.Dispose()
}
$oneLineClock.Stop()

$batchSizes = @(4, 8, 16, 32, 64)
$batchRows = @()
foreach ($batchSize in $batchSizes) {
    $batchPath = Join-Path $microJournalRoot ('batch-{0}.jsonl' -f $batchSize)
    $batchWriter = [CodexSafeTreeDelete.ThreadJournalWriter]::new($batchPath, 1, $evidenceHome)
    $batchClock = [Diagnostics.Stopwatch]::StartNew()
    $batchFlushCount = 0
    $batchFlushMs = 0L
    try {
        $pending = 0
        for ($i = 0; $i -lt $entryCount; $i++) {
            $batchWriter.WriteEntry(('{"op":"pending","path":"f-' + $i + '.txt"}'))
            $pending++
            if ($pending -ge $batchSize) {
                $batchWriter.Flush()
                $pending = 0
            }
        }
        if ($pending -gt 0) {
            $batchWriter.Flush()
        }
        $batchFlushCount = [int]$batchWriter.FlushCount
        $batchFlushMs = [int64]$batchWriter.TotalFlushTimeMs
    } finally {
        $batchWriter.Dispose()
    }
    $batchClock.Stop()
    $batchRows += [ordered]@{
        batchSize = [int]$batchSize
        entryCount = [int]$entryCount
        flushCount = [int]$batchFlushCount
        totalFlushTimeMs = [int64]$batchFlushMs
        wallMs = [int64]$batchClock.ElapsedMilliseconds
        flushMsPerEntry = [double]($batchFlushMs / [double]$entryCount)
        wallMsPerEntry = [double]($batchClock.ElapsedMilliseconds / [double]$entryCount)
    }
}

$verifyPath = Join-Path $microJournalRoot 'verify.jsonl'
$verifyWriter = [CodexSafeTreeDelete.ThreadJournalWriter]::new($verifyPath, 1, $evidenceHome)
$verifyReadMs = 0L
$verifyOpenCount = 0
try {
    for ($i = 0; $i -lt 250; $i++) {
        $line = '{"op":"pending","path":"v-' + $i + '.txt"}'
        $verifyWriter.WriteEntry($line)
        $verifyWriter.Flush()
        $readClock = [Diagnostics.Stopwatch]::StartNew()
        $stream = [IO.File]::Open($verifyPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
            try {
                $text = $reader.ReadToEnd()
                if ($text.IndexOf($line, [StringComparison]::Ordinal) -lt 0) {
                    throw 'pending not visible'
                }
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
        $readClock.Stop()
        $verifyReadMs += $readClock.ElapsedMilliseconds
        $verifyOpenCount++
    }
} finally {
    $verifyWriter.Dispose()
}

$scaleRows = @()
if (-not $SkipTenK) {
    $fileCount = 10000
    $filesPerDir = 2500
    foreach ($degree in @(1, 2, 4)) {
        $scaleTree = Join-Path $workRoot ('scale-10k-dop{0}-tree' -f $degree)
        $scaleJournal = Join-Path $workRoot ('scale-10k-dop{0}-journal' -f $degree)
        if (Test-Path -LiteralPath $scaleTree) {
            throw "leftover scale tree exists: $scaleTree"
        }
        [void][IO.Directory]::CreateDirectory($scaleJournal)
        for ($dirIndex = 0; $dirIndex -lt 4; $dirIndex++) {
            $dirPath = Join-Path $scaleTree ('dir-{0}' -f $dirIndex)
            [void][IO.Directory]::CreateDirectory($dirPath)
            for ($fileIndex = 0; $fileIndex -lt $filesPerDir; $fileIndex++) {
                [IO.File]::WriteAllText(
                    (Join-Path $dirPath ('f-{0:D4}.txt' -f $fileIndex)),
                    'x',
                    [Text.UTF8Encoding]::new($false))
            }
        }
        $coordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
            $scaleTree,
            $scaleJournal,
            $evidenceHome,
            (New-OptimizeCapabilities -Degree $degree))
        try {
            $result = $coordinator.Purge()
            $report = $result.JournalPerformance
        } finally {
            $coordinator.Dispose()
        }
        $remaining = @(Get-ChildItem -LiteralPath $scaleTree -Recurse -File -ErrorAction SilentlyContinue)
        $scaleRows += [ordered]@{
            degree = [int]$degree
            fileCount = [int]$result.FileCount
            deletedCount = [int]$result.DeletedCount
            failedCount = [int]$result.FailedCount
            remainingFiles = [int]$remaining.Count
            elapsedMs = [int64]$result.ElapsedMs
            totalFlushTimeMs = [int64]$report.TotalFlushTimeMs
            flushCount = [int]$report.FlushCount
            overheadPercent = [double]$report.OverheadPercent
            isWithinTarget = [bool]$report.IsWithinTarget
            slowFlushCount = [int]$report.SlowFlushCount
            warning = [string]$report.Warning
            meanFlushMs = [double]($report.TotalFlushTimeMs / [double]$report.FlushCount)
        }
        foreach ($leftover in $remaining) {
            [IO.File]::Delete($leftover.FullName)
        }
        Remove-EmptyDirectories -LiteralPath $scaleTree
    }
}

$record = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue41-flush-profile'
    measuredAtUtc = [DateTime]::UtcNow.ToString('o')
    codeBaseline = ('HEAD 5f7f597 plus #32/#40 uncommitted; output={0}; work={1}' -f $profileJsonPath, $workRoot)
    oneLine = [ordered]@{
        entryCount = [int]$entryCount
        flushCount = [int]$oneLineFlushCount
        totalFlushTimeMs = [int64]$oneLineFlushMs
        wallMs = [int64]$oneLineClock.ElapsedMilliseconds
        meanFlushMs = [double]($oneLineFlushMs / [double]$entryCount)
    }
    groupCommitMicro = $batchRows
    verifySecondHandle = [ordered]@{
        iterations = [int]$verifyOpenCount
        readToEndMs = [int64]$verifyReadMs
        meanReadMs = [double]($verifyReadMs / [double]$verifyOpenCount)
        note = 'ReadToEnd after each of 250 durable flushes; cost is not in TotalFlushTimeMs'
    }
    scale10k = $scaleRows
    analysisHint = 'Flush(true)/FlushFileBuffers dominates; group-commit of B pending then B commit should cut FlushCount from 2N to ~2N/B without deleting before pending durability.'
}

[IO.File]::WriteAllText(
    $profileJsonPath,
    ($record | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))

$record
