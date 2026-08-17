# Production #20 evidence: .cmd -> host wrapper -> Purge -Json leaf-delete-failed.
# Uses reports/ allowlist only. Holds FileShare.Read after transaction status becomes purging,
# which is after locked preflight releases leases. Not a second production entry.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$liveWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$reportsRoot = Join-Path $projectRoot 'reports'
$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$lockHolder = Join-Path $PSScriptRoot 'issue20-lock-holder.ps1'
$fixtureRoot = Join-Path $reportsRoot ('safe-tree-delete-issue20-livefail-{0}' -f ([guid]::NewGuid().ToString('N')))
$payloadPath = Join-Path $fixtureRoot 'locked-payload.txt'
$acquiredMarkerPath = Join-Path $OutputDirectory 'lock-acquired.txt'
$releaseSignalPath = Join-Path $OutputDirectory 'lock-release.signal'
$lockLogPath = Join-Path $OutputDirectory 'lock-holder.log'
$purgeStdoutPath = Join-Path $OutputDirectory 'purge-fail.stdout.txt'
$purgeStderrPath = Join-Path $OutputDirectory 'purge-fail.stderr.txt'
$resumeStdoutPath = Join-Path $OutputDirectory 'purge-resume.stdout.txt'
$evidencePath = Join-Path $OutputDirectory 'issue20-production-purge-fail.json'

[void][IO.Directory]::CreateDirectory($OutputDirectory)

function Invoke-LiveSafeDeleteDirect {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = & $liveWrapper @Arguments
    $exitCode = if (Test-Path Variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $text = ($raw -join "`n")
    return [pscustomobject][ordered]@{
        exitCode = $exitCode
        raw = $text
        document = $text | ConvertFrom-Json -Depth 32 -DateKind String
    }
}

$startedAtUtc = [datetimeoffset]::UtcNow
$plan = $null
$apply = $null
$purge = $null
$lockProcess = $null
$evidence = $null
$cleanup = [ordered]@{
    lockReleased = $false
    resumeAttempted = $false
    resumeExitCode = $null
    resumePurged = $null
    resumeRaw = $null
    resumeApprovedSha256 = $null
    fixtureExistsAfter = $null
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [IO.File]::WriteAllText($payloadPath, 'issue20-production-leaf-delete-failed', [Text.UTF8Encoding]::new($false))

    $plan = Invoke-LiveSafeDeleteDirect -Arguments @(
        '-Mode', 'Plan'
        '-TargetPath', $fixtureRoot
        '-CapabilityRoot', $reportsRoot
        '-Json'
    )
    if ($plan.exitCode -ne 0 -or $plan.document.planned -ne $true) {
        throw "Plan failed: exit=$($plan.exitCode) raw=$($plan.raw)"
    }

    $apply = Invoke-LiveSafeDeleteDirect -Arguments @(
        '-Mode', 'Apply'
        '-PlanPath', [string]$plan.document.planPath
        '-ApprovedPlanSha256', [string]$plan.document.planSha256
        '-ConfirmApply'
        '-Json'
    )
    if ($apply.exitCode -ne 0 -or $apply.document.quarantined -ne $true) {
        throw "Apply failed: exit=$($apply.exitCode) raw=$($apply.raw)"
    }

    $quarantinePath = [string]$apply.document.quarantinePath
    $quarantinePayload = Join-Path $quarantinePath 'locked-payload.txt'
    if (-not [IO.File]::Exists($quarantinePayload)) {
        throw "quarantine payload missing: $quarantinePayload"
    }

    $lockArgs = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $lockHolder
        '-TransactionPath', [string]$apply.document.transactionPath
        '-PayloadPath', $quarantinePayload
        '-AcquiredMarkerPath', $acquiredMarkerPath
        '-ReleaseSignalPath', $releaseSignalPath
        '-LogPath', $lockLogPath
        '-TimeoutSeconds', '90'
    )
    $lockProcess = Start-Process -FilePath $pwsh `
        -ArgumentList $lockArgs `
        -WorkingDirectory $OutputDirectory `
        -PassThru -NoNewWindow

    $purge = Invoke-LiveSafeDeleteDirect -Arguments @(
        '-Mode', 'Purge'
        '-TransactionPath', [string]$apply.document.transactionPath
        '-ApprovedTransactionSha256', [string]$apply.document.transactionSha256
        '-ConfirmPurge'
        '-Json'
    )
    [IO.File]::WriteAllText($purgeStdoutPath, [string]$purge.raw, [Text.UTF8Encoding]::new($false))

    $metrics = $null
    if ($null -ne $purge.document -and $purge.document.PSObject.Properties.Name -contains 'metrics') {
        $metrics = $purge.document.metrics
    }

    $evidence = [ordered]@{
        artifactType = 'unified-environment.safe-tree-delete.issue20.production-purge-leaf-delete-failed'
        schemaVersion = 1
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        startedAtUtc = $startedAtUtc.ToString('o')
        wallClockSeconds = [math]::Round(([datetimeoffset]::UtcNow - $startedAtUtc).TotalSeconds, 3)
        invokedVia = $liveWrapper
        lockStrategy = 'watch-transaction-status-purging-then-FileShare.Read'
        lockAcquiredMarkerExists = [IO.File]::Exists($acquiredMarkerPath)
        plan = [ordered]@{
            exitCode = [int]$plan.exitCode
            planned = [bool]$plan.document.planned
            planPath = [string]$plan.document.planPath
            planSha256 = [string]$plan.document.planSha256
        }
        apply = [ordered]@{
            exitCode = [int]$apply.exitCode
            quarantined = [bool]$apply.document.quarantined
            transactionPath = [string]$apply.document.transactionPath
            transactionSha256 = [string]$apply.document.transactionSha256
            quarantinePath = $quarantinePath
        }
        purge = [ordered]@{
            exitCode = [int]$purge.exitCode
            lastExitCodeCheckedImmediately = $true
            stdout = [string]$purge.raw
            purged = $(if ($null -ne $purge.document -and $purge.document.PSObject.Properties.Name -contains 'purged') { [bool]$purge.document.purged } else { $null })
            refusalReason = $(if ($null -ne $purge.document -and $purge.document.PSObject.Properties.Name -contains 'refusalReason') { [string]$purge.document.refusalReason } else { $null })
            recoverable = $(if ($null -ne $purge.document -and $purge.document.PSObject.Properties.Name -contains 'recoverable') { [bool]$purge.document.recoverable } else { $null })
            purgeResumable = $(if ($null -ne $purge.document -and $purge.document.PSObject.Properties.Name -contains 'purgeResumable') { [bool]$purge.document.purgeResumable } else { $null })
            metricsPresent = ($null -ne $metrics)
            metrics = $metrics
        }
        requiredShape = [ordered]@{
            purged = $false
            refusalReason = 'leaf-delete-failed'
            metricsPresent = $true
            nonzeroExit = $true
            source = 'production-Purge-via-managed-wrapper'
        }
        lockProcessId = [int]$lockProcess.Id
    }

    $evidence.assertions = [ordered]@{
        purgedFalse = ($evidence.purge.purged -eq $false)
        refusalIsLeafDeleteFailed = ($evidence.purge.refusalReason -ceq 'leaf-delete-failed')
        metricsPresent = [bool]$evidence.purge.metricsPresent
        nonzeroExit = ($evidence.purge.exitCode -ne 0)
        lockAcquired = [bool]$evidence.lockAcquiredMarkerExists
        productionJsonObtained = (
            $evidence.purge.purged -eq $false -and
            $evidence.purge.refusalReason -ceq 'leaf-delete-failed' -and
            [bool]$evidence.purge.metricsPresent -and
            $evidence.purge.exitCode -ne 0)
    }
} finally {
    [IO.File]::WriteAllText($releaseSignalPath, [datetimeoffset]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
    $cleanup.lockReleased = $true
    if ($null -ne $lockProcess -and -not $lockProcess.HasExited) {
        [void]$lockProcess.WaitForExit(15000)
    }
    if ($null -ne $apply -and $apply.document.quarantined -eq $true) {
        $cleanup.resumeAttempted = $true
        $resumeSha = (Get-FileHash -LiteralPath ([string]$apply.document.transactionPath) -Algorithm SHA256).Hash
        $cleanup.resumeApprovedSha256 = $resumeSha
        $resume = Invoke-LiveSafeDeleteDirect -Arguments @(
            '-Mode', 'Purge'
            '-TransactionPath', [string]$apply.document.transactionPath
            '-ApprovedTransactionSha256', $resumeSha
            '-ConfirmPurge'
            '-Json'
        )
        [IO.File]::WriteAllText($resumeStdoutPath, [string]$resume.raw, [Text.UTF8Encoding]::new($false))
        $cleanup.resumeExitCode = [int]$resume.exitCode
        $cleanup.resumeRaw = [string]$resume.raw
        if ($null -ne $resume.document -and $resume.document.PSObject.Properties.Name -contains 'purged') {
            $cleanup.resumePurged = [bool]$resume.document.purged
        }
    }
    $cleanup.fixtureExistsAfter = [IO.Directory]::Exists($fixtureRoot)
    if ($null -ne $evidence) {
        $evidence.cleanup = $cleanup
        [IO.File]::WriteAllText(
            $evidencePath,
            ($evidence | ConvertTo-Json -Depth 16),
            [Text.UTF8Encoding]::new($false))
    }
}

if ($null -eq $evidence -or -not [bool]$evidence.assertions.productionJsonObtained) {
    throw "issue20 production leaf-delete-failed JSON was not obtained. See $evidencePath"
}

[pscustomobject]$evidence.assertions
