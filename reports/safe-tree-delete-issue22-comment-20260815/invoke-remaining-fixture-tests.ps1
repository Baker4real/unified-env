#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportDir = $PSScriptRoot
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $reportDir '..\..')).Path
$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$tests = @(
    'tests\Test-CodexSafeTreeDeleteIdentityV2.ps1',
    'tests\Test-CodexSafeTreeDeletePlanIdentityV2.ps1',
    'tests\Test-CodexSafeTreeDeleteHashSafely.ps1',
    'tests\Test-CodexSafeTreeDeleteFileSystem.ps1',
    'tests\Test-CodexSafeTreeDeleteStatus.ps1'
)

if (-not [IO.File]::Exists($pwsh)) {
    throw "pwsh not found: $pwsh"
}

$startedAtUtc = [datetimeoffset]::UtcNow
$results = [System.Collections.Generic.List[object]]::new()

foreach ($relative in $tests) {
    $testPath = Join-Path $repoRoot $relative
    $stem = [IO.Path]::GetFileNameWithoutExtension($relative)
    $stdoutPath = Join-Path $reportDir ($stem + '.stdout.txt')
    $stderrPath = Join-Path $reportDir ($stem + '.stderr.txt')
    $metaPath = Join-Path $reportDir ($stem + '.meta.json')
    $started = [datetimeoffset]::UtcNow
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $pwsh -NoProfile -NonInteractive -File $testPath 1> $stdoutPath 2> $stderrPath
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
    } finally {
        $ErrorActionPreference = $previousEap
    }
    $finished = [datetimeoffset]::UtcNow
    $stdoutBytes = if ([IO.File]::Exists($stdoutPath)) { [int]((Get-Item -LiteralPath $stdoutPath).Length) } else { 0 }
    $stderrBytes = if ([IO.File]::Exists($stderrPath)) { [int]((Get-Item -LiteralPath $stderrPath).Length) } else { 0 }
    $row = [ordered]@{
        test = $relative
        testPath = $testPath
        exitCode = $exitCode
        startedAtUtc = $started.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        wallClockSeconds = [math]::Round(($finished - $started).TotalSeconds, 3)
        stdoutBytes = $stdoutBytes
        stderrBytes = $stderrBytes
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
    }
    ($row | ConvertTo-Json -Depth 6) + [Environment]::NewLine |
        Set-Content -LiteralPath $metaPath -Encoding utf8NoBOM
    $results.Add([pscustomobject]$row)
    Write-Output ("EXIT {0} {1} {2}s" -f $exitCode, $relative, $row.wallClockSeconds)
}

$finishedAtUtc = [datetimeoffset]::UtcNow
$summary = [ordered]@{
    snapshot = $true
    note = 'Issue #22 允许的剩余 fixture。未跑 ProductionSmoke，未跑 host-safety 全量 runner。失败不改生产实现。'
    pwsh = $pwsh
    repoRoot = $repoRoot
    startedAtUtc = $startedAtUtc.ToString('o')
    finishedAtUtc = $finishedAtUtc.ToString('o')
    wallClockSeconds = [math]::Round(($finishedAtUtc - $startedAtUtc).TotalSeconds, 3)
    results = @($results)
    anyNonZero = [bool](@($results | Where-Object { $_.exitCode -ne 0 }).Count -gt 0)
}
$summaryPath = Join-Path $reportDir 'fixture-tests-summary.json'
($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine |
    Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
Write-Output ("SUMMARY " + $summaryPath)
if ($summary.anyNonZero) { exit 1 }
exit 0
