[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$fixtureRoot = Join-Path `
    'D:\Codex\projects' `
    ('.safe-tree-delete-grace-fixture-{0}' -f [guid]::NewGuid().ToString('N'))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy-v5.json'

. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)

    try {
        & $Action
    } catch {
        return $_.Exception.Message
    }
    throw $Message
}

function Remove-TestTree {
    param([string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete grace test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete grace test cleanup'
}

function Get-EvidenceFileState {
    param([Parameter(Mandatory)][string]$Path)

    $runDirectory = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $Path `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete grace immutable evidence state'
    return [pscustomobject][ordered]@{
        sha256 = [string]$snapshot.sha256
        identity = @($snapshot.identity)
    }
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 5L
        entries = @([pscustomobject][ordered]@{
            id = 'grace-fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1L
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            minimumQuarantineAgeMinutes = 10L
            producerFenceMode = 'manual-only'
            deniedExactPaths = @($evidenceRoot)
        })
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))

    $targetPath = Join-Path $fixtureRoot 'anchor-target'
    [void][IO.Directory]::CreateDirectory($targetPath)
    [IO.File]::WriteAllText(
        (Join-Path $targetPath 'payload.txt'),
        'immutable-grace',
        [Text.UTF8Encoding]::new($false))
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot

    $transaction = Get-Content -Raw -LiteralPath $apply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $anchor = Get-Content -Raw -LiteralPath $transaction.quarantineTimeAnchor.path |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-True ($transaction.schemaVersion -eq 3L) `
        'policy v5 must create transaction v3'
    Assert-True ($anchor.schemaVersion -eq 2L) `
        'quarantine-time anchor must use schema v2'
    Assert-True ($anchor.elapsedTimeSource -ceq 'system-uptime-milliseconds') `
        'quarantine-time anchor must name the production monotonic source'
    Assert-True ($anchor.elapsedTimeStartMilliseconds -is [long] -and
        $anchor.elapsedTimeStartMilliseconds -ge 0L) `
        'quarantine-time anchor must capture a non-negative monotonic start'
    Assert-True ($anchor.bootSessionId -is [string] -and
        $anchor.bootSessionId -match '^[0-9a-f]{64}$') `
        'quarantine-time anchor must bind a production-observable boot session'

    $transaction.updatedAtUtc = '2000-01-01T00:00:00.0000000+00:00'
    [IO.File]::WriteAllText(
        $apply.transactionPath,
        ($transaction | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    $apply.transactionSha256 = (Get-FileHash `
        -LiteralPath $apply.transactionPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()

    $v5PolicyText = Get-Content -Raw -LiteralPath $policyPath
    $transactionBytesBeforeRollback = [IO.File]::ReadAllBytes($apply.transactionPath)
    $v4Policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4L
        entries = @([pscustomobject][ordered]@{
            id = 'grace-fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1L
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            deniedExactPaths = @($evidenceRoot)
        })
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($v4Policy | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false))
    $rollbackError = Assert-Throws -Message 'policy v4 rollback must refuse transaction v3' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$apply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$apply.transactionSha256) `
            -ConfirmPurge `
            -FixtureTrustedNowUtc ([datetimeoffset]$anchor.createdAtUtc).AddMinutes(10) `
            -FixtureTrustedElapsedNowMilliseconds `
                ([long]$anchor.elapsedTimeStartMilliseconds + 600000L) `
            -FixtureTrustedBootSessionId ([string]$anchor.bootSessionId) `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rollbackError -match 'policy rollback.*manual-review') `
        'transaction v3 policy rollback must enter manual-review'
    Assert-True ([Linq.Enumerable]::SequenceEqual(
        [byte[]]$transactionBytesBeforeRollback,
        [byte[]][IO.File]::ReadAllBytes($apply.transactionPath))) `
        'policy rollback refusal must not rewrite transaction v3'

    [IO.File]::WriteAllText($policyPath, $v5PolicyText, [Text.UTF8Encoding]::new($false))
    $zeroAgePolicy = $v5PolicyText |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $zeroAgePolicy.entries[0].minimumQuarantineAgeMinutes = 0L
    $zeroAgePolicyText = $zeroAgePolicy | ConvertTo-Json -Depth 16
    $policyReread = {
        param([string]$IgnoredTargetPath)
        [IO.File]::WriteAllText(
            $policyPath,
            $zeroAgePolicyText,
            [Text.UTF8Encoding]::new($false))
    }.GetNewClosure()
    $purge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$apply.transactionSha256) `
        -ConfirmPurge `
        -FixtureBeforePurgeMutex $policyReread `
        -FixtureTrustedNowUtc ([datetimeoffset]$anchor.createdAtUtc) `
        -FixtureTrustedElapsedNowMilliseconds ([long]$anchor.elapsedTimeStartMilliseconds) `
        -FixtureTrustedBootSessionId ([string]$anchor.bootSessionId) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($purge.purged -eq $true) `
        'Purge must re-read the current minimum age inside the target mutex'

    [IO.File]::WriteAllText($policyPath, $v5PolicyText, [Text.UTF8Encoding]::new($false))
    $clockTarget = Join-Path $fixtureRoot 'clock-target'
    [void][IO.Directory]::CreateDirectory($clockTarget)
    [IO.File]::WriteAllText(
        (Join-Path $clockTarget 'clock.txt'),
        'clock-continuity',
        [Text.UTF8Encoding]::new($false))
    $clockPlan = & $entryPath -Mode Plan -TargetPath $clockTarget `
        -CapabilityRoot $fixtureRoot -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $clockApply = & $entryPath -Mode Apply -PlanPath $clockPlan.planPath `
        -ApprovedPlanSha256 $clockPlan.planSha256 -ConfirmApply `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $clockTransaction = Get-Content -Raw -LiteralPath $clockApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $clockAnchor = Get-Content -Raw -LiteralPath $clockTransaction.quarantineTimeAnchor.path |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $driftError = Assert-Throws -Message 'wall/monotonic drift must refuse Purge' -Action {
        & $entryPath -Mode Purge -TransactionPath $clockApply.transactionPath `
            -ApprovedTransactionSha256 $clockApply.transactionSha256 -ConfirmPurge `
            -FixtureTrustedNowUtc ([datetimeoffset]$clockAnchor.createdAtUtc).AddMinutes(1) `
            -FixtureTrustedElapsedNowMilliseconds `
                ([long]$clockAnchor.elapsedTimeStartMilliseconds + 600000L) `
            -FixtureTrustedBootSessionId ([string]$clockAnchor.bootSessionId) `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($driftError -match 'manual-review.*continuity drift') `
        'wall/monotonic drift must enter manual-review'
    $forwardJumpError = Assert-Throws -Message 'abnormal forward jump must refuse Purge' -Action {
        & $entryPath -Mode Purge -TransactionPath $clockApply.transactionPath `
            -ApprovedTransactionSha256 $clockApply.transactionSha256 -ConfirmPurge `
            -FixtureTrustedNowUtc ([datetimeoffset]$clockAnchor.createdAtUtc).AddDays(400) `
            -FixtureTrustedElapsedNowMilliseconds `
                ([long]$clockAnchor.elapsedTimeStartMilliseconds + 600000L) `
            -FixtureTrustedBootSessionId ([string]$clockAnchor.bootSessionId) `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($forwardJumpError -match 'manual-review.*abnormal forward jump') `
        'abnormal wall-clock forward jump must enter manual-review'
    Assert-True ([IO.Directory]::Exists([string]$clockApply.quarantinePath)) `
        'clock refusal must preserve recoverable quarantine'
    [void](& $entryPath -Mode Restore -TransactionPath $clockApply.transactionPath `
        -ApprovedTransactionSha256 $clockApply.transactionSha256 -ConfirmRestore `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot)

    $crashTarget = Join-Path $fixtureRoot 'missing-anchor-target'
    [void][IO.Directory]::CreateDirectory($crashTarget)
    [IO.File]::WriteAllText(
        (Join-Path $crashTarget 'crash.txt'),
        'recover-conservatively',
        [Text.UTF8Encoding]::new($false))
    $crashPlan = & $entryPath -Mode Plan -TargetPath $crashTarget `
        -CapabilityRoot $fixtureRoot -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $crashPlanDocument = Get-Content -Raw -LiteralPath $crashPlan.planPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $crashRunDirectory = Split-Path -Parent ([string]$crashPlan.planPath)
    $crashTransactionPath = Join-Path $crashRunDirectory 'transaction.json'
    $crashQuarantinePath = Join-Path `
        (Split-Path -Parent $crashTarget) `
        ('.codex-safe-delete-{0}.quarantine' -f [string]$crashPlanDocument.generationId)
    $markerRoot = Join-Path $fixtureRoot 'crash-markers'
    [void][IO.Directory]::CreateDirectory($markerRoot)
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
            (Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteApplyCrashFixture.ps1'),
            '-PlanPath', [string]$crashPlan.planPath,
            '-ApprovedPlanSha256', [string]$crashPlan.planSha256,
            '-FixturePolicyPath', $policyPath,
            '-FixtureEvidenceRoot', $evidenceRoot,
            '-MarkerRoot', $markerRoot)) {
        [void]$processInfo.ArgumentList.Add($argument)
    }
    $crashProcess = [Diagnostics.Process]::Start($processInfo)
    try {
        Assert-True ($crashProcess.WaitForExit(30000)) 'apply crash fixture timed out'
        Assert-True ($crashProcess.ExitCode -ne 0) 'apply crash fixture must terminate non-zero'
    } finally {
        $crashProcess.Dispose()
    }
    Assert-True ([IO.Directory]::Exists($crashQuarantinePath) -and
        -not [IO.File]::Exists((Join-Path $crashRunDirectory 'quarantine-time.json'))) `
        'rename crash must leave prepared v3 quarantine without an anchor'
    $crashTransactionSha256 = (Get-FileHash `
        -LiteralPath $crashTransactionPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    $unexpectedPath = Join-Path $crashQuarantinePath 'unexpected.txt'
    [IO.File]::WriteAllText($unexpectedPath, 'drift', [Text.UTF8Encoding]::new($false))
    [void](Assert-Throws -Message 'tree drift must block conservative anchor creation' -Action {
        & $entryPath -Mode Purge -TransactionPath $crashTransactionPath `
            -ApprovedTransactionSha256 $crashTransactionSha256 -ConfirmPurge `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    })
    Assert-True (-not [IO.File]::Exists((Join-Path $crashRunDirectory 'quarantine-time.json'))) `
        'tree drift must fail before conservative anchor publication'
    [IO.File]::Delete($unexpectedPath)
    $recoveryNow = [datetimeoffset]::UtcNow
    $recoveryElapsed = [Environment]::TickCount64
    $earlyRecoveryError = Assert-Throws -Message 'recovery anchor must restart grace' -Action {
        & $entryPath -Mode Purge -TransactionPath $crashTransactionPath `
            -ApprovedTransactionSha256 $crashTransactionSha256 -ConfirmPurge `
            -FixtureTrustedNowUtc $recoveryNow `
            -FixtureTrustedElapsedNowMilliseconds $recoveryElapsed `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($earlyRecoveryError -match 'grace not satisfied') `
        'missing anchor recovery must conservatively restart grace'
    $recoveredTransaction = Get-Content -Raw -LiteralPath $crashTransactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $recoveredAnchorPath = [string]$recoveredTransaction.quarantineTimeAnchor.path
    $recoveredAnchorHash = (Get-FileHash -LiteralPath $recoveredAnchorPath -Algorithm SHA256).Hash
    $recoveredTransactionSha256 = (Get-FileHash `
        -LiteralPath $crashTransactionPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    [void](Assert-Throws -Message 'repeated early recovery must still refuse' -Action {
        & $entryPath -Mode Purge -TransactionPath $crashTransactionPath `
            -ApprovedTransactionSha256 $recoveredTransactionSha256 -ConfirmPurge `
            -FixtureTrustedNowUtc $recoveryNow `
            -FixtureTrustedElapsedNowMilliseconds $recoveryElapsed `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    })
    Assert-True ((Get-FileHash -LiteralPath $recoveredAnchorPath -Algorithm SHA256).Hash -ceq
        $recoveredAnchorHash) `
        'repeated recovery must not republish or rewrite the immutable anchor'
    $recoveredAnchor = Get-Content -Raw -LiteralPath $recoveredAnchorPath |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $recoveredPurge = & $entryPath -Mode Purge -TransactionPath $crashTransactionPath `
        -ApprovedTransactionSha256 $recoveredTransactionSha256 -ConfirmPurge `
        -FixtureTrustedNowUtc $recoveryNow.AddMinutes(10) `
        -FixtureTrustedElapsedNowMilliseconds ($recoveryElapsed + 600000L) `
        -FixtureTrustedBootSessionId ([string]$recoveredAnchor.bootSessionId) `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($recoveredPurge.purged -eq $true) `
        'conservative recovery anchor exact boundary must allow Purge'

    $bootTarget = Join-Path $fixtureRoot 'boot-source-target'
    [void][IO.Directory]::CreateDirectory($bootTarget)
    [IO.File]::WriteAllText(
        (Join-Path $bootTarget 'boot.txt'),
        'boot-source-fail-closed',
        [Text.UTF8Encoding]::new($false))
    $bootPlan = & $entryPath -Mode Plan -TargetPath $bootTarget `
        -CapabilityRoot $fixtureRoot -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $bootApply = & $entryPath -Mode Apply -PlanPath $bootPlan.planPath `
        -ApprovedPlanSha256 $bootPlan.planSha256 -ConfirmApply `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    $bootTransaction = Get-Content -Raw -LiteralPath $bootApply.transactionPath |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $bootAnchorPath = [string]$bootTransaction.quarantineTimeAnchor.path
    $bootAnchor = Get-Content -Raw -LiteralPath $bootAnchorPath |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $bootWallNow = ([datetimeoffset]$bootAnchor.createdAtUtc).AddMinutes(1)
    $bootElapsedNow = [long]$bootAnchor.elapsedTimeStartMilliseconds + 60000L
    $validBootTime = $bootWallNow.AddDays(-1).UtcDateTime
    $bootSourceCases = @(
        [pscustomobject]@{
            name = 'unavailable'
            source = { throw 'simulated CIM unavailable' }
            errorPattern = 'manual-review.*boot session source unavailable'
        },
        [pscustomobject]@{
            name = 'multiple-results'
            source = {
                [pscustomobject]@{ LastBootUpTime = $validBootTime }
                [pscustomobject]@{ LastBootUpTime = $validBootTime }
            }.GetNewClosure()
            errorPattern = 'manual-review.*boot session source was ambiguous'
        },
        [pscustomobject]@{
            name = 'null-boot-time'
            source = { [pscustomobject]@{ LastBootUpTime = $null } }
            errorPattern = 'manual-review.*boot session source was ambiguous'
        },
        [pscustomobject]@{
            name = 'invalid-boot-time'
            source = { [pscustomobject]@{ LastBootUpTime = 'not-a-time' } }
            errorPattern = 'manual-review.*boot session source was invalid'
        },
        [pscustomobject]@{
            name = 'future-boot-time'
            source = {
                [pscustomobject]@{ LastBootUpTime = $bootWallNow.AddSeconds(1).UtcDateTime }
            }.GetNewClosure()
            errorPattern = 'manual-review.*boot session source was in the future'
        }
    )
    foreach ($bootSourceCase in $bootSourceCases) {
        $transactionStateBefore = Get-EvidenceFileState -Path $bootApply.transactionPath
        $anchorStateBefore = Get-EvidenceFileState -Path $bootAnchorPath
        $bootSourceError = Assert-Throws `
            -Message ("boot source case {0} must refuse Purge" -f $bootSourceCase.name) `
            -Action {
                & $entryPath -Mode Purge -TransactionPath $bootApply.transactionPath `
                    -ApprovedTransactionSha256 $bootApply.transactionSha256 -ConfirmPurge `
                    -FixtureTrustedNowUtc $bootWallNow `
                    -FixtureTrustedElapsedNowMilliseconds $bootElapsedNow `
                    -FixtureTrustedBootSessionSource $bootSourceCase.source `
                    -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
            }
        Assert-True ($bootSourceError -match $bootSourceCase.errorPattern) `
            ("boot source case {0} must enter manual-review" -f $bootSourceCase.name)
        $transactionStateAfter = Get-EvidenceFileState -Path $bootApply.transactionPath
        $anchorStateAfter = Get-EvidenceFileState -Path $bootAnchorPath
        Assert-True ($transactionStateAfter.sha256 -ceq $transactionStateBefore.sha256 -and
            (($transactionStateAfter.identity -join '|') -ceq
                ($transactionStateBefore.identity -join '|'))) `
            ("boot source case {0} must not rewrite transaction" -f $bootSourceCase.name)
        Assert-True ($anchorStateAfter.sha256 -ceq $anchorStateBefore.sha256 -and
            (($anchorStateAfter.identity -join '|') -ceq ($anchorStateBefore.identity -join '|'))) `
            ("boot source case {0} must not rewrite anchor" -f $bootSourceCase.name)
        Assert-True ([IO.Directory]::Exists([string]$bootApply.quarantinePath)) `
            ("boot source case {0} must preserve quarantine" -f $bootSourceCase.name)
    }
    [void](& $entryPath -Mode Restore -TransactionPath $bootApply.transactionPath `
        -ApprovedTransactionSha256 $bootApply.transactionSha256 -ConfirmRestore `
        -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot)

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteGrace'
        slices = 10
    }
} finally {
    Remove-TestTree -Path $fixtureRoot
}
