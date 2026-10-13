<#
.SYNOPSIS
Lint the holding directories under the staging and unclassified-evidence roots. Reads only.

.DESCRIPTION
Every child of a holding root must be a real directory with a manifest.json carrying these keys
(D:/Codex/.codex/docs/agent-guidance/storage-and-junctions.md, "Quarantine And Trash Directories"):

  createdBy    { host, session }                     who made it; "unknown" when no record survives
  createdAt    ISO 8601 time
  purpose      why it exists
  sources      [{ path, from }]                      every top-level item and where it came from
  sensitive    { present, items: [{ path, type }] }  names and types only, never contents
  expires      ISO 8601 date or time
  disposition  what happens when it expires

Errors: root-missing, root-reparse-point, loose-file, reparse-point, missing-manifest, invalid-json,
missing-field, invalid-field, unlisted-item. Warning: expired.
Prints one JSON report and writes nothing; exit 0 when no entry has an error, 1 otherwise.

.EXAMPLE
pwsh -NoProfile -File D:/agents/projects/统一环境/scripts/Invoke-StagingManifestLint.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Root = @('D:\agents\staging', 'D:\agents\run-evidence\unclassified-temp-artifacts'),
    [datetime]$AsOf = (Get-Date)
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$reparse = [System.IO.FileAttributes]::ReparsePoint

function New-Issue([string]$Level, [string]$Code, [string]$Detail) {
    [ordered]@{ level = $Level; code = $Code; detail = $Detail }
}

function Test-Text($Value) { $Value -is [string] -and $Value.Trim().Length -gt 0 }

function ConvertTo-Instant($Value) {
    # ConvertFrom-Json turns ISO 8601 strings into DateTime, so accept both shapes.
    if ($Value -is [datetime]) { return [datetimeoffset]$Value }
    if ($Value -is [datetimeoffset]) { return $Value }
    if (-not (Test-Text $Value)) { return $null }
    $parsed = [datetimeoffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    if ([datetimeoffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    $null
}

function Test-Records($Value, [string[]]$Keys, [switch]$AllowEmpty) {
    # A list of objects whose named keys all hold text.
    if ($Value -isnot [System.Collections.IList] -or (-not $AllowEmpty -and $Value.Count -eq 0)) { return $false }
    foreach ($record in $Value) {
        if ($record -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($key in $Keys) { if (-not (Test-Text $record[$key])) { return $false } }
    }
    $true
}

$fieldRules = [ordered]@{
    createdBy   = @{ expect = 'object with host and session text'
                     test = { param($v) $v -is [System.Collections.IDictionary] -and (Test-Text $v['host']) -and (Test-Text $v['session']) } }
    createdAt   = @{ expect = 'ISO 8601 time'; test = { param($v) $null -ne (ConvertTo-Instant $v) } }
    purpose     = @{ expect = 'text'; test = { param($v) Test-Text $v } }
    sources     = @{ expect = 'non-empty list of { path, from } text'; test = { param($v) Test-Records $v @('path', 'from') } }
    sensitive   = @{ expect = '{ present: bool, items: [{ path, type }] }, items non-empty when present'
                     test = { param($v)
                         $v -is [System.Collections.IDictionary] -and $v['present'] -is [bool] -and
                         (Test-Records $v['items'] @('path', 'type') -AllowEmpty) -and
                         (-not $v['present'] -or $v['items'].Count -gt 0) } }
    expires     = @{ expect = 'ISO 8601 date or time'; test = { param($v) $null -ne (ConvertTo-Instant $v) } }
    disposition = @{ expect = 'text'; test = { param($v) Test-Text $v } }
}

function Get-ManifestFinding([System.IO.DirectoryInfo]$Directory) {
    $finding = [ordered]@{ expires = $null; issues = [System.Collections.Generic.List[object]]::new() }
    $manifestPath = Join-Path $Directory.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $finding.issues.Add((New-Issue 'error' 'missing-manifest' 'manifest.json'))
        return $finding
    }
    try {
        $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($manifestPath, $utf8)) -AsHashtable -NoEnumerate
    } catch {
        $finding.issues.Add((New-Issue 'error' 'invalid-json' $_.Exception.Message))
        return $finding
    }
    if ($doc -isnot [System.Collections.IDictionary]) {
        $finding.issues.Add((New-Issue 'error' 'invalid-json' 'top level is not an object'))
        return $finding
    }

    foreach ($field in $fieldRules.Keys) {
        if (-not $doc.Contains($field)) {
            $finding.issues.Add((New-Issue 'error' 'missing-field' $field))
        } elseif (-not (& $fieldRules[$field].test $doc[$field])) {
            $finding.issues.Add((New-Issue 'error' 'invalid-field' ('{0}: expected {1}' -f $field, $fieldRules[$field].expect)))
        }
    }

    if (Test-Records $doc['sources'] @('path', 'from')) {
        $listed = @($doc['sources'] | ForEach-Object { ($_['path'] -split '[\\/]')[0].ToLowerInvariant() })
        foreach ($item in Get-ChildItem -LiteralPath $Directory.FullName -Force) {
            if ($item.Name -ne 'manifest.json' -and $item.Name.ToLowerInvariant() -notin $listed) {
                $finding.issues.Add((New-Issue 'error' 'unlisted-item' $item.Name))
            }
        }
    }

    $expiresAt = ConvertTo-Instant $doc['expires']
    if ($null -ne $expiresAt) {
        $finding.expires = $expiresAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
        if ($expiresAt -lt [datetimeoffset]$AsOf) { $finding.issues.Add((New-Issue 'warning' 'expired' $finding.expires)) }
    }
    $finding
}

$entries = foreach ($rootPath in $Root) {
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction SilentlyContinue
    if (-not $rootItem -or -not $rootItem.PSIsContainer) {
        [ordered]@{ root = $rootPath; name = $null; kind = 'root'; expires = $null; issues = @(New-Issue 'error' 'root-missing' $rootPath) }
        continue
    }
    if ($rootItem.Attributes -band $reparse) {
        [ordered]@{ root = $rootPath; name = $null; kind = 'root'; expires = $null; issues = @(New-Issue 'error' 'root-reparse-point' $rootPath) }
        continue
    }
    foreach ($child in Get-ChildItem -LiteralPath $rootItem.FullName -Force | Sort-Object Name) {
        $entry = [ordered]@{ root = $rootPath; name = $child.Name; kind = 'directory'; expires = $null; issues = @() }
        if ($child.Attributes -band $reparse) {
            $entry.kind = 'reparse-point'
            $entry.issues = @(New-Issue 'error' 'reparse-point' 'holding entries must be real directories')
        } elseif (-not $child.PSIsContainer) {
            $entry.kind = 'file'
            $entry.issues = @(New-Issue 'error' 'loose-file' 'files belong inside a holding directory with a manifest')
        } else {
            $finding = Get-ManifestFinding $child
            $entry.expires = $finding.expires
            $entry.issues = @($finding.issues)
        }
        $entry
    }
}
$entries = @($entries)
$issues = @($entries | ForEach-Object { $_.issues })
$errorCount = @($issues | Where-Object { $_.level -eq 'error' }).Count
$warningCount = @($issues | Where-Object { $_.level -eq 'warning' }).Count

[ordered]@{
    status   = if ($errorCount) { 'error' } elseif ($warningCount) { 'warning' } else { 'ok' }
    asOf     = ([datetimeoffset]$AsOf).ToString('yyyy-MM-ddTHH:mm:sszzz')
    roots    = @($Root)
    entries  = $entries.Count
    errors   = $errorCount
    warnings = $warningCount
    findings = $entries
} | ConvertTo-Json -Depth 6 -Compress
exit $(if ($errorCount) { 1 } else { 0 })
