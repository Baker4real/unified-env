[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedRoot = Join-Path $projectRoot 'managed\claude-hooks'
$node = 'D:\Codex\tools\bin\node.exe'
$guardPath = Join-Path $managedRoot 'claude-pretool-guard.mjs'
$managedHooksPath = Join-Path $managedRoot 'claude-hooks.json'
$liveSettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message actual=[$Actual] expected=[$Expected]" }
}

function Invoke-Guard([AllowEmptyString()][string]$InputText) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $node
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    [void]$startInfo.ArgumentList.Add($guardPath)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "guard 无法启动：$guardPath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(15000)) 'guard 超时'
        return [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $stdoutTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

Assert-True (Test-Path -LiteralPath $guardPath -PathType Leaf) '缺少 claude-pretool-guard.mjs。'
Assert-True (Test-Path -LiteralPath $managedHooksPath -PathType Leaf) '缺少受管 claude-hooks.json。'

$selfTest = & $node $guardPath --self-test
Assert-Equal $LASTEXITCODE 0 "guard --self-test 必须成功：$selfTest"

$denyCases = @(
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Remove-Item -Recurse -Force D:\tmp\x' } },
    @{ tool_name = 'Bash'; tool_input = @{ command = 'rm -rf node_modules' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'gh issue view 1 --json number,title' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'git clone D:\agents\knowledge-base D:\agents\tmp\kb' } }
)
foreach ($case in $denyCases) {
    $result = Invoke-Guard ($case | ConvertTo-Json -Compress)
    Assert-Equal $result.exitCode 0 "deny 路径也必须 exit 0：$($case.tool_input.command)"
    $decision = ($result.stdout | ConvertFrom-Json).hookSpecificOutput
    Assert-Equal $decision.hookEventName 'PreToolUse' 'deny 输出必须是 PreToolUse 决定。'
    Assert-Equal $decision.permissionDecision 'deny' "必须拦截：$($case.tool_input.command)"
}

$allowCases = @(
    @{ tool_name = 'PowerShell'; tool_input = @{ command = "& 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1' -Mode Plan" } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = "gh issue view 1 --json 'number,title'" } },
    @{ tool_name = 'Bash'; tool_input = @{ command = 'git status' } },
    @{ tool_name = 'Bash'; tool_input = @{ command = 'git clone --no-hardlinks /d/agents/knowledge-base /d/agents/tmp/kb' } }
)
foreach ($case in $allowCases) {
    $result = Invoke-Guard ($case | ConvertTo-Json -Compress)
    Assert-Equal $result.exitCode 0 "放行路径必须 exit 0：$($case.tool_input.command)"
    Assert-Equal $result.stdout.Trim() '' "放行时不得输出决定：$($case.tool_input.command)"
}

$garbage = Invoke-Guard 'not json'
Assert-Equal $garbage.exitCode 0 '非 JSON 输入必须放行。'
Assert-Equal $garbage.stdout.Trim() '' '非 JSON 输入不得输出决定。'

$managed = Get-Content -LiteralPath $managedHooksPath -Raw | ConvertFrom-Json
$registration = @($managed.PreToolUse)
Assert-Equal $registration.Count 1 '受管注册只含一条 PreToolUse。'
Assert-Equal $registration[0].matcher 'PowerShell|Bash' 'matcher 必须覆盖 PowerShell 与 Bash。'
$hook = @($registration[0].hooks)[0]
Assert-Equal $hook.command $node 'hook 必须用受管 node 的 exec 形式。'
Assert-Equal @($hook.args)[0] $guardPath 'hook 参数必须指向受管 guard。'
Assert-Equal $hook.onFailure 'continue' 'guard 自身故障必须放行（onFailure=continue）。'

if (Test-Path -LiteralPath $liveSettingsPath -PathType Leaf) {
    $live = Get-Content -LiteralPath $liveSettingsPath -Raw | ConvertFrom-Json
    Assert-True ($null -ne $live.hooks) 'live settings.json 缺少 hooks。'
    $liveJson = ($live.hooks | ConvertTo-Json -Depth 10 -Compress)
    $managedJson = ($managed | ConvertTo-Json -Depth 10 -Compress)
    Assert-Equal $liveJson $managedJson 'live ~/.claude/settings.json 的 hooks 必须与受管 claude-hooks.json 一致。'
}

Write-Output 'Test-ClaudeHostHooks: OK'
