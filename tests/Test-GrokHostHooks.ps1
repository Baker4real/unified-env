[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionProjectRoot = 'D:\agents\projects\统一环境'
$managedRoot = Join-Path $projectRoot 'managed\grok-hooks'
$registeredRoot = Join-Path $productionProjectRoot 'managed\grok-hooks'
$python = 'D:\Codex\tools\python315-official\python.exe'
$pythonw = 'D:\Codex\tools\python315-official\pythonw.exe'
$pwsh = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$hiddenLauncher = 'D:\Codex\.codex\hooks\lib\hidden-console-launcher.py'
$githubCliGuard = 'D:\Codex\.codex\hooks\codex-github-cli-guard.ps1'
$liveHooksPath = Join-Path $env:USERPROFILE '.grok\hooks\host-lifecycle.json'
$managedHooksPath = Join-Path $managedRoot 'host-lifecycle.json'
$adapterPath = Join-Path $managedRoot 'grok-host-hook.py'
$registeredAdapterPath = Join-Path $registeredRoot 'grok-host-hook.py'
$configPath = Join-Path $env:USERPROFILE '.grok\config.toml'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message actual=[$Actual] expected=[$Expected]" }
}

function Assert-StringArrayEqual([string[]]$Actual, [string[]]$Expected, [string]$Message) {
    if ($Actual.Count -ne $Expected.Count) {
        throw "$Message count actual=$($Actual.Count) expected=$($Expected.Count) actual=[$($Actual -join ' ')] expected=[$($Expected -join ' ')]"
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($Actual[$i] -cne $Expected[$i]) {
            throw "$Message index=$i actual=[$($Actual[$i])] expected=[$($Expected[$i])]"
        }
    }
}

function Invoke-ChildProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) { $startInfo.Environment[[string]$name] = [string]$Environment[$name] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "子进程无法启动：$FilePath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(15000)) "子进程超时：$FilePath"
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
            durationMs = 0
        }
    }
    finally { $process.Dispose() }
}

function Resolve-TestHookArguments {
    param([Parameter(Mandatory)][string[]]$RegisteredArguments)
    $resolved = @(foreach ($item in $RegisteredArguments) {
        if ($item -ieq $registeredAdapterPath) { $adapterPath } else { $item }
    })
    return $resolved
}

Assert-True (Test-Path -LiteralPath $adapterPath -PathType Leaf) '缺少 Grok host hook adapter。'
Assert-True (Test-Path -LiteralPath $managedHooksPath -PathType Leaf) '缺少受管 host-lifecycle.json。'
Assert-True (Test-Path -LiteralPath $hiddenLauncher -PathType Leaf) '缺少受管 hidden-console-launcher.py。'

foreach ($retiredWrapper in @(
    'grok-github-cli.cmd',
    'grok-serena-activation.cmd',
    'grok-serena-cleanup.cmd',
    'grok-serena-reminder.cmd',
    'grok-serena-auto-approve.cmd',
    'grok-serena-dashboard.cmd'
)) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managedRoot $retiredWrapper))) "已退役的批处理包装器不得保留：$retiredWrapper"
}
$remainingCmds = @(Get-ChildItem -LiteralPath $managedRoot -Filter '*.cmd' -File)
$remainingCmdNames = @($remainingCmds | ForEach-Object { $_.Name }) -join ','
Assert-Equal $remainingCmds.Count 0 "managed/grok-hooks 不得残留任何 .cmd 文件：$remainingCmdNames"

$selfTest = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, '--self-test')
Assert-Equal $selfTest.exitCode 0 "adapter --self-test 必须成功。 stderr=$($selfTest.stderr)"

$managedJson = Get-Content -LiteralPath $managedHooksPath -Raw
Assert-True ($managedJson -notmatch 'codex-state-preflight') 'Grok host-lifecycle 不得注册 Codex state preflight。'
Assert-True ($managedJson -notmatch 'serena-dashboard') 'Grok host-lifecycle 不得注册已退役的 serena-dashboard。'
Assert-True ($managedJson -notmatch '(?i)cmd\.exe|\.cmd') 'Grok host-lifecycle 不得经 cmd.exe 或 .cmd 批处理启动。'

if (-not $projectRoot.Equals($productionProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Output "Test-GrokHostHooks: 本次从 $projectRoot 运行，不是正式检出，跳过 live host-lifecycle.json 比对。"
} else {
    Assert-True (Test-Path -LiteralPath $liveHooksPath -PathType Leaf) '缺少 Grok 用户级 live host-lifecycle.json。'
    $liveJson = Get-Content -LiteralPath $liveHooksPath -Raw
    Assert-Equal $liveJson.Trim() $managedJson.Trim() 'live ~/.grok/hooks/host-lifecycle.json 必须与受管源一致（忽略首尾空白）。'
}

$registry = $managedJson | ConvertFrom-Json
$eventNames = @($registry.hooks.PSObject.Properties.Name)
Assert-True ($eventNames -notcontains 'Stop') '不得把 Serena cleanup 挂到 Grok Stop。'

$sessionStart = @($registry.hooks.SessionStart)
$sessionEnd = @($registry.hooks.SessionEnd)
$preToolUse = @($registry.hooks.PreToolUse)
Assert-Equal $sessionStart.Count 2 'SessionStart 必须只保留 github-cli 与 activation。'
Assert-Equal $sessionEnd.Count 1 'SessionEnd 必须只保留 cleanup。'
Assert-Equal $preToolUse.Count 2 'PreToolUse 必须只保留 reminder 与 auto-approve。'

$expectedGithubCliArgs = @(
    '-I', '-S', '-B', '-X', 'utf8',
    $hiddenLauncher,
    $pwsh,
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $githubCliGuard
)
$githubHook = @($sessionStart[0].hooks)[0]
Assert-Equal ([string]$githubHook.type) 'command' 'SessionStart[0] type 必须为 command。'
Assert-Equal ([string]$githubHook.command) $pythonw 'SessionStart[0] 必须以 exec 形式直接调用 pythonw.exe。'
Assert-StringArrayEqual ([string[]]@($githubHook.args)) $expectedGithubCliArgs 'SessionStart[0] args 必须通过 hidden-console-launcher 调用 codex-github-cli-guard.ps1。'
Assert-Equal ([int]$githubHook.timeout) 10 'SessionStart[0] timeout 必须为 10。'

$expectedAdapterHooks = @(
    @{ label = 'SessionStart[1]'; group = $sessionStart[1]; matcher = 'startup|resume'; mode = 'Activation' },
    @{ label = 'SessionEnd[0]'; group = $sessionEnd[0]; matcher = $null; mode = 'Cleanup' },
    @{ label = 'PreToolUse[0]'; group = $preToolUse[0]; matcher = 'Bash|Grep|Read'; mode = 'Reminder' },
    @{ label = 'PreToolUse[1]'; group = $preToolUse[1]; matcher = 'serena__.*|mcp__serena__.*'; mode = 'AutoApprove' }
)
foreach ($spec in $expectedAdapterHooks) {
    if ($null -ne $spec.matcher) {
        Assert-Equal ([string]$spec.group.matcher) $spec.matcher "$($spec.label) matcher 不符。"
    }
    $entry = @($spec.group.hooks)[0]
    Assert-Equal ([string]$entry.type) 'command' "$($spec.label) type 必须为 command。"
    Assert-Equal ([string]$entry.command) $pythonw "$($spec.label) 必须以 exec 形式直接调用 pythonw.exe。"
    $expectedArgs = @(
        '-I', '-S', '-B', '-X', 'utf8',
        $hiddenLauncher,
        $python,
        '-I', '-S', '-B', '-X', 'utf8',
        $registeredAdapterPath,
        $spec.mode
    )
    Assert-StringArrayEqual ([string[]]@($entry.args)) $expectedArgs "$($spec.label) args 必须固定 hidden-console-launcher 与 mode=$($spec.mode)。"
    Assert-Equal ([int]$entry.timeout) 10 "$($spec.label) timeout 必须为 10。"
}

# 验证最终子进程（Python 与 PowerShell）经注册入口形态运行时的无窗口句柄、JSON 协议流与非零退出码透传
$pythonProbeCode = 'import ctypes,json,sys; data=json.loads(sys.stdin.buffer.read().decode("utf-8-sig")); sys.stdout.write(json.dumps({"echo":data,"windowHandle":ctypes.windll.kernel32.GetConsoleWindow()},ensure_ascii=False)); sys.stderr.write("grok-python-probe-stderr"); raise SystemExit(23)'
$pythonProbe = Invoke-ChildProcess `
    -FilePath $pythonw `
    -Arguments @('-I', '-S', '-B', '-X', 'utf8', $hiddenLauncher, $python, '-I', '-S', '-B', '-X', 'utf8', '-c', $pythonProbeCode) `
    -InputText '{"sessionId":"probe-py","text":"中文"}'
Assert-Equal $pythonProbe.exitCode 23 "Python 入口非零退出码未透传。 stderr=$($pythonProbe.stderr)"
Assert-True ($pythonProbe.stderr.Contains('grok-python-probe-stderr')) "Python 入口 stderr 未透传：$($pythonProbe.stderr)"
$pythonProbeJson = $pythonProbe.stdout | ConvertFrom-Json
Assert-Equal ([int64]$pythonProbeJson.windowHandle) ([int64]0) "Python 最终子进程 GetConsoleWindow 必须为 0：$($pythonProbe.stdout)"
Assert-Equal ([string]$pythonProbeJson.echo.sessionId) 'probe-py' 'Python 入口 stdin/stdout JSON 协议不完整。'

$pwshProbeCode = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GrokPwshConsoleProbe {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
$raw = [Console]::In.ReadToEnd()
$payload = $raw | ConvertFrom-Json
[Console]::Out.Write(([ordered]@{ sessionId = $payload.sessionId; windowHandle = [GrokPwshConsoleProbe]::GetConsoleWindow().ToInt64() } | ConvertTo-Json -Compress))
[Console]::Error.Write('grok-pwsh-probe-stderr')
exit 24
'@
$pwshProbeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pwshProbeCode))
$pwshProbe = Invoke-ChildProcess `
    -FilePath $pythonw `
    -Arguments @('-I', '-S', '-B', '-X', 'utf8', $hiddenLauncher, $pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $pwshProbeEncoded) `
    -InputText '{"sessionId":"probe-pwsh"}'
Assert-Equal $pwshProbe.exitCode 24 "PowerShell 入口非零退出码未透传。 stderr=$($pwshProbe.stderr)"
Assert-True ($pwshProbe.stderr.Contains('grok-pwsh-probe-stderr')) "PowerShell 入口 stderr 未透传：$($pwshProbe.stderr)"
$pwshProbeJson = $pwshProbe.stdout | ConvertFrom-Json
Assert-Equal ([int64]$pwshProbeJson.windowHandle) ([int64]0) "PowerShell 最终子进程 GetConsoleWindow 必须为 0：$($pwshProbe.stdout)"
Assert-Equal ([string]$pwshProbeJson.sessionId) 'probe-pwsh' 'PowerShell 入口 stdin/stdout JSON 协议不完整。'

# 非法 mode 经 hidden-console-launcher 返回非零退出码 1
$invalidMode = Invoke-ChildProcess `
    -FilePath $pythonw `
    -Arguments @('-I', '-S', '-B', '-X', 'utf8', $hiddenLauncher, $python, '-I', '-S', '-B', '-X', 'utf8', $adapterPath, 'InvalidMode')
Assert-Equal $invalidMode.exitCode 1 "adapter 非法 mode 的非零退出码必须透传。 stderr=$($invalidMode.stderr)"
Assert-True ($invalidMode.stderr.Contains('grok host hook mode required')) "adapter 非法 mode 必须保留 stderr 诊断：$($invalidMode.stderr)"

$pollutedEnv = @{ SERENA_HOME = 'D:\Codex\temp\polluted-serena-home-must-not-be-used' }

$payload = @{
    hookEventName = 'pre_tool_use'
    sessionId = '01a009aa-3594-7ac2-9c61-36e3cb568878'
    permissionMode = 'auto'
    toolName = 'serena__initial_instructions'
    toolInput = @{}
} | ConvertTo-Json -Compress -Depth 5

$autoApproveEntry = @($preToolUse[1].hooks)[0]
$watch = [Diagnostics.Stopwatch]::StartNew()
$approve = Invoke-ChildProcess `
    -FilePath ([string]$autoApproveEntry.command) `
    -Arguments (Resolve-TestHookArguments -RegisteredArguments ([string[]]@($autoApproveEntry.args))) `
    -InputText $payload `
    -Environment $pollutedEnv
$watch.Stop()
Assert-Equal $approve.exitCode 0 "AutoApprove 必须成功。 stderr=$($approve.stderr)"
$approveJson = $approve.stdout | ConvertFrom-Json
Assert-Equal ([string]$approveJson.decision) 'allow' 'Grok camelCase Serena payload 必须映射后发出 allow。'
Assert-True ($watch.ElapsedMilliseconds -lt 5000) "AutoApprove 必须在 5 秒内返回，actual=$($watch.ElapsedMilliseconds)ms"

$activationEntry = @($sessionStart[1].hooks)[0]
$activation = Invoke-ChildProcess `
    -FilePath ([string]$activationEntry.command) `
    -Arguments (Resolve-TestHookArguments -RegisteredArguments ([string[]]@($activationEntry.args))) `
    -InputText '{"sessionId":"01a009aa-3594-7ac2-9c61-36e3cb568878"}' `
    -Environment $pollutedEnv
Assert-Equal $activation.exitCode 0 "Activation 必须成功。 stderr=$($activation.stderr)"
Assert-True $activation.stdout.Contains('serena__activate_project') 'Activation 必须注入 activate_project。'
Assert-True $activation.stdout.Contains('serena__get_current_config') 'Activation 必须注入 get_current_config。'
Assert-True (-not $activation.stdout.Contains('initial_instructions first')) 'Activation 不得再把 initial_instructions 当成开工门槛。'

$cleanupEntry = @($sessionEnd[0].hooks)[0]
$cleanup = Invoke-ChildProcess `
    -FilePath ([string]$cleanupEntry.command) `
    -Arguments (Resolve-TestHookArguments -RegisteredArguments ([string[]]@($cleanupEntry.args))) `
    -InputText '{"sessionId":"01a009aa-3594-7ac2-9c61-36e3cb568878","subagentType":"explore"}' `
    -Environment $pollutedEnv
Assert-Equal $cleanup.exitCode 0 "Cleanup 必须成功。 stderr=$($cleanup.stderr)"
Assert-Equal $cleanup.stdout.Trim() '' 'subagent Cleanup 不得输出多余内容。'

$reminderEntry = @($preToolUse[0].hooks)[0]
$reminderFailOpen = Invoke-ChildProcess `
    -FilePath ([string]$reminderEntry.command) `
    -Arguments (Resolve-TestHookArguments -RegisteredArguments ([string[]]@($reminderEntry.args))) `
    -InputText '{not-json}' `
    -Environment $pollutedEnv
Assert-Equal $reminderFailOpen.exitCode 0 "Reminder 非法 payload 必须 fail open。 stderr=$($reminderFailOpen.stderr)"
Assert-Equal $reminderFailOpen.stdout.Trim() '' 'Reminder 非法 payload 不得输出决定。'

$githubRun = Invoke-ChildProcess `
    -FilePath ([string]$githubHook.command) `
    -Arguments ([string[]]@($githubHook.args)) `
    -InputText '{}'
Assert-Equal $githubRun.exitCode 0 "Grok github-cli 入口必须成功。 stderr=$($githubRun.stderr)"

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $config = Get-Content -LiteralPath $configPath -Raw
    Assert-True $config.Contains('MCPTool(serena__*)') 'Grok config 必须允许 serena__* MCP 工具。'
    Assert-True $config.Contains('tool_timeout_sec = 45') 'Serena MCP 必须有 45 秒 tool timeout。'
}

Write-Output 'Test-GrokHostHooks: OK'
