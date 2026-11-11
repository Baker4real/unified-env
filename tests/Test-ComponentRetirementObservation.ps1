#requires -Version 7.4
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$entry=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Get-ComponentRetirementObservation.ps1'
$global:RetirementProbeDeny=$false
function Get-ScheduledTask {
 [CmdletBinding()]param()
 if($global:RetirementProbeDeny){throw [UnauthorizedAccessException]::new('fixture')}
 [pscustomobject]@{TaskName='Demo Elevated'}
}
function Get-Process {
 [CmdletBinding()]param()
 if($global:RetirementProbeDeny){throw [UnauthorizedAccessException]::new('fixture')}
 [pscustomobject]@{ProcessName='Demo'}
}
$spec='{"tasks":["demo elevated"],"products":[],"process_names":["demo"]}'
$observed=(& $entry -SpecJson $spec) | ConvertFrom-Json
if($observed.tasks.'demo elevated' -ne 'present' -or $observed.processes.demo -ne 'present'){throw 'Windows identity comparison must be ordinal case-insensitive.'}
$global:RetirementProbeDeny=$true
$observed=(& $entry -SpecJson $spec) | ConvertFrom-Json
if($observed.tasks.'demo elevated' -ne 'unknown' -or $observed.processes.demo -ne 'unknown'){throw 'Query denial must stay unknown.'}
[pscustomobject]@{ok=$true;suite='ComponentRetirementObservation';caseInsensitive=$true;denialUnknown=$true}
