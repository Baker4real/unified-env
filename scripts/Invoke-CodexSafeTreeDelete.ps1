[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Purge', 'BatchPurge', 'Status', 'Restore', 'Archive', 'Lint')][string]$Mode,
    [string]$TargetPath,
    [string[]]$TargetPaths,
    [string]$CapabilityRoot,
    [string]$PlanPath,
    [string]$ApprovedPlanSha256,
    [switch]$ConfirmApply,
    [string]$TransactionPath,
    [string]$ApprovedTransactionSha256,
    [switch]$ConfirmPurge,
    [switch]$ConfirmRestore,
    [switch]$ConfirmArchive,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PlainText 渲染：重定向捕获的错误文本不夹 ANSI/VT 序列，调用方可安全按词分类
# （结构化结果仍以 -Json 的 stdout 为准；stderr 仅作诊断）。
if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\CodexHostSafety.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDelete.ps1')

$policyPath = Join-Path $projectRoot 'managed\safe-tree-delete\policy.json'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'

# 确认拒绝、参数校验与库函数调用都在共享分发 Invoke-CodexSafeTreeDeleteMode 里，与 fixture 入口同一份。
# 生产入口只给出固定的仓库 policy 与生产 evidence 根，不传任何测试参数。
$result = Invoke-CodexSafeTreeDeleteMode `
    -EntryParameters $PSBoundParameters `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot

if ($Json) {
    $result | ConvertTo-Json -Depth 12 -Compress
} else {
    $result
}

if ($Json -and
    $null -ne $result -and
    $result.PSObject.Properties.Name -contains 'refusalReason' -and
    [string]$result.refusalReason -ceq 'leaf-delete-failed') {
    exit 1
}
