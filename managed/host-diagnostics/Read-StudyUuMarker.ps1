#requires -Version 7.4
<#
.SYNOPSIS
经同目录的 Invoke-RemoteStep.ps1 在 study 回读 UU marker，返回它是否与预期一致。
.DESCRIPTION
路径、哈希和 runId 以 Base64 嵌入生成的远端脚本，不拼进引号。回读走 SSH；SSH 不可用或回读失败时返回 $false。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MarkerPath,
    [Parameter(Mandatory)][string]$ExpectedHash,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][int]$Index,
    [string]$EvidenceRoot = 'D:/agents/run-evidence/uu-marker-readers'
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$stepEntry = Join-Path $PSScriptRoot 'Invoke-RemoteStep.ps1'
$runDirectory = Join-Path $EvidenceRoot ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$remoteScript = Join-Path $runDirectory 'Read-Marker.ps1'
function ConvertTo-Base64Utf8([string]$Text) { [Convert]::ToBase64String($utf8.GetBytes($Text)) }
$body = @'
$ErrorActionPreference = 'Stop'
function ConvertFrom-Base64Utf8([string]$Value) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }
$path = ConvertFrom-Base64Utf8 '__PATH__'
$expected = ConvertFrom-Base64Utf8 '__HASH__'
$runId = ConvertFrom-Base64Utf8 '__RUN__'
$index = __INDEX__
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    [ordered]@{ matched = $false; reason = 'missing' } | ConvertTo-Json -Compress
    exit 0
}
$marker = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
$matched = $marker.runId -eq $runId -and [int]$marker.index -eq $index -and $marker.commandSha256 -eq $expected
[ordered]@{ matched = $matched } | ConvertTo-Json -Compress
'@.Replace('__PATH__', (ConvertTo-Base64Utf8 $MarkerPath)).Replace('__HASH__', (ConvertTo-Base64Utf8 $ExpectedHash)).Replace('__RUN__', (ConvertTo-Base64Utf8 $RunId)).Replace('__INDEX__', [string]$Index)
[IO.File]::WriteAllText($remoteScript, $body, $utf8)
try {
    $global:LASTEXITCODE = 0
    $stepOutput = @(& $stepEntry -Target study -ScriptPath $remoteScript -TimeoutSeconds 20 -IncludeOutput)
    if ($LASTEXITCODE -ne 0) { return $false }
    $summary = ($stepOutput | Select-Object -Last 1) | ConvertFrom-Json
    $result = $summary.output | ConvertFrom-Json
    return $result.matched -eq $true
} catch {
    return $false
}
