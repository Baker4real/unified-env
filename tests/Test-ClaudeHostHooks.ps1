[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/claude-host-hooks-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedRoot = Join-Path $projectRoot 'managed\claude-hooks'
$node = 'D:\Codex\tools\bin\node.exe'
$guardPath = Join-Path $managedRoot 'claude-pretool-guard.mjs'
$stopHookPath = Join-Path $managedRoot 'claude-stop-handoff-lint.mjs'
$pushGuardPath = Join-Path $managedRoot 'claude-public-push-guard.mjs'
$managedHooksPath = Join-Path $managedRoot 'claude-hooks.json'
$liveSettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message actual=[$Actual] expected=[$Expected]" }
}

# 不给 -Entrypoint 时从子进程环境里去掉 CLAUDE_CODE_ENTRYPOINT，结果不随运行本测试的宿主变化。
function Invoke-Guard([AllowEmptyString()][string]$InputText, [string]$ScriptPath = $guardPath, [string]$Entrypoint) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $node
    if ($Entrypoint) { $startInfo.Environment['CLAUDE_CODE_ENTRYPOINT'] = $Entrypoint }
    else { [void]$startInfo.Environment.Remove('CLAUDE_CODE_ENTRYPOINT') }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    [void]$startInfo.ArgumentList.Add($ScriptPath)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "hook 无法启动：$ScriptPath"
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

# 回收站 API 名拆开拼接：本文件经 pwsh -File 运行时，guard 会扫描它的内容。
$denyCases = @(
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Remove-Item -Recurse -Force D:\tmp\x' } },
    @{ tool_name = 'Bash'; tool_input = @{ command = 'rm -rf node_modules' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'gh issue view 1 --json number,title' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'git clone D:\agents\knowledge-base D:\agents\tmp\kb' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = ('[Native]::SHFile' + 'OperationW([ref]$op)') } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = ('Clear-' + 'RecycleBin -DriveLetter D -Force') } },
    @{ tool_name = 'Bash'; tool_input = @{ command = "ls 'D:\\agents'" } },
    @{ tool_name = 'Bash'; tool_input = @{ command = 'pwsh -NoProfile -Command "Get-Item $env:TEMP"' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'rg -n foo D:\agents\x\*.ps1' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'git status --porcelain | Where-Object { $_ -like ''??*'' }' } }
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
    @{ tool_name = 'Bash'; tool_input = @{ command = 'git clone --no-hardlinks /d/agents/knowledge-base /d/agents/tmp/kb' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = "& 'D:\Codex\.codex\scripts\Invoke-ManagedRecycle.ps1' -Mode Plan -TargetPath D:\x" } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Get-ChildItem -Force -LiteralPath ''D:\$Recycle.Bin''' } },
    @{ tool_name = 'Bash'; tool_input = @{ command = 'pwsh -NoProfile -File ./x.ps1 "$HOME"' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'rg -n foo D:\agents\x -g ''*.ps1''' } },
    @{ tool_name = 'PowerShell'; tool_input = @{ command = 'git status --porcelain | Where-Object { $_.StartsWith(''??'') }' } }
)
foreach ($case in $allowCases) {
    $result = Invoke-Guard ($case | ConvertTo-Json -Compress)
    Assert-Equal $result.exitCode 0 "放行路径必须 exit 0：$($case.tool_input.command)"
    Assert-Equal $result.stdout.Trim() '' "放行时不得输出决定：$($case.tool_input.command)"
}

# 引用脚本扫描走真实文件读取：含回收站调用的 .ps1 被拦，无害内容放行。
$fixtureDir = Join-Path $FixtureRoot ([guid]::NewGuid().ToString('N'))
$fixture = Join-Path $fixtureDir 'recycle.ps1'
$scriptCase = @{ tool_name = 'PowerShell'; tool_input = @{ command = "pwsh -NoProfile -File '$fixture'" } } | ConvertTo-Json -Compress
[void][IO.Directory]::CreateDirectory($fixtureDir)
try {
    [IO.File]::WriteAllText($fixture, ('[Native]::SHFile' + 'OperationW([ref]$op)'), [Text.UTF8Encoding]::new($false))
    $result = Invoke-Guard $scriptCase
    Assert-Equal $result.exitCode 0 '引用脚本 deny 也必须 exit 0。'
    Assert-Equal ($result.stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision 'deny' '引用脚本里的回收站调用必须拦截。'
    [IO.File]::WriteAllText($fixture, 'Get-ChildItem -LiteralPath $PSScriptRoot', [Text.UTF8Encoding]::new($false))
    $result = Invoke-Guard $scriptCase
    Assert-Equal $result.stdout.Trim() '' '无害的引用脚本必须放行。'
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture }
    if (Test-Path -LiteralPath $fixtureDir) { [IO.Directory]::Delete($fixtureDir) }
}

# Claude Desktop 下的 HKCU 写入只在入口变量以 claude-desktop 开头时拦截。写法拆开拼接：
# 本文件经 pwsh -File 运行时，guard 会扫描它的内容。
$hkcuCase = @{ tool_name = 'PowerShell'; tool_input = @{ command = ('Set-Item' + 'Property -LiteralPath ''HK' + 'CU:\Software\X'' -Name a -Value 1') } } | ConvertTo-Json -Compress
$result = Invoke-Guard $hkcuCase -Entrypoint 'claude-desktop'
Assert-Equal $result.exitCode 0 'HKCU 写入 deny 也必须 exit 0。'
Assert-Equal ($result.stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision 'deny' 'Claude Desktop 下的 HKCU 写入必须拦截。'
$result = Invoke-Guard $hkcuCase
Assert-Equal $result.stdout.Trim() '' '没有 Claude Desktop 入口变量时 HKCU 写入放行。'

$garbage = Invoke-Guard 'not json'
Assert-Equal $garbage.exitCode 0 '非 JSON 输入必须放行。'
Assert-Equal $garbage.stdout.Trim() '' '非 JSON 输入不得输出决定。'

# Stop hook：交给用户的命令要同时能被 bash 和 PowerShell 解析，否则拦一次；stop_hook_active 时放行。
Assert-True (Test-Path -LiteralPath $stopHookPath -PathType Leaf) '缺少 claude-stop-handoff-lint.mjs。'
$stopSelfTest = & $node $stopHookPath --self-test
Assert-Equal $LASTEXITCODE 0 "stop hook --self-test 必须成功：$stopSelfTest"
$fence = '```'
$badReply = $fence + "bash`n'D:/x/run.cmd' --dry-run`n" + $fence
$goodReply = $fence + "bash`nD:/x/run.cmd --candidate 'D:/y' --dry-run`n" + $fence
$blocked = Invoke-Guard (@{ hook_event_name = 'Stop'; stop_hook_active = $false; last_assistant_message = $badReply } | ConvertTo-Json -Compress) -ScriptPath $stopHookPath
Assert-Equal $blocked.exitCode 0 'stop hook 拦截也必须 exit 0。'
$decision = $blocked.stdout | ConvertFrom-Json
Assert-Equal $decision.decision 'block' '引号路径开头又跟参数的命令必须拦下。'
Assert-True ($decision.reason -match 'ParserError') '拦截原因必须说明 PowerShell 报 ParserError。'
foreach ($allowStop in @(
        @{ hook_event_name = 'Stop'; stop_hook_active = $true; last_assistant_message = $badReply },
        @{ hook_event_name = 'Stop'; stop_hook_active = $false; last_assistant_message = $goodReply }
    )) {
    $result = Invoke-Guard ($allowStop | ConvertTo-Json -Compress) -ScriptPath $stopHookPath
    Assert-Equal $result.exitCode 0 'stop hook 放行必须 exit 0。'
    Assert-Equal $result.stdout.Trim() '' "stop hook 放行时不得输出决定：stop_hook_active=$($allowStop.stop_hook_active)"
}
$stopGarbage = Invoke-Guard 'not json' -ScriptPath $stopHookPath
Assert-Equal $stopGarbage.stdout.Trim() '' 'stop hook 遇到非 JSON 输入必须放行。'

# 公开仓库推送 guard：夹具仓库建一次后保留复用（不递归删除），提交里埋一个 Tailscale 地址（拼接写，本文件推到公开仓库
# 时不被自己拦下），远端指向不存在的 GitHub 仓库。gh 读不到可见性按公开处理，所以联网与否都应拦下；--dry-run 和确认标记放行。
Assert-True (Test-Path -LiteralPath $pushGuardPath -PathType Leaf) '缺少 claude-public-push-guard.mjs。'
$pushSelfTest = & $node $pushGuardPath --self-test
Assert-Equal $LASTEXITCODE 0 "push guard --self-test 必须成功：$pushSelfTest"
$pushRepo = Join-Path $FixtureRoot 'public-push-guard-repo'
if (-not (Test-Path -LiteralPath (Join-Path $pushRepo '.git'))) {
    [void][IO.Directory]::CreateDirectory($pushRepo)
    git -C $pushRepo init -q -b main
    git -C $pushRepo config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $pushRepo 'hosts.md'), ('- node: 100.' + "101.2.3`n"), [Text.UTF8Encoding]::new($false))
    git -C $pushRepo add hosts.md
    git -C $pushRepo -c user.name=probe -c user.email=1+probe@users.noreply.github.com commit -q -m 'docs: hosts'
    git -C $pushRepo remote add origin 'https://github.com/Baker4real/push-guard-probe-nonexistent.git'
}
$pushCommand = "git -C '$pushRepo' push origin main"
$pushDenied = Invoke-Guard (@{ tool_name = 'PowerShell'; tool_input = @{ command = $pushCommand } } | ConvertTo-Json -Compress) -ScriptPath $pushGuardPath
Assert-Equal $pushDenied.exitCode 0 'push guard 拦截也必须 exit 0。'
$pushDecision = ($pushDenied.stdout | ConvertFrom-Json).hookSpecificOutput
Assert-Equal $pushDecision.permissionDecision 'deny' '推到公开或可见性未知的 GitHub 仓库时，新提交里的 Tailscale 地址必须拦下。'
Assert-True ($pushDecision.permissionDecisionReason -match 'fp=aec3a99b70' -and $pushDecision.permissionDecisionReason -notmatch ('100\.' + '101\.2\.3')) '拦截理由必须给指纹并遮掩原值。'
foreach ($pushAllowed in @("$pushCommand --dry-run", "$pushCommand # PUSH_PRIVACY_ACK=aec3a99b70")) {
    $result = Invoke-Guard (@{ tool_name = 'PowerShell'; tool_input = @{ command = $pushAllowed } } | ConvertTo-Json -Compress) -ScriptPath $pushGuardPath
    Assert-Equal $result.stdout.Trim() '' "push guard 必须放行：$pushAllowed"
}
$pushGarbage = Invoke-Guard 'not json' -ScriptPath $pushGuardPath
Assert-Equal $pushGarbage.stdout.Trim() '' 'push guard 遇到非 JSON 输入必须放行。'

$managed = Get-Content -LiteralPath $managedHooksPath -Raw | ConvertFrom-Json
$registration = @($managed.PreToolUse)
Assert-Equal $registration.Count 1 '受管注册只含一条 PreToolUse。'
Assert-Equal $registration[0].matcher 'PowerShell|Bash' 'matcher 必须覆盖 PowerShell 与 Bash。'
$hook = @($registration[0].hooks)[0]
Assert-Equal $hook.command $node 'hook 必须用受管 node 的 exec 形式。'
Assert-Equal @($hook.args)[0] $guardPath 'hook 参数必须指向受管 guard。'
Assert-Equal $hook.onFailure 'continue' 'guard 自身故障必须放行（onFailure=continue）。'
Assert-Equal @($registration[0].hooks).Count 2 'PreToolUse 只挂 guard 与 push guard 两个 hook。'
$pushHook = @($registration[0].hooks)[1]
Assert-Equal $pushHook.command $node 'push guard 必须用受管 node 的 exec 形式。'
Assert-Equal @($pushHook.args)[0] $pushGuardPath 'push guard 参数必须指向受管脚本。'
Assert-Equal $pushHook.onFailure 'continue' 'push guard 自身故障必须放行（onFailure=continue）。'
Assert-Equal $pushHook.timeout 30 'push guard 要给流式扫描和 gh 可见性查询留 30 秒。'
$stopRegistration = @($managed.Stop)
Assert-Equal $stopRegistration.Count 1 '受管注册只含一条 Stop。'
$stopHook = @($stopRegistration[0].hooks)[0]
Assert-Equal $stopHook.command $node 'Stop hook 必须用受管 node 的 exec 形式。'
Assert-Equal @($stopHook.args)[0] $stopHookPath 'Stop hook 参数必须指向受管 lint。'

if (Test-Path -LiteralPath $liveSettingsPath -PathType Leaf) {
    $live = Get-Content -LiteralPath $liveSettingsPath -Raw | ConvertFrom-Json
    Assert-True ($null -ne $live.hooks) 'live settings.json 缺少 hooks。'
    $liveJson = ($live.hooks | ConvertTo-Json -Depth 10 -Compress)
    $managedJson = ($managed | ConvertTo-Json -Depth 10 -Compress)
    Assert-Equal $liveJson $managedJson 'live ~/.claude/settings.json 的 hooks 必须与受管 claude-hooks.json 一致。'
}

Write-Output 'Test-ClaudeHostHooks: OK'
