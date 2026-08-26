[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedRoot = Join-Path $projectRoot 'managed\cursor-hooks'
$python = 'D:\Codex\tools\python314-official\python.exe'
$liveHooksPath = Join-Path $env:USERPROFILE '.cursor\hooks.json'
$managedHooksPath = Join-Path $managedRoot 'hooks.json'
$adapterPath = Join-Path $managedRoot 'cursor-host-hook.py'

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
        }
    }
    finally { $process.Dispose() }
}

Assert-True (Test-Path -LiteralPath $adapterPath -PathType Leaf) '缺少 Cursor host hook adapter。'
Assert-True (Test-Path -LiteralPath $managedHooksPath -PathType Leaf) '缺少 Cursor 受管 hooks.json。'
Assert-True (Test-Path -LiteralPath $liveHooksPath -PathType Leaf) '缺少 Cursor 用户级 live hooks.json。'

$wrappers = @(
    @{ name = 'cursor-serena-activation.cmd'; mode = 'Activation'; serena = $true },
    @{ name = 'cursor-serena-cleanup.cmd'; mode = 'Cleanup'; serena = $true },
    @{ name = 'cursor-serena-reminder.cmd'; mode = 'Reminder'; serena = $true },
    @{ name = 'cursor-serena-auto-approve.cmd'; mode = 'AutoApprove'; serena = $true },
    @{ name = 'cursor-github-cli.cmd'; mode = 'GitHubCli'; serena = $false }
)
foreach ($wrapper in $wrappers) {
    $path = Join-Path $managedRoot $wrapper.name
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "缺少 wrapper：$($wrapper.name)"
    $source = Get-Content -LiteralPath $path -Raw
    Assert-True ($source.Contains('D:\Codex\tools\python314-official\pythonw.exe') -and $source.Contains('lib\hidden-console-launcher.py')) "$($wrapper.name) 必须通过 hidden launcher 启动。"
    Assert-True $source.Contains("%~dp0cursor-host-hook.py`" $($wrapper.mode)") "$($wrapper.name) 必须固定 adapter mode。"
    Assert-True (-not $source.Contains('%*')) "$($wrapper.name) 不得接受外部参数覆盖固定命令。"
    if ([bool]$wrapper.serena) {
        Assert-True $source.Contains('set "SERENA_HOME=D:\Codex\.serena"') "$($wrapper.name) 必须覆盖外部 SERENA_HOME。"
    }
    else {
        Assert-True (-not $source.Contains('SERENA_HOME')) "$($wrapper.name) 不得改写 SERENA_HOME。"
    }
}

$selfTest = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, '--self-test')
Assert-Equal $selfTest.exitCode 0 "adapter --self-test 必须成功。 stderr=$($selfTest.stderr)"

$managedJson = Get-Content -LiteralPath $managedHooksPath -Raw
$liveJson = Get-Content -LiteralPath $liveHooksPath -Raw
Assert-Equal $liveJson.Trim() $managedJson.Trim() 'live ~/.cursor/hooks.json 必须与受管源字节一致（忽略首尾空白）。'

$registry = $managedJson | ConvertFrom-Json
Assert-Equal ([int]$registry.version) 1 'Cursor hooks.json version 必须为 1。'
$hookNames = @($registry.hooks.PSObject.Properties.Name)
foreach ($required in @('workspaceOpen', 'sessionStart', 'sessionEnd', 'preToolUse', 'beforeMCPExecution')) {
    Assert-True ($hookNames -contains $required) "必须注册 $required。"
}
Assert-True ($hookNames -notcontains 'stop') '不得把 Serena cleanup 挂到 Cursor stop。'
Assert-Equal ([string]$registry.hooks.preToolUse[0].matcher) 'Shell|Grep|Read' 'reminder matcher 必须覆盖 Cursor Shell/Grep/Read。'
Assert-True ([string]$registry.hooks.sessionStart[0].command).StartsWith('cmd.exe /c ') 'Windows 注册必须经 cmd.exe 启动 .cmd wrapper。'
Assert-True ([string]$registry.hooks.sessionStart[0].command).EndsWith('\cursor-serena-activation.cmd') 'sessionStart 必须指向 activation wrapper。'
Assert-True ([string]$registry.hooks.sessionEnd[0].command).EndsWith('\cursor-serena-cleanup.cmd') 'sessionEnd 必须指向 cleanup wrapper。'
Assert-True ([string]$registry.hooks.beforeMCPExecution[0].command).EndsWith('\cursor-serena-auto-approve.cmd') 'beforeMCPExecution 必须指向 auto-approve wrapper。'
Assert-True ([string]$registry.hooks.workspaceOpen[0].command).EndsWith('\cursor-github-cli.cmd') 'workspaceOpen[0] 必须指向 github-cli wrapper。'
Assert-Equal ([int]@($registry.hooks.workspaceOpen).Count) 1 'workspaceOpen 必须只保留 github-cli。'
Assert-True ($managedJson -notmatch 'serena-dashboard') 'Cursor hooks.json 不得注册已退役的 serena-dashboard。'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $managedRoot 'cursor-serena-dashboard.cmd'))) '已退役的 cursor-serena-dashboard.cmd 不得保留。'

$failOpen = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, 'Reminder') -InputText '{not-json}'
Assert-Equal $failOpen.exitCode 0 '非法 payload 必须 fail open。'
Assert-Equal $failOpen.stdout.Trim() '{}' '非法 payload 必须输出合法空 JSON。'

$activation = Invoke-ChildProcess -FilePath $python -Arguments @('-I', '-S', '-B', '-X', 'utf8', $adapterPath, 'Activation') -InputText '{"session_id":"cursor-hook-self-test","workspace_roots":["D:\\Codex\\projects\\demo"]}'
Assert-Equal $activation.exitCode 0 "Activation 必须成功。 stderr=$($activation.stderr)"
$activationJson = $activation.stdout | ConvertFrom-Json
Assert-True ([string]$activationJson.additional_context).Contains('activate_project') 'Activation 必须注入 Cursor Serena 工具名。'
Assert-True ([string]$activationJson.additional_context).Contains('D:\Codex\projects\demo') 'Activation 必须带上 workspace root。'
Assert-Equal ([string]$activationJson.env.SERENA_HOME) 'D:\Codex\.serena' 'Activation 必须设置 SERENA_HOME。'
Assert-True (-not $activation.stdout.Contains('additionalContext')) 'Cursor Activation 不得只输出 Claude additionalContext。'
