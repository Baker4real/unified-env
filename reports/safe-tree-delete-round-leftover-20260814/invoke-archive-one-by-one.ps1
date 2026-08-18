# One-shot per-item Archive driver for this leftover report. Not a production Mode.
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
    throw 'wrapper hash mismatch; refuse live Archive'
}

$candidatesDocument = Get-Content -Raw -LiteralPath $CandidatesPath |
    ConvertFrom-Json -Depth 16 -DateKind String -ErrorAction Stop
$candidates = @($candidatesDocument.candidates | Where-Object { [bool]$_.archiveEligible })

$startedAtUtc = [datetimeoffset]::UtcNow
$counts = [ordered]@{
    attempted = 0
    succeeded = 0
    alreadyArchived = 0
    refused = 0
    failed = 0
}
$results = [System.Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $LogPath))
$logStream = [IO.File]::Open($LogPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try {
    $logWriter = [IO.StreamWriter]::new($logStream, $utf8)
    foreach ($candidate in $candidates) {
        $operationId = [string]$candidate.operationId
        $transactionPath = [string]$candidate.transactionPath
        $approvedSha256 = (Get-FileHash -LiteralPath $transactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record = [ordered]@{
            capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
            operationId = $operationId
            source = [string]$candidate.source
            transactionPath = $transactionPath
            approvedTransactionSha256 = $approvedSha256
            candidateSha256 = [string]$candidate.transactionSha256
            sha256MatchedCandidate = ($approvedSha256 -ceq [string]$candidate.transactionSha256)
            archived = $false
            alreadyArchived = $false
            refusalReason = $null
            error = $null
            exitCode = $null
            archivePath = $null
        }
        $counts.attempted = [int]$counts.attempted + 1
        try {
            $raw = & $entry `
                -Mode Archive `
                -TransactionPath $transactionPath `
                -ApprovedTransactionSha256 $approvedSha256 `
                -ConfirmArchive `
                -Json
            $record.exitCode = $LASTEXITCODE
            if ($null -eq $raw) {
                throw 'Archive returned empty stdout'
            }
            $text = if ($raw -is [System.Array]) { [string]::Join("`n", @($raw)) } else { [string]$raw }
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
                $record.exitCode = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 1 }
            }
            $counts.failed = [int]$counts.failed + 1
        }
        $results.Add([pscustomobject]$record)
        $logWriter.WriteLine(($record | ConvertTo-Json -Depth 8 -Compress))
        $logWriter.Flush()
    }
} finally {
    if ($null -ne $logWriter) { $logWriter.Dispose() }
    else { $logStream.Dispose() }
}

$summary = [ordered]@{
    snapshot = $true
    note = '逐条 Archive 调用记录快照，不构成后续授权。create-only marker。未新增 BatchArchive。'
    startedAtUtc = $startedAtUtc.ToString('o')
    finishedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    wrapper = $wrapperState
    counts = $counts
    results = $results
}
[IO.File]::WriteAllText(
    $SummaryPath,
    ($summary | ConvertTo-Json -Depth 8),
    $utf8)
Write-Output ($counts | ConvertTo-Json -Compress)
if ([int]$counts.failed -gt 0) { exit 1 }
exit 0
