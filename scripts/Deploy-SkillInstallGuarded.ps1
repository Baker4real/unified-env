[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceRoot = $PSScriptRoot,
    [string]$CodexRoot = 'D:\Codex\.codex',
    [string]$EvidenceRoot = 'D:\Codex\.codex\run-evidence\skill-install-guarded-deployment'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DDrivePath {
    param([Parameter(Mandatory = $true)][string]$Value)
    $full = [System.IO.Path]::GetFullPath($Value)
    if (-not $full.StartsWith('D:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径必须位于 D 盘：$full"
    }
    return $full.TrimEnd('\')
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    if (-not (Test-Path -LiteralPath $PathValue)) { return $false }
    return ((Get-Item -LiteralPath $PathValue -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Get-FileHashUpper {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    return (Get-FileHash -LiteralPath $PathValue -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][object]$Value
    )
    if ($WhatIfPreference) { return }
    $parent = Split-Path -Parent $PathValue
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($PathValue) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $PathValue -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

$sourceRootResolved = Resolve-DDrivePath $SourceRoot
$codexRootResolved = Resolve-DDrivePath $CodexRoot
$evidenceRootResolved = Resolve-DDrivePath $EvidenceRoot
$targetRoot = Join-Path $codexRootResolved 'scripts'
$sourceFiles = @('install_skill_guarded.py', 'install-skill-guarded.cmd')
$evidenceDirectory = Join-Path $evidenceRootResolved ('deploy-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
$manifestPath = Join-Path $evidenceDirectory 'manifest.json'
$records = @()
$replaced = @()
$manifest = [ordered]@{
    schemaVersion = 1
    status = 'prepared'
    sourceRoot = $sourceRootResolved
    targetRoot = $targetRoot
    evidenceDirectory = $evidenceDirectory
    files = @()
}

try {
    if (-not (Test-Path -LiteralPath $sourceRootResolved -PathType Container)) { throw "SourceRoot 不存在：$sourceRootResolved" }
    if (Test-ReparsePoint $sourceRootResolved) { throw "SourceRoot 不能是 reparse point：$sourceRootResolved" }
    if (Test-ReparsePoint $codexRootResolved) { throw "CodexRoot 不能是 reparse point：$codexRootResolved" }
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    if (Test-ReparsePoint $targetRoot) { throw "目标 scripts 目录不能是 reparse point：$targetRoot" }
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

    foreach ($relative in $sourceFiles) {
        $source = Join-Path $sourceRootResolved $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少部署源文件：$source" }
        if (Test-ReparsePoint $source) { throw "部署源文件不能是 reparse point：$source" }
        $target = Join-Path $targetRoot $relative
        if (Test-ReparsePoint $target) { throw "部署目标文件不能是 reparse point：$target" }
        $record = [ordered]@{
            relative = $relative
            source = $source
            target = $target
            sourceSha256 = Get-FileHashUpper $source
            beforeExists = Test-Path -LiteralPath $target -PathType Leaf
            beforeSha256 = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-FileHashUpper $target } else { $null }
            backup = $null
            status = 'prepared'
        }
        $manifest.files += $record
    }
    Write-JsonAtomic -PathValue $manifestPath -Value $manifest

    foreach ($record in $manifest.files) {
        if (-not $PSCmdlet.ShouldProcess([string]$record.target, 'deploy guarded skill wrapper')) { continue }
        if ([bool]$record.beforeExists) {
            $backup = Join-Path $evidenceDirectory ('before-' + [IO.Path]::GetFileName([string]$record.target))
            Copy-Item -LiteralPath ([string]$record.target) -Destination $backup -Force
            $record.backup = $backup
        }
        $replaced += $record
        $temp = Join-Path $targetRoot ('.' + [IO.Path]::GetFileName([string]$record.target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            Copy-Item -LiteralPath ([string]$record.source) -Destination $temp -Force
            if ((Get-FileHashUpper $temp) -ne [string]$record.sourceSha256) { throw "临时部署指纹不一致：$temp" }
            Move-Item -LiteralPath $temp -Destination ([string]$record.target) -Force
            if ((Get-FileHashUpper ([string]$record.target)) -ne [string]$record.sourceSha256) { throw "目标部署指纹不一致：$($record.target)" }
            $record.status = 'deployed'
        }
        finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    }

    $manifest.status = if ($WhatIfPreference) { 'what-if' } else { 'succeeded' }
    $manifest.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonAtomic -PathValue $manifestPath -Value $manifest
    [pscustomobject]@{ ok = $true; status = $manifest.status; targetRoot = $targetRoot; evidence = $evidenceDirectory; files = $manifest.files }
}
catch {
    $failure = $_.Exception.Message
    $rollbackErrors = @()
    foreach ($record in @($replaced | Sort-Object -Property relative -Descending)) {
        try {
            if ($record.backup) {
                Copy-Item -LiteralPath ([string]$record.backup) -Destination ([string]$record.target) -Force
            }
            elseif (Test-Path -LiteralPath ([string]$record.target)) {
                Remove-Item -LiteralPath ([string]$record.target) -Force
            }
        }
        catch { $rollbackErrors += "$($record.relative): $($_.Exception.Message)" }
    }
    $manifest.status = if ($rollbackErrors.Count) { 'rollback-failed' } else { 'rolled-back' }
    $manifest.error = $failure
    $manifest.rollbackErrors = $rollbackErrors
    $manifest.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    if (Test-Path -LiteralPath $evidenceDirectory) { Write-JsonAtomic -PathValue $manifestPath -Value $manifest }
    throw
}
