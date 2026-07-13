[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $CodexRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $EvidenceRoot,

    [Parameter(Mandatory = $false)]
    [int] $InjectFailureAfter = -1,

    [Parameter(Mandatory = $false)]
    [switch] $InjectConcurrentChangeBeforeRollback
)

$ErrorActionPreference = 'Stop'

function Resolve-DPath {
    param([Parameter(Mandatory = $true)][string] $PathValue)
    $resolved = [System.IO.Path]::GetFullPath($PathValue)
    if ($resolved -notmatch '^(?i)D:[\\/]') {
        throw "目标必须位于 D: 盘：$PathValue"
    }
    return $resolved
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $CandidatePath
    )
    $root = ([System.IO.Path]::GetFullPath($RootPath)).TrimEnd('\') + '\'
    $candidate = [System.IO.Path]::GetFullPath($CandidatePath)
    return $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidate.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-ControlledEvidencePath {
    param([Parameter(Mandatory = $true)][string] $PathValue)
    $resolved = Resolve-DPath -PathValue $PathValue
    $controlledRoot = Resolve-DPath -PathValue 'D:\Codex\.codex\run-evidence\github-default-branch-skill-policy'
    if (-not (Test-PathWithin -RootPath $controlledRoot -CandidatePath $resolved)) {
        throw "EvidenceRoot 必须位于 $controlledRoot：$PathValue"
    }
    return $resolved
}

function Get-HashUpper {
    param([Parameter(Mandatory = $true)][string] $PathValue)
    return (Get-FileHash -LiteralPath $PathValue -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string] $PathValue,
        [Parameter(Mandatory = $true)] $Value
    )
    $directory = Split-Path -Parent $PathValue
    $temp = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($PathValue) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $PathValue -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

$sourceRootResolved = Resolve-DPath -PathValue $SourceRoot
$codexRootResolved = Resolve-DPath -PathValue $CodexRoot
$evidenceRootResolved = Resolve-ControlledEvidencePath -PathValue $EvidenceRoot
$sourceFiles = @(
    'Apply-GitHubDefaultBranchSkillOverlay.cjs',
    'github-default-branch-skill-overlay-catalog.json'
)
$runtimeDirectory = Join-Path $codexRootResolved 'scripts'
$deployment = @()
$replacedFiles = @()
$evidenceDirectory = Join-Path $evidenceRootResolved ('deploy-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
$manifestPath = Join-Path $evidenceDirectory 'manifest.json'
$manifest = [ordered]@{
    version = 1
    status = 'prepared'
    sourceRoot = $sourceRootResolved
    codexRoot = $codexRootResolved
    evidenceDirectory = $evidenceDirectory
    files = @()
}

try {
    if (-not (Test-Path -LiteralPath $sourceRootResolved -PathType Container)) {
        throw "SourceRoot 不存在：$sourceRootResolved"
    }
    foreach ($relative in $sourceFiles) {
        $source = Join-Path $sourceRootResolved $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "缺少部署源文件：$source"
        }
        $sourceHash = Get-HashUpper -PathValue $source
        $target = Join-Path $runtimeDirectory $relative
        $targetHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-HashUpper -PathValue $target } else { $null }
        $deployment += [ordered]@{
            relative = $relative
            sha256 = $sourceHash
            target = $target
            existingSha256 = $targetHash
            changed = ($targetHash -ne $sourceHash)
        }
        $manifest.files += [ordered]@{
            relative = $relative
            source = $source
            target = $target
            sourceSha256 = $sourceHash
            existingSha256 = $targetHash
            status = 'prepared'
        }
    }

    if ($PSCmdlet.ShouldProcess($evidenceDirectory, 'create overlay deployment evidence')) {
        New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
        Write-JsonAtomic -PathValue $manifestPath -Value $manifest
    }

    foreach ($file in $manifest.files) {
        $source = [string] $file.source
        $target = [string] $file.target
        $targetDirectory = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            if ($PSCmdlet.ShouldProcess($targetDirectory, 'create runtime scripts directory')) {
                New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
            }
        }

        if ($PSCmdlet.ShouldProcess($target, 'deploy byte-identical GitHub default-branch overlay file')) {
            $hadTarget = Test-Path -LiteralPath $target -PathType Leaf
            if ($hadTarget) {
                $backup = Join-Path $evidenceDirectory ('before-' + [System.IO.Path]::GetFileName($target))
                Copy-Item -LiteralPath $target -Destination $backup -Force
                $file.backup = $backup
            }
            if ($InjectFailureAfter -ge 0 -and $replacedFiles.Count -ge $InjectFailureAfter) {
                throw "injected deployment failure before $($file.relative)"
            }
            $temp = Join-Path $targetDirectory ('.' + [System.IO.Path]::GetFileName($target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Copy-Item -LiteralPath $source -Destination $temp -Force
                if ((Get-HashUpper -PathValue $temp) -ne [string] $file.sourceSha256) {
                    throw "临时部署文件指纹不匹配：$temp"
                }
                Move-Item -LiteralPath $temp -Destination $target -Force
                $replacedFiles += [pscustomobject]@{
                    target = $target
                    backup = if ($hadTarget) { [string] $file.backup } else { $null }
                    hadTarget = $hadTarget
                    originalSha256 = [string] $file.existingSha256
                    file = $file
                }
                if ((Get-HashUpper -PathValue $target) -ne [string] $file.sourceSha256) {
                    throw "runtime 文件指纹不匹配：$target"
                }
                $file.status = 'deployed'
            }
            finally {
                if (Test-Path -LiteralPath $temp) {
                    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                }
            }
        }
        elseif (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $file.status = 'would-deploy'
        }
        else {
            $file.status = if ([string] $file.existingSha256 -eq [string] $file.sourceSha256) { 'already-current' } else { 'would-deploy' }
        }
    }

    $manifest.status = if ($WhatIfPreference) { 'what-if' } else { 'succeeded' }
    $manifest.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    if ($PSCmdlet.ShouldProcess($manifestPath, 'write final deployment evidence')) {
        Write-JsonAtomic -PathValue $manifestPath -Value $manifest
    }

    [pscustomobject]@{
        ok = $true
        sourceRoot = $sourceRootResolved
        deployed = @($deployment | ForEach-Object {
            [ordered]@{ relative = $_.relative; sha256 = $_.sha256; target = $_.target; changed = $_.changed }
        })
        evidenceDir = $evidenceDirectory
        manifestPath = $manifestPath
        whatIf = [bool] $WhatIfPreference
    } | ConvertTo-Json -Depth 8
}
catch {
    $failureMessage = $_.Exception.Message
    $rollbackErrors = @()
    $rollbackStatus = 'unsafe-partial'
    try {
        $manifest.status = 'rollback-in-progress'
        $manifest.error = $failureMessage
        if (Test-Path -LiteralPath $evidenceDirectory -PathType Container) {
            Write-JsonAtomic -PathValue $manifestPath -Value $manifest
        }
    }
    catch {
        $rollbackErrors += [ordered]@{ reason = 'manifest-pre-rollback-write-failed'; message = $_.Exception.Message }
    }

    if ($InjectConcurrentChangeBeforeRollback -and $replacedFiles.Count -gt 0) {
        $concurrentTarget = [string] $replacedFiles[0].target
        Set-Content -LiteralPath $concurrentTarget -Value 'concurrent change detected during rollback' -Encoding UTF8
    }

    for ($replacedIndex = $replacedFiles.Count - 1; $replacedIndex -ge 0; $replacedIndex--) {
        $replaced = $replacedFiles[$replacedIndex]
        try {
            $target = [string] $replaced.target
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                throw "回滚 CAS 目标不存在：$target"
            }
            $currentReplacementHash = Get-HashUpper -PathValue $target
            if ($currentReplacementHash -ne [string] $replaced.file.sourceSha256) {
                throw "回滚 CAS 冲突：$target 当前指纹不是本次 replacement"
            }
            if ([string]::IsNullOrWhiteSpace([string] $replaced.backup)) {
                Remove-Item -LiteralPath $target -Force
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    throw "无法删除本次创建的 runtime 文件：$target"
                }
            }
            else {
                $targetDirectory = Split-Path -Parent $target
                $restoreTemp = Join-Path $targetDirectory ('.restore-' + [System.IO.Path]::GetFileName($target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    Copy-Item -LiteralPath ([string] $replaced.backup) -Destination $restoreTemp -Force
                    if ((Get-HashUpper -PathValue $restoreTemp) -ne [string] $replaced.originalSha256) {
                        throw "回滚 backup 指纹不匹配：$($replaced.backup)"
                    }
                    Move-Item -LiteralPath $restoreTemp -Destination $target -Force
                    if ((Get-HashUpper -PathValue $target) -ne [string] $replaced.originalSha256) {
                        throw "回滚后 runtime 指纹不匹配：$target"
                    }
                }
                finally {
                    if (Test-Path -LiteralPath $restoreTemp) {
                        Remove-Item -LiteralPath $restoreTemp -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            $replaced.file.status = 'restored'
        }
        catch {
            $rollbackErrors += [ordered]@{
                path = [string] $replaced.target
                reason = 'rollback-failed'
                message = $_.Exception.Message
            }
            $replaced.file.status = 'rollback-failed'
        }
    }

    $rollbackStatus = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'unsafe-partial' }
    try {
        $manifest.status = $rollbackStatus
        $manifest.rollbackCompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        $manifest.rollbackErrors = $rollbackErrors
        if (Test-Path -LiteralPath $evidenceDirectory -PathType Container) {
            Write-JsonAtomic -PathValue $manifestPath -Value $manifest
        }
    }
    catch {
        $rollbackErrors += [ordered]@{ reason = 'manifest-post-rollback-write-failed'; message = $_.Exception.Message }
        $rollbackStatus = 'unsafe-partial'
    }

    [pscustomobject]@{
        ok = $false
        status = $rollbackStatus
        rolledBack = ($rollbackStatus -eq 'rolled-back')
        sourceRoot = $sourceRootResolved
        codexRoot = $codexRootResolved
        evidenceDir = $evidenceDirectory
        manifestPath = $manifestPath
        rollbackErrors = $rollbackErrors
        error = $failureMessage
    } | ConvertTo-Json -Depth 8
    exit 1
}
