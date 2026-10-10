Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexHostSafety.ps1')
. (Join-Path $PSScriptRoot 'CodexSafeTreeDelete.ps1')

function Test-SafeCleanupJobPathEqual([string]$Left, [string]$Right) {
    return [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($Left),[IO.Path]::GetFullPath($Right))
}

function Read-SafeCleanupJobJson([string]$Path, [string]$ExpectedSha256, [ref]$SnapshotResult) {
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $Path -Name 'cleanup job document' -AllowedExactPaths @($Path)
    if ($ExpectedSha256 -and $snapshot.sha256 -ine $ExpectedSha256) { throw 'Cleanup document SHA drift.' }
    if ($null -ne $SnapshotResult) { $SnapshotResult.Value=$snapshot }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    return $snapshot.text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}

function Write-SafeCleanupJobJson {
    param([string]$Path, [object]$Document, [scriptblock]$BeforeRename)
    $root = Split-Path -Parent $Path
    $before = Get-CodexHookCapabilityFileSnapshot -Path $Path -CapabilityRoot $root -AllowedExactPaths @($Path) -Name 'cleanup checkpoint prewrite'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Document | ConvertTo-Json -Depth 100))
    Set-CodexHookAtomicFileBytesWithCapability -Path $Path -Bytes $bytes -ExpectedExists $before.exists -ExpectedSha256 $before.sha256 -ExpectedIdentity $before.identity -AfterSha256 (Get-CodexHookBytesSha256 $bytes) -CapabilityRoot $root -AllowedExactPaths @($Path) -Scope 'cleanup job checkpoint' -BeforeRename $BeforeRename
}

function ConvertTo-SafeCleanupJobCanonical([object]$Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [Collections.IDictionary]) {
        $pairs = foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            '{0}:{1}' -f (ConvertTo-Json ([string]$key) -Compress), (ConvertTo-SafeCleanupJobCanonical $Value[$key])
        }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [array]) {
        $items = foreach ($item in $Value) { ConvertTo-SafeCleanupJobCanonical $item }
        return '[' + ($items -join ',') + ']'
    }
    return ConvertTo-Json $Value -Compress -Depth 100
}

function Compare-SafeCleanupJobPolicy {
    param([Collections.IDictionary]$OldPolicy, [Collections.IDictionary]$CurrentPolicy, [string]$CapabilityRoot)
    $oldGlobal = @{}; $newGlobal = @{}
    foreach ($key in $OldPolicy.Keys) { if ($key -ne 'entries') { $oldGlobal[$key]=$OldPolicy[$key] } }
    foreach ($key in $CurrentPolicy.Keys) { if ($key -ne 'entries') { $newGlobal[$key]=$CurrentPolicy[$key] } }
    $reasons = [Collections.Generic.List[string]]::new()
    if ((ConvertTo-SafeCleanupJobCanonical $oldGlobal) -cne (ConvertTo-SafeCleanupJobCanonical $newGlobal)) { $reasons.Add('global-policy-changed') }
    $oldById=@{}; $newById=@{}
    foreach ($entry in $OldPolicy.entries) {
        if ($oldById.ContainsKey($entry.id)) { throw 'Duplicate old policy id.' }
        $oldById[$entry.id]=$entry
    }
    foreach ($entry in $CurrentPolicy.entries) {
        if ($newById.ContainsKey($entry.id)) { throw 'Duplicate current policy id.' }
        $newById[$entry.id]=$entry
    }
    foreach ($id in $oldById.Keys) {
        if (-not $newById.ContainsKey($id) -or (ConvertTo-SafeCleanupJobCanonical $oldById[$id]) -cne (ConvertTo-SafeCleanupJobCanonical $newById[$id])) { $reasons.Add("existing-entry-changed:$id") }
    }
    $added = @($newById.Keys | Where-Object { -not $oldById.ContainsKey($_) } | Sort-Object)
    foreach ($id in $added) {
        $root = [IO.Path]::GetFullPath([string]$newById[$id].capabilityRoot)
        $cap = [IO.Path]::GetFullPath($CapabilityRoot)
        if ((Test-CodexHookPathWithin -Path $root -ParentPath $cap) -or (Test-CodexHookPathWithin -Path $cap -ParentPath $root)) { $reasons.Add("overlapping-entry-added:$id") }
    }
    if (@($OldPolicy.entries | Where-Object { Test-SafeCleanupJobPathEqual $_.capabilityRoot $CapabilityRoot }).Count -ne 1) { $reasons.Add('original-capability-not-unique') }
    return @{ compatible=($reasons.Count -eq 0); reasons=@($reasons); addedEntryIds=$added }
}

function Get-SafeCleanupJobHealth {
    param([Collections.IDictionary]$State, [Collections.IDictionary]$Ledger, [AllowNull()][object]$ProcessObservation)
    $matches = $false
    if ($null -ne $ProcessObservation -and $State.Contains('executable')) {
        $matches = [long]$ProcessObservation.pid -eq [long]$State.pid -and
            [Math]::Abs(([datetimeoffset]$ProcessObservation.startUtc).UtcTicks - ([datetimeoffset]$State.processStartUtc).UtcTicks) -le 10 -and
            (Test-SafeCleanupJobPathEqual $ProcessObservation.executable $State.executable) -and
            ([string]$ProcessObservation.commandLine).Contains([string]$State.ownerTokenHash) -and -not [string]::IsNullOrWhiteSpace([string]$State.ownerTokenHash)
    }
    $counts=@{processed=0;skipped=0;failed=0;pending=0;'manual-review'=0}; [long]$bytes=0
    foreach ($unit in $Ledger.units) {
        if (-not $counts.ContainsKey([string]$unit.status)) { throw "Unknown unit status: $($unit.status)" }
        $counts[[string]$unit.status]++
        if ($unit.status -eq 'processed') { $bytes += [long]$unit.baseline.bytes }
    }
    $health = [string]$State.processState
    if ($health -eq 'running' -and -not $matches) { $health='interrupted' }
    if ($health -eq 'completed' -and ($counts.pending -gt 0 -or $counts.failed -gt 0 -or $counts['manual-review'] -gt 0)) { $health='incomplete' }
    return [ordered]@{ health=$health; processIdentityMatches=$matches; pid=$State.pid; lastProgressUtc=$State.updatedAtUtc; taskFailure=($health -in @('failed','interrupted','incomplete')); error=$State.error; processedCount=$counts.processed;processedBytes=$bytes;skippedCount=$counts.skipped;failedCount=$counts.failed;manualReviewCount=$counts['manual-review'];pendingCount=$counts.pending;physicalReclaimStatus='unknown' }
}

function Get-SafeCleanupJobPathGeneration {
    param([string[]]$OriginalIdentity, [string[]]$CurrentIdentity, [bool]$Exists)
    if (-not $Exists) { return 'absent' }
    if ($OriginalIdentity.Count -ne 2 -or $CurrentIdentity.Count -ne 2) { return 'unknown-preserved' }
    if (Test-CodexHookDirectoryTreeIdentityEqual -Expected $OriginalIdentity -Actual $CurrentIdentity) { return 'original-present' }
    return 'recreated-preserved'
}

function Read-SafeCleanupJob {
    param([string]$JobPath)
    $job = Read-SafeCleanupJobJson $JobPath
    $scope = Read-SafeCleanupJobJson $job.scopePath $job.scopeSha256
    $ledger = Read-SafeCleanupJobJson $job.ledgerPath
    if ($ledger.scopeSha256 -ine $job.scopeSha256) { throw 'Ledger scope mismatch.' }
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $baselines=@{}
    foreach ($unit in $scope.units) {
        $path=[IO.Path]::GetFullPath([string]$unit.path)
        if (-not $paths.Add($path)) { throw 'Duplicate scope target.' }
        $baselines[$path]=$unit.baseline
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($unit in $ledger.units) {
        $path=[IO.Path]::GetFullPath([string]$unit.path)
        if (-not $seen.Add($path)) { throw 'Duplicate ledger target.' }
        if (-not $paths.Contains($path)) { throw "Ledger target outside immutable scope: $path" }
        if ((ConvertTo-SafeCleanupJobBaselineCanonical $unit.baseline) -cne (ConvertTo-SafeCleanupJobBaselineCanonical $baselines[$path])) { throw 'Ledger baseline differs from approved scope.' }
        if (-not (Test-CodexHookPathWithin -Path $path -ParentPath $scope.capabilityRoot) -or (Test-SafeCleanupJobPathEqual $path $scope.capabilityRoot)) { throw 'Scope target outside descendant capability.' }
    }
    if ($ledger.units.Count -ne $paths.Count) { throw 'Ledger and scope target count mismatch.' }
    return @{job=$job;scope=$scope;ledger=$ledger}
}

function ConvertTo-SafeCleanupJobBaselineCanonical([Collections.IDictionary]$Baseline) {
    $normalized=@{}
    foreach ($key in $Baseline.Keys) {
        $normalized[$key]=$Baseline[$key]
        if ($key -in @('createdUtc','modifiedUtc','latestCreationOrWriteUtc')) { $normalized[$key]=([datetimeoffset]$Baseline[$key]).ToUniversalTime().ToString('o') }
    }
    return ConvertTo-SafeCleanupJobCanonical $normalized
}

function New-SafeCleanupJobMutex([string]$JobPath) {
    return [Threading.Mutex]::new($false,('Local\SafeCleanupJob-'+(Get-CodexHookBytesSha256 ([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($JobPath).ToLowerInvariant())))))
}

function Assert-SafeCleanupJobPlanBaseline([object]$Context, [string]$TargetPath, [object]$Plan, [switch]$RequireIdentity) {
    $unit=@($Context.scope.units | Where-Object { Test-SafeCleanupJobPathEqual $_.path $TargetPath })
    if ($unit.Count -ne 1 -or -not (Test-SafeCleanupJobPathEqual $Plan.targetPath $TargetPath)) { throw 'Plan target outside immutable scope.' }
    $baseline=$unit[0].baseline
    if (-not $baseline.Contains('rootIdentity')) {
        if ($RequireIdentity) { throw 'Execution requires identity in immutable scope.' }
        return
    }
    if (@($baseline.rootIdentity).Count -ne 2 -or -not $baseline.Contains('treeManifestSha256')) { throw 'Incomplete immutable baseline.' }
    if (-not (Test-CodexHookDirectoryTreeIdentityEqual -Expected $baseline.rootIdentity -Actual $Plan.treeManifest.rootIdentity)) { throw 'Plan generation differs from immutable scope.' }
    $planObject=($Plan | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100 -DateKind String
    if ((Get-CodexSafeTreeDeleteManifestSha256 $planObject.treeManifest) -cne $baseline.treeManifestSha256) { throw 'Plan tree differs from immutable scope.' }
}

function Assert-SafeCleanupJobPlanPolicy([object]$Context, [string]$PolicySha256) {
    $snapshots=@(@{path=$Context.job.policySnapshotPath;sha256=$Context.job.policySnapshotSha256})
    if ($Context.job.Contains('policySnapshots')) { $snapshots+=@($Context.job.policySnapshots) }
    $currentHash=(Get-FileHash -LiteralPath $Context.job.policyPath).Hash
    if ($currentHash -ieq $PolicySha256) {
        $comparison=Compare-SafeCleanupJobPolicy (Read-SafeCleanupJobJson $Context.job.policySnapshotPath $Context.job.policySnapshotSha256) (Read-SafeCleanupJobJson $Context.job.policyPath $PolicySha256) $Context.scope.capabilityRoot
        if (-not $comparison.compatible) { throw 'Plan policy has relevant drift.' }
        return
    }
    $match=@($snapshots | Where-Object sha256 -IEQ $PolicySha256)
    if ($match.Count -eq 0) { throw 'Plan policy SHA has no verified snapshot.' }
    foreach ($snapshot in $match) {
        $comparison=Compare-SafeCleanupJobPolicy (Read-SafeCleanupJobJson $snapshot.path $snapshot.sha256) (Read-SafeCleanupJobJson $Context.job.policyPath) $Context.scope.capabilityRoot
        if (-not $comparison.compatible) { throw 'Plan policy snapshot has relevant drift.' }
    }
}

function Get-SafeCleanupJobStatus([string]$JobPath) {
    $context=Read-SafeCleanupJob $JobPath
    $state=Read-SafeCleanupJobJson $context.job.statePath
    if (-not $state.Contains('executable')) {
        $launch=Read-SafeCleanupJobJson $context.job.launchPath
        $state.executable=$launch.executable
    }
    $observation=$null
    try {
        $process=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction Stop
        if ($null -ne $process) { $observation=@{pid=$process.ProcessId;startUtc=$process.CreationDate.ToUniversalTime().ToString('o');executable=$process.ExecutablePath;commandLine=$process.CommandLine} }
    } catch { $state.error = 'Process observation unavailable: ' + $_.Exception.Message }
    return Get-SafeCleanupJobHealth -State $state -Ledger $context.ledger -ProcessObservation $observation
}

function Assert-SafeCleanupJobPolicy([object]$Context) {
    $job=$Context.job
    $currentSnapshot=$null
    $current=Read-SafeCleanupJobJson $job.policyPath -SnapshotResult ([ref]$currentSnapshot)
    $comparison=Compare-SafeCleanupJobPolicy -OldPolicy (Read-SafeCleanupJobJson $job.policySnapshotPath $job.policySnapshotSha256) -CurrentPolicy $current -CapabilityRoot $Context.scope.capabilityRoot
    if (-not $comparison.compatible) { throw ('Relevant policy drift: ' + ($comparison.reasons -join ', ')) }
    $comparison.currentPolicySha256=$currentSnapshot.sha256
    $comparison.oldPolicySha256=$job.policySnapshotSha256
    return $comparison
}

function Read-SafeCleanupJobReceipt {
    param([object]$Context, [string]$TransactionPath)
    $evidence=$Context.job.transactionEvidenceRoot
    [void](Assert-CodexHookCapabilityPath -Path $TransactionPath -CapabilityRoot $evidence -Name 'cleanup receipt')
    if ([IO.Path]::GetFileName($TransactionPath) -cne 'transaction.json') { throw 'Invalid receipt filename.' }
    $receiptSnapshot=$null
    $transaction=Read-SafeCleanupJobJson $TransactionPath -SnapshotResult ([ref]$receiptSnapshot)
    $run=Split-Path -Parent $TransactionPath
    $planPath=Join-Path $run 'plan.json'
    if (-not (Test-SafeCleanupJobPathEqual $transaction.planPath $planPath)) { throw 'Receipt plan outside run.' }
    # Historical evidence is validated with the current unchanged capability; it grants no deletion authority.
    $approved=Read-CodexSafeTreeDeleteApprovedPlan -PlanPath $planPath -ApprovedPlanSha256 $transaction.planSha256 -PolicyPath $Context.job.policyPath -EvidenceRoot $evidence -AllowMissingTarget -AllowExpiredPlan -AllowPolicyShaDrift
    Assert-SafeCleanupJobPlanPolicy $Context $approved.document.policySha256
    Assert-SafeCleanupJobPlanBaseline $Context $approved.target.targetPath $approved.document
    $doc=ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument -Document (($transaction | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100 -DateKind String)
    $quarantine=Join-Path (Split-Path -Parent $approved.target.targetPath) ('.codex-safe-delete-{0}.quarantine' -f $approved.document.generationId)
    Assert-CodexSafeTreeDeleteStrictTransactionEvidence -Transaction $doc -Plan $approved.document -PlanPath $planPath -PlanSha256 $transaction.planSha256 -TargetPath $approved.target.targetPath -QuarantinePath $quarantine -RunDirectory $run
    if ($doc.status -cne 'purged') { throw 'Receipt is not terminal purged.' }
    if (Test-Path -LiteralPath $quarantine) { throw 'Purged quarantine still exists.' }
    return @{transaction=$transaction;plan=$approved.document;transactionSha256=$receiptSnapshot.sha256}
}

function Test-SafeCleanupJobVerification([string]$JobPath) {
    $context=Read-SafeCleanupJob $JobPath
    [void](Assert-SafeCleanupJobPolicy $context)
    $results=[Collections.Generic.List[object]]::new()
    foreach ($unit in $context.ledger.units) {
        if ($unit.status -ne 'processed') { continue }
        try {
            $receipt=Read-SafeCleanupJobReceipt -Context $context -TransactionPath $unit.outcome.transactionPath
            if ($unit.outcome.Contains('transactionSha256') -and $unit.outcome.transactionSha256 -ine $receipt.transactionSha256) { throw 'Ledger receipt SHA drift.' }
            if (-not (Test-SafeCleanupJobPathEqual $unit.path $receipt.transaction.targetPath)) { throw 'Receipt target differs from ledger.' }
            $identity=@(); $exists=Test-Path -LiteralPath $unit.path
            if ($exists) {
                $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($context.scope.capabilityRoot,$unit.path,$false)
                try { $identity=@([string]$guard.VolumeSerialNumber,[string]$guard.FileIndex) } finally { $guard.Dispose() }
            }
            $generation=Get-SafeCleanupJobPathGeneration -OriginalIdentity $receipt.plan.treeManifest.rootIdentity -CurrentIdentity $identity -Exists $exists
            $results.Add(@{path=$unit.path;generation=$generation;actualPlanPolicySha256=$receipt.plan.policySha256;transactionSha256=$receipt.transactionSha256;identitySource=$(if ($unit.baseline.Contains('rootIdentity')) {'immutable-scope'} else {'historical-approved-plan'});receiptHashBinding=$(if ($unit.outcome.Contains('transactionSha256')) {'ledger-sha256'} else {'historical-evidence'})})
        } catch { $results.Add(@{path=$unit.path;generation='unverified-preserved';error=$_.Exception.Message}) }
    }
    $uncertain=@($results | Where-Object generation -in @('original-present','unknown-preserved','unverified-preserved'))
    return @{verified=($uncertain.Count -eq 0 -and @($context.ledger.units | Where-Object status -in @('pending','failed','manual-review')).Count -eq 0);processedCount=$results.Count;recreatedCount=@($results | Where-Object generation -eq 'recreated-preserved').Count;uncertainCount=$uncertain.Count;physicalReclaimStatus='unknown';results=@($results)}
}

function Invoke-SafeCleanupJobReconcile {
    param([string]$JobPath, [scriptblock]$BeforeCheckpoint)
    $mutex=New-SafeCleanupJobMutex $JobPath
    $acquired=$false
    try {
    try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
    if (-not $acquired) { throw 'Another worker owns this cleanup job.' }
    $context=Read-SafeCleanupJob $JobPath
    if ($context.job.Contains('readOnly') -and $context.job.readOnly) { throw 'Historical descriptor is read-only.' }
    [void](Assert-SafeCleanupJobPolicy $context)
    $recovered=0
    foreach ($unit in $context.ledger.units) {
        if ($unit.status -ne 'pending') { continue }
        $intentPath=Join-Path $context.job.intentRoot ((Get-CodexHookBytesSha256 ([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($unit.path).ToLowerInvariant()))) + '.json')
        if (-not (Test-Path -LiteralPath $intentPath)) { continue }
        $intent=Read-SafeCleanupJobJson $intentPath
        if ($intent.scopeSha256 -ine $context.job.scopeSha256 -or -not (Test-SafeCleanupJobPathEqual $intent.targetPath $unit.path)) { throw 'Intent scope/target mismatch.' }
        $transactionPath=Join-Path (Split-Path -Parent $intent.planPath) 'transaction.json'
        if (-not (Test-Path -LiteralPath $transactionPath)) { continue }
        $transaction=Read-SafeCleanupJobJson $transactionPath
        if ($transaction.status -ne 'purged') { continue }
        $receipt=Read-SafeCleanupJobReceipt $context $transactionPath
        if ($receipt.transaction.planSha256 -cne $intent.planSha256 -or -not (Test-SafeCleanupJobPathEqual $receipt.transaction.targetPath $unit.path) -or -not (Test-CodexHookDirectoryTreeIdentityEqual -Expected $intent.originalIdentity -Actual $receipt.plan.treeManifest.rootIdentity)) { throw 'Intent/receipt identity or plan mismatch.' }
        $unit.status='processed'
        $unit.outcome=@{action='receipt-reconciled';transactionPath=$transactionPath;transactionSha256=$receipt.transactionSha256;actualPlanPolicySha256=$receipt.plan.policySha256;preCallPolicySha256=$intent.preCallPolicySha256;originalIdentity=$intent.originalIdentity;observedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
        $recovered++
    }
    if ($recovered -gt 0) {
        $context.ledger.lastObservedAtUtc=[datetimeoffset]::UtcNow.ToString('o')
        Write-SafeCleanupJobJson -Path $context.job.ledgerPath -Document $context.ledger -BeforeRename $BeforeCheckpoint
    }
    return @{recoveredCount=$recovered;ledgerPath=$context.job.ledgerPath}
    } finally { if ($acquired) { $mutex.ReleaseMutex() };$mutex.Dispose() }
}

function Invoke-SafeCleanupJobGate {
    param([Collections.IDictionary]$Arguments)
    $processInfo=[Diagnostics.ProcessStartInfo]::new('D:/Codex/tools/PowerShell/7.6.5/pwsh.exe')
    $processInfo.UseShellExecute=$false; $processInfo.CreateNoWindow=$true
    $processInfo.RedirectStandardOutput=$true; $processInfo.RedirectStandardError=$true
    $processInfo.StandardOutputEncoding=[Text.Encoding]::UTF8; $processInfo.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File','D:/Codex/.codex/scripts/invoke-safe-tree-delete.ps1')) { $processInfo.ArgumentList.Add($arg) }
    foreach ($key in $Arguments.Keys) {
        $processInfo.ArgumentList.Add('-'+$key)
        if ($Arguments[$key] -isnot [bool]) { $processInfo.ArgumentList.Add([string]$Arguments[$key]) }
    }
    $processInfo.ArgumentList.Add('-Json')
    $process=[Diagnostics.Process]::Start($processInfo)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output=$stdout.GetAwaiter().GetResult(); $errorText=$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Gate exit $($process.ExitCode): $errorText" }
        return $output | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -ErrorAction Stop
    } finally { $process.Dispose() }
}

function Invoke-SafeCleanupJobUnit {
    param([string]$JobPath, [string]$TargetPath, [scriptblock]$GateInvoker, [scriptblock]$AfterPurge)
    $mutex=New-SafeCleanupJobMutex $JobPath;$acquired=$false
    try {
    try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
    if (-not $acquired) { throw 'Another worker owns this cleanup job.' }
    $context=Read-SafeCleanupJob $JobPath
    if ($context.job.Contains('readOnly') -and $context.job.readOnly) { throw 'Historical descriptor is read-only.' }
    [void](Assert-SafeCleanupJobPolicy $context)
    $matches=@($context.ledger.units | Where-Object { Test-SafeCleanupJobPathEqual $_.path $TargetPath })
    if ($matches.Count -ne 1 -or $matches[0].status -ne 'pending') { throw 'Unit is not uniquely pending in approved scope.' }
    $unit=$matches[0]
    if (-not $unit.baseline.Contains('rootIdentity') -or @($unit.baseline.rootIdentity).Count -ne 2 -or -not $unit.baseline.Contains('treeManifestSha256')) { throw 'Execution requires original directory identity and tree manifest hash in immutable scope.' }
    $scopeUnit=@($context.scope.units | Where-Object { Test-SafeCleanupJobPathEqual $_.path $TargetPath })[0]
    if ((ConvertTo-SafeCleanupJobBaselineCanonical $scopeUnit.baseline) -cne (ConvertTo-SafeCleanupJobBaselineCanonical $unit.baseline)) { throw 'Ledger baseline differs from approved scope.' }
    if ($null -eq $GateInvoker) { $GateInvoker={param($arguments) Invoke-SafeCleanupJobGate $arguments} }
    $intentPath=Join-Path $context.job.intentRoot ((Get-CodexHookBytesSha256 ([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($unit.path).ToLowerInvariant()))) + '.json')
    if (Test-Path -LiteralPath $intentPath) {
        $intent=Read-SafeCleanupJobJson $intentPath
        if ($intent.scopeSha256 -ine $context.job.scopeSha256 -or -not (Test-SafeCleanupJobPathEqual $intent.targetPath $unit.path)) { throw 'Intent scope drift.' }
    } else {
        $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($context.scope.capabilityRoot,$unit.path,$false)
        try { Assert-CodexHookDirectoryTreeIdentity -Expected $unit.baseline.rootIdentity -Actual @($guard.VolumeSerialNumber,$guard.FileIndex) -Scope 'cleanup original generation' } finally { $guard.Dispose() }
        $preCallHash=(Get-FileHash -LiteralPath $context.job.policyPath).Hash.ToLowerInvariant()
        $planResult=& $GateInvoker @{Mode='Plan';TargetPath=$unit.path;CapabilityRoot=$context.scope.capabilityRoot}
        $plan=Read-SafeCleanupJobJson $planResult.planPath
        if (-not (Test-CodexHookDirectoryTreeIdentityEqual -Expected $unit.baseline.rootIdentity -Actual $plan.treeManifest.rootIdentity)) { throw 'Plan generation changed.' }
        $planObject=($plan | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100 -DateKind String
        if ((Get-CodexSafeTreeDeleteManifestSha256 $planObject.treeManifest) -cne $unit.baseline.treeManifestSha256) { throw 'Plan tree differs from immutable approved baseline.' }
        $intent=@{scopeSha256=$context.job.scopeSha256;targetPath=$unit.path;originalIdentity=$plan.treeManifest.rootIdentity;planPath=$planResult.planPath;planSha256=$planResult.planSha256;preCallPolicySha256=$preCallHash;actualPlanPolicySha256=$plan.policySha256;createdAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
        Write-SafeCleanupJobJson $intentPath $intent
    }
    # Gate revalidates live policy and filesystem at Apply/Purge. The intent is durable first.
    [void](Assert-SafeCleanupJobPolicy $context)
    $approved=Read-CodexSafeTreeDeleteApprovedPlan -PlanPath $intent.planPath -ApprovedPlanSha256 $intent.planSha256 -PolicyPath $context.job.policyPath -EvidenceRoot $context.job.transactionEvidenceRoot -AllowMissingTarget -AllowExpiredPlan
    Assert-SafeCleanupJobPlanBaseline $context $unit.path $approved.document -RequireIdentity
    Assert-SafeCleanupJobPlanPolicy $context $approved.document.policySha256
    if (-not (Test-CodexHookDirectoryTreeIdentityEqual -Expected $intent.originalIdentity -Actual $approved.document.treeManifest.rootIdentity) -or $intent.actualPlanPolicySha256 -ine $approved.document.policySha256) { throw 'Intent identity/policy differs from approved Plan.' }
    $transactionPath=Join-Path (Split-Path -Parent $intent.planPath) 'transaction.json'
    if (-not (Test-Path -LiteralPath $transactionPath)) {
        $apply=& $GateInvoker @{Mode='Apply';PlanPath=$intent.planPath;ApprovedPlanSha256=$intent.planSha256;ConfirmApply=$true}
        if (-not $apply.quarantined) { throw 'Gate Apply refused.' }
    }
    $transaction=Read-SafeCleanupJobJson $transactionPath
    if ($transaction.status -ne 'purged') {
        $purge=& $GateInvoker @{Mode='Purge';TransactionPath=$transactionPath;ApprovedTransactionSha256=(Get-FileHash -LiteralPath $transactionPath).Hash.ToLowerInvariant();ConfirmPurge=$true}
        if (-not $purge.purged) { throw 'Gate Purge refused.' }
    }
    if ($null -ne $AfterPurge) { & $AfterPurge }
    return Invoke-SafeCleanupJobReconcile $JobPath
    } finally { if ($acquired) { $mutex.ReleaseMutex() };$mutex.Dispose() }
}
