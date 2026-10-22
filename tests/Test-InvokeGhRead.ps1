[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/gh-read-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# scripts\Invoke-GhRead.ps1 对替身 gh 运行。替身按 FAKE_GH_READ_STATE 指向的 JSON 先报 failuresLeft 次 EOF，
# 之后输出固定的 stdout，并记下每次收到的参数。夹具目录复用，各场景只覆盖写单个文件，不递归删除。
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$readScript = Join-Path $projectRoot 'scripts\Invoke-GhRead.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
# 子进程按 UTF-8 输出中文，捕获时按 UTF-8 解码。
[Console]::OutputEncoding = $utf8
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$fakeGhPath = Join-Path $FixtureRoot 'fake-gh.ps1'
$statePath = Join-Path $FixtureRoot 'state.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

[IO.File]::WriteAllText($fakeGhPath, @'
$ErrorActionPreference = 'Stop'
# 替身 gh：前 failuresLeft 次调用报 EOF 并退出 1，之后输出 stdout 并退出 0。每次调用的参数记成一行 [a][b]...。
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$state = [IO.File]::ReadAllText($env:FAKE_GH_READ_STATE, $utf8) | ConvertFrom-Json -AsHashtable
$state['calls'] = @($state['calls']) + @((@($args | ForEach-Object { '[' + $_ + ']' }) -join ''))
$failing = $state['failuresLeft'] -gt 0
if ($failing) { $state['failuresLeft'] = $state['failuresLeft'] - 1 }
[IO.File]::WriteAllText($env:FAKE_GH_READ_STATE, ($state | ConvertTo-Json -Depth 4), $utf8)
if ($failing) {
    [Console]::Error.WriteLine('Get "https://api.github.com/repos/fixture/repo/issues/7": EOF')
    exit 1
}
foreach ($line in $state['stdout']) { [Console]::Out.WriteLine($line) }
exit 0
'@, $utf8)

function Set-FakeState([int]$FailuresLeft, [string[]]$Stdout) {
    $state = [ordered]@{ failuresLeft = $FailuresLeft; stdout = @($Stdout); calls = @() }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), $utf8)
}

# 函数返回时数组会被展开，调用处一律写 @(Get-FakeCall)。
function Get-FakeCall {
    ([IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json -AsHashtable)['calls']
}

function Get-Quoted([string]$Text) { return "'" + ($Text -replace "'", "''") + "'" }

# 在独立 pwsh 里像调用方那样用 & 调用，取退出码、stdout 和 stderr。$Seams 是 -- 之前的参数文本。
function Invoke-Read([string]$Seams, [string]$GhArguments) {
    $command = '& {0} {1} -- {2}' -f (Get-Quoted $readScript), $Seams, $GhArguments
    $previous = $env:FAKE_GH_READ_STATE
    $env:FAKE_GH_READ_STATE = $statePath
    try {
        $output = @(& $pwsh -NoProfile -NonInteractive -Command $command 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:FAKE_GH_READ_STATE = $previous
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        stdout = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        stderr = (@($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ')
    }
}

Assert-True (Test-Path -LiteralPath $readScript -PathType Leaf) "缺少 $readScript"
$fakeSeam = '-GhCommandForTest @({0}) -NoRetryDelayForTest' -f ((@($pwsh, '-NoProfile', '-NonInteractive', '-File', $fakeGhPath) | ForEach-Object { Get-Quoted $_ }) -join ', ')
$ghArguments = "api -X GET 'repos/{owner}/{repo}/issues/7' --jq '.[] | .name' -f 'labels[]=a,b'"
$expectedCall = '[api][-X][GET][repos/{owner}/{repo}/issues/7][--jq][.[] | .name][-f][labels[]=a,b]'

# 两次 EOF 后成功：输出第三次的 stdout，-- 之后的参数（含短参数、空格与逗号）原样到达 gh。
Set-FakeState -FailuresLeft 2 -Stdout @('{"number":7,"title":"中文标题"}', 'second line')
$result = Invoke-Read $fakeSeam $ghArguments
Assert-True ($result.exitCode -eq 0) ('两次 EOF 后应成功退出 0，实际 {0}：{1}' -f $result.exitCode, $result.stderr)
Assert-True (($result.stdout -join "`n") -ceq ('{"number":7,"title":"中文标题"}' + "`n" + 'second line')) ('stdout 应原样输出：{0}' -f ($result.stdout -join ' | '))
$calls = @(Get-FakeCall)
Assert-True ($calls.Count -eq 3) ('应调用 3 次 gh，实际 {0}' -f $calls.Count)
Assert-True (@($calls | Where-Object { $_ -cne $expectedCall }).Count -eq 0) ('gh 参数应原样转发：{0}' -f ($calls -join ' | '))

# 四次都失败：不输出 stdout，stderr 给出次数与最后一次的错误，退出 1。
Set-FakeState -FailuresLeft 4 -Stdout @('不该输出')
$result = Invoke-Read $fakeSeam $ghArguments
Assert-True ($result.exitCode -eq 1) ('四次失败应退出 1，实际 {0}' -f $result.exitCode)
Assert-True ($result.stdout.Count -eq 0) ('失败时不应有 stdout：{0}' -f ($result.stdout -join ' | '))
Assert-True ($result.stderr -match 'failed after 4 attempts' -and $result.stderr -match 'EOF') ('stderr 应说明失败次数与 EOF：{0}' -f $result.stderr)
Assert-True (@(Get-FakeCall).Count -eq 4) '四次失败应正好调用 4 次 gh'

# 没给 gh 参数：直接失败，不调用 gh。
Set-FakeState -FailuresLeft 0 -Stdout @('不该输出')
$result = Invoke-Read $fakeSeam ''
Assert-True ($result.exitCode -eq 1 -and $result.stderr -match '--') ('没有 gh 参数时应退出 1 并提示放在 -- 之后：{0}' -f $result.stderr)
Assert-True (@(Get-FakeCall).Count -eq 0) '没有 gh 参数时不应调用 gh'

# 生产路径：两个 seam 都不传，按 PATH 解析 gh，重试走真实等待（一次失败只等 2 秒）。
# PATH 最前面放一个转发到替身的 gh.cmd，并先确认解析到它，免得真 gh 发出请求。
$pathGhRoot = Join-Path $FixtureRoot 'path-gh'
[void][IO.Directory]::CreateDirectory($pathGhRoot)
$pathGhCmd = Join-Path $pathGhRoot 'gh.cmd'
[IO.File]::WriteAllText($pathGhCmd, ("@echo off`r`n`"{0}`" -NoProfile -NonInteractive -File `"{1}`" %*`r`nexit /b %ERRORLEVEL%`r`n" -f $pwsh, $fakeGhPath), $utf8)
Set-FakeState -FailuresLeft 1 -Stdout @('[{"databaseId":1,"status":"completed"}]')
$previousPath = $env:PATH
$env:PATH = $pathGhRoot + [IO.Path]::PathSeparator + $env:PATH
try {
    $resolvedGh = Get-Command -Name gh | Select-Object -First 1
    Assert-True ($resolvedGh.Source -eq $pathGhCmd) ('gh 应解析到替身 {0}，实际是 {1}' -f $pathGhCmd, $resolvedGh.Source)
    $result = Invoke-Read '' "run list --limit 1 --json 'databaseId,status'"
} finally {
    $env:PATH = $previousPath
}
Assert-True ($result.exitCode -eq 0 -and ($result.stdout -join '') -ceq '[{"databaseId":1,"status":"completed"}]') ('不带 seam 时应按 PATH 解析 gh 并在重试后成功：{0} {1}' -f $result.exitCode, $result.stderr)
$calls = @(Get-FakeCall)
Assert-True ($calls.Count -eq 2 -and $calls[1] -ceq '[run][list][--limit][1][--json][databaseId,status]') ('不带 seam 时的调用不对：{0}' -f ($calls -join ' | '))

'gh read: all checks passed'
