[CmdletBinding()]
param(
    [ValidateRange(1000, 7200000)][int]$DeadlineMs = 3600000,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'cold-run-result.json'),
    [string]$StdoutPath = (Join-Path $PSScriptRoot 'cold-run-stdout.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'D:\agents\projects\统一环境'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$entry = Join-Path $repo 'scripts\Invoke-CodexSafeTreeDelete.ps1'

foreach ($writePath in @($OutputPath, $StdoutPath)) {
    $full = [IO.Path]::GetFullPath($writePath)
    if ($full.StartsWith($evidenceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cold-run output must be outside the observed evidence root.'
    }
}

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = $repo
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $entry, '-Mode', 'Status', '-Json')) {
    [void]$psi.ArgumentList.Add($argument)
}
$psi.EnvironmentVariables['CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS'] = '1'

$result = [ordered]@{
    artifactType = 'issue58.n1-cold-run'
    startedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    deadlineMs = $DeadlineMs
    entry = $entry
    executable = $psi.FileName
    processId = $null
    elapsedMs = $null
    timedOut = $false
    exitCode = $null
    stdoutBytes = 0
    stderr = ''
    parseSucceeded = $false
    complete = $null
    operationCount = $null
    statusSha256 = $null
    semanticSha256 = $null
    segments = $null
    metrics = $null
    error = $null
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $psi
$watch = [Diagnostics.Stopwatch]::StartNew()
$started = $false
try {
    $started = $process.Start()
    if (-not $started) { throw 'Cold Status process did not start.' }
    $result.processId = $process.Id
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($DeadlineMs)) {
        $result.timedOut = $true
        if (-not $process.HasExited) { $process.Kill($true) }
        if (-not $process.WaitForExit(10000)) {
            throw 'Owned Cold Status process did not exit after Kill(entireProcessTree: true).'
        }
    }
    $watch.Stop()
    $result.elapsedMs = [long]$watch.ElapsedMilliseconds
    $result.exitCode = [int]$process.ExitCode
    if (-not [Threading.Tasks.Task]::WaitAll(
            [Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 30000)) {
        throw 'Cold Status output pipes did not close within 30000 ms after process exit.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $result.stderr = $stderrTask.GetAwaiter().GetResult()
    $result.stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
    $result.statusSha256 = Get-TextSha256 -Text $stdout
    [IO.File]::WriteAllText($StdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
    if ($result.timedOut) { throw "Cold Status exceeded the $DeadlineMs ms deadline." }
    if ($result.exitCode -ne 0) { throw "Cold Status exited with code $($result.exitCode): $($result.stderr)" }
    $parsed = ConvertFrom-Json -InputObject $stdout -AsHashtable -Depth 128 -DateKind String
    if ($null -eq $parsed -or $parsed -isnot [Collections.IDictionary] -or
        $parsed.artifactType -cne 'env-governance.codex-safe-tree-delete-status' -or
        $parsed.schemaVersion -ne 1 -or $parsed.operations -isnot [array]) {
        throw 'Cold Status output did not match the Status JSON contract.'
    }
    $result.parseSucceeded = $true
    $result.complete = [bool]$parsed.complete
    $result.operationCount = $parsed.operations.Count
    if ($parsed.Contains('statusSegments')) { $result.segments = $parsed['statusSegments'] }
    if ($parsed.Contains('metrics')) { $result.metrics = $parsed['metrics'] }
    [void]$parsed.Remove('capturedAtUtc')
    [void]$parsed.Remove('metrics')
    [void]$parsed.Remove('statusSegments')
    $result.semanticSha256 = Get-TextSha256 -Text ($parsed | ConvertTo-Json -Depth 100 -Compress)
} catch {
    $result.error = $_.Exception.Message
} finally {
    if ($started -and -not $process.HasExited) {
        try { $process.Kill($true) } catch { }
    }
    if ($started -and $process.HasExited -and $null -eq $result.exitCode) {
        $result.exitCode = [int]$process.ExitCode
    }
    $watch.Stop()
    if ($null -eq $result.elapsedMs) { $result.elapsedMs = [long]$watch.ElapsedMilliseconds }
    $process.Dispose()
}
$result.finishedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
$json = $result | ConvertTo-Json -Depth 16
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output ("elapsedMs={0} timedOut={1} exitCode={2} stdoutBytes={3} ops={4} error={5}" -f
    $result.elapsedMs, $result.timedOut, $result.exitCode, $result.stdoutBytes,
    $result.operationCount, $result.error)
Write-Output 'cold-run-done'
