[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/pre-commit-privacy-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# .githooks/pre-commit 经真实 git commit 扫描暂存改动。夹具仓库建一次后保留复用（不递归删除），每轮提交后退回初始提交；
# 样例地址拼接写，本文件提交进公开仓库时不被自己拦下。
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$hooksPath = Join-Path $projectRoot '.githooks'
$utf8 = [Text.UTF8Encoding]::new($false)
# hook 的中文提示按 UTF-8 输出，捕获时按 UTF-8 解码，结果不随运行机器的代码页变化。
[Console]::OutputEncoding = $utf8

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Commit([string]$Repo, [string]$Ack) {
    $ErrorActionPreference = 'Continue'
    $previous = $env:COMMIT_PRIVACY_ACK
    $env:COMMIT_PRIVACY_ACK = $Ack
    try {
        $output = git -C $Repo -c user.name=probe -c user.email=1+probe@users.noreply.github.com commit -q -m probe 2>&1 | Out-String
        return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output }
    }
    finally { $env:COMMIT_PRIVACY_ACK = $previous }
}

function Set-StagedFile([string]$Repo, [string]$Name, [string]$Text) {
    [IO.File]::WriteAllText((Join-Path $Repo $Name), $Text, $utf8)
    git -C $Repo add -- $Name
    Assert-True ($LASTEXITCODE -eq 0) "git add $Name 失败。"
}

$repo = Join-Path $FixtureRoot 'pre-commit-privacy-repo'
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    [void][IO.Directory]::CreateDirectory($repo)
    git -C $repo init -q -b main
    git -C $repo config core.autocrlf false
    git -C $repo -c user.name=probe -c user.email=1+probe@users.noreply.github.com commit -q --allow-empty -m init
}
git -C $repo config core.hooksPath $hooksPath
$base = git -C $repo rev-parse HEAD
git -C $repo reset -q

$tailscaleLine = '- node: 100.' + "101.2.3`n"
Set-StagedFile $repo 'hosts.md' $tailscaleLine
$denied = Invoke-Commit $repo ''
Assert-True ($denied.exitCode -ne 0) "暂存改动含 Tailscale 地址时必须拒绝提交：$($denied.output)"
Assert-True ($denied.output -match 'fp=aec3a99b70）：hosts\.md:1' -and $denied.output -notmatch ('100\.' + '101\.2\.3')) "拒绝理由必须给指纹与位置并遮掩原值：$($denied.output)"
Assert-True ((git -C $repo rev-parse HEAD) -eq $base) '被拒绝的提交不能落地。'

$acknowledged = Invoke-Commit $repo 'aec3a99b70'
Assert-True ($acknowledged.exitCode -eq 0) "COMMIT_PRIVACY_ACK 给出指纹后必须放行：$($acknowledged.output)"
git -C $repo reset -q --soft $base

Set-StagedFile $repo 'hosts.md' "- node: <tailscale-ip>`n"
Set-StagedFile $repo 'AGENTS.md' "# probe`n"
$clean = Invoke-Commit $repo ''
Assert-True ($clean.exitCode -eq 0) "干净的暂存改动必须放行：$($clean.output)"
Assert-True ($clean.output -match 'AGENTS\.md 变更') "暂存 AGENTS.md 时必须提醒：$($clean.output)"
git -C $repo reset -q --soft $base
git -C $repo reset -q

'pre-commit privacy hook: all checks passed'
