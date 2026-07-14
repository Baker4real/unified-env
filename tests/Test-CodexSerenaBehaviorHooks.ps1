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
    Assert-True (-not $source.Contains('%*')) 'wrapper 不得接受外部参数覆盖固定命令。'
}
Assert-True $reminderSource.Contains('"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Reminder') 'reminder 必须固定 sibling 受控 guard 和 Mode。'
Assert-True $cleanupSource.Contains('"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Cleanup') 'cleanup 必须固定 sibling 受控 guard 和 Mode。'
Assert-True $activationSource.Contains('"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Activation') 'activation reminder 必须固定 sibling 受控 guard 和 Mode。'
Assert-True $behaviorGuardSource.Contains("'D:\Codex\tools\uv\bin\serena-hooks.exe'") 'behavior guard 必须固定官方 vendor。'
Assert-True $behaviorGuardSource.Contains("'--client=codex'") 'behavior guard 必须固定 Codex client。'
Assert-True $behaviorGuardSource.Contains('Complete-CodexHookProcessWithBoundedDrain') 'behavior guard 必须复用 bounded native drain。'
Assert-True $behaviorGuardSource.Contains('Write-CodexHookLatestHealthCore') 'behavior guard 必须复用 strict health writer。'
Assert-True (-not $behaviorGuardSource.Contains('VendorPath =')) 'production CLI 不得暴露 vendor path override。'

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

$guardFixtureRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-serena-behavior-fixture'
$guardFixtureHome = Join-Path $guardFixtureRoot '.serena'
$guardHealthRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-health-test'
$runtimePath = 'D:\Codex\projects\统一环境\managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
if (Test-Path -LiteralPath $guardFixtureRoot) { Remove-Item -LiteralPath $guardFixtureRoot -Recurse -Force }
if (Test-Path -LiteralPath $guardHealthRoot) { Remove-Item -LiteralPath $guardHealthRoot -Recurse -Force }
[IO.Directory]::CreateDirectory($guardFixtureRoot) | Out-Null
try {
    . $behaviorGuardPath
    $outsideSentinel = Join-Path $guardFixtureRoot 'outside-sentinel.txt'
    [IO.File]::WriteAllText($outsideSentinel, 'preserve', [Text.UTF8Encoding]::new($false))

    $hookDataRoot = Join-Path $guardFixtureHome 'hook_data'
    $outsideSessionRoot = Join-Path $guardFixtureRoot 'outside-session-state'
    [IO.Directory]::CreateDirectory($hookDataRoot) | Out-Null
    [IO.Directory]::CreateDirectory($outsideSessionRoot) | Out-Null
    $outsideSessionSentinel = Join-Path $outsideSessionRoot 'third-party-sentinel.txt'
    [IO.File]::WriteAllText($outsideSessionSentinel, 'preserve', [Text.UTF8Encoding]::new($false))

    # 缺失 leaf 由 guard 创建后，其逐段目录句柄必须持续阻止删除/替换；否则 vendor 按路径重开时可越界。
    Initialize-CodexSerenaSessionDirectoryGuard
    $raceSessionPath = Join-Path $hookDataRoot 'missing-leaf-race-redacted'
    $raceGuard = [CodexHookRuntime.SerenaSessionDirectoryGuard]::Acquire($guardFixtureRoot, $raceSessionPath)
    try {
        Assert-True (Test-Path -LiteralPath $raceSessionPath -PathType Container) 'guard 必须安全创建缺失 session leaf。'
        & 'C:\Windows\System32\cmd.exe' /d /c rmdir $raceSessionPath 2>$null
        Assert-True ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $raceSessionPath -PathType Container)) 'guard 持有期间必须拒绝删除缺失 leaf 的竞争替换。'
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
        if (Test-Path -LiteralPath $junctionPath) { & 'C:\Windows\System32\cmd.exe' /d /c rmdir $junctionPath | Out-Null }
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
    Assert-True (-not $healthFailure.ok -and $healthFailure.exitCode -eq 0 -and $healthFailure.stdout.Length -eq 0) 'optional health 写入失败必须静默降级。'
    Assert-Throws {
        Invoke-CodexSerenaBehaviorAcceptanceCore -Behavior Activation `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    } 'acceptance'
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
    Assert-Equal ([string]$record.sha256) ((Get-FileHash -LiteralPath $wrapper.path -Algorithm SHA256).Hash.ToLowerInvariant()) "$($wrapper.relative) hash 漂移。"
}

Write-Output 'Codex Serena behavior hook tests passed.'
