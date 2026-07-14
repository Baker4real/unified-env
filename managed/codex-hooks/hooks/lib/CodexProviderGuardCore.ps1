Set-StrictMode -Version Latest

function Invoke-CodexProviderGuardCore {
    [CmdletBinding()]
    param(
        [switch]$Repair,
        [switch]$CheckNetwork,
        [Parameter(Mandatory)][scriptblock]$ReadConfigState,
        [Parameter(Mandatory)][scriptblock]$ReadEnvironmentState,
        [Parameter(Mandatory)][scriptblock]$RepairConfig,
        [Parameter(Mandatory)][scriptblock]$RepairEnvironment,
        [Parameter(Mandatory)][scriptblock]$NetworkProbe
    )
    if ($Repair -and $CheckNetwork) { throw 'Repair 与 CheckNetwork 不能同时使用。' }

    $tracker = [pscustomobject][ordered]@{ changed = $false; restartRequired = $false }
    $errors = [Collections.Generic.List[string]]::new()
    $configState = [ordered]@{ drift = $true }
    $environmentState = [ordered]@{ driftCount = 1 }
    $network = [ordered]@{ checked = $false; ok = $null; exitCode = $null; httpCode = $null; proxyUsed = $null }

    try {
        $configState = & $ReadConfigState
        $environmentState = & $ReadEnvironmentState
        if ($null -eq $configState -or -not $configState.Contains('drift')) { throw 'provider config probe contract failed' }
        if ($null -eq $environmentState -or -not $environmentState.Contains('driftCount') -or [int]$environmentState['driftCount'] -lt 0) { throw 'provider environment probe contract failed' }

        if ($Repair) {
            if ([bool]$configState['drift']) { & $RepairConfig $tracker }
            if ([int]$environmentState['driftCount'] -gt 0) { & $RepairEnvironment $tracker }
        }
        elseif ($CheckNetwork) {
            $network = & $NetworkProbe
            if ($null -eq $network -or -not $network.Contains('checked') -or -not [bool]$network['checked']) { throw 'provider network probe contract failed' }
            if (-not [bool]$network['ok']) { throw 'provider network check failed' }
        }
    }
    catch {
        $errors.Add('provider operation failed')
    }

    # Repair must be judged from a new observation, even after a partial failure.
    if ($Repair) {
        try {
            $configState = & $ReadConfigState
            $environmentState = & $ReadEnvironmentState
            if ($null -eq $configState -or -not $configState.Contains('drift')) { throw 'provider config post-read contract failed' }
            if ($null -eq $environmentState -or -not $environmentState.Contains('driftCount') -or [int]$environmentState['driftCount'] -lt 0) { throw 'provider environment post-read contract failed' }
        }
        catch {
            $errors.Add('provider post-read failed')
            $configState = [ordered]@{ drift = $true }
            $environmentState = [ordered]@{ driftCount = 1 }
        }
    }

    $driftCount = ([int][bool]$configState['drift']) + [int]$environmentState['driftCount']
    if ($Repair -and $driftCount -gt 0 -and -not $errors.Contains('provider repair did not converge')) {
        $errors.Add('provider repair did not converge')
    }
    $ok = ($errors.Count -eq 0)
    $mode = if ($Repair) { 'repair' } elseif ($CheckNetwork) { 'network-check' } else { 'check-only' }
    return [ordered]@{
        schemaVersion = 1
        hookId = 'provider-stability'
        ok = $ok
        mode = $mode
        converged = ($ok -and $driftCount -eq 0)
        driftCount = $driftCount
        repairRequired = ($driftCount -gt 0)
        changed = [bool]$tracker.changed
        restartRequired = [bool]$tracker.restartRequired
        networkCheckRequested = [bool]$CheckNetwork
        network = $network
        errors = [string[]]$errors
    }
}
