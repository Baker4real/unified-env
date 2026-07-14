[CmdletBinding()]
param(
    [string]$ManifestPath,
    [switch]$LegacyFixtureManifest,
    [string]$CodexHome = 'D:\Codex\.codex',
    [string]$OutputDir = 'D:\Codex\projects\统一环境\reports\codex-hook-inventory',
    [switch]$RequireNoRetiredRegistrations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib\ReportArtifactPublisher.ps1')

function Get-CodexHookTrustKeyObservations {
    param([Parameter(Mandatory)][string]$ConfigPath)

    $configObservation = Get-CodexHookSafeFileProbe -Path $ConfigPath -Name 'config.toml' -AllowedExactPaths @($ConfigPath)
    if (-not $configObservation.safeToRead) {
        return @([pscustomobject][ordered]@{
            section = 'hooks.state'
            keyKind = "config-$($configObservation.state)"
            keyNameSha256 = $null
            present = $false
        })
    }

    $section = $null
    $observations = [Collections.Generic.List[object]]::new()
    $configText = Read-CodexHookSafeTextFile -Path $ConfigPath -Name 'config.toml' -AllowedExactPaths @($ConfigPath)
    foreach ($line in @($configText -split '\r?\n')) {
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
            $keyName = $keyMatch.Groups['key'].Value
            $observations.Add([pscustomobject][ordered]@{
                section = 'hooks.state'
                keyKind = if ($keyName -match '(?i)^trusted[_-]?hash') { 'trusted-hash' } else { 'other' }
                keyNameSha256 = Get-CodexHookTextSha256 -Text $keyName
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
    $root = [IO.Path]::GetPathRoot($fullPath)
    $segments = @($fullPath.Substring($root.Length) -split '[\\/]' | Where-Object { $_ -ne '' })
    $currentPath = $root
    $ancestors = [Collections.Generic.List[object]]::new()
    $state = 'complete'
    foreach ($segment in @('__ROOT__') + $segments) {
        if ($segment -cne '__ROOT__') {
            $currentPath = Join-Path $currentPath $segment
        }
        try {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        } catch [System.Management.Automation.ItemNotFoundException] {
            $state = 'missing-tail'
            break
        }
        $isReparsePoint = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $ancestors.Add([pscustomobject][ordered]@{
            path = $item.FullName
            isReparsePoint = $isReparsePoint
        })
        if ($isReparsePoint) {
            $state = 'reparse-blocked'
            break
        }
    }

    return [pscustomobject][ordered]@{
        scope = $Scope
        path = $fullPath
        state = $state
        hasReparsePoint = @($ancestors | Where-Object isReparsePoint).Count -gt 0
        ancestors = [object[]]$ancestors.ToArray()
    }
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = if ($LegacyFixtureManifest) {
        Get-CodexHookLegacyFixtureManifestPath
    } else {
        Get-CodexHookHostPreflightManifestPath
    }
}
$manifest = if ($LegacyFixtureManifest) {
    Read-CodexHookLegacyFixtureManifest -Path $ManifestPath
} else {
    Read-CodexHookHostPreflightManifest -Path $ManifestPath
}
$codexHomePath = Assert-CodexHookDPath -Value $CodexHome -Name 'CodexHome'
$outputPath = Assert-CodexHookDPath -Value $OutputDir -Name 'OutputDir'
if (Test-CodexHookPathWithin -Path $outputPath -ParentPath $codexHomePath) {
    throw "OutputDir 不得位于 CodexHome live 树内：$outputPath"
}

$manifestCodexHome = [IO.Path]::GetFullPath([string]$manifest.codexHome)
if ($codexHomePath -ine $manifestCodexHome) {
    throw "CodexHome 与 manifest.codexHome 不一致：$codexHomePath"
}

$projectReportsRoot = 'D:\Codex\projects\统一环境\reports'
$allowedOutputRoots = @(
    Join-Path $projectReportsRoot 'codex-hook-inventory'
    Join-Path $projectReportsRoot 'codex-hook-inventory-test'
)
if (-not @($allowedOutputRoots | Where-Object { Test-CodexHookPathWithin -Path $outputPath -ParentPath $_ }).Count) {
    throw "OutputDir 必须位于受控 hook inventory 报告根：$outputPath"
}
if ($outputPath.Substring(2).Contains(':')) {
    throw "OutputDir 不得包含 NTFS alternate data stream：$outputPath"
}
$outputReparse = Get-CodexHookReparseAncestorFacts -Path $outputPath -Scope 'outputDir'
if ($outputReparse.hasReparsePoint) {
    throw "OutputDir 祖先包含 reparse point：$outputPath"
}

$managedRoot = [IO.Path]::GetFullPath([string]$manifest.managedRoot)
$liveHooksRoot = Join-Path $codexHomePath 'hooks'
$registryPath = Join-Path $codexHomePath 'hooks.json'
$configPath = Join-Path $codexHomePath 'config.toml'

$registry = Get-CodexHookRegistryFacts -RegistryPath $registryPath -Manifest $manifest
$fileFacts = @(Get-CodexHookFileFacts -Manifest $manifest -ManagedRoot $managedRoot -LiveHooksRoot $liveHooksRoot)
$dependencyFacts = @(Get-CodexHookDependencyFacts -Manifest $manifest)
$trustObservation = @(Get-CodexHookTrustKeyObservations -ConfigPath $configPath)
$document = New-CodexHookInventoryDocument `
    -Manifest $manifest `
    -Registry $registry `
    -FileFacts $fileFacts `
    -DependencyFacts $dependencyFacts `
    -TrustObservation $trustObservation

$runtimeFacts = @(Get-CodexHookRuntimeFacts -Manifest $manifest)

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
            "- 重复规范 identity 数：$($Document.summary.duplicateIdentityCount)"
            "- 缺失 command target：$($Document.summary.missingTargetCount)"
            "- 未探测 unknown target：$($Document.summary.unprobedTargetCount)"
            "- 缺失 managed 文件：$($Document.summary.managedMissingCount)"
            "- 缺失 live 文件：$($Document.summary.liveMissingCount)"
            "- Wrapper/runtime/implementation 缺口：$($Document.summary.dependencyGapCount)"
            "- 已 retirement 但仍注册：$($Document.summary.retiredButRegisteredCount)"
            "- Trust key 观察数：$($Document.summary.trustObservationCount)"
            ''
            '本报告仅采集注册、路径、存在性和 SHA-256 事实；未执行任何 hook。'
        ) -join "`n"
    }

if ($RequireNoRetiredRegistrations -and $document.summary.retiredButRegisteredCount -ne 0) {
    throw "retired hook 仍被注册：count=$($document.summary.retiredButRegisteredCount)；inventory artifacts 已保留。"
}

$published
