[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\CodexHookProductionFixtureTestSupport.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$fixtureRoot = 'D:\agents\projects\统一环境\reports\codex-hook-deployment-test\production-registration-repair'
$mutexName = Get-CodexHookProductionFixtureLifecycleMutexName
$readyName = "Local\CodexHookProductionFixtureReady-$([guid]::NewGuid().ToString('N'))"
$ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $readyName)
$holderPidPath = Join-Path $fixtureRoot 'holder.pid'
$holderScript = @"
`$ErrorActionPreference = 'Stop'
`$mutex = [Threading.Mutex]::new(`$false, '$mutexName')
`$readyEvent = [Threading.EventWaitHandle]::OpenExisting('$readyName')
try {
    if (-not `$mutex.WaitOne(10000)) { throw 'holder fixture lifecycle mutex timeout' }
    if ([IO.Directory]::Exists('$fixtureRoot')) {
        Remove-Item -LiteralPath '$fixtureRoot' -Recurse -Force
    }
    [void][IO.Directory]::CreateDirectory('$fixtureRoot')
    [IO.File]::WriteAllText((Join-Path '$fixtureRoot' 'sentinel.txt'), 'preserve', [Text.UTF8Encoding]::new(`$false))
    [IO.File]::WriteAllText('$holderPidPath', [string]`$PID, [Text.UTF8Encoding]::new(`$false))
    [void]`$readyEvent.Set()
    Start-Sleep -Seconds 30
} finally {
    `$readyEvent.Dispose()
    try { [void]`$mutex.ReleaseMutex() } catch {}
    `$mutex.Dispose()
}
"@
$encodedHolderScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holderScript))
$holder = $null
$holderStarted = $false
$holderPid = $null
$contender = $null
$contenderBlocked = $false
$sentinelPreserved = $false
$primaryError = $null
try {
    $holderStart = [Diagnostics.ProcessStartInfo]::new()
    $holderStart.FileName = (Get-Process -Id $PID).Path
    $holderStart.UseShellExecute = $false
    $holderStart.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedHolderScript)) {
        [void]$holderStart.ArgumentList.Add($argument)
    }
    $holder = [Diagnostics.Process]::new()
    $holder.StartInfo = $holderStart
    $holderStarted = $holder.Start()
    Assert-True $holderStarted 'holder 无法以无窗口模式启动'
    Assert-True ($ready.WaitOne([TimeSpan]::FromSeconds(10))) 'holder 未进入 fixture lifecycle critical section'
    $holderPid = [int](Get-Content -LiteralPath $holderPidPath -Raw)
    Assert-True ($holderPid -eq $holder.Id -and $holderPid -ne $PID -and $null -ne (Get-Process -Id $holderPid -ErrorAction Stop)) 'holder 必须运行在独立无窗口进程'
    # Keep this non-owning handle open through holder termination so the kernel
    # object survives long enough for the helper to observe abandonment.
    $contender = [Threading.Mutex]::new($false, $mutexName)
    $contenderAcquired = $false
    try {
        $contenderAcquired = $contender.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $contenderAcquired = $true
    }
    if ($contenderAcquired) { [void]$contender.ReleaseMutex() }
    $contenderBlocked = -not $contenderAcquired
    $sentinelPreserved = [IO.File]::Exists((Join-Path $fixtureRoot 'sentinel.txt'))
    Assert-True $contenderBlocked '第二进程在 holder 持锁时不得进入 fixture cleanup critical section'
    Assert-True $sentinelPreserved '被阻塞 contender 不得清理 fixture sentinel'
} catch {
    $primaryError = $_
} finally {
    if ($holderStarted -and $null -ne (Get-Process -Id $holder.Id -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $holder.Id -Force
        Wait-Process -Id $holder.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
    if ($null -ne $holder) { $holder.Dispose() }
    $ready.Dispose()
}

$abandonedLease = $null
$abandonedRecovered = $false
$recoveryError = $null
try {
    $abandonedLease = Enter-CodexHookProductionFixtureLifecycle -TimeoutMilliseconds 10000
    $abandonedRecovered = $abandonedLease.abandoned
    if ($null -eq $primaryError) {
        Assert-True $abandonedRecovered 'helper 必须显式识别并接管 abandoned fixture mutex'
    }
    if ([IO.Directory]::Exists($fixtureRoot)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
} catch {
    $recoveryError = $_
} finally {
    try {
        if ($null -ne $abandonedLease) {
            Exit-CodexHookProductionFixtureLifecycle -Lease $abandonedLease
        }
    } finally {
        if ($null -ne $contender) { $contender.Dispose() }
    }
}
if ($null -ne $primaryError) { throw $primaryError }
if ($null -ne $recoveryError) { throw $recoveryError }

[pscustomobject][ordered]@{
    ok = $true
    test = 'CodexHookProductionFixtureConcurrency'
    independentHolderProcess = $true
    contenderBlocked = $contenderBlocked
    sentinelPreserved = $sentinelPreserved
    abandonedRecovered = $abandonedRecovered
}
