[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1, 1073741824)][long]$SmallDatasetBytes = 4096,
    [ValidateRange(1, 1073741824)][long]$LargeDatasetBytes = 33554432
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$fixtureEntryPath = Join-Path $projectRoot 'tests\Invoke-CodexSafeTreeDeleteFixture.ps1'
$hostSafetyLibraryPath = Join-Path $PSScriptRoot 'lib\CodexHostSafety.ps1'
$sourceLibraryPath = Join-Path $PSScriptRoot 'lib\CodexSafeTreeDelete.ps1'
$sourceWrapperPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDelete.ps1'
$sourceHostAdapterPath = Join-Path $PSScriptRoot 'invoke-codex-safe-tree-delete-host.ps1'
$liveWrapperPath = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
$workRoot = Join-Path $projectRoot ("reports\safe-tree-delete-benchmark-work-{0}" -f [guid]::NewGuid().ToString('N'))

. $hostSafetyLibraryPath

$outputFullPath = Assert-CodexHookDPath -Value $OutputPath -Name 'safe-delete benchmark output'
$outputParent = Split-Path -Parent $outputFullPath
if (-not [IO.Directory]::Exists($outputParent)) {
    throw 'safe-delete benchmark output parent 不存在。'
}
$outputBaseName = [IO.Path]::GetFileNameWithoutExtension($outputFullPath)
$retainedEvidenceRoot = Join-Path $outputParent "$outputBaseName-evidence"
$retainedEvidencePath = Join-Path $retainedEvidenceRoot 'benchmark-evidence.json'

function Get-LowerSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Remove-BenchmarkTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -AllowHardLinks `
        -Name 'safe-delete benchmark cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -AllowHardLinks `
        -Scope 'safe-delete benchmark cleanup'
}

function New-BenchmarkPayload {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Length
    )

    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    try {
        $stream.SetLength($Length)
        if ($Length -gt 0) {
            $stream.Position = 0
            $stream.WriteByte(0x43)
            if ($Length -gt 1) {
                $stream.Position = $Length - 1
                $stream.WriteByte(0x58)
            }
        }
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function New-BenchmarkDatasetPayload {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][long]$TotalLength
    )

    $objectRoot = Join-Path $TargetPath 'objects'
    $firstShard = Join-Path $objectRoot 'first'
    $secondShard = Join-Path $objectRoot 'second'
    foreach ($directory in @($objectRoot, $firstShard, $secondShard)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $baseLength = [long][Math]::Floor($TotalLength / 4)
    $remainder = [int]($TotalLength % 4)
    $definitions = @(
        [pscustomobject]@{ path = Join-Path $TargetPath 'root.bin'; offset = 0 },
        [pscustomobject]@{ path = Join-Path $firstShard 'first.bin'; offset = 1 },
        [pscustomobject]@{ path = Join-Path $secondShard 'second.bin'; offset = 2 },
        [pscustomobject]@{ path = Join-Path $secondShard 'third.bin'; offset = 3 }
    )
    foreach ($definition in $definitions) {
        $length = $baseLength + $(if ([int]$definition.offset -lt $remainder) { 1L } else { 0L })
        New-BenchmarkPayload -Path ([string]$definition.path) -Length $length
    }
}

function ConvertTo-BenchmarkCommandValue {
    param([AllowNull()][object]$Value)

    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [datetimeoffset]) {
        $Value = $Value.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $text = [string]$Value
    return '"{0}"' -f $text.Replace('"', '""')
}

function Invoke-BenchmarkStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters
    )

    $commandParts = [Collections.Generic.List[string]]::new()
    $commandParts.Add(('pwsh -NoLogo -NoProfile -File {0}' -f
        (ConvertTo-BenchmarkCommandValue -Value $fixtureEntryPath)))
    foreach ($entry in $Parameters.GetEnumerator()) {
        if ($entry.Value -is [bool] -and [bool]$entry.Value) {
            $commandParts.Add("-$($entry.Key)")
        } else {
            $commandParts.Add(("-{0} {1}" -f
                $entry.Key,
                (ConvertTo-BenchmarkCommandValue -Value $entry.Value)))
        }
    }

    $startedAtUtc = [datetimeoffset]::UtcNow
    $result = & $fixtureEntryPath @Parameters
    $completedAtUtc = [datetimeoffset]::UtcNow
    return [pscustomobject][ordered]@{
        result = $result
        evidence = [pscustomobject][ordered]@{
            name = $Name
            invocation = [pscustomobject][ordered]@{
                scriptPath = $fixtureEntryPath
                parameters = [pscustomobject]$Parameters
                command = $commandParts -join ' '
            }
            startedAtUtc = $startedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            completedAtUtc = $completedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            exitStatus = 'succeeded'
            exitCode = 0
            result = $result
        }
    }
}

function Invoke-BenchmarkDataset {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][long]$PayloadBytes
    )

    $datasetRoot = Join-Path $workRoot $Name
    $targetPath = Join-Path $datasetRoot 'build-output'
    $evidenceRoot = Join-Path $datasetRoot 'evidence'
    $policyPath = Join-Path $datasetRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory($targetPath)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    New-BenchmarkDatasetPayload -TargetPath $targetPath -TotalLength $PayloadBytes
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 5
        entries = @([pscustomobject][ordered]@{
            id = "benchmark-$Name"
            capabilityRoot = $targetPath
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            minimumQuarantineAgeMinutes = 0
            producerFenceMode = 'os-handle-required'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    $fixture = [pscustomobject][ordered]@{
        directoryCount = 1 + @(Get-ChildItem -LiteralPath $targetPath -Directory -Recurse -Force).Count
        fileCount = @(Get-ChildItem -LiteralPath $targetPath -File -Recurse -Force).Count
        logicalBytes = $PayloadBytes
    }
    $stages = [Collections.Generic.List[object]]::new()

    $stage = Invoke-BenchmarkStage -Name 'plan' -Parameters ([ordered]@{
        Mode = 'Plan'
        TargetPath = $targetPath
        CapabilityRoot = $targetPath
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $plan = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'status-planned' -Parameters ([ordered]@{
        Mode = 'Status'
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $plannedStatus = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'apply' -Parameters ([ordered]@{
        Mode = 'Apply'
        PlanPath = [string]$plan.planPath
        ApprovedPlanSha256 = [string]$plan.planSha256
        ConfirmApply = $true
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $apply = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'status-recoverable' -Parameters ([ordered]@{
        Mode = 'Status'
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $recoverableStatus = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'restore' -Parameters ([ordered]@{
        Mode = 'Restore'
        TransactionPath = [string]$apply.transactionPath
        ApprovedTransactionSha256 = [string]$apply.transactionSha256
        ConfirmRestore = $true
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $restore = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'purge-plan' -Parameters ([ordered]@{
        Mode = 'Plan'
        TargetPath = $targetPath
        CapabilityRoot = $targetPath
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $purgePlan = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'purge-apply' -Parameters ([ordered]@{
        Mode = 'Apply'
        PlanPath = [string]$purgePlan.planPath
        ApprovedPlanSha256 = [string]$purgePlan.planSha256
        ConfirmApply = $true
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $purgeApply = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'purge' -Parameters ([ordered]@{
        Mode = 'Purge'
        TransactionPath = [string]$purgeApply.transactionPath
        ApprovedTransactionSha256 = [string]$purgeApply.transactionSha256
        ConfirmPurge = $true
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $purge = $stage.result
    $stages.Add($stage.evidence)

    $stage = Invoke-BenchmarkStage -Name 'status-terminal' -Parameters ([ordered]@{
        Mode = 'Status'
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    })
    $terminalStatus = $stage.result
    $stages.Add($stage.evidence)

    return [pscustomobject][ordered]@{
        name = $Name
        payloadBytes = $PayloadBytes
        policySha256 = Get-LowerSha256 -Path $policyPath
        fixture = $fixture
        plan = [pscustomobject][ordered]@{
            metrics = $plan.metrics
            planSha256 = [string]$plan.planSha256
        }
        status = [pscustomobject][ordered]@{
            metrics = $recoverableStatus.metrics
            plannedLifecycle = [string]$plannedStatus.operations[0].lifecycle
            recoverableLifecycle = [string]$recoverableStatus.operations[0].lifecycle
            terminalComplete = [bool]$terminalStatus.complete
        }
        apply = [pscustomobject][ordered]@{
            metrics = $apply.metrics
            transactionSha256 = [string]$apply.transactionSha256
        }
        restore = [pscustomobject][ordered]@{
            metrics = $restore.metrics
            logicalCompletion = [bool]$restore.logicalCompletion
        }
        purge = [pscustomobject][ordered]@{
            metrics = $purge.metrics
            deletionOutcome = $purge.deletionOutcome
            transactionSha256 = [string]$purge.transactionSha256
        }
        retainedEvidence = [pscustomobject][ordered]@{
            path = $retainedEvidencePath
            datasetName = $Name
        }
        evidence = [pscustomobject][ordered]@{
            name = $Name
            policyPath = $policyPath
            policySha256 = Get-LowerSha256 -Path $policyPath
            fixture = $fixture
            stages = @($stages)
        }
    }
}

$datasets = [Collections.Generic.List[object]]::new()
$evidenceDatasets = [Collections.Generic.List[object]]::new()
try {
    [void][IO.Directory]::CreateDirectory($workRoot)
    foreach ($definition in @(
            [pscustomobject]@{ name = 'small'; bytes = $SmallDatasetBytes },
            [pscustomobject]@{ name = 'large'; bytes = $LargeDatasetBytes })) {
        $dataset = Invoke-BenchmarkDataset `
            -Name ([string]$definition.name) `
            -PayloadBytes ([long]$definition.bytes)
        $evidenceDatasets.Add($dataset.evidence)
        [void]$dataset.PSObject.Properties.Remove('evidence')
        $datasets.Add($dataset)
    }
} finally {
    Remove-BenchmarkTree -Path $workRoot
}

$capturedAtUtc = [datetimeoffset]::UtcNow.ToString(
    'o',
    [Globalization.CultureInfo]::InvariantCulture)
if (-not [IO.Directory]::Exists($retainedEvidenceRoot)) {
    [void](New-CodexHookCapabilityDirectory `
        -Path $retainedEvidenceRoot `
        -CapabilityRoot $outputParent `
        -Name 'safe-delete benchmark retained evidence root' `
        -RequireMissing)
} else {
    [void](Assert-CodexHookCapabilityPath `
        -Path $retainedEvidenceRoot `
        -CapabilityRoot $outputParent `
        -AllowedExactPaths @($retainedEvidenceRoot) `
        -Name 'safe-delete benchmark retained evidence root')
}
$retainedEvidence = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-benchmark-evidence'
    schemaVersion = 1
    capturedAtUtc = $capturedAtUtc
    profile = 'isolated-fixture'
    payloadBytesRetained = $false
    datasets = @($evidenceDatasets)
}
[void](Set-CodexHookCapabilityJson `
    -Path $retainedEvidencePath `
    -Document $retainedEvidence `
    -CapabilityRoot $retainedEvidenceRoot `
    -AllowedExactPaths @($retainedEvidencePath) `
    -Scope 'safe-delete benchmark retained evidence publish')
$retainedEvidenceSnapshot = Get-CodexHookCapabilityFileSnapshot `
    -Path $retainedEvidencePath `
    -CapabilityRoot $retainedEvidenceRoot `
    -AllowedExactPaths @($retainedEvidencePath) `
    -Name 'safe-delete benchmark retained evidence published'

$sourceWrapperSha256 = Get-LowerSha256 -Path $sourceWrapperPath
$sourceHostAdapterSha256 = Get-LowerSha256 -Path $sourceHostAdapterPath
$liveWrapperStatus = 'not-checked'
$liveWrapperSha256 = $null
if ([IO.File]::Exists($liveWrapperPath)) {
    $liveWrapperSha256 = Get-LowerSha256 -Path $liveWrapperPath
    $liveWrapperStatus = if ($liveWrapperSha256 -ceq $sourceHostAdapterSha256) {
        'matched-source'
    } else {
        'different-from-source'
    }
}
$commandText = "pwsh -NoLogo -NoProfile -File `"$PSCommandPath`" -OutputPath `"$outputFullPath`" -SmallDatasetBytes $SmallDatasetBytes -LargeDatasetBytes $LargeDatasetBytes"
$report = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-benchmark'
    schemaVersion = 2
    capturedAtUtc = $capturedAtUtc
    profile = 'isolated-fixture'
    machine = [pscustomobject][ordered]@{
        osVersion = [Environment]::OSVersion.VersionString
        processorCount = [Environment]::ProcessorCount
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    artifacts = [pscustomobject][ordered]@{
        sourceLibraryPath = $sourceLibraryPath
        sourceLibrarySha256 = Get-LowerSha256 -Path $sourceLibraryPath
        sourceWrapperPath = $sourceWrapperPath
        sourceWrapperSha256 = $sourceWrapperSha256
        sourceHostAdapterPath = $sourceHostAdapterPath
        sourceHostAdapterSha256 = $sourceHostAdapterSha256
        liveWrapperPath = $liveWrapperPath
        liveWrapperSha256 = $liveWrapperSha256
        liveWrapperStatus = $liveWrapperStatus
    }
    execution = [pscustomobject][ordered]@{
        command = $commandText
        exitCode = 0
        exitStatus = 'succeeded'
        cleanup = 'managed-fixture-tree-removed'
    }
    retainedEvidence = [pscustomobject][ordered]@{
        path = $retainedEvidencePath
        sha256 = [string]$retainedEvidenceSnapshot.sha256
        payloadBytesRetained = $false
    }
    datasets = @($datasets)
    conclusion = [pscustomobject][ordered]@{
        hashReuseDesignRecommendation = 'insufficient-evidence'
        hashReuseDesignDecision = 'do-not-open-with-current-evidence'
        contentAuthenticatedContractChanged = $false
        note = 'Fixture measurements do not authorize metadata-only approval or transparent manifest replacement.'
    }
    unverified = @(
        'host wrapper deployment',
        'live policy activation',
        'real capability target deletion',
        '16 GiB dataset',
        'independent physical allocation evidence'
    )
}
[void](Set-CodexHookCapabilityJson `
    -Path $outputFullPath `
    -Document $report `
    -CapabilityRoot $outputParent `
    -AllowedExactPaths @($outputFullPath) `
    -Scope 'safe-delete benchmark evidence publish')
$report
