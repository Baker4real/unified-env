#requires -Version 7.4
# Repository runner adapter; the deployable fixture stays beside its managed entry.
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'managed/host-diagnostics/Test-RemoteMagpiePortable.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
