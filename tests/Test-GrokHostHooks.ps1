[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedRoot = Join-Path $projectRoot 'managed\grok-hooks'
$python = 'D:\Codex\tools\python314-official\python.exe'
$liveHooksPath = Join-Path $env:USERPROFILE '.grok\hooks\host-lifecycle.json'
$managedHooksPath = Join-Path $managedRoot 'host-lifecycle.json'
$adapterPath = Join-Path $managedRoot 'grok-host-hook.py'
$configPath = Join-Path $env:USERPROFILE '.grok\config.toml'

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
        [AllowEmptyString()][string]$InputText = ''
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
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

Assert-True (Test-Path -LiteralPath $adapterPath -PathType Leaf) '缺少 Grok host hook adapter。'
Assert-True (Test-Path -LiteralPath $managedHooksPath -PathType Leaf) '缺少受管 host-lifecycle.json。'
Assert-True (Test-Path -LiteralPath $liveHooksPath -PathType Leaf) '缺少 Grok 用户级 live host-lifecycle.json。'

$selfTest = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, '--self-test')
Assert-Equal $selfTest.exitCode 0 "adapter --self-test 必须成功。 stderr=$($selfTest.stderr)"

$managedJson = Get-Content -LiteralPath $managedHooksPath -Raw
$liveJson = Get-Content -LiteralPath $liveHooksPath -Raw
Assert-Equal $liveJson.Trim() $managedJson.Trim() 'live ~/.grok/hooks/host-lifecycle.json 必须与受管源一致（忽略首尾空白）。'
Assert-True ($managedJson -notmatch 'codex-state-preflight') 'Grok host-lifecycle 不得注册 Codex state preflight。'
Assert-True ($managedJson -notmatch 'serena-dashboard') 'Grok host-lifecycle 不得注册已退役的 serena-dashboard。'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $managedRoot 'grok-serena-dashboard.cmd'))) '已退役的 grok-serena-dashboard.cmd 不得保留。'
$registry = $managedJson | ConvertFrom-Json
$sessionStart = @($registry.hooks.SessionStart)
Assert-Equal ([int]$sessionStart.Count) 2 'SessionStart 必须只保留 github-cli 与 activation。'
Assert-True ([string]$sessionStart[0].hooks[0].command).EndsWith('\grok-github-cli.cmd') 'session_start[0] 必须指向 github-cli。'
Assert-Equal ([string]$sessionStart[1].matcher) 'startup|resume' 'activation matcher 必须为 startup|resume。'
Assert-True ([string]$sessionStart[1].hooks[0].command).EndsWith('\grok-serena-activation.cmd') 'session_start[1] 必须指向 activation。'

$payload = @{
    hookEventName = 'pre_tool_use'
    sessionId = '01a009aa-3594-7ac2-9c61-36e3cb568878'
    permissionMode = 'auto'
    toolName = 'serena__initial_instructions'
    toolInput = @{}
} | ConvertTo-Json -Compress -Depth 5

$watch = [Diagnostics.Stopwatch]::StartNew()
$approve = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, 'AutoApprove') -InputText $payload
$watch.Stop()
Assert-Equal $approve.exitCode 0 "AutoApprove 必须成功。 stderr=$($approve.stderr)"
$approveJson = $approve.stdout | ConvertFrom-Json
Assert-Equal ([string]$approveJson.decision) 'allow' 'Grok camelCase Serena payload 必须映射后发出 allow。'
Assert-True ($watch.ElapsedMilliseconds -lt 5000) "AutoApprove 必须在 5 秒内返回，actual=$($watch.ElapsedMilliseconds)ms"

$activation = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, 'Activation') -InputText '{"sessionId":"01a009aa-3594-7ac2-9c61-36e3cb568878"}'
Assert-Equal $activation.exitCode 0 "Activation 必须成功。 stderr=$($activation.stderr)"
Assert-True $activation.stdout.Contains('serena__activate_project') 'Activation 必须注入 activate_project。'
Assert-True $activation.stdout.Contains('serena__get_current_config') 'Activation 必须注入 get_current_config。'
Assert-True (-not $activation.stdout.Contains('initial_instructions first')) 'Activation 不得再把 initial_instructions 当成开工门槛。'

$config = Get-Content -LiteralPath $configPath -Raw
Assert-True $config.Contains('MCPTool(serena__*)') 'Grok config 必须允许 serena__* MCP 工具。'
Assert-True $config.Contains('tool_timeout_sec = 45') 'Serena MCP 必须有 45 秒 tool timeout。'
