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

Assert-Superseded { Invoke-CodexHookProductionFullApplyEngine -Profile $fullProfile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -ApprovedGenerationId unread -ApprovedPlanSha256 ('0' * 64) } 'ProductionFull engine 必须在任何 production 读取前拒绝'
Assert-Superseded { Invoke-CodexHookProductionFullApplyCore -Profile $fullProfile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment } 'ProductionFull core 必须在任何 production 读取前拒绝'
Assert-Superseded { Invoke-CodexHookProductionFullApply -ApprovedGenerationId unread -ApprovedPlanSha256 ('0' * 64) } 'ProductionFull public apply 必须稳定拒绝'
Assert-Superseded { Restore-CodexHookProductionFullEngine -Profile $fullProfile -EvidenceDirectory $unreadEvidence -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment } 'ProductionFull restore engine 必须在 evidence 读取前拒绝'
Assert-Superseded { Restore-CodexHookProductionFullCore -Profile $fullProfile -EvidenceDirectory $unreadEvidence -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment } 'ProductionFull restore core 必须在 evidence 读取前拒绝'
Assert-Superseded { Restore-CodexHookProductionFull -EvidenceDirectory $unreadEvidence } 'ProductionFull public restore 必须稳定拒绝'
Assert-Superseded { Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $registrationProfile } 'RegistrationRepair core 必须在 plan/live 读取前拒绝'
Assert-Superseded { Restore-CodexHookProductionRegistrationRepairCore -Profile $registrationProfile -EvidenceDirectory $unreadEvidence } 'RegistrationRepair restore core 必须在 evidence 读取前拒绝'

$reconciler = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\Invoke-CodexHostHookReconciliation.ps1')
Assert-True ($reconciler -match '\$alreadyEmpty\s*=\s*-not\s+\$hookProperties\[0\]\.Value\.EnumerateObject\(\)\.MoveNext\(\)') 'reconciler 必须保持用户级 lifecycle hooks=0 目标'
Assert-True ($reconciler -match 'Set-TomlKeyLiteral[^\r\n]+-Key\s+"hooks"\s+-Literal\s+"true"') 'reconciler 必须保持 features.hooks=true 目标'

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

$historicalBriefPath = Join-Path $root '.superpowers\sdd\task-7-brief.md'
if (Test-Path -LiteralPath $historicalBriefPath -PathType Leaf) {
    $historicalBrief = Get-Content -Raw -LiteralPath $historicalBriefPath
    Assert-True ($historicalBrief -notmatch '(?m)^\s*&.*(?:Invoke|Restore)-CodexHookDeployment\.ps1') '本机历史 Task 7 brief 不得保留可复制的 live apply/restore 命令'
}

[pscustomobject][ordered]@{ok=$true;test='CodexHostHookAuthority'}
