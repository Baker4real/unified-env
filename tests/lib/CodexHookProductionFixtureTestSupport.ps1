Set-StrictMode -Version Latest

function Get-CodexHookProductionFixtureLifecycleMutexName {
    return 'Local\CodexHookProductionRegistrationRepairFixtureLifecycleV1'
}

function Enter-CodexHookProductionFixtureLifecycle {
    param(
        [ValidateRange(0, 600000)]
        [int]$TimeoutMilliseconds = 120000
    )

    $mutex = [Threading.Mutex]::new($false, (Get-CodexHookProductionFixtureLifecycleMutexName))
    $held = $false
    $abandoned = $false
    try {
        try {
            $held = $mutex.WaitOne($TimeoutMilliseconds)
        } catch [Threading.AbandonedMutexException] {
            # WaitOne grants ownership while reporting the previous owner's abandonment.
            $held = $true
            $abandoned = $true
        }
        if (-not $held) {
            throw 'production fixture lifecycle mutex timeout。'
        }
        return [pscustomobject][ordered]@{
            mutex = $mutex
            held = $true
            abandoned = $abandoned
        }
    } catch {
        if (-not $held) { $mutex.Dispose() }
        throw
    }
}

function Exit-CodexHookProductionFixtureLifecycle {
    param([Parameter(Mandatory)][object]$Lease)

    try {
        if ($Lease.held) {
            [void]$Lease.mutex.ReleaseMutex()
            $Lease.held = $false
        }
    } finally {
        $Lease.mutex.Dispose()
    }
}
