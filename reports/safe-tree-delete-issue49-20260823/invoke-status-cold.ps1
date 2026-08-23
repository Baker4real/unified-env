# One independent production Status cold start for issue #49. Not an authorization.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Index,
    [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$evidenceRoot = 'D:\Codex\.codex\run-evidence\safe-tree-delete'
$leftoverTx = Join-Path $evidenceRoot '20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json'
$expectedLeftoverSha = '4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7'
$leftoverId = '20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e'

function Get-EvidenceInventory {
    param([Parameter(Mandatory)][string]$Root)
    $dirs = @([IO.Directory]::GetDirectories($Root))
    $files = 0
    foreach ($unused in [IO.Directory]::EnumerateFiles($Root, '*', [IO.SearchOption]::AllDirectories)) {
        $files++
    }
    $leftoverSha = $null
    if ([IO.File]::Exists($leftoverTx)) {
        $leftoverSha = (Get-FileHash -LiteralPath $leftoverTx -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return [ordered]@{
        runDirectories = $dirs.Count
        files = $files
        leftoverTransactionSha256 = $leftoverSha
    }
}

[void][IO.Directory]::CreateDirectory($OutputDirectory)
$stdoutPath = Join-Path $OutputDirectory ("cold-{0}.stdout.json" -f $Index)
$stderrPath = Join-Path $OutputDirectory ("cold-{0}.stderr.txt" -f $Index)
$jsonPath = Join-Path $OutputDirectory ("cold-{0}.json" -f $Index)
$heartbeatPath = Join-Path $OutputDirectory ("cold-{0}.heartbeat.json" -f $Index)

$wrapperSha256 = $null
if ([IO.File]::Exists($entry)) {
    $wrapperSha256 = (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash.ToLowerInvariant()
}

$before = Get-EvidenceInventory -Root $evidenceRoot
$env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = '1'
$startedAtUtc = [datetimeoffset]::UtcNow
$exitCode = 1
$childId = $null
# UTF-8 stdout capture: the child pwsh encodes its redirected stdout with the attached
# console's output code page (OEM 936 on this host), which produced GBK-mangled
# cold-N.stdout.json captures in earlier rounds. Switch the shared console (-NoNewWindow)
# to 65001 before launch and restore afterwards; the capture is still strictly validated
# below and transcoded from 936 only if the child ignored the code page.
$previousOutputEncoding = $null
try {
    $previousOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
} catch {
    $previousOutputEncoding = $null
}
try {
    $process = Start-Process -FilePath $entry `
        -ArgumentList @('-Mode', 'Status', '-Json') `
        -WorkingDirectory (Split-Path -Parent $entry) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru -NoNewWindow -Wait
    $childId = [int]$process.Id
    $exitCode = [int]$process.ExitCode
} finally {
    $env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = $null
    if ($null -ne $previousOutputEncoding) {
        try { [Console]::OutputEncoding = $previousOutputEncoding } catch { }
    }
}

$finishedAtUtc = [datetimeoffset]::UtcNow
$after = Get-EvidenceInventory -Root $evidenceRoot
$wallClockSeconds = [math]::Round(($finishedAtUtc - $startedAtUtc).TotalSeconds, 3)

$stdoutStrictUtf8 = $true
$stdoutTranscodedFrom = $null
$stdoutText = $null
try {
    $stdoutText = [Text.UTF8Encoding]::new($false, $true).GetString(
        [IO.File]::ReadAllBytes($stdoutPath))
} catch {
    $stdoutStrictUtf8 = $false
}
if (-not $stdoutStrictUtf8) {
    [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    $stdoutText = [Text.Encoding]::GetEncoding(
        936,
        [System.Text.EncoderFallback]::ExceptionFallback,
        [System.Text.DecoderFallback]::ExceptionFallback).GetString(
        [IO.File]::ReadAllBytes($stdoutPath))
    [IO.File]::WriteAllText(
        $stdoutPath,
        $stdoutText,
        [Text.UTF8Encoding]::new($false))
    $stdoutTranscodedFrom = 936
}

$status = $null
$parseError = $null
try {
    $status = $stdoutText | ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
} catch {
    $parseError = $_.Exception.Message
}

$leftoverOp = $null
$purgedManualReview = 0
if ($null -ne $status) {
    $leftoverOp = @($status.operations | Where-Object operationId -ceq $leftoverId) | Select-Object -First 1
    $purgedManualReview = @($status.operations | Where-Object {
        $_.transactionStatus -ceq 'purged' -and $_.lifecycle -ceq 'manual-review'
    }).Count
}

$payload = [ordered]@{
    issue = 49
    runIndex = $Index
    kind = 'cold'
    whyCold = @(
        'new pwsh 7.6.4 process',
        'live invoke-safe-tree-delete.cmd -Mode Status -Json',
        'previous Status child process exited before this Start-Process',
        'no Status-owned disk cache',
        'OS standby list not flushed (not VSS, not EmptyStandbyList)'
    )
    entry = $entry
    wrapperSha256 = $wrapperSha256
    launcherPid = $PID
    childPid = $childId
    psEdition = [string]$PSVersionTable.PSEdition
    psVersion = [string]$PSVersionTable.PSVersion
    processPath = [string](Get-Process -Id $PID).Path
    startedAtUtc = $startedAtUtc.ToString('o')
    finishedAtUtc = $finishedAtUtc.ToString('o')
    wallClockSeconds = $wallClockSeconds
    exitCode = $exitCode
    stdoutStrictUtf8 = $stdoutStrictUtf8
    stdoutTranscodedFrom = $stdoutTranscodedFrom
    parseError = $parseError
    before = $before
    after = $after
    zeroWrite = (
        [int]$before.runDirectories -eq [int]$after.runDirectories -and
        [int]$before.files -eq [int]$after.files -and
        [string]$before.leftoverTransactionSha256 -ceq [string]$after.leftoverTransactionSha256
    )
    leftoverShaUnchanged = ([string]$after.leftoverTransactionSha256 -ceq $expectedLeftoverSha)
    leftoverLifecycle = if ($null -eq $leftoverOp) { $null } else { [string]$leftoverOp.lifecycle }
    leftoverInBlocking = if ($null -eq $status) {
        $null
    } else {
        $leftoverId -cin @($status.migrationReadiness.blockingRecords)
    }
    purgedManualReviewCount = $purgedManualReview
    complete = if ($null -eq $status) { $null } else { [bool]$status.complete }
    operationCount = if ($null -eq $status) { $null } else { @($status.operations).Count }
    blockingCount = if ($null -eq $status) { $null } else { @($status.migrationReadiness.blockingRecords).Count }
    entriesScanned = if ($null -eq $status) { $null } else { [long]$status.metrics.entriesScanned }
    bytesHashed = if ($null -eq $status) { $null } else { [long]$status.metrics.bytesHashed }
    elapsedMs = if ($null -eq $status) { $null } else { [long]$status.metrics.elapsedMs }
    capturedAtUtc = if ($null -eq $status) { $null } else { [string]$status.capturedAtUtc }
    statusSegments = if ($null -ne $status -and $null -ne $status.PSObject.Properties['statusSegments']) {
        $status.statusSegments
    } else {
        $null
    }
    metTarget = ($exitCode -eq 0 -and $null -eq $parseError -and $wallClockSeconds -lt 60)
}

[IO.File]::WriteAllText(
    $heartbeatPath,
    (([ordered]@{ atUtc = $finishedAtUtc.ToString('o'); childPid = $childId; exitCode = $exitCode }) | ConvertTo-Json -Depth 4),
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    $jsonPath,
    ($payload | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))

if ($exitCode -ne 0) {
    throw "Status cold-$Index failed with exit code $exitCode"
}
if ($null -ne $parseError) {
    throw "Status cold-$Index JSON parse failed: $parseError"
}

[pscustomobject]$payload
