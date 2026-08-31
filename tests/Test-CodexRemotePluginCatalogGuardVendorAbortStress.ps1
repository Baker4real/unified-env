[CmdletBinding()]
param(
    [ValidateRange(50, 500)]
    [int]$Iterations = 50,
    [string]$EvidenceRoot = 'D:\agents\run-evidence\remote-plugin-catalog-guard'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$guardPath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\CodexRemotePluginCatalogGuard.ps1'
$policyPath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\policy.json'
$handleIoPath = Join-Path $projectRoot 'scripts\lib\CodexHookHandleBoundIO.cs'
$pwshPath = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$safeDeleteWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$runId = '{0}-vendor-abort-after-clear-stress-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N')
$evidenceDirectory = Join-Path $EvidenceRoot $runId
$eventsPath = Join-Path $evidenceDirectory 'stress-events.jsonl'
$summaryPath = Join-Path $evidenceDirectory 'summary.json'
$reportsRoot = Join-Path $projectRoot 'reports'
$fixtureParent = Join-Path $reportsRoot ("catalog-guard-tests-{0}" -f [guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $fixtureParent '.codex'
$catalogRoot = Join-Path $fixtureRoot 'cache\remote_plugin_catalog'
$catalogPath = Join-Path $catalogRoot 'aaaaaaaaaaaaaaaa.json'
$fixturePolicyPath = Join-Path $fixtureRoot 'policy.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$completedIterations = 0
$firstFailure = $null
$cleanupResult = $null

if (-not ('CodexHookGovernance.VerifiedDirectoryChainGuard' -as [type])) {
    Add-Type -Path $handleIoPath -ErrorAction Stop
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-FileSha256 {
    param([string]$Path)
    return Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Write-DurableEvidenceRecord {
    param([object]$Record)
    $line = ($Record | ConvertTo-Json -Compress -Depth 48) + "`n"
    $bytes = $utf8.GetBytes($line)
    $stream = [IO.File]::Open($eventsPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Write-DurableJsonFile {
    param([string]$Path, [object]$Value)
    $tempPath = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.stress-summary-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth 48) + "`n")
    $stream = $null
    try {
        $stream = [IO.File]::Open($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [IO.File]::Move($tempPath, $Path, $true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

function New-StressCatalog {
    param([int]$Iteration, [string]$Role)
    return [ordered]@{
        schema_version = 1
        plugins = @(
            [ordered]@{ id = 'keep-before'; name = 'before'; payload = [ordered]@{ iteration = $Iteration; role = $Role } }
            [ordered]@{ id = 'plugin_asdk_app_69418aad55e08191aa5e437b649ca2e4'; name = 'heygen'; payload = 'remove' }
            [ordered]@{ id = 'keep-after'; name = 'after'; payload = [ordered]@{ stable = $true } }
            [ordered]@{ id = "keep-stress-$Iteration"; name = "stress-$Iteration"; payload = $Role }
        )
    }
}

function ConvertTo-CatalogBytes {
    param([object]$Catalog)
    return $utf8.GetBytes(($Catalog | ConvertTo-Json -Depth 32) + "`n")
}

function Invoke-PublicSweep {
    param([byte[]]$PostIsolationReplacementBytes, [string]$DurableRenameExit)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $guardPath,
        '-Mode', 'Sweep',
        '-PolicyPath', $fixturePolicyPath,
        '-FixtureRoot', $fixtureRoot,
        '-Json'
    )) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    if ($null -ne $PostIsolationReplacementBytes) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_POST_ISOLATION_BYTES_BASE64'] = [Convert]::ToBase64String($PostIsolationReplacementBytes)
    }
    if (-not [string]::IsNullOrWhiteSpace($DurableRenameExit)) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DURABLE_RENAME_EXIT'] = $DurableRenameExit
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stdout = ''
    $stderr = ''
    $timedOut = $false
    $processId = $null
    try {
        if (-not $process.Start()) { throw 'Sweep process failed to start.' }
        $processId = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $timedOut = $true
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $result = $null
        $parseError = $null
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            try { $result = $stdout | ConvertFrom-Json -Depth 48 } catch { $parseError = $_.Exception.ToString() }
        }
        return [pscustomobject][ordered]@{
            processId = $processId
            exitCode = if ($timedOut) { $null } else { $process.ExitCode }
            timedOut = $timedOut
            durationMs = $stopwatch.ElapsedMilliseconds
            stdoutSha256 = Get-BytesSha256 -Bytes $utf8.GetBytes($stdout)
            result = $result
            parseError = $parseError
            stderr = $stderr
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
        }
        $stopwatch.Stop()
        $process.Dispose()
    }
}

function Get-ArtifactIdentity {
    param([string]$Path)
    $guard = $null
    $file = $null
    try {
        $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($catalogRoot, $catalogRoot, $false)
        $file = $guard.AcquirePreparedTempFile($Path)
        return @([string]$file.VolumeSerialNumber, [string]$file.FileIndex)
    } finally {
        if ($null -ne $file) { $file.Dispose() }
        if ($null -ne $guard) { $guard.Dispose() }
    }
}

function Get-ArtifactInventory {
    $entries = [Collections.Generic.List[object]]::new()
    if (-not [IO.Directory]::Exists($catalogRoot)) { return @() }
    foreach ($path in @([IO.Directory]::EnumerateFileSystemEntries($catalogRoot, '*', [IO.SearchOption]::TopDirectoryOnly) | Sort-Object)) {
        $leaf = [IO.Path]::GetFileName($path)
        try {
            $attributes = [IO.File]::GetAttributes($path)
            $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
            $isReparse = ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            $type = if ($isDirectory) { 'directory' } elseif ($isReparse) { 'reparse-file' } else { 'regular-file' }
            $identity = $null
            $sha256 = $null
            $length = $null
            $readError = $null
            if (-not $isDirectory -and -not $isReparse) {
                try {
                    $length = [IO.FileInfo]::new($path).Length
                    $sha256 = Get-FileSha256 -Path $path
                    $identity = @(Get-ArtifactIdentity -Path $path)
                } catch {
                    $readError = $_.Exception.ToString()
                }
            }
            $entries.Add([pscustomobject][ordered]@{
                leaf = $leaf
                type = $type
                attributes = [string]$attributes
                attributesValue = [int64]$attributes
                length = $length
                identity = $identity
                sha256 = $sha256
                readError = $readError
            })
        } catch {
            $entries.Add([pscustomobject][ordered]@{
                leaf = $leaf
                type = 'inventory-error'
                attributes = $null
                attributesValue = $null
                length = $null
                identity = $null
                sha256 = $null
                readError = $_.Exception.ToString()
            })
        }
    }
    return @($entries)
}

function Get-ProcessFailureDiagnostics {
    param([string]$Text)
    $exceptionTypes = @([regex]::Matches($Text, '(?m)(?:^|--->\s+)([A-Za-z_][A-Za-z0-9_.+]*Exception)\b') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $apis = @([regex]::Matches($Text, '\b(CreateFileW|NtSetEaFile|NtQueryEaFile|FlushFileBuffers|NtSetInformationFile|GetFileInformationByHandle|GetFinalPathNameByHandleW|MoveFileExW|DeleteFileW)\b') | ForEach-Object Value | Sort-Object -Unique)
    $nativeCodes = @([regex]::Matches($Text, 'Win32Exception\s*\((\d+)\)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
    $hResults = @([regex]::Matches($Text, '\b0x[0-9A-Fa-f]{8}\b') | ForEach-Object Value | Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        exceptionTypes = $exceptionTypes
        apis = $apis
        nativeCodes = $nativeCodes
        hResults = $hResults
    }
}

function Assert-StressCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-StressFixture {
    if (-not [IO.Directory]::Exists($fixtureParent)) {
        return [pscustomobject][ordered]@{ ok = $true; planExit = 0; applyExit = 0; purgeExit = 0 }
    }
    $planText = & $safeDeleteWrapper -Mode Plan -TargetPath $fixtureParent -CapabilityRoot $reportsRoot -Json
    $planExit = $LASTEXITCODE
    if ($planExit -ne 0) { throw "safe delete Plan failed: exit=$planExit" }
    $plan = $planText | ConvertFrom-Json -Depth 16
    $applyText = & $safeDeleteWrapper -Mode Apply -PlanPath $plan.planPath -ApprovedPlanSha256 $plan.planSha256 -ConfirmApply -Json
    $applyExit = $LASTEXITCODE
    if ($applyExit -ne 0) { throw "safe delete Apply failed: exit=$applyExit" }
    $apply = $applyText | ConvertFrom-Json -Depth 16
    $purgeText = & $safeDeleteWrapper -Mode Purge -TransactionPath $apply.transactionPath -ApprovedTransactionSha256 $apply.transactionSha256 -ConfirmPurge -Json
    $purgeExit = $LASTEXITCODE
    if ($purgeExit -ne 0) { throw "safe delete Purge failed: exit=$purgeExit" }
    $purge = $purgeText | ConvertFrom-Json -Depth 16
    return [pscustomobject][ordered]@{ ok = ($purge.purged -eq $true -and -not [IO.Directory]::Exists($fixtureParent)); planExit = $planExit; applyExit = $applyExit; purgeExit = $purgeExit }
}

[void][IO.Directory]::CreateDirectory($evidenceDirectory)
$runStartedAtUtc = [DateTime]::UtcNow
Write-DurableEvidenceRecord -Record ([ordered]@{
    schemaVersion = 1
    event = 'stress-start'
    timestampUtc = $runStartedAtUtc.ToString('o')
    runId = $runId
    iterationsRequested = $Iterations
    faultPoint = 'vendor-abort:after-clear'
    runtimeSha256 = Get-FileSha256 -Path $guardPath
    policySha256 = Get-FileSha256 -Path $policyPath
    fixtureRoot = $fixtureRoot
    payloadRecorded = $false
})

try {
    [void][IO.Directory]::CreateDirectory($catalogRoot)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot '.remote-plugin-catalog-guard-fixture'), "fixture-v1`n", $utf8)
    [IO.File]::WriteAllBytes($fixturePolicyPath, [IO.File]::ReadAllBytes($policyPath))

    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        $iterationStartedAtUtc = [DateTime]::UtcNow
        $faultInvocation = $null
        $recoveryInvocation = $null
        $phase = 'setup'
        try {
            $beforeBytes = ConvertTo-CatalogBytes -Catalog (New-StressCatalog -Iteration $iteration -Role 'before')
            $vendorBytes = ConvertTo-CatalogBytes -Catalog (New-StressCatalog -Iteration $iteration -Role 'vendor')
            [IO.File]::WriteAllBytes($catalogPath, $beforeBytes)

            $phase = 'fault-injection'
            $faultInvocation = Invoke-PublicSweep -PostIsolationReplacementBytes $vendorBytes -DurableRenameExit 'vendor-abort:after-clear'
            $faultInventory = @(Get-ArtifactInventory)
            Write-DurableEvidenceRecord -Record ([ordered]@{
                schemaVersion = 1
                event = 'operation-result'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                iteration = $iteration
                operation = 'fault-injection'
                process = [ordered]@{ id = $faultInvocation.processId; exitCode = $faultInvocation.exitCode; timedOut = $faultInvocation.timedOut; durationMs = $faultInvocation.durationMs }
                handleStage = 'vendor-abort staging delete disposition cleared; before handle-bound no-replace rename'
                result = $faultInvocation.result
                parseError = $faultInvocation.parseError
                stderr = $faultInvocation.stderr
                inventory = $faultInventory
            })
            Assert-StressCondition ($faultInvocation.exitCode -eq 89 -and -not $faultInvocation.timedOut -and $null -eq $faultInvocation.result) "fault process did not stop at exit 89: exit=$($faultInvocation.exitCode) timeout=$($faultInvocation.timedOut)"
            Assert-StressCondition ([IO.File]::Exists($catalogPath) -and (Get-FileSha256 -Path $catalogPath) -ceq (Get-BytesSha256 -Bytes $vendorBytes)) 'fault process changed or removed vendor canonical'
            $stageEntries = @($faultInventory | Where-Object leaf -CLike '.codex-catalog-guard-*.stage-*.vendor-abort')
            Assert-StressCondition ($stageEntries.Count -eq 1) "fault process did not leave exactly one managed vendor-abort staging artifact: count=$($stageEntries.Count)"

            $phase = 'recovery'
            $recoveryInvocation = Invoke-PublicSweep
            $recoveryInventory = @(Get-ArtifactInventory)
            Write-DurableEvidenceRecord -Record ([ordered]@{
                schemaVersion = 1
                event = 'operation-result'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                iteration = $iteration
                operation = 'recovery'
                process = [ordered]@{ id = $recoveryInvocation.processId; exitCode = $recoveryInvocation.exitCode; timedOut = $recoveryInvocation.timedOut; durationMs = $recoveryInvocation.durationMs }
                handleStage = 'public Sweep reconciliation and vendor canonical filtering'
                result = $recoveryInvocation.result
                parseError = $recoveryInvocation.parseError
                stderr = $recoveryInvocation.stderr
                inventory = $recoveryInventory
            })
            Assert-StressCondition ($recoveryInvocation.exitCode -eq 0 -and -not $recoveryInvocation.timedOut -and $null -ne $recoveryInvocation.result -and $recoveryInvocation.result.ok -eq $true) "recovery Sweep failed: exit=$($recoveryInvocation.exitCode) timeout=$($recoveryInvocation.timedOut)"
            Assert-StressCondition (@($recoveryInventory | Where-Object leaf -CLike '.codex-catalog-guard-*').Count -eq 0) 'recovery Sweep left transaction or staging artifacts'
            Assert-StressCondition ([IO.File]::Exists($catalogPath)) 'recovery Sweep removed canonical'
            $recoveredCatalog = [IO.File]::ReadAllText($catalogPath, $utf8) | ConvertFrom-Json -Depth 32
            Assert-StressCondition ((@($recoveredCatalog.plugins.name) -join ',') -ceq "before,after,stress-$iteration") 'recovery Sweep did not preserve the expected vendor non-target entries'

            [IO.File]::Delete($catalogPath)
            $completedIterations++
            Write-DurableEvidenceRecord -Record ([ordered]@{
                schemaVersion = 1
                event = 'iteration-complete'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                iteration = $iteration
                ok = $true
                durationMs = [int64]([DateTime]::UtcNow - $iterationStartedAtUtc).TotalMilliseconds
            })
        } catch {
            $combinedProcessStderr = @(
                if ($null -ne $faultInvocation) { [string]$faultInvocation.stderr }
                if ($null -ne $recoveryInvocation) { [string]$recoveryInvocation.stderr }
            ) -join "`n"
            $diagnosticText = $_.Exception.ToString() + "`n" + $_.ScriptStackTrace + "`n" + $combinedProcessStderr
            $parsedDiagnostics = Get-ProcessFailureDiagnostics -Text $diagnosticText
            $firstFailure = [pscustomobject][ordered]@{
                iteration = $iteration
                phase = $phase
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                harnessExceptionType = $_.Exception.GetType().FullName
                harnessException = $_.Exception.ToString()
                harnessScriptStack = $_.ScriptStackTrace
                processStderr = $combinedProcessStderr
                exceptionTypes = @($parsedDiagnostics.exceptionTypes)
                apis = @($parsedDiagnostics.apis)
                nativeCodes = @($parsedDiagnostics.nativeCodes)
                hResults = @($parsedDiagnostics.hResults)
                faultProcess = if ($null -eq $faultInvocation) { $null } else { [ordered]@{ id = $faultInvocation.processId; exitCode = $faultInvocation.exitCode; timedOut = $faultInvocation.timedOut; durationMs = $faultInvocation.durationMs } }
                recoveryProcess = if ($null -eq $recoveryInvocation) { $null } else { [ordered]@{ id = $recoveryInvocation.processId; exitCode = $recoveryInvocation.exitCode; timedOut = $recoveryInvocation.timedOut; durationMs = $recoveryInvocation.durationMs } }
                handleStage = if ($phase -ceq 'fault-injection') { 'vendor-abort staging delete disposition cleared; before handle-bound no-replace rename' } else { 'public Sweep reconciliation and vendor canonical filtering' }
                inventory = @(Get-ArtifactInventory)
                payloadRecorded = $false
            }
            Write-DurableEvidenceRecord -Record ([ordered]@{
                schemaVersion = 1
                event = 'stress-failure'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                failure = $firstFailure
            })
            break
        }
    }
} finally {
    try { $cleanupResult = Remove-StressFixture } catch {
        $cleanupResult = [pscustomobject][ordered]@{ ok = $false; error = $_.Exception.ToString() }
        if ($null -eq $firstFailure) {
            $firstFailure = [pscustomobject][ordered]@{
                iteration = $completedIterations + 1
                phase = 'fixture-cleanup'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                harnessExceptionType = $_.Exception.GetType().FullName
                harnessException = $_.Exception.ToString()
                harnessScriptStack = $_.ScriptStackTrace
                processStderr = ''
                exceptionTypes = @($_.Exception.GetType().FullName)
                apis = @()
                nativeCodes = @()
                hResults = @()
                inventory = @()
                payloadRecorded = $false
            }
        }
    }
    $summary = [ordered]@{
        schemaVersion = 1
        runId = $runId
        startedAtUtc = $runStartedAtUtc.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        faultPoint = 'vendor-abort:after-clear'
        iterationsRequested = $Iterations
        iterationsCompleted = $completedIterations
        failureCount = if ($null -eq $firstFailure) { 0 } else { 1 }
        status = if ($null -eq $firstFailure -and $cleanupResult.ok) { 'passed-not-reproduced' } else { 'failed' }
        firstFailure = $firstFailure
        cleanup = $cleanupResult
        eventsPath = $eventsPath
        runtimeSha256 = Get-FileSha256 -Path $guardPath
        policySha256 = Get-FileSha256 -Path $policyPath
        residual = if ($null -eq $firstFailure) { "本次 $Iterations 次连续运行未复现间歇 I/O 失败；这不是历史根因已被证明修复。" } else { $null }
        payloadRecorded = $false
    }
    Write-DurableJsonFile -Path $summaryPath -Value $summary
}

if ($null -ne $firstFailure -or -not $cleanupResult.ok) {
    Write-Error "FAIL Test-CodexRemotePluginCatalogGuardVendorAbortStress completed=$completedIterations evidence=$summaryPath"
    exit 1
}

Write-Output "PASS Test-CodexRemotePluginCatalogGuardVendorAbortStress iterations=$completedIterations failures=0 evidence=$summaryPath"
