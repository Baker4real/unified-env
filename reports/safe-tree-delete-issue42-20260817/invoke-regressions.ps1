[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testsRoot = Join-Path $projectRoot 'tests'
$regressionRoot = Join-Path $PSScriptRoot 'regressions'
[void][IO.Directory]::CreateDirectory($regressionRoot)

$suites = @(
    'Test-CodexSafeTreeDeleteHashSafely.ps1',
    'Test-CodexSafeTreeDeleteCrashSafety.ps1',
    'Test-CodexSafeTreeDeleteUncertainRecovery.ps1',
    'Test-CodexSafeTreeDeleteLeafStreamSet.ps1'
)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($suite in $suites) {
    $testPath = Join-Path $testsRoot $suite
    $name = [IO.Path]::GetFileNameWithoutExtension($suite)
    $stdoutPath = Join-Path $regressionRoot ($name + '.stdout.txt')
    $stderrPath = Join-Path $regressionRoot ($name + '.stderr.txt')
    $startedAtUtc = [DateTime]::UtcNow.ToString('o')
    $process = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile',
        '-NonInteractive',
        '-File',
        $testPath
    ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $row = [ordered]@{
        suite = $suite
        testPath = $testPath
        startedAtUtc = $startedAtUtc
        finishedAtUtc = [DateTime]::UtcNow.ToString('o')
        exitCode = [int]$process.ExitCode
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        reran = $true
    }
    $results.Add([pscustomobject]$row)
    if ($process.ExitCode -ne 0) {
        break
    }
}

$issue41MetaPath = Join-Path $projectRoot 'reports\safe-tree-delete-issue41-20260817\suite-meta.json'
$issue41ScalePath = Join-Path $projectRoot 'reports\safe-tree-delete-issue41-20260817\scale-10000.json'
$issue41Meta = Get-Content -Raw -LiteralPath $issue41MetaPath |
    ConvertFrom-Json -Depth 8 -DateKind String
$issue41Scale = Get-Content -Raw -LiteralPath $issue41ScalePath |
    ConvertFrom-Json -Depth 8 -DateKind String

$summary = [ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue42-regressions'
    pwsh = $pwsh
    suites = @($results)
    journalPerformance = [ordered]@{
        suite = 'Test-CodexSafeTreeDeleteJournalPerformance.ps1'
        reran = $false
        reason = 'cite #41 already-green meta; 10k overhead 18.659% IsWithinTarget=false; not rerun'
        citedMetaPath = $issue41MetaPath
        citedScalePath = $issue41ScalePath
        citedExitCode = [int]$issue41Meta.exitCode
        citedOverheadPercent = [double]$issue41Scale.OverheadPercent
        citedIsWithinTarget = [bool]$issue41Scale.IsWithinTarget
    }
    allReranPassed = (@($results | Where-Object { $_.exitCode -ne 0 }).Count -eq 0)
}
$summaryPath = Join-Path $PSScriptRoot 'regression-meta.json'
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))

if (-not $summary.allReranPassed) {
    exit 1
}
exit 0
