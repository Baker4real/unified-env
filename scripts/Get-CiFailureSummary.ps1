<#
.SYNOPSIS
把一次 GitHub Actions run 的失败日志压成几行：每个失败 job 只留失败的测试、报错行和失败标记。只读。

.DESCRIPTION
读 gh run view <RunId> --json 的 job 列表和 gh run view <RunId> --log-failed 的日志；读取失败时按
docs/agents/issue-tracker.md「gh 报 EOF 时」退避重试。输出纯文本，第一行是 run 的名称、标题、状态和链接，
之后每个失败 job 一段，以 == <job> (<结论>) failed step: <步骤> 开头：
- 失败标记是 Run-PowerShellTests.cjs 打印的「<测试> failed with exit code N」，没有这一行时用第一条 ##[error] 行。
- 从标记往前找最近的 Running <测试> 行，只保留它和标记之间的报错行：含 exception、error、fail、assert、
  traceback 的行，以及 PowerShell 报错块里以 | 对齐的行，最多 30 行。没有失败标记时给出最后 20 行。
- 去掉 ANSI 颜色（ESC 或字面的 ^[ 开头）和时间戳，每行最多 300 个字符。
没有失败的 job 时只输出 no failed jobs，不读日志。gh 重试用完仍失败时不输出摘要，错误写到 stderr，退出 1。
需要完整日志时另跑 gh run view <RunId> --log-failed。

.EXAMPLE
& D:/agents/projects/统一环境/scripts/Get-CiFailureSummary.ps1 -RunId 39623094219
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

$lineLimit = 300
$keyLineLimit = 30
$tailLimit = 20
$failureMarker = 'failed with exit code'
$keyLinePattern = '(?i)\b(exception|error|fail\w*|assert\w*|traceback)\b|^\s*(\d+\s+)?\||^Line \|'
$passingConclusions = @('success', 'skipped', 'neutral')

# --log-failed 的每行是「job<TAB>step<TAB>时间戳 文本」。返回 job 名和去掉时间戳、颜色、行尾空白并截断后的文本。
function Split-LogLine([string]$Line) {
    $parts = $Line.Split("`t", 3)
    if ($parts.Count -lt 3) { return $null }
    $text = $parts[2] -replace '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?', ''
    # 日志里的 ESC 可能是控制字符，也可能写成字面的 ^[（实测 run 39623094219 是后者）。
    $text = ($text -replace '(?:\x1b|\^\[)\[[0-9;]*[A-Za-z]', '').TrimEnd()
    if ($text.Length -gt $lineLimit) { $text = $text.Substring(0, $lineLimit) + '...' }
    return [pscustomobject]@{ job = $parts[0].TrimStart([char]0xFEFF); text = $text }
}

# 一个失败 job 的日志里要保留的行。
function Select-JobLine([string[]]$Lines) {
    $markerIndex = [Array]::FindIndex($Lines, [Predicate[string]] { param($line) $line.Contains($failureMarker) })
    if ($markerIndex -lt 0) { $markerIndex = [Array]::FindIndex($Lines, [Predicate[string]] { param($line) $line.StartsWith('##[error]') }) }
    if ($markerIndex -lt 0) { return @($Lines | Select-Object -Last $tailLimit) }
    $startIndex = [Array]::FindLastIndex($Lines, $markerIndex, [Predicate[string]] { param($line) $line.StartsWith('Running ') })
    $selected = [Collections.Generic.List[string]]::new()
    if ($startIndex -ge 0) { $selected.Add($Lines[$startIndex]) }
    $keyLines = @(for ($i = $startIndex + 1; $i -lt $markerIndex; $i++) { if ($Lines[$i] -match $keyLinePattern) { $Lines[$i] } })
    foreach ($line in @($keyLines | Select-Object -Last $keyLineLimit)) { $selected.Add($line) }
    $markers = @(for ($i = $markerIndex; $i -lt $Lines.Count; $i++) { if ($Lines[$i].Contains($failureMarker) -or $Lines[$i].StartsWith('##[error]')) { $Lines[$i] } })
    foreach ($line in @($markers | Select-Object -First 3)) { $selected.Add($line) }
    return $selected.ToArray()
}

$ghCommand = @(if ($null -ne $GhCommandForTest -and $GhCommandForTest.Count -gt 0) { $GhCommandForTest } else { 'gh' })
$summary = [Collections.Generic.List[string]]::new()
try {
    $runFields = 'databaseId,name,displayTitle,status,conclusion,url,jobs'
    $run = (Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('run', 'view', [string]$RunId, '--json', $runFields) -NoRetryDelay:$NoRetryDelayForTest) -join "`n" | ConvertFrom-Json
    $jobs = @($run.jobs)
    $failedJobs = @($jobs | Where-Object { $_.conclusion -and $_.conclusion -notin $passingConclusions })
    $summary.Add(('run {0} {1}: {2} [{3}/{4}] {5}' -f $RunId, $run.name, $run.displayTitle, $run.status, $run.conclusion, $run.url))
    if ($failedJobs.Count -eq 0) {
        $summary.Add('no failed jobs')
    } else {
        $summary.Add(('failed jobs: {0} of {1}' -f $failedJobs.Count, $jobs.Count))
        $log = @(Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('run', 'view', [string]$RunId, '--log-failed') -NoRetryDelay:$NoRetryDelayForTest)
        $entries = @($log | ForEach-Object { Split-LogLine $_ } | Where-Object { $null -ne $_ })
        foreach ($job in $failedJobs) {
            $failedSteps = @($job.steps | Where-Object { $_.conclusion -and $_.conclusion -notin $passingConclusions } | ForEach-Object { $_.name })
            $summary.Add(('== {0} ({1}) failed step: {2}' -f $job.name, $job.conclusion, $(if ($failedSteps.Count -gt 0) { $failedSteps -join ', ' } else { '(none)' })))
            $jobLines = @($entries | Where-Object { $_.job -ceq $job.name } | ForEach-Object { $_.text })
            if ($jobLines.Count -eq 0) {
                $summary.Add('(no log lines for this job)')
                continue
            }
            foreach ($line in @(Select-JobLine $jobLines)) { $summary.Add($line) }
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$summary
exit 0
