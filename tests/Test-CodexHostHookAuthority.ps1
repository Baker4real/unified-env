[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Superseded {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Message)
    try {
        & $Action
    } catch {
        Assert-True ($_.Exception.Message -ceq 'superseded-by-host-hook-reconciler') $Message
        return
    }
    throw "$Message：调用未拒绝"
}

$root = Split-Path -Parent $PSScriptRoot
$facades = @(
    'scripts\New-CodexHookDeploymentPlan.ps1',
    'scripts\Invoke-CodexHookDeployment.ps1',
    'scripts\Restore-CodexHookDeployment.ps1'
)
foreach ($relativePath in $facades) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $root $relativePath)
    $refusalIndex = $text.IndexOf("superseded-by-host-hook-reconciler", [StringComparison]::Ordinal)
    $runtimeIndex = $text.IndexOf("CodexHookProductionFull.ps1", [StringComparison]::Ordinal)
    Assert-True ($refusalIndex -ge 0 -and $refusalIndex -lt $runtimeIndex) "$relativePath 必须在加载 ProductionFull runtime 前拒绝"
}

. (Join-Path $root 'scripts\lib\CodexHookPolicy.ps1')
. (Join-Path $root 'scripts\lib\CodexHookProductionRegistrationRepair.ps1')
. (Join-Path $root 'scripts\lib\CodexHookProductionFull.ps1')
$readEnvironment = { param($Name,$Scope) throw 'production environment read was reached' }
$writeEnvironment = { param($Name,$Scope,$Value) throw 'production environment write was reached' }
$fullProfile = Get-CodexHookProductionFullProfile
$registrationProfile = Get-CodexHookProductionRegistrationRepairProfile
$unreadEvidence = 'D:\Codex\.codex\run-evidence\must-not-be-read'

Assert-True ($fullProfile.manifestPath -ceq 'D:\agents\projects\统一环境\managed\codex-hooks\host-preflight-manifest.json') 'ProductionFull 非 fixture profile 不得绑定 legacy fixture manifest'
Assert-True ($registrationProfile.manifestPath -ceq 'D:\agents\projects\统一环境\managed\codex-hooks\host-preflight-manifest.json') 'RegistrationRepair 非 fixture profile 不得绑定 legacy fixture manifest'
Assert-Superseded { New-CodexHookProductionFullState -Profile ([pscustomobject]@{ isFixtureAdapter = $false }) -EnvironmentReadValue $readEnvironment } 'ProductionFull state 必须在 profile/manifest/live 读取前拒绝非 fixture 调用'
Assert-Superseded { New-CodexHookProductionRegistrationRepairState -Profile ([pscustomobject]@{ isFixtureAdapter = $false }) } 'RegistrationRepair state 必须在 profile/manifest/live 读取前拒绝非 fixture 调用'

Assert-Superseded { Invoke-CodexHookProductionFullApplyEngine -Profile $fullProfile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -ApprovedGenerationId unread -ApprovedPlanSha256 ('0' * 64) } 'ProductionFull engine 必须在任何 production 读取前拒绝'
Assert-Superseded { Invoke-CodexHookProductionFullApplyCore -Profile $fullProfile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment } 'ProductionFull core 必须在任何 production 读取前拒绝'
Assert-Superseded { Invoke-CodexHookProductionFullApply -ApprovedGenerationId unread -ApprovedPlanSha256 ('0' * 64) } 'ProductionFull public apply 必须稳定拒绝'
Assert-Superseded { Restore-CodexHookProductionFullEngine -Profile $fullProfile -EvidenceDirectory $unreadEvidence -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment } 'ProductionFull restore engine 必须在 evidence 读取前拒绝'
Assert-Superseded { Restore-CodexHookProductionFullCore -Profile $fullProfile -EvidenceDirectory $unreadEvidence -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment } 'ProductionFull restore core 必须在 evidence 读取前拒绝'
Assert-Superseded { Restore-CodexHookProductionFull -EvidenceDirectory $unreadEvidence } 'ProductionFull public restore 必须稳定拒绝'
Assert-Superseded { Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $registrationProfile } 'RegistrationRepair core 必须在 plan/live 读取前拒绝'
Assert-Superseded { Restore-CodexHookProductionRegistrationRepairCore -Profile $registrationProfile -EvidenceDirectory $unreadEvidence } 'RegistrationRepair restore core 必须在 evidence 读取前拒绝'

$reconciler = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\Invoke-CodexHostHookReconciliation.ps1')
Assert-True ($reconciler -match 'Merge-CodexHookRegistry\s+-Manifest\s+\$script:HostPreflightManifest') 'reconciler 必须按 active host manifest 合并 lifecycle hooks'
Assert-True ($reconciler -match 'Merge-CodexHookRegistry\s+-Manifest\s+\$script:HostPreflightManifest\s+-LiveRegistry\s+\$liveRegistry\s+-Mode\s+full') 'reconciler 必须以 host-preflight manifest 合并用户级 lifecycle hooks'
Assert-True ($reconciler -match '\$alreadyDesired\s*=\s+\$currentHooksJson\s+-ceq\s+\$mergedHooksJson') 'reconciler 必须以目标 registry 幂等判断替代已退役的 hooks=0 判断'
Assert-True (-not ($reconciler -match 'Set-TomlKeyLiteral[^\r\n]+-Key\s+"(?:approval_policy|sandbox_mode|unified_exec)"')) 'reconciler 不得擅自重写用户权限或 Windows unified_exec 默认值'

$userDocs = @(
    'README.md',
    'CONTEXT.md',
    'docs\specs\2026-07-11-codex-hook-governance-design.md',
    'docs\specs\2026-07-11-host-hook-reconciliation-design.md',
    'docs\plans\2026-07-11-codex-hook-governance-implementation.md'
)
foreach ($relativePath in $userDocs) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $root $relativePath)
    Assert-True ($text -match '唯一.{0,12}(生产|当前).{0,12}(权威|入口)|唯一.{0,12}(权威|入口)') "$relativePath 必须声明 reconciler 的单一生产权威"
}

[pscustomobject][ordered]@{ok=$true;test='CodexHostHookAuthority'}
