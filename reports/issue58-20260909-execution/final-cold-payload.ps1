$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = '1'
$setup = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'prepare-runtime.ps1')
$setup.Stop()
$watch = [Diagnostics.Stopwatch]::StartNew()
$exitCode = $null
$errorText = $null
try {
    & (Join-Path $repo 'scripts/Invoke-CodexSafeTreeDelete.ps1') -Mode Status -Json
    $exitCode = if (Test-Path Variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
} catch {
    $errorText = $_.Exception.Message
    $exitCode = 1
} finally {
    $watch.Stop()
    $result = [ordered]@{
        payload = 'final-cold'
        setupMs = $setup.ElapsedMilliseconds
        statusElapsedMs = $watch.ElapsedMilliseconds
        entryExitCode = $exitCode
        error = $errorText
    }
    [IO.File]::WriteAllText(
        (Join-Path $env:ISSUE58_RUN_ROOT 'final-cold-metrics.json'),
        ($result | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
}
exit $exitCode
