#Requires -Version 7.5
<#
.SYNOPSIS
Watch for new wsl.exe processes for a bounded period and record launch provenance.
.DESCRIPTION
Writes monitor events to events.jsonl and a bounded summary to result.json under a new D drive EvidenceDirectory.
The target command line is recorded; parent and grandparent records omit command lines to limit unrelated secrets.
Polling can miss a process that starts and exits between samples. No process is started, stopped or changed by this tool.
ProcessNameForTest exists for isolated tests; production use should retain the default wsl.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateRange(5, 3600)][int]$DurationSeconds = 600,
    [ValidateRange(100, 2000)][int]$PollMilliseconds = 250,
    [switch]$StopAfterFirst,
    [ValidatePattern('^[A-Za-z0-9_.-]+\.exe$')][string]$ProcessNameForTest = 'wsl.exe'
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$ownerToken = [Environment]::GetEnvironmentVariable('DSH_WSL_WATCH_OWNER_TOKEN')
$ownerTokenSha256 = $null
if (-not [string]::IsNullOrEmpty($ownerToken)) {
    $ownerTokenSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($ownerToken))).ToLowerInvariant()
}

if (-not [IO.Path]::IsPathFullyQualified($EvidenceDirectory)) { throw 'EvidenceDirectory must be an absolute D drive path.' }
$directory = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not $directory.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase) -or $directory.Length -le 3) {
    throw 'EvidenceDirectory must resolve to a new D drive directory.'
}
if (Test-Path -LiteralPath $directory) { throw "EvidenceDirectory already exists: $directory" }
[void][IO.Directory]::CreateDirectory($directory)
$eventLog = Join-Path $directory 'events.jsonl'
$resultPath = Join-Path $directory 'result.json'

function Write-Event([Collections.IDictionary]$Record) {
    $Record['observedAt'] = [DateTime]::UtcNow.ToString('o')
    [IO.File]::AppendAllText($eventLog, ((ConvertTo-Json -InputObject $Record -Depth 7 -Compress) + "`n"), $utf8)
}
function Get-ProcessKey($Process) {
    '{0}:{1}' -f $Process.ProcessId, $Process.CreationDate.ToUniversalTime().Ticks
}
function Convert-ProcessRecord($Process, [bool]$IncludeCommandLine) {
    [ordered]@{
        name = $Process.Name
        processId = $Process.ProcessId
        parentProcessId = $Process.ParentProcessId
        executablePath = $Process.ExecutablePath
        commandLine = if ($IncludeCommandLine) { $Process.CommandLine } else { $null }
        creationDate = $Process.CreationDate.ToUniversalTime().ToString('o')
    }
}
function Get-ProcessById([uint32]$ProcessId) {
    Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop | Select-Object -First 1
}
function Get-WatchedProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='$ProcessNameForTest'" -ErrorAction Stop)
}

$result = [ordered]@{
    status = 'running'
    processName = $ProcessNameForTest
    ownerTokenSha256 = $ownerTokenSha256
    startedAt = [DateTime]::UtcNow.ToString('o')
    endedAt = $null
    durationSeconds = $DurationSeconds
    pollMilliseconds = $PollMilliseconds
    baselineCount = 0
    processSeen = $false
    eventCount = 0
    stopReason = $null
    eventLog = $eventLog
    evidenceDirectory = $directory
    error = $null
}

try {
    $baseline = @(Get-WatchedProcesses)
    $seen = @{}
    foreach ($process in $baseline) { $seen[(Get-ProcessKey $process)] = $true }
    $result['baselineCount'] = $baseline.Count
    Write-Event ([ordered]@{
        kind = 'monitor-start'
        ownerTokenSha256 = $ownerTokenSha256
        baseline = @($baseline | ForEach-Object { Convert-ProcessRecord $_ $true })
    })

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $stopAfterCapture = $false
    while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds) {
        foreach ($process in @(Get-WatchedProcesses)) {
            $key = Get-ProcessKey $process
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $parent = if ($process.ParentProcessId) { Get-ProcessById $process.ParentProcessId } else { $null }
            $grandparent = if ($null -ne $parent -and $parent.ParentProcessId) { Get-ProcessById $parent.ParentProcessId } else { $null }
            Write-Event ([ordered]@{
                kind = 'process-start'
                process = (Convert-ProcessRecord $process $true)
                parent = if ($null -ne $parent) { Convert-ProcessRecord $parent $false } else { $null }
                grandparent = if ($null -ne $grandparent) { Convert-ProcessRecord $grandparent $false } else { $null }
            })
            $result['processSeen'] = $true
            $result['eventCount']++
            if ($StopAfterFirst) {
                $stopAfterCapture = $true
                break
            }
        }
        if ($stopAfterCapture) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    $result['stopReason'] = if ($stopAfterCapture) { 'first-process' } else { 'duration-elapsed' }
    $result['status'] = 'complete'
    Write-Event ([ordered]@{kind = 'monitor-end'; eventCount = $result['eventCount']})
}
catch {
    $result['status'] = 'failed'
    $result['stopReason'] = 'error'
    $result['error'] = $_.Exception.Message
}
finally {
    $result['endedAt'] = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($resultPath, (ConvertTo-Json -InputObject $result -Depth 6), $utf8)
}

ConvertTo-Json -InputObject $result -Depth 6 -Compress
if ($result['status'] -ne 'complete') { exit 1 }
