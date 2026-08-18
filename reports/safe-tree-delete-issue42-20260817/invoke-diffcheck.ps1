[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
Set-Location -LiteralPath $projectRoot

$files = @(
    'tests/Test-CodexSafeTreeDeletePhase3Integration.ps1',
    'reports/safe-tree-delete-issue42-20260817/invoke-issue42.ps1',
    'reports/safe-tree-delete-issue42-20260817/invoke-regressions.ps1',
    'reports/safe-tree-delete-issue42-20260817/invoke-diffcheck.ps1',
    'reports/safe-tree-delete-issue42-20260817/scale-phase3.json',
    'reports/safe-tree-delete-issue42-20260817/baseline-partial.json',
    'reports/safe-tree-delete-issue42-20260817/phase3-prod-attempts.json',
    'reports/safe-tree-delete-issue42-20260817/phase3-prod-failure.json',
    'reports/safe-tree-delete-issue42-20260817/filesystem-probe.json',
    'reports/safe-tree-delete-issue42-20260817/coordinator-journal.json',
    'reports/safe-tree-delete-issue42-20260817/leftover-guard.json',
    'reports/safe-tree-delete-issue42-20260817/first-attempt-failure.json',
    'reports/safe-tree-delete-issue42-20260817/1kb-apply-failures.md',
    'reports/safe-tree-delete-issue42-20260817/CLOSEABLE.md',
    'reports/safe-tree-delete-issue42-20260817/suite-meta.json',
    'reports/safe-tree-delete-issue42-20260817/regression-meta.json',
    'reports/safe-tree-delete-issue42-20260817/git-diff-check.json'
)

$failed = $false
foreach ($file in $files) {
    $raw = git -c core.safecrlf=false diff --check --no-index -- NUL $file 2>&1 | Out-String
    if ($raw -match 'trailing whitespace|space before tab|conflict marker') {
        Write-Output $raw
        $failed = $true
    }
}

if ($failed) {
    Write-Output 'DIFFCHECK_EXIT=1'
    exit 1
}

Write-Output 'DIFFCHECK_EXIT=0'
exit 0
