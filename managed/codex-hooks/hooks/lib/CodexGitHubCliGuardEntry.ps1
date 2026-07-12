Set-StrictMode -Version Latest

function New-CodexGitHubCliGuardPayload {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Errors
    )
    return [ordered]@{
        ok = $Ok
        sourcePath = 'D:\Codex\tools\gh\bin\gh.exe'
        nativePath = 'D:\Codex\tools\bin\gh.exe'
        sourceExists = $false
        sourceSignature = $null
        hardLinkState = $null
        nativeHardLinkOk = $false
        processPathOk = $false
        persistentPathOk = $false
        resolvedExecutablePath = $null
        managedResolutionOk = $false
        processGhConfigDirOk = $false
        persistentGhConfigDirOk = $false
        hostsExists = $false
        versionProbe = [ordered]@{ success = $false; skipped = $true; attemptCount = 0 }
        authProbe = [ordered]@{ checked = $false; success = $null; skipped = $true }
        authCheckRequested = $false
        repairs = [string[]]@()
        backupPath = $null
        restartRequired = [bool]$State.restartRequired
        changed = [bool]$State.changed
        errors = [string[]]$Errors
    }
}

function Set-CodexGitHubCliPayloadState {
    param([Parameter(Mandatory)][Collections.IDictionary]$Payload, [Parameter(Mandatory)][object]$State)
    $Payload['changed'] = [bool]$State.changed
    $Payload['restartRequired'] = [bool]$State.restartRequired
    if (-not $Payload.Contains('errors')) { $Payload['errors'] = [string[]]@() }
    else { $Payload['errors'] = [string[]]@($Payload['errors']) }
    return $Payload
}

function Invoke-CodexGitHubCliGuardEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][scriptblock]$HealthWriter,
        [switch]$Json,
        [switch]$Strict
    )
    $state = [pscustomobject][ordered]@{ changed = $false; restartRequired = $false }
    $payload = $null
    try {
        $operationOutput = @(& $Operation $state)
        if ($operationOutput.Count -ne 1 -or $operationOutput[0] -isnot [Collections.IDictionary]) { throw 'guard operation contract failed' }
        $payload = Set-CodexGitHubCliPayloadState -Payload $operationOutput[0] -State $state
    }
    catch {
        $payload = New-CodexGitHubCliGuardPayload -State $state -Ok $false -Errors ([string[]]@('github-cli guard failed'))
    }

    try { $null = @(& $HealthWriter $state $payload) }
    catch { $payload = New-CodexGitHubCliGuardPayload -State $state -Ok $false -Errors ([string[]]@('health write failed')) }

    $failed = -not [bool]$payload['ok']
    if ($Json) { Write-Output ($payload | ConvertTo-Json -Depth 8 -Compress) }
    elseif ($failed) { [Console]::Error.WriteLine('WARNING: Codex GitHub CLI guard could not complete.') }
    if ($Strict -and $failed) { throw 'Codex GitHub CLI guard failed.' }
}
