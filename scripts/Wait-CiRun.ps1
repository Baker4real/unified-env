<#
.SYNOPSIS
等一个已推送提交的 ci.yml run 跑完，列出每个 job 的结论和耗时；没通过时接着给出 Get-CiFailureSummary.ps1 的失败摘要。只读。

.DESCRIPTION
每隔 PollSeconds 秒用 gh run list --commit <Sha> --workflow ci.yml 查一次这个提交最新的 run，直到它跑完或等满
TimeoutMinutes 分钟（至少查一次）。某次查询失败不算结论，下一轮照常再查。gh 按当前目录的仓库解析 run，脚本在本仓库
根目录里调用它，所以可以从任何目录运行。
跑完后输出纯文本：第一行是 run 的 id、结论、标题和链接，之后每个 job 一行：结论、耗时（gh 给的 startedAt 到
completedAt，整秒）和 job 名。退出码：
- 0：跑完且通过（success、neutral、skipped）。
- 1：跑完但没通过，job 列表后面附 Get-CiFailureSummary.ps1 的输出。
- 2：等满时间仍没有结论（这个提交还没有 run、run 还在跑，或最后一次查询失败），原因写到 stderr。

.EXAMPLE
& D:/agents/projects/统一环境/scripts/Wait-CiRun.ps1 -Sha (git -C D:/agents/projects/统一环境 rev-parse HEAD)
#>
[CmdletBinding()]
param(
    # 完整的 40 位 SHA：给 gh run list --commit 短 SHA 时它什么也查不到，也不报错。
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Sha,
    [ValidateRange(0, 3600)][int]$PollSeconds = 30,
    [ValidateRange(0, 1440)][int]$TimeoutMinutes = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 按 UTF-8 解码 gh 的输出（标题和 job 名含中文）。
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'lib\GitHubCli.ps1')

$ghCommand = @('gh')
$passingConclusions = @('success', 'neutral', 'skipped')
$invariant = [Globalization.CultureInfo]::InvariantCulture
$listArguments = @('run', 'list', '--commit', $Sha, '--workflow', 'ci.yml', '--limit', '1', '--json', 'databaseId,status,conclusion,displayTitle,url')

$exitCode = 2
Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
try {
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $run = $null
    $lastError = ''
    while ($true) {
        $result = Invoke-Gh -GhCommand $ghCommand -Arguments $listArguments
        if ($result.exitCode -eq 0) {
            $lastError = ''
            $run = @(($result.stdout -join "`n") | ConvertFrom-Json) | Select-Object -First 1
            if ($null -ne $run -and $run.status -ceq 'completed') { break }
        } else {
            $lastError = 'gh 退出码 {0}：{1}' -f $result.exitCode, $result.stderr
        }
        if ([datetime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    if ($null -eq $run -or $run.status -cne 'completed') {
        $reason = if ($lastError) { "最后一次查询失败（$lastError）" }
            elseif ($null -eq $run) { "提交 $Sha 还没有 ci.yml run" }
            else { 'run 仍是 {0}：{1}' -f $run.status, $run.url }
        [Console]::Error.WriteLine(('等了 {0} 分钟没有结论：{1}' -f $TimeoutMinutes, $reason))
    } else {
        $view = (Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('run', 'view', [string]$run.databaseId, '--json', 'jobs')) -join "`n" | ConvertFrom-Json -DateKind String
        'run {0} {1}: {2} {3}' -f $run.databaseId, $run.conclusion, $run.displayTitle, $run.url
        foreach ($job in @($view.jobs)) {
            $duration = if ($job.startedAt -and $job.completedAt) {
                '{0}s' -f [long][Math]::Round(([datetimeoffset]::Parse($job.completedAt, $invariant) - [datetimeoffset]::Parse($job.startedAt, $invariant)).TotalSeconds)
            } else { '-' }
            '{0} {1} {2}' -f $job.conclusion, $duration, $job.name
        }
        if ($run.conclusion -in $passingConclusions) {
            $exitCode = 0
        } else {
            $exitCode = 1
            ''
            & (Join-Path $PSScriptRoot 'Get-CiFailureSummary.ps1') -RunId ([long]$run.databaseId)
        }
    }
} finally {
    Pop-Location
}
exit $exitCode
