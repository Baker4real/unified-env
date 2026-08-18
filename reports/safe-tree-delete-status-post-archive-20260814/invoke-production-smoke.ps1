# Capture-only ProductionSmoke runner for issue #24. Not an authorization beyond the test's managed Plan/Apply/Purge.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = 'D:\Codex\projects\统一环境'
$testPath = Join-Path $projectRoot 'tests\Test-CodexSafeTreeDeleteProductionSmoke.ps1'
$stdoutPath = [IO.Path]::ChangeExtension($OutputJsonPath, '.stdout.txt')
$stderrPath = [IO.Path]::ChangeExtension($OutputJsonPath, '.stderr.txt')
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputJsonPath))

$startedAtUtc = [datetimeoffset]::UtcNow
$p = Start-Process -FilePath 'pwsh' `
    -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $testPath) `
    -WorkingDirectory $projectRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru -NoNewWindow -Wait
$finishedAtUtc = [datetimeoffset]::UtcNow
$exitCode = [int]$p.ExitCode

$stdoutText = ''
if ([IO.File]::Exists($stdoutPath)) {
    $stdoutText = [IO.File]::ReadAllText($stdoutPath)
}

$parsed = $null
$parseError = $null
try {
    $parsed = $stdoutText | ConvertFrom-Json -Depth 32 -DateKind String
} catch {
    $parseError = [string]$_.Exception.Message
}

$meta = [ordered]@{
    snapshot = $true
    note = 'ProductionSmoke 运行记录。其新 operation 不属于归档收敛判定集。'
    issue = 24
    testPath = $testPath
    startedAtUtc = $startedAtUtc.ToString('o')
    finishedAtUtc = $finishedAtUtc.ToString('o')
    wallClockSeconds = [math]::Round(($finishedAtUtc - $startedAtUtc).TotalSeconds, 3)
    exitCode = $exitCode
    stdoutBytes = if ([IO.File]::Exists($stdoutPath)) { [long](Get-Item -LiteralPath $stdoutPath).Length } else { 0 }
    stderrBytes = if ([IO.File]::Exists($stderrPath)) { [long](Get-Item -LiteralPath $stderrPath).Length } else { 0 }
    parseError = $parseError
    result = $parsed
}
[IO.File]::WriteAllText(
    $OutputJsonPath,
    ($meta | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))

if ($exitCode -ne 0) {
    throw "ProductionSmoke failed with exit code $exitCode"
}

[pscustomobject]$meta
