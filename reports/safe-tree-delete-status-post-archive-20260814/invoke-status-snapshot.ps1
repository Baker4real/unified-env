# Snapshot-only production Status capture for issue #24. Not an authorization.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$stderrPath = [IO.Path]::ChangeExtension($OutputPath, '.stderr.txt')
$metaPath = [IO.Path]::ChangeExtension($OutputPath, '.meta.json')
$heartbeatPath = [IO.Path]::ChangeExtension($OutputPath, '.heartbeat.json')
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))

function Write-Heartbeat {
    param([string]$State, [Nullable[int]]$ChildId)
    $beat = [ordered]@{
        snapshot = $true
        atUtc = [datetimeoffset]::UtcNow.ToString('o')
        state = $State
        launcherPid = $PID
        childPid = $ChildId
    }
    [IO.File]::WriteAllText(
        $heartbeatPath,
        ($beat | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
}

$startedAtUtc = [datetimeoffset]::UtcNow
Write-Heartbeat -State 'starting' -ChildId $null
$exitCode = 1
$childId = $null
try {
    $process = Start-Process -FilePath $entry `
        -ArgumentList @('-Mode', 'Status', '-Json') `
        -WorkingDirectory (Split-Path -Parent $entry) `
        -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $stderrPath `
        -PassThru -NoNewWindow -Wait
    $childId = [int]$process.Id
    $exitCode = [int]$process.ExitCode
    Write-Heartbeat -State 'child-exited' -ChildId $childId
} catch {
    Write-Heartbeat -State 'launcher-error' -ChildId $childId
    throw
} finally {
    $stderrBytes = 0L
    if ([IO.File]::Exists($stderrPath)) {
        $stderrBytes = [long](Get-Item -LiteralPath $stderrPath).Length
    }
    $stdoutBytes = 0L
    $outputSha256 = $null
    if ([IO.File]::Exists($OutputPath)) {
        $stdoutBytes = [long](Get-Item -LiteralPath $OutputPath).Length
        if ($stdoutBytes -gt 0L) {
            $outputSha256 = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $meta = [ordered]@{
        snapshot = $true
        note = 'Status 快照，不构成后续授权。判定用 Status 应对证据根零写入。'
        issue = 24
        entry = $entry
        mode = 'Status'
        json = $true
        startedAtUtc = $startedAtUtc.ToString('o')
        finishedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        wallClockSeconds = [math]::Round(([datetimeoffset]::UtcNow - $startedAtUtc).TotalSeconds, 3)
        exitCode = $exitCode
        childPid = $childId
        stdoutBytes = $stdoutBytes
        stderrBytes = $stderrBytes
        outputSha256 = $outputSha256
    }
    [IO.File]::WriteAllText(
        $metaPath,
        ($meta | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
}

if ($exitCode -ne 0) {
    throw "Status snapshot failed with exit code $exitCode"
}

[pscustomobject]$meta
