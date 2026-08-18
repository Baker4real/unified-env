[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
Set-Location -LiteralPath $projectRoot

$files = @(
    'scripts/lib/CodexSafeTreeDeleteThreadJournal.cs',
    'scripts/lib/CodexSafeTreeDeleteParallelPurge.cs',
    'tests/Test-CodexSafeTreeDeleteJournalPerformance.ps1',
    'reports/safe-tree-delete-issue41-20260817/invoke-issue41.ps1',
    'reports/safe-tree-delete-issue41-20260817/invoke-diffcheck.ps1'
)

# These files are still untracked on this dirty worktree. `git diff --check -- <path>`
# is a no-op for untracked paths, so check each file against NUL.
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
