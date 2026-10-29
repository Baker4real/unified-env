<#
.SYNOPSIS
列出一次 GitHub Actions run 每个 job 的逐测试耗时；测试打了 STAGE 阶段标记时再列分段耗时。只读。

.DESCRIPTION
读 gh run view <RunId> --json 的 job 列表，再逐个读已结束 job 的日志：
gh api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/<job id>/logs。日志含颜色控制符，不带这个参数时
gh 2.103.2 退出 1 且什么也不输出。gh 按当前目录的仓库（或 GH_REPO）解析 run 和 {owner}/{repo}，所以在仓库目录里运行。
读取失败时按 docs/agents/issue-tracker.md「gh 报 EOF 时」退避重试。
- 一个测试从 Running <测试> 行（Run-PowerShellTests.cjs 与 Run-ManifestTests.cjs 在每个测试前打印）开始，到下一条
  Running 行或之后第一条 ##[group]、##[error]、Post job cleanup 行为止；都没有时到日志最后一行。
- 测试输出里的 STAGE <名称> utc=... 行（tests 里的 Write-Stage）把这个测试再切成段，第一条 STAGE 之前记为 (start)。
- 时间都取 GitHub 给日志行加的时间戳，所以各段之和等于测试耗时；tests 耗时是各测试之和。
输出纯文本，第一行是 run 的名称、标题、状态和链接。run 已结束时第二行给出墙钟和最大起跑延迟，都从 run 的 startedAt
（重跑时重置）起算：墙钟到最后一个 job 的 completedAt，分钟保留一位小数；起跑延迟是 job 的 startedAt 与它之差，取最大的
一个，整秒，带 job 名。被跳过的 job 不占 runner，两项都不算它。之后每个 job 一段，以 == <job> (<结论>) 开头，给出 job 耗时
（gh 给的 startedAt 到 completedAt，整秒）、测试个数和 tests 耗时；下面每个测试一行，每段一行（以 - 开头），
秒数保留一位小数。没结束或被跳过的 job 不读日志。gh 重试用完仍失败时不输出，错误写到 stderr，退出 1。

.EXAMPLE
& D:/agents/projects/统一环境/scripts/Get-CiTestTiming.ps1 -RunId 40696601168
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$RunId,
    # 测试专用 seam（生产调用不传）：替身 gh 命令（可执行文件加前置参数）与零等待重试。
    [string[]]$GhCommandForTest,
    [switch]$NoRetryDelayForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 按 UTF-8 解码 gh 的输出（日志和标题含中文）。
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'lib\GitHubCli.ps1')

$invariant = [Globalization.CultureInfo]::InvariantCulture
$logLinePattern = '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) ?(.*)$'
$testEndPattern = '^(?:##\[group\]|##\[error\]|Post job cleanup)'
$stagePattern = '^STAGE (\S+) utc='

function Format-Second([double]$Seconds) {
    return $Seconds.ToString('0.0', $invariant)
}

# 日志每行是「时间戳 文本」。返回时间戳和去掉行尾空白的文本；开头不是时间戳的行返回 $null。
# 日志第一行带 BOM，因此也被跳过；那是 runner 版本行，不影响切分。
function ConvertFrom-LogLine([string]$Line) {
    $match = [regex]::Match($Line, $logLinePattern)
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        time = [datetimeoffset]::Parse($match.Groups[1].Value, $invariant)
        text = $match.Groups[2].Value.TrimEnd()
    }
}

# 测试在 $End 结束：算出秒数；有 STAGE 行时按它们切段，第一条 STAGE 之前记为 (start)。
function Complete-Test($Test, [datetimeoffset]$End) {
    $stages = [Collections.Generic.List[object]]::new()
    if ($Test.marks.Count -gt 0) {
        $bounds = @([pscustomobject]@{ name = '(start)'; time = $Test.start }) + @($Test.marks)
        for ($i = 0; $i -lt $bounds.Count; $i++) {
            $stageEnd = if ($i + 1 -lt $bounds.Count) { $bounds[$i + 1].time } else { $End }
            $stages.Add([pscustomobject]@{ name = $bounds[$i].name; seconds = ($stageEnd - $bounds[$i].time).TotalSeconds })
        }
    }
    return [pscustomobject]@{ label = $Test.label; seconds = ($End - $Test.start).TotalSeconds; stages = $stages.ToArray() }
}

# 把一个 job 的日志行切成测试。
function Split-JobTest([object[]]$Entries) {
    $tests = [Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($entry in $Entries) {
        if ($entry.text.StartsWith('Running ', [StringComparison]::Ordinal)) {
            if ($null -ne $current) { $tests.Add((Complete-Test $current $entry.time)) }
            $current = [pscustomobject]@{ label = $entry.text.Substring(8); start = $entry.time; marks = [Collections.Generic.List[object]]::new() }
        } elseif ($null -ne $current -and $entry.text -cmatch $testEndPattern) {
            $tests.Add((Complete-Test $current $entry.time))
            $current = $null
        } elseif ($null -ne $current -and $entry.text -cmatch $stagePattern) {
            $current.marks.Add([pscustomobject]@{ name = $Matches[1]; time = $entry.time })
        }
    }
    if ($null -ne $current) { $tests.Add((Complete-Test $current $Entries[-1].time)) }
    return $tests.ToArray()
}

$ghCommand = @(if ($null -ne $GhCommandForTest -and $GhCommandForTest.Count -gt 0) { $GhCommandForTest } else { 'gh' })
$report = [Collections.Generic.List[string]]::new()
try {
    $runFields = 'databaseId,name,displayTitle,status,conclusion,startedAt,url,jobs'
    $run = (Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('run', 'view', [string]$RunId, '--json', $runFields) -NoRetryDelay:$NoRetryDelayForTest) -join "`n" | ConvertFrom-Json -DateKind String
    $report.Add(('run {0} {1}: {2} [{3}/{4}] {5}' -f $RunId, $run.name, $run.displayTitle, $run.status, $run.conclusion, $run.url))
    $ranJobs = @(if ($run.status -ceq 'completed') { @($run.jobs) | Where-Object { $_.conclusion -cne 'skipped' } })
    if ($ranJobs.Count -gt 0) {
        $runStart = [datetimeoffset]::Parse($run.startedAt, $invariant)
        $offsets = @(foreach ($job in $ranJobs) {
            [pscustomobject]@{
                name = $job.name
                startDelay = ([datetimeoffset]::Parse($job.startedAt, $invariant) - $runStart).TotalSeconds
                end = ([datetimeoffset]::Parse($job.completedAt, $invariant) - $runStart).TotalSeconds
            }
        })
        $wallMinutes = ($offsets | Measure-Object -Property end -Maximum).Maximum / 60
        $latestStart = $offsets | Sort-Object -Property startDelay -Descending | Select-Object -First 1
        $report.Add(('wall {0} min from run start to last job end, max job start delay {1}s ({2})' -f $wallMinutes.ToString('0.0', $invariant), [long][Math]::Round($latestStart.startDelay), $latestStart.name))
    }
    foreach ($job in @($run.jobs)) {
        $state = if ($job.conclusion) { $job.conclusion } else { $job.status }
        if ($job.status -cne 'completed' -or $job.conclusion -ceq 'skipped') {
            $report.Add(('== {0} ({1}) log not read' -f $job.name, $state))
            continue
        }
        $jobSeconds = [long][Math]::Round(([datetimeoffset]::Parse($job.completedAt, $invariant) - [datetimeoffset]::Parse($job.startedAt, $invariant)).TotalSeconds)
        $logEndpoint = 'repos/{owner}/{repo}/actions/jobs/' + $job.databaseId + '/logs'
        $log = @(Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('api', '--allow-escape-sequences', $logEndpoint) -NoRetryDelay:$NoRetryDelayForTest)
        $entries = @(foreach ($line in $log) { $entry = ConvertFrom-LogLine $line; if ($null -ne $entry) { $entry } })
        $tests = @(if ($entries.Count -gt 0) { Split-JobTest $entries })
        if ($tests.Count -eq 0) {
            $report.Add(('== {0} ({1}) job {2}s, no Running lines in log' -f $job.name, $state, $jobSeconds))
            continue
        }
        $testsSeconds = ($tests | Measure-Object -Property seconds -Sum).Sum
        $report.Add(('== {0} ({1}) job {2}s, tests: {3} in {4}s' -f $job.name, $state, $jobSeconds, $tests.Count, (Format-Second $testsSeconds)))
        foreach ($test in $tests) {
            $report.Add(('{0,9}s  {1}' -f (Format-Second $test.seconds), $test.label))
            foreach ($stage in $test.stages) { $report.Add(('{0,9}s    - {1}' -f (Format-Second $stage.seconds), $stage.name)) }
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$report
exit 0
