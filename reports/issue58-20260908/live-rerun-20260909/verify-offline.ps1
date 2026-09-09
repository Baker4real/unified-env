[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = 'D:\agents\projects\统一环境'
$commit = '97b7c23133be0106e212db79d35ca07497b35e71'
$git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$outputPath = Join-Path $PSScriptRoot 'offline-verification-v2.json'
if (Test-Path -LiteralPath $outputPath) { throw 'Offline verification already exists; refusing overwrite.' }

function Read-Json {
    param([string]$Name)
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name))) -AsHashtable -Depth 32 -DateKind String
}

function Get-BytesSha {
    param([byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-CommitBlobFingerprint {
    param([string]$RelativePath)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $git
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in @('--no-optional-locks', '-C', $repo, 'cat-file', 'blob', ($commit + ':' + $RelativePath))) { [void]$psi.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $memory = [IO.MemoryStream]::new()
    $started = $false
    $result = [ordered]@{ gitExitCode=$null; sha256=$null; lfOnlySha256=$null; length=$null; error=$null; cleanupConfirmed=$false }
    try {
        $started = $process.Start()
        if (-not $started) { throw 'git cat-file did not start.' }
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { throw 'git cat-file process exceeded 10000 ms.' }
        $result.gitExitCode = [int]$process.ExitCode
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($copyTask, $stderrTask), 10000)) { throw 'git cat-file pipes exceeded 10000 ms.' }
        [void]$copyTask.GetAwaiter().GetResult()
        if ($result.gitExitCode -ne 0) { throw ('git cat-file failed: ' + $stderrTask.GetAwaiter().GetResult()) }
        $bytes = $memory.ToArray()
        $result.sha256 = Get-BytesSha $bytes
        $result.length = $bytes.Length
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $result.lfOnlySha256 = Get-BytesSha ([Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n", "`n")))
    } catch { $result.error = $_.Exception.Message } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(10000) }
        $result.cleanupConfirmed = (-not $started -or $process.HasExited)
        if ($started -and $process.HasExited -and $null -eq $result.gitExitCode) { $result.gitExitCode = [int]$process.ExitCode }
        $process.Dispose()
        $memory.Dispose()
    }
    return $result
}

$result = [ordered]@{
    artifactType = 'issue58.offline-source-and-process-verification'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    commit = $commit; additionalStatusRuns = 0; exitCode = 1
    preliminaryReadOnlyProbe = @{exitCode=1; processStarted=$false; reason='Get-Command git returned multiple applications; corrected invocation selects the first application explicitly.'}
    sourceFiles = @(); fingerprintCopy = $null; processes = @(); taskResidue = @()
    checks = [ordered]@{}; errors = @()
    acknowledgedDriverRisk = 'The original driver has unbounded post-exit pipe reads and does not prove subtree exit in finally. This is an exceptional-path risk, not an observed failure; individual process exit is checked below.'
}
try {
    $preflight = Read-Json 'preflight.json'
    $postflight = Read-Json 'postflight.json'
    foreach ($path in $preflight.sources.sha256.Keys) {
        $relative = $path.Replace('\', '/')
        $blob = Read-CommitBlobFingerprint $relative
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $path))
        $liveSha = Get-BytesSha $bytes
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $lfSha = Get-BytesSha ([Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n", "`n")))
        $result.sourceFiles += [ordered]@{
            path=$relative; preflightSha256=$preflight.sources.sha256[$path]; postflightSha256=$postflight.sources.sha256[$path]
            currentSha256=$liveSha; commitBlobSha256=$blob.sha256; commitBlobLength=$blob.length; currentLength=$bytes.Length
            gitExitCode=$blob.gitExitCode; gitCleanupConfirmed=$blob.cleanupConfirmed; error=$blob.error
            preflightMatchesCurrentAndPostflight=($liveSha -ceq $preflight.sources.sha256[$path] -and $liveSha -ceq $postflight.sources.sha256[$path])
            rawCommitBytesMatch=($liveSha -ceq $blob.sha256)
            contentMatchesAfterOnlyCrlfToLf=($lfSha -ceq $blob.lfOnlySha256)
        }
    }
    $original = Join-Path $repo 'reports/issue58-20260908/evidence-fingerprint.ps1'
    $copy = Join-Path $PSScriptRoot 'evidence-fingerprint.ps1'
    $originalSha = Get-BytesSha ([IO.File]::ReadAllBytes($original))
    $copySha = Get-BytesSha ([IO.File]::ReadAllBytes($copy))
    $result.fingerprintCopy = @{ originalPath=$original; copyPath=$copy; originalSha256=$originalSha; copySha256=$copySha; exactByteMatch=($originalSha -ceq $copySha) }
    foreach ($name in @('before', 'cold-run-1', 'cold-run-2', 'cold-run-3', 'after')) {
        $command = Read-Json "$name-command.json"
        $targets = @(@{role='wrapper-or-fingerprint'; processId=$command.processId})
        if ($name.StartsWith('cold-run-')) {
            $run = Read-Json "$name.json"
            $targets += @{role='Status'; processId=$run.processId}
        }
        foreach ($target in $targets) {
            $live = Get-Process -Id $target.processId -ErrorAction SilentlyContinue
            $reused = ($null -ne $live -and $live.StartTime.ToUniversalTime() -gt [datetimeoffset]::Parse($command.finishedAtUtc).UtcDateTime)
            $processRow = @{
                run=$name; role=$target.role; processId=$target.processId
                checkedAtUtc=[datetimeoffset]::UtcNow.ToString('o')
                pidAbsent=($null -eq $live); pidReusedAfterRun=$reused; originalProcessExited=($null -eq $live -or $reused)
            }
            if ($target.role -ceq 'Status') {
                $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($run.executable)
                $executableSha = Get-BytesSha ([IO.File]::ReadAllBytes($run.executable))
                $processRow.launcherRecordedExecutable = $run.executable
                $processRow.executableFileVersion = $version.FileVersion
                $processRow.executableProductVersion = $version.ProductVersion
                $processRow.executableSha256 = $executableSha
                $processRow.executableMatchesPreflightAndPostflight = ($executableSha -ceq $preflight.executableSha256 -and $executableSha -ceq $postflight.executableSha256)
                $processRow.osLiveObservationAvailable = $null -ne $command.observedStatusChild
                $processRow.osObservationError = $command.observationError
            }
            $result.processes += $processRow
        }
    }
    $owned = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" | Where-Object {
        $_.ProcessId -ne $PID -and $null -ne $_.CommandLine -and
        $_.CommandLine.Contains($PSScriptRoot) -and
        ($_.CommandLine.Contains('run-acceptance.ps1') -or $_.CommandLine.Contains('evidence-fingerprint.ps1'))
    })
    $result.taskResidue = @($owned | ForEach-Object { @{processId=$_.ProcessId; executable=$_.ExecutablePath} })
    $result.checks.allCommitReadsSucceeded = @($result.sourceFiles | Where-Object { $_.gitExitCode -ne 0 -or $null -ne $_.error -or -not $_.gitCleanupConfirmed }).Count -eq 0
    $result.checks.allSourceHashesStable = @($result.sourceFiles | Where-Object { -not $_.preflightMatchesCurrentAndPostflight }).Count -eq 0
    $result.checks.allSourceRawBytesMatchCommit = @($result.sourceFiles | Where-Object { -not $_.rawCommitBytesMatch }).Count -eq 0
    $result.checks.allSourceContentMatchesCommitModuloCrlfOnly = @($result.sourceFiles | Where-Object { -not $_.contentMatchesAfterOnlyCrlfToLf }).Count -eq 0
    $result.checks.fingerprintCopyExact = $result.fingerprintCopy.exactByteMatch
    $result.checks.allRecordedProcessesExited = ($result.processes.Count -eq 8 -and @($result.processes | Where-Object { -not $_.originalProcessExited }).Count -eq 0)
    $result.checks.noKnownTaskResidue = $result.taskResidue.Count -eq 0
} catch { $result.errors += $_.Exception.Message }
$result.checks.noOfflineVerificationErrors = $result.errors.Count -eq 0
if ($result.checks.Count -eq 8 -and @($result.checks.Values | Where-Object { $_ -isnot [bool] -or -not $_ }).Count -eq 0) { $result.exitCode = 0 }
$stream = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $result -Depth 16))) } finally { $stream.Dispose() }
Write-Host ("offlineExitCode={0} sourceFiles={1} recordedProcesses={2} residue={3}" -f $result.exitCode, $result.sourceFiles.Count, $result.processes.Count, $result.taskResidue.Count)
exit $result.exitCode
