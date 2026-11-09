#requires -Version 7.4
<#
.SYNOPSIS
经同目录的 Invoke-OfficeRemote.ps1 在 office/study 执行本地脚本，以 helper 的运行摘要做业务门禁。
.DESCRIPTION
helper 每次运行都在 stdout 打印一行 JSON 摘要（与它写的 .run.json 内容相同，连接前拒绝时也打印），
本入口解析这一行，不按文件名推算 .run.json，也就不会读到上一次留下的结果。result 不是 ok、
目标错配、helper 或远端非零退出都返回 1。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('office', 'study')][string]$Target,
    [Parameter(Mandatory)][string]$ScriptPath,
    [string]$OutputPath,
    [string]$StdinScript,
    [int]$TimeoutSeconds = 300,
    [switch]$WriteOperation,
    [switch]$IncludeOutput,
    [ValidateRange(1, 1048576)][int]$MaxOutputChars = 65536
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$remoteHelperPath = Join-Path $PSScriptRoot 'Invoke-OfficeRemote.ps1'
if (-not (Test-Path -LiteralPath $remoteHelperPath -PathType Leaf)) { throw 'Invoke-OfficeRemote.ps1 is missing next to Invoke-RemoteStep.ps1' }
$helperArguments = @{
    Target = $Target
    ScriptPath = $ScriptPath
    TimeoutSeconds = $TimeoutSeconds
}
if ($OutputPath) { $helperArguments.OutputPath = $OutputPath }
if ($StdinScript) { $helperArguments.StdinScript = $StdinScript }
if ($WriteOperation) { $helperArguments.RequireRemoteContext = $true }
$global:LASTEXITCODE = 0
$helperOutput = @(& $remoteHelperPath @helperArguments)
$helperExitCode = [int]$LASTEXITCODE
$summaryLine = @($helperOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
$run = $null
if ($summaryLine) {
    try { $run = $summaryLine | ConvertFrom-Json -ErrorAction Stop } catch { $run = $null }
}
if ($null -eq $run -or $null -eq $run.PSObject.Properties['result']) { throw 'Remote helper did not print a run summary' }
$status = [string]$run.result
$remoteExitCode = if ($null -ne $run.PSObject.Properties['exitCode']) { [int]$run.exitCode } else { $null }
$summary = [ordered]@{
    status = $status
    target = [string]$run.target
    exitCode = $remoteExitCode
    helperExitCode = $helperExitCode
    outputPath = [string]$run.stdout
}
if ($status -eq 'refused') { $summary.reason = [string]$run.reason }
if ($IncludeOutput) {
    $hasOutput = $summary.outputPath -and (Test-Path -LiteralPath $summary.outputPath -PathType Leaf)
    if (-not $hasOutput -and $status -eq 'ok') { throw "Remote output is missing: $($summary.outputPath)" }
    $summary.output = $null
    $summary.outputTruncated = $false
    if ($hasOutput) {
        $reader = [IO.StreamReader]::new($summary.outputPath, [Text.UTF8Encoding]::new($false))
        try {
            $buffer = [char[]]::new($MaxOutputChars + 1)
            $read = $reader.ReadBlock($buffer, 0, $buffer.Length)
        } finally { $reader.Dispose() }
        $length = [Math]::Min($read, $MaxOutputChars)
        # 截断处不留半个代理对。
        if ($read -gt $MaxOutputChars -and $length -gt 0 -and [char]::IsHighSurrogate($buffer[$length - 1])) { $length-- }
        $summary.output = [string]::new($buffer, 0, $length)
        $summary.outputTruncated = $read -gt $MaxOutputChars
    }
}
$summary | ConvertTo-Json -Compress
if ($helperExitCode -ne 0 -or $remoteExitCode -ne 0 -or $status -ne 'ok' -or $summary.target -ne $Target) { exit 1 }
