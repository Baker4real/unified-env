[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/ci-test-timing-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# scripts\Get-CiTestTiming.ps1 对替身 gh 运行。替身只实现 run view <id> --json … 与
# api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/<id>/logs，前 failuresLeft 次调用报 EOF，
# 并记下每次调用的路由。夹具目录复用，各场景只覆盖写单个文件，不递归删除。
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$timingScript = Join-Path $projectRoot 'scripts\Get-CiTestTiming.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
# 子进程按 UTF-8 输出中文，捕获时按 UTF-8 解码。
[Console]::OutputEncoding = $utf8
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$fakeGhPath = Join-Path $FixtureRoot 'fake-gh.ps1'
$statePath = Join-Path $FixtureRoot 'state.json'
$runUrl = 'https://github.com/fixture/repo/actions/runs/9001'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

[IO.File]::WriteAllText($fakeGhPath, @'
$ErrorActionPreference = 'Stop'
# 替身 gh：run view 9001 --json … 输出 runJson；api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/<id>/logs
# 原样输出 logs 里该 job 的日志文件字节。
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$state = [IO.File]::ReadAllText($env:FAKE_GH_TIMING_STATE, $utf8) | ConvertFrom-Json -AsHashtable
$route = 'unsupported'
if ($args.Count -eq 5 -and [string]$args[0] -ceq 'run' -and [string]$args[1] -ceq 'view' -and [string]$args[2] -ceq '9001' -and [string]$args[3] -ceq '--json') {
    $route = 'jobs'
} elseif ($args.Count -eq 3 -and [string]$args[0] -ceq 'api' -and [string]$args[1] -ceq '--allow-escape-sequences' -and [string]$args[2] -cmatch '^repos/\{owner\}/\{repo\}/actions/jobs/(\d+)/logs$') {
    $route = 'log:' + $Matches[1]
}
$state['calls'] = @($state['calls']) + @($route)
$failing = $state['failuresLeft'] -gt 0
if ($failing) { $state['failuresLeft'] = $state['failuresLeft'] - 1 }
[IO.File]::WriteAllText($env:FAKE_GH_TIMING_STATE, ($state | ConvertTo-Json -Depth 4), $utf8)
if ($failing) {
    [Console]::Error.WriteLine('Get "https://api.github.com/repos/fixture/repo/actions/runs/9001": EOF')
    exit 1
}
if ($route -ceq 'jobs') {
    [Console]::Out.WriteLine($state['runJson'])
    exit 0
}
$jobId = if ($route.StartsWith('log:')) { $route.Substring(4) } else { '' }
if ($state['logs'].ContainsKey($jobId)) {
    $bytes = [IO.File]::ReadAllBytes($state['logs'][$jobId])
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
    exit 0
}
[Console]::Error.WriteLine('fake gh: unsupported call')
exit 2
'@, $utf8)

# 日志每行是「时间戳 文本」；夹具的时间都在 2026-10-21T15:<分:秒>Z。
function New-LogLine([string]$Clock, [string]$Text) {
    return ('2026-10-21T15:{0}Z {1}' -f $Clock, $Text)
}

function Write-JobLog([long]$JobId, [string[]]$Lines) {
    $path = Join-Path $FixtureRoot ('job-{0}.log' -f $JobId)
    [IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), $utf8)
    return $path
}

function New-Job([long]$Id, [string]$Name, [string]$Conclusion, [string]$Completed) {
    return [ordered]@{
        databaseId = $Id; name = $Name; status = 'completed'; conclusion = $Conclusion
        startedAt = '2026-10-21T15:00:00Z'; completedAt = "2026-10-21T15:$($Completed)Z"; url = "$runUrl/job/$Id"
    }
}

# 真实日志第一行带 BOM，step 头里回显的命令带颜色控制符（2026-10-28 读 run 40696601168 的 job 日志实测）。
$esc = [char]27
$logs = [ordered]@{
    '101' = Write-JobLog 101 @(
        (New-LogLine '00:01.0000000' "Current runner version: '2.338.0'")
        (New-LogLine '00:02.0000000' '##[group]Run node .\scripts\Validate-ModuleBoundaries.cjs')
        (New-LogLine '00:02.1000000' '##[endgroup]')
        (New-LogLine '00:03.0000000' 'module boundaries: ok')
        (New-LogLine '01:04.0000000' 'Post job cleanup.')
    )
    # 两个测试；第一个带 STAGE 行，最后一个测试截到下一个 step 的 ##[group]。
    '102' = Write-JobLog 102 @(
        ([string][char]0xFEFF + (New-LogLine '00:00.5000000' "Current runner version: '2.338.0'"))
        (New-LogLine '00:29.0000000' '##[group]Run node .\scripts\Run-PowerShellTests.cjs --module host-safety')
        (New-LogLine '00:29.0500000' ('{0}[36;1mnode .\scripts\Run-PowerShellTests.cjs --module host-safety{0}[0m' -f $esc))
        (New-LogLine '00:29.1000000' '##[endgroup]')
        (New-LogLine '00:30.5000000' 'Running Test-Alpha.ps1')
        (New-LogLine '00:31.0000000' 'STAGE runtime-check utc=2026-10-21T15:00:30.9876543+00:00')
        (New-LogLine '00:32.5000000' 'STAGE scale-create utc=2026-10-21T15:00:32.4876543+00:00')
        (New-LogLine '00:40.0000000' 'alpha: tree created')
        (New-LogLine '01:00.0000000' 'STAGE scale-baseline utc=2026-10-21T15:00:59.9876543+00:00')
        (New-LogLine '05:00.4000000' 'STAGE done utc=2026-10-21T15:05:00.3876543+00:00')
        (New-LogLine '05:00.4500000' '')
        (New-LogLine '05:00.5000000' ('{0}[32;1mok    : {0}[0mTrue' -f $esc))
        (New-LogLine '05:10.0000000' 'Running Test-Beta.ps1')
        (New-LogLine '07:00.0000000' 'beta: all checks passed')
        (New-LogLine '09:50.0000000' '##[group]Run actions/upload-artifact@v4')
        (New-LogLine '09:55.0000000' 'Post job cleanup.')
    )
    # 失败的测试截到 ##[error]。
    '103' = Write-JobLog 103 @(
        (New-LogLine '00:10.0000000' '##[group]Run node .\scripts\Run-PowerShellTests.cjs --module shared')
        (New-LogLine '00:10.1000000' '##[endgroup]')
        (New-LogLine '00:20.0000000' 'Running Test-Gamma.ps1')
        (New-LogLine '00:45.2000000' 'Exception: gamma broke')
        (New-LogLine '00:50.0000000' 'Test-Gamma.ps1 failed with exit code 1')
        (New-LogLine '00:50.7000000' '##[error]Process completed with exit code 1.')
        (New-LogLine '01:30.0000000' 'Post job cleanup.')
    )
    # Run-ManifestTests.cjs 也打印 Running 行；最后一个测试截到 Post job cleanup。
    '104' = Write-JobLog 104 @(
        (New-LogLine '00:15.0000000' '##[group]Run node .\scripts\Run-ManifestTests.cjs')
        (New-LogLine '00:15.5000000' '##[endgroup]')
        (New-LogLine '00:16.0000000' 'Running tests/Test-Delta.cjs')
        (New-LogLine '00:58.3000000' 'delta: ok')
        (New-LogLine '01:01.0000000' 'Running tests/Test-Epsilon.py')
        (New-LogLine '02:39.0000000' 'Manifest tests: 2 passed, 0 failed, 0 not run (host-bound)')
        (New-LogLine '02:40.0000000' 'Post job cleanup.')
    )
    # 取消的 job：日志停在测试中间，测试截到最后一行。
    '105' = Write-JobLog 105 @(
        (New-LogLine '00:05.0000000' 'Running Test-Zeta.ps1')
        (New-LogLine '00:06.0000000' 'STAGE scale-create utc=2026-10-21T15:00:05.9876543+00:00')
        (New-LogLine '01:35.5000000' 'zeta: still writing')
    )
}
$skippedJob = New-Job 106 'host-safety diagnostics' 'skipped' '00:00'
$runJson = ([ordered]@{
    databaseId = 9001; name = 'CI'; displayTitle = 'fix: demo'; status = 'completed'; conclusion = 'failure'; url = $runUrl
    jobs = @(
        (New-Job 101 'lint' 'success' '01:05')
        (New-Job 102 'host-safety fixtures (Alpha)' 'success' '10:00')
        (New-Job 103 'shared fixtures' 'failure' '01:40')
        (New-Job 104 'Python and Node fixtures' 'success' '03:00')
        (New-Job 105 'host-safety fixtures (Zeta)' 'cancelled' '02:00')
        $skippedJob
    )
} | ConvertTo-Json -Depth 6 -Compress)

function Set-FakeState([int]$FailuresLeft = 0) {
    $state = [ordered]@{ runJson = $runJson; logs = $logs; failuresLeft = $FailuresLeft; calls = @() }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), $utf8)
}

# 函数返回时数组会被展开，调用处一律写 @(Get-FakeCall)。
function Get-FakeCall {
    ([IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json -AsHashtable)['calls']
}

function Get-Quoted([string]$Text) { return "'" + ($Text -replace "'", "''") + "'" }

function Invoke-Timing([string]$Seams) {
    $command = '& {0} -RunId 9001 {1}' -f (Get-Quoted $timingScript), $Seams
    $previous = $env:FAKE_GH_TIMING_STATE
    $env:FAKE_GH_TIMING_STATE = $statePath
    try {
        $output = @(& $pwsh -NoProfile -NonInteractive -Command $command 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:FAKE_GH_TIMING_STATE = $previous
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        stdout = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        stderr = (@($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ')
    }
}

$expected = @(
    "run 9001 CI: fix: demo [completed/failure] $runUrl"
    '== lint (success) job 65s, no Running lines in log'
    '== host-safety fixtures (Alpha) (success) job 600s, tests: 2 in 559.5s'
    '    279.5s  Test-Alpha.ps1'
    '      0.5s    - (start)'
    '      1.5s    - runtime-check'
    '     27.5s    - scale-create'
    '    240.4s    - scale-baseline'
    '      9.6s    - done'
    '    280.0s  Test-Beta.ps1'
    '== shared fixtures (failure) job 100s, tests: 1 in 30.7s'
    '     30.7s  Test-Gamma.ps1'
    '== Python and Node fixtures (success) job 180s, tests: 2 in 144.0s'
    '     45.0s  tests/Test-Delta.cjs'
    '     99.0s  tests/Test-Epsilon.py'
    '== host-safety fixtures (Zeta) (cancelled) job 120s, tests: 1 in 90.5s'
    '     90.5s  Test-Zeta.ps1'
    '      1.0s    - (start)'
    '     89.5s    - scale-create'
    '== host-safety diagnostics (skipped) log not read'
)
$expectedCalls = 'jobs,jobs,log:101,log:102,log:103,log:104,log:105'
$fakeSeam = '-GhCommandForTest @({0}) -NoRetryDelayForTest' -f ((@($pwsh, '-NoProfile', '-NonInteractive', '-File', $fakeGhPath) | ForEach-Object { Get-Quoted $_ }) -join ', ')
Assert-True (Test-Path -LiteralPath $timingScript -PathType Leaf) "缺少 $timingScript"

# 每个 job 按 Running 行切出测试，按 STAGE 行切出分段；被跳过的 job 不读日志。第一次读取报 EOF，重试后照常输出。
Set-FakeState -FailuresLeft 1
$result = Invoke-Timing $fakeSeam
Assert-True ($result.exitCode -eq 0) ('耗时报告应退出 0，实际 {0}：{1}' -f $result.exitCode, $result.stderr)
Assert-True (($result.stdout -join "`n") -ceq ($expected -join "`n")) ("耗时报告不符合预期：`n" + ($result.stdout -join "`n"))
Assert-True ((@(Get-FakeCall) -join ',') -ceq $expectedCalls) ('调用顺序应是 {0}：{1}' -f $expectedCalls, (@(Get-FakeCall) -join ','))

# gh 一直失败：不输出报告，stderr 说明失败次数，退出 1。
Set-FakeState -FailuresLeft 99
$result = Invoke-Timing $fakeSeam
Assert-True ($result.exitCode -eq 1 -and $result.stdout.Count -eq 0 -and $result.stderr -match 'failed after 4 attempts') ('gh 一直失败时应退出 1 并说明：{0} {1}' -f $result.exitCode, $result.stderr)

# 生产路径：两个 seam 都不传，按 PATH 解析 gh。PATH 最前面放一个转发到替身的 gh.cmd，并先确认解析到它，免得真 gh 发出请求。
$pathGhRoot = Join-Path $FixtureRoot 'path-gh'
[void][IO.Directory]::CreateDirectory($pathGhRoot)
$pathGhCmd = Join-Path $pathGhRoot 'gh.cmd'
[IO.File]::WriteAllText($pathGhCmd, ("@echo off`r`n`"{0}`" -NoProfile -NonInteractive -File `"{1}`" %*`r`nexit /b %ERRORLEVEL%`r`n" -f $pwsh, $fakeGhPath), $utf8)
Set-FakeState
$previousPath = $env:PATH
$env:PATH = $pathGhRoot + [IO.Path]::PathSeparator + $env:PATH
try {
    $resolvedGh = Get-Command -Name gh | Select-Object -First 1
    Assert-True ($resolvedGh.Source -eq $pathGhCmd) ('gh 应解析到替身 {0}，实际是 {1}' -f $pathGhCmd, $resolvedGh.Source)
    $result = Invoke-Timing ''
} finally {
    $env:PATH = $previousPath
}
Assert-True ($result.exitCode -eq 0 -and ($result.stdout -join "`n") -ceq ($expected -join "`n")) ("不带 seam 时应按 PATH 解析 gh 并输出同样的报告：{0} {1}`n{2}" -f $result.exitCode, $result.stderr, ($result.stdout -join "`n"))
Assert-True ((@(Get-FakeCall) -join ',') -ceq 'jobs,log:101,log:102,log:103,log:104,log:105') ('不带 seam 时的调用顺序不对：{0}' -f (@(Get-FakeCall) -join ','))

'ci test timing: all checks passed'
