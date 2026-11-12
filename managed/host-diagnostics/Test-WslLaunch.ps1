#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/wsl-launch-tests')
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Watch-WslLaunch.ps1'
$cases = [Collections.Generic.List[object]]::new()

function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $cases.Add([pscustomobject]@{name=$Name;passed=$true}) }
    catch { $cases.Add([pscustomobject]@{name=$Name;passed=$false;reason=$_.Exception.Message}) }
}
function Assert([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
function Start-Entry([string[]]$Arguments, [string]$OwnerToken) {
    Assert (Test-Path -LiteralPath $entry -PathType Leaf) 'wsl-launch-entry-missing'
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    if ($OwnerToken) { $psi.Environment['DSH_WSL_WATCH_OWNER_TOKEN'] = $OwnerToken }
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$entry) + $Arguments) { $psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
    }
}
function Complete-Entry($Handle, [int]$TimeoutMs) {
    if (-not $Handle.Process.WaitForExit($TimeoutMs)) {
        $Handle.Process.Kill($true)
        [void]$Handle.Process.WaitForExit(5000)
        throw 'wsl-launch-monitor-timeout'
    }
    $stdout = $Handle.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Handle.StderrTask.GetAwaiter().GetResult()
    Assert ([string]::IsNullOrWhiteSpace($stderr)) 'wsl-launch-unexpected-stderr'
    [pscustomobject]@{
        exitCode = $Handle.Process.ExitCode
        report = ($stdout | ConvertFrom-Json -ErrorAction Stop)
    }
}
function Stop-OwnedProcess($Handle) {
    if ($null -ne $Handle -and $null -ne $Handle.Process) {
        if (-not $Handle.Process.HasExited) { $Handle.Process.Kill($true); [void]$Handle.Process.WaitForExit(5000) }
        $Handle.Process.Dispose()
    }
}

Check 'new-process-records-target-command-line-and-parent-identity' {
    $monitor = $null
    $target = $null
    try {
        $captureRoot = Join-Path $runRoot 'capture'
        $monitor = Start-Entry @(
            '-EvidenceDirectory',$captureRoot,
            '-DurationSeconds','20',
            '-PollMilliseconds','100',
            '-StopAfterFirst',
            '-ProcessNameForTest','ping.exe'
        )
        $eventLog = Join-Path $captureRoot 'events.jsonl'
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        $ready = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $eventLog -PathType Leaf) {
                $ready = @((Get-Content -LiteralPath $eventLog -ErrorAction Stop) | Where-Object { $_ -match 'monitor-start' }).Count -gt 0
                if ($ready) { break }
            }
            Start-Sleep -Milliseconds 100
        }
        Assert $ready 'wsl-launch-monitor-not-ready'

        $targetStart = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/ping.exe'))
        $targetStart.UseShellExecute = $false; $targetStart.CreateNoWindow = $true
        foreach ($argument in @('-n','5','127.0.0.1')) { $targetStart.ArgumentList.Add($argument) }
        $target = [Diagnostics.Process]::Start($targetStart)
        $completed = Complete-Entry $monitor 15000
        Assert ($completed.exitCode -eq 0 -and $completed.report.status -eq 'complete') 'wsl-launch-capture-failed'
        Assert ($completed.report.processSeen -eq $true -and $completed.report.stopReason -eq 'first-process') 'wsl-launch-stop-contract'

        $events = @([IO.File]::ReadAllLines($eventLog) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
        $matches = @($events | Where-Object { $_.kind -eq 'process-start' -and $_.process.processId -eq $target.Id })
        Assert ($matches.Count -eq 1) 'started-process-not-captured'
        $observation = $matches[0]
        Assert ($observation.process.commandLine.Contains('127.0.0.1')) 'target-command-line-missing'
        Assert ($null -ne $observation.process.creationDate -and $null -ne $observation.process.executablePath) 'target-identity-incomplete'
        Assert ($observation.parent.processId -eq $PID -and $observation.parent.name -eq 'pwsh.exe') 'parent-identity-mismatch'
        Assert ($null -eq $observation.parent.commandLine) 'parent-command-line-not-omitted'
    }
    finally {
        if ($null -ne $target) {
            if (-not $target.HasExited) { $target.Kill($true); [void]$target.WaitForExit(5000) }
            $target.Dispose()
        }
        if ($null -ne $monitor) { Stop-OwnedProcess $monitor }
    }
}

Check 'quiet-window-completes-without-inventing-a-process' {
    $monitor = $null
    try {
        $captureRoot = Join-Path $runRoot 'quiet'
        $processName = 'absent-' + [guid]::NewGuid().ToString('N') + '.exe'
        $ownerToken = [guid]::NewGuid().ToString('N')
        $expectedOwnerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($ownerToken))).ToLowerInvariant()
        $monitor = Start-Entry @(
            '-EvidenceDirectory',$captureRoot,
            '-DurationSeconds','5',
            '-PollMilliseconds','100',
            '-ProcessNameForTest',$processName
        ) $ownerToken
        $completed = Complete-Entry $monitor 10000
        Assert ($completed.exitCode -eq 0 -and $completed.report.status -eq 'complete') 'quiet-window-failed'
        Assert ($completed.report.processSeen -eq $false -and $completed.report.eventCount -eq 0) 'quiet-window-false-positive'
        Assert ($completed.report.stopReason -eq 'duration-elapsed') 'quiet-window-stop-reason'
        Assert ($completed.report.ownerTokenSha256 -eq $expectedOwnerHash) 'owner-token-hash-mismatch'
    }
    finally { if ($null -ne $monitor) { Stop-OwnedProcess $monitor } }
}

$results = @($cases)
[pscustomobject]@{status=$(if (@($results | Where-Object { -not $_.passed }).Count -eq 0) { 'passed' } else { 'failed' });cases=$results.Count;results=$results;evidenceDirectory=$runRoot} | ConvertTo-Json -Depth 8 -Compress
if (@($results | Where-Object { -not $_.passed }).Count -gt 0) { exit 1 }
