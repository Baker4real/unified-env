[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/ci-failure-summary-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# scripts\Get-CiFailureSummary.ps1 对替身 gh 运行。替身只实现 run view <id> --json … 与 run view <id> --log-failed，
# 前 failuresLeft 次调用报 EOF，并记下每次调用的路由。夹具目录复用，各场景只覆盖写单个文件，不递归删除。
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$summaryScript = Join-Path $projectRoot 'scripts\Get-CiFailureSummary.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
# 子进程按 UTF-8 输出中文，捕获时按 UTF-8 解码。
[Console]::OutputEncoding = $utf8
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$fakeGhPath = Join-Path $FixtureRoot 'fake-gh.ps1'
$statePath = Join-Path $FixtureRoot 'state.json'
$logPath = Join-Path $FixtureRoot 'log-failed.txt'
$runUrl = 'https://github.com/fixture/repo/actions/runs/9001'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

[IO.File]::WriteAllText($fakeGhPath, @'
$ErrorActionPreference = 'Stop'
# 替身 gh：run view 9001 --json … 输出 runJson，run view 9001 --log-failed 输出 logPath 的内容。
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$state = [IO.File]::ReadAllText($env:FAKE_GH_CI_STATE, $utf8) | ConvertFrom-Json -AsHashtable
$route = 'unsupported'
if ($args.Count -ge 4 -and [string]$args[0] -ceq 'run' -and [string]$args[1] -ceq 'view' -and [string]$args[2] -ceq '9001') {
    if ([string]$args[3] -ceq '--json') { $route = 'jobs' } elseif ([string]$args[3] -ceq '--log-failed') { $route = 'log' }
}
$state['calls'] = @($state['calls']) + @($route)
$failing = $state['failuresLeft'] -gt 0
if ($failing) { $state['failuresLeft'] = $state['failuresLeft'] - 1 }
[IO.File]::WriteAllText($env:FAKE_GH_CI_STATE, ($state | ConvertTo-Json -Depth 4), $utf8)
if ($failing) {
    [Console]::Error.WriteLine('Get "https://api.github.com/repos/fixture/repo/actions/runs/9001": EOF')
    exit 1
}
if ($route -ceq 'jobs') { [Console]::Out.WriteLine($state['runJson']) }
elseif ($route -ceq 'log') { [Console]::Out.Write([IO.File]::ReadAllText($state['logPath'], $utf8)) }
else { [Console]::Error.WriteLine('fake gh: unsupported call'); exit 2 }
exit 0
'@, $utf8)

function New-Job([string]$Name, [string]$Conclusion, [object[]]$Steps) {
    return [ordered]@{ name = $Name; status = 'completed'; conclusion = $Conclusion; url = "$runUrl/job/1"; steps = @($Steps) }
}

function New-Step([int]$Number, [string]$Name, [string]$Conclusion) {
    return [ordered]@{ number = $Number; name = $Name; status = 'completed'; conclusion = $Conclusion }
}

function Get-RunJson([string]$Conclusion, [object[]]$Jobs) {
    $run = [ordered]@{ databaseId = 9001; name = 'CI'; displayTitle = 'fix: demo'; status = 'completed'; conclusion = $Conclusion; url = $runUrl; jobs = @($Jobs) }
    return ($run | ConvertTo-Json -Depth 6 -Compress)
}

function Set-FakeState([string]$RunJson, [int]$FailuresLeft = 0) {
    $state = [ordered]@{ runJson = $RunJson; logPath = $logPath; failuresLeft = $FailuresLeft; calls = @() }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), $utf8)
}

# 函数返回时数组会被展开，调用处一律写 @(Get-FakeCall)。
function Get-FakeCall {
    ([IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json -AsHashtable)['calls']
}

function Get-Quoted([string]$Text) { return "'" + ($Text -replace "'", "''") + "'" }

function Invoke-Summary([string]$Seams) {
    $command = '& {0} -RunId 9001 {1}' -f (Get-Quoted $summaryScript), $Seams
    $previous = $env:FAKE_GH_CI_STATE
    $env:FAKE_GH_CI_STATE = $statePath
    try {
        $output = @(& $pwsh -NoProfile -NonInteractive -Command $command 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:FAKE_GH_CI_STATE = $previous
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        stdout = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        stderr = (@($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ')
    }
}

# --log-failed 的每行是「job<TAB>step<TAB>时间戳 文本」，PowerShell 的报错带 ANSI 颜色。真实日志里 ESC 写成字面的 ^[
# （2026-10-22 读 run 39623094219 实测），两种写法都要去掉。
$esc = [char]27
$caret = '^['
$logLines = [Collections.Generic.List[string]]::new()
function Add-LogLine([string]$Job, [string]$Step, [string]$Text) {
    $logLines.Add(('{0}{1}{2}{1}2026-10-21T15:10:{3:00}.1234567Z {4}' -f $Job, "`t", $Step, $logLines.Count, $Text))
}
$step = 'Run module fixture tests'
Add-LogLine 'shared fixtures' $step 'Running Test-Alpha.ps1'
Add-LogLine 'shared fixtures' $step 'alpha: all checks passed'
Add-LogLine 'shared fixtures' $step 'Running Test-Beta.ps1'
foreach ($n in 1..5) { Add-LogLine 'shared fixtures' $step ('What if: Performing the operation "deploy" on target "D:\a\x{0}.py".' -f $n) }
Add-LogLine 'shared fixtures' $step ('{0}[31;1mException: {0}[0mD:\a\scripts\Deploy-Beta.ps1:160{0}[0m' -f $esc)
Add-LogLine 'shared fixtures' $step ('{0}[31;1m{0}[0m{0}[36;1mLine |{0}[0m' -f $caret)
Add-LogLine 'shared fixtures' $step ('{0}[36;1m 160 | {0}[0m    throw "部署源有未提交的改动：$files"' -f $caret)
Add-LogLine 'shared fixtures' $step ('     | {0}[31;1m    ~~~~~~~~~~~~~~~~~~{0}[0m' -f $caret)
Add-LogLine 'shared fixtures' $step ('     | {0}[31;1m部署源有未提交的改动：scripts/a.py, scripts/b.cmd{0}[0m' -f $caret)
Add-LogLine 'shared fixtures' $step ('     | ' + ('x' * 400))
Add-LogLine 'shared fixtures' $step 'Test-Beta.ps1 failed with exit code 1'
Add-LogLine 'shared fixtures' $step '##[error]Process completed with exit code 1.'
Add-LogLine 'shared fixtures' 'Post job cleanup' 'Post job cleanup.'
Add-LogLine 'node fixtures' 'UNKNOWN STEP' 'Running tests/Test-Gamma.cjs'
Add-LogLine 'node fixtures' 'UNKNOWN STEP' 'node:assert:128'
Add-LogLine 'node fixtures' 'UNKNOWN STEP' '  throw new AssertionError(obj);'
Add-LogLine 'node fixtures' 'UNKNOWN STEP' 'AssertionError [ERR_ASSERTION]: gamma must equal 2'
Add-LogLine 'node fixtures' 'UNKNOWN STEP' '    at Object.<anonymous> (D:\a\tests\Test-Gamma.cjs:10:3)'
Add-LogLine 'node fixtures' 'UNKNOWN STEP' '##[error]Process completed with exit code 1.'
[IO.File]::WriteAllText($logPath, (($logLines -join "`n") + "`n"), $utf8)

$failingRun = Get-RunJson 'failure' @(
    (New-Job 'lint' 'success' @((New-Step 1 'Run lint' 'success')))
    (New-Job 'shared fixtures' 'failure' @((New-Step 1 'Set up job' 'success'), (New-Step 4 'Run module fixture tests' 'failure'), (New-Step 9 'Post job cleanup' 'success')))
    (New-Job 'node fixtures' 'failure' @((New-Step 3 'Run node tests' 'failure')))
)
$expected = @(
    "run 9001 CI: fix: demo [completed/failure] $runUrl"
    'failed jobs: 2 of 3'
    '== shared fixtures (failure) failed step: Run module fixture tests'
    'Running Test-Beta.ps1'
    'Exception: D:\a\scripts\Deploy-Beta.ps1:160'
    'Line |'
    ' 160 |     throw "部署源有未提交的改动：$files"'
    '     |     ~~~~~~~~~~~~~~~~~~'
    '     | 部署源有未提交的改动：scripts/a.py, scripts/b.cmd'
    ('     | ' + ('x' * 293) + '...')
    'Test-Beta.ps1 failed with exit code 1'
    '##[error]Process completed with exit code 1.'
    '== node fixtures (failure) failed step: Run node tests'
    'Running tests/Test-Gamma.cjs'
    'node:assert:128'
    '  throw new AssertionError(obj);'
    'AssertionError [ERR_ASSERTION]: gamma must equal 2'
    '##[error]Process completed with exit code 1.'
)
$fakeSeam = '-GhCommandForTest @({0}) -NoRetryDelayForTest' -f ((@($pwsh, '-NoProfile', '-NonInteractive', '-File', $fakeGhPath) | ForEach-Object { Get-Quoted $_ }) -join ', ')
Assert-True (Test-Path -LiteralPath $summaryScript -PathType Leaf) "缺少 $summaryScript"

# 失败的 run：每个失败 job 只留失败测试的 Running 行、报错行和失败标记；去掉颜色、时间戳和无关输出，超长行截断。
# 第一次读取报 EOF，重试后照常输出。
Set-FakeState $failingRun -FailuresLeft 1
$result = Invoke-Summary $fakeSeam
Assert-True ($result.exitCode -eq 0) ('失败 run 的摘要应退出 0，实际 {0}：{1}' -f $result.exitCode, $result.stderr)
Assert-True (($result.stdout -join "`n") -ceq ($expected -join "`n")) ("摘要不符合预期：`n" + ($result.stdout -join "`n"))
Assert-True ((@(Get-FakeCall) -join ',') -ceq 'jobs,jobs,log') ('调用顺序应是 jobs（EOF）、jobs、log：{0}' -f (@(Get-FakeCall) -join ','))

# 全部通过的 run：只说没有失败的 job，不读日志。
Set-FakeState (Get-RunJson 'success' @((New-Job 'lint' 'success' @((New-Step 1 'Run lint' 'success')))))
$result = Invoke-Summary $fakeSeam
Assert-True ($result.exitCode -eq 0 -and ($result.stdout -join "`n") -ceq ("run 9001 CI: fix: demo [completed/success] $runUrl`nno failed jobs")) ("通过的 run 应只报没有失败：`n" + ($result.stdout -join "`n"))
Assert-True ((@(Get-FakeCall) -join ',') -ceq 'jobs') '通过的 run 不应读日志'

# gh 一直失败：不输出摘要，stderr 说明失败次数，退出 1。
Set-FakeState $failingRun -FailuresLeft 4
$result = Invoke-Summary $fakeSeam
Assert-True ($result.exitCode -eq 1 -and $result.stdout.Count -eq 0 -and $result.stderr -match 'failed after 4 attempts') ('gh 一直失败时应退出 1 并说明：{0} {1}' -f $result.exitCode, $result.stderr)

# 生产路径：两个 seam 都不传，按 PATH 解析 gh。PATH 最前面放一个转发到替身的 gh.cmd，并先确认解析到它，免得真 gh 发出请求。
$pathGhRoot = Join-Path $FixtureRoot 'path-gh'
[void][IO.Directory]::CreateDirectory($pathGhRoot)
$pathGhCmd = Join-Path $pathGhRoot 'gh.cmd'
[IO.File]::WriteAllText($pathGhCmd, ("@echo off`r`n`"{0}`" -NoProfile -NonInteractive -File `"{1}`" %*`r`nexit /b %ERRORLEVEL%`r`n" -f $pwsh, $fakeGhPath), $utf8)
Set-FakeState $failingRun
$previousPath = $env:PATH
$env:PATH = $pathGhRoot + [IO.Path]::PathSeparator + $env:PATH
try {
    $resolvedGh = Get-Command -Name gh | Select-Object -First 1
    Assert-True ($resolvedGh.Source -eq $pathGhCmd) ('gh 应解析到替身 {0}，实际是 {1}' -f $pathGhCmd, $resolvedGh.Source)
    $result = Invoke-Summary ''
} finally {
    $env:PATH = $previousPath
}
Assert-True ($result.exitCode -eq 0 -and ($result.stdout -join "`n") -ceq ($expected -join "`n")) ("不带 seam 时应按 PATH 解析 gh 并输出同样的摘要：{0} {1}`n{2}" -f $result.exitCode, $result.stderr, ($result.stdout -join "`n"))

'ci failure summary: all checks passed'
