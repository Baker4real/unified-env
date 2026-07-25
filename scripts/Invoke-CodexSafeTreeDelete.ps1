[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Purge', 'BatchPurge')][string]$Mode,
    [string]$TargetPath,
    [string[]]$TargetPaths,
    [string]$CapabilityRoot,
    [string]$PlanPath,
    [string]$ApprovedPlanSha256,
    [switch]$ConfirmApply,
    [string]$TransactionPath,
    [string]$ApprovedTransactionSha256,
    [switch]$ConfirmPurge,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-TargetPathArguments {
    param([string[]]$Values)

    $items = @($Values)
    if ($items.Count -eq 1 -and [string]$items[0] -match '::') {
        $items = @(([string]$items[0]).Split([string[]]@('::'), [StringSplitOptions]::RemoveEmptyEntries))
    }
    return @($items)
}

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDelete.ps1')

$policyPath = Join-Path $projectRoot 'managed\safe-tree-delete\policy.json'
$evidenceRoot = 'D:\Codex\.codex\run-evidence\safe-tree-delete'

switch ($Mode) {
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
            -EvidenceRoot $evidenceRoot
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
