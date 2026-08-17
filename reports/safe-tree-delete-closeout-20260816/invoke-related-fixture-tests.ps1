# Related fixture regressions for #22/#46/#48/#54. Isolated fixtures only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$tests = @(
    @{ id = 'LeafStreamSet'; relative = 'tests\Test-CodexSafeTreeDeleteLeafStreamSet.ps1'; tickets = @('54') }
    @{ id = 'Status'; relative = 'tests\Test-CodexSafeTreeDeleteStatus.ps1'; tickets = @('22', '48') }
    @{ id = 'FileSystem'; relative = 'tests\Test-CodexSafeTreeDeleteFileSystem.ps1'; tickets = @('35') }
    @{ id = 'HashSafely'; relative = 'tests\Test-CodexSafeTreeDeleteHashSafely.ps1'; tickets = @('22') }
    @{ id = 'CrashSafety'; relative = 'tests\Test-CodexSafeTreeDeleteCrashSafety.ps1'; tickets = @('54') }
    @{ id = 'SerenaBehavior'; relative = 'tests\Test-CodexSerenaBehaviorHooks.ps1'; tickets = @('46') }
    @{ id = 'HookInventory'; relative = 'tests\Test-CodexHookInventory.ps1'; tickets = @('46') }
)

$results = @()
foreach ($test in $tests) {
    $scriptPath = Join-Path $projectRoot $test.relative
    $stdoutPath = Join-Path $PSScriptRoot ("fixture-{0}.stdout.txt" -f $test.id)
    $stderrPath = Join-Path $PSScriptRoot ("fixture-{0}.stderr.txt" -f $test.id)
    $started = [datetimeoffset]::UtcNow
    $process = Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath) `
        -WorkingDirectory $projectRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru -NoNewWindow -Wait
    $finished = [datetimeoffset]::UtcNow
    $results += [ordered]@{
        id = $test.id
        tickets = @($test.tickets)
        script = $test.relative
        exitCode = [int]$process.ExitCode
        wallClockSeconds = [math]::Round(($finished - $started).TotalSeconds, 3)
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        stdoutBytes = [long](Get-Item -LiteralPath $stdoutPath).Length
        stderrBytes = [long](Get-Item -LiteralPath $stderrPath).Length
    }
}

$document = [ordered]@{
    artifactType = 'unified-environment.safe-tree-delete.closeout-20260816.related-fixture-tests'
    schemaVersion = 1
    generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    runtime = [ordered]@{
        psEdition = [string]$PSVersionTable.PSEdition
        psVersion = [string]$PSVersionTable.PSVersion
    }
    results = @($results)
}
[IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$document
