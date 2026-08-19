#requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')

function Remove-ManagedTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot
    )

    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths @($Path) `
        -Name 'issue32 leftover cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'issue32 leftover cleanup'
}

$legacyFixture = Join-Path $projectRoot 'reports\safe-tree-delete-issue32-20260817\fixtures-7f708262197f4e698d6179aa248d7fae'
$legacyCandidate = Join-Path $legacyFixture 'candidate'
if ([IO.Directory]::Exists($legacyCandidate)) {
    Remove-ManagedTree -Path $legacyCandidate -CapabilityRoot $legacyFixture
}

foreach ($name in @('benchmark-fixtures', 'profile-fixtures', 'profile-stream-fixtures')) {
    $root = Join-Path $PSScriptRoot $name
    if (-not [IO.Directory]::Exists($root)) { continue }
    foreach ($child in @('candidate', 'candidate-1000', 'candidate-reuse', 'candidate-baseline')) {
        $path = Join-Path $root $child
        Remove-ManagedTree -Path $path -CapabilityRoot $root
    }
}

Write-Output 'CLEANUP_DONE'
