param(
    [Parameter(Mandatory)][string]$TransactionPath,
    [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
    [Parameter(Mandatory)][string]$FixturePolicyPath,
    [Parameter(Mandatory)][string]$FixtureEvidenceRoot,
    [Parameter(Mandatory)][string]$MarkerPath,
    [Parameter(Mandatory)]
    [ValidateSet('after-intent', 'after-rename', 'after-target-verification', 'after-complete-journal')]
    [string]$Scenario
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

Invoke-CodexSafeTreeDeleteRestore `
    -TransactionPath $TransactionPath `
    -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
    -PolicyPath $FixturePolicyPath `
    -EvidenceRoot $FixtureEvidenceRoot `
    -RestoreCheckpointForTest {
        param([string]$TargetPath, [string]$QuarantinePath, [string]$Phase)
        if ($Phase -cne $Scenario) { return }
        [IO.File]::WriteAllText(
            $MarkerPath,
            "$Phase|$TargetPath|$QuarantinePath",
            [Text.UTF8Encoding]::new($false))
        [Environment]::Exit(197)
    }

throw 'safe-delete Restore crash fixture did not reach the requested checkpoint.'
