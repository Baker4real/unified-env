#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$diagnostics = Join-Path (Split-Path -Parent $PSScriptRoot) 'managed/host-diagnostics'
& (Join-Path $diagnostics 'Test-DesktopShortcut.ps1')
& (Join-Path $diagnostics 'antigravity/Test-AntigravityLauncher.ps1')
& python -B -I (Join-Path $diagnostics 'antigravity/test_wsl_patch.py')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& node (Join-Path $diagnostics 'antigravity/test_quota_health.cjs')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
