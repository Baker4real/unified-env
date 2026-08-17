[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..')
$paths = @(
    'scripts/lib/CodexSafeTreeDeleteThreadJournal.cs',
    'scripts/lib/CodexSafeTreeDelete.ps1',
    'tests/Test-CodexSafeTreeDeleteThreadJournal.ps1',
    'modules/manifest.json',
    'modules/host-safety/CONTEXT.md',
    'reports/safe-tree-delete-issue38-20260817/CLOSEABLE.md',
    'reports/safe-tree-delete-issue38-20260817/invoke-issue38.ps1',
    'reports/safe-tree-delete-issue38-20260817/suite-meta.json',
    'reports/safe-tree-delete-issue38-20260817/Test-CodexSafeTreeDeleteThreadJournal.stdout.txt',
    'reports/safe-tree-delete-issue38-20260817/Test-CodexSafeTreeDeleteThreadJournal.stderr.txt'
)
git diff --check -- @paths
$code = $LASTEXITCODE
Write-Output "DIFFCHECK_EXIT=$code"
exit $code
