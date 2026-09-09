param([ValidateSet('before','after')][string]$Label)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'prepare-runtime.ps1')
$output=Join-Path $env:ISSUE58_RUN_ROOT 'fingerprint.json'
& (Join-Path $repo 'reports/issue58-20260908/evidence-fingerprint.ps1') -Label $Label -OutputPath $output | Out-Null
[Console]::Write([IO.File]::ReadAllText($output))
exit 0
