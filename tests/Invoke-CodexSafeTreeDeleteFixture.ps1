[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Purge', 'BatchPurge', 'Status', 'Restore')][string]$Mode,
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
    [switch]$FixtureFailAfterRename,
    [scriptblock]$FixtureBeforePurgeMutex,
    [scriptblock]$FixtureBeforeDirectoryTreeDelete,
    [scriptblock]$FixtureDirectoryDeleteCheckpoint,
    [scriptblock]$FixtureLeafDeleteFault,
    [object]$FixtureLeafRetryPolicy,
    [scriptblock]$FixtureLeafRetryElapsedMilliseconds,
    [scriptblock]$FixtureLeafRetryDelay,
    [switch]$Json,
    [Nullable[datetimeoffset]]$FixtureTrustedNowUtc,
    [Nullable[long]]$FixtureTrustedElapsedNowMilliseconds,
    [string]$FixtureTrustedBootSessionId,
    [scriptblock]$FixtureTrustedBootSessionSource,
    [switch]$FixtureTrustedTimeRestartAmbiguous,
    [string]$FixtureCandidatePolicyPath,
    [string]$FixtureApprovedCandidatePolicySha256,
    [Parameter(Mandatory)][string]$FixturePolicyPath,
    [Parameter(Mandatory)][string]$FixtureEvidenceRoot
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
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

$result = switch ($Mode) {
    'Status' {
        $statusArguments = @{
            PolicyPath = $FixturePolicyPath
            EvidenceRoot = $FixtureEvidenceRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($FixtureCandidatePolicyPath)) {
            $statusArguments.CandidatePolicyPath = $FixtureCandidatePolicyPath
        }
        if (-not [string]::IsNullOrWhiteSpace($FixtureApprovedCandidatePolicySha256)) {
            $statusArguments.ApprovedCandidatePolicySha256 = $FixtureApprovedCandidatePolicySha256
        }
        Get-CodexSafeTreeDeleteStatus @statusArguments
    }
    'Restore' {
        if (-not $ConfirmRestore) {
            [pscustomobject][ordered]@{ restored = $false; refusalReason = 'confirm-restore-required' }
            break
        }
        if ([string]::IsNullOrWhiteSpace($TransactionPath) -or
            [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
            throw 'Restore 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
        }
        Invoke-CodexSafeTreeDeleteRestore `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
            -PolicyPath $FixturePolicyPath `
            -EvidenceRoot $FixtureEvidenceRoot
    }
    'Plan' {
        if ([string]::IsNullOrWhiteSpace($TargetPath) -or [string]::IsNullOrWhiteSpace($CapabilityRoot)) {
            throw 'Plan 模式要求 TargetPath 与 CapabilityRoot。'
        }
        New-CodexSafeTreeDeletePlan `
            -TargetPath $TargetPath `
            -CapabilityRoot $CapabilityRoot `
            -PolicyPath $FixturePolicyPath `
            -EvidenceRoot $FixtureEvidenceRoot
    }
    'Apply' {
        if (-not $ConfirmApply) {
            [pscustomobject][ordered]@{ quarantined = $false; refusalReason = 'confirm-apply-required' }
            break
        }
        if ([string]::IsNullOrWhiteSpace($PlanPath) -or [string]::IsNullOrWhiteSpace($ApprovedPlanSha256)) {
            throw 'Apply 模式要求 PlanPath 与 ApprovedPlanSha256。'
        }
        Invoke-CodexSafeTreeDeleteQuarantine `
            -PlanPath $PlanPath `
            -ApprovedPlanSha256 $ApprovedPlanSha256 `
            -PolicyPath $FixturePolicyPath `
            -EvidenceRoot $FixtureEvidenceRoot `
            -FailAfterRenameForTest:$FixtureFailAfterRename
    }
    'Purge' {
        if (-not $ConfirmPurge) {
            [pscustomobject][ordered]@{ purged = $false; refusalReason = 'confirm-purge-required' }
            break
        }
        if ([string]::IsNullOrWhiteSpace($TransactionPath) -or [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
            throw 'Purge 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
        }
        $purgeArguments = @{
            TransactionPath = $TransactionPath
            ApprovedTransactionSha256 = $ApprovedTransactionSha256
            PolicyPath = $FixturePolicyPath
            EvidenceRoot = $FixtureEvidenceRoot
            BeforePurgeMutexForTest = $FixtureBeforePurgeMutex
            BeforeDirectoryTreeDeleteForTest = $FixtureBeforeDirectoryTreeDelete
            DirectoryDeleteCheckpointForTest = $FixtureDirectoryDeleteCheckpoint
            LeafDeleteFaultForTest = $FixtureLeafDeleteFault
            TrustedTimeRestartAmbiguous = [bool]$FixtureTrustedTimeRestartAmbiguous
            ReturnFailureMetrics = [bool]$Json
        }
        if ($null -ne $FixtureTrustedNowUtc) {
            $purgeArguments.TrustedNowUtc = [datetimeoffset]$FixtureTrustedNowUtc
        }
        if ($null -ne $FixtureTrustedElapsedNowMilliseconds) {
            $purgeArguments.TrustedElapsedNowMilliseconds = [long]$FixtureTrustedElapsedNowMilliseconds
        }
        if (-not [string]::IsNullOrWhiteSpace($FixtureTrustedBootSessionId)) {
            $purgeArguments.TrustedBootSessionId = $FixtureTrustedBootSessionId
        }
        if ($null -ne $FixtureTrustedBootSessionSource) {
            $purgeArguments.TrustedBootSessionSourceForTest = $FixtureTrustedBootSessionSource
        }
        if ($null -ne $FixtureLeafRetryPolicy) {
            $purgeArguments.LeafRetryPolicyForTest = $FixtureLeafRetryPolicy
        }
        if ($null -ne $FixtureLeafRetryElapsedMilliseconds) {
            $purgeArguments.LeafRetryElapsedMillisecondsForTest = $FixtureLeafRetryElapsedMilliseconds
        }
        if ($null -ne $FixtureLeafRetryDelay) {
            $purgeArguments.LeafRetryDelayForTest = $FixtureLeafRetryDelay
        }
        Invoke-CodexSafeTreeDeletePurge @purgeArguments
    }
    'BatchPurge' {
        if (-not $ConfirmApply -or -not $ConfirmPurge) {
            [pscustomobject][ordered]@{ completed = $false; refusalReason = 'confirm-apply-and-purge-required' }
            break
        }
        $resolvedTargets = @(Resolve-TargetPathArguments -Values $TargetPaths)
        if ($resolvedTargets.Count -eq 0 -or [string]::IsNullOrWhiteSpace($CapabilityRoot)) {
            throw 'BatchPurge 模式要求 TargetPaths 与 CapabilityRoot。'
        }
        Invoke-CodexSafeTreeDeleteBatchPurge `
            -TargetPaths $resolvedTargets `
            -CapabilityRoot $CapabilityRoot `
            -PolicyPath $FixturePolicyPath `
            -EvidenceRoot $FixtureEvidenceRoot
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 12 -Compress
} else {
    $result
}
