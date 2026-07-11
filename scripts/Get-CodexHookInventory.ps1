[CmdletBinding()]
param(
    [string]$ManifestPath = 'D:\Codex\projects\统一环境\managed\codex-hooks\manifest.json',
    [string]$CodexHome = 'D:\Codex\.codex',
    [string]$OutputDir = 'D:\Codex\projects\统一环境\reports\codex-hook-inventory'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib\ReportArtifactPublisher.ps1')

function Get-CodexHookTrustKeyObservations {
    param([Parameter(Mandatory)][string]$ConfigPath)

    if (-not [IO.File]::Exists($ConfigPath)) {
        return @()
    }

    $section = $null
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        $sectionMatch = [regex]::Match($line, '^\s*\[(?<section>[^\]]+)\]\s*(?:#.*)?$')
        if ($sectionMatch.Success) {
            $section = $sectionMatch.Groups['section'].Value.Trim()
            continue
        }

        if ($section -cne 'hooks.state') {
            continue
        }

        $keyMatch = [regex]::Match($line, '^\s*(?<key>[A-Za-z0-9_.-]+)\s*=')
        if ($keyMatch.Success) {
            $observations.Add([pscustomobject][ordered]@{
                section = 'hooks.state'
                keyName = $keyMatch.Groups['key'].Value
                present = $true
            })
        }
    }

    return [object[]]$observations.ToArray()
}

function Get-CodexHookReparseAncestorFacts {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Scope
    )

    $fullPath = Assert-CodexHookDPath -Value $Path -Name $Scope
    $currentPath = $fullPath
    while (-not (Test-Path -LiteralPath $currentPath -ErrorAction Stop)) {
        $parent = [IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent) {
            break
        }
        $currentPath = $parent.FullName
    }

    $ancestors = [Collections.Generic.List[object]]::new()
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        $isReparsePoint = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $ancestors.Add([pscustomobject][ordered]@{
            path = $item.FullName
            isReparsePoint = $isReparsePoint
        })

        $parent = [IO.Directory]::GetParent($item.FullName)
        if ($null -eq $parent) {
            break
        }
        $currentPath = $parent.FullName
    }

    return [pscustomobject][ordered]@{
        scope = $Scope
        path = $fullPath
        hasReparsePoint = @($ancestors | Where-Object isReparsePoint).Count -gt 0
        ancestors = [object[]]$ancestors.ToArray()
    }
}

function Test-CodexHookPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ParentPath
    )

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parent = [IO.Path]::GetFullPath($ParentPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return (
        $candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    )
}

$manifest = Read-CodexHookManifest -Path $ManifestPath
$codexHomePath = Assert-CodexHookDPath -Value $CodexHome -Name 'CodexHome'
$outputPath = Assert-CodexHookDPath -Value $OutputDir -Name 'OutputDir'
if (Test-CodexHookPathWithin -Path $outputPath -ParentPath $codexHomePath) {
    throw "OutputDir 不得位于 CodexHome live 树内：$outputPath"
}

$manifestCodexHome = [IO.Path]::GetFullPath([string]$manifest.codexHome)
if ($codexHomePath -ine $manifestCodexHome) {
    throw "CodexHome 与 manifest.codexHome 不一致：$codexHomePath"
}

$managedRoot = [IO.Path]::GetFullPath([string]$manifest.managedRoot)
$liveHooksRoot = Join-Path $codexHomePath 'hooks'
$registryPath = Join-Path $codexHomePath 'hooks.json'
$configPath = Join-Path $codexHomePath 'config.toml'

$registry = Get-CodexHookRegistryFacts -RegistryPath $registryPath
$fileFacts = @(Get-CodexHookFileFacts -Manifest $manifest -ManagedRoot $managedRoot -LiveHooksRoot $liveHooksRoot)
$trustObservation = @(Get-CodexHookTrustKeyObservations -ConfigPath $configPath)
$document = New-CodexHookInventoryDocument `
    -Manifest $manifest `
    -Registry $registry `
    -FileFacts $fileFacts `
    -TrustObservation $trustObservation

$runtimeFacts = @(
    foreach ($property in $manifest.runtimes.PSObject.Properties) {
        $runtimePath = [IO.Path]::GetFullPath([string]$property.Value)
        [pscustomobject][ordered]@{
            name = $property.Name
            path = $runtimePath
            exists = [IO.File]::Exists($runtimePath)
        }
    }
)

$serenaHomeTarget = 'D:\Codex\.serena'
$serenaHomeObservation = @(
    foreach ($scope in @('User', 'Process')) {
        $value = [Environment]::GetEnvironmentVariable('SERENA_HOME', $scope)
        [pscustomobject][ordered]@{
            scope = $scope
            present = -not [string]::IsNullOrWhiteSpace($value)
            matchesTarget = [string]::Equals($value, $serenaHomeTarget, [StringComparison]::OrdinalIgnoreCase)
        }
    }
)

$reparseAncestors = @(
    Get-CodexHookReparseAncestorFacts -Path $codexHomePath -Scope 'codexHome'
    Get-CodexHookReparseAncestorFacts -Path $managedRoot -Scope 'managedRoot'
    Get-CodexHookReparseAncestorFacts -Path $liveHooksRoot -Scope 'liveHooksRoot'
)

$document | Add-Member -NotePropertyName runtimeFacts -NotePropertyValue ([object[]]$runtimeFacts) -ErrorAction Stop
$document | Add-Member -NotePropertyName serenaHomeObservation -NotePropertyValue ([object[]]$serenaHomeObservation) -ErrorAction Stop
$document | Add-Member -NotePropertyName reparseAncestors -NotePropertyValue ([object[]]$reparseAncestors) -ErrorAction Stop

$published = Publish-JsonMarkdownArtifactPair `
    -Document $document `
    -OutputDir $outputPath `
    -JsonFileName 'inventory.json' `
    -MarkdownFileName 'REPORT.md' `
    -RenderMarkdown {
        param($Document, $JsonSha256)

        @(
            '# Codex Hook 只读盘点'
            ''
            "- 生成时间（UTC）：$($Document.generatedAtUtc)"
            "- 只读：$($Document.readOnly)"
            "- 允许执行：$($Document.executionAllowed)"
            "- Registry 事件数：$($Document.summary.eventCount)"
            "- Registry 条目数：$($Document.summary.registryEntryCount)"
            "- 缺失 command target：$($Document.summary.missingTargetCount)"
            "- 缺失 managed 文件：$($Document.summary.managedMissingCount)"
            "- 缺失 live 文件：$($Document.summary.liveMissingCount)"
            "- Trust key 观察数：$($Document.summary.trustObservationCount)"
            ''
            '本报告仅采集注册、路径、存在性和 SHA-256 事实；未执行任何 hook。'
        ) -join "`n"
    }

$published
