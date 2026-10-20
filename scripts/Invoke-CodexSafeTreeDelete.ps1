[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Check', 'Apply', 'Purge', 'BatchPurge', 'Status', 'Restore', 'Archive', 'Lint')][string]$Mode,
    [string]$TargetPath,
    [string[]]$TargetPaths,
    [string]$CapabilityRoot,
    [string]$PlanPath,
    [string]$ApprovedPlanSha256,
    [switch]$ConfirmApply,
    [string]$TransactionPath,
    [string]$ApprovedTransactionSha256,
    [string[]]$TransactionPaths,
    [string[]]$ApprovedTransactionSha256s,
    [switch]$ConfirmPurge,
    [switch]$ConfirmRestore,
    [switch]$ConfirmArchive,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PlainText 渲染：重定向捕获的错误文本不夹 ANSI/VT 序列，调用方可安全按词分类
# （结构化结果以 stdout 的 JSON 为准；stderr 仅作诊断）。
if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\CodexHostSafety.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDelete.ps1')

$policyPath = Join-Path $projectRoot 'managed\safe-tree-delete\policy.json'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'

# 生产入口一律按 -Json 运行并输出单行 JSON，-Json 只为兼容既有调用方保留：不带 -Json 时的对象输出
# 经 gate shim 的 exit 与跨进程格式化会丢失或截断，调用方拿不到可判定的结果（2026-10-20）。
$PSBoundParameters['Json'] = $true

# 确认拒绝、参数校验与库函数调用都在共享分发 Invoke-CodexSafeTreeDeleteMode 里，与 fixture 入口同一份。
# 生产入口只给出固定的仓库 policy 与生产 evidence 根，不传任何测试参数。
$result = Invoke-CodexSafeTreeDeleteMode `
    -EntryParameters $PSBoundParameters `
    -PolicyPath $policyPath `
    -EvidenceRoot $evidenceRoot

$result | ConvertTo-Json -Depth 12 -Compress

if ($null -ne $result -and
    $result.PSObject.Properties.Name -contains 'refusalReason' -and
    [string]$result.refusalReason -ceq 'leaf-delete-failed') {
    exit 1
}
