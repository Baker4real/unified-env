#Requires -Version 7.4
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/screenshot-geometry')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$runRoot = Join-Path $EvidenceRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $runRoot -Force
$logPath = Join-Path $runRoot 'node-tests.tap'
$testPath = Join-Path $PSScriptRoot 'screenshot-geometry.test.mjs'
$node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

# 子进程的失败是套件结果，不把原始 TAP 混入 JSON 报告。
$PSNativeCommandUseErrorActionPreference = $false
& $node --test --test-reporter=tap $testPath *> $logPath
$code = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
$tap = [IO.File]::ReadAllText($logPath)
$count = [regex]::Match($tap, '(?m)^# tests (\d+)\r?$')
$passed = [regex]::Match($tap, '(?m)^# pass (\d+)\r?$')
$rows = @([regex]::Matches($tap, '(?m)^ok \d+ - (.+)\r?$') | ForEach-Object {
    [pscustomobject]@{ name = $_.Groups[1].Value.TrimEnd("`r"); passed = $true }
})
$complete = $code -eq 0 -and $count.Success -and $passed.Success -and
    [int]$count.Groups[1].Value -gt 0 -and $count.Groups[1].Value -eq $passed.Groups[1].Value -and
    $rows.Count -eq [int]$count.Groups[1].Value -and
    $tap -match '(?m)^# fail 0\r?$' -and $tap -match '(?m)^# cancelled 0\r?$' -and
    $tap -match '(?m)^# skipped 0\r?$'

[pscustomobject]@{
    status = if ($complete) { 'passed' } else { 'failed' }
    cases = if ($count.Success) { [int]$count.Groups[1].Value } else { 0 }
    results = $rows
    nodeExitCode = $code
    log = $logPath
} | ConvertTo-Json -Depth 5 -Compress
if (-not $complete) { exit 1 }
