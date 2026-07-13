[CmdletBinding(DefaultParameterSetName = 'Fixture')]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [switch]$Apply,
    [Parameter(ParameterSetName = 'Fixture')][scriptblock]$EnvironmentReadValue,
    [Parameter(ParameterSetName = 'Fixture')][scriptblock]$EnvironmentWriteValue,
    [Parameter(ParameterSetName = 'Fixture')]
    [Parameter(Mandatory, ParameterSetName = 'ProductionRegistrationRepair')]
    [Parameter(Mandatory, ParameterSetName = 'ProductionFull')]
    [string]$ApprovedScope,
    [Parameter(Mandatory, ParameterSetName = 'ProductionRegistrationRepair')][switch]$ProductionRegistrationRepair,
    [Parameter(Mandatory, ParameterSetName = 'ProductionFull')][switch]$ProductionFull
)

if ($PSCmdlet.ParameterSetName -in @('ProductionRegistrationRepair', 'ProductionFull')) {
    [pscustomobject][ordered]@{
        restored = $false
        refusalReason = 'superseded-by-host-hook-reconciler'
    }
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionRegistrationRepair.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionFull.ps1')

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
