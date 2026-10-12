#requires -Version 7.5
<#
.SYNOPSIS
只读采集当前 Explorer 身份、窗口状态计数和固定项聚合哈希。
.DESCRIPTION
默认仅向 stdout 输出 JSON。-OutputPath 可保存快照；不采集窗口标题或展开快捷方式目标。
-TestSessionPath 只供 Test-ExplorerShellRecovery.ps1 的同进程测试会话使用。
#>
[CmdletBinding()]
param([string]$OutputPath, [string]$TestSessionPath, [switch]$AsObject)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/ExplorerShellRecovery.ps1"
$snapshot = Get-ExplorerRecoverySnapshot -TestSessionPath $TestSessionPath
if ($OutputPath) { Write-ExplorerRecoveryJson -Path $OutputPath -Value $snapshot }
if ($AsObject) { $snapshot } else { $snapshot | ConvertTo-Json -Depth 10 }
