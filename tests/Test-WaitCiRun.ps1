[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/wait-ci-run-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# scripts\Wait-CiRun.ps1 对替身 gh 运行。脚本没有替身 seam：PATH 最前面放一个转发到替身的 gh.cmd，每个场景都先确认
# 解析到它，免得真 gh 发出请求。替身按顺序回放 run list 的结果（用完后重复最后一个），实现 run view 9001 --json …
# 与 --log-failed（失败摘要要用），并记下每次调用的路由。夹具目录复用，各场景只覆盖写单个文件，不递归删除。
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$waitScript = Join-Path $projectRoot 'scripts\Wait-CiRun.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
# 子进程按 UTF-8 输出中文，捕获时按 UTF-8 解码。
[Console]::OutputEncoding = $utf8
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$fakeGhPath = Join-Path $FixtureRoot 'fake-gh.ps1'
$statePath = Join-Path $FixtureRoot 'state.json'
$logPath = Join-Path $FixtureRoot 'log-failed.txt'
$pathGhRoot = Join-Path $FixtureRoot 'path-gh'
$pathGhCmd = Join-Path $pathGhRoot 'gh.cmd'
$sha = '0123456789abcdef0123456789abcdef01234567'
$runUrl = 'https://github.com/fixture/repo/actions/runs/9001'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

[IO.File]::WriteAllText($fakeGhPath, @'
$ErrorActionPreference = 'Stop'
# 替身 gh：run list --commit <sha> 按顺序输出 lists，run view 9001 --json … 输出 runJson，--log-failed 输出 logPath 的内容。
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$state = [IO.File]::ReadAllText($env:FAKE_GH_WAIT_STATE, $utf8) | ConvertFrom-Json -AsHashtable
$route = 'unsupported'
if ($args.Count -ge 2 -and [string]$args[0] -ceq 'run' -and [string]$args[1] -ceq 'list') {
    $commit = [array]::IndexOf([string[]]$args, '--commit')
    if ($commit -ge 0 -and $commit + 1 -lt $args.Count -and [string]$args[$commit + 1] -ceq $state['sha']) { $route = 'list' }
} elseif ($args.Count -ge 4 -and [string]$args[0] -ceq 'run' -and [string]$args[1] -ceq 'view' -and [string]$args[2] -ceq '9001') {
    if ([string]$args[3] -ceq '--json') { $route = 'view' } elseif ([string]$args[3] -ceq '--log-failed') { $route = 'log' }
}
$state['calls'] = @($state['calls']) + @($route)
$lists = @($state['lists'])
$listIndex = [Math]::Min(@($state['calls'] | Where-Object { $_ -ceq 'list' }).Count, $lists.Count) - 1
[IO.File]::WriteAllText($env:FAKE_GH_WAIT_STATE, ($state | ConvertTo-Json -Depth 4), $utf8)
if ($state['failing']) {
    [Console]::Error.WriteLine('Get "https://api.github.com/repos/fixture/repo/actions/runs": EOF')
    exit 1
}
if ($route -ceq 'list') { [Console]::Out.WriteLine($lists[$listIndex]) }
elseif ($route -ceq 'view') { [Console]::Out.WriteLine($state['runJson']) }
elseif ($route -ceq 'log') { [Console]::Out.Write([IO.File]::ReadAllText($state['logPath'], $utf8)) }
else { [Console]::Error.WriteLine('fake gh: unsupported call ' + ($args -join ' ')); exit 2 }
exit 0
'@, $utf8)
[void][IO.Directory]::CreateDirectory($pathGhRoot)
[IO.File]::WriteAllText($pathGhCmd, ("@echo off`r`n`"{0}`" -NoProfile -NonInteractive -File `"{1}`" %*`r`nexit /b %ERRORLEVEL%`r`n" -f $pwsh, $fakeGhPath), $utf8)

function Get-ListJson([string]$Status, [string]$Conclusion) {
    $run = [ordered]@{ databaseId = 9001; status = $Status; conclusion = $Conclusion; displayTitle = 'fix: 演示'; url = $runUrl }
    return (ConvertTo-Json -InputObject @($run) -Compress)
}

function New-Job([string]$Name, [string]$Conclusion, [string]$StartedAt, [string]$CompletedAt, [object[]]$Steps) {
    return [ordered]@{ name = $Name; status = 'completed'; conclusion = $Conclusion; startedAt = $StartedAt; completedAt = $CompletedAt; url = "$runUrl/job/1"; steps = @($Steps) }
}

function Get-RunJson([string]$Conclusion, [object[]]$Jobs) {
    $run = [ordered]@{ databaseId = 9001; name = 'CI'; displayTitle = 'fix: 演示'; status = 'completed'; conclusion = $Conclusion; url = $runUrl; jobs = @($Jobs) }
    return ($run | ConvertTo-Json -Depth 6 -Compress)
}

function Set-FakeState([string[]]$Lists, [string]$RunJson = '', [switch]$Failing) {
    $state = [ordered]@{ sha = $sha; lists = @($Lists); runJson = $RunJson; logPath = $logPath; failing = [bool]$Failing; calls = @() }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), $utf8)
}

# 函数返回时数组会被展开，调用处一律写 @(Get-FakeCall)。
function Get-FakeCall {
    ([IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json -AsHashtable)['calls']
}

# 用 -File 运行：脚本的 exit 码就是进程退出码（-Command 会把非零的 exit 码都折成 1）。
function Invoke-Wait([string[]]$Arguments) {
    $previousState = $env:FAKE_GH_WAIT_STATE
    $previousPath = $env:PATH
    $env:FAKE_GH_WAIT_STATE = $statePath
    $env:PATH = $pathGhRoot + [IO.Path]::PathSeparator + $env:PATH
    try {
        $resolvedGh = Get-Command -Name gh | Select-Object -First 1
        Assert-True ($resolvedGh.Source -eq $pathGhCmd) ('gh 应解析到替身 {0}，实际是 {1}' -f $pathGhCmd, $resolvedGh.Source)
        $output = @(& $pwsh -NoProfile -NonInteractive -File $waitScript @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:FAKE_GH_WAIT_STATE = $previousState
        $env:PATH = $previousPath
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        stdout = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        stderr = (@($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ')
    }
}

Assert-True (Test-Path -LiteralPath $waitScript -PathType Leaf) "缺少 $waitScript"
$poll = @('-Sha', $sha, '-PollSeconds', '0')

# 提交还没有 run、run 还在跑时继续等；跑完且通过后列出每个 job 的结论和耗时，退出 0。没开始的 job 耗时记为 -。
Set-FakeState @('[]', (Get-ListJson 'in_progress' ''), (Get-ListJson 'completed' 'success')) (Get-RunJson 'success' @(
    (New-Job 'lint' 'success' '2026-10-29T02:38:18Z' '2026-10-29T02:39:33Z' @())
    (New-Job 'shared fixtures' 'skipped' $null $null @())
))
$result = Invoke-Wait ($poll + @('-TimeoutMinutes', '5'))
$expected = @("run 9001 success: fix: 演示 $runUrl", 'success 75s lint', 'skipped - shared fixtures')
Assert-True ($result.exitCode -eq 0 -and ($result.stdout -join "`n") -ceq ($expected -join "`n")) ("通过的 run 应退出 0 并列出 job：{0} {1}`n{2}" -f $result.exitCode, $result.stderr, ($result.stdout -join "`n"))
Assert-True ((@(Get-FakeCall) -join ',') -ceq 'list,list,list,view') ('应查到 run 跑完才读 job：{0}' -f (@(Get-FakeCall) -join ','))

# 跑完但没通过：job 列表后面附失败摘要，退出 1。
$logLines = @(
    "shared fixtures`tRun module fixture tests`t2026-10-29T02:40:01.1234567Z Running Test-Beta.ps1"
    "shared fixtures`tRun module fixture tests`t2026-10-29T02:40:02.1234567Z Exception: 部署源有未提交的改动"
    "shared fixtures`tRun module fixture tests`t2026-10-29T02:40:03.1234567Z Test-Beta.ps1 failed with exit code 1"
)
[IO.File]::WriteAllText($logPath, (($logLines -join "`n") + "`n"), $utf8)
Set-FakeState @((Get-ListJson 'completed' 'failure')) (Get-RunJson 'failure' @(
    (New-Job 'lint' 'success' '2026-10-29T02:38:18Z' '2026-10-29T02:39:33Z' @())
    (New-Job 'shared fixtures' 'failure' '2026-10-29T02:38:18Z' '2026-10-29T02:40:04Z' @([ordered]@{ number = 4; name = 'Run module fixture tests'; status = 'completed'; conclusion = 'failure' }))
))
$result = Invoke-Wait ($poll + @('-TimeoutMinutes', '5'))
$expected = @(
    "run 9001 failure: fix: 演示 $runUrl"
    'success 75s lint'
    'failure 106s shared fixtures'
    ''
    "run 9001 CI: fix: 演示 [completed/failure] $runUrl"
    'failed jobs: 1 of 2'
    '== shared fixtures (failure) failed step: Run module fixture tests'
    'Running Test-Beta.ps1'
    'Exception: 部署源有未提交的改动'
    'Test-Beta.ps1 failed with exit code 1'
)
Assert-True ($result.exitCode -eq 1 -and ($result.stdout -join "`n") -ceq ($expected -join "`n")) ("没通过的 run 应退出 1 并附失败摘要：{0} {1}`n{2}" -f $result.exitCode, $result.stderr, ($result.stdout -join "`n"))
Assert-True ((@(Get-FakeCall) -join ',') -ceq 'list,view,view,log') ('应读 job 后再由失败摘要读 job 与日志：{0}' -f (@(Get-FakeCall) -join ','))

# 等满时间 run 仍在跑：至少查一次，不输出 job，stderr 说明 run 的状态，退出 2。
Set-FakeState @((Get-ListJson 'in_progress' ''))
$result = Invoke-Wait ($poll + @('-TimeoutMinutes', '0'))
Assert-True ($result.exitCode -eq 2 -and $result.stdout.Count -eq 0 -and $result.stderr -match "run 仍是 in_progress：$([regex]::Escape($runUrl))") ('仍在跑的 run 应退出 2 并说明：{0} {1}' -f $result.exitCode, $result.stderr)
Assert-True ((@(Get-FakeCall) -join ',') -ceq 'list') '超时为 0 时只查一次'

# 查询一直失败：不算结论，等满时间后 stderr 给出 gh 的报错，退出 2。
Set-FakeState @('[]') -Failing
$result = Invoke-Wait ($poll + @('-TimeoutMinutes', '0'))
Assert-True ($result.exitCode -eq 2 -and $result.stdout.Count -eq 0 -and $result.stderr -match '最后一次查询失败（gh 退出码 1：.*EOF') ('查询失败时应退出 2 并带上 gh 的报错：{0} {1}' -f $result.exitCode, $result.stderr)

# 短 SHA 在 gh 里什么也查不到：参数校验直接拒绝，不调用 gh。
Set-FakeState @('[]')
$result = Invoke-Wait @('-Sha', '0123456', '-PollSeconds', '0', '-TimeoutMinutes', '0')
Assert-True ($result.exitCode -ne 0 -and $result.stderr -match 'Sha') ('短 SHA 应被参数校验拒绝：{0} {1}' -f $result.exitCode, $result.stderr)
Assert-True (@(Get-FakeCall).Count -eq 0) '短 SHA 不应调用 gh'

'wait ci run: all checks passed'
