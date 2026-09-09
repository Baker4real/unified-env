[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$frozenSha = '88d4b67943d7d451931c024ad031a591efcffd528df9acbcb5e0d566d5938ad6'
$expectedComplete = $false
$expectedHead = '97b7c23133be0106e212db79d35ca07497b35e71'
$expectedExecutable = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$outputPath = Join-Path $PSScriptRoot 'comparison-corrected-v2.json'
if (Test-Path -LiteralPath $outputPath) { throw 'Corrected comparison already exists; refusing overwrite.' }

function Read-Json {
    param([string]$Name)
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name))) -AsHashtable -Depth 128 -DateKind String
}

function Get-TextSha {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
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
        completeBooleanMatchesFrozenBaseline = ($Run['complete'] -is [bool] -and $Run['complete'] -eq $expectedComplete)
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

function Test-FieldsEqual {
    param([Collections.IDictionary]$Before, [Collections.IDictionary]$After)
    $checks = [ordered]@{}
    foreach ($key in $Before.Keys) {
        $checks[$key] = ($After.Contains($key) -and
            (ConvertTo-Json -InputObject $Before[$key] -Compress -Depth 32) -ceq
            (ConvertTo-Json -InputObject $After[$key] -Compress -Depth 32))
    }
    $checks.sameFieldSet = (($Before.Keys | Sort-Object) -join '|') -ceq (($After.Keys | Sort-Object) -join '|')
    return $checks
}

function Test-DefaultEnvironment {
    param([object[]]$Rows)
    if ($Rows.Count -ne 3) { return $false }
    foreach ($row in $Rows) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            if (-not $row.Contains($scope) -or $null -ne $row[$scope]) { return $false }
        }
    }
    return $true
}

$summary = [ordered]@{
    artifactType = 'issue58.live-rerun-comparison-corrected'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    status = 'BLOCKED'; aggregateExitCode = 1; additionalColdRuns = 0
    correction = 'complete is a business-state boolean, not sampling completion. Require boolean false matching the frozen pipeline baseline; retain first erroneous aggregation unchanged.'
    originalComparisonSha256 = $null; originalAggregateExitCode = $null
    expectedHead = $expectedHead; frozenPipelineSemanticSha256 = $frozenSha; expectedComplete = $expectedComplete
    expectedOperationCount = $null; expectedOperationIdsSha256 = $null
    fingerprintClaim = 'Evidence and policy content/identity before-after comparison only; not an intervening zero-write-event audit.'
    scope = 'Repository Status entry only; frozen pipeline baseline equivalence only; not host gate acceptance or full fast/slow equivalence.'
    runs = @(); fingerprintFieldEquality = [ordered]@{}; sourceFieldEquality = [ordered]@{}
    checks = [ordered]@{}; negativeControls = [ordered]@{}; commandExitCodes = @(); errors = @()
}
try {
    $original = Read-Json 'comparison.json'
    $summary.originalComparisonSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'comparison.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $summary.originalAggregateExitCode = $original.aggregateExitCode
    $before = Read-Json 'before.json'
    $after = Read-Json 'after.json'
    $preflight = Read-Json 'preflight.json'
    $postflight = Read-Json 'postflight.json'
    $summary.expectedOperationCount = $before.evidence.operationCount
    $summary.expectedOperationIdsSha256 = $before.evidence.operationIdsSha256
    foreach ($section in @('evidence', 'policy')) {
        $summary.fingerprintFieldEquality[$section] = Test-FieldsEqual $before[$section] $after[$section]
    }
    $summary.sourceFieldEquality = Test-FieldsEqual $preflight.sources.sha256 $postflight.sources.sha256
    $environmentChecks = @(Test-DefaultEnvironment $preflight.environment; Test-DefaultEnvironment $postflight.environment)
    $sourceChecks = @()
    $commandsSucceeded = $true
    foreach ($name in @('before', 'cold-run-1', 'cold-run-2', 'cold-run-3', 'after')) {
        $command = Read-Json "$name-command.json"
        $ok = ($null -ne $command.exitCode -and $command.exitCode -eq 0 -and $null -eq $command.error -and -not $command.watchdogTimedOut)
        if (-not $ok) { $commandsSucceeded = $false }
        $summary.commandExitCodes += @{ name = $name; exitCode = $command.exitCode; watchdogTimedOut = $command.watchdogTimedOut; error = $command.error }
    }
    for ($i = 1; $i -le 3; $i++) {
        try {
            $run = Read-Json "cold-run-$i.json"
            $parsed = Read-Json "cold-run-$i-stdout.json"
            $command = Read-Json "cold-run-$i-command.json"
            $runPreflight = Read-Json "cold-run-$i-preflight.json"
            $environmentChecks += Test-DefaultEnvironment $runPreflight.environment
            $sourceChecks += (($runPreflight.sources.head -ceq $expectedHead) -and (Test-AllChecks (Test-FieldsEqual $preflight.sources.sha256 $runPreflight.sources.sha256)))
            $coverage = Get-Coverage -Operations $parsed.operations
            $checks = Test-RunChecks $run $coverage $summary.expectedOperationCount $summary.expectedOperationIdsSha256
            $checks.wrapperExitCodeZero = ($null -ne $command.exitCode -and $command.exitCode -eq 0 -and $null -eq $command.error -and -not $command.watchdogTimedOut)
            $checks.observedActualChild = ($null -ne $command.observedStatusChild -and $command.observedStatusChild.processId -eq $run.processId -and
                $command.observedStatusChild.executable -ieq $run.executable -and $run.executable -ieq $expectedExecutable -and
                $command.observedStatusChild.executableSha256 -ceq $preflight.executableSha256 -and $command.observedStatusChild.fileVersion -like '7.6.5*')
            $checks.stdoutSchemaValid = ($parsed.artifactType -ceq 'env-governance.codex-safe-tree-delete-status' -and $parsed.schemaVersion -eq 1 -and $parsed.operations -is [array])
            $checks.stdoutCompleteBooleanMatchesFrozenBaseline = ($parsed.complete -is [bool] -and $parsed.complete -eq $expectedComplete)
            $checks.stdoutRawShaMatches = ((Get-TextSha ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "cold-run-$i-stdout.json")))) -ceq $run.statusSha256)
            foreach ($volatile in @('capturedAtUtc', 'metrics', 'statusSegments')) { [void]$parsed.Remove($volatile) }
            $checks.independentSemanticShaMatches = ((Get-TextSha (ConvertTo-Json -InputObject $parsed -Depth 100 -Compress)) -ceq $frozenSha)
            $row = [ordered]@{ run = $i; passed = Test-AllChecks $checks }
            foreach ($field in @('elapsedMs', 'timedOut', 'exitCode', 'parseSucceeded', 'complete', 'operationCount', 'semanticSha256', 'error')) { $row[$field] = $run[$field] }
            $row.coverage = $coverage
            $row.child = $command.observedStatusChild
            $row.statusProcessId = $run.processId
            $row.launcherRecordedExecutable = $run.executable
            $row.osObservationError = $command.observationError
            $row.checks = $checks
            $row.failedChecks = @($checks.Keys | Where-Object { -not $checks[$_] })
            $summary.runs += $row
        } catch { $summary.runs += @{run=$i; passed=$false; validationError=$_.Exception.Message} }
    }
    $good = [ordered]@{ error=$null; exitCode=0; timedOut=$false; parseSucceeded=$true; complete=$false; elapsedMs=1; semanticSha256=$frozenSha; operationCount=2 }
    $goodCoverage = Get-Coverage -Operations @(@{operationId='a'}, @{operationId='b'})
    $summary.negativeControls.validFalseCompleteAccepted = Test-AllChecks (Test-RunChecks $good $goodCoverage 2 $goodCoverage.operationIdsSha256)
    foreach ($mutation in @(
        @{key='error'; value='synthetic-error'; name='error'}, @{key='exitCode'; value=1; name='exitCode'},
        @{key='timedOut'; value=$true; name='timedOut'}, @{key='parseSucceeded'; value=$false; name='parseSucceeded'},
        @{key='complete'; value=$true; name='trueComplete'}, @{key='complete'; value='false'; name='stringComplete'},
        @{key='complete'; value=$null; name='nullComplete'}, @{key='elapsedMs'; value=60000; name='elapsedThreshold'},
        @{key='semanticSha256'; value='wrong'; name='semanticSha'}, @{key='operationCount'; value=1; name='operationCount'}
    )) {
        $changed = [ordered]@{}
        foreach ($key in $good.Keys) { $changed[$key] = $good[$key] }
        $changed[$mutation.key] = $mutation.value
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
    $summary.checks.exactlyThreeOriginalRuns = ($original.startedRuns -eq 3 -and $summary.runs.Count -eq 3)
    $summary.checks.allRunsPassed = @($summary.runs | Where-Object { -not $_.passed }).Count -eq 0
    $pids = @($summary.runs | ForEach-Object { if ($_.Contains('statusProcessId')) { $_.statusProcessId } })
    $summary.checks.threeDistinctChildProcesses = ($pids.Count -eq 3 -and @($pids | Sort-Object -Unique).Count -eq 3)
    $summary.checks.evidenceContentIdentityUnchanged = Test-AllChecks $summary.fingerprintFieldEquality.evidence
    $summary.checks.policyContentIdentityUnchanged = Test-AllChecks $summary.fingerprintFieldEquality.policy
    $summary.checks.sourceHeadAndHashesUnchanged = ($preflight.sources.head -ceq $expectedHead -and $postflight.sources.head -ceq $expectedHead -and
        (Test-AllChecks $summary.sourceFieldEquality) -and $sourceChecks.Count -eq 3 -and @($sourceChecks | Where-Object { -not $_ }).Count -eq 0)
    $summary.checks.defaultEnvironmentAllFiveObservations = ($environmentChecks.Count -eq 5 -and @($environmentChecks | Where-Object { -not $_ }).Count -eq 0)
    $summary.checks.nativeCacheContentUnchanged = Test-AllChecks (Test-FieldsEqual $preflight.nativeCache $postflight.nativeCache)
    $summary.checks.allRecordedCommandsSucceeded = $commandsSucceeded
    $summary.checks.negativeControlsPassed = Test-AllChecks $summary.negativeControls
    $summary.gitDiffCheck = $original.gitDiffCheck
    $summary.checks.gitDiffCheckPassed = $original.gitDiffCheck.exitCode -eq 0
    $summary.checks.noOriginalOrchestrationErrors = $original.failures.Count -eq 0
    $summary.status = 'DONE_WITH_CONCERNS'
} catch { $summary.errors += $_.Exception.Message }
$summary.checks.noReaggregationErrors = $summary.errors.Count -eq 0
if ($summary.checks.Count -ge 12 -and (Test-AllChecks $summary.checks)) { $summary.status = 'DONE'; $summary.aggregateExitCode = 0 }
$summary.failedChecks = @($summary.checks.Keys | Where-Object { -not $summary.checks[$_] })
$stream = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try {
    $stream.Write([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $summary -Depth 32)))
} finally { $stream.Dispose() }
Write-Host ("status={0} aggregateExitCode={1} additionalColdRuns=0 failedChecks={2}" -f $summary.status, $summary.aggregateExitCode, ($summary.failedChecks -join ','))
exit $summary.aggregateExitCode
