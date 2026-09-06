[CmdletBinding()]
param(
    [ValidateRange(1, 60000)][int]$DeadlineMs = 60000,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'full-coldstart-acceptance.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'D:\agents\projects\统一环境'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$entry = Join-Path $repo 'scripts\Invoke-CodexSafeTreeDelete.ps1'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$checkpointPath = $OutputPath + '.checkpoint.json'
if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputPath))) {
    throw 'Output directory must already exist.'
}
foreach ($writePath in @($OutputPath, $checkpointPath)) {
    if ($writePath.StartsWith($evidenceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $writePath.Equals($policyPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Acceptance output must be outside the observed evidence and policy.'
    }
}
$events = [Collections.Generic.List[object]]::new()
$runs = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$result = [ordered]@{
    artifactType = 'issue58.full-coldstart-acceptance'
    startedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    deadlineMs = $DeadlineMs
    requiredRunCount = 3
    entry = $entry
    evidenceRoot = $evidenceRoot
    policyPath = $policyPath
    outputPath = $OutputPath
    checkpointPath = $checkpointPath
    status = 'running'
    stage = 'initializing'
    before = $null
    policyBefore = $null
    runs = @()
    after = $null
    policyAfter = $null
    evidenceUnchanged = $false
    policyUnchanged = $false
    operationCountStable = $false
    semanticResultStable = $false
    passed = $false
    failures = @()
    events = @()
}

function Write-Checkpoint {
    param([Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][string]$State)
    $observedAt = [datetimeoffset]::UtcNow.ToString('o')
    $result.stage = $Stage
    $events.Add([pscustomobject]@{ stage = $Stage; state = $State; atUtc = $observedAt })
    $result.events = $events.ToArray()
    $result.runs = $runs.ToArray()
    $result.failures = $failures.ToArray()
    [IO.File]::WriteAllText($checkpointPath, ($result | ConvertTo-Json -Depth 32),
        [Text.UTF8Encoding]::new($false))
    [Console]::Error.WriteLine("[$observedAt] $Stage $State")
}

function Get-TreeFingerprint {
    param([Parameter(Mandatory)][string]$Path)
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'issue58 full Status acceptance snapshot'
    $manifestSha = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $snapshot
    $operationIds = @($snapshot.entries | Where-Object {
        $_.relativePath -cne '.' -and -not $_.relativePath.Contains('/')
    } | ForEach-Object { $_.relativePath })
    $coverage = Get-OperationIdFingerprint -OperationIds $operationIds
    [pscustomobject][ordered]@{
        manifestSha256 = [string]$manifestSha
        rootIdentity = @([string[]]$snapshot.rootIdentity)
        entryCount = @($snapshot.entries).Count
        operationCount = $coverage.count
        operationIdsSha256 = $coverage.sha256
    }
}

function Get-PolicyFingerprint {
    $snapshot = Get-CodexHookCapabilityFileSnapshot -Path $policyPath `
        -CapabilityRoot (Split-Path -Parent $policyPath) -AllowedExactPaths @($policyPath) `
        -Name 'issue58 full Status acceptance policy snapshot'
    if (-not $snapshot.exists -or $snapshot.state -cne 'regular-file' -or
        [string]::IsNullOrWhiteSpace($snapshot.sha256)) {
        throw 'Policy fingerprint did not produce a regular-file SHA-256.'
    }
    [pscustomobject][ordered]@{
        path = $snapshot.path
        sha256 = $snapshot.sha256
        length = $snapshot.bytes.Length
        identity = @($snapshot.identity)
        sddl = $snapshot.sddl
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-OperationIdFingerprint {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OperationIds)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sorted = [Collections.Generic.List[string]]::new()
    foreach ($operationId in $OperationIds) {
        if ($operationId -isnot [string] -or [string]::IsNullOrEmpty($operationId)) {
            throw 'Each operationId must be a nonempty JSON string.'
        }
        if (-not $seen.Add($operationId)) { throw 'Duplicate operationId in coverage.' }
        $sorted.Add($operationId)
    }
    $sorted.Sort([StringComparer]::Ordinal)
    [pscustomobject][ordered]@{
        count = $sorted.Count
        sha256 = Get-TextSha256 -Text (ConvertTo-Json -InputObject $sorted.ToArray() -Compress)
    }
}

function Invoke-ColdStatus {
    param([Parameter(Mandatory)][int]$Index)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repo
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-File', $entry,
            '-Mode', 'Status', '-Json')) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $run = [ordered]@{
        run = $Index
        processId = $null
        processStartedAtUtc = $null
        executable = $psi.FileName
        arguments = @($psi.ArgumentList)
        elapsedMs = $null
        timedOut = $false
        stopConfirmed = $false
        exitCode = $null
        stdoutBytes = 0
        stderr = ''
        parseSucceeded = $false
        complete = $null
        operationCount = $null
        operationIdsSha256 = $null
        operationCoverageMatches = $false
        statusSha256 = $null
        semanticSha256 = $null
        error = $null
        passed = $false
    }
    $runs.Add($run)
    Write-Checkpoint -Stage "cold-status-$Index" -State 'started'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Cold Status process did not start.' }
        $run.processId = $process.Id
        $run.processStartedAtUtc = $process.StartTime.ToUniversalTime().ToString('o')
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Write-Checkpoint -Stage "cold-status-$Index" -State 'process-started'
        $remainingMs = $DeadlineMs - $watch.ElapsedMilliseconds
        if ($remainingMs -le 0 -or -not $process.WaitForExit([int]$remainingMs)) {
            $run.timedOut = $true
            Write-Checkpoint -Stage "cold-status-$Index" -State 'deadline-exceeded-stopping'
            # This Process instance is the one created above; never resolve a PID or process name to stop it.
            if (-not $process.HasExited) { $process.Kill($true) }
            if (-not $process.WaitForExit(10000)) {
                throw 'Owned Cold Status process did not exit after Kill(entireProcessTree: true).'
            }
        }
        $run.stopConfirmed = $process.HasExited
        $watch.Stop()
        $run.elapsedMs = [long]$watch.ElapsedMilliseconds
        $run.exitCode = [int]$process.ExitCode
        if (-not [Threading.Tasks.Task]::WaitAll(
                [Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 10000)) {
            throw 'Cold Status output pipes did not close within 10000 ms after process exit.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $run.stderr = $stderrTask.GetAwaiter().GetResult()
        $run.stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
        $run.statusSha256 = Get-TextSha256 -Text $stdout
        if ($run.timedOut) { throw "Cold Status exceeded the $DeadlineMs ms deadline." }
        if ($run.exitCode -ne 0) { throw "Cold Status exited with code $($run.exitCode)." }
        if ($run.elapsedMs -ge $DeadlineMs) { throw 'Cold Status did not finish strictly before the deadline.' }
        $parsed = ConvertFrom-Json -InputObject $stdout -AsHashtable -Depth 128 -DateKind String
        if ($null -eq $parsed -or $parsed -isnot [Collections.IDictionary] -or
            $parsed.artifactType -cne 'env-governance.codex-safe-tree-delete-status' -or
            $parsed.schemaVersion -ne 1 -or $parsed.complete -isnot [bool] -or
            $parsed.operations -isnot [array]) {
            throw 'Cold Status output did not match the Status JSON contract.'
        }
        $run.parseSucceeded = $true
        $run.complete = [bool]$parsed.complete
        $run.operationCount = $parsed.operations.Count
        $operationIds = @(foreach ($operation in $parsed.operations) {
            if ($operation -isnot [Collections.IDictionary] -or -not $operation.Contains('operationId')) {
                throw 'Each Status operation must contain an operationId.'
            }
            if ($operation.operationId -isnot [string] -or [string]::IsNullOrEmpty($operation.operationId)) {
                throw 'Each operationId must be a nonempty JSON string.'
            }
            $operation.operationId
        })
        $coverage = Get-OperationIdFingerprint -OperationIds $operationIds
        $run.operationIdsSha256 = $coverage.sha256
        $run.operationCoverageMatches = $coverage.count -eq $result.before.operationCount -and
            $coverage.sha256 -ceq $result.before.operationIdsSha256
        if (-not $run.operationCoverageMatches) {
            throw 'Status operation IDs did not cover exactly the independently snapshotted evidence children.'
        }
        # Exclude only observation timing and diagnostic counters, not lifecycle or operation fields.
        [void]$parsed.Remove('capturedAtUtc')
        [void]$parsed.Remove('metrics')
        [void]$parsed.Remove('statusSegments')
        $run.semanticSha256 = Get-TextSha256 -Text ($parsed | ConvertTo-Json -Depth 100 -Compress)
        $run.passed = $true
    } catch {
        $run.error = $_.Exception.Message
    } finally {
        if ($started -and -not $process.HasExited) {
            try {
                $process.Kill($true)
                $run.stopConfirmed = $process.WaitForExit(10000)
            } catch {
                $run.error = "$($run.error) Cleanup: $($_.Exception.Message)"
            }
        }
        if ($started -and $process.HasExited) {
            $run.stopConfirmed = $true
            $run.exitCode = [int]$process.ExitCode
        }
        $watch.Stop()
        if ($null -eq $run.elapsedMs) { $run.elapsedMs = [long]$watch.ElapsedMilliseconds }
        $process.Dispose()
        Write-Checkpoint -Stage "cold-status-$Index" -State $(if ($run.passed) { 'completed' } else { 'failed' })
    }
}

try {
    Write-Checkpoint -Stage 'load-libraries' -State 'started'
    . (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
    . (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')
    Write-Checkpoint -Stage 'load-libraries' -State 'completed'
    Write-Checkpoint -Stage 'fingerprint-before-policy' -State 'started'
    $result.policyBefore = Get-PolicyFingerprint
    Write-Checkpoint -Stage 'fingerprint-before-policy' -State 'completed'
    Write-Checkpoint -Stage 'fingerprint-before-evidence' -State 'started'
    $result.before = Get-TreeFingerprint -Path $evidenceRoot
    Write-Checkpoint -Stage 'fingerprint-before-evidence' -State 'completed'
    for ($index = 1; $index -le 3; $index++) {
        Invoke-ColdStatus -Index $index
        if (-not $runs[$runs.Count - 1].passed) {
            $failures.Add("cold-status-$index failed: $($runs[$runs.Count - 1].error)")
            break
        }
    }
} catch {
    $failures.Add("$($result.stage): $($_.Exception.Message)")
    Write-Checkpoint -Stage $result.stage -State 'failed'
} finally {
    if ($null -ne $result.before) {
        try {
            Write-Checkpoint -Stage 'fingerprint-after-evidence' -State 'started'
            $result.after = Get-TreeFingerprint -Path $evidenceRoot
            $result.evidenceUnchanged = (($result.before | ConvertTo-Json -Depth 16 -Compress) -ceq
                ($result.after | ConvertTo-Json -Depth 16 -Compress))
            Write-Checkpoint -Stage 'fingerprint-after-evidence' -State 'completed'
        } catch {
            $failures.Add("fingerprint-after-evidence: $($_.Exception.Message)")
            Write-Checkpoint -Stage 'fingerprint-after-evidence' -State 'failed'
        }
    }
    if ($null -ne $result.policyBefore) {
        try {
            Write-Checkpoint -Stage 'fingerprint-after-policy' -State 'started'
            $result.policyAfter = Get-PolicyFingerprint
            $result.policyUnchanged = (($result.policyBefore | ConvertTo-Json -Depth 16 -Compress) -ceq
                ($result.policyAfter | ConvertTo-Json -Depth 16 -Compress))
            Write-Checkpoint -Stage 'fingerprint-after-policy' -State 'completed'
        } catch {
            $failures.Add("fingerprint-after-policy: $($_.Exception.Message)")
            Write-Checkpoint -Stage 'fingerprint-after-policy' -State 'failed'
        }
    }
}

if ($runs.Count -eq 3 -and @($runs | Where-Object { -not $_.passed }).Count -eq 0) {
    $result.operationCountStable = @($runs | ForEach-Object { $_.operationCount } | Select-Object -Unique).Count -eq 1
    $result.semanticResultStable = @($runs | ForEach-Object { $_.semanticSha256 } | Select-Object -Unique).Count -eq 1
}
if ($runs.Count -ne 3) { $failures.Add("Expected 3 runs; executed $($runs.Count).") }
if (-not $result.operationCountStable) { $failures.Add('Operation counts were not verified stable across 3 successful runs.') }
if (-not $result.semanticResultStable) { $failures.Add('Semantic results were not verified stable across 3 successful runs.') }
if (-not $result.evidenceUnchanged) { $failures.Add('Full evidence fingerprint was not verified unchanged.') }
if (-not $result.policyUnchanged) { $failures.Add('Policy fingerprint was not verified unchanged.') }
$result.passed = $failures.Count -eq 0
$result.status = if ($result.passed) { 'complete' } else { 'failed' }
Write-Checkpoint -Stage 'acceptance' -State $result.status
$json = $result | ConvertTo-Json -Depth 32
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
$json
if (-not $result.passed) { exit 1 }
exit 0
