[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$hooksRoot = Join-Path $projectRoot 'managed\codex-hooks\hooks'
$reminderPath = Join-Path $hooksRoot 'serena-reminder-guarded.cmd'
$cleanupPath = Join-Path $hooksRoot 'serena-cleanup-guarded.cmd'
$activationPath = Join-Path $hooksRoot 'serena-activation-reminder.cmd'
$behaviorGuardPath = Join-Path $hooksRoot 'serena-behavior-guard.ps1'
. (Join-Path $projectRoot 'scripts\lib\CodexHookPolicy.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message actual=[$Actual] expected=[$Expected]" }
}

function Assert-Throws([scriptblock]$Action, [string]$ExpectedFragment) {
    try { & $Action; throw 'expected exception was not thrown' }
    catch {
        if (-not $_.Exception.Message.Contains($ExpectedFragment, [StringComparison]::OrdinalIgnoreCase)) { throw }
    }
}

function Invoke-ChildProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText,
        [hashtable]$Environment = @{}
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) { $startInfo.Environment[$name] = [string]$Environment[$name] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "子进程无法启动：$FilePath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(10000)) "子进程超时：$FilePath"
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

function Start-NoWindowProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$Environment = @{}
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) { $startInfo.Environment[$name] = [string]$Environment[$name] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    Assert-True $process.Start() "子进程无法启动：$FilePath"
    return $process
}

function New-ReminderPayload([string]$SessionId, [string]$ToolName) {
    [pscustomobject][ordered]@{
        session_id = $SessionId
        tool_name = $ToolName
        tool_input = [pscustomobject][ordered]@{ command = 'rg -n hook file.ps1' }
    } | ConvertTo-Json -Compress -Depth 5
}

Assert-True (Test-Path -LiteralPath $reminderPath -PathType Leaf) '缺少 Serena reminder 受控 wrapper。'
Assert-True (Test-Path -LiteralPath $cleanupPath -PathType Leaf) '缺少 Serena cleanup 受控 wrapper。'
Assert-True (Test-Path -LiteralPath $activationPath -PathType Leaf) '缺少 Serena activation reminder 静态 wrapper。'
Assert-True (Test-Path -LiteralPath $behaviorGuardPath -PathType Leaf) '缺少 Serena behavior 共享安全 guard。'

$combinedSource = (Get-Content -LiteralPath @($reminderPath, $cleanupPath, $activationPath) -Raw) -join "`n"
Assert-True (-not $combinedSource.Contains('auto-approve')) '行为 hook 不得恢复 Serena auto-approve。'

$reminderSource = Get-Content -LiteralPath $reminderPath -Raw
$cleanupSource = Get-Content -LiteralPath $cleanupPath -Raw
$activationSource = Get-Content -LiteralPath $activationPath -Raw
$behaviorGuardSource = Get-Content -LiteralPath $behaviorGuardPath -Raw
foreach ($source in @($reminderSource, $cleanupSource, $activationSource)) {
    Assert-True $source.Contains('set "SERENA_HOME=D:\Codex\.serena"') 'wrapper 必须覆盖外部 SERENA_HOME。'
    Assert-True ($source.Contains('D:\Codex\tools\python314-official\pythonw.exe') -and $source.Contains('lib\hidden-console-launcher.py')) 'wrapper 必须通过 hidden launcher 启动。'
    Assert-True (-not $source.Contains('%*')) 'wrapper 不得接受外部参数覆盖固定命令。'
}
Assert-True $reminderSource.Contains('"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Reminder') 'reminder 必须固定 sibling 受控 guard 和 Mode。'
Assert-True $cleanupSource.Contains('"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Cleanup') 'cleanup 必须固定 sibling 受控 guard 和 Mode。'
Assert-True $activationSource.Contains('"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Activation') 'activation reminder 必须固定 sibling 受控 guard 和 Mode。'
Assert-True $behaviorGuardSource.Contains("'D:\Codex\tools\uv\bin\serena-hooks.exe'") 'behavior guard 必须固定官方 vendor。'
Assert-True $behaviorGuardSource.Contains("'--client=codex'") 'behavior guard 必须固定 Codex client。'
Assert-True $behaviorGuardSource.Contains('Complete-CodexHookProcessWithBoundedDrain') 'behavior guard 必须复用 bounded native drain。'
Assert-True $behaviorGuardSource.Contains('Write-CodexHookLatestHealthCore') 'behavior guard 必须复用 strict health writer。'
Assert-True (-not $behaviorGuardSource.Contains('VendorPath =')) 'production CLI 不得暴露 vendor path override。'
Assert-True $behaviorGuardSource.Contains('Get-CodexSerenaSessionMutexName') 'behavior guard 必须为每个 Serena session 建立稳定互斥名。'
Assert-True $behaviorGuardSource.Contains('Invoke-CodexSerenaSessionMutex') 'behavior guard 必须通过 session 级互斥串行化状态访问。'

$scratchBase = [IO.Path]::GetFullPath((Join-Path $projectRoot '.scratch'))
$fixtureRoot = Join-Path $scratchBase ("codex-serena-behavior-hooks-{0}" -f [guid]::NewGuid().ToString('N'))
$fixtureHome = Join-Path $fixtureRoot '.serena'
$vendorPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
Assert-True ($fixtureRoot.StartsWith($scratchBase + '\', [StringComparison]::OrdinalIgnoreCase)) 'Serena fixture 必须严格位于项目 .scratch。'
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
try {
    function Invoke-SerenaVendor([string]$Command, [string]$InputJson) {
        Invoke-ChildProcess -FilePath $vendorPath -Arguments @($Command, '--client=codex') -InputText $InputJson -Environment @{ SERENA_HOME = $fixtureHome }
    }

    # 格式等价的脱敏 UUID；fixture 只证明当前观察到的 Codex payload schema。
    $codexSession = '11111111-2222-4333-8444-555555555555'
    $codexSessionResult = Invoke-SerenaVendor 'remind' (New-ReminderPayload $codexSession 'Bash')
    Assert-True ($codexSessionResult.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($codexSessionResult.stdout)) '真实 Codex UUID session grammar 必须可用。'

    $claudeAccept = Invoke-SerenaVendor 'auto-approve' '{"session_id":"claude-redacted","permission_mode":"acceptEdits","tool_name":"mcp__serena__get_symbols_overview"}'
    $claudeAuto = Invoke-SerenaVendor 'auto-approve' '{"session_id":"claude-redacted","permission_mode":"auto","tool_name":"mcp__serena__get_symbols_overview"}'
    $codexAutoApprove = Invoke-SerenaVendor 'auto-approve' (New-ReminderPayload $codexSession 'mcp__serena__get_symbols_overview')
    Assert-Equal (($claudeAccept.stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision) 'allow' 'Claude acceptEdits 对照必须返回 allow。'
    Assert-Equal (($claudeAuto.stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision) 'allow' 'Claude auto 对照必须返回 allow。'
    Assert-True ($codexAutoApprove.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($codexAutoApprove.stdout)) '无 permission_mode 的脱敏负向 payload 不得被 vendor auto-approve 误判为 allow。'

    $sessionA = 'session-a-redacted'
    $sessionB = 'session-b-redacted'
    $bashA = New-ReminderPayload $sessionA 'Bash'
    $bashB = New-ReminderPayload $sessionB 'Bash'

    foreach ($attempt in 1..2) {
        $result = Invoke-SerenaVendor 'remind' $bashA
        Assert-Equal $result.exitCode 0 "session A 第 $attempt 次 Bash 必须成功。"
        Assert-True ([string]::IsNullOrWhiteSpace($result.stdout)) "session A 第 $attempt 次 Bash 必须静默。"
    }
    $sessionBFirst = Invoke-SerenaVendor 'remind' $bashB
    Assert-True ($sessionBFirst.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($sessionBFirst.stdout)) '不同 session 的首次 Bash 必须独立静默。'

    $sessionAThird = Invoke-SerenaVendor 'remind' $bashA
    Assert-Equal $sessionAThird.exitCode 0 'session A 第三次 Bash 必须成功返回协议。'
    $deny = $sessionAThird.stdout | ConvertFrom-Json
    Assert-Equal $deny.hookSpecificOutput.hookEventName 'PreToolUse' 'reminder 必须输出 PreToolUse 协议。'
    Assert-Equal $deny.hookSpecificOutput.permissionDecision 'deny' '第三次连续 Bash 必须触发 reminder deny。'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$deny.hookSpecificOutput.permissionDecisionReason)) 'reminder deny 必须包含可操作说明。'

    $sessionBSecond = Invoke-SerenaVendor 'remind' $bashB
    Assert-True ($sessionBSecond.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($sessionBSecond.stdout)) 'session A 达阈值不得污染 session B 计数。'

    $serenaReset = Invoke-SerenaVendor 'remind' (New-ReminderPayload $sessionB 'mcp__serena__get_symbols_overview')
    Assert-True ($serenaReset.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($serenaReset.stdout)) 'Serena 工具调用必须静默并重置连续计数。'
    $afterReset = Invoke-SerenaVendor 'remind' $bashB
    Assert-True ($afterReset.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($afterReset.stdout)) 'Serena 工具重置后下一次 Bash 不得立即提醒。'

    $sessionADir = Join-Path $fixtureHome "hook_data\$sessionA"
    $sessionBDir = Join-Path $fixtureHome "hook_data\$sessionB"
    Assert-True (Test-Path -LiteralPath $sessionADir -PathType Container) 'cleanup 前应存在 session A hook state。'
    Assert-True (Test-Path -LiteralPath $sessionBDir -PathType Container) 'cleanup 前应存在 session B hook state。'
    $cleanup = Invoke-SerenaVendor 'cleanup' ("{`"session_id`":`"$sessionA`"}")
    Assert-Equal $cleanup.exitCode 0 'cleanup 当前 session 必须成功。'
    Assert-True ([string]::IsNullOrWhiteSpace($cleanup.stdout)) 'cleanup 成功必须保持 stdout 静默。'
    Assert-True (-not (Test-Path -LiteralPath $sessionADir)) 'cleanup 必须删除当前 session state。'
    Assert-True (Test-Path -LiteralPath $sessionBDir -PathType Container) 'cleanup 不得删除其他 session state。'

    foreach ($badPayload in @('', '{}', '{not-json}')) {
        $badReminder = Invoke-SerenaVendor 'remind' $badPayload
        Assert-True ($badReminder.exitCode -ne 0) '空或错误 reminder payload 必须失败关闭。'
        Assert-True ([string]::IsNullOrWhiteSpace($badReminder.stdout)) '错误 reminder payload 不得污染 stdout。'
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

$guardFixtureRoot = 'D:\agents\projects\统一环境\reports\codex-hook-serena-behavior-fixture'
$guardFixtureHome = Join-Path $guardFixtureRoot '.serena'
$guardHealthRoot = 'D:\agents\projects\统一环境\reports\codex-hook-health-test'
$runtimePath = 'D:\agents\projects\统一环境\managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
if (Test-Path -LiteralPath $guardFixtureRoot) { Remove-Item -LiteralPath $guardFixtureRoot -Recurse -Force }
if (Test-Path -LiteralPath $guardHealthRoot) { Remove-Item -LiteralPath $guardHealthRoot -Recurse -Force }
[IO.Directory]::CreateDirectory($guardFixtureRoot) | Out-Null
try {
    . $behaviorGuardPath
    # holder 子进程继承本进程环境；防御性清除同名变量，持锁时长一律由下方显式注入。
    Remove-Item Env:CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS -ErrorAction SilentlyContinue
    $outsideSentinel = Join-Path $guardFixtureRoot 'outside-sentinel.txt'
    [IO.File]::WriteAllText($outsideSentinel, 'preserve', [Text.UTF8Encoding]::new($false))

    $hookDataRoot = Join-Path $guardFixtureHome 'hook_data'
    $outsideSessionRoot = Join-Path $guardFixtureRoot 'outside-session-state'
    [IO.Directory]::CreateDirectory($hookDataRoot) | Out-Null
    [IO.Directory]::CreateDirectory($outsideSessionRoot) | Out-Null
    $outsideSessionSentinel = Join-Path $outsideSessionRoot 'third-party-sentinel.txt'
    [IO.File]::WriteAllText($outsideSessionSentinel, 'preserve', [Text.UTF8Encoding]::new($false))

    # A competing PreToolUse invocation must fail open before it creates or
    # touches the shared Serena session state. The old guard had no session
    # mutex, so this assertion is intentionally red until the guard is fixed.
    $mutexSession = 'session-mutex-held-redacted'
    $mutexSessionPath = Join-Path $guardFixtureHome "hook_data\$mutexSession"
    $mutexName = Get-CodexSerenaSessionMutexName -SerenaHome $guardFixtureHome -SessionId $mutexSession
    $mutexAlias = Get-CodexSerenaSessionMutexName -SerenaHome ($guardFixtureHome.ToUpperInvariant()) -SessionId $mutexSession.ToUpperInvariant()
    Assert-Equal $mutexAlias $mutexName 'session mutex 名称必须对 Windows 路径和 session id 大小写等价。'
    # 固定测试向量：期望锁名钉死当前算法的真实输出；若回归删掉 GetFullPath/TrimEnd/大写不变式，本断言必须变红。
    $vectorSession = 'Session-Vector-Redacted_09'
    $expectedVectorMutex = 'Local\CodexSerenaSession-9EE577DEB07F6BC4F5C29161054D270A0EB2FE3FBE172318C0063203276785E4'
    Assert-Equal (Get-CodexSerenaSessionMutexName -SerenaHome $guardFixtureHome -SessionId $vectorSession) $expectedVectorMutex 'session mutex 名称必须匹配固定测试向量。'
    Assert-Equal (Get-CodexSerenaSessionMutexName -SerenaHome ($guardFixtureHome -replace '\\', '/') -SessionId $vectorSession) $expectedVectorMutex '/ 与 \ 等价拼写必须产生同一锁名。'
    Assert-Equal (Get-CodexSerenaSessionMutexName -SerenaHome ($guardFixtureHome + '\') -SessionId $vectorSession) $expectedVectorMutex '尾部斜杠等价拼写必须产生同一锁名。'
    $mutexReady = Join-Path $guardFixtureRoot 'session-mutex-ready.txt'
    $mutexHolderScript = @'
$mutex = [Threading.Mutex]::new($false, $env:CODEX_TEST_SERENA_MUTEX_NAME)
try {
    if (-not $mutex.WaitOne(0)) { exit 2 }
    [IO.File]::WriteAllText($env:CODEX_TEST_SERENA_MUTEX_READY, 'ready', [Text.UTF8Encoding]::new($false))
    $holdSeconds = 5
    if ($env:CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS -match '^\d+$') { $holdSeconds = [int]$env:CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS }
    Start-Sleep -Seconds $holdSeconds
}
finally {
    try { [void]$mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
'@
    $mutexHolderEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($mutexHolderScript))
    $mutexHolder = Start-NoWindowProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
        -Arguments @('-NoProfile', '-EncodedCommand', $mutexHolderEncoded) `
        -Environment @{ CODEX_TEST_SERENA_MUTEX_NAME = $mutexName; CODEX_TEST_SERENA_MUTEX_READY = $mutexReady; CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS = '5' }
    try {
        for ($attempt = 0; $attempt -lt 80 -and -not (Test-Path -LiteralPath $mutexReady -PathType Leaf); $attempt++) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $mutexReady -PathType Leaf) 'session mutex holder 必须进入临界区。'
        $mutexWatch = [Diagnostics.Stopwatch]::StartNew()
        $mutexResult = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
            -InputText (New-ReminderPayload $mutexSession 'Bash') `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        $mutexWatch.Stop()
        Assert-True ($mutexResult.ok -and $mutexResult.exitCode -eq 0 -and $mutexResult.stdout.Length -eq 0) 'session mutex contention 必须静默 fail-open。'
        Assert-True ($mutexWatch.ElapsedMilliseconds -lt 3500) "session mutex contention 必须在宿主 10 秒预算前返回；actual=$($mutexWatch.ElapsedMilliseconds)ms"
        Assert-True (-not (Test-Path -LiteralPath $mutexSessionPath)) 'session mutex contention 不得创建或修改 session state。'
        # Reminder 让路不触碰任何状态也无泄漏，热路径保持完全静默：不升级健康记录，
        # 避免 health writer 的 .backups 随每次 PreToolUse 竞争无界增长。
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardHealthRoot 'serena-reminder.json'))) 'reminder 竞争让路必须保持静默，不得写 latest health。'
        # A different session maps to a different mutex and must not be blocked
        # by the held one.
        $otherMutexSession = 'session-mutex-other-redacted'
        $otherMutexName = Get-CodexSerenaSessionMutexName -SerenaHome $guardFixtureHome -SessionId $otherMutexSession
        Assert-True ($otherMutexName -cne $mutexName) '不同 session 必须生成不同互斥名。'
        $otherMutexResult = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
            -InputText (New-ReminderPayload $otherMutexSession 'Bash') `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        Assert-True ($otherMutexResult.ok -and $otherMutexResult.exitCode -eq 0) '不同 session 的 Reminder 不得被持有的互斥阻塞。'
        Assert-True (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$otherMutexSession") -PathType Container) '不同 session 的 Reminder 必须正常建立自有 session state。'
        # Activation 不拿这把 session 锁：同 session 互斥被占用时仍须立刻产出 SessionStart，
        # 不得走 Reminder 的 250ms 空输出 fail-open，也不得等到 holder 释放。
        $activationHeldWatch = [Diagnostics.Stopwatch]::StartNew()
        $activationHeld = Invoke-CodexSerenaBehaviorGuardCore -Behavior Activation `
            -InputText (ConvertTo-Json ([ordered]@{ session_id = $mutexSession }) -Compress) `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        $activationHeldWatch.Stop()
        Assert-True ($activationHeld.ok -and $activationHeld.exitCode -eq 0 -and $activationHeld.stdout.Length -gt 0) 'Activation 在同 session 互斥被占用时仍须成功且有协议输出。'
        Assert-True ($activationHeldWatch.ElapsedMilliseconds -lt 3500) "Activation 不得等待 session 互斥；actual=$($activationHeldWatch.ElapsedMilliseconds)ms"
        $activationHeldJson = [Text.UTF8Encoding]::new($false, $true).GetString($activationHeld.stdout) | ConvertFrom-Json
        Assert-Equal $activationHeldJson.hookSpecificOutput.hookEventName 'SessionStart' 'Activation 不得因互斥竞争变成空输出 fail-open。'
        Assert-True (-not (Test-Path -LiteralPath $mutexSessionPath)) 'Activation 不得创建或修改 session state。'
    }
    finally {
        if (-not $mutexHolder.HasExited) { $mutexHolder.Kill($true) }
        try { $mutexHolder.WaitForExit(2000) } catch {}
        $mutexHolder.Dispose()
    }

    # Stop/Cleanup may wait for an in-flight reminder, but must still finish
    # within the outer 10s hook budget and remove the now-safe session state.
    $cleanupMutexSession = 'cleanup-mutex-held-redacted'
    $cleanupMutexPayload = New-ReminderPayload $cleanupMutexSession 'Bash'
    $cleanupMutexSeed = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
        -InputText $cleanupMutexPayload `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($cleanupMutexSeed.ok -and (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$cleanupMutexSession") -PathType Container)) 'cleanup contention fixture 必须先建立 session state。'
    $cleanupMutexName = Get-CodexSerenaSessionMutexName -SerenaHome $guardFixtureHome -SessionId $cleanupMutexSession
    $cleanupMutexReady = Join-Path $guardFixtureRoot 'cleanup-mutex-ready.txt'
    $cleanupMutexHolder = Start-NoWindowProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
        -Arguments @('-NoProfile', '-EncodedCommand', $mutexHolderEncoded) `
        -Environment @{ CODEX_TEST_SERENA_MUTEX_NAME = $cleanupMutexName; CODEX_TEST_SERENA_MUTEX_READY = $cleanupMutexReady; CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS = '5' }
    try {
        for ($attempt = 0; $attempt -lt 80 -and -not (Test-Path -LiteralPath $cleanupMutexReady -PathType Leaf); $attempt++) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $cleanupMutexReady -PathType Leaf) 'cleanup session mutex holder 必须进入临界区。'
        $cleanupMutexWatch = [Diagnostics.Stopwatch]::StartNew()
        $cleanupMutexResult = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup `
            -InputText (ConvertTo-Json ([ordered]@{ session_id = $cleanupMutexSession }) -Compress) `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        $cleanupMutexWatch.Stop()
        Assert-True ($cleanupMutexResult.ok -and $cleanupMutexResult.exitCode -eq 0 -and $cleanupMutexResult.stdout.Length -eq 0) 'cleanup contention 必须在锁释放后成功。'
        Assert-True ($cleanupMutexWatch.ElapsedMilliseconds -lt 9500) "cleanup contention 必须留在宿主 10 秒预算内；actual=$($cleanupMutexWatch.ElapsedMilliseconds)ms"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$cleanupMutexSession"))) 'cleanup contention 成功后不得留下 session state。'
    }
    finally {
        if (-not $cleanupMutexHolder.HasExited) { $cleanupMutexHolder.Kill($true) }
        try { $cleanupMutexHolder.WaitForExit(2000) } catch {}
        $cleanupMutexHolder.Dispose()
    }

    # Cleanup 等锁超过 6000ms 预算必须 fail-open：返回形态不变、不删除 session
    # 状态，但必须留下可区分的健康记录，不再静默跳过（本用例在修复前为红）。
    $cleanupTimeoutSession = 'cleanup-timeout-redacted'
    $cleanupTimeoutSessionDir = Join-Path $guardFixtureHome "hook_data\$cleanupTimeoutSession"
    $cleanupTimeoutSeed = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
        -InputText (New-ReminderPayload $cleanupTimeoutSession 'Bash') `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($cleanupTimeoutSeed.ok -and (Test-Path -LiteralPath $cleanupTimeoutSessionDir -PathType Container)) 'cleanup timeout fixture 必须先建立 session state。'
    $cleanupTimeoutCounter = Join-Path $cleanupTimeoutSessionDir 'tool_use_counter.pkl'
    Assert-True (Test-Path -LiteralPath $cleanupTimeoutCounter -PathType Leaf) 'cleanup timeout fixture 必须有计数器文件。'
    $cleanupTimeoutNamesBefore = @(Get-ChildItem -LiteralPath $cleanupTimeoutSessionDir -Force -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($cleanupTimeoutSessionDir.Length) }) -join ','
    $cleanupTimeoutHashBefore = (Get-FileHash -LiteralPath $cleanupTimeoutCounter -Algorithm SHA256).Hash
    $cleanupTimeoutName = Get-CodexSerenaSessionMutexName -SerenaHome $guardFixtureHome -SessionId $cleanupTimeoutSession
    $cleanupTimeoutReady = Join-Path $guardFixtureRoot 'cleanup-timeout-ready.txt'
    $cleanupTimeoutHolder = Start-NoWindowProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
        -Arguments @('-NoProfile', '-EncodedCommand', $mutexHolderEncoded) `
        -Environment @{ CODEX_TEST_SERENA_MUTEX_NAME = $cleanupTimeoutName; CODEX_TEST_SERENA_MUTEX_READY = $cleanupTimeoutReady; CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS = '8' }
    try {
        for ($attempt = 0; $attempt -lt 80 -and -not (Test-Path -LiteralPath $cleanupTimeoutReady -PathType Leaf); $attempt++) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $cleanupTimeoutReady -PathType Leaf) 'cleanup timeout holder 必须进入临界区。'
        $cleanupTimeoutWatch = [Diagnostics.Stopwatch]::StartNew()
        $cleanupTimeoutResult = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup `
            -InputText (ConvertTo-Json ([ordered]@{ session_id = $cleanupTimeoutSession }) -Compress) `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        $cleanupTimeoutWatch.Stop()
        Assert-True ($cleanupTimeoutResult.ok -and $cleanupTimeoutResult.exitCode -eq 0 -and $cleanupTimeoutResult.stdout.Length -eq 0) 'cleanup 等锁超时必须保持 fail-open 返回形态。'
        Assert-True ($cleanupTimeoutWatch.ElapsedMilliseconds -ge 6000 -and $cleanupTimeoutWatch.ElapsedMilliseconds -lt 9500) "cleanup 等锁超时必须落在 6000ms 预算边界；actual=$($cleanupTimeoutWatch.ElapsedMilliseconds)ms"
        Assert-True (Test-Path -LiteralPath $cleanupTimeoutSessionDir -PathType Container) 'cleanup 等锁超时不得删除 session state。'
        $cleanupTimeoutNamesAfter = @(Get-ChildItem -LiteralPath $cleanupTimeoutSessionDir -Force -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($cleanupTimeoutSessionDir.Length) }) -join ','
        Assert-Equal $cleanupTimeoutNamesAfter $cleanupTimeoutNamesBefore 'cleanup 等锁超时不得创建或删除 session 文件。'
        Assert-Equal (Get-FileHash -LiteralPath $cleanupTimeoutCounter -Algorithm SHA256).Hash $cleanupTimeoutHashBefore 'cleanup 等锁超时不得改写 session 计数器。'
        $timeoutHealth = Get-Content -LiteralPath (Join-Path $guardHealthRoot 'serena-cleanup.json') -Raw | ConvertFrom-Json
        Assert-True ($timeoutHealth.ok -eq $false) 'cleanup 等锁超时必须写健康记录。'
        Assert-Equal (@($timeoutHealth.errors) -join ',') 'skipped: session mutex contention' 'cleanup 超时健康记录必须携带可区分的跳过原因。'
    }
    finally {
        if (-not $cleanupTimeoutHolder.HasExited) { $cleanupTimeoutHolder.Kill($true) }
        try { $cleanupTimeoutHolder.WaitForExit(2000) } catch {}
        $cleanupTimeoutHolder.Dispose()
    }
    # 超时让路不是永久状态：锁可用后重试 cleanup 必须完成删除。
    $cleanupTimeoutRetry = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup `
        -InputText (ConvertTo-Json ([ordered]@{ session_id = $cleanupTimeoutSession }) -Compress) `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($cleanupTimeoutRetry.ok -and -not (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$cleanupTimeoutSession"))) '超时让路后重试 cleanup 必须完成删除。'

    # A holder that dies inside the critical section abandons the named mutex.
    # The next hook must treat that as acquired and still run the existing path
    # and counter identity validation instead of wedging the session.
    $abandonedMutexSession = 'abandoned-mutex-redacted'
    $abandonedMutexName = Get-CodexSerenaSessionMutexName -SerenaHome $guardFixtureHome -SessionId $abandonedMutexSession
    $abandonedMutexReady = Join-Path $guardFixtureRoot 'abandoned-mutex-ready.txt'
    $abandonedMutexHolder = Start-NoWindowProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
        -Arguments @('-NoProfile', '-EncodedCommand', $mutexHolderEncoded) `
        -Environment @{ CODEX_TEST_SERENA_MUTEX_NAME = $abandonedMutexName; CODEX_TEST_SERENA_MUTEX_READY = $abandonedMutexReady; CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS = '5' }
    try {
        for ($attempt = 0; $attempt -lt 80 -and -not (Test-Path -LiteralPath $abandonedMutexReady -PathType Leaf); $attempt++) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $abandonedMutexReady -PathType Leaf) 'abandoned session mutex holder 必须进入临界区。'
        $abandonedMutexHolder.Kill($true)
        Assert-True ($abandonedMutexHolder.WaitForExit(2000)) 'abandoned session mutex holder 必须被终止。'
        $abandonedMutexResult = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
            -InputText (New-ReminderPayload $abandonedMutexSession 'Bash') `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        Assert-True ($abandonedMutexResult.ok -and $abandonedMutexResult.exitCode -eq 0) 'abandoned mutex 必须被视为已取得。'
        Assert-True (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$abandonedMutexSession\tool_use_counter.pkl") -PathType Leaf) 'abandoned mutex 之后必须仍执行既有路径与计数器身份校验。'
    }
    finally {
        if (-not $abandonedMutexHolder.HasExited) { $abandonedMutexHolder.Kill($true) }
        try { $abandonedMutexHolder.WaitForExit(2000) } catch {}
        $abandonedMutexHolder.Dispose()
    }

    # 两个并发 Cleanup 对同一 session 必须串行化并收敛到同一终态：状态被删、双方无异常。
    # 竞争方用真实子进程跑受管 guard 核心（与 hook 同路径），不用线程内模拟。
    $guardCoreChildScript = @'
. $env:CODEX_TEST_SERENA_GUARD_PATH
$result = Invoke-CodexSerenaBehaviorGuardCore -Behavior $env:CODEX_TEST_SERENA_BEHAVIOR -InputText $env:CODEX_TEST_SERENA_INPUT -VendorPath $env:CODEX_TEST_SERENA_VENDOR -SerenaHome $env:CODEX_TEST_SERENA_HOME -RuntimePath $env:CODEX_TEST_SERENA_RUNTIME -HealthRoot $env:CODEX_TEST_SERENA_HEALTH -AllowFixture
if (-not $result.ok -or $result.exitCode -ne 0 -or $result.stdout.Length -ne 0) { exit 3 }
exit 0
'@
    $guardCoreChildEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guardCoreChildScript))
    function Start-GuardCoreChild([string]$Behavior, [string]$InputText) {
        Start-NoWindowProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
            -Arguments @('-NoProfile', '-EncodedCommand', $guardCoreChildEncoded) `
            -Environment @{
                CODEX_TEST_SERENA_GUARD_PATH = $behaviorGuardPath
                CODEX_TEST_SERENA_BEHAVIOR = $Behavior
                CODEX_TEST_SERENA_INPUT = $InputText
                CODEX_TEST_SERENA_VENDOR = $vendorPath
                CODEX_TEST_SERENA_HOME = $guardFixtureHome
                CODEX_TEST_SERENA_RUNTIME = $runtimePath
                CODEX_TEST_SERENA_HEALTH = $guardHealthRoot
            }
    }
    $concurrentCleanupSession = 'cleanup-concurrent-redacted'
    $concurrentCleanupSeed = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
        -InputText (New-ReminderPayload $concurrentCleanupSession 'Bash') `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($concurrentCleanupSeed.ok -and (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$concurrentCleanupSession") -PathType Container)) '并发 cleanup fixture 必须先建立 session state。'
    $concurrentCleanupName = Get-CodexSerenaSessionMutexName -SerenaHome $guardFixtureHome -SessionId $concurrentCleanupSession
    $concurrentCleanupReady = Join-Path $guardFixtureRoot 'cleanup-concurrent-ready.txt'
    $concurrentCleanupHolder = Start-NoWindowProcess -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
        -Arguments @('-NoProfile', '-EncodedCommand', $mutexHolderEncoded) `
        -Environment @{ CODEX_TEST_SERENA_MUTEX_NAME = $concurrentCleanupName; CODEX_TEST_SERENA_MUTEX_READY = $concurrentCleanupReady; CODEX_TEST_SERENA_MUTEX_HOLD_SECONDS = '2' }
    $concurrentCleanupFirst = $null
    $concurrentCleanupSecond = $null
    try {
        for ($attempt = 0; $attempt -lt 80 -and -not (Test-Path -LiteralPath $concurrentCleanupReady -PathType Leaf); $attempt++) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $concurrentCleanupReady -PathType Leaf) '并发 cleanup holder 必须进入临界区。'
        $concurrentCleanupPayload = ConvertTo-Json ([ordered]@{ session_id = $concurrentCleanupSession }) -Compress
        $concurrentCleanupFirst = Start-GuardCoreChild 'Cleanup' $concurrentCleanupPayload
        $concurrentCleanupSecond = Start-GuardCoreChild 'Cleanup' $concurrentCleanupPayload
        Assert-True ($concurrentCleanupFirst.WaitForExit(20000)) '第一个并发 cleanup 必须在预算内退出。'
        Assert-True ($concurrentCleanupSecond.WaitForExit(20000)) '第二个并发 cleanup 必须在预算内退出。'
        Assert-Equal ([string]$concurrentCleanupFirst.ExitCode) '0' '第一个并发 cleanup 不得异常。'
        Assert-Equal ([string]$concurrentCleanupSecond.ExitCode) '0' '第二个并发 cleanup 不得异常。'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$concurrentCleanupSession"))) '并发 cleanup 终态必须一致：session state 被删除。'
    }
    finally {
        foreach ($child in @($concurrentCleanupFirst, $concurrentCleanupSecond, $concurrentCleanupHolder)) {
            if ($null -ne $child) {
                if (-not $child.HasExited) { $child.Kill($true) }
                try { $child.WaitForExit(2000) } catch {}
                $child.Dispose()
            }
        }
    }

    # Reminder×Cleanup 交错（确定性顺序编排）：Cleanup 完整删除并释放锁之后，后来的
    # Reminder 拿锁会重建 session 状态。该行为是已知设计边界（互斥只保证串行化，不保证
    # Cleanup 是最后一个持锁者），此处按现状钉住；消除需 tombstone 机制。
    # 见 .scratch/serena-session-mutex-spec.md Further Notes 的边界记录（复核 F5）。
    # 用严格顺序而非并发竞态表达同一事实：Cleanup 返回后锁必然空闲、状态必然已删，
    # 随后的 Reminder 无竞争地拿锁并走既有 Acquire/vendor 重建路径，结果由代码路径
    # 决定而非调度时序，因此是确定性的。
    $interleaveSession = 'cleanup-reminder-interleave-redacted'
    $interleaveSeed = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
        -InputText (New-ReminderPayload $interleaveSession 'Bash') `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($interleaveSeed.ok -and (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$interleaveSession") -PathType Container)) '交错 fixture 必须先建立 session state。'
    $interleaveCleanup = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup `
        -InputText (ConvertTo-Json ([ordered]@{ session_id = $interleaveSession }) -Compress) `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($interleaveCleanup.ok -and $interleaveCleanup.exitCode -eq 0 -and $interleaveCleanup.stdout.Length -eq 0) '交错 cleanup 必须成功且保持 stdout 空。'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$interleaveSession"))) '交错 cleanup 必须先完成删除。'
    $interleaveReminder = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder `
        -InputText (New-ReminderPayload $interleaveSession 'Bash') `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($interleaveReminder.ok -and $interleaveReminder.exitCode -eq 0) '交错 reminder 不得异常。'
    Assert-True (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$interleaveSession\tool_use_counter.pkl") -PathType Leaf) '设计边界钉住：Cleanup 后拿到锁的 Reminder 会重建 session 状态。'
    # 边界用例结束后恢复干净终态。
    $interleaveFinal = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup `
        -InputText (ConvertTo-Json ([ordered]@{ session_id = $interleaveSession }) -Compress) `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($interleaveFinal.ok -and -not (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$interleaveSession"))) '交错用例收尾必须删除复活的状态。'

    # 缺失 leaf 由 guard 创建后，其逐段目录句柄必须持续阻止删除/替换；否则 vendor 按路径重开时可越界。
    Initialize-CodexSerenaSessionDirectoryGuard
    $raceSessionPath = Join-Path $hookDataRoot 'missing-leaf-race-redacted'
    $raceGuard = [CodexHookRuntime.SerenaSessionDirectoryGuard]::Acquire($guardFixtureRoot, $raceSessionPath)
    try {
        Assert-True (Test-Path -LiteralPath $raceSessionPath -PathType Container) 'guard 必须安全创建缺失 session leaf。'
        $raceDelete = Invoke-ChildProcess -FilePath 'C:\Windows\System32\cmd.exe' -Arguments @('/d','/c','rmdir',$raceSessionPath) -InputText ''
        Assert-True ($raceDelete.exitCode -ne 0 -and (Test-Path -LiteralPath $raceSessionPath -PathType Container)) 'guard 持有期间必须拒绝删除缺失 leaf 的竞争替换。'
        $junctionReplacementRejected = $false
        try { $null = New-Item -ItemType Junction -Path $raceSessionPath -Target $outsideSessionRoot -ErrorAction Stop }
        catch { $junctionReplacementRejected = $true }
        Assert-True $junctionReplacementRejected 'guard 持有期间必须拒绝把缺失 leaf 替换为 junction。'
        Assert-Equal ([IO.File]::ReadAllText($outsideSessionSentinel)) 'preserve' '缺失 leaf 竞争不得触及 hook_data 外哨兵。'
    }
    finally { $raceGuard.Dispose() }
    Remove-Item -LiteralPath $raceSessionPath -Force

    # session 目录租约必须同时封住 counter 的 rename/replacement 窗口；cleanup 随后再对文件本身做同句柄验证和删除。
    $counterRacePath = Join-Path $hookDataRoot 'counter-replacement-race-redacted'
    [IO.Directory]::CreateDirectory($counterRacePath) | Out-Null
    $counterRaceFile = Join-Path $counterRacePath 'tool_use_counter.pkl'
    [IO.File]::WriteAllText($counterRaceFile, 'owned-counter', [Text.UTF8Encoding]::new($false))
    $counterRaceGuard = [CodexHookRuntime.SerenaSessionDirectoryGuard]::Acquire($guardFixtureRoot, $counterRacePath)
    try {
        Assert-Throws { Move-Item -LiteralPath $counterRaceFile -Destination (Join-Path $counterRacePath 'attacker-counter.pkl') -ErrorAction Stop } 'being used by another process'
        Assert-Equal ([IO.File]::ReadAllText($counterRaceFile)) 'owned-counter' '目录租约持有期间 counter replacement 必须失败且原字节保持。'
    }
    finally { $counterRaceGuard.Dispose() }
    Remove-Item -LiteralPath $counterRacePath -Recurse -Force

    # Reminder 在调用 vendor 前必须认证既有 counter；共享 hardlink 不能被 vendor 原地改写。
    $reminderHardlinkSession = 'reminder-hardlink-redacted'
    $reminderHardlinkDirectory = Join-Path $hookDataRoot $reminderHardlinkSession
    [IO.Directory]::CreateDirectory($reminderHardlinkDirectory) | Out-Null
    $reminderHardlinkOutside = Join-Path $guardFixtureRoot 'reminder-shared-counter.pkl'
    $reminderHardlinkCounter = Join-Path $reminderHardlinkDirectory 'tool_use_counter.pkl'
    [IO.File]::WriteAllText($reminderHardlinkOutside, 'preserve-reminder-shared-bytes', [Text.UTF8Encoding]::new($false))
    $null = New-Item -ItemType HardLink -Path $reminderHardlinkCounter -Target $reminderHardlinkOutside
    $reminderHardlink = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText (New-ReminderPayload $reminderHardlinkSession 'Bash') `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $reminderHardlink.ok -and $reminderHardlink.exitCode -eq 0 -and $reminderHardlink.stdout.Length -eq 0) 'reminder 必须在 vendor 前拒绝多硬链接 counter。'
    Assert-Equal ([IO.File]::ReadAllText($reminderHardlinkOutside)) 'preserve-reminder-shared-bytes' 'reminder 不得让 vendor 改写共享 counter 的外部链接。'

    $reminderReparseSession = 'reminder-reparse-redacted'
    $reminderReparseDirectory = Join-Path $hookDataRoot $reminderReparseSession
    [IO.Directory]::CreateDirectory($reminderReparseDirectory) | Out-Null
    $reminderReparseOutside = Join-Path $guardFixtureRoot 'reminder-reparse-outside'
    $reminderReparseSentinel = Join-Path $reminderReparseOutside 'sentinel.pkl'
    $reminderReparseCounter = Join-Path $reminderReparseDirectory 'tool_use_counter.pkl'
    [IO.Directory]::CreateDirectory($reminderReparseOutside) | Out-Null
    [IO.File]::WriteAllText($reminderReparseSentinel, 'preserve-reminder-reparse-bytes', [Text.UTF8Encoding]::new($false))
    $null = New-Item -ItemType Junction -Path $reminderReparseCounter -Target $reminderReparseOutside -ErrorAction Stop
    $reminderReparse = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText (New-ReminderPayload $reminderReparseSession 'Bash') `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $reminderReparse.ok -and $reminderReparse.exitCode -eq 0 -and $reminderReparse.stdout.Length -eq 0) 'reminder 必须在 vendor 前拒绝 reparse counter。'
    Assert-Equal ([IO.File]::ReadAllText($reminderReparseSentinel)) 'preserve-reminder-reparse-bytes' 'reminder 不得让 vendor 通过 reparse counter 改写外部文件。'

    # 缺失 counter 必须由 guard 以 CREATE_NEW 建立并持有 name fence；租约期间删除/替换必须被 Windows 拒绝。
    $missingCounterSession = 'missing-counter-race-redacted'
    $missingCounterDirectory = Join-Path $hookDataRoot $missingCounterSession
    [IO.Directory]::CreateDirectory($missingCounterDirectory) | Out-Null
    $missingCounterPath = Join-Path $missingCounterDirectory 'tool_use_counter.pkl'
    $missingCounterGuard = [CodexHookRuntime.SerenaSessionDirectoryGuard]::Acquire($guardFixtureRoot, $missingCounterDirectory)
    $missingCounterLease = $null
    try {
        $missingCounterLease = $missingCounterGuard.AcquireCounterLease($missingCounterPath)
        Assert-True (Test-Path -LiteralPath $missingCounterPath -PathType Leaf) 'missing counter lease 必须原子建立受管 leaf。'
        Assert-Throws { Remove-Item -LiteralPath $missingCounterPath -Force -ErrorAction Stop } 'being used by another process'
        $missingCounterLease.ValidateAfterVendor($missingCounterPath)
    }
    finally {
        if ($null -ne $missingCounterLease) { $missingCounterLease.Dispose() }
        $missingCounterGuard.Dispose()
    }
    Remove-Item -LiteralPath $missingCounterDirectory -Recurse -Force

    $junctionSession = 'junction-session-redacted'
    $junctionPath = Join-Path $hookDataRoot $junctionSession
    $null = New-Item -ItemType Junction -Path $junctionPath -Target $outsideSessionRoot
    try {
        foreach ($behavior in @('Reminder', 'Cleanup')) {
            $junctionPayload = if ($behavior -ceq 'Reminder') {
                New-ReminderPayload $junctionSession 'Bash'
            }
            else {
                [pscustomobject][ordered]@{ session_id = $junctionSession } | ConvertTo-Json -Compress
            }
            $junctionResult = Invoke-CodexSerenaBehaviorGuardCore -Behavior $behavior -InputText $junctionPayload `
                -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
            Assert-True (-not $junctionResult.ok -and $junctionResult.exitCode -eq 0 -and $junctionResult.stdout.Length -eq 0) "$behavior 遇到越界 session junction 必须静默拒绝。"
            Assert-Equal ([IO.File]::ReadAllText($outsideSessionSentinel)) 'preserve' "$behavior 不得改写或删除 hook_data 外哨兵。"
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $outsideSessionRoot 'tool_use_counter.pkl'))) "$behavior 不得通过 junction 在 hook_data 外创建 vendor 状态。"
        }
    }
    finally {
        if (Test-Path -LiteralPath $junctionPath) {
            $junctionDelete = Invoke-ChildProcess -FilePath 'C:\Windows\System32\cmd.exe' -Arguments @('/d','/c','rmdir',$junctionPath) -InputText ''
            Assert-True ($junctionDelete.exitCode -eq 0) 'session junction 清理失败。'
        }
    }
    foreach ($dangerousSession in @('..', '../outside-sentinel.txt', '..\outside-sentinel.txt', 'D:\outside', '\\server\share', 'nested/session', 'nested\session')) {
        foreach ($behavior in @('Reminder', 'Cleanup', 'Activation')) {
            $dangerousPayload = [pscustomobject][ordered]@{ session_id = $dangerousSession; tool_name = 'Bash'; tool_input = [pscustomobject]@{ command = 'rg hook' } } | ConvertTo-Json -Compress -Depth 4
            $dangerous = Invoke-CodexSerenaBehaviorGuardCore -Behavior $behavior -InputText $dangerousPayload `
                -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
            Assert-True (-not $dangerous.ok -and $dangerous.exitCode -eq 0 -and $dangerous.stdout.Length -eq 0) "$behavior 必须静默拒绝危险 session id：$dangerousSession"
            Assert-Equal ([IO.File]::ReadAllText($outsideSentinel)) 'preserve' '危险 session 不得读写或删除 hook_data 外哨兵。'
        }
    }
    $invalidActivation = Invoke-CodexSerenaBehaviorGuardCore -Behavior Activation -InputText '{invalid payload}' `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $invalidActivation.ok -and $invalidActivation.exitCode -eq 0 -and $invalidActivation.stdout.Length -eq 0) 'activation reminder 必须静默拒绝畸形 SessionStart payload。'
    $activation = Invoke-CodexSerenaBehaviorGuardCore -Behavior Activation -InputText '{"session_id":"activation-session-redacted"}' `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($activation.ok -and $activation.exitCode -eq 0) '静态 activation reminder 必须成功。'
    $activationJson = [Text.UTF8Encoding]::new($false, $true).GetString($activation.stdout) | ConvertFrom-Json
    Assert-Equal $activationJson.hookSpecificOutput.hookEventName 'SessionStart' 'activation reminder 必须输出 SessionStart 协议。'
    $activationContext = [string]$activationJson.hookSpecificOutput.additionalContext
    Assert-True $activationContext.Contains('absolute workspace root from environment_context') 'activation reminder 必须要求使用 environment_context 的绝对 workspace。'
    Assert-True $activationContext.Contains('mcp__serena__activate_project') 'activation reminder 必须要求显式 activate_project。'
    Assert-True $activationContext.Contains('mcp__serena__get_current_config') 'activation reminder 必须要求 get_current_config 复验。'
    Assert-True $activationContext.Contains('Do not infer the project from cwd') 'activation reminder 不得按 cwd 自动激活。'

    $failedGuard = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText '{not-json}' `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $failedGuard.ok -and $failedGuard.exitCode -eq 0) 'optional 错误 payload 必须静默降级。'
    Assert-Equal $failedGuard.stdout.Length 0 'behavior guard 失败不得污染 stdout。'
    Assert-Equal ([string]$failedGuard.error) 'serena behavior hook failed' 'behavior guard 错误必须脱敏。'
    $failureHealth = Get-Content -LiteralPath (Join-Path $guardHealthRoot 'serena-reminder.json') -Raw | ConvertFrom-Json
    Assert-True ($failureHealth.ok -eq $false) 'behavior guard 失败必须写结构化失败 health。'
    Assert-Equal (@($failureHealth.errors) -join ',') 'serena behavior protocol validation failed' '失败 health 不得包含 payload/session/vendor stderr。'
    Remove-Item -LiteralPath $guardHealthRoot -Recurse -Force

    $vendorFailure = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText '{"session_id":"11111111-2222-4333-8444-555555555555"}' `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $vendorFailure.ok -and $vendorFailure.exitCode -eq 0 -and $vendorFailure.stdout.Length -eq 0) 'optional vendor 失败必须静默降级。'
    Remove-Item -LiteralPath $guardHealthRoot -Recurse -Force

    [IO.File]::WriteAllText($guardHealthRoot, 'block-health-root', [Text.UTF8Encoding]::new($false))
    $healthFailure = Invoke-CodexSerenaBehaviorGuardCore -Behavior Activation -InputText '{"session_id":"11111111-2222-4333-8444-555555555555"}' `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    # 成功路径健康写失败必须降级为仅缺失记录，不得翻转 vendor 已成功的结果（F2 修复前本断言为红）。
    Assert-True ($healthFailure.ok -and $healthFailure.exitCode -eq 0 -and $healthFailure.stdout.Length -gt 0) 'health 写入失败不得翻转 vendor 已成功的结果。'
    $healthFailureJson = [Text.UTF8Encoding]::new($false, $true).GetString($healthFailure.stdout) | ConvertFrom-Json
    Assert-Equal $healthFailureJson.hookSpecificOutput.hookEventName 'SessionStart' 'health 写入失败不得吞掉 vendor stdout。'
    $blockedHealthAcceptance = Invoke-CodexSerenaBehaviorAcceptanceCore -Behavior Activation `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($blockedHealthAcceptance.ok -and $blockedHealthAcceptance.exitCode -eq 0) 'health 写入失败降级后 acceptance 不得被健康层翻转。'
    Remove-Item -LiteralPath $guardHealthRoot -Force

    $guardSession = 'guard-session-redacted'
    $guardPayload = New-ReminderPayload $guardSession 'Bash'
    $guardFirst = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $guardPayload `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    $guardSecond = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $guardPayload `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardHealthRoot 'serena-reminder.json'))) '静默 reminder 不得写 latest health。'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardHealthRoot '.backups'))) '静默 reminder 不得生成 health backup。'
    $guardThird = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $guardPayload `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($guardFirst.ok -and $guardFirst.stdout.Length -eq 0 -and $guardSecond.ok -and $guardSecond.stdout.Length -eq 0) 'guard 前两次 reminder 必须逐字节保持空 stdout。'
    Assert-True ($guardThird.ok -and $guardThird.stdout.Length -gt 0) 'guard 第三次 reminder 必须转发 vendor 协议字节。'
    $guardThirdJson = [Text.UTF8Encoding]::new($false, $true).GetString($guardThird.stdout) | ConvertFrom-Json
    Assert-Equal $guardThirdJson.hookSpecificOutput.permissionDecision 'deny' 'guard 不得改变 vendor reminder 决策。'
    $successHealth = Get-Content -LiteralPath (Join-Path $guardHealthRoot 'serena-reminder.json') -Raw | ConvertFrom-Json
    Assert-True ($successHealth.ok -eq $true -and @($successHealth.errors).Count -eq 0) '合法 vendor 协议后必须写成功 health。'

    # 独立重建同一 vendor 状态，证明受管 guard 没有重编码或改写协议字节。
    if (Test-Path -LiteralPath $guardFixtureHome) { Remove-Item -LiteralPath $guardFixtureHome -Recurse -Force }
    [IO.Directory]::CreateDirectory($guardFixtureHome) | Out-Null
    foreach ($attempt in 1..2) {
        $directSilent = Invoke-ChildProcess -FilePath $vendorPath -Arguments @('remind', '--client=codex') -InputText $guardPayload -Environment @{ SERENA_HOME = $guardFixtureHome }
        Assert-True ($directSilent.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($directSilent.stdout)) "vendor 对照第 $attempt 次必须静默。"
    }
    $directThird = Invoke-ChildProcess -FilePath $vendorPath -Arguments @('remind', '--client=codex') -InputText $guardPayload -Environment @{ SERENA_HOME = $guardFixtureHome }
    $directThirdBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$directThird.stdout)
    Assert-True ([Linq.Enumerable]::SequenceEqual[byte]($guardThird.stdout, $directThirdBytes)) 'reminder guard 必须逐字节转发 vendor stdout。'

    # cleanup 必须通过受管 guard 删除且只删除当前 session。
    $cleanupSession = 'cleanup-session-redacted'
    $otherSession = 'cleanup-other-redacted'
    foreach ($session in @($cleanupSession, $otherSession)) {
        $payload = New-ReminderPayload $session 'Bash'
        $seed = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $payload `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        Assert-True ($seed.ok -and $seed.stdout.Length -eq 0) 'cleanup fixture session 必须由受管 reminder guard 建立。'
    }
    $cleanupTarget = Join-Path $guardFixtureHome "hook_data\$cleanupSession"
    $cleanupOther = Join-Path $guardFixtureHome "hook_data\$otherSession"
    $guardCleanup = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup -InputText ("{`"session_id`":`"$cleanupSession`"}") `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True ($guardCleanup.ok -and $guardCleanup.exitCode -eq 0 -and $guardCleanup.stdout.Length -eq 0) 'cleanup guard 必须成功且保持 stdout 空。'
    Assert-True (-not (Test-Path -LiteralPath $cleanupTarget)) 'cleanup guard 必须删除当前 session state。'
    Assert-True (Test-Path -LiteralPath $cleanupOther -PathType Container) 'cleanup guard 不得删除其他 session state。'

    $hardlinkSession = 'cleanup-hardlink-redacted'
    $hardlinkDirectory = Join-Path $guardFixtureHome "hook_data\$hardlinkSession"
    [IO.Directory]::CreateDirectory($hardlinkDirectory) | Out-Null
    $hardlinkOutside = Join-Path $guardFixtureRoot 'shared-counter-sentinel.pkl'
    $hardlinkCounter = Join-Path $hardlinkDirectory 'tool_use_counter.pkl'
    [IO.File]::WriteAllText($hardlinkOutside, 'preserve-shared-bytes', [Text.UTF8Encoding]::new($false))
    $null = New-Item -ItemType HardLink -Path $hardlinkCounter -Target $hardlinkOutside
    $hardlinkCleanup = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup -InputText ("{`"session_id`":`"$hardlinkSession`"}") `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $hardlinkCleanup.ok -and $hardlinkCleanup.exitCode -eq 0 -and $hardlinkCleanup.stdout.Length -eq 0) 'cleanup 必须拒绝多硬链接 counter。'
    Assert-Equal ([IO.File]::ReadAllText($hardlinkOutside)) 'preserve-shared-bytes' 'cleanup 不得改写或删除共享 counter 的外部链接。'
    Assert-True (Test-Path -LiteralPath $hardlinkCounter -PathType Leaf) 'cleanup 拒绝共享 counter 时必须保留 session 内链接。'

    $unknownSession = 'cleanup-unknown-redacted'
    $unknownDirectory = Join-Path $guardFixtureHome "hook_data\$unknownSession"
    [IO.Directory]::CreateDirectory($unknownDirectory) | Out-Null
    $unknownSentinel = Join-Path $unknownDirectory 'third-party-state.txt'
    [IO.File]::WriteAllText($unknownSentinel, 'preserve', [Text.UTF8Encoding]::new($false))
    $unknownCleanup = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup -InputText ("{`"session_id`":`"$unknownSession`"}") `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $unknownCleanup.ok -and $unknownCleanup.exitCode -eq 0 -and $unknownCleanup.stdout.Length -eq 0) 'cleanup 遇到未知 session 子项必须静默 fail-open。'
    Assert-Equal ([IO.File]::ReadAllText($unknownSentinel)) 'preserve' 'cleanup 不得删除或改写未知 session 子项。'

    $mixedUnknownSession = 'cleanup-counter-unknown-redacted'
    $mixedUnknownDirectory = Join-Path $guardFixtureHome "hook_data\$mixedUnknownSession"
    [IO.Directory]::CreateDirectory($mixedUnknownDirectory) | Out-Null
    $mixedCounter = Join-Path $mixedUnknownDirectory 'tool_use_counter.pkl'
    $mixedUnknown = Join-Path $mixedUnknownDirectory 'third-party-state.txt'
    [IO.File]::WriteAllText($mixedCounter, 'preserve-counter', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($mixedUnknown, 'preserve-unknown', [Text.UTF8Encoding]::new($false))
    $mixedCleanup = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup -InputText ("{`"session_id`":`"$mixedUnknownSession`"}") `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $mixedCleanup.ok -and $mixedCleanup.exitCode -eq 0 -and $mixedCleanup.stdout.Length -eq 0) 'cleanup 遇到 counter+unknown 组合必须静默失败。'
    Assert-Equal ([IO.File]::ReadAllText($mixedCounter)) 'preserve-counter' 'cleanup 在完整 closure 验证前不得删除或改写 counter。'
    Assert-Equal ([IO.File]::ReadAllText($mixedUnknown)) 'preserve-unknown' 'cleanup 不得删除或改写未知子项。'

    foreach ($behavior in @('Reminder','Cleanup','Activation')) {
        $acceptance = Invoke-CodexSerenaBehaviorAcceptanceCore -Behavior $behavior `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        Assert-True ($acceptance.ok -and $acceptance.exitCode -eq 0) "$behavior full acceptance 必须成功。"
        if ($null -ne $acceptance.sessionId) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$($acceptance.sessionId)"))) "$behavior full acceptance 必须清理合成 session state。"
        }
    }

}
finally {
    if (Test-Path -LiteralPath $guardFixtureRoot) { Remove-Item -LiteralPath $guardFixtureRoot -Recurse -Force }
    if (Test-Path -LiteralPath $guardHealthRoot) { Remove-Item -LiteralPath $guardHealthRoot -Recurse -Force }
}

$manifestPath = Join-Path $projectRoot 'managed\codex-hooks\host-preflight-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
$hooksById = @{}
foreach ($hook in @($manifest.hooks)) { $hooksById[[string]$hook.id] = $hook }
$expectedWrapperFacts = @{
    'serena-reminder' = 'D:\Codex\.codex\hooks\serena-reminder-guarded.cmd'
    'serena-cleanup' = 'D:\Codex\.codex\hooks\serena-cleanup-guarded.cmd'
}
foreach ($hookId in $expectedWrapperFacts.Keys) {
    $hook = $hooksById[$hookId]
    Assert-Equal ([string]$hook.commandPath) $expectedWrapperFacts[$hookId] "$hookId 必须通过受管 wrapper 注册。"
    Assert-Equal ([string]$hook.wrapperPath) $expectedWrapperFacts[$hookId] "$hookId wrapperPath 必须固定。"
    Assert-Equal ([string]$hook.implementationPath) 'D:\Codex\.codex\hooks\serena-behavior-guard.ps1' "$hookId 必须共用安全 behavior guard。"
    Assert-Equal ([string]$hook.runtimeId) 'pwsh' "$hookId runtime 必须固定受管 PowerShell。"
    Assert-Equal ([string]$hook.sourceState) 'managed' "$hookId wrapper 必须声明为受管源。"
}
Assert-Equal ([string]$hooksById['serena-reminder'].matcher) 'Bash' 'reminder 只能绑定 Bash matcher。'
Assert-Equal ([string]$hooksById['serena-cleanup'].event) 'Stop' 'cleanup 只能绑定 Stop。'
Assert-Equal ([string]$hooksById['serena-activate'].commandPath) 'D:\Codex\.codex\hooks\serena-activation-reminder.cmd' 'SessionStart 必须切换为静态 activation reminder。'
Assert-Equal ([string]$hooksById['serena-activate'].wrapperPath) 'D:\Codex\.codex\hooks\serena-activation-reminder.cmd' 'activation reminder wrapperPath 必须固定。'
Assert-Equal ([string]$hooksById['serena-activate'].implementationPath) 'D:\Codex\.codex\hooks\serena-behavior-guard.ps1' 'activation reminder 必须复用安全 guard。'
Assert-True (-not $hooksById.ContainsKey('serena-auto-approve')) 'production manifest 必须完全排除 auto-approve。'

$filesByRelativePath = @{}
foreach ($file in @($manifest.files)) { $filesByRelativePath[[string]$file.relativePath] = $file }
foreach ($wrapper in @(
    @{ relative = 'hooks/serena-reminder-guarded.cmd'; live = 'serena-reminder-guarded.cmd'; owner = 'serena-reminder'; path = $reminderPath },
    @{ relative = 'hooks/serena-cleanup-guarded.cmd'; live = 'serena-cleanup-guarded.cmd'; owner = 'serena-cleanup'; path = $cleanupPath },
    @{ relative = 'hooks/serena-activation-reminder.cmd'; live = 'serena-activation-reminder.cmd'; owner = 'serena-activate'; path = $activationPath },
    @{ relative = 'hooks/serena-behavior-guard.ps1'; live = 'serena-behavior-guard.ps1'; owner = 'serena-reminder,serena-cleanup,serena-activate'; path = $behaviorGuardPath }
)) {
    Assert-True $filesByRelativePath.ContainsKey($wrapper.relative) "manifest 缺少 $($wrapper.relative)。"
    $record = $filesByRelativePath[$wrapper.relative]
    Assert-Equal ([string]$record.liveRelativePath) $wrapper.live "$($wrapper.relative) live path 非法。"
    Assert-Equal (@($record.ownerHookIds) -join ',') $wrapper.owner "$($wrapper.relative) owner 非法。"
    Assert-Equal ([string]$record.sha256) (Get-CodexHookManifestSourceSha256 -Path $wrapper.path -AllowedExactPaths @($wrapper.path)) "$($wrapper.relative) manifest hash 漂移。"
}

Write-Output 'Codex Serena behavior hook tests passed.'
