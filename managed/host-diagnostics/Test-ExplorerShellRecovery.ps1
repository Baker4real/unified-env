#requires -Version 7.5
<#
.SYNOPSIS
验证 Explorer 恢复工具；仅创建和回收带所有权握手的隐藏测试子进程。
.DESCRIPTION
不停止真实 Explorer。-Worker 是测试器内部的固定子进程入口，不接受可执行文件参数。
-SkipLiveSnapshot 仅省略真实 Explorer 的前后只读快照，明确记录 skipped；隔离恢复用例照常执行。
#>
[CmdletBinding()]
param(
    [ValidateSet('All','IdentityDrift','CapturedPath','StartFailure','ReadinessTimeout','PreflightGuards','ConcurrentApply','Snapshot')][string]$Case = 'All',
    [string]$EvidenceDirectory = 'D:/agents/run-evidence/explorer-shell-recovery-tests',
    [switch]$SkipLiveSnapshot,
    [switch]$Worker
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($Worker) {
    $token = [Environment]::GetEnvironmentVariable('CODEX_EXPLORER_TEST_TOKEN')
    $reportPath = [Environment]::GetEnvironmentVariable('CODEX_EXPLORER_TEST_REPORT')
    $stopPath = [Environment]::GetEnvironmentVariable('CODEX_EXPLORER_TEST_STOP')
    if (-not $token -or -not $reportPath -or -not $stopPath) { exit 70 }
    $tokenHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($token)))
    [Environment]::SetEnvironmentVariable('CODEX_EXPLORER_TEST_TOKEN', $null)
    $token = $null
    $self = Get-Process -Id $PID
    $parentId = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID").ParentProcessId
    $report = [ordered]@{
        OwnerTokenSha256 = $tokenHash
        ParentId = [int]$parentId
        Id = $self.Id
        StartTimeTicks = $self.StartTime.ToUniversalTime().Ticks.ToString()
        ExePath = [string]$self.Path
        Ready = $true
    }
    $report | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding utf8
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 90) {
        if (Test-Path -LiteralPath $stopPath) {
            if ((Get-Content -LiteralPath $stopPath -Raw).Trim() -ceq $tokenHash) { exit 0 }
        }
        Start-Sleep -Milliseconds 50
    }
    exit 71
}

$runRoot = Join-Path $EvidenceDirectory ('test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$results = [Collections.Generic.List[object]]::new()
$sessionPath = Join-Path $runRoot 'session.json'
$previousToken = [Environment]::GetEnvironmentVariable('CODEX_EXPLORER_TEST_TOKEN')
$realBefore = $null
$realAfter = $null
try {
    . "$PSScriptRoot/lib/ExplorerShellRecovery.ps1"
    if (-not $SkipLiveSnapshot) {
        $realBefore = & "$PSScriptRoot/Get-TaskbarSnapshot.ps1" -OutputPath (Join-Path $runRoot 'real-before.json') -AsObject
    }
    if ($Case -ne 'Snapshot') { Initialize-ExplorerRecoveryTestSession -SessionPath $sessionPath }
    $planPath = Join-Path $runRoot 'plan.json'
    if ($Case -in @('All','IdentityDrift')) {
        $plan = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Plan -PlanPath $planPath -TestSessionPath $sessionPath -AsObject
        $plannedIdentity = $plan.Snapshot.ShellProcess
        $plan.Snapshot.ShellProcess.StartTimeTicks = '1'
        $plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $planPath -Encoding utf8
        $result = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Apply -PlanPath $planPath -TestSessionPath $sessionPath -EvidenceDirectory (Join-Path $runRoot 'identity') -AsObject
        $current = & "$PSScriptRoot/Get-TaskbarSnapshot.ps1" -TestSessionPath $sessionPath -AsObject
        if ($result.Status -ne 'refused' -or $result.Reason -ne 'IdentityChanged' -or $result.StopAttempted -or $current.ShellProcess.Id -ne $plannedIdentity.Id) {
            throw 'IdentityDrift: a stale process identity must be refused without stopping the owned process.'
        }
        $results.Add([ordered]@{ Case = 'IdentityDrift'; Status = 'passed'; Result = $result.Status; Reason = $result.Reason })
    }
    if ($Case -in @('All','CapturedPath')) {
        $plan = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Plan -PlanPath $planPath -TestSessionPath $sessionPath -AsObject
        $original = Get-Process -Id $plan.Snapshot.ShellProcess.Id
        try {
            [void]$original.Handle
            $result = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Apply -PlanPath $planPath -TestSessionPath $sessionPath -EvidenceDirectory (Join-Path $runRoot 'captured-path') -AsObject
            if ($result.Status -ne 'ready' -or -not $original.HasExited -or $result.LaunchAttempts.Count -ne 1 -or
                $result.LaunchAttempts[0].ExePath -ine $plan.Snapshot.ShellProcess.ExePath -or $result.NewIdentity.Id -eq $plan.Snapshot.ShellProcess.Id) {
                throw 'CapturedPath: restart must succeed from the captured executable after the original process has exited.'
            }
            $results.Add([ordered]@{ Case = 'CapturedPath'; Status = 'passed'; OldProcessExited = $original.HasExited; Result = $result.Status })
        }
        finally { $original.Dispose() }
    }
    if ($Case -in @('All','StartFailure')) {
        $session = Read-ExplorerRecoveryJson -Path $sessionPath
        $session.FailStartsRemaining = 1
        Write-ExplorerRecoveryJson -Path $sessionPath -Value $session
        $plan = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -PlanPath $planPath -TestSessionPath $sessionPath -ReadinessTimeoutSeconds 5 -AsObject
        $result = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Apply -PlanPath $planPath -TestSessionPath $sessionPath -EvidenceDirectory (Join-Path $runRoot 'start-failure') -AsObject
        if ($result.Status -ne 'ready' -or $result.LaunchAttempts.Count -ne 2 -or $result.LaunchAttempts[0].State -ne 'creation_failed' -or
            $result.LaunchAttempts[1].State -ne 'created' -or $result.RecoveryMethod -ne 'retry-launch') {
            throw 'StartFailure: one failed creation must allow one bounded recovery attempt from the saved executable.'
        }
        $results.Add([ordered]@{ Case = 'StartFailure'; Status = 'passed'; Result = $result.Status; Attempts = $result.LaunchAttempts.Count })
    }
    if ($Case -in @('All','ReadinessTimeout')) {
        $session = Read-ExplorerRecoveryJson -Path $sessionPath
        $session | Add-Member -NotePropertyName DesktopResponding -NotePropertyValue $false -Force
        Write-ExplorerRecoveryJson -Path $sessionPath -Value $session
        $plan = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -PlanPath $planPath -TestSessionPath $sessionPath -ReadinessTimeoutSeconds 5 -AsObject
        $result = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Apply -PlanPath $planPath -TestSessionPath $sessionPath -EvidenceDirectory (Join-Path $runRoot 'readiness-timeout') -AsObject
        if ($result.Status -ne 'failed' -or $result.Reason -ne 'ReadinessTimeout' -or $result.DesktopAndTaskbarReady -or $result.ProcessState -eq 'running_handed_off') {
            throw 'ReadinessTimeout: a responsive taskbar alone must never be reported as recovered when the desktop does not respond.'
        }
        $results.Add([ordered]@{ Case = 'ReadinessTimeout'; Status = 'passed'; Result = $result.Status; Reason = $result.Reason; ElapsedSeconds = $result.ElapsedSeconds })
    }
    if ($Case -in @('All','PreflightGuards')) {
        foreach ($guard in @('PlanExpired','InvalidRecoveryBudget','UserSessionChanged','FolderWindow','FileOperation','PinsChanged')) {
            $session = Read-ExplorerRecoveryJson -Path $sessionPath
            $session.FolderWindows = 0; $session.VisibleFileOperations = 0; $session.DesktopResponding = $true
            Write-ExplorerRecoveryJson -Path $sessionPath -Value $session
            $plan = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -PlanPath $planPath -TestSessionPath $sessionPath -AsObject
            $expectedReason = $guard
            switch ($guard) {
                'PlanExpired' { $plan.CreatedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o') }
                'InvalidRecoveryBudget' { $plan.RecoveryBudget.ReadinessTimeoutSeconds = 2 }
                'UserSessionChanged' { $plan.Snapshot.Context.SessionId++ }
                'FolderWindow' { $session.FolderWindows = 1; $expectedReason = 'UnsafeWindowsPresent' }
                'FileOperation' { $session.VisibleFileOperations = 1; $expectedReason = 'UnsafeWindowsPresent' }
                'PinsChanged' { $plan.Snapshot.Pins.Sha256 = ('B' * 64) }
            }
            Write-ExplorerRecoveryJson -Path $planPath -Value $plan
            Write-ExplorerRecoveryJson -Path $sessionPath -Value $session
            $result = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Apply -PlanPath $planPath -TestSessionPath $sessionPath -EvidenceDirectory (Join-Path $runRoot $guard) -AsObject
            $stillRunning = & "$PSScriptRoot/Get-TaskbarSnapshot.ps1" -TestSessionPath $sessionPath -AsObject
            if ($result.Status -ne 'refused' -or $result.Reason -ne $expectedReason -or $result.StopAttempted -or $stillRunning.ShellProcess.Id -ne $plan.Snapshot.ShellProcess.Id) {
                throw "$guard`: preflight must refuse without stopping the owned process."
            }
            $results.Add([ordered]@{ Case = $guard; Status = 'passed'; Reason = $result.Reason; StopAttempted = $result.StopAttempted })
        }
    }
    if ($Case -in @('All','ConcurrentApply')) {
        $plan = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -PlanPath $planPath -TestSessionPath $sessionPath -AsObject
        if (-not ('ExplorerRecoveryTests.LockOwner' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace ExplorerRecoveryTests {
    public sealed class LockOwner : IDisposable {
        private readonly ManualResetEventSlim acquired = new ManualResetEventSlim();
        private readonly ManualResetEventSlim release = new ManualResetEventSlim();
        private readonly Thread thread;
        public LockOwner(string name) {
            thread = new Thread(() => {
                using (var mutex = new Mutex(false, name)) {
                    if (!mutex.WaitOne(2000)) return;
                    try { acquired.Set(); release.Wait(10000); }
                    finally { mutex.ReleaseMutex(); }
                }
            });
            thread.IsBackground = true;
            thread.Start();
            if (!acquired.Wait(3000)) { release.Set(); throw new InvalidOperationException("TestLockTimeout"); }
        }
        public void Dispose() {
            release.Set();
            if (!thread.Join(3000)) throw new InvalidOperationException("TestLockReleaseTimeout");
            acquired.Dispose(); release.Dispose();
        }
    }
}
'@
        }
        $holder = [ExplorerRecoveryTests.LockOwner]::new($plan.ConcurrencyLockName)
        try {
            $result = & "$PSScriptRoot/Restart-ExplorerShell.ps1" -Mode Apply -PlanPath $planPath -TestSessionPath $sessionPath -EvidenceDirectory (Join-Path $runRoot 'concurrent-apply') -AsObject
            $current = & "$PSScriptRoot/Get-TaskbarSnapshot.ps1" -TestSessionPath $sessionPath -AsObject
            if ($result.Status -ne 'refused' -or $result.Reason -ne 'ExplorerRecoveryAlreadyInProgress' -or $result.StopAttempted -or
                $current.ShellProcess.Id -ne $plan.Snapshot.ShellProcess.Id -or $result.LaunchAttempts.Count -ne 0) {
                throw 'ConcurrentApply: a competing Apply must be refused without stopping or launching any process.'
            }
            $results.Add([ordered]@{ Case = 'ConcurrentApply'; Status = 'passed'; Reason = $result.Reason; StopAttempted = $false })
        }
        finally { $holder.Dispose() }
    }
}
catch {
    $results.Add([ordered]@{ Case = $Case; Status = 'failed'; Error = $_.Exception.Message })
}
finally {
    if (Get-Command Close-ExplorerRecoveryTestSession -ErrorAction SilentlyContinue) {
        try { Close-ExplorerRecoveryTestSession -SessionPath $sessionPath }
        catch { $results.Add([ordered]@{ Case = 'OwnedProcessCleanup'; Status = 'failed'; Error = $_.Exception.Message }) }
    }
    [Environment]::SetEnvironmentVariable('CODEX_EXPLORER_TEST_TOKEN', $previousToken)
    if ($SkipLiveSnapshot) {
        $results.Add([ordered]@{ Case = 'RealReadOnlySnapshot'; Status = 'skipped'; Reason = 'SkipLiveSnapshot' })
    }
    else { try {
        $realAfter = & "$PSScriptRoot/Get-TaskbarSnapshot.ps1" -OutputPath (Join-Path $runRoot 'real-after.json') -AsObject
        if (-not $realBefore.Complete -or -not $realAfter.Complete -or -not $realAfter.DesktopAndTaskbarReady -or
            -not (Test-ExplorerRecoveryIdentity -Expected $realBefore.ShellProcess -Actual $realAfter.ShellProcess) -or $realBefore.Pins.Sha256 -cne $realAfter.Pins.Sha256) {
            throw 'RealSnapshot: real shell must remain unchanged, responsive and fully observed throughout the tests.'
        }
        $results.Add([ordered]@{ Case = 'RealReadOnlySnapshot'; Status = 'passed'; SameShellIdentity = $true; PinsUnchanged = $true; DesktopAndTaskbarReady = $true })
    }
    catch { $results.Add([ordered]@{ Case = 'RealReadOnlySnapshot'; Status = 'failed'; Error = $_.Exception.Message }) } }
}
$childSummary = @()
if (Test-Path -LiteralPath $sessionPath) {
    $closedSession = Read-ExplorerRecoveryJson -Path $sessionPath
    $childSummary = @($closedSession.Children | ForEach-Object { [ordered]@{ Identity = $_.Identity; OwnerTokenSha256 = $closedSession.OwnerTokenSha256; ProcessState = $_.ProcessState; ExitCode = $_.ExitCode } })
}
$summary = [ordered]@{
    SchemaVersion = 1
    ObservedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Status = $(if (@($results | Where-Object Status -eq 'failed').Count) { 'failed' } elseif ($SkipLiveSnapshot) { 'passed-with-skips' } else { 'passed' })
    PassedChecks = @($results | Where-Object Status -eq 'passed').Count
    SkippedChecks = @($results | Where-Object Status -eq 'skipped').Count
    RealExplorerStopped = $false
    Children = $childSummary
    Results = @($results)
    EvidenceDirectory = $runRoot
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'test-results.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 8
if ($summary.Status -notin @('passed','passed-with-skips')) { exit 1 }
