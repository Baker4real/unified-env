$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
# git grep 按 UTF-8 输出路径和行文本。
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# 子进程按控制台输出代码页写重定向的 stdout/stderr（CI 的 en-US runner 是 437，本机常见 936 或 65001），不是按当前区域
# 的 OEM 代码页，所以按 OEMCodePage 解码捕获只在两者碰巧相同时才对（af273ed 修的 CI 失败就是这样来的）。启动子进程前把
# [Console]::OutputEncoding 设成 UTF-8，再按 UTF-8 读回；写法见 tests/Test-CodexSafeTreeDeleteFixtureCmdLauncher.ps1。
$hits = @(git -C $repo grep -n -I -F -e 'OEMCodePage' -- '*.ps1' '*.psm1' ':(exclude)tests/Test-NoOemCaptureDecoding.ps1')
$grepExit = $LASTEXITCODE
if ($grepExit -gt 1) { throw "git grep 失败，退出码 $grepExit" }
if ($hits.Count -gt 0) {
    throw ("受版本控制的 PowerShell 按 OEM 代码页解码子进程输出：`n" + ($hits -join "`n"))
}

[pscustomobject]@{
    ok = $true
    test = 'Test-NoOemCaptureDecoding'
} | ConvertTo-Json -Compress
