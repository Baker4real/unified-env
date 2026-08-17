# One-shot per-item Archive driver for issue #22. Not a production Mode.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidatesPath,
    [Parameter(Mandatory)][string]$LogPath,
    [Parameter(Mandatory)][string]$SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$hostWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
$repoWrapper = 'D:\Codex\projects\统一环境\scripts\invoke-codex-safe-tree-delete-host.ps1'

function Get-WrapperHashState {
    $hostSha256 = (Get-FileHash -LiteralPath $hostWrapper -Algorithm SHA256).Hash.ToLowerInvariant()
    $repoSha256 = (Get-FileHash -LiteralPath $repoWrapper -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject][ordered]@{
        capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        hostWrapper = $hostWrapper
        repoWrapper = $repoWrapper
        hostSha256 = $hostSha256
        repoSha256 = $repoSha256
        match = ($hostSha256 -ceq $repoSha256)
    }
}

$wrapperState = Get-WrapperHashState
if (-not [bool]$wrapperState.match) {
    $blocked = [ordered]@{
        snapshot = $true
        result = 'BLOCKED'
        reason = 'wrapper-hash-drift'
        wrapper = $wrapperState
    }
    [IO.File]::WriteAllText(
        $SummaryPath,
        ($blocked | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
    throw 'wrapper hash mismatch; refuse live Archive'
}

$candidatesDocument = Get-Content -Raw -LiteralPath $CandidatesPath |
    ConvertFrom-Json -Depth 16 -DateKind String -ErrorAction Stop
$candidates = @($candidatesDocument.candidates)
$completedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if ([IO.File]::Exists($LogPath)) {
    foreach ($line in [IO.File]::ReadLines($LogPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $prior = $line | ConvertFrom-Json -Depth 8 -DateKind String -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$prior.operationId)) {
            [void]$completedIds.Add([string]$prior.operationId)
        }
    }
}

$startedAtUtc = [datetimeoffset]::UtcNow
$counts = [ordered]@{
    attempted = 0
    succeeded = 0
    alreadyArchived = 0
    refused = 0
    failed = 0
    skippedAlreadyLogged = 0
}
$logDirectory = Split-Path -Parent $LogPath
[void][IO.Directory]::CreateDirectory($logDirectory)
$utf8 = [Text.UTF8Encoding]::new($false)
$logStream = [IO.File]::Open($LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try {
    $logWriter = [IO.StreamWriter]::new($logStream, $utf8)
    foreach ($candidate in $candidates) {
        $operationId = [string]$candidate.operationId
        if ($completedIds.Contains($operationId)) {
            $counts.skippedAlreadyLogged = [int]$counts.skippedAlreadyLogged + 1
            continue
        }

        $transactionPath = [string]$candidate.transactionPath
        $approvedSha256 = (Get-FileHash -LiteralPath $transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record = [ordered]@{
            capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
            operationId = $operationId
            transactionPath = $transactionPath
            approvedTransactionSha256 = $approvedSha256
            archived = $false
            alreadyArchived = $false
            refusalReason = $null
            error = $null
            exitCode = $null
            archivePath = $null
        }
        $counts.attempted = [int]$counts.attempted + 1
        try {
            $mode = 'Archive'
            $argumentList = @(
                '-Mode', $mode,
                '-TransactionPath', $transactionPath,
                '-ApprovedTransactionSha256', $approvedSha256,
                '-ConfirmArchive',
                '-Json'
            )
            $raw = & $entry @argumentList
            $record.exitCode = $LASTEXITCODE
            if ($null -eq $raw) {
                throw 'Archive returned empty stdout'
            }
            $text = if ($raw -is [System.Array]) { [string]::Join('', @($raw)) } else { [string]$raw }
            $result = $text | ConvertFrom-Json -Depth 12 -DateKind String -ErrorAction Stop
            if (@($result.PSObject.Properties.Name) -contains 'archived') {
                $record.archived = [bool]$result.archived
            }
            if (@($result.PSObject.Properties.Name) -contains 'alreadyArchived') {
                $record.alreadyArchived = [bool]$result.alreadyArchived
            }
            if (@($result.PSObject.Properties.Name) -contains 'refusalReason') {
                $record.refusalReason = [string]$result.refusalReason
            }
            if (@($result.PSObject.Properties.Name) -contains 'archivePath') {
                $record.archivePath = [string]$result.archivePath
            }
            if ([bool]$record.alreadyArchived) {
                $counts.alreadyArchived = [int]$counts.alreadyArchived + 1
            } elseif ([bool]$record.archived) {
                $counts.succeeded = [int]$counts.succeeded + 1
            } else {
                $counts.refused = [int]$counts.refused + 1
            }
        } catch {
            $record.error = $_.Exception.Message
            if ($null -eq $record.exitCode) {
                $record.exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
            }
            $counts.failed = [int]$counts.failed + 1
        }

        $line = ($record | ConvertTo-Json -Depth 8 -Compress)
        $logWriter.WriteLine($line)
        $logWriter.Flush()
        [void]$completedIds.Add($operationId)
        $progress = [ordered]@{
            snapshot = $true
            updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
            attempted = [int]$counts.attempted
            succeeded = [int]$counts.succeeded
            alreadyArchived = [int]$counts.alreadyArchived
            refused = [int]$counts.refused
            failed = [int]$counts.failed
            lastOperationId = $operationId
        }
        [IO.File]::WriteAllText(
            ([IO.Path]::ChangeExtension($LogPath, '.progress.json')),
            ($progress | ConvertTo-Json -Depth 6),
            [Text.UTF8Encoding]::new($false))
    }
} finally {
    if ($null -ne $logWriter) { $logWriter.Dispose() }
    else { $logStream.Dispose() }
}

$summary = [ordered]@{
    snapshot = $true
    note = '逐条 Archive 调用记录。每条现场重算 SHA-256 并自带 ConfirmArchive。未新增 BatchArchive。'
    startedAtUtc = $startedAtUtc.ToString('o')
    finishedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    wallClockSeconds = [math]::Round(([datetimeoffset]::UtcNow - $startedAtUtc).TotalSeconds, 3)
    entry = $entry
    candidatesPath = $CandidatesPath
    liveCandidateCount = $candidates.Count
    wrapper = $wrapperState
    counts = $counts
}
[IO.File]::WriteAllText(
    $SummaryPath,
    ($summary | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))

[pscustomobject]$summary
