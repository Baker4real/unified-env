[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionProjectRoot = 'D:\agents\projects\统一环境'
$managedRoot = Join-Path $projectRoot 'managed\cursor-hooks'
$registeredRoot = Join-Path $productionProjectRoot 'managed\cursor-hooks'
$python = 'D:\Codex\tools\python315-official\python.exe'
$pythonw = 'D:\Codex\tools\python315-official\pythonw.exe'
$pwsh = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$hiddenLauncher = 'D:\Codex\.codex\hooks\lib\hidden-console-launcher.py'
$liveHooksPath = Join-Path $env:USERPROFILE '.cursor\hooks.json'
$managedHooksPath = Join-Path $managedRoot 'hooks.json'
$adapterPath = Join-Path $managedRoot 'cursor-host-hook.py'
$registeredAdapterPath = Join-Path $registeredRoot 'cursor-host-hook.py'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message actual=[$Actual] expected=[$Expected]" }
}

function Invoke-ChildProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [AllowEmptyString()][string]$RawArguments,
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
    if ($PSBoundParameters.ContainsKey('RawArguments')) {
        $startInfo.Arguments = $RawArguments
    } else {
        foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    }
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
        }
    }
    finally { $process.Dispose() }
}

function Invoke-CmdRawCursorCommand {
    param(
        [Parameter(Mandatory)][string]$CommandText,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    $remapped = $CommandText.Replace($registeredAdapterPath, $adapterPath)
    Invoke-ChildProcess `
        -FilePath 'C:\Windows\System32\cmd.exe' `
        -RawArguments ('/d /c ' + $remapped) `
        -InputText $InputText `
        -Environment $Environment
}

function Invoke-RegisteredCursorCommand {
    param(
        [Parameter(Mandatory)][string]$CommandText,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    $tokens = @($CommandText -split ' ' | Where-Object { -not [string]::IsNullOrEmpty($_) })
    Assert-True ($tokens.Count -ge 2) "Cursor hook command token 数量不足：$CommandText"
    $executable = $tokens[0]
    $argsList = @(foreach ($token in @($tokens | Select-Object -Skip 1)) {
        if ($token -ieq $registeredAdapterPath) { $adapterPath } else { $token }
    })
    Invoke-ChildProcess -FilePath $executable -Arguments $argsList -InputText $InputText -Environment $Environment
}

Assert-True (Test-Path -LiteralPath $adapterPath -PathType Leaf) '缺少 Cursor host hook adapter。'
Assert-True (Test-Path -LiteralPath $managedHooksPath -PathType Leaf) '缺少 Cursor 受管 hooks.json。'
Assert-True (Test-Path -LiteralPath $hiddenLauncher -PathType Leaf) '缺少受管 hidden-console-launcher.py。'

foreach ($retiredWrapper in @(
    'cursor-serena-activation.cmd',
    'cursor-serena-cleanup.cmd',
    'cursor-serena-reminder.cmd',
    'cursor-serena-auto-approve.cmd',
    'cursor-github-cli.cmd',
    'cursor-serena-dashboard.cmd'
)) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $managedRoot $retiredWrapper))) "已退役的批处理包装器不得保留：$retiredWrapper"
}
$remainingCmds = @(Get-ChildItem -LiteralPath $managedRoot -Filter '*.cmd' -File)
$remainingCmdNames = @($remainingCmds | ForEach-Object { $_.Name }) -join ','
Assert-Equal $remainingCmds.Count 0 "managed/cursor-hooks 不得残留任何 .cmd 文件：$remainingCmdNames"

$selfTest = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, '--self-test')
Assert-Equal $selfTest.exitCode 0 "adapter --self-test 必须成功。 stderr=$($selfTest.stderr)"

$managedJson = Get-Content -LiteralPath $managedHooksPath -Raw
Assert-True ($managedJson -notmatch 'serena-dashboard') 'Cursor hooks.json 不得注册已退役的 serena-dashboard。'
Assert-True ($managedJson -notmatch '(?i)cmd\.exe|\.cmd') 'Cursor hooks.json 不得经 cmd.exe 或 .cmd 批处理启动。'

if (-not $projectRoot.Equals($productionProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Output "Test-CursorHostHooks: 本次从 $projectRoot 运行，不是正式检出，跳过 live hooks.json 比对。"
} elseif (Test-Path -LiteralPath $liveHooksPath -PathType Leaf) {
    $liveJson = Get-Content -LiteralPath $liveHooksPath -Raw
    Assert-Equal $liveJson.Trim() $managedJson.Trim() 'live ~/.cursor/hooks.json 必须与受管源字节一致（忽略首尾空白）。'
} else {
    Write-Output 'Test-CursorHostHooks: 未检测到 live ~/.cursor/hooks.json，跳过 live 比对。'
}

$registry = $managedJson | ConvertFrom-Json
Assert-Equal ([int]$registry.version) 1 'Cursor hooks.json version 必须为 1。'
$hookNames = @($registry.hooks.PSObject.Properties.Name)
foreach ($required in @('workspaceOpen', 'sessionStart', 'sessionEnd', 'preToolUse', 'beforeMCPExecution')) {
    Assert-True ($hookNames -contains $required) "必须注册 $required。"
}
Assert-True ($hookNames -notcontains 'stop') '不得把 Serena cleanup 挂到 Cursor stop。'
Assert-Equal ([int]@($registry.hooks.workspaceOpen).Count) 1 'workspaceOpen 必须只保留 github-cli。'
Assert-Equal ([string]$registry.hooks.preToolUse[0].matcher) 'Shell|Grep|Read' 'reminder matcher 必须覆盖 Cursor Shell/Grep/Read。'

$expectedHooks = @(
    @{ event = 'workspaceOpen'; mode = 'GitHubCli' },
    @{ event = 'sessionStart'; mode = 'Activation' },
    @{ event = 'sessionEnd'; mode = 'Cleanup' },
    @{ event = 'preToolUse'; mode = 'Reminder' },
    @{ event = 'beforeMCPExecution'; mode = 'AutoApprove' }
)
foreach ($spec in $expectedHooks) {
    $entry = @($registry.hooks.($spec.event))[0]
    $command = [string]$entry.command
    Assert-True (-not ($command.StartsWith('"') -or $command.StartsWith("'"))) "$($spec.event) command 不得以引号开头（否则 cursor-agent q3 会注入 & 前缀）。"
    $expectedCommand = "$pythonw -I -S -B -X utf8 $hiddenLauncher $python -I -S -B -X utf8 $registeredAdapterPath $($spec.mode)"
    Assert-Equal $command $expectedCommand "$($spec.event) 必须通过 pythonw + hidden-console-launcher 直调 $($spec.mode)。"
    Assert-Equal ([int]$entry.timeout) 10 "$($spec.event) timeout 必须为 10。"
}

# 验证最终 Python 子进程经注册入口形态运行时的无窗口句柄、JSON 协议流与非零退出码透传
$probeCode = 'import ctypes,json,sys; data=json.loads(sys.stdin.buffer.read().decode("utf-8-sig")); sys.stdout.write(json.dumps({"echo":data,"windowHandle":ctypes.windll.kernel32.GetConsoleWindow()},ensure_ascii=False)); sys.stderr.write("cursor-python-probe-stderr"); raise SystemExit(23)'
$probe = Invoke-ChildProcess `
    -FilePath $pythonw `
    -Arguments @('-I', '-S', '-B', '-X', 'utf8', $hiddenLauncher, $python, '-I', '-S', '-B', '-X', 'utf8', '-c', $probeCode) `
    -InputText '{"session_id":"cursor-probe","text":"中文"}'
Assert-Equal $probe.exitCode 23 "Cursor 入口非零退出码未透传。 stderr=$($probe.stderr)"
Assert-True ($probe.stderr.Contains('cursor-python-probe-stderr')) "Cursor 入口 stderr 未透传：$($probe.stderr)"
$probeJson = $probe.stdout | ConvertFrom-Json
Assert-Equal ([int64]$probeJson.windowHandle) ([int64]0) "Cursor 最终子进程 GetConsoleWindow 必须为 0：$($probe.stdout)"
Assert-Equal ([string]$probeJson.echo.session_id) 'cursor-probe' 'Cursor 入口 stdin/stdout JSON 协议不完整。'

# 非法 mode 经 hidden-console-launcher 返回非零退出码 1
$invalidMode = Invoke-ChildProcess `
    -FilePath $pythonw `
    -Arguments @('-I', '-S', '-B', '-X', 'utf8', $hiddenLauncher, $python, '-I', '-S', '-B', '-X', 'utf8', $adapterPath, 'InvalidMode')
Assert-Equal $invalidMode.exitCode 1 "adapter 非法 mode 的非零退出码必须透传。 stderr=$($invalidMode.stderr)"
Assert-True ($invalidMode.stderr.Contains('cursor host hook mode required')) "adapter 非法 mode 必须保留 stderr 诊断：$($invalidMode.stderr)"

# 贴合本机 cursor-agent P1：经 cmd.exe /d /c 执行原始 command 字符串验证退出码与 JSON 协议流
$cmdActivation = Invoke-CmdRawCursorCommand `
    -CommandText ([string]$registry.hooks.sessionStart[0].command) `
    -InputText '{"session_id":"cursor-cmd-raw-probe","workspace_roots":["D:\\Codex\\projects\\demo"]}' `
    -Environment @{ SERENA_HOME = 'D:\Codex\temp\polluted-serena-home-must-not-be-used' }
Assert-Equal $cmdActivation.exitCode 0 "cmd.exe /d /c 执行原始 sessionStart 命令必须成功。 stderr=$($cmdActivation.stderr)"
$cmdActivationJson = $cmdActivation.stdout | ConvertFrom-Json
Assert-True ([string]$cmdActivationJson.additional_context).Contains('activate_project') 'cmd.exe /d /c 原始 sessionStart 命令必须返回完整 JSON 协议。'
Assert-Equal ([string]$cmdActivationJson.env.SERENA_HOME) 'D:\Codex\.serena' 'cmd.exe /d /c 原始 sessionStart 命令必须注入 SERENA_HOME。'

$cmdInvalidModeCommand = ([string]$registry.hooks.sessionStart[0].command) -replace ' Activation$', ' InvalidMode'
$cmdInvalidMode = Invoke-CmdRawCursorCommand -CommandText $cmdInvalidModeCommand
Assert-Equal $cmdInvalidMode.exitCode 1 "cmd.exe /d /c 执行原始 command 字符串必须透传非零退出码 1。 stderr=$($cmdInvalidMode.stderr)"
Assert-True ($cmdInvalidMode.stderr.Contains('cursor host hook mode required')) "cmd.exe /d /c 非法 mode 必须保留 stderr 诊断：$($cmdInvalidMode.stderr)"

# 验证 pwsh 子进程经同一 hidden-console-launcher 启动时的 GetConsoleWindow() == 0、协议流与非零退出码
$pwshProbeScript = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CursorPwshConsoleWindowProbe {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
$raw = [Console]::In.ReadToEnd()
$payload = $raw | ConvertFrom-Json
$out = [ordered]@{
    session_id = [string]$payload.session_id
    windowHandle = [CursorPwshConsoleWindowProbe]::GetConsoleWindow().ToInt64()
}
[Console]::Out.Write(($out | ConvertTo-Json -Compress))
[Console]::Error.Write('cursor-pwsh-probe-stderr')
exit 29
'@
$pwshProbeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pwshProbeScript))
$pwshProbe = Invoke-ChildProcess `
    -FilePath $pythonw `
    -Arguments @('-I', '-S', '-B', '-X', 'utf8', $hiddenLauncher, $pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $pwshProbeEncoded) `
    -InputText '{"session_id":"cursor-pwsh-probe"}'
Assert-Equal $pwshProbe.exitCode 29 "Cursor hidden-console-launcher 启动 pwsh 的非零退出码未透传。 stderr=$($pwshProbe.stderr)"
Assert-True ($pwshProbe.stderr.Contains('cursor-pwsh-probe-stderr')) "Cursor pwsh 探针 stderr 未透传：$($pwshProbe.stderr)"
$pwshProbeJson = $pwshProbe.stdout | ConvertFrom-Json
Assert-Equal ([int64]$pwshProbeJson.windowHandle) ([int64]0) "Cursor pwsh 最终子进程 GetConsoleWindow 必须为 0：$($pwshProbe.stdout)"
Assert-Equal ([string]$pwshProbeJson.session_id) 'cursor-pwsh-probe' 'Cursor pwsh 探针 stdin/stdout JSON 协议不完整。'

$pollutedEnv = @{ SERENA_HOME = 'D:\Codex\temp\polluted-serena-home-must-not-be-used' }

$failOpen = Invoke-RegisteredCursorCommand `
    -CommandText ([string]$registry.hooks.preToolUse[0].command) `
    -InputText '{not-json}' `
    -Environment $pollutedEnv
Assert-Equal $failOpen.exitCode 0 '非法 payload 必须 fail open。'
Assert-Equal $failOpen.stdout.Trim() '{}' '非法 payload 必须输出合法空 JSON。'

$activation = Invoke-RegisteredCursorCommand `
    -CommandText ([string]$registry.hooks.sessionStart[0].command) `
    -InputText '{"session_id":"cursor-hook-self-test","workspace_roots":["D:\\Codex\\projects\\demo"]}' `
    -Environment $pollutedEnv
Assert-Equal $activation.exitCode 0 "Activation 必须成功。 stderr=$($activation.stderr)"
$activationJson = $activation.stdout | ConvertFrom-Json
Assert-True ([string]$activationJson.additional_context).Contains('activate_project') 'Activation 必须注入 Cursor Serena 工具名。'
Assert-True ([string]$activationJson.additional_context).Contains('D:\Codex\projects\demo') 'Activation 必须带上 workspace root。'
Assert-Equal ([string]$activationJson.env.SERENA_HOME) 'D:\Codex\.serena' 'Activation 必须设置 SERENA_HOME。'
Assert-True (-not $activation.stdout.Contains('additionalContext')) 'Cursor Activation 不得只输出 Claude additionalContext。'

$autoApprove = Invoke-RegisteredCursorCommand `
    -CommandText ([string]$registry.hooks.beforeMCPExecution[0].command) `
    -InputText '{"conversation_id":"11111111-2222-4333-8444-555555555555","tool_name":"replace_symbol_body"}' `
    -Environment $pollutedEnv
Assert-Equal $autoApprove.exitCode 0 "AutoApprove 必须成功。 stderr=$($autoApprove.stderr)"
$autoApproveJson = $autoApprove.stdout | ConvertFrom-Json
Assert-Equal ([string]$autoApproveJson.permission) 'allow' 'Cursor Serena 工具 AutoApprove 必须返回 allow。'

$cleanup = Invoke-RegisteredCursorCommand `
    -CommandText ([string]$registry.hooks.sessionEnd[0].command) `
    -InputText '{"session_id":"cursor-hook-self-test","subagent_type":"explore"}' `
    -Environment $pollutedEnv
Assert-Equal $cleanup.exitCode 0 "Cleanup 必须成功。 stderr=$($cleanup.stderr)"
Assert-Equal $cleanup.stdout.Trim() '{}' 'subagent Cleanup 必须输出合法空 JSON。'

$githubCli = Invoke-RegisteredCursorCommand `
    -CommandText ([string]$registry.hooks.workspaceOpen[0].command) `
    -InputText '{}'
Assert-Equal $githubCli.exitCode 0 "GitHubCli 必须成功。 stderr=$($githubCli.stderr)"
Assert-Equal $githubCli.stdout.Trim() '{}' 'GitHubCli 必须输出合法空 JSON。'

Write-Output 'Test-CursorHostHooks: OK'
