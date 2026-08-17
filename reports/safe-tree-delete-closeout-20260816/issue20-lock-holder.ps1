# Holds FileShare.Read on a quarantine payload after transaction.json becomes purging.
# Used only by the issue #20 production Purge-failure harness. Not a production entry.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TransactionPath,
    [Parameter(Mandatory)][string]$PayloadPath,
    [Parameter(Mandatory)][string]$AcquiredMarkerPath,
    [Parameter(Mandatory)][string]$ReleaseSignalPath,
    [Parameter(Mandatory)][string]$LogPath,
    [int]$TimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-LockLog {
    param([string]$Message)
    $line = '{0} {1}' -f [datetimeoffset]::UtcNow.ToString('o'), $Message
    [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

Write-LockLog 'lock-holder-start'
$deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
$stream = $null
try {
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ReleaseSignalPath) {
            Write-LockLog 'release-before-acquire'
            exit 3
        }
        if (Test-Path -LiteralPath $TransactionPath) {
            try {
                $raw = [IO.File]::ReadAllText($TransactionPath)
                $tx = $raw | ConvertFrom-Json -Depth 8 -DateKind String
                if ([string]$tx.status -ceq 'purging') {
                    Write-LockLog 'saw-purging'
                    $stream = [IO.File]::Open(
                        $PayloadPath,
                        [IO.FileMode]::Open,
                        [IO.FileAccess]::Read,
                        [IO.FileShare]::Read)
                    [IO.File]::WriteAllText(
                        $AcquiredMarkerPath,
                        [datetimeoffset]::UtcNow.ToString('o'),
                        [Text.UTF8Encoding]::new($false))
                    Write-LockLog 'acquired'
                    while (-not (Test-Path -LiteralPath $ReleaseSignalPath)) {
                        if ([datetime]::UtcNow -ge $deadline) {
                            Write-LockLog 'timeout-holding'
                            exit 4
                        }
                        Start-Sleep -Milliseconds 50
                    }
                    Write-LockLog 'released'
                    exit 0
                }
            } catch {
                Write-LockLog ('parse-or-open-retry: ' + $_.Exception.Message)
            }
        }
        Start-Sleep -Milliseconds 5
    }
    Write-LockLog 'timeout-waiting-purging'
    exit 2
} finally {
    if ($null -ne $stream) {
        $stream.Dispose()
    }
}
