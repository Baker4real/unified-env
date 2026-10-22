#Requires -Version 7.5
<#
.SYNOPSIS
Check or deploy the explicitly managed host diagnostic scripts.
.DESCRIPTION
Check is read-only and returns exit 1 on drift. Apply saves backups and hashes
under EvidenceRoot, replaces only the allowlist, then independently reads it back.
SourceRoot and TargetRoot may be supplied for isolated deployment fixtures.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','Apply')][string]$Mode = 'Check',
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'managed/host-diagnostics'),
    [string]$TargetRoot = 'D:/Codex/.codex/scripts',
    [string]$EvidenceRoot = 'D:/agents/run-evidence/host-diagnostics-deployment'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$allowlist = @(
    'Read-BoundedProjection.ps1','Test-BoundedProjection.ps1',
    'Invoke-CheckedPowerShell.ps1','Test-CheckedPowerShell.ps1',
    'BrowserPrivacyProbe.py','Test-BrowserPrivacyProbe.py',
    'Get-NvidiaDownloadStatus.ps1','Test-NvidiaDownloadStatus.ps1',
    'Get-TaskbarSnapshot.ps1','Restart-ExplorerShell.ps1',
    'lib/ExplorerShellRecovery.ps1','Test-ExplorerShellRecovery.ps1',
    'Invoke-ManagedRecycle.ps1','Test-ManagedRecycle.ps1',
    'Get-ConsoleLaunchAudit.ps1','Test-ConsoleLaunchAudit.ps1','Watch-ConsoleWindows.ps1',
    'Test-HostDiagnostics.ps1'
)

# Keep Check independent of host native-loader/cache initialization.
function Resolve-DiagnosticPath([string]$Path, [string]$Name) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Name must be an absolute D drive path." }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith('D:\',[StringComparison]::OrdinalIgnoreCase) -or $full.Length -le 3 -or $full.Substring(2).Contains(':')) {
        throw "$Name must resolve to an ordinary D drive path."
    }
    $full.TrimEnd('\')
}

function Assert-NoReparseAncestor([string]$Path) {
    $current = $Path
    while (-not [string]::IsNullOrEmpty($current)) {
        $item = $null
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw } }
        if ($null -ne $item) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not an allowed deployment path: $current"
            }
            if ($current -ne $Path -and -not $item.PSIsContainer) { throw "A deployment ancestor is not a directory: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Test-PathOverlap([string]$First, [string]$Second) {
    $First.Equals($Second,[StringComparison]::OrdinalIgnoreCase) -or
        $First.StartsWith($Second + '\',[StringComparison]::OrdinalIgnoreCase) -or
        $Second.StartsWith($First + '\',[StringComparison]::OrdinalIgnoreCase)
}

function Get-DiagnosticHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-TargetUnchanged([object]$Record, [string]$Target) {
    Assert-NoReparseAncestor $Target
    $exists = Test-Path -LiteralPath $Target -PathType Leaf
    if ((Test-Path -LiteralPath $Target -PathType Container) -or $exists -ne $Record.beforeExists -or
        ($exists -and (Get-DiagnosticHash $Target) -ne $Record.beforeSha256)) {
        throw "Target changed before replacement: $($Record.relative)"
    }
}

function Save-DeploymentManifest {
    $manifest = Join-Path $report.evidenceDirectory 'manifest.json'
    Assert-NoReparseAncestor $manifest
    [IO.File]::WriteAllText($manifest,($report | ConvertTo-Json -Depth 7),$utf8)
}

$report = [ordered]@{
    schemaVersion = 1
    mode = $Mode
    status = 'failed'
    sourceRoot = $null
    targetRoot = $null
    changedFiles = 0
    writtenFiles = 0
    files = @()
    evidenceDirectory = $null
}
try {
    $sourceFull = Resolve-DiagnosticPath $SourceRoot 'SourceRoot'
    $targetFull = Resolve-DiagnosticPath $TargetRoot 'TargetRoot'
    if (Test-PathOverlap $sourceFull $targetFull) { throw 'SourceRoot and TargetRoot must not be the same path or overlap.' }
    foreach ($root in @($sourceFull,$targetFull)) {
        Assert-NoReparseAncestor $root
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Deployment directory does not exist: $root" }
    }
    $report.sourceRoot = $sourceFull
    $report.targetRoot = $targetFull
    $report.files = @(foreach ($relative in $allowlist) {
        $source = Join-Path $sourceFull $relative
        $target = Join-Path $targetFull $relative
        Assert-NoReparseAncestor $source
        Assert-NoReparseAncestor $target
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing allowlisted source: $relative" }
        if (Test-Path -LiteralPath $target -PathType Container) { throw "An allowlisted target is a directory: $relative" }
        $sourceHash = Get-DiagnosticHash $source
        $targetExists = Test-Path -LiteralPath $target -PathType Leaf
        $targetHash = if ($targetExists) { Get-DiagnosticHash $target } else { $null }
        [pscustomobject]@{
            relative = $relative
            sourceSha256 = $sourceHash
            beforeExists = $targetExists
            beforeSha256 = $targetHash
            afterSha256 = $targetHash
            status = if ($sourceHash -eq $targetHash) { 'matched' } elseif ($targetExists) { 'different' } else { 'missing' }
            backupPath = $null
            written = $false
        }
    })
    $report.changedFiles = @($report.files | Where-Object status -NE 'matched').Count
    if ($Mode -eq 'Check') {
        $report.status = if ($report.changedFiles) { 'drift' } else { 'in-sync' }
    }
    else {
        $evidenceFull = Resolve-DiagnosticPath $EvidenceRoot 'EvidenceRoot'
        if ((Test-PathOverlap $evidenceFull $sourceFull) -or (Test-PathOverlap $evidenceFull $targetFull)) {
            throw 'EvidenceRoot must not overlap SourceRoot or TargetRoot.'
        }
        Assert-NoReparseAncestor $evidenceFull
        $runRoot = Join-Path $evidenceFull ('deploy-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($runRoot)
        Assert-NoReparseAncestor $runRoot
        $report.evidenceDirectory = $runRoot
        $report.status = 'preparing'
        Save-DeploymentManifest
        $changed = @($report.files | Where-Object status -NE 'matched')
        # Complete every original backup and staged source before replacing any target.
        foreach ($record in $changed) {
            $source = Join-Path $sourceFull $record.relative
            $target = Join-Path $targetFull $record.relative
            $staged = Join-Path (Join-Path $runRoot 'staged') $record.relative
            Assert-NoReparseAncestor $source
            Assert-TargetUnchanged $record $target
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $staged))
            Assert-NoReparseAncestor $staged
            [IO.File]::Copy($source,$staged,$false)
            if ((Get-DiagnosticHash $staged) -ne $record.sourceSha256 -or (Get-DiagnosticHash $source) -ne $record.sourceSha256) {
                throw "Source changed while staging: $($record.relative)"
            }
            if ($record.beforeExists) {
                $backup = Join-Path (Join-Path $runRoot 'backup') $record.relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup))
                Assert-NoReparseAncestor $backup
                [IO.File]::Copy($target,$backup,$false)
                if ((Get-DiagnosticHash $backup) -ne $record.beforeSha256) { throw "Backup hash mismatch: $($record.relative)" }
                $record.backupPath = $backup
            }
        }
        $report.status = 'prepared'
        Save-DeploymentManifest
        foreach ($record in $report.files) {
            Assert-NoReparseAncestor (Join-Path $sourceFull $record.relative)
            if ((Get-DiagnosticHash (Join-Path $sourceFull $record.relative)) -ne $record.sourceSha256) {
                throw "Source changed before deployment: $($record.relative)"
            }
            Assert-TargetUnchanged $record (Join-Path $targetFull $record.relative)
        }
        foreach ($record in $changed) {
            $target = Join-Path $targetFull $record.relative
            $staged = Join-Path (Join-Path $runRoot 'staged') $record.relative
            Assert-TargetUnchanged $record $target
            Assert-NoReparseAncestor $staged
            if ((Get-DiagnosticHash $staged) -ne $record.sourceSha256) { throw "Staged hash mismatch: $($record.relative)" }
            $parent = Split-Path -Parent $target
            Assert-NoReparseAncestor $parent
            [void][IO.Directory]::CreateDirectory($parent)
            Assert-NoReparseAncestor $target
            # Replacement does not write through hard links. Original bytes remain in backup.
            if ($record.beforeExists) { [IO.File]::Replace($staged,$target,[NullString]::Value) }
            else { [IO.File]::Move($staged,$target,$false) }
            $record.written = $true
            $report.writtenFiles++
            $record.afterSha256 = Get-DiagnosticHash $target
            $record.status = if ($record.afterSha256 -eq $record.sourceSha256) { 'matched' } else { 'readback-mismatch' }
            Save-DeploymentManifest
            if ($record.status -ne 'matched') { throw "Deployed hash mismatch: $($record.relative)" }
        }
        # Include unchanged files in the final independent readback.
        foreach ($record in $report.files) {
            $source = Join-Path $sourceFull $record.relative
            $target = Join-Path $targetFull $record.relative
            Assert-NoReparseAncestor $source
            Assert-NoReparseAncestor $target
            $record.afterSha256 = Get-DiagnosticHash $target
            if ($record.afterSha256 -ne $record.sourceSha256 -or (Get-DiagnosticHash $source) -ne $record.sourceSha256) {
                throw "Final source/target hash mismatch: $($record.relative)"
            }
        }
        $report.status = 'deployed'
        Save-DeploymentManifest
    }
}
catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    if ($report.evidenceDirectory) {
        try { Save-DeploymentManifest }
        catch { $report.evidenceWriteFailed = $true }
    }
}

$report | ConvertTo-Json -Depth 7 -Compress
if ($report.status -notin @('in-sync','deployed')) { exit 1 }
