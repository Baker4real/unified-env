[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
Set-Location -LiteralPath $projectRoot

$files = @(
    'scripts/lib/CodexSafeTreeDeleteThreadJournal.cs',
    'scripts/lib/CodexSafeTreeDeleteParallelPurge.cs',
    'scripts/lib/CodexSafeTreeDelete.ps1',
    'tests/Test-CodexSafeTreeDeleteParallelPurgeCoordinator.ps1',
    'modules/manifest.json',
    'modules/host-safety/CONTEXT.md',
    'reports/safe-tree-delete-issue39-20260817/invoke-issue39.ps1'
)

git diff --check -- @files
$exit = $LASTEXITCODE
Write-Output "DIFFCHECK_EXIT=$exit"
exit $exit
