[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('pre-payload','post-mutation','health-writer','success')][string]$Case,
    [switch]$Json,
    [switch]$Strict
)

$ErrorActionPreference='Stop'
$entry='D:\Codex\projects\统一环境\managed\codex-hooks\hooks\lib\CodexGitHubCliGuardEntry.ps1'
. $entry
$operation={
    param($state)
    switch($Case){
        'pre-payload' { throw 'fixture secret must not escape' }
        'post-mutation' { $state.changed=$true;$state.restartRequired=$true;throw 'fixture secret after mutation' }
        default {
            $payload=New-CodexGitHubCliGuardPayload -State $state -Ok $true -Errors ([string[]]@())
            $payload.sourceExists=$true;$payload.nativeHardLinkOk=$true;$payload.processPathOk=$true;$payload.persistentPathOk=$true;$payload.managedResolutionOk=$true;$payload.processGhConfigDirOk=$true;$payload.persistentGhConfigDirOk=$true;$payload.versionProbe=[ordered]@{success=$true;skipped=$false;attemptCount=1}
            return $payload
        }
    }
}.GetNewClosure()
$healthWriter={
    param($state,$payload)
    if($Case -ceq 'post-mutation' -and (-not $state.changed -or -not $state.restartRequired)){throw 'fixture state was lost before health'}
    if($Case -ceq 'pre-payload' -and ($state.changed -or $state.restartRequired)){throw 'fixture pre-payload state drifted'}
    if($Case -ceq 'health-writer'){throw 'fixture health secret'}
}.GetNewClosure()
Invoke-CodexGitHubCliGuardEntry -Operation $operation -HealthWriter $healthWriter -WriteHealth:$true -Json:$Json -Strict:$Strict
