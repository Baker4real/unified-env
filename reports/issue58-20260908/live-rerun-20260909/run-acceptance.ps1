[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = 'D:\agents\projects\统一环境'
$pwsh = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$expectedHead = '97b7c23133be0106e212db79d35ca07497b35e71'
$frozenSha = '88d4b67943d7d451931c024ad031a591efcffd528df9acbcb5e0d566d5938ad6'
$coldScript = Join-Path $repo 'reports/issue58-20260908/cold-run.ps1'
$fingerprint = Join-Path $PSScriptRoot 'evidence-fingerprint.ps1'
$commands = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$startedRuns = 0
$beforeAttempted = $false
$preflight = $null
$postflight = $null

function Write-NewJson {
    param([string]$Name, [object]$Value)
    $path = Join-Path $PSScriptRoot $Name
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 32))
        $stream.Write($bytes)
    } finally { $stream.Dispose() }
}

function Read-Json {
    param([string]$Name)
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name))) -AsHashtable -Depth 128 -DateKind String
}

function Get-Sha {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-SourceState {
    $head = & git --no-optional-locks -C $repo rev-parse HEAD
    $headExitCode = $LASTEXITCODE
    if ($headExitCode -ne 0) { throw "git rev-parse failed: $headExitCode" }
    $paths = @(
        'scripts/Invoke-CodexSafeTreeDelete.ps1',
        'scripts/lib/CodexHostSafety.ps1',
        'scripts/lib/CodexSafeTreeDelete.ps1',
        'scripts/lib/CodexHostSafetyNativeLoader.ps1',
        'scripts/lib/CodexSafeTreeDeleteStatusScan.cs',
        'scripts/lib/CodexSafeTreeDeleteClosure.ps1',
        'reports/issue58-20260908/cold-run.ps1',
        'reports/issue58-20260908/evidence-fingerprint.ps1'
    ) + @(Get-CodexHostSafetyNativeSourceSet -Variant default)
    $hashes = [ordered]@{}
    foreach ($path in $paths) {
        $full = if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $repo $path }
        $hashes[[IO.Path]::GetRelativePath($repo, $full)] = Get-Sha $full
    }
    @{ head = [string]$head; headCommandExitCode = $headExitCode; sha256 = $hashes }
}

function Get-EnvironmentState {
    $rows = @()
    foreach ($suffix in @('FAST_SCAN', 'PARALLEL_FALLBACK', 'TREE_FAST')) {
        $name = 'CODEX_SAFE_TREE_DELETE_STATUS_' + $suffix
        $row = [ordered]@{ name = $name }
        foreach ($scope in @('Process', 'User', 'Machine')) {
            $row[$scope] = [Environment]::GetEnvironmentVariable($name, $scope)
        }
        $rows += $row
    }
    return ,$rows
}

function Test-DefaultEnvironment {
    param([object[]]$Rows)
    foreach ($row in $Rows) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            if ($null -ne $row[$scope]) { return $false }
        }
    }
    return $true
}

function Get-Preflight {
    $variant = Get-CodexHostSafetyNativeRequestedVariant
    $sources = Get-CodexHostSafetyNativeSourceSet -Variant $variant
    $composite = Get-CodexHostSafetyNativeCompileCompositeSha256 -Sources $sources -Variant $variant
    $root = Get-CodexHostSafetyNativeProductionRoot
    $generation = Join-Path (Join-Path $root $variant) $composite
    $scannerDll = Join-Path $root 'CodexSafeTreeDeleteStatusScan.dll'
    $scannerSource = Join-Path $repo 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs'
    $envRows = Get-EnvironmentState
    @{
        capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        sources = Get-SourceState
        environment = $envRows
        allThreeSwitchesUnsetAtAllScopes = Test-DefaultEnvironment $envRows
        currentExecutable = [Environment]::ProcessPath
        resolvedChildExecutable = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        psVersion = $PSVersionTable.PSVersion.ToString()
        psEdition = $PSVersionTable.PSEdition
        executableSha256 = Get-Sha $pwsh
        nativeCache = @{
            variant = $variant
            generation = $generation
            valid = Test-CodexHostSafetyNativeGenerationValid -GenerationDirectory $generation -ExpectedCompositeSha256 $composite -ExpectedVariant $variant
            dllSha256 = Get-Sha (Join-Path $generation 'CodexHostSafetyNative.dll')
            manifestSha256 = Get-Sha (Join-Path $generation 'generation-manifest.json')
            scannerSourceMatches = ([IO.File]::Exists($scannerDll) -and (Get-Sha $scannerSource) -ceq [IO.File]::ReadAllText("$scannerDll.sha256").Trim())
            scannerDllSha256 = Get-Sha $scannerDll
        }
    }
}

function Invoke-RecordedProcess {
    param([string]$Name, [string[]]$Arguments, [int]$WatchdogMs = 600000, [switch]$ObserveStatus)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile') + $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $record = [ordered]@{
        name = $Name; executable = $pwsh; arguments = @($psi.ArgumentList)
        startedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        processId = $null; exitCode = $null; watchdogTimedOut = $false
        observedStatusChild = $null; observationError = $null; error = $null
        stdout = ''; stderr = ''; elapsedMs = $null
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Process did not start.' }
        $record.processId = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($ObserveStatus) {
            try {
                for ($attempt = 0; $attempt -lt 12 -and -not $process.HasExited; $attempt++) {
                    Start-Sleep -Milliseconds 250
                    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($process.Id)" | Where-Object { $_.Name -ieq 'pwsh.exe' })
                    if ($children.Count -eq 1) {
                        $child = $children[0]
                        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($child.ExecutablePath)
                        $record.observedStatusChild = @{
                            processId = [int]$child.ProcessId
                            executable = [string]$child.ExecutablePath
                            fileVersion = $version.FileVersion
                            productVersion = $version.ProductVersion
                            executableSha256 = Get-Sha $child.ExecutablePath
                        }
                        break
                    }
                }
            } catch { $record.observationError = $_.Exception.Message }
        }
        $remaining = [Math]::Max(1, $WatchdogMs - [int]$watch.ElapsedMilliseconds)
        if (-not $process.WaitForExit($remaining)) {
            $record.watchdogTimedOut = $true
            $process.Kill($true)
            if (-not $process.WaitForExit(10000)) { throw 'Owned process tree did not exit after watchdog kill.' }
        }
        $record.exitCode = [int]$process.ExitCode
        $record.stdout = $stdoutTask.GetAwaiter().GetResult()
        $record.stderr = $stderrTask.GetAwaiter().GetResult()
    } catch {
        $record.error = $_.Exception.Message
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(10000)
        }
        if ($started -and $process.HasExited -and $null -eq $record.exitCode) { $record.exitCode = [int]$process.ExitCode }
        $watch.Stop()
        $record.elapsedMs = $watch.ElapsedMilliseconds
        $record.finishedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        $process.Dispose()
    }
    Write-NewJson "$Name-command.json" $record
    $commands.Add($record)
    Write-Host ("{0}: commandExitCode={1} elapsedMs={2}" -f $Name, $record.exitCode, $record.elapsedMs)
    return $record
}

function Get-Coverage {
    param([object[]]$Operations)
    $ids = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $invalid = 0
    $duplicates = 0
    foreach ($operation in $Operations) {
        $id = $operation['operationId']
        if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) { $invalid++; continue }
        if (-not $seen.Add($id)) { $duplicates++ }
        $ids.Add($id)
    }
    $ids.Sort([StringComparer]::Ordinal)
    @{
        count = $Operations.Count; invalidIdCount = $invalid; duplicateIdCount = $duplicates
        operationIdsSha256 = Get-TextSha (ConvertTo-Json -InputObject $ids.ToArray() -Compress)
    }
}

function Test-RunChecks {
    param([Collections.IDictionary]$Run, [Collections.IDictionary]$Coverage, [int]$ExpectedCount, [string]$ExpectedIdsSha)
    [ordered]@{
        errorIsNull = ($Run.Contains('error') -and $null -eq $Run['error'])
        childExitCodeZero = ($null -ne $Run['exitCode'] -and $Run['exitCode'] -eq 0)
        notTimedOut = ($Run['timedOut'] -is [bool] -and -not $Run['timedOut'])
        parseSucceeded = ($Run['parseSucceeded'] -is [bool] -and $Run['parseSucceeded'])
        complete = ($Run['complete'] -is [bool] -and $Run['complete'])
        elapsedBelow60000 = ($null -ne $Run['elapsedMs'] -and $Run['elapsedMs'] -ge 0 -and $Run['elapsedMs'] -lt 60000)
        frozenPipelineSemanticMatch = ($Run['semanticSha256'] -ceq $frozenSha)
        nonemptyCoverage = ($ExpectedCount -gt 0 -and $Coverage['count'] -gt 0)
        validIds = ($Coverage['invalidIdCount'] -eq 0)
        noDuplicateIds = ($Coverage['duplicateIdCount'] -eq 0)
        countMatchesBefore = ($Coverage['count'] -eq $ExpectedCount -and $Run['operationCount'] -eq $ExpectedCount)
        completeIdSetMatchesBefore = ($Coverage['operationIdsSha256'] -ceq $ExpectedIdsSha)
    }
}

function Test-AllChecks {
    param([Collections.IDictionary]$Checks)
    return @($Checks.Values | Where-Object { $_ -isnot [bool] -or -not $_ }).Count -eq 0
}

. (Join-Path $repo 'scripts/lib/CodexHostSafetyNativeLoader.ps1')
try {
    foreach ($name in @('before.json', 'after.json', 'comparison.json', 'preflight.json', 'postflight.json', 'cold-run-1.json', 'cold-run-2.json', 'cold-run-3.json')) {
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name)) { throw "Existing result must not be overwritten: $name" }
    }
    $parent = [IO.DirectoryInfo]::new($PSScriptRoot)
    while ($null -ne $parent) {
        if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse ancestor: $($parent.FullName)" }
        $parent = $parent.Parent
    }
    $originalFingerprint = Join-Path $repo 'reports/issue58-20260908/evidence-fingerprint.ps1'
    if ([IO.File]::ReadAllText($fingerprint) -cne [IO.File]::ReadAllText($originalFingerprint)) { throw 'Fingerprint copy is not text-identical to the existing script.' }
    $preflight = Get-Preflight
    Write-NewJson 'preflight.json' $preflight
    if ($preflight.sources.head -cne $expectedHead) { throw 'HEAD differs from the authorized commit.' }
    if (-not $preflight.allThreeSwitchesUnsetAtAllScopes) { throw 'External diagnostic or rollback configuration is present.' }
    if ($preflight.resolvedChildExecutable -ine $pwsh -or $preflight.psEdition -cne 'Core' -or $preflight.psVersion -cne '7.6.5') { throw 'Child executable or runtime is not the authorized runtime.' }
    if (-not $preflight.nativeCache.valid -or -not $preflight.nativeCache.scannerSourceMatches -or $preflight.nativeCache.variant -cne 'default') { throw 'Existing native cache is not valid; rebuilding outside ownership is forbidden.' }
    $beforeAttempted = $true
    Write-Host 'before fingerprint started'
    $beforeCommand = Invoke-RecordedProcess -Name before -Arguments @('-File', $fingerprint, '-Label', 'before', '-OutputPath', (Join-Path $PSScriptRoot 'before.json'))
    if ($beforeCommand.exitCode -ne 0 -or $null -ne $beforeCommand.error -or $beforeCommand.watchdogTimedOut) { throw 'Before fingerprint command failed.' }
    $baseline = Read-Json 'before.json'
    if ($baseline.evidence.operationCount -le 0 -or [string]::IsNullOrWhiteSpace($baseline.evidence.operationIdsSha256)) { throw 'Before fingerprint did not produce independent nonempty coverage.' }
    for ($i = 1; $i -le 3; $i++) {
        $state = Get-Preflight
        Write-NewJson "cold-run-$i-preflight.json" $state
        if (-not $state.allThreeSwitchesUnsetAtAllScopes -or $state.sources.head -cne $expectedHead -or
            (ConvertTo-Json -InputObject $state.sources.sha256 -Compress) -cne (ConvertTo-Json -InputObject $preflight.sources.sha256 -Compress) -or
            -not $state.nativeCache.valid -or -not $state.nativeCache.scannerSourceMatches) { throw "Input drift before run $i." }
        $startedRuns++
        Write-Host "cold-run-$i started (DeadlineMs=180000)"
        $runCommand = Invoke-RecordedProcess -Name "cold-run-$i" -WatchdogMs 240000 -ObserveStatus -Arguments @(
            '-File', $coldScript, '-DeadlineMs', '180000',
            '-OutputPath', (Join-Path $PSScriptRoot "cold-run-$i.json"),
            '-StdoutPath', (Join-Path $PSScriptRoot "cold-run-$i-stdout.json")
        )
    }
} catch {
    $failures.Add($_.Exception.Message)
} finally {
    if ($beforeAttempted) {
        try {
            Write-Host 'after fingerprint started'
            $afterCommand = Invoke-RecordedProcess -Name after -Arguments @('-File', $fingerprint, '-Label', 'after', '-OutputPath', (Join-Path $PSScriptRoot 'after.json'))
        } catch { $failures.Add('After fingerprint: ' + $_.Exception.Message) }
    }
    try { $postflight = Get-Preflight; Write-NewJson 'postflight.json' $postflight } catch { $failures.Add('Postflight: ' + $_.Exception.Message) }
}

$summary = [ordered]@{
    artifactType = 'issue58.live-rerun-comparison'; capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    status = 'BLOCKED'; aggregateExitCode = 1; startedRuns = $startedRuns
    expectedHead = $expectedHead; frozenPipelineSemanticSha256 = $frozenSha
    coldStartMeaning = 'Three distinct fresh pwsh Status processes; existing authenticated native cache retained; no OS cache flush.'
    fingerprintClaim = 'Evidence and policy content/identity before-after comparison only; not an intervening zero-write-event audit.'
    scope = 'Repository Status entry only; frozen pipeline baseline equivalence only; not host gate acceptance or full fast/slow equivalence.'
    expectedOperationCount = $null; expectedOperationIdsSha256 = $null
    runs = @(); fingerprintFieldEquality = [ordered]@{}; checks = [ordered]@{}
    commandExitCodes = @($commands | ForEach-Object { @{ name = $_.name; exitCode = $_.exitCode; watchdogTimedOut = $_.watchdogTimedOut; error = $_.error } })
    negativeControls = [ordered]@{}; failures = @()
}
try {
    $before = Read-Json 'before.json'
    $after = Read-Json 'after.json'
    $summary.expectedOperationCount = $before.evidence.operationCount
    $summary.expectedOperationIdsSha256 = $before.evidence.operationIdsSha256
    foreach ($section in @('evidence', 'policy')) {
        $equality = [ordered]@{}
        foreach ($key in $before[$section].Keys) {
            $equality[$key] = ($after[$section].Contains($key) -and
                (ConvertTo-Json -InputObject $before[$section][$key] -Compress -Depth 32) -ceq
                (ConvertTo-Json -InputObject $after[$section][$key] -Compress -Depth 32))
        }
        $equality['sameFieldSet'] = (($before[$section].Keys | Sort-Object) -join '|') -ceq (($after[$section].Keys | Sort-Object) -join '|')
        $summary.fingerprintFieldEquality[$section] = $equality
    }
    for ($i = 1; $i -le 3; $i++) {
        try {
            $run = Read-Json "cold-run-$i.json"
            $parsed = Read-Json "cold-run-$i-stdout.json"
            $command = Read-Json "cold-run-$i-command.json"
            $coverage = Get-Coverage -Operations $parsed.operations
            $checks = Test-RunChecks -Run $run -Coverage $coverage -ExpectedCount $summary.expectedOperationCount -ExpectedIdsSha $summary.expectedOperationIdsSha256
            $checks['wrapperExitCodeZero'] = ($null -ne $command.exitCode -and $command.exitCode -eq 0 -and $null -eq $command.error -and -not $command.watchdogTimedOut)
            $checks['observedActualChild'] = ($null -ne $command.observedStatusChild -and $command.observedStatusChild.processId -eq $run.processId -and
                $command.observedStatusChild.executable -ieq $run.executable -and $run.executable -ieq $pwsh -and
                $command.observedStatusChild.executableSha256 -ceq $preflight.executableSha256 -and $command.observedStatusChild.fileVersion -like '7.6.5*')
            $checks['stdoutSchemaValid'] = ($parsed.artifactType -ceq 'env-governance.codex-safe-tree-delete-status' -and $parsed.schemaVersion -eq 1 -and $parsed.operations -is [array])
            $checks['stdoutComplete'] = ($parsed.complete -is [bool] -and $parsed.complete)
            $checks['stdoutRawShaMatches'] = ((Get-TextSha ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "cold-run-$i-stdout.json")))) -ceq $run.statusSha256)
            foreach ($volatile in @('capturedAtUtc', 'metrics', 'statusSegments')) { [void]$parsed.Remove($volatile) }
            $checks['independentSemanticShaMatches'] = ((Get-TextSha (ConvertTo-Json -InputObject $parsed -Depth 100 -Compress)) -ceq $frozenSha)
            $row = [ordered]@{ run = $i; passed = Test-AllChecks $checks }
            foreach ($field in @('elapsedMs', 'timedOut', 'exitCode', 'parseSucceeded', 'complete', 'operationCount', 'semanticSha256', 'error')) { $row[$field] = $run[$field] }
            $row.coverage = $coverage
            $row.child = $command.observedStatusChild
            $row.checks = $checks
            $summary.runs += $row
        } catch {
            $summary.runs += @{ run = $i; passed = $false; validationError = $_.Exception.Message }
        }
    }
    $good = [ordered]@{ error=$null; exitCode=0; timedOut=$false; parseSucceeded=$true; complete=$true; elapsedMs=1; semanticSha256=$frozenSha; operationCount=2 }
    $goodCoverage = Get-Coverage @(@{operationId='a'}, @{operationId='b'})
    $summary.negativeControls.validSyntheticAccepted = Test-AllChecks (Test-RunChecks $good $goodCoverage 2 $goodCoverage.operationIdsSha256)
    foreach ($mutation in @(
        @{name='error'; value='synthetic-error'}, @{name='exitCode'; value=1}, @{name='timedOut'; value=$true},
        @{name='parseSucceeded'; value=$false}, @{name='complete'; value=$false}, @{name='elapsedMs'; value=60000},
        @{name='semanticSha256'; value='wrong'}, @{name='operationCount'; value=1}
    )) {
        $changed = [ordered]@{}
        foreach ($key in $good.Keys) { $changed[$key] = $good[$key] }
        $changed[$mutation.name] = $mutation.value
        $summary.negativeControls[$mutation.name + 'Rejected'] = -not (Test-AllChecks (Test-RunChecks $changed $goodCoverage 2 $goodCoverage.operationIdsSha256))
    }
    foreach ($case in @(
        @{name='emptyId'; operations=@(@{operationId=''}, @{operationId='b'})},
        @{name='duplicateId'; operations=@(@{operationId='a'}, @{operationId='a'})},
        @{name='wrongIdSameCount'; operations=@(@{operationId='a'}, @{operationId='c'})},
        @{name='emptySet'; operations=@()}
    )) {
        $badCoverage = Get-Coverage -Operations $case.operations
        $summary.negativeControls[$case.name + 'Rejected'] = -not (Test-AllChecks (Test-RunChecks $good $badCoverage 2 $goodCoverage.operationIdsSha256))
    }
    $summary.checks['exactlyThreeRuns'] = ($startedRuns -eq 3 -and $summary.runs.Count -eq 3)
    $summary.checks['allRunsPassed'] = @($summary.runs | Where-Object { -not $_.passed }).Count -eq 0
    $summary.checks['evidenceContentIdentityUnchanged'] = Test-AllChecks $summary.fingerprintFieldEquality.evidence
    $summary.checks['policyContentIdentityUnchanged'] = Test-AllChecks $summary.fingerprintFieldEquality.policy
    $summary.checks['sourceHeadAndHashesUnchanged'] = ($preflight.sources.head -ceq $expectedHead -and $postflight.sources.head -ceq $expectedHead -and
        (ConvertTo-Json -InputObject $preflight.sources.sha256 -Compress) -ceq (ConvertTo-Json -InputObject $postflight.sources.sha256 -Compress))
    $summary.checks['defaultEnvironmentBeforeAfter'] = ($preflight.allThreeSwitchesUnsetAtAllScopes -and $postflight.allThreeSwitchesUnsetAtAllScopes)
    $summary.checks['nativeCacheContentUnchanged'] = (ConvertTo-Json -InputObject $preflight.nativeCache -Compress) -ceq (ConvertTo-Json -InputObject $postflight.nativeCache -Compress)
    $summary.checks['allRecordedCommandsSucceeded'] = ($commands.Count -eq 5 -and @($commands | Where-Object { $null -eq $_.exitCode -or $_.exitCode -ne 0 -or $null -ne $_.error -or $_.watchdogTimedOut }).Count -eq 0)
    $summary.checks['negativeControlsPassed'] = Test-AllChecks $summary.negativeControls
} catch { $failures.Add('Aggregation: ' + $_.Exception.Message) }
$diffOutput = & git --no-optional-locks -C $repo diff --check 2>&1
$diffExit = $LASTEXITCODE
$summary.gitDiffCheck = @{ exitCode = $diffExit; output = @($diffOutput | ForEach-Object { [string]$_ }) }
$summary.checks['gitDiffCheckPassed'] = $diffExit -eq 0
$summary.checks['noOrchestrationErrors'] = $failures.Count -eq 0
$summary.failures = @($failures)
if ($startedRuns -eq 3) { $summary.status = 'DONE_WITH_CONCERNS' }
if ($summary.checks.Count -ge 10 -and (Test-AllChecks $summary.checks)) { $summary.status = 'DONE'; $summary.aggregateExitCode = 0 }
Write-NewJson 'comparison.json' $summary
Write-Host ("status={0} aggregateExitCode={1} startedRuns={2}" -f $summary.status, $summary.aggregateExitCode, $startedRuns)
exit $summary.aggregateExitCode
