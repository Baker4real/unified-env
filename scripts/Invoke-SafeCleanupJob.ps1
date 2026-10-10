[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Status','Reconcile','Verify','PolicyProof','Run','Worker')][string]$Mode,
    [Parameter(Mandatory)][string]$JobPath,
    [switch]$ConfirmRun,
    [string]$OwnerTokenHash,
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell Core 7 required.' }
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'lib/SafeCleanupJob.ps1')
$context=Read-SafeCleanupJob $JobPath
if ($Mode -in @('Run','Worker')) {
    if (-not (Test-SafeCleanupJobPathEqual $context.job.transactionEvidenceRoot 'D:/agents/run-evidence/safe-tree-delete') -or -not (Test-SafeCleanupJobPathEqual $context.job.policyPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'managed/safe-tree-delete/policy.json'))) { throw 'Execution accepts production managed gate configuration only.' }
    if ($context.job.Contains('readOnly') -and $context.job.readOnly) { throw 'Historical descriptor is read-only.' }
    foreach ($unit in $context.scope.units) {
        if (-not $unit.baseline.Contains('rootIdentity') -or -not $unit.baseline.Contains('treeManifestSha256')) { throw 'Execution requires original immutable identity baseline.' }
    }
}
if ($Mode -eq 'Reconcile' -and $context.job.Contains('readOnly') -and $context.job.readOnly) { throw 'Historical descriptor is read-only.' }
if ($Mode -eq 'PolicyProof' -and [string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath=Join-Path (Split-Path -Parent $JobPath) 'policy-proof.json' }
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    [void](Assert-CodexHookCapabilityPath -Path $OutputPath -CapabilityRoot (Split-Path -Parent $JobPath) -Name 'cleanup output')
    $protected=@($JobPath,$context.job.scopePath,$context.job.ledgerPath,$context.job.statePath,$context.job.policyPath,$context.job.policySnapshotPath)
    if ($context.job.Contains('launchPath')) { $protected+=@($context.job.launchPath) }
    if ($context.job.Contains('policySnapshots')) { $protected+=@($context.job.policySnapshots | ForEach-Object path) }
    foreach ($path in $protected) { if (Test-SafeCleanupJobPathEqual $path $OutputPath) { throw 'Output cannot overwrite job input/state.' } }
    if (Test-CodexHookPathWithin -Path $OutputPath -ParentPath $context.job.intentRoot) { throw 'Output cannot overwrite intents.' }
    if (Test-CodexHookPathWithin -Path $OutputPath -ParentPath $context.job.transactionEvidenceRoot) { throw 'Output cannot overwrite transaction evidence.' }
}
$result=switch ($Mode) {
    'Status' { Get-SafeCleanupJobStatus $JobPath }
    'Reconcile' { Invoke-SafeCleanupJobReconcile $JobPath }
    'Verify' { Test-SafeCleanupJobVerification $JobPath }
    'PolicyProof' {
        $comparison=Assert-SafeCleanupJobPolicy $context
        $comparison.scopeSha256=$context.job.scopeSha256
        $comparison
    }
    'Run' {
        if (-not $ConfirmRun) { throw 'Run requires ConfirmRun and existing approved immutable scope.' }
        $owner=[guid]::NewGuid().ToString('N')
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.StandardOutputEncoding=[Text.Encoding]::UTF8;$start.StandardErrorEncoding=[Text.Encoding]::UTF8
        foreach ($arg in @('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Mode','Worker','-JobPath',$JobPath,'-OwnerTokenHash',$owner)) { $start.ArgumentList.Add($arg) }
        $child=[Diagnostics.Process]::Start($start)
        $childStart=$child.StartTime.ToUniversalTime().ToString('o')
        try {
            $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
            $child.WaitForExit()
            $errorText=$stderr.GetAwaiter().GetResult();$output=$stdout.GetAwaiter().GetResult()
            $mutex=New-SafeCleanupJobMutex $JobPath;$acquired=$false
            try {
                try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
                if ($acquired -and (Test-Path -LiteralPath $context.job.statePath)) {
                    $state=Read-SafeCleanupJobJson $context.job.statePath
                    if ($state.pid -eq $child.Id -and $state.ownerTokenHash -ceq $owner -and $state.processStartUtc -ceq $childStart) {
                        $state.exitCode=$child.ExitCode;$state.stderr=$errorText;$state.stdout=$output;$state.observedExitUtc=[datetimeoffset]::UtcNow.ToString('o')
                        if ($child.ExitCode -ne 0) { $state.processState='failed';$state.error="Worker exit $($child.ExitCode): $errorText" }
                        Write-SafeCleanupJobJson $context.job.statePath $state
                    }
                }
            } finally { if ($acquired) { $mutex.ReleaseMutex() };$mutex.Dispose() }
            if ($child.ExitCode -ne 0) { throw "Worker exit $($child.ExitCode): $errorText" }
            Get-SafeCleanupJobStatus $JobPath
        } finally { $child.Dispose() }
    }
    'Worker' {
        if ($OwnerTokenHash -notmatch '^[0-9a-f]{32}$') { throw 'Worker owner identity required.' }
        $mutex=New-SafeCleanupJobMutex $JobPath
        $acquired=$false
        try {
            try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
            if (-not $acquired) { throw 'Another worker owns this cleanup job.' }
            $self=Get-Process -Id $PID
            $state=@{processState='running';pid=$PID;processStartUtc=$self.StartTime.ToUniversalTime().ToString('o');executable=$self.Path;ownerTokenHash=$OwnerTokenHash;updatedAtUtc=[datetimeoffset]::UtcNow.ToString('o');error=''}
            Write-SafeCleanupJobJson $context.job.statePath $state
            [void](Invoke-SafeCleanupJobReconcile $JobPath)
            foreach ($unit in (Read-SafeCleanupJob $JobPath).ledger.units) {
                if ($unit.status -ne 'pending') { continue }
                [void](Invoke-SafeCleanupJobUnit $JobPath $unit.path)
                $state.updatedAtUtc=[datetimeoffset]::UtcNow.ToString('o')
                $state.lastTarget=$unit.path
                Write-SafeCleanupJobJson $context.job.statePath $state
            }
            $health=Get-SafeCleanupJobHealth $state (Read-SafeCleanupJob $JobPath).ledger $null
            if ($health.pendingCount -gt 0 -or $health.failedCount -gt 0 -or $health.manualReviewCount -gt 0) { throw 'Job has unresolved units.' }
            if (-not (Test-SafeCleanupJobVerification $JobPath).verified) { throw 'Final receipt/generation verification failed.' }
            $state.processState='completed';Write-SafeCleanupJobJson $context.job.statePath $state
            @{completed=$true}
        } catch {
            if ($acquired -and $null -ne (Get-Variable state -ErrorAction SilentlyContinue)) { $state.processState='failed';$state.error=$_.Exception.Message;Write-SafeCleanupJobJson $context.job.statePath $state }
            throw
        } finally { if ($acquired) { $mutex.ReleaseMutex() };$mutex.Dispose() }
    }
}
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    [void](Assert-CodexHookCapabilityPath -Path $OutputPath -CapabilityRoot (Split-Path -Parent $JobPath) -Name 'cleanup output')
    Write-SafeCleanupJobJson $OutputPath $result
    @{outputPath=$OutputPath;mode=$Mode} | ConvertTo-Json -Compress
} else { $result | ConvertTo-Json -Depth 100 -Compress }
if ($Mode -eq 'Run' -and $result.taskFailure) { exit 1 }
if ($Mode -eq 'Verify' -and -not $result.verified) { exit 1 }
