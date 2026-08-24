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

$isolatedRoot = Join-Path 'D:\agents\projects\统一环境\.scratch' "production-full-cli-retirement-$([guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $isolatedRoot)
try {
    foreach ($scriptName in @('New-CodexHookDeploymentPlan.ps1','Invoke-CodexHookDeployment.ps1','Restore-CodexHookDeployment.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "scripts\$scriptName") -Destination (Join-Path $isolatedRoot $scriptName)
    }

    $newRefusal = & (Join-Path $isolatedRoot 'New-CodexHookDeploymentPlan.ps1') -ProductionFull
    Assert-True (-not $newRefusal.generated -and $newRefusal.refusalReason -ceq 'superseded-by-host-hook-reconciler') 'ProductionFull plan 必须在加载 production runtime 或生成报告前稳定拒绝'

    $invokeRefusal = & (Join-Path $isolatedRoot 'Invoke-CodexHookDeployment.ps1') -ProductionFull -ApprovedScope codex-hook-governance-2026-07-11
    Assert-True (-not $invokeRefusal.applied -and $invokeRefusal.refusalReason -ceq 'superseded-by-host-hook-reconciler') 'ProductionFull invoke 必须在 apply/scope/plan gate 和 production runtime 前稳定拒绝'

    $approvalRefusal = & (Join-Path $isolatedRoot 'Invoke-CodexHookDeployment.ps1') -ProductionFull -Apply -ApprovedScope codex-hook-governance-2026-07-11 -ApprovedGenerationId 'unread-generation' -ApprovedPlanSha256 ('0' * 64)
    Assert-True (-not $approvalRefusal.applied -and $approvalRefusal.refusalReason -ceq 'superseded-by-host-hook-reconciler') 'ProductionFull apply 即使批准参数完整也必须稳定拒绝'

    $restoreRefusal = & (Join-Path $isolatedRoot 'Restore-CodexHookDeployment.ps1') -ProductionFull -EvidenceDirectory 'D:\Codex\.codex\run-evidence\must-not-be-read' -ApprovedScope codex-hook-governance-2026-07-11
    Assert-True (-not $restoreRefusal.restored -and $restoreRefusal.refusalReason -ceq 'superseded-by-host-hook-reconciler') 'ProductionFull restore 必须在 evidence/apply/scope gate 和 production runtime 前稳定拒绝'

    $registrationPlanRefusal = & (Join-Path $isolatedRoot 'New-CodexHookDeploymentPlan.ps1') -ProductionRegistrationRepair
    Assert-True (-not $registrationPlanRefusal.generated -and $registrationPlanRefusal.refusalReason -ceq 'superseded-by-host-hook-reconciler') 'ProductionRegistrationRepair plan 也不得保留第二生产权威'

    $registrationApplyRefusal = & (Join-Path $isolatedRoot 'Invoke-CodexHookDeployment.ps1') -ProductionRegistrationRepair -Apply -ApprovedScope codex-hook-governance-2026-07-11
    Assert-True (-not $registrationApplyRefusal.applied -and $registrationApplyRefusal.refusalReason -ceq 'superseded-by-host-hook-reconciler') 'ProductionRegistrationRepair apply 也不得保留第二生产权威'

    $registrationRestoreRefusal = & (Join-Path $isolatedRoot 'Restore-CodexHookDeployment.ps1') -ProductionRegistrationRepair -EvidenceDirectory 'D:\Codex\.codex\run-evidence\must-not-be-read' -Apply -ApprovedScope codex-hook-governance-2026-07-11
    Assert-True (-not $registrationRestoreRefusal.restored -and $registrationRestoreRefusal.refusalReason -ceq 'superseded-by-host-hook-reconciler') 'ProductionRegistrationRepair restore 也不得保留第二生产权威'

    $isolatedChildren = @(Get-ChildItem -LiteralPath $isolatedRoot -Recurse -Force)
    $isolatedFiles = @($isolatedChildren | Where-Object { -not $_.PSIsContainer })
    Assert-True ($isolatedChildren.Count -eq 3 -and $isolatedFiles.Count -eq 3) 'Production façades 拒绝不得递归生成报告、目录、lib 或 lifecycle 文件'
    $isolatedNames = @($isolatedFiles.Name | Sort-Object) -join ','
    $expectedNames = @('Invoke-CodexHookDeployment.ps1','New-CodexHookDeploymentPlan.ps1','Restore-CodexHookDeployment.ps1') -join ','
    Assert-True ($isolatedNames -ceq $expectedNames) '隔离目录只允许三份 façade 脚本'
} finally {
    Remove-Item -LiteralPath $isolatedRoot -Recurse -Force
}
$invokeProductionFullSet = @($invoke.ParameterSets | Where-Object Name -ceq 'ProductionFull')[0]
foreach($requiredApprovalParameter in @('ApprovedGenerationId','ApprovedPlanSha256')){
    Assert-True (@($invokeProductionFullSet.Parameters.Name) -ccontains $requiredApprovalParameter) "ProductionFull apply 必须暴露 $requiredApprovalParameter"
}
[pscustomobject][ordered]@{ok=$true;test='CodexHookProductionFullCli'}
