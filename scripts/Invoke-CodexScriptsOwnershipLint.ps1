<#
.SYNOPSIS
Lint D:/Codex/.codex/scripts against its ownership registry. Reads only.

.DESCRIPTION
Every file under the scripts root must be covered by an entry in managed/codex-scripts/ownership.json: a file
entry covers that file, a directory entry (path ending in "/") covers everything below it. Each entry names its
owner: the deploy script in this repository that installs it, or the document or skill responsible for it.
Entries deployed from this repository also name their repository-relative source.

Errors: root-missing, reparse-point, unowned, source-missing, owner-mismatch (a scripts/Deploy-*.ps1 owner that
is absent or never names the entry's file). Warnings: missing (registered but absent on this host), source-drift
(deployed bytes differ from the source). An invalid registry is a terminating error.
Prints one JSON report and writes nothing; exit 0 when no finding is an error, 1 otherwise.

.EXAMPLE
pwsh -NoProfile -File D:/agents/projects/统一环境/scripts/Invoke-CodexScriptsOwnershipLint.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\Codex\.codex\scripts',
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$RegistryPath = (Join-Path $ProjectRoot 'managed\codex-scripts\ownership.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$reparse = [System.IO.FileAttributes]::ReparsePoint

function New-Finding([string]$Level, [string]$Code, [string]$Path, [string]$Detail) {
    [ordered]@{ level = $Level; code = $Code; path = $Path; detail = $Detail }
}

function Test-Text($Value) { $Value -is [string] -and $Value.Trim().Length -gt 0 }

function Test-RelativePath([string]$Value) {
    # Forward slashes only, no drive, no rooted path and no "." or ".." segment.
    if ($Value.Contains('\') -or $Value.Contains(':') -or $Value.StartsWith('/')) { return $false }
    foreach ($segment in $Value.TrimEnd('/').Split('/')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { return $false }
    }
    $true
}

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function Read-Registry([string]$Path) {
    $registry = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable
    if ($registry -isnot [System.Collections.IDictionary] -or
        $registry['artifactType'] -cne 'env-governance.codex-scripts-ownership' -or $registry['schemaVersion'] -ne 1) {
        throw "Registry is not an env-governance.codex-scripts-ownership schema 1 document: $Path"
    }
    $entries = $registry['entries']
    if ($entries -isnot [System.Collections.IList] -or $entries.Count -eq 0) { throw 'Registry entries must be a non-empty list.' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if ($entry -isnot [System.Collections.IDictionary] -or -not (Test-Text $entry['path']) -or -not (Test-Text $entry['owner'])) {
            throw 'Every registry entry needs a path and an owner.'
        }
        $path = [string]$entry['path']
        if (-not (Test-RelativePath $path)) { throw "Registry path must be relative with forward slashes: $path" }
        if (-not $seen.Add($path)) { throw "Registry path is listed twice: $path" }
        if ($entry.Contains('source')) {
            if ($path.EndsWith('/')) { throw "A directory entry cannot name a source: $path" }
            if (-not (Test-Text $entry['source']) -or -not (Test-RelativePath ([string]$entry['source']))) {
                throw "Registry source must be a repository-relative path: $path"
            }
        }
    }
    foreach ($directory in @($entries | Where-Object { ([string]$_['path']).EndsWith('/') })) {
        foreach ($entry in $entries) {
            $path = [string]$entry['path']
            if ($path -ne $directory['path'] -and $path.StartsWith([string]$directory['path'], [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Registry entry $path is already covered by $($directory['path'])"
            }
        }
    }
    @($entries)
}

$entries = Read-Registry $RegistryPath
$findings = [System.Collections.Generic.List[object]]::new()
$fileCount = 0
$rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
if (-not $rootItem -or -not $rootItem.PSIsContainer) {
    $findings.Add((New-Finding 'error' 'root-missing' '.' $Root))
} elseif ($rootItem.Attributes -band $reparse) {
    $findings.Add((New-Finding 'error' 'reparse-point' '.' 'the scripts root must be a real directory'))
} else {
    $rootFull = $rootItem.FullName.TrimEnd('\')
    $directories = @($entries | Where-Object { ([string]$_['path']).EndsWith('/') } | ForEach-Object { [string]$_['path'] })
    $files = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) { if (-not ([string]$entry['path']).EndsWith('/')) { [void]$files.Add([string]$entry['path']) } }

    # Get-ChildItem -Recurse does not descend into junctions or symbolic links; they are reported, never followed.
    foreach ($item in Get-ChildItem -LiteralPath $rootFull -Recurse -Force | Sort-Object FullName) {
        $relative = $item.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
        if ($item.Attributes -band $reparse) {
            $findings.Add((New-Finding 'error' 'reparse-point' $relative 'entries under the scripts root must not be reparse points'))
            continue
        }
        if ($item.PSIsContainer) { continue }
        $fileCount++
        $covered = $files.Contains($relative) -or @($directories | Where-Object {
                $relative.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $covered) {
            $findings.Add((New-Finding 'error' 'unowned' $relative 'no registry entry covers this file'))
        }
    }

    foreach ($entry in $entries) {
        $path = [string]$entry['path']
        $target = Join-Path $rootFull $path.TrimEnd('/').Replace('/', '\')
        $isDirectory = $path.EndsWith('/')
        $present = if ($isDirectory) { Test-Path -LiteralPath $target -PathType Container } else { Test-Path -LiteralPath $target -PathType Leaf }
        if (-not $present) { $findings.Add((New-Finding 'warning' 'missing' $path 'registered but absent on this host')) }

        $owner = [string]$entry['owner']
        if ($owner -cmatch '^scripts/Deploy-[^/]+\.ps1$') {
            $ownerPath = Join-Path $ProjectRoot $owner.Replace('/', '\')
            $leaf = $path.TrimEnd('/').Split('/')[-1]
            if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf) -or
                -not (Get-Content -Raw -LiteralPath $ownerPath).Contains($leaf)) {
                $findings.Add((New-Finding 'error' 'owner-mismatch' $path "$owner does not deploy $leaf"))
            }
        }

        if (-not $entry.Contains('source')) { continue }
        $source = Join-Path $ProjectRoot ([string]$entry['source']).Replace('/', '\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $findings.Add((New-Finding 'error' 'source-missing' $path "$($entry['source']) is not in the repository"))
        } elseif ($present -and (Get-Sha256 $source) -ne (Get-Sha256 $target)) {
            $findings.Add((New-Finding 'warning' 'source-drift' $path "differs from $($entry['source'])"))
        }
    }
}

$sorted = @($findings | Sort-Object { $_.path }, { $_.code })
$errorCount = @($sorted | Where-Object { $_.level -eq 'error' }).Count
$warningCount = @($sorted | Where-Object { $_.level -eq 'warning' }).Count
[ordered]@{
    status   = if ($errorCount) { 'error' } elseif ($warningCount) { 'warning' } else { 'ok' }
    root     = $Root
    registry = $RegistryPath
    files    = $fileCount
    entries  = $entries.Count
    errors   = $errorCount
    warnings = $warningCount
    findings = $sorted
} | ConvertTo-Json -Depth 5 -Compress
exit $(if ($errorCount) { 1 } else { 0 })
