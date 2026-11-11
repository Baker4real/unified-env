#requires -Version 7.4
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string[]]$TargetPaths,
 [Parameter(Mandatory)][string]$JobDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'lib/SafeCleanupJob.ps1')
$result=New-SafeCleanupJobSet -TargetPaths $TargetPaths -JobDirectory $JobDirectory -PolicyPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'managed/safe-tree-delete/policy.json') -TransactionEvidenceRoot 'D:/agents/run-evidence/safe-tree-delete'
$result | ConvertTo-Json -Depth 8 -Compress
if($result.status -ne 'prepared'){exit 1}
