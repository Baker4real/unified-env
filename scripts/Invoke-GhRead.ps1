<#
.SYNOPSIS
运行只读的 gh 命令；gh 非零退出（如偶发 EOF）时退避重试。

.DESCRIPTION
gh 的参数放在 -- 之后，原样转发。成功时原样输出 gh 的 stdout，退出 0。共试 4 次（间隔 2、4、6 秒）仍失败时，
不输出 stdout，把最后一次的错误写到 stderr，退出 1。
只用于读取：写入失败时请求可能已经落地，不能直接重试，规则见 docs/agents/issue-tracker.md「gh 报 EOF 时」。

在 PowerShell 里用 & 调用。-- 之后的参数不会被当成本脚本的参数；不加 --，-d、-v 这类短参数会被 PowerShell
当成公共参数吃掉。pwsh -File 会把 -- 当成参数名，所以不要用 pwsh -File 调用。
gh 按当前目录的 git remote 填 {owner}/{repo}，在仓库根目录运行。

.EXAMPLE
& D:/agents/projects/统一环境/scripts/Invoke-GhRead.ps1 -- run list --branch main --limit 3 --json 'databaseId,status,conclusion'

.EXAMPLE
& D:/agents/projects/统一环境/scripts/Invoke-GhRead.ps1 -- api 'repos/{owner}/{repo}/issues/89' --jq '.state'
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # gh 的参数，放在 -- 之后。
    [Parameter(ValueFromRemainingArguments)][string[]]$GhArguments,
    # 测试专用 seam（生产调用不传）：替身 gh 命令（可执行文件加前置参数）与零等待重试。
    [string[]]$GhCommandForTest,
    [switch]$NoRetryDelayForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 按 UTF-8 解码 gh 的输出（标题、评论含中文）。
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'lib\GitHubCli.ps1')

if ($null -eq $GhArguments -or $GhArguments.Count -eq 0) {
    [Console]::Error.WriteLine('no gh arguments: put them after --, e.g. & Invoke-GhRead.ps1 -- run list')
    exit 1
}
$ghCommand = @(if ($null -ne $GhCommandForTest -and $GhCommandForTest.Count -gt 0) { $GhCommandForTest } else { 'gh' })
try {
    $stdout = @(Invoke-GhWithRetry -GhCommand $ghCommand -Arguments $GhArguments -NoRetryDelay:$NoRetryDelayForTest)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$stdout
exit 0
