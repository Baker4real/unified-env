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
    [string[]]$TransactionPaths,
    [string[]]$ApprovedTransactionSha256s,
    [switch]$ConfirmPurge,
    [switch]$ConfirmRestore,
    [switch]$ConfirmArchive,
    [switch]$FixtureFailAfterRename,
    [scriptblock]$FixtureBeforePurgeMutex,
    [scriptblock]$FixtureBeforeDirectoryTreeDelete,
    [scriptblock]$FixtureDirectoryDeleteCheckpoint,
    [scriptblock]$FixtureLeafDeleteFault,
    [object]$FixtureLeafRetryPolicy,
    [scriptblock]$FixtureLeafRetryElapsedMilliseconds,
    [scriptblock]$FixtureLeafRetryDelay,
    [scriptblock]$FixtureAfterBatchHistoryScan,
    [switch]$Json,
    [Nullable[datetimeoffset]]$FixtureTrustedNowUtc,
    [Nullable[long]]$FixtureTrustedElapsedNowMilliseconds,
    [string]$FixtureTrustedBootSessionId,
    [scriptblock]$FixtureTrustedBootSessionSource,
    [switch]$FixtureTrustedTimeRestartAmbiguous,
    [string]$FixtureCandidatePolicyPath,
    [string]$FixtureApprovedCandidatePolicySha256,
    [Parameter(Mandatory)][string]$FixturePolicyPath,
    [Parameter(Mandatory)][string]$FixtureEvidenceRoot,
    [object]$FixtureFileSystemCapabilities
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

# 确认拒绝、参数校验与库函数调用都在共享分发 Invoke-CodexSafeTreeDeleteMode 里，与生产入口同一份。
# 本入口只换上 fixture policy / evidence 根，并按 mode 追加 fixture 钩子。
$statusTestArguments = @{}
if (-not [string]::IsNullOrWhiteSpace($FixtureCandidatePolicyPath)) {
    $statusTestArguments.CandidatePolicyPath = $FixtureCandidatePolicyPath
}
if (-not [string]::IsNullOrWhiteSpace($FixtureApprovedCandidatePolicySha256)) {
    $statusTestArguments.ApprovedCandidatePolicySha256 = $FixtureApprovedCandidatePolicySha256
}

$planTestArguments = @{}
if ($null -ne $FixtureFileSystemCapabilities) {
    $planTestArguments.FileSystemCapabilitiesForTest = $FixtureFileSystemCapabilities
}

$applyTestArguments = @{
    FailAfterRenameForTest = [bool]$FixtureFailAfterRename
}
if ($null -ne $FixtureFileSystemCapabilities) {
    $applyTestArguments.FileSystemCapabilitiesForTest = $FixtureFileSystemCapabilities
}

$purgeTestArguments = @{
    BeforePurgeMutexForTest = $FixtureBeforePurgeMutex
    BeforeDirectoryTreeDeleteForTest = $FixtureBeforeDirectoryTreeDelete
    DirectoryDeleteCheckpointForTest = $FixtureDirectoryDeleteCheckpoint
    LeafDeleteFaultForTest = $FixtureLeafDeleteFault
    TrustedTimeRestartAmbiguous = [bool]$FixtureTrustedTimeRestartAmbiguous
}
if ($null -ne $FixtureTrustedNowUtc) {
    $purgeTestArguments.TrustedNowUtc = [datetimeoffset]$FixtureTrustedNowUtc
}
if ($null -ne $FixtureTrustedElapsedNowMilliseconds) {
    $purgeTestArguments.TrustedElapsedNowMilliseconds = [long]$FixtureTrustedElapsedNowMilliseconds
}
if (-not [string]::IsNullOrWhiteSpace($FixtureTrustedBootSessionId)) {
    $purgeTestArguments.TrustedBootSessionId = $FixtureTrustedBootSessionId
}
if ($null -ne $FixtureTrustedBootSessionSource) {
    $purgeTestArguments.TrustedBootSessionSourceForTest = $FixtureTrustedBootSessionSource
}
if ($null -ne $FixtureLeafRetryPolicy) {
    $purgeTestArguments.LeafRetryPolicyForTest = $FixtureLeafRetryPolicy
}
if ($null -ne $FixtureLeafRetryElapsedMilliseconds) {
    $purgeTestArguments.LeafRetryElapsedMillisecondsForTest = $FixtureLeafRetryElapsedMilliseconds
}
if ($null -ne $FixtureLeafRetryDelay) {
    $purgeTestArguments.LeafRetryDelayForTest = $FixtureLeafRetryDelay
}
if ($null -ne $FixtureFileSystemCapabilities) {
    $purgeTestArguments.FileSystemCapabilitiesForTest = $FixtureFileSystemCapabilities
}

$batchPurgeTestArguments = @{
    AfterBatchHistoryScanForTest = $FixtureAfterBatchHistoryScan
}

$result = Invoke-CodexSafeTreeDeleteMode `
    -EntryParameters $PSBoundParameters `
    -PolicyPath $FixturePolicyPath `
    -EvidenceRoot $FixtureEvidenceRoot `
    -ModeArgumentsForTest @{
        Status = $statusTestArguments
        Plan = $planTestArguments
        Apply = $applyTestArguments
        Purge = $purgeTestArguments
        BatchPurge = $batchPurgeTestArguments
    }

if ($Json) {
    $result | ConvertTo-Json -Depth 12 -Compress
} else {
    $result
}
