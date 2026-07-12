[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [switch]$Apply,
    [scriptblock]$EnvironmentReadValue,
    [scriptblock]$EnvironmentWriteValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')

if (-not $Apply) {
    [pscustomobject][ordered]@{ restored = $false; refusalReason = 'apply-switch-required' }
    return
}
if ($null -eq $EnvironmentReadValue) { $EnvironmentReadValue = { param($Name, $Scope) return $null } }
if ($null -eq $EnvironmentWriteValue) { $EnvironmentWriteValue = { param($Name, $Scope, $Value) throw 'environment adapter 未授权' } }

Restore-CodexHookDeploymentCore `
    -EvidenceDirectory $EvidenceDirectory `
    -EnvironmentReadValue $EnvironmentReadValue `
    -EnvironmentWriteValue $EnvironmentWriteValue `
    -FinalStatus 'restored'
