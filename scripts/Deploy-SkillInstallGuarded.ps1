[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceRoot = '',
    [string]$CodexRoot = 'D:\Codex\.codex',
    [string]$EvidenceRoot = 'D:\agents\run-evidence\skill-install-guarded-deployment',
    [string]$PythonPath = 'D:\Codex\tools\python315-official\python.exe',
    [switch]$AllowUncommittedSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\skill-supply-chain\implementation'
}

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

function Get-FileIdentity {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $PathValue -Force
    return [ordered]@{
        length = [int64]$item.Length
        creationTimeUtcTicks = [int64]$item.CreationTimeUtc.Ticks
        lastWriteTimeUtcTicks = [int64]$item.LastWriteTimeUtc.Ticks
        attributes = [int]$item.Attributes
    }
}

function Get-SourceCommitState {
    # Sources inside a git work tree must match its HEAD, compared through git's clean filter like git status.
    param([Parameter(Mandatory = $true)][string[]]$PathValues)
    $inWorkTree = $false
    $uncommitted = @()
    foreach ($group in @($PathValues | Group-Object { Split-Path -Parent $_ })) {
        $directory = [string]$group.Name
        $inside = @(& git -C $directory rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -ne 0 -or $inside -notcontains 'true') { continue }
        $inWorkTree = $true
        $names = @($group.Group | ForEach-Object { Split-Path -Leaf $_ })
        $treeLines = @(& git -C $directory ls-tree HEAD -- @names)
        if ($LASTEXITCODE -ne 0) { throw "无法读取部署源所在仓库的 HEAD：$directory" }
        $committed = @{}
        foreach ($line in $treeLines) {
            $entry, $name = $line -split "`t", 2
            $committed[$name] = ($entry -split ' ')[2]
        }
        $current = @(& git -C $directory hash-object -- @names)
        if ($LASTEXITCODE -ne 0 -or $current.Count -ne $names.Count) { throw "无法计算部署源的 git blob：$directory" }
        for ($index = 0; $index -lt $names.Count; $index++) {
            if ($committed[$names[$index]] -cne $current[$index]) { $uncommitted += [string]$group.Group[$index] }
        }
    }
    return [pscustomobject]@{ inWorkTree = $inWorkTree; uncommitted = $uncommitted }
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
$repositoryScriptsRootResolved = Resolve-DDrivePath $PSScriptRoot
$moduleImplementationRootResolved = Resolve-DDrivePath (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\skill-supply-chain\implementation')
$codexRootResolved = Resolve-DDrivePath $CodexRoot
$evidenceRootResolved = Resolve-DDrivePath $EvidenceRoot
$pythonPathResolved = Resolve-DDrivePath $PythonPath
$targetRoot = Join-Path $codexRootResolved 'scripts'
$sourceFiles = @(
    'skill_source_record.py',
    'generate_skill_catalog.py',
    'system_skill_provenance_repair.py',
    'system_package_identity.py',
    # Installer modules deploy before the entry that imports them.
    'install_skill_guarded_base.py',
    'install_skill_guarded_tree.py',
    'install_skill_guarded_activation.py',
    'install_skill_guarded_payload.py',
    'install_skill_guarded_source_record.py',
    'install_skill_guarded_bundled.py',
    'install_skill_guarded_closure.py',
    'install_skill_guarded_decision.py',
    'install_skill_guarded_ledger.py',
    'install_skill_guarded_rename.py',
    'install_skill_guarded_retirement.py',
    'install_skill_guarded_system_overlay.py',
    'install_skill_guarded_staging.py',
    'install_skill_guarded.py',
    'install-skill-guarded.cmd'
)
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
    pythonPath = $pythonPathResolved
    yamlDependency = 'pending'
    sourceCommitCheck = 'pending'
    files = @()
}

try {
    if (-not (Test-Path -LiteralPath $sourceRootResolved -PathType Container)) { throw "SourceRoot 不存在：$sourceRootResolved" }
    if (Test-ReparsePoint $sourceRootResolved) { throw "SourceRoot 不能是 reparse point：$sourceRootResolved" }
    $sources = [ordered]@{}
    foreach ($relative in $sourceFiles) {
        $source = Join-Path $sourceRootResolved $relative
        if ($sourceRootResolved -ieq $repositoryScriptsRootResolved -and $relative -ne 'install-skill-guarded.cmd') {
            $source = Join-Path $moduleImplementationRootResolved $relative
        }
        if ($relative -eq 'install-skill-guarded.cmd' -and $sourceRootResolved -ieq $moduleImplementationRootResolved -and -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\install-skill-guarded.cmd'
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少部署源文件：$source" }
        if (Test-ReparsePoint $source) { throw "部署源文件不能是 reparse point：$source" }
        $sources[$relative] = $source
    }
    if ($AllowUncommittedSource) { $manifest.sourceCommitCheck = 'skipped' }
    else {
        $commitState = Get-SourceCommitState @($sources.Values)
        if ($commitState.uncommitted.Count) {
            throw "部署源有未提交的改动（与所在工作树的 HEAD 不一致）：$($commitState.uncommitted -join '、')。共享工作树里可能是别的会话的改动；从工作树外的 git archive 快照部署，或确认这些改动该上线后加 -AllowUncommittedSource。"
        }
        $manifest.sourceCommitCheck = if ($commitState.inWorkTree) { 'matches-head' } else { 'outside-work-tree' }
    }
    if (Test-ReparsePoint $codexRootResolved) { throw "CodexRoot 不能是 reparse point：$codexRootResolved" }
    if (-not (Test-Path -LiteralPath $pythonPathResolved -PathType Leaf)) { throw "受管 Python 不存在：$pythonPathResolved" }
    if (Test-ReparsePoint $pythonPathResolved) { throw "受管 Python 不能是 reparse point：$pythonPathResolved" }
    $pythonProbeArgs = @('-I', '-c', 'import yaml; assert callable(yaml.safe_load)')
    & $pythonPathResolved @pythonProbeArgs
    $pythonProbeExitCode = $LASTEXITCODE
    if ($pythonProbeExitCode -ne 0) {
        throw "受管 Python 缺少 PyYAML 或 yaml.safe_load 不可用，拒绝部署 guarded skill wrapper：exit=$pythonProbeExitCode"
    }
    $manifest.yamlDependency = 'passed'
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    if (Test-ReparsePoint $targetRoot) { throw "目标 scripts 目录不能是 reparse point：$targetRoot" }
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

    foreach ($relative in $sourceFiles) {
        $source = $sources[$relative]
        $target = Join-Path $targetRoot $relative
        if (Test-ReparsePoint $target) { throw "部署目标文件不能是 reparse point：$target" }
        $record = [ordered]@{
            relative = $relative
            source = $source
            target = $target
            sourceSha256 = Get-FileHashUpper $source
            beforeExists = Test-Path -LiteralPath $target -PathType Leaf
            beforeIdentity = Get-FileIdentity $target
            beforeSha256 = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-FileHashUpper $target } else { $null }
            backup = $null
            backupIdentity = $null
            writtenIdentity = $null
            status = 'prepared'
        }
        $manifest.files += $record
    }
    Write-JsonAtomic -PathValue $manifestPath -Value $manifest

    foreach ($record in $manifest.files) {
        if (-not $PSCmdlet.ShouldProcess([string]$record.target, 'deploy guarded skill wrapper')) { continue }
        if ([bool]$record.beforeExists) {
            if ((Get-FileIdentity ([string]$record.target) | ConvertTo-Json -Compress) -ne ([string]($record.beforeIdentity | ConvertTo-Json -Compress))) {
                throw "部署目标 identity 在写入前漂移：$($record.target)"
            }
            if ((Get-FileHashUpper ([string]$record.target)) -ne [string]$record.beforeSha256) {
                throw "部署目标 hash 在写入前漂移：$($record.target)"
            }
            $backup = Join-Path $evidenceDirectory ('before-' + [IO.Path]::GetFileName([string]$record.target))
            Copy-Item -LiteralPath ([string]$record.target) -Destination $backup -Force
            $record.backup = $backup
            $record.backupIdentity = Get-FileIdentity $backup
        }
        elseif (Test-Path -LiteralPath ([string]$record.target)) {
            throw "部署目标在写入前从不存在变为已存在：$($record.target)"
        }
        $replaced += $record
        $temp = Join-Path $targetRoot ('.' + [IO.Path]::GetFileName([string]$record.target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            Copy-Item -LiteralPath ([string]$record.source) -Destination $temp -Force
            if ((Get-FileHashUpper $temp) -ne [string]$record.sourceSha256) { throw "临时部署指纹不一致：$temp" }
            if ([bool]$record.beforeExists) {
                Move-Item -LiteralPath $temp -Destination ([string]$record.target) -Force
            }
            else {
                [IO.File]::Move($temp, [string]$record.target, $false)
            }
            $record.writtenIdentity = Get-FileIdentity ([string]$record.target)
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
    [pscustomobject]@{
        ok = $true
        status = $manifest.status
        targetRoot = $targetRoot
        evidence = $evidenceDirectory
        pythonPath = $pythonPathResolved
        yamlDependency = $manifest.yamlDependency
        sourceCommitCheck = $manifest.sourceCommitCheck
        files = $manifest.files
    }
}
catch {
    $failure = $_.Exception.Message
    $rollbackErrors = @()
    foreach ($record in @($replaced | Sort-Object -Property relative -Descending)) {
        try {
            $currentIdentity = Get-FileIdentity ([string]$record.target)
            $currentHash = if ($currentIdentity) { Get-FileHashUpper ([string]$record.target) } else { $null }
            if ($record.writtenIdentity -and (
                ($currentIdentity | ConvertTo-Json -Compress) -ne ([string]($record.writtenIdentity | ConvertTo-Json -Compress)) -or
                $currentHash -ne [string]$record.sourceSha256
            )) {
                throw "部署目标在 rollback 前已被外部修改：$($record.target)"
            }
            if ($record.backup) {
                if (-not $record.writtenIdentity -and [bool]$record.beforeExists) {
                    if (-not $currentIdentity -or
                        ($currentIdentity | ConvertTo-Json -Compress) -ne ([string]($record.beforeIdentity | ConvertTo-Json -Compress)) -or
                        $currentHash -ne [string]$record.beforeSha256
                    ) {
                        throw "部署 rollback 前目标已偏离 baseline：$($record.target)"
                    }
                }
                if (-not (Test-Path -LiteralPath ([string]$record.backup) -PathType Leaf)) {
                    throw "部署 rollback backup 缺失：$($record.target)"
                }
                if ($record.backupIdentity -and ((Get-FileIdentity ([string]$record.backup) | ConvertTo-Json -Compress) -ne ([string]($record.backupIdentity | ConvertTo-Json -Compress)))) {
                    throw "部署 rollback backup identity 已漂移：$($record.target)"
                }
                if ((Get-FileHashUpper ([string]$record.backup)) -ne [string]$record.beforeSha256) {
                    throw "部署 rollback backup hash 已漂移：$($record.target)"
                }
                Copy-Item -LiteralPath ([string]$record.backup) -Destination ([string]$record.target) -Force
                if ((Get-FileHashUpper ([string]$record.target)) -ne [string]$record.beforeSha256) {
                    throw "部署目标 rollback hash 校验失败：$($record.target)"
                }
            }
            elseif ($record.writtenIdentity) {
                if (-not (Test-Path -LiteralPath ([string]$record.target) -PathType Leaf)) {
                    throw "部署 rollback 目标缺失：$($record.target)"
                }
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
