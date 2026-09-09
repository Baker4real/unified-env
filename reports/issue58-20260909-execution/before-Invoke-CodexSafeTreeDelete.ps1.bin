[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Purge', 'BatchPurge', 'Status', 'Restore', 'Archive')][string]$Mode,
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

function Resolve-TargetPathArguments {
    param([string[]]$Values)

    $items = @($Values)
    if ($items.Count -eq 1 -and [string]$items[0] -match '::') {
        $items = @(([string]$items[0]).Split([string[]]@('::'), [StringSplitOptions]::RemoveEmptyEntries))
    }
    return @($items)
}

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\CodexHostSafety.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDelete.ps1')

$policyPath = Join-Path $projectRoot 'managed\safe-tree-delete\policy.json'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'

switch ($Mode) {
    'Status' {
        $result = Get-CodexSafeTreeDeleteStatus `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot
    }
    'Restore' {
        if (-not $ConfirmRestore) {
            $result = [pscustomobject][ordered]@{ restored = $false; refusalReason = 'confirm-restore-required' }
            break
        }
        if ([string]::IsNullOrWhiteSpace($TransactionPath) -or
            [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
            throw 'Restore 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
        }
        $result = Invoke-CodexSafeTreeDeleteRestore `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot
    }
    'Archive' {
        if (-not $ConfirmArchive) {
            $result = [pscustomobject][ordered]@{ archived = $false; refusalReason = 'confirm-archive-required' }
            break
        }
        if ([string]::IsNullOrWhiteSpace($TransactionPath) -or
            [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
            throw 'Archive 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
        }
        $result = Invoke-CodexSafeTreeDeleteArchive `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
            -EvidenceRoot $evidenceRoot
    }
    'Plan' {
        if ([string]::IsNullOrWhiteSpace($TargetPath) -or [string]::IsNullOrWhiteSpace($CapabilityRoot)) {
            throw 'Plan 模式要求 TargetPath 与 CapabilityRoot。'
        }
        $result = New-CodexSafeTreeDeletePlan `
            -TargetPath $TargetPath `
            -CapabilityRoot $CapabilityRoot `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot
    }
    'Apply' {
        if (-not $ConfirmApply) {
            $result = [pscustomobject][ordered]@{ quarantined = $false; refusalReason = 'confirm-apply-required' }
            break
        }
        if ([string]::IsNullOrWhiteSpace($PlanPath) -or [string]::IsNullOrWhiteSpace($ApprovedPlanSha256)) {
            throw 'Apply 模式要求 PlanPath 与 ApprovedPlanSha256。'
        }
        $result = Invoke-CodexSafeTreeDeleteQuarantine `
            -PlanPath $PlanPath `
            -ApprovedPlanSha256 $ApprovedPlanSha256 `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot
    }
    'Purge' {
        if (-not $ConfirmPurge) {
            $result = [pscustomobject][ordered]@{ purged = $false; refusalReason = 'confirm-purge-required' }
            break
        }
        if ([string]::IsNullOrWhiteSpace($TransactionPath) -or [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
            throw 'Purge 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
        }
        $result = Invoke-CodexSafeTreeDeletePurge `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot `
            -ReturnFailureMetrics:$Json
    }
    'BatchPurge' {
        if (-not $ConfirmApply -or -not $ConfirmPurge) {
            $result = [pscustomobject][ordered]@{ completed = $false; refusalReason = 'confirm-apply-and-purge-required' }
            break
        }
        $resolvedTargets = @(Resolve-TargetPathArguments -Values $TargetPaths)
        if ($resolvedTargets.Count -eq 0 -or [string]::IsNullOrWhiteSpace($CapabilityRoot)) {
            throw 'BatchPurge 模式要求 TargetPaths 与 CapabilityRoot。'
        }
        $result = Invoke-CodexSafeTreeDeleteBatchPurge `
            -TargetPaths $resolvedTargets `
            -CapabilityRoot $CapabilityRoot `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot
    }
}

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
