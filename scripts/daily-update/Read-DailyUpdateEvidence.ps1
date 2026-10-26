[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [string]$PreviousRunDirectory,
    [ValidateRange(512, 6000)][int]$MaxTotalBytes = 6000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$allowedRoot = [IO.Path]::GetFullPath('D:/agents/run-evidence').TrimEnd('\') + '\'
$knownStatuses = @('complete','completed','processed','updated','updated-verified','pass','passed','ok',
    'blocked','deferred','failed','pending','skipped','unchanged','latest','in_progress','running','manual-review')

function ConvertTo-SortedValue($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $sorted = [ordered]@{}
        [string[]]$keys = @($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $sorted[$key] = ConvertTo-SortedValue $Value[$key] }
        return ,$sorted
    }
    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-SortedValue $_ })
        return ,$items
    }
    return ,$Value
}

function Get-CanonicalHash($Value) {
    # Recorded Python contract: ensure_ascii=False, sort_keys=True, separators=(',', ':').
    # Keep ISO timestamps as strings when parsing; preserve array ordering.
    $canonical = ConvertTo-Json -InputObject (ConvertTo-SortedValue $Value) -Depth 100 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($canonical))).ToLowerInvariant()
}

function Assert-EvidencePath([string]$Path, [bool]$Directory = $false) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Outside evidence root.' }
    $item = Get-Item -LiteralPath $full -Force
    if ($Directory -ne [bool]$item.PSIsContainer) { throw 'Unexpected evidence kind.' }
    $cursor = $item
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse evidence.' }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    return $full
}

function Read-Receipt([string]$Directory) {
    $root = Assert-EvidencePath $Directory $true
    $checkpointFile = Assert-EvidencePath (Join-Path $root 'scope-checkpoint.json')
    $checkpointHash = (Get-FileHash -LiteralPath $checkpointFile -Algorithm SHA256).Hash
    $checkpoint = Get-Content -LiteralPath $checkpointFile -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    if ($checkpoint -isnot [Collections.IDictionary]) { throw 'Invalid checkpoint.' }
    $manifestPath = Join-Path $root 'scope-manifest.json'
    $legacy = -not (Test-Path -LiteralPath $manifestPath)
    if ($legacy) { $manifestPath = Join-Path $root 'scope.json' }
    $manifestFile = Assert-EvidencePath $manifestPath
    $manifestHash = (Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    if ($manifest -isnot [Collections.IDictionary]) { throw 'Invalid manifest.' }
    $contract = 'raw'
    if ($legacy) {
        # 2026-10-21 scope-checkpoint.py binds exactly these three scope.json fields.
        if ($manifest['required'] -isnot [array] -or $manifest['owners'] -isnot [Collections.IDictionary] -or
            $checkpoint['contracts'] -isnot [array] -or $checkpoint['scope_id'] -ne $manifest['scope_id']) { throw 'Unsupported legacy receipt.' }
        $binding = @{ scope_id=$manifest['scope_id']; required=$manifest['required']; owners=$manifest['owners'] }
        if ($checkpoint['scope_manifest_sha256'] -ne (Get-CanonicalHash $binding)) { throw 'Legacy receipt hash mismatch.' }
        $inputUnits = $checkpoint['contracts']
        $contract = 'legacy-canonical-subset'
    } else {
        $reference = $checkpoint['scope_manifest']
        if ($reference -isnot [string]) { throw 'Missing manifest reference.' }
        $boundPath = if ([IO.Path]::IsPathRooted($reference)) { [IO.Path]::GetFullPath($reference) } else { [IO.Path]::GetFullPath((Join-Path $root $reference)) }
        if (-not $boundPath.Equals($manifestFile, [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest reference mismatch.' }
        if ($checkpoint.Contains('scope_manifest_sha256')) {
            if ($checkpoint['scope_manifest_sha256'] -ne $manifestHash) { throw 'Receipt hash mismatch.' }
        } elseif (-not $checkpoint.Contains('scope_manifest_canonical_sha256')) { throw 'Missing receipt hash.' }
        if ($checkpoint.Contains('scope_manifest_canonical_sha256')) {
            if ($checkpoint['scope_manifest_canonical_sha256'] -ne (Get-CanonicalHash $manifest)) { throw 'Canonical receipt hash mismatch.' }
            $contract = 'canonical'
        }
        $inputUnits = $manifest['units']
    }
    if ($inputUnits -isnot [array]) { throw 'Missing receipt units.' }
    $units = [ordered]@{}
    $evidenceHashes = @{}
    foreach ($unit in $inputUnits) {
        if ($unit -isnot [Collections.IDictionary]) { throw 'Invalid unit.' }
        $id = $unit['id']
        if ($id -isnot [string] -or $id.Length -gt 100 -or $id -notmatch '^[\p{L}\p{N} ._/-]+$' -or $units.Contains($id)) { throw 'Invalid or duplicate unit.' }
        $status = $unit['status']
        if ($status -notin $knownStatuses) { throw 'Unknown status.' }
        $refs = @()
        $unitHashes = [ordered]@{}
        foreach ($reference in @($unit['evidence'])) {
            if ($null -eq $reference) { continue }
            if ($reference -isnot [string] -or $reference.Length -gt 240 -or
                [IO.Path]::IsPathRooted($reference) -or $reference -match '(^|[/\\])\.\.([/\\]|$)|[\x00-\x1f:@?]') { throw 'Invalid evidence reference.' }
            $evidencePath = Assert-EvidencePath (Join-Path $root $reference)
            if (-not $evidencePath.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence outside run.' }
            if (-not $evidenceHashes.ContainsKey($evidencePath)) {
                $evidenceHashes[$evidencePath] = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            $unitHashes[$reference] = $evidenceHashes[$evidencePath]
            $refs += $reference
        }
        # Ignore only observation clocks; content/versions/findings remain in the
        # fingerprint so an unchanged status cannot hide a changed finding.
        $comparison = [ordered]@{}
        foreach ($key in @($unit.Keys | Sort-Object)) {
            if ($key -notin @('last_observed_at','observed_at','updated_at','checked_at')) { $comparison[$key] = $unit[$key] }
        }
        $fingerprint = Get-CanonicalHash @{ unit=$comparison; evidence_sha256=$unitHashes }
        $units[$id] = [ordered]@{ id=$id; status=$status; evidence=$refs; fingerprint=$fingerprint }
    }
    $requiredIds = if ($legacy) { $manifest['required'] } else { $manifest['required_units'] }
    if ($null -ne $requiredIds) {
        $expectedIds = @($requiredIds) + @($manifest['optional_units'] | Where-Object { $null -ne $_ })
        if ($expectedIds.Count -ne $units.Count -or @($expectedIds | Select-Object -Unique).Count -ne $units.Count -or
            @($expectedIds | Where-Object { -not $units.Contains($_) }).Count -gt 0) { throw 'Scope unit mismatch.' }
    }
    foreach ($path in $evidenceHashes.Keys) {
        [void](Assert-EvidencePath $path)
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $evidenceHashes[$path]) { throw 'Evidence changed during read.' }
    }
    if ((Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifestHash) { throw 'Receipt changed during read.' }
    if ((Get-FileHash -LiteralPath $checkpointFile -Algorithm SHA256).Hash -ne $checkpointHash) { throw 'Checkpoint changed during read.' }
    return @{ root=$root; manifest_hash=$manifestHash; units=$units; contract=$contract }
}

function Read-DecisionSection([string]$Root) {
    $resultFile = Join-Path $Root 'RESULT.md'
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) { return $null }
    $resultFile = Assert-EvidencePath $resultFile
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $reader = Join-Path $projectRoot 'managed/host-diagnostics/Read-BoundedProjection.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Join-Path $PSHOME 'pwsh.exe')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    foreach ($arg in @('-NoProfile','-NonInteractive','-File',$reader,'-LiteralPath',$resultFile,
        '-MarkdownSection','需要用户裁决','-MaxRows','6','-MaxValueChars','350','-MaxTotalBytes','2500')) {
        [void]$start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Projection did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Projection timeout.' }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Decision section projection failed.' }
        return ($stdout | ConvertFrom-Json -AsHashtable)
    } finally { $process.Dispose() }
}

try {
    $current = Read-Receipt $RunDirectory
    $previous = if ($PreviousRunDirectory) { Read-Receipt $PreviousRunDirectory } else { $null }
    $allChanges = [Collections.Generic.List[object]]::new()
    $unchanged = 0
    $counts = [ordered]@{}
    foreach ($unit in $current.units.Values) {
        if (-not $counts.Contains($unit.status)) { $counts[$unit.status] = 0 }
        $counts[$unit.status]++
        $old = if ($null -ne $previous -and $previous.units.Contains($unit.id)) { $previous.units[$unit.id] } else { $null }
        if ($null -ne $old -and $old.fingerprint -eq $unit.fingerprint) { $unchanged++; continue }
        $allChanges.Add([ordered]@{ id=$unit.id; status=$unit.status; evidence=$unit.evidence })
    }
    $removed = if ($null -ne $previous) { @($previous.units.Keys | Where-Object { -not $current.units.Contains($_) }).Count } else { 0 }
    $result = [ordered]@{
        schema_version=1; ok=$true; read_only=$true; run_directory=$current.root; receipt_contract=$current.contract
        manifest_sha256=$current.manifest_hash; unit_count=$current.units.Count
        counts=$counts; unchanged_count=$unchanged; removed_count=$removed
        changed_count=$allChanges.Count; emitted_count=0; omitted_count=$allChanges.Count
        changes=[Collections.Generic.List[object]]::new(); decisions=$null
        decisions_status='absent'; decisions_omitted_rows=0
        next_action='Inspect changed unit evidence; this projection does not grant mutation or prove live state.'
    }
    $decisions = Read-DecisionSection $current.root
    if ($null -ne $decisions) {
        $result.decisions_status = 'omitted-budget'
        $result.decisions_omitted_rows = [int]$decisions.sources[0].matchedRows
        $result.next_action = 'Read RESULT.md decision section and omitted unit evidence; receipt projection does not prove live state.'
    }
    $json = ConvertTo-Json -InputObject $result -Depth 30 -Compress
    if ($utf8.GetByteCount($json) + 2 -gt $MaxTotalBytes) { throw 'Budget below metadata size.' }
    # Admit user decisions before changed-unit rows, and retain an explicit omission state.
    if ($null -ne $decisions) {
        $result.decisions = $decisions
        $result.decisions_omitted_rows = [int]$decisions.sources[0].omittedRows
        $clipped = @($decisions.sources[0].rows | Where-Object { $_.text -like '*[[]value clipped[]]*' }).Count -gt 0
        $result.decisions_status = if ($result.decisions_omitted_rows -gt 0 -or $clipped) { 'truncated' } else { 'included' }
        $candidate = ConvertTo-Json -InputObject $result -Depth 30 -Compress
        if ($utf8.GetByteCount($candidate) + 2 -le $MaxTotalBytes) { $json = $candidate }
        else {
            $result.decisions = $null; $result.decisions_status = 'omitted-budget'
            $result.decisions_omitted_rows = [int]$decisions.sources[0].matchedRows
        }
    }
    foreach ($change in $allChanges) {
        $result.changes.Add($change); $result.emitted_count++; $result.omitted_count--
        $candidate = ConvertTo-Json -InputObject $result -Depth 30 -Compress
        if ($utf8.GetByteCount($candidate) + 2 -le $MaxTotalBytes) { $json = $candidate }
        else { $result.changes.RemoveAt($result.changes.Count-1); $result.emitted_count--; $result.omitted_count++ }
    }
    Write-Output $json
} catch {
    [ordered]@{schema_version=1;ok=$false;status='invalid-receipt-or-budget';
        error_type=$_.Exception.GetType().Name;line=$_.InvocationInfo.ScriptLineNumber;
        next_action='Verify receipt files, scope hash, input path and budget.'} | ConvertTo-Json -Compress
    exit 2
}
