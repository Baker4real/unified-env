Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$guardPath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\CodexRemotePluginCatalogGuard.ps1'
$policyPath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\policy.json'
$pwshPath = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$safeDeleteWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$reportsRoot = Join-Path $projectRoot 'reports'
$fixtureParent = Join-Path $projectRoot ("reports\catalog-guard-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
$fixtureRoot = Join-Path $fixtureParent '.codex'
$catalogRoot = Join-Path $fixtureRoot 'cache\remote_plugin_catalog'
$catalogPath = Join-Path $catalogRoot '1111111111111111.json'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestCatalog {
    return [ordered]@{
        schema_version = 1
        plugins = @(
            [ordered]@{ id = 'keep-1'; name = 'alpha'; nested = [ordered]@{ value = @(1, 2, 3) } }
            [ordered]@{ id = 'plugin_asdk_app_69418aad55e08191aa5e437b649ca2e4'; name = 'heygen'; nested = [ordered]@{ value = 'remove' } }
            [ordered]@{ id = 'keep-2'; name = 'omega'; nested = [ordered]@{ value = @($true, $false, $null) } }
            [ordered]@{ id = 'Plugin_d72b815ecf6481919e3beede9c71ef08'; name = 'hyperframes'; nested = [ordered]@{ value = 42 } }
            [ordered]@{ id = 'plugins~Plugin_efd07789186881918253a50acfc32762'; name = 'remotion'; nested = [ordered]@{ value = 'remove' } }
            [ordered]@{ id = 'plugins~Plugin_60aea7460bd4819199fd97a9553a5e12'; name = 'superpowers'; nested = [ordered]@{ value = 'remove' } }
            [ordered]@{ id = 'keep-3'; name = 'zeta'; nested = [ordered]@{ value = [ordered]@{ exact = 'survive' } } }
        )
    }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $json = ($Value | ConvertTo-Json -Depth 32) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Invoke-GuardSweep {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $guardPath,
        '-Mode', 'Sweep',
        '-PolicyPath', $policyPath,
        '-FixtureRoot', $fixtureRoot,
        '-Json'
    )) {
        [void]$start.ArgumentList.Add($argument)
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_SCAN_INTERVAL_MILLISECONDS'] = '750'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() 'guard fixture sweep 无法启动'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        Assert-True ($process.WaitForExit(30000)) 'guard fixture sweep 超时'
        Assert-True ($process.ExitCode -eq 0) "guard fixture sweep 失败：$stderr$stdout"
        return ($stdout | ConvertFrom-Json -Depth 32)
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Start-GuardWatch {
    param([byte[]]$PostprocessReplacementBytes)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', $guardPath,
        '-Mode', 'Watch',
        '-PolicyPath', $policyPath,
        '-FixtureRoot', $fixtureRoot
    )) {
        [void]$start.ArgumentList.Add($argument)
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'] = '1'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_SCAN_INTERVAL_MILLISECONDS'] = '750'
    $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS'] = '1'
    if ($null -ne $PostprocessReplacementBytes) {
        $start.Environment['CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_POSTPROCESS_BYTES_BASE64'] = [Convert]::ToBase64String($PostprocessReplacementBytes)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True $process.Start() 'guard fixture watcher 无法启动'
    return $process
}

function Get-FixtureSynchronizationName {
    param([ValidateSet('mutex', 'stop')][string]$Kind)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($fixtureRoot.ToLowerInvariant())
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant().Substring(0, 24)
    if ($Kind -ceq 'mutex') { return "CodexRemotePluginCatalogGuardFixture$hash" }
    return "CodexRemotePluginCatalogGuardFixtureStop$hash"
}

function New-CrossSessionCurrentUserOptions {
    $options = [Threading.NamedWaitHandleOptions]::new()
    $options.CurrentUserOnly = $true
    $options.CurrentSessionOnly = $false
    return $options
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutMilliseconds, [string]$Message)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try { if (& $Condition) { return } } catch {}
        Start-Sleep -Milliseconds 100
    }
    throw $Message
}

function Move-FileWithSharingRetry {
    param([string]$SourcePath, [string]$TargetPath, [int]$TimeoutMilliseconds = 5000)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            [IO.File]::Move($SourcePath, $TargetPath, $true)
            return
        } catch {
            $exception = $_.Exception
            while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
            $win32Code = $exception.HResult -band 0xffff
            if ($win32Code -notin @(32, 33) -or $clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Assert-CatalogFiltered {
    param([string]$Path, [string]$Label)
    $after = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 32
    Assert-True (@($after.plugins).Count -eq 3) "$Label 非目标条目数量必须完整保留"
    Assert-True ((@($after.plugins.name) -join ',') -ceq 'alpha,omega,zeta') "$Label 非目标条目顺序必须完整保留"
    $expected = @((New-TestCatalog).plugins | Where-Object name -notin @('heygen', 'hyperframes', 'remotion', 'superpowers'))
    Assert-True (($after.plugins | ConvertTo-Json -Depth 32 -Compress) -ceq ($expected | ConvertTo-Json -Depth 32 -Compress)) "$Label 非目标条目深度内容必须相等"
}

function Wait-CatalogFiltered {
    param([string]$Path, [string]$Label)
    Wait-Until -TimeoutMilliseconds 15000 -Message "$Label 未被 watcher 收敛" -Condition {
        if (-not [IO.File]::Exists($Path)) { return $false }
        try {
            $data = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 32
            return @($data.plugins | Where-Object name -in @('heygen', 'hyperframes', 'remotion', 'superpowers')).Count -eq 0
        } catch { return $false }
    }
    Assert-CatalogFiltered -Path $Path -Label $Label
}

function Stop-GuardWatch {
    param([Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $stopEvent = [Threading.EventWaitHandle]::OpenExisting((Get-FixtureSynchronizationName -Kind stop), (New-CrossSessionCurrentUserOptions))
            try { [void]$stopEvent.Set() } finally { $stopEvent.Dispose() }
            Assert-True ($Process.WaitForExit(10000)) 'guard fixture watcher 未响应 stop event'
        }
        $stdout = $Process.StandardOutput.ReadToEnd()
        $stderr = $Process.StandardError.ReadToEnd()
        Assert-True ($Process.ExitCode -eq 0) "guard fixture watcher 异常退出：$stderr$stdout"
    } finally {
        if (-not $Process.HasExited) { $Process.Kill($true); [void]$Process.WaitForExit(5000) }
        $Process.Dispose()
    }
}

function Remove-FixtureWithManagedDelete {
    if (-not [IO.Directory]::Exists($fixtureParent)) { return }
    $planText = & $safeDeleteWrapper -Mode Plan -TargetPath $fixtureParent -CapabilityRoot $reportsRoot -Json
    $planExit = $LASTEXITCODE
    Assert-True ($planExit -eq 0) "safe delete Plan 失败，exit=$planExit"
    $plan = $planText | ConvertFrom-Json -Depth 16
    $applyText = & $safeDeleteWrapper -Mode Apply -PlanPath $plan.planPath -ApprovedPlanSha256 $plan.planSha256 -ConfirmApply -Json
    $applyExit = $LASTEXITCODE
    Assert-True ($applyExit -eq 0) "safe delete Apply 失败，exit=$applyExit"
    $apply = $applyText | ConvertFrom-Json -Depth 16
    $purgeText = & $safeDeleteWrapper -Mode Purge -TransactionPath $apply.transactionPath -ApprovedTransactionSha256 $apply.transactionSha256 -ConfirmPurge -Json
    $purgeExit = $LASTEXITCODE
    Assert-True ($purgeExit -eq 0) "safe delete Purge 失败，exit=$purgeExit"
    $purge = $purgeText | ConvertFrom-Json -Depth 16
    Assert-True ($purge.purged -eq $true -and -not [IO.Directory]::Exists($fixtureParent)) 'safe delete 未完整清理 fixture'
}

$watchProcess = $null
try {
    Assert-True (Test-Path -LiteralPath $pwshPath -PathType Leaf) '固定 PowerShell 7.6.4 runtime 不存在'
    Assert-True (Test-Path -LiteralPath $safeDeleteWrapper -PathType Leaf) '受管安全树删除入口不存在'
    Assert-True (Test-Path -LiteralPath $guardPath -PathType Leaf) 'catalog guard 公共入口不存在（预期 RED）'
    Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) 'catalog guard policy 不存在（预期 RED）'

    [IO.Directory]::CreateDirectory($catalogRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureRoot '.remote-plugin-catalog-guard-fixture'), "fixture-v1`n", [Text.UTF8Encoding]::new($false))

    # 一次性清理结束后的 catalog 可以是干净的；随后 vendor 完整覆盖会重新引入目标。
    Write-JsonFile -Path $catalogPath -Value ([ordered]@{ schema_version = 1; plugins = @([ordered]@{ id = 'keep-0'; name = 'initial-clean' }) })
    Write-JsonFile -Path $catalogPath -Value (New-TestCatalog)
    $before = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json -Depth 32
    Assert-True (@($before.plugins | Where-Object name -in @('heygen', 'hyperframes', 'remotion', 'superpowers')).Count -eq 4) '刷新前置条件未复现四条目标'

    $result = Invoke-GuardSweep
    Assert-True ($result.ok -eq $true -and $result.removedCount -eq 4) '启动 sweep 必须精确移除四项'
    Assert-CatalogFiltered -Path $catalogPath -Label '启动 sweep'

    $postprocessReplacementBytes = [Text.UTF8Encoding]::new($false).GetBytes((((New-TestCatalog) | ConvertTo-Json -Depth 32) + "`n"))
    $watchProcess = Start-GuardWatch -PostprocessReplacementBytes $postprocessReplacementBytes
    $statePath = Join-Path $fixtureRoot 'state\state.json'
    try {
        Wait-Until -TimeoutMilliseconds 15000 -Message 'watcher 未发布 ready state' -Condition {
            if ($watchProcess.HasExited -or -not [IO.File]::Exists($statePath)) { return $false }
            $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 32
            return $state.status -in @('running', 'retrying')
        }
    } catch {
        if ($watchProcess.HasExited) {
            $watchStdout = $watchProcess.StandardOutput.ReadToEnd()
            $watchStderr = $watchProcess.StandardError.ReadToEnd()
            throw "watcher ready 前退出，exit=$($watchProcess.ExitCode)：$watchStderr$watchStdout"
        }
        throw
    }

    $fixtureMutexName = Get-FixtureSynchronizationName -Kind mutex
    $crossSessionMutex = $null
    try {
        Assert-True ([Threading.Mutex]::TryOpenExisting($fixtureMutexName, (New-CrossSessionCurrentUserOptions), [ref]$crossSessionMutex)) 'watcher mutex 未发布到 current-user-only 跨会话命名空间'
    } finally {
        if ($null -ne $crossSessionMutex) { $crossSessionMutex.Dispose() }
    }
    $sessionOnlyOptions = [Threading.NamedWaitHandleOptions]::new()
    $sessionOnlyOptions.CurrentUserOnly = $true
    $sessionOnlyOptions.CurrentSessionOnly = $true
    $sessionOnlyMutex = $null
    try {
        Assert-True (-not [Threading.Mutex]::TryOpenExisting($fixtureMutexName, $sessionOnlyOptions, [ref]$sessionOnlyMutex)) '跨会话 watcher mutex 被错误发布为 session-local 对象'
    } finally {
        if ($null -ne $sessionOnlyMutex) { $sessionOnlyMutex.Dispose() }
    }

    $logPath = Join-Path $fixtureRoot 'logs\guard.jsonl'
    Wait-Until -TimeoutMilliseconds 10000 -Message 'fingerprint race 未记录 pending retry' -Condition {
        if (-not [IO.File]::Exists($logPath)) { return $false }
        foreach ($line in [IO.File]::ReadAllLines($logPath)) {
            try {
                $record = $line | ConvertFrom-Json -Depth 16
                if ($record.event -ceq 'catalog-blocked' -and $record.code -ceq 'catalog-postprocess-identity-drift') { return $true }
            } catch {}
        }
        return $false
    }
    Wait-CatalogFiltered -Path $catalogPath -Label 'fingerprint race 自动重试'
    Wait-Until -TimeoutMilliseconds 15000 -Message 'fingerprint race 恢复后 watcher state 未收敛' -Condition {
        if (-not [IO.File]::Exists($statePath)) { return $false }
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 32
        return $state.status -ceq 'running' -and $state.lastSweep.pendingRetryCount -eq 0
    }
    $fingerprintRecoveryState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 32
    Assert-True ($fingerprintRecoveryState.status -ceq 'running' -and $fingerprintRecoveryState.lastSweep.pendingRetryCount -eq 0) 'fingerprint race 恢复后仍残留 pending retry'

    $secondWatch = Start-GuardWatch
    try {
        Assert-True (-not $watchProcess.HasExited) '第一 watcher 在单实例验收前已退出'
        Assert-True ($secondWatch.WaitForExit(10000)) '第二个 watcher 未被单实例锁及时拒绝'
        if ($secondWatch.ExitCode -ne 23) {
            $secondStdout = $secondWatch.StandardOutput.ReadToEnd()
            $secondStderr = $secondWatch.StandardError.ReadToEnd()
            throw "第二个 watcher 应以 23 拒绝，actual=$($secondWatch.ExitCode)：$secondStderr$secondStdout"
        }
    } finally {
        if (-not $secondWatch.HasExited) { $secondWatch.Kill($true); [void]$secondWatch.WaitForExit(5000) }
        $secondWatch.Dispose()
    }

    for ($round = 1; $round -le 3; $round++) {
        Write-JsonFile -Path $catalogPath -Value (New-TestCatalog)
        Wait-CatalogFiltered -Path $catalogPath -Label "原地覆盖 round $round"
    }

    for ($round = 1; $round -le 3; $round++) {
        $createdPath = Join-Path $catalogRoot ("{0}.json" -f (($round + 1).ToString() * 16))
        Write-JsonFile -Path $createdPath -Value (New-TestCatalog)
        Wait-CatalogFiltered -Path $createdPath -Label "新 hash round $round"
    }

    for ($round = 1; $round -le 3; $round++) {
        $replacement = Join-Path $catalogRoot (".atomic-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        Write-JsonFile -Path $replacement -Value (New-TestCatalog)
        Move-FileWithSharingRetry -SourcePath $replacement -TargetPath $catalogPath
        Wait-CatalogFiltered -Path $catalogPath -Label "原子替换 round $round"
    }

    $malformedPath = Join-Path $catalogRoot '5555555555555555.json'
    $malformedBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":1,"plugins":[')
    [IO.File]::WriteAllBytes($malformedPath, $malformedBytes)
    Wait-Until -TimeoutMilliseconds 10000 -Message 'malformed catalog 未进入 retrying 状态' -Condition {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 32
        $currentBlocked = @($state.lastSweep.blocked | Where-Object { $_.file -ceq '5555555555555555.json' -and $_.code -ceq 'malformed-json' }).Count -eq 1
        $retryPending = $state.lastSweep.pendingRetryCount -ge 1
        return $state.status -ceq 'retrying' -and ($currentBlocked -or $retryPending)
    }
    Start-Sleep -Milliseconds 1800
    Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($malformedPath)) -ceq [Convert]::ToHexString($malformedBytes)) 'malformed retry 期间原文件字节被覆盖'
    Write-JsonFile -Path $malformedPath -Value (New-TestCatalog)
    Wait-CatalogFiltered -Path $malformedPath -Label 'malformed 恢复后重试'

    Start-Sleep -Milliseconds 1200
    $idleBefore = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 32
    Start-Sleep -Milliseconds 2500
    $idleAfter = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 32
    Assert-True ($idleAfter.metrics.metadataProbeCount -gt $idleBefore.metrics.metadataProbeCount) '周期补扫必须继续执行轻量元数据探测'
    Assert-True ($idleAfter.metrics.contentReadCount -eq $idleBefore.metrics.contentReadCount) '未变化 catalog 不得被周期补扫反复读取完整内容'

    Stop-GuardWatch -Process $watchProcess
    $watchProcess = $null
    Write-Output 'PASS Test-CodexRemotePluginCatalogGuard sweep=1 inplace=3 create=3 atomic=3 malformedRetry=1 fingerprintRetry=1 unchangedRead=0 singleInstance=1 crossSessionNamespace=1'
} finally {
    if ($null -ne $watchProcess) {
        try { Stop-GuardWatch -Process $watchProcess } catch {}
    }
    Remove-FixtureWithManagedDelete
}
