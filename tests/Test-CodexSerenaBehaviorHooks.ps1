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
Assert-True $reminderSource.Contains('"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-behavior-guard.ps1" -Mode Reminder') 'reminder 必须固定受控 guard 和 Mode。'
Assert-True $cleanupSource.Contains('"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-behavior-guard.ps1" -Mode Cleanup') 'cleanup 必须固定受控 guard 和 Mode。'
Assert-True $activationSource.Contains('"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-behavior-guard.ps1" -Mode Activation') 'activation reminder 必须固定受控 guard 和 Mode。'
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
    $invalidActivation = Invoke-CodexSerenaBehaviorGuardCore -Behavior Activation -InputText '{invalid payload}' `
        -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
    Assert-True (-not $invalidActivation.ok -and $invalidActivation.exitCode -eq 1 -and $invalidActivation.stdout.Length -eq 0) 'activation reminder 必须拒绝畸形 SessionStart payload。'
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
    Assert-True (-not $failedGuard.ok -and $failedGuard.exitCode -eq 1) '错误 payload 必须由 behavior guard 失败关闭。'
    Assert-Equal $failedGuard.stdout.Length 0 'behavior guard 失败不得污染 stdout。'
    Assert-Equal ([string]$failedGuard.error) 'serena behavior hook failed' 'behavior guard 错误必须脱敏。'
    $failureHealth = Get-Content -LiteralPath (Join-Path $guardHealthRoot 'serena-reminder.json') -Raw | ConvertFrom-Json
    Assert-True ($failureHealth.ok -eq $false) 'behavior guard 失败必须写结构化失败 health。'
    Assert-Equal (@($failureHealth.errors) -join ',') 'serena behavior protocol validation failed' '失败 health 不得包含 payload/session/vendor stderr。'
    Remove-Item -LiteralPath $guardHealthRoot -Recurse -Force

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

    foreach ($behavior in @('Reminder','Cleanup','Activation')) {
        $acceptance = Invoke-CodexSerenaBehaviorAcceptanceCore -Behavior $behavior `
            -VendorPath $vendorPath -SerenaHome $guardFixtureHome -RuntimePath $runtimePath -HealthRoot $guardHealthRoot -AllowFixture
        Assert-True ($acceptance.ok -and $acceptance.exitCode -eq 0) "$behavior full acceptance 必须成功。"
        if ($null -ne $acceptance.sessionId) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $guardFixtureHome "hook_data\$($acceptance.sessionId)"))) "$behavior full acceptance 必须清理合成 session state。"
        }
    }

    $successHealth = Get-Content -LiteralPath (Join-Path $guardHealthRoot 'serena-reminder.json') -Raw | ConvertFrom-Json
    Assert-True ($successHealth.ok -eq $true -and @($successHealth.errors).Count -eq 0) '合法 vendor 协议后必须写成功 health。'
}
finally {
    if (Test-Path -LiteralPath $guardFixtureRoot) { Remove-Item -LiteralPath $guardFixtureRoot -Recurse -Force }
    if (Test-Path -LiteralPath $guardHealthRoot) { Remove-Item -LiteralPath $guardHealthRoot -Recurse -Force }
}

$manifestPath = Join-Path $projectRoot 'managed\codex-hooks\manifest.json'
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
Assert-Equal ([string]$hooksById['serena-auto-approve'].lifecycle) 'retired' 'auto-approve 必须保持退役。'

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
