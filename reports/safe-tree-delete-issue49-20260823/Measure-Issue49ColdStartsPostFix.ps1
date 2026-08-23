# Drive 3 independent production Status cold starts at the post-MED-fix code state.
# Same protocol as Measure-Issue49ColdStarts.ps1, indices 5-7, separate summary file.
# Not an authorization.
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$invoke = Join-Path $OutputDirectory 'invoke-status-cold.ps1'
if (-not [IO.File]::Exists($invoke)) {
    throw "missing $invoke"
}
if ([string]$PSVersionTable.PSEdition -cne 'Core' -or
    [version]$PSVersionTable.PSVersion -lt [version]'7.6.0') {
    throw "Measure-Issue49ColdStartsPostFix 必须在 PowerShell Core 7.6+ 运行。"
}

$runs = [Collections.Generic.List[object]]::new()
for ($index = 5; $index -le 7; $index++) {
    Write-Host ("starting cold-{0} in a new pwsh (post MED fix)" -f $index)
    $child = Start-Process -FilePath $pwsh `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $invoke,
            '-Index', [string]$index,
            '-OutputDirectory', $OutputDirectory
        ) `
        -WorkingDirectory $OutputDirectory `
        -PassThru -NoNewWindow -Wait
    if ([int]$child.ExitCode -ne 0) {
        throw "cold-$index launcher exited $([int]$child.ExitCode)"
    }
    $runPath = Join-Path $OutputDirectory ("cold-{0}.json" -f $index)
    $runs.Add((Get-Content -Raw -LiteralPath $runPath | ConvertFrom-Json -Depth 16))
}

$summary = [ordered]@{
    issue = 49
    kind = 'post-med-fix-official-triple'
    protocol = (Join-Path $OutputDirectory 'protocol.md')
    measuredAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    codeStateNote = 'CodexSafeTreeDeleteStatusScan.cs 含 MED-1a/1b/2 回退修复；cold-1/2/3 为修复前历史样本，cold-4 为修复后单次确认样本'
    coldStarts = @($runs | ForEach-Object {
        [ordered]@{
            runIndex = $_.runIndex
            wallClockSeconds = $_.wallClockSeconds
            elapsedMs = $_.elapsedMs
            operationCount = $_.operationCount
            entriesScanned = $_.entriesScanned
            bytesHashed = $_.bytesHashed
            exitCode = $_.exitCode
            childPid = $_.childPid
            capturedAtUtc = $_.capturedAtUtc
            zeroWrite = $_.zeroWrite
            leftoverShaUnchanged = $_.leftoverShaUnchanged
            leftoverLifecycle = $_.leftoverLifecycle
            leftoverInBlocking = $_.leftoverInBlocking
            purgedManualReviewCount = $_.purgedManualReviewCount
            complete = $_.complete
            blockingCount = $_.blockingCount
            statusSegments = $_.statusSegments
            metTarget = $_.metTarget
        }
    })
    allUnder60s = @($runs | Where-Object { [double]$_.wallClockSeconds -ge 60 }).Count -eq 0
    allZeroWrite = @($runs | Where-Object { -not [bool]$_.zeroWrite }).Count -eq 0
    leftoverShaStable = @($runs | Where-Object { -not [bool]$_.leftoverShaUnchanged }).Count -eq 0
    metTarget = (
        (@($runs | Where-Object { [double]$_.wallClockSeconds -ge 60 }).Count -eq 0) -and
        (@($runs | Where-Object { -not [bool]$_.zeroWrite }).Count -eq 0) -and
        (@($runs | Where-Object { [int]$_.exitCode -ne 0 }).Count -eq 0)
    )
}
$summaryPath = Join-Path $OutputDirectory 'cold-summary-post-fix.json'
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false))
[pscustomobject]$summary
