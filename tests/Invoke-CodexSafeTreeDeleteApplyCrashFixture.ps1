param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ApprovedPlanSha256,
    [Parameter(Mandatory)][string]$FixturePolicyPath,
    [Parameter(Mandatory)][string]$FixtureEvidenceRoot,
    [Parameter(Mandatory)][string]$MarkerRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

Invoke-CodexSafeTreeDeleteQuarantine `
    -PlanPath $PlanPath `
    -ApprovedPlanSha256 $ApprovedPlanSha256 `
    -PolicyPath $FixturePolicyPath `
    -EvidenceRoot $FixtureEvidenceRoot `
    -QuarantineCheckpointForTest {
        param($TargetPath, $QuarantinePath, $Phase)
        if ($Phase -ceq 'after-quarantine-rename-before-status') {
            [IO.File]::WriteAllText(
                (Join-Path $MarkerRoot 'after-quarantine-rename.marker'),
                $QuarantinePath,
                [Text.UTF8Encoding]::new($false))
            [Environment]::FailFast('safe-delete apply crash fixture after quarantine rename')
        }
    }

throw 'safe-delete apply crash fixture did not reach the hard-crash checkpoint.'
