[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IndexPath,
    [ValidateRange(512, 6000)][int]$MaxTotalBytes = 6000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
& python -B (Join-Path $PSScriptRoot 'daily-update-resume.py') resume --index-path $IndexPath --max-total-bytes $MaxTotalBytes
exit $LASTEXITCODE
