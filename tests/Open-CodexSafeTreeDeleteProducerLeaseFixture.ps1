param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][string]$CapabilityRoot,
    [Parameter(Mandatory)][string]$FixturePolicyPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$ReleasePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

$lease = New-CodexSafeTreeDeleteProducerLease `
    -TargetPath $TargetPath `
    -CapabilityRoot $CapabilityRoot `
    -PolicyPath $FixturePolicyPath
try {
    [IO.File]::WriteAllText(
        $ReadyPath,
        ($lease.identity -join '|'),
        [Text.UTF8Encoding]::new($false))
    $deadline = [datetimeoffset]::UtcNow.AddSeconds(30)
    while (-not [IO.File]::Exists($ReleasePath)) {
        if ([datetimeoffset]::UtcNow -ge $deadline) {
            throw 'producer lease fixture release timeout。'
        }
        Start-Sleep -Milliseconds 25
    }
} finally {
    $lease.Dispose()
}
