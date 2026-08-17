# Snapshot-only source identity. Not an authorization.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$paths = @(
    'scripts\lib\CodexSafeTreeDelete.ps1'
    'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
    'scripts\lib\CodexSafeTreeDeleteHashCache.cs'
    'scripts\Invoke-CodexSafeTreeDelete.ps1'
    'scripts\invoke-codex-safe-tree-delete-host.ps1'
    'scripts\invoke-codex-safe-tree-delete.cmd'
    'managed\safe-tree-delete\policy.json'
    'tests\Test-CodexSafeTreeDeleteProductionSmoke.ps1'
    'tests\Test-CodexSafeTreeDeleteStatus.ps1'
    'tests\Test-CodexSafeTreeDeleteLeafStreamSet.ps1'
    'tests\Test-CodexSafeTreeDeleteCrashSafety.ps1'
    'tests\Test-CodexSafeTreeDeleteFileSystem.ps1'
    'tests\Test-CodexSafeTreeDeleteHashSafely.ps1'
    'tests\Test-CodexHookInventory.ps1'
    'tests\Test-CodexSerenaBehaviorHooks.ps1'
    'managed\codex-hooks\hooks\serena-behavior-guard.ps1'
    'docs\specs\2026-07-24-safe-tree-delete-capability.md'
)

$hostPaths = @(
    'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
    'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
)

function Get-PathIdentity {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) {
        return [ordered]@{
            path = $Path
            exists = $false
        }
    }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $Path
        exists = $true
        length = [long]$item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

$repoFiles = foreach ($relative in $paths) {
    Get-PathIdentity -Path (Join-Path $projectRoot $relative)
}
$hostFiles = foreach ($absolute in $hostPaths) {
    Get-PathIdentity -Path $absolute
}

$repoMiddle = $repoFiles | Where-Object { [string]$_.path -like '*invoke-codex-safe-tree-delete-host.ps1' }
$hostMiddle = $hostFiles | Where-Object { [string]$_.path -like '*invoke-safe-tree-delete.ps1' }
$repoCmd = $repoFiles | Where-Object { [string]$_.path -like '*invoke-codex-safe-tree-delete.cmd' }
$hostCmd = $hostFiles | Where-Object { [string]$_.path -like '*invoke-safe-tree-delete.cmd' }

$document = [ordered]@{
    artifactType = 'unified-environment.safe-tree-delete.closeout-20260816.source-identity'
    schemaVersion = 1
    generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    note = '当前工作树文件 SHA-256/mtime，不是 git commit，也不是执行授权。'
    runtime = [ordered]@{
        psEdition = [string]$PSVersionTable.PSEdition
        psVersion = [string]$PSVersionTable.PSVersion
        processPath = [string](Get-Process -Id $PID).Path
    }
    wrappers = [ordered]@{
        repoMiddleSha256 = [string]$repoMiddle.sha256
        hostMiddleSha256 = [string]$hostMiddle.sha256
        middleEqual = [string]$repoMiddle.sha256 -ceq [string]$hostMiddle.sha256
        repoCmdSha256 = [string]$repoCmd.sha256
        hostCmdSha256 = [string]$hostCmd.sha256
        cmdEqual = [string]$repoCmd.sha256 -ceq [string]$hostCmd.sha256
    }
    repoFiles = @($repoFiles)
    hostFiles = @($hostFiles)
}

[void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
[IO.File]::WriteAllText(
    $OutputPath,
    ($document | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
$document
