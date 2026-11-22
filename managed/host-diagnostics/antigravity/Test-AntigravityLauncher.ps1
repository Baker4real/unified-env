#Requires -Version 7.5
[CmdletBinding(DefaultParameterSetName = 'Launcher')]
param(
    [Parameter(ParameterSetName = 'Launcher')][string]$EvidenceRoot = 'D:/agents/run-evidence/antigravity-launcher-tests',
    [Parameter(Mandatory, ParameterSetName = 'LockedUpgrade')][string]$UpgradeFixtureRoot,
    [Parameter(Mandatory, ParameterSetName = 'LockedUpgrade')][string]$ReconcilerPath,
    [Parameter(Mandatory, ParameterSetName = 'LockedUpgrade')][string]$NodeExe
)

$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
function Assert-OrdinaryFixtureAncestry([string]$Directory, [switch]$AllowMissing) {
    $parents = [Collections.Generic.Stack[string]]::new()
    for ($entry = $Directory; $entry; $entry = [IO.Path]::GetDirectoryName($entry)) { $parents.Push($entry) }
    foreach ($entry in $parents) {
        try { $attrs = [IO.File]::GetAttributes($entry) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
            if ($AllowMissing) { continue }
            throw
        }
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -or -not ($attrs -band [IO.FileAttributes]::Directory)) {
            throw "Launcher fixture requires an ordinary directory: $entry"
        }
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Launcher') {
    $outputRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([char]'\')
    if ($outputRoot -ine 'D:\agents\run-evidence\antigravity-launcher-tests') { throw 'Launcher fixture output requires its evidence directory.' }
    Assert-OrdinaryFixtureAncestry $outputRoot -AllowMissing
    $runRoot = Join-Path $outputRoot ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($runRoot)
} else {
    $runRoot = [IO.Path]::GetFullPath($UpgradeFixtureRoot)
    if ($runRoot -notmatch '\AD:\\(?:agents\\tmp|Codex\\temp)\\antigravity-addons-(?:unit|e2e)-[a-z0-9]{6}\\[a-z0-9-]+\z') {
        throw 'Launcher upgrade requires a generated Antigravity fixture root.'
    }
    Assert-OrdinaryFixtureAncestry $runRoot
    $pendingDirectories = [Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($runRoot)
    while ($pendingDirectories.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $pendingDirectories.Pop() -Force) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Launcher fixture contains a reparse point: $($entry.FullName)"
            }
            if ($entry.PSIsContainer) { $pendingDirectories.Push($entry.FullName) }
        }
    }
    foreach ($child in 'app/resources/bin', 'backup', 'state', 'evidence') {
        Assert-OrdinaryFixtureAncestry (Join-Path $runRoot $child)
    }
    $repoReconciler = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../antigravity-addons/reconcile-addons.mjs'))
    $stagedReconciler = Join-Path ([IO.Path]::GetDirectoryName($runRoot)) 'tools/reconcile-addons.mjs'
    $ReconcilerPath = [IO.Path]::GetFullPath($ReconcilerPath)
    if ($ReconcilerPath -ine $repoReconciler -and $ReconcilerPath -ine $stagedReconciler) { throw 'Launcher fixture requires its source reconciler.' }
    Assert-OrdinaryFixtureAncestry ([IO.Path]::GetDirectoryName($ReconcilerPath))
    if (([IO.File]::GetAttributes($ReconcilerPath) -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-FileHash -LiteralPath $ReconcilerPath).Hash -cne (Get-FileHash -LiteralPath $repoReconciler).Hash) {
        throw 'Launcher fixture reconciler must match the repository source.'
    }
}
$testExe = Join-Path $runRoot 'TestLauncher.exe'
if (Test-Path -LiteralPath $testExe) { throw 'Launcher fixture compiler output already exists.' }
& $compiler /nologo /target:exe /platform:x64 /main:TestLauncher /r:System.Windows.Forms.dll "/out:$testExe" (Join-Path $PSScriptRoot 'LaunchAntigravity.cs') (Join-Path $PSScriptRoot 'Test-LaunchAntigravity.cs')
if ($LASTEXITCODE -ne 0) { throw "Launcher fixture compilation failed ($LASTEXITCODE)." }
if ($PSCmdlet.ParameterSetName -eq 'Launcher') {
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw "Launcher fixture failed ($LASTEXITCODE)." }
    return
}

$appDirectory = Join-Path $runRoot 'app'
$stateRoot = Join-Path $runRoot 'state'
$asar = Join-Path $appDirectory 'resources/app.asar'
$fixtureArguments = @('--app-dir', $appDirectory, '--state-root', $stateRoot,
    '--backup-dir', (Join-Path $runRoot 'backup'), '--evidence-root', (Join-Path $runRoot 'evidence'))

function Invoke-LauncherFixture([string]$Action = '--reconcile-fixture') {
    $outcome = & $testExe $Action
    if ($LASTEXITCODE -ne 0) { throw "Launcher promotion fixture failed ($LASTEXITCODE)." }
    $outcome
}

# The installer stand-in has already replaced the payload and "reopened" it. Allow reads but deny rename/delete.
$lock = [IO.File]::Open($asar, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    # PostQuit invokes this same reconciler command with the installed paths.
    $staged = & $NodeExe $ReconcilerPath 'reconcile' '--apply' @fixtureArguments
    if ($LASTEXITCODE -ne 0) { throw "Locked reconciliation failed ($LASTEXITCODE)." }
    $pendingStatus = & $NodeExe $ReconcilerPath 'status' @fixtureArguments
    if ($LASTEXITCODE -ne 0) { throw "Status while locked failed ($LASTEXITCODE)." }
    $retry = & $NodeExe $ReconcilerPath 'reconcile' '--apply' @fixtureArguments
    if ($LASTEXITCODE -ne 0) { throw "Locked reconciliation retry failed ($LASTEXITCODE)." }
    $launcherWhileReopened = Invoke-LauncherFixture '--reconcile-reopened-fixture'
    $launcherWhileLocked = Invoke-LauncherFixture
    $asarWhileLocked = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash.ToLowerInvariant()
    $pendingWhileLocked = (Get-FileHash -LiteralPath (Join-Path $stateRoot 'pending-app.asar') -Algorithm SHA256).Hash.ToLowerInvariant()
    $activeWhileLocked = (Get-FileHash -LiteralPath (Join-Path $stateRoot 'active-build.json') -Algorithm SHA256).Hash.ToLowerInvariant()
} finally {
    $lock.Dispose()
}

[pscustomobject]@{
    staged = ($staged | ConvertFrom-Json)
    pendingStatus = ($pendingStatus | ConvertFrom-Json)
    retry = ($retry | ConvertFrom-Json)
    launcherWhileReopened = $launcherWhileReopened
    launcherWhileLocked = $launcherWhileLocked
    asarWhileLocked = $asarWhileLocked
    pendingWhileLocked = $pendingWhileLocked
    activeWhileLocked = $activeWhileLocked
    promotion = (Invoke-LauncherFixture)
    subsequentLaunch = (Invoke-LauncherFixture)
} | ConvertTo-Json -Depth 12 -Compress
