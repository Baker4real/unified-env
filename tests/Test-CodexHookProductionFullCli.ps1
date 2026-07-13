[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if(-not $Condition){throw $Message}
}

$root = Split-Path -Parent $PSScriptRoot
$new = Get-Command -Name (Join-Path $root 'scripts\New-CodexHookDeploymentPlan.ps1')
$invoke = Get-Command -Name (Join-Path $root 'scripts\Invoke-CodexHookDeployment.ps1')
$restore = Get-Command -Name (Join-Path $root 'scripts\Restore-CodexHookDeployment.ps1')

foreach($command in @($new,$invoke,$restore)){
    Assert-True ($command.Parameters.ContainsKey('ProductionFull')) "$($command.Name) 缺少 -ProductionFull"
    $set = @($command.ParameterSets | Where-Object Name -ceq 'ProductionFull')
    Assert-True ($set.Count -eq 1) "$($command.Name) 必须有唯一 ProductionFull 参数集"
    $names = @($set[0].Parameters.Name)
    foreach($forbidden in @('ManifestPath','FixtureSourceRoot','FixtureCodexHome','EnvironmentReadValue','EnvironmentWriteValue','FaultInjection','TestFaultInjection','TestAfterPredecessorSnapshot','TestBeforeRollbackPendingStatus','TestBeforeAutomaticRollback','TestAfterAutomaticRollbackAction','TestAfterRestoreAction','TestBeforeEnvironmentRestoreWrite','TestBeforeActiveRestorePublish','TestAfterActiveConverged','PlanPath','EvidenceRoot')){
        Assert-True ($names -cnotcontains $forbidden) "$($command.Name) ProductionFull 不得接受 $forbidden"
    }
}

$invokeRefusal = & (Join-Path $root 'scripts\Invoke-CodexHookDeployment.ps1') -ProductionFull -ApprovedScope codex-hook-governance-2026-07-11
Assert-True (-not $invokeRefusal.applied -and $invokeRefusal.refusalReason -ceq 'apply-switch-required') 'ProductionFull invoke 缺少 -Apply 必须零读取拒绝'
$invokeProductionFullSet = @($invoke.ParameterSets | Where-Object Name -ceq 'ProductionFull')[0]
foreach($requiredApprovalParameter in @('ApprovedGenerationId','ApprovedPlanSha256')){
    Assert-True (@($invokeProductionFullSet.Parameters.Name) -ccontains $requiredApprovalParameter) "ProductionFull apply 必须暴露 $requiredApprovalParameter"
}
$approvalRefusal = & (Join-Path $root 'scripts\Invoke-CodexHookDeployment.ps1') -ProductionFull -Apply -ApprovedScope codex-hook-governance-2026-07-11
Assert-True (-not $approvalRefusal.applied -and $approvalRefusal.refusalReason -ceq 'approved-plan-binding-required') 'ProductionFull apply 缺少 approved generation/hash 必须在零读取前拒绝'
$restoreRefusal = & (Join-Path $root 'scripts\Restore-CodexHookDeployment.ps1') -ProductionFull -EvidenceDirectory 'D:\Codex\.codex\run-evidence\env-governance\deployment-00000000-0000-0000-0000-000000000001' -ApprovedScope codex-hook-governance-2026-07-11
Assert-True (-not $restoreRefusal.restored -and $restoreRefusal.refusalReason -ceq 'apply-switch-required') 'ProductionFull restore 缺少 -Apply 必须零读取拒绝'

[pscustomobject][ordered]@{ok=$true;test='CodexHookProductionFullCli'}
