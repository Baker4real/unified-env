[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $CodexRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $EvidenceRoot
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
$evidenceRootResolved = Resolve-DPath -PathValue $EvidenceRoot
$sourceFiles = @(
    'Apply-GitHubDefaultBranchSkillOverlay.cjs',
    'github-default-branch-skill-overlay-catalog.json'
)
$runtimeDirectory = Join-Path $codexRootResolved 'scripts'
$deployment = @()
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
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $backup = Join-Path $evidenceDirectory ('before-' + [System.IO.Path]::GetFileName($target))
                Copy-Item -LiteralPath $target -Destination $backup -Force
                $file.backup = $backup
            }
            $temp = Join-Path $targetDirectory ('.' + [System.IO.Path]::GetFileName($target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Copy-Item -LiteralPath $source -Destination $temp -Force
                if ((Get-HashUpper -PathValue $temp) -ne [string] $file.sourceSha256) {
                    throw "临时部署文件指纹不匹配：$temp"
                }
                Move-Item -LiteralPath $temp -Destination $target -Force
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
    [pscustomobject]@{
        ok = $false
        sourceRoot = $sourceRootResolved
        codexRoot = $codexRootResolved
        evidenceDir = $evidenceDirectory
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 8
    exit 1
}
