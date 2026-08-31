[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Apply')]
    [string]$Mode = 'Audit',
    [string[]]$ConfirmRetiredProject = @(),
    [string]$FixtureRoot,
    [switch]$ColdMaintenance,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false, $true)

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ProductionCodexRoot = 'D:\Codex\.codex'
$script:FixtureMarkerName = '.retired-project-snapshot-sanitizer-fixture'
$script:FixtureMarkerValue = 'retired-project-snapshot-sanitizer-fixture-v1'
$script:ManifestPath = Join-Path $script:ProjectRoot 'managed\codex-hooks\host-preflight-manifest.json'
$script:TomlKeyPattern = '(?:[A-Za-z0-9_-]+|"(?:\\.|[^"\\])*"|''[^'']*'')'

# All live rewrites use the shared handle-bound transaction.  It holds the
# verified directory chain throughout the publish and rejects reparse points,
# hard links, identity drift, and path swaps without creating a payload backup.
. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')

function Get-CanonicalDPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "路径必须是绝对路径：$Path"
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetPathRoot($fullPath) -ine 'D:\') {
        throw "路径必须位于 D:\：$fullPath"
    }

    if ($fullPath.Length -gt 3) {
        $fullPath = $fullPath.TrimEnd('\', '/')
    }
    return $fullPath
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = Get-CanonicalDPath -Path $Path
    $fullRoot = Get-CanonicalDPath -Path $Root
    return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$RequireLeaf
    )

    $fullPath = Get-CanonicalDPath -Path $Path
    $root = [IO.Path]::GetPathRoot($fullPath)
    $current = $root
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }

        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "路径不得穿过 reparse point：$current"
        }
        if (-not $item.PSIsContainer -and $item.LinkType -eq 'HardLink') {
            throw "文件不得是 hard link：$current"
        }
    }

    if ($RequireLeaf -and -not (Test-Path -LiteralPath $fullPath)) {
        throw "路径不存在：$fullPath"
    }
    return $fullPath
}

function Assert-PhysicalFile {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-NoReparsePath -Path $Path -RequireLeaf
    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.PSIsContainer) {
        throw "目标必须是普通文件：$fullPath"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.LinkType -eq 'HardLink') {
        throw "目标不得是链接文件：$fullPath"
    }
    return $fullPath
}

function Assert-PhysicalDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-NoReparsePath -Path $Path -RequireLeaf
    $item = Get-Item -LiteralPath $fullPath -Force
    if (-not $item.PSIsContainer) {
        throw "目标必须是目录：$fullPath"
    }
    return $fullPath
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-StrictUtf8TextFile {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-PhysicalFile -Path $Path
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    $hasUtf8Bom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasUtf8Bom) { 3 } else { 0 }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    try {
        $content = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        throw "文件不是严格 UTF-8：$fullPath"
    }

    [pscustomobject]@{
        path = $fullPath
        content = $content
        hasUtf8Bom = $hasUtf8Bom
        sha256 = Get-BytesSha256 -Bytes $bytes
    }
}

function ConvertTo-Utf8Bytes {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][bool]$HasUtf8Bom
    )

    $payload = [Text.UTF8Encoding]::new($false, $true).GetBytes($Content)
    if (-not $HasUtf8Bom) {
        return $payload
    }

    $result = [byte[]]::new($payload.Length + 3)
    $result[0] = 0xEF
    $result[1] = 0xBB
    $result[2] = 0xBF
    [Array]::Copy($payload, 0, $result, 3, $payload.Length)
    return $result
}

function Get-TextLayout {
    param([Parameter(Mandatory)][string]$Content)

    if ($Content -match "`r(?!`n)") {
        throw '文件包含 bare CR，拒绝进行结构化重写。'
    }

    $hasCrLf = $Content.Contains("`r`n")
    $hasBareLf = [regex]::IsMatch($Content, '(?<!\r)\n')
    if ($hasCrLf -and $hasBareLf) {
        throw '文件混用了 CRLF 和 LF，拒绝进行结构化重写。'
    }

    $newLine = if ($hasCrLf) { "`r`n" } else { "`n" }
    [pscustomobject]@{
        newLine = $newLine
        hasTrailingNewLine = $Content.EndsWith($newLine, [StringComparison]::Ordinal)
    }
}

function Get-TomlLineRecords {
    param([Parameter(Mandatory)][string]$Content)

    if ($Content -match "`r(?!`n)") {
        throw '文件包含 bare CR，拒绝进行结构化重写。'
    }

    # TOML snapshots may contain historical CRLF/LF mixtures. Keep each original
    # line terminator so the untouched portion is reconstructed byte-for-byte.
    $records = [Collections.Generic.List[object]]::new()
    $offset = 0
    foreach ($match in [regex]::Matches($Content, "`r`n|`n")) {
        $records.Add([pscustomobject]@{
            text = $Content.Substring($offset, $match.Index - $offset)
            newLine = $match.Value
        })
        $offset = $match.Index + $match.Length
    }

    if ($offset -lt $Content.Length -or $records.Count -eq 0) {
        $records.Add([pscustomobject]@{
            text = $Content.Substring($offset)
            newLine = ''
        })
    }
    return @($records.ToArray())
}

function ConvertFrom-TomlDottedKeyName {
    param([Parameter(Mandatory)][string]$Name)

    $match = [regex]::Match(
        $Name,
        '^\s*(?<key>' + $script:TomlKeyPattern + ')\s*(?:\.\s*(?<key>' + $script:TomlKeyPattern + ')\s*)*$'
    )
    if (-not $match.Success) {
        throw "无法安全解析 TOML dotted key：$Name"
    }

    $segments = [Collections.Generic.List[string]]::new()
    foreach ($capture in $match.Groups['key'].Captures) {
        $token = $capture.Value
        if ($token.StartsWith('"', [StringComparison]::Ordinal)) {
            try {
                # ConvertFrom-Json otherwise promotes ISO-8601-looking JSON strings
                # to DateTime. TOML quoted keys are always strings, so retain the
                # lexical value while still using JSON only for escape decoding.
                $decoded = ConvertFrom-Json -InputObject $token -NoEnumerate -DateKind String
            } catch {
                throw "无法安全解析 TOML quoted key：$token"
            }
            if ($decoded -isnot [string]) {
                throw "TOML quoted key 必须解析为字符串：$token"
            }
            $segments.Add($decoded)
        } elseif ($token.StartsWith("'", [StringComparison]::Ordinal)) {
            $segments.Add($token.Substring(1, $token.Length - 2))
        } else {
            $segments.Add($token)
        }
    }
    return @($segments.ToArray())
}

function Test-IsRetiredProjectTomlHeader {
    param(
        [Parameter(Mandatory)][psobject]$Header,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    if ($Header.kind -cne 'table' -and $Header.kind -cne 'array') {
        return $false
    }

    $segments = @($Header.segments)
    if ($segments.Count -lt 2 -or -not ([string]$segments[0]).Equals('projects', [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $candidatePath = [string]$segments[1]
    if (-not [IO.Path]::IsPathFullyQualified($candidatePath)) {
        return $false
    }
    return Test-IsExactRetiredProjectPath -Value $candidatePath -RetiredProjectPaths $RetiredProjectPaths
}

function Get-RetiredProjectTrustConfiguration {
    $manifestPath = Assert-PhysicalFile -Path $script:ManifestPath
    try {
        $manifest = (Read-StrictUtf8TextFile -Path $manifestPath).content | ConvertFrom-Json -AsHashtable -NoEnumerate
    } catch {
        throw '无法读取受管 host preflight manifest 中的 retiredProjectTrusts。'
    }

    if ($manifest -isnot [Collections.IDictionary] -or -not $manifest.Contains('retiredProjectTrusts')) {
        throw 'host preflight manifest 缺少 retiredProjectTrusts。'
    }

    $values = @($manifest['retiredProjectTrusts'])
    if ($values.Count -eq 0) {
        throw 'host preflight manifest 的 retiredProjectTrusts 不能为空。'
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $values) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw 'retiredProjectTrusts 只能包含非空字符串。'
        }
        $canonicalPath = Get-CanonicalDPath -Path $value
        if (-not $canonicalPath.StartsWith('D:\Codex\projects\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "retiredProjectTrusts 路径不在 D:\Codex\projects 下：$value"
        }
        if ($canonicalPath.Equals('D:\Codex\projects', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'retiredProjectTrusts 不得使用 projects 集合根。'
        }
        $id = [IO.Path]::GetFileName($canonicalPath)
        if ([string]::IsNullOrWhiteSpace($id) -or $id -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "retiredProjectTrusts 中的项目标识不受支持：$value"
        }
        [void]$ids.Add($id.ToLowerInvariant())
        if (-not $paths.Add($canonicalPath)) {
            throw "retiredProjectTrusts 路径重复：$canonicalPath"
        }
    }
    return [pscustomobject]@{
        ids = @($ids | Sort-Object)
        paths = @($paths | Sort-Object)
    }
}

function Test-IsExactRetiredProjectPath {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    if ($Value -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Value)) {
        return $false
    }
    try {
        $candidatePath = Get-CanonicalDPath -Path $Value
    } catch {
        return $false
    }
    return @($RetiredProjectPaths | Where-Object { $candidatePath.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
}

function Test-ContainsRetiredMarker {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds
    )

    foreach ($id in $RetiredProjectIds) {
        if ($Value.IndexOf($id, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Resolve-Scope {
    param([string]$RequestedFixtureRoot)

    if ([string]::IsNullOrWhiteSpace($RequestedFixtureRoot)) {
        $root = Assert-PhysicalDirectory -Path $script:ProductionCodexRoot
        return [pscustomobject]@{ root = $root; fixture = $false }
    }

    $fixtureRoot = Get-CanonicalDPath -Path $RequestedFixtureRoot
    $productionRoot = Get-CanonicalDPath -Path $script:ProductionCodexRoot
    $agentsRoot = Get-CanonicalDPath -Path 'D:\agents'
    $agentsEvidenceRoot = Get-CanonicalDPath -Path 'D:\agents\run-evidence'
    if ($fixtureRoot.Equals($productionRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'FixtureRoot 不得指向 live D:\Codex\.codex。'
    }
    if ($fixtureRoot.Equals($agentsRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fixtureRoot.Equals($agentsEvidenceRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fixtureRoot.StartsWith("$agentsEvidenceRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'FixtureRoot 不得指向 live D:\agents 或 D:\agents\run-evidence。'
    }

    $reportsRoot = Assert-PhysicalDirectory -Path (Join-Path $script:ProjectRoot 'reports')
    if (-not (Test-PathWithinRoot -Path $fixtureRoot -Root $reportsRoot)) {
        throw 'FixtureRoot 必须位于项目 reports 的受控测试子树。'
    }
    $fixtureRoot = Assert-PhysicalDirectory -Path $fixtureRoot
    $relative = [IO.Path]::GetRelativePath($reportsRoot, $fixtureRoot).Replace('/', '\')
    if ($relative -notmatch '^retired-project-snapshot-sanitizer-tests-[0-9a-f]{32}(?:\\[a-z0-9-]+)?(?:\\\.codex|\\agents)$') {
        throw 'FixtureRoot 不在专用 retired-project-snapshot-sanitizer-tests fixture 根内。'
    }

    $markerPath = Assert-PhysicalFile -Path (Join-Path $fixtureRoot $script:FixtureMarkerName)
    $marker = (Read-StrictUtf8TextFile -Path $markerPath).content.Trim()
    if ($marker -cne $script:FixtureMarkerValue) {
        throw 'FixtureRoot marker 内容不匹配。'
    }
    return [pscustomobject]@{ root = $fixtureRoot; fixture = $true }
}

function Assert-ApplyConfirmation {
    param([Parameter(Mandatory)][string[]]$RetiredProjectIds)

    $confirmed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $ConfirmRetiredProject) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [void]$confirmed.Add($value.Trim())
        }
    }

    $missing = @($RetiredProjectIds | Where-Object { -not $confirmed.Contains($_) })
    if ($missing.Count -gt 0) {
        throw 'Apply 必须为 manifest 中每个 retired project 显式传入 -ConfirmRetiredProject。'
    }
}

function Assert-GlobalCodexColdMaintenance {
    $running = @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath -match '^C:\\Program Files\\WindowsApps\\OpenAI\.Codex_[^\\]+\\'
        }
    )
    if ($running.Count -ne 0) {
        throw '仍有 OpenAI.Codex 官方进程，拒绝热修改 retired project snapshot。'
    }
}

function Add-SnapshotTarget {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Targets,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$Seen,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('toml', 'yaml', 'json')][string]$Kind
    )

    $fullPath = Assert-PhysicalFile -Path $Path
    if ($Seen.Add($fullPath)) {
        $Targets.Add([pscustomobject]@{ path = $fullPath; kind = $Kind })
    }
}

function Add-RecursiveSnapshotTargets {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Targets,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$Seen,
        [Parameter(Mandatory)][string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }
    $rootPath = Assert-PhysicalDirectory -Path $Root
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "受控快照树中存在 reparse point：$($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
                continue
            }
            if ($item.LinkType -eq 'HardLink') {
                throw "受控快照树中存在 hard link：$($item.FullName)"
            }

            $name = $item.Name.ToLowerInvariant()
            $kind = if ($name -match '^config\.toml(?:\.[a-z0-9][a-z0-9._-]*)?$') {
                'toml'
            } else {
                switch ($name) {
                    'serena_config.yml' { 'yaml'; break }
                    '.codex-global-state.json' { 'json'; break }
                    '.codex-global-state.json.bak' { 'json'; break }
                    'global-state.restore-source.json' { 'json'; break }
                    default { $null }
                }
            }
            if ($null -ne $kind) {
                Add-SnapshotTarget -Targets $Targets -Seen $Seen -Path $item.FullName -Kind $kind
            }
        }
    }
}

function Get-SnapshotTargets {
    param([Parameter(Mandatory)][psobject]$Scope)

    $targets = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $root = $Scope.root

    foreach ($item in @(Get-ChildItem -LiteralPath $root -File -Force -ErrorAction Stop)) {
        if ($item.Name -like '.config.toml.replace-backup.*') {
            Add-SnapshotTarget -Targets $targets -Seen $seen -Path $item.FullName -Kind toml
        }
    }

    foreach ($relativeRoot in @(
        'backups_state\provider-sync',
        'backups_state\remote-plugin-debug-20260630',
        'backups_state\serena-dashboard-guard',
        'backups_state\codex-state-policy',
        'run-evidence\host-hook-remediation',
        'run-evidence\codex-project-trust-repair',
        'run-evidence\wss-enable'
    )) {
        Add-RecursiveSnapshotTargets -Targets $targets -Seen $seen -Root (Join-Path $root $relativeRoot)
    }

    $replicatorRoot = Join-Path $root 'run-evidence\replicator'
    if (Test-Path -LiteralPath $replicatorRoot) {
        $replicatorRoot = Assert-PhysicalDirectory -Path $replicatorRoot
        foreach ($item in @(Get-ChildItem -LiteralPath $replicatorRoot -Force -ErrorAction Stop)) {
            if ($item.Name -notlike 'serena-runtime-repair-*' -and $item.Name -notlike 'remote-provider-*') {
                continue
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "受控 replicator 快照根是 reparse point：$($item.FullName)"
            }
            if (-not $item.PSIsContainer) {
                throw "受控 replicator 快照根必须是目录：$($item.FullName)"
            }
            Add-RecursiveSnapshotTargets -Targets $targets -Seen $seen -Root $item.FullName
        }
    }

    $runEvidenceRoot = Join-Path $root 'run-evidence'
    if (Test-Path -LiteralPath $runEvidenceRoot) {
        $runEvidenceRoot = Assert-PhysicalDirectory -Path $runEvidenceRoot
        foreach ($item in @(Get-ChildItem -LiteralPath $runEvidenceRoot -Force -ErrorAction Stop)) {
            if ($item.Name -notlike 'sidebar-recovery-*') {
                continue
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "受控 sidebar recovery 快照根是 reparse point：$($item.FullName)"
            }
            if (-not $item.PSIsContainer) {
                throw "受控 sidebar recovery 快照根必须是目录：$($item.FullName)"
            }
            Add-RecursiveSnapshotTargets -Targets $targets -Seen $seen -Root $item.FullName
        }
    }

    foreach ($runtime in @('login_runtime', 'refresh_runtime')) {
        $statePath = Join-Path $root "account_backup\windows\$runtime\.codex-global-state.json"
        if (Test-Path -LiteralPath $statePath) {
            Add-SnapshotTarget -Targets $targets -Seen $seen -Path $statePath -Kind json
        }
    }

    foreach ($stateFileName in @('.codex-global-state.json', '.codex-global-state.json.bak')) {
        $statePath = Join-Path $root $stateFileName
        if (Test-Path -LiteralPath $statePath) {
            Add-SnapshotTarget -Targets $targets -Seen $seen -Path $statePath -Kind json
        }
    }

    if (-not $Scope.fixture) {
        $secondRoot = Get-CanonicalDPath -Path 'D:\agents'
        foreach ($relativeRoot in @(
            'run-evidence\host-hook-remediation',
            'run-evidence\codex-project-trust-repair',
            'run-evidence\wss-enable'
        )) {
            Add-RecursiveSnapshotTargets -Targets $targets -Seen $seen -Root (Join-Path $secondRoot $relativeRoot)
        }
        $replicatorRoot = Join-Path $secondRoot 'run-evidence\replicator'
        if (Test-Path -LiteralPath $replicatorRoot) {
            $replicatorRoot = Assert-PhysicalDirectory -Path $replicatorRoot
            foreach ($item in @(Get-ChildItem -LiteralPath $replicatorRoot -Force -ErrorAction Stop)) {
                if ($item.Name -notlike 'serena-runtime-repair-*' -and $item.Name -notlike 'remote-provider-*') {
                    continue
                }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "受控 replicator 快照根是 reparse point：$($item.FullName)"
                }
                if (-not $item.PSIsContainer) {
                    throw "受控 replicator 快照根必须是目录：$($item.FullName)"
                }
                Add-RecursiveSnapshotTargets -Targets $targets -Seen $seen -Root $item.FullName
            }
        }
        $runEvidenceRoot = Join-Path $secondRoot 'run-evidence'
        if (Test-Path -LiteralPath $runEvidenceRoot) {
            $runEvidenceRoot = Assert-PhysicalDirectory -Path $runEvidenceRoot
            foreach ($item in @(Get-ChildItem -LiteralPath $runEvidenceRoot -Force -ErrorAction Stop)) {
                if ($item.Name -notlike 'sidebar-recovery-*') {
                    continue
                }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "受控 sidebar recovery 快照根是 reparse point：$($item.FullName)"
                }
                if (-not $item.PSIsContainer) {
                    throw "受控 sidebar recovery 快照根必须是目录：$($item.FullName)"
                }
                Add-RecursiveSnapshotTargets -Targets $targets -Seen $seen -Root $item.FullName
            }
        }
    }

    return @($targets | Sort-Object path)
}

function Get-TomlHeaders {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $headers = [Collections.Generic.List[object]]::new()
    $dottedKeyPattern = $script:TomlKeyPattern + '(?:\s*\.\s*' + $script:TomlKeyPattern + ')*'
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        $arrayMatch = [regex]::Match($line, '^\s*\[\[(?<name>' + $dottedKeyPattern + ')\]\]\s*(?:#.*)?$')
        if ($arrayMatch.Success) {
            $headers.Add([pscustomobject]@{
                index = $index
                kind = 'array'
                segments = @(ConvertFrom-TomlDottedKeyName -Name $arrayMatch.Groups['name'].Value)
            })
            continue
        }

        $tableMatch = [regex]::Match($line, '^\s*\[(?<name>' + $dottedKeyPattern + ')\]\s*(?:#.*)?$')
        if ($tableMatch.Success) {
            $headers.Add([pscustomobject]@{
                index = $index
                kind = 'table'
                segments = @(ConvertFrom-TomlDottedKeyName -Name $tableMatch.Groups['name'].Value)
            })
        } elseif ($line.TrimStart().StartsWith('[', [StringComparison]::Ordinal)) {
            throw "无法安全识别 TOML table header（第 $($index + 1) 行）。"
        }
    }
    return @($headers)
}

function Get-TomlQuotedStringValues {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $values = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Line, '"(?:\\.|[^"\\])*"|''[^'']*''')) {
        $token = $match.Value
        if ($token.StartsWith('"', [StringComparison]::Ordinal)) {
            try {
                # A TOML basic string remains a string even when it looks like an
                # ISO timestamp. Retain it as such so ordinary metadata cannot
                # block the entire snapshot before retired references are checked.
                $decoded = ConvertFrom-Json -InputObject $token -NoEnumerate -DateKind String
            } catch {
                throw "无法安全解析 TOML quoted string：$token"
            }
            if ($decoded -isnot [string]) {
                throw "TOML quoted string 必须解析为字符串：$token"
            }
            $values.Add($decoded)
        } else {
            $values.Add($token.Substring(1, $token.Length - 2))
        }
    }
    return @($values.ToArray())
}

function Test-IsSerenaTomlHeader {
    param([Parameter(Mandatory)][psobject]$Header)

    $segments = @($Header.segments)
    return $Header.kind -ceq 'table' -and
        $segments.Count -eq 2 -and
        ([string]$segments[0]).Equals('mcp_servers', [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$segments[1]).Equals('serena', [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsSupportedTomlRetiredProjectReference {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][psobject]$Header,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    $assignment = [regex]::Match($Line, '^\s*(?<key>[A-Za-z0-9_-]+)\s*=')
    if (-not $assignment.Success) {
        return $false
    }
    $key = $assignment.Groups['key'].Value
    $containsExactPath = @(
        Get-TomlQuotedStringValues -Line $Line | Where-Object {
            Test-IsExactRetiredProjectPath -Value $_ -RetiredProjectPaths $RetiredProjectPaths
        }
    ).Count -gt 0
    if (-not $containsExactPath) {
        return $false
    }
    if ($key -in @('project', 'cwd', 'workspace', 'workspace_root', 'root')) {
        return $true
    }
    return (Test-IsSerenaTomlHeader -Header $Header) -and $key -ceq 'args'
}

function New-SanitizationResult {
    param(
        [Parameter(Mandatory)][psobject]$Source,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Changes
    )

    [pscustomobject]@{
        sourceSha256 = $Source.sha256
        hasUtf8Bom = [bool]$Source.hasUtf8Bom
        kind = $Kind
        content = $Content
        changes = @($Changes)
        changed = $Changes.Count -gt 0
    }
}

function Get-TomlSanitization {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    $source = Read-StrictUtf8TextFile -Path $Path
    if ($source.content.Contains('"""', [StringComparison]::Ordinal) -or $source.content.Contains("'''", [StringComparison]::Ordinal)) {
        # TOML basic multiline strings may encode a retired path with \u escapes.
        # This line-oriented sanitizer cannot prove a safe block boundary there,
        # so block the whole snapshot instead of silently auditing it clean.
        throw '含有 multiline string 的 TOML 快照不支持局部清理，已失败关闭（包括可能由 Unicode 转义隐藏的 retired project 路径）。'
    }

    $lineRecords = @(Get-TomlLineRecords -Content $source.content)
    $lines = @($lineRecords | ForEach-Object { [string]$_.text })
    $headers = Get-TomlHeaders -Lines $lines
    $remove = [bool[]]::new($lineRecords.Count)
    $removedBlocks = [Collections.Generic.HashSet[int]]::new()
    $headersToRemove = [Collections.Generic.HashSet[int]]::new()

    foreach ($header in $headers) {
        if (Test-IsRetiredProjectTomlHeader -Header $header -RetiredProjectPaths $RetiredProjectPaths) {
            [void]$headersToRemove.Add([int]$header.index)
        }
    }

    $currentHeader = $null
    $nextHeaderIndex = 0
    for ($index = 0; $index -lt $lines.Count; $index++) {
        while ($nextHeaderIndex -lt $headers.Count -and [int]$headers[$nextHeaderIndex].index -le $index) {
            $currentHeader = $headers[$nextHeaderIndex]
            $nextHeaderIndex++
        }
        $lineHasRawRetiredMarker = Test-ContainsRetiredMarker -Value $lines[$index] -RetiredProjectIds $RetiredProjectIds
        if ($null -ne $currentHeader -and $headersToRemove.Contains([int]$currentHeader.index)) {
            continue
        }
        if ($null -ne $currentHeader -and (Test-IsSupportedTomlRetiredProjectReference -Line $lines[$index] -Header $currentHeader -RetiredProjectPaths $RetiredProjectPaths)) {
            [void]$headersToRemove.Add([int]$currentHeader.index)
            continue
        }
        if (-not $lineHasRawRetiredMarker) {
            continue
        }
        if ($null -eq $currentHeader) {
            throw "退休 project marker 出现在 TOML 根级内容（第 $($index + 1) 行），拒绝猜测删除范围。"
        }
        throw "退休 project marker 不在受支持的精确 TOML project/Serena 结构中（第 $($index + 1) 行）。"
    }

    if ($headersToRemove.Count -eq 0) {
        return New-SanitizationResult -Source $source -Kind toml -Content $source.content -Changes @()
    }

    for ($headerIndex = 0; $headerIndex -lt $headers.Count; $headerIndex++) {
        $header = $headers[$headerIndex]
        if (-not $headersToRemove.Contains([int]$header.index)) {
            continue
        }
        $end = if ($headerIndex + 1 -lt $headers.Count) { [int]$headers[$headerIndex + 1].index } else { $lines.Count }
        for ($lineIndex = [int]$header.index; $lineIndex -lt $end; $lineIndex++) {
            $remove[$lineIndex] = $true
        }
        [void]$removedBlocks.Add([int]$header.index)
    }

    $builder = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $lineRecords.Count; $index++) {
        if (-not $remove[$index]) {
            [void]$builder.Append([string]$lineRecords[$index].text)
            [void]$builder.Append([string]$lineRecords[$index].newLine)
        }
    }
    $content = $builder.ToString()
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw 'TOML 清理会得到空文件，拒绝应用。'
    }
    if (Test-ContainsRetiredMarker -Value $content -RetiredProjectIds $RetiredProjectIds) {
        throw 'TOML 清理后仍存在退休 project marker，拒绝部分应用。'
    }
    $remainingRecords = @(Get-TomlLineRecords -Content $content)
    $remainingHeaders = Get-TomlHeaders -Lines @($remainingRecords | ForEach-Object { [string]$_.text })
    if (@($remainingHeaders | Where-Object { Test-IsRetiredProjectTomlHeader -Header $_ -RetiredProjectPaths $RetiredProjectPaths }).Count -gt 0) {
        throw 'TOML 清理后仍存在退休 project table，拒绝部分应用。'
    }
    $remainingCurrentHeader = $null
    $remainingHeaderIndex = 0
    for ($index = 0; $index -lt $remainingRecords.Count; $index++) {
        while ($remainingHeaderIndex -lt $remainingHeaders.Count -and [int]$remainingHeaders[$remainingHeaderIndex].index -le $index) {
            $remainingCurrentHeader = $remainingHeaders[$remainingHeaderIndex]
            $remainingHeaderIndex++
        }
        if ($null -ne $remainingCurrentHeader -and
            (Test-IsSupportedTomlRetiredProjectReference -Line ([string]$remainingRecords[$index].text) -Header $remainingCurrentHeader -RetiredProjectPaths $RetiredProjectPaths)) {
            throw 'TOML 清理后仍存在退休 project 结构化引用，拒绝部分应用。'
        }
    }
    return New-SanitizationResult -Source $source -Kind toml -Content $content -Changes @("removed-toml-section-blocks:$($removedBlocks.Count)")
}

function Get-YamlSanitization {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    $source = Read-StrictUtf8TextFile -Path $Path
    $layout = Get-TextLayout -Content $source.content
    $lines = [regex]::Split($source.content, [regex]::Escape($layout.newLine))
    $sections = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [regex]::Match($lines[$index], '^(?<indent>[ \t]*)projects\s*:\s*(?:#.*)?$')
        if ($match.Success) {
            $sections.Add([pscustomobject]@{ index = $index; indent = $match.Groups['indent'].Value; end = $lines.Count })
        }
    }
    for ($sectionIndex = 0; $sectionIndex -lt $sections.Count; $sectionIndex++) {
        $section = $sections[$sectionIndex]
        $indentLength = $section.indent.Length
        for ($index = $section.index + 1; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]
            if ($line -match '^\s*(?:#.*)?$') {
                continue
            }
            $lineIndent = [regex]::Match($line, '^[ \t]*').Value.Length
            $rest = $line.Substring($lineIndent)
            if ($lineIndent -lt $indentLength -or ($lineIndent -eq $indentLength -and -not $rest.StartsWith('-', [StringComparison]::Ordinal))) {
                $section.end = $index
                break
            }
        }
    }

    $remove = [bool[]]::new($lines.Count)
    $removedEntries = 0
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineHasRawRetiredMarker = Test-ContainsRetiredMarker -Value $lines[$index] -RetiredProjectIds $RetiredProjectIds
        $section = @($sections | Where-Object { $_.index -lt $index -and $index -lt $_.end } | Sort-Object index -Descending | Select-Object -First 1)
        if ($section.Count -ne 1) {
            if ($lineHasRawRetiredMarker) {
                throw "退休 project marker 不在受支持的 YAML projects list 中（第 $($index + 1) 行）。"
            }
            continue
        }
        $prefix = [regex]::Escape($section[0].indent)
        $entry = [regex]::Match($lines[$index], "^$prefix-\s*(?<value>[^\r\n]*?)\s*(?:#.*)?$")
        if (-not $entry.Success) {
            if ($lineHasRawRetiredMarker) {
                throw "退休 project marker 不在 projects 的直接 list entry 中（第 $($index + 1) 行）。"
            }
            continue
        }
        $value = $entry.Groups['value'].Value.Trim()
        if ($value.StartsWith('"', [StringComparison]::Ordinal)) {
            try {
                $value = ConvertFrom-Json -InputObject $value -NoEnumerate
            } catch {
                throw "无法安全解析 YAML projects quoted scalar（第 $($index + 1) 行）。"
            }
        } elseif ($value.StartsWith("'", [StringComparison]::Ordinal)) {
            if ($value.Length -lt 2 -or -not $value.EndsWith("'", [StringComparison]::Ordinal)) {
                throw "无法安全解析 YAML projects quoted scalar（第 $($index + 1) 行）。"
            }
            $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
        }
        if (Test-IsExactRetiredProjectPath -Value $value -RetiredProjectPaths $RetiredProjectPaths) {
            $remove[$index] = $true
            $removedEntries++
            continue
        }
        if ($lineHasRawRetiredMarker) {
            throw "退休 project marker 不是 manifest 中的精确 YAML projects 路径（第 $($index + 1) 行）。"
        }
    }
    if ($removedEntries -eq 0) {
        return New-SanitizationResult -Source $source -Kind yaml -Content $source.content -Changes @()
    }

    $kept = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if (-not $remove[$index]) {
            $kept.Add($lines[$index])
        }
    }
    $content = [string]::Join($layout.newLine, $kept)
    if (Test-ContainsRetiredMarker -Value $content -RetiredProjectIds $RetiredProjectIds) {
        throw 'YAML 清理后仍存在退休 project marker，拒绝部分应用。'
    }
    return New-SanitizationResult -Source $source -Kind yaml -Content $content -Changes @("removed-yaml-project-entries:$removedEntries")
}

function Test-JsonArray {
    param([object]$Value)

    return $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [Collections.IDictionary] -and $Value -is [Collections.IEnumerable]
}

function Assert-StringMap {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$FieldName
    )

    if ($Value -isnot [Collections.IDictionary]) {
        throw "$FieldName 必须是 JSON object。"
    }
    foreach ($key in @($Value.Keys)) {
        if ($key -isnot [string] -or $Value[$key] -isnot [string]) {
            throw "$FieldName 必须只包含 string key 和 string value。"
        }
    }
}

function Get-RetiredJsonReferenceCount {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds
    )

    if ($Value -is [Collections.IDictionary]) {
        $count = 0
        foreach ($key in @($Value.Keys)) {
            # Prompt history and thread titles are user-authored conversation
            # text, not a state-recovery surface.  Do not inspect or rewrite it.
            if ($key -in @('prompt-history', 'thread-descriptions-v1')) {
                continue
            }
            if ($key -is [string] -and (Test-ContainsRetiredMarker -Value $key -RetiredProjectIds $RetiredProjectIds)) {
                $count++
            }
            $count += Get-RetiredJsonReferenceCount -Value $Value[$key] -RetiredProjectIds $RetiredProjectIds
        }
        return $count
    }
    if ($Value -is [string]) {
        if (Test-ContainsRetiredMarker -Value $Value -RetiredProjectIds $RetiredProjectIds) {
            return 1
        }
        return 0
    }
    if (Test-JsonArray -Value $Value) {
        $count = 0
        foreach ($item in $Value) {
            $count += Get-RetiredJsonReferenceCount -Value $item -RetiredProjectIds $RetiredProjectIds
        }
        return $count
    }
    return 0
}

function Remove-RetiredJsonArrayEntries {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Container,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    $value = $Container[$Key]
    if (-not (Test-JsonArray -Value $value)) {
        throw "$Key 必须是 JSON array。"
    }

    $kept = [Collections.Generic.List[object]]::new()
    $removed = 0
    foreach ($item in $value) {
        if ($item -isnot [string]) {
            throw "$Key 必须只包含 string。"
        }
        if (Test-IsExactRetiredProjectPath -Value $item -RetiredProjectPaths $RetiredProjectPaths) {
            $removed++
            continue
        }
        $kept.Add($item)
    }
    if ($removed -gt 0) {
        $Container[$Key] = $kept.ToArray()
    }
    return $removed
}

function Invoke-JsonRetiredReferencePass {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$RemovedThreadIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$OutputMaps,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Changes
    )

    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ($key -isnot [string]) {
                throw 'JSON object key 必须是 string。'
            }
            $sidebarPrefix = 'sidebar-project-expanded-v1-codex:'
            if ($key.StartsWith($sidebarPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-IsExactRetiredProjectPath -Value $key.Substring($sidebarPrefix.Length) -RetiredProjectPaths $RetiredProjectPaths)) {
                [void]$Value.Remove($key)
                $Changes.Add('removed-sidebar-project-expanded:1')
            }
        }

        foreach ($key in @($Value.Keys)) {
            $child = $Value[$key]
            if ($key -in @('electron-saved-workspace-roots', 'project-order', 'active-workspace-roots')) {
                $removed = Remove-RetiredJsonArrayEntries -Container $Value -Key $key -RetiredProjectPaths $RetiredProjectPaths
                if ($removed -gt 0) {
                    $Changes.Add("removed-${key}:$removed")
                }
                continue
            }
            if ($key -ceq 'thread-workspace-root-hints') {
                Assert-StringMap -Value $child -FieldName 'thread-workspace-root-hints'
                $removed = 0
                foreach ($threadId in @($child.Keys)) {
                    if (Test-IsExactRetiredProjectPath -Value ([string]$child[$threadId]) -RetiredProjectPaths $RetiredProjectPaths) {
                        [void]$RemovedThreadIds.Add($threadId)
                        [void]$child.Remove($threadId)
                        $removed++
                    }
                }
                if ($removed -gt 0) {
                    $Changes.Add("removed-thread-workspace-root-hints:$removed")
                }
                continue
            }
            if ($key -ceq 'thread-projectless-output-directories') {
                Assert-StringMap -Value $child -FieldName 'thread-projectless-output-directories'
                $OutputMaps.Add($child)
                continue
            }
            if ($key -in @('prompt-history', 'thread-descriptions-v1')) {
                continue
            }
            Invoke-JsonRetiredReferencePass -Value $child -RetiredProjectIds $RetiredProjectIds -RetiredProjectPaths $RetiredProjectPaths -RemovedThreadIds $RemovedThreadIds -OutputMaps $OutputMaps -Changes $Changes
        }
        return
    }

    if (Test-JsonArray -Value $Value) {
        foreach ($item in $Value) {
            Invoke-JsonRetiredReferencePass -Value $item -RetiredProjectIds $RetiredProjectIds -RetiredProjectPaths $RetiredProjectPaths -RemovedThreadIds $RemovedThreadIds -OutputMaps $OutputMaps -Changes $Changes
        }
    }
}

function Remove-AssociatedThreadOutputs {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$OutputMaps,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$RemovedThreadIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Changes
    )

    foreach ($map in $OutputMaps) {
        $removed = 0
        foreach ($threadId in @($map.Keys)) {
            if ($RemovedThreadIds.Contains($threadId)) {
                [void]$map.Remove($threadId)
                $removed++
            }
        }
        if ($removed -gt 0) {
            $Changes.Add("removed-thread-projectless-output-directories:$removed")
        }
    }
}

function Get-JsonSanitization {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    $source = Read-StrictUtf8TextFile -Path $Path
    $layout = Get-TextLayout -Content $source.content
    try {
        $document = $source.content | ConvertFrom-Json -AsHashtable -NoEnumerate
    } catch {
        throw '账户 global-state 不是可安全解析的 JSON。'
    }
    if ($document -isnot [Collections.IDictionary]) {
        throw '账户 global-state 顶层必须是 JSON object。'
    }

    $changes = [Collections.Generic.List[string]]::new()
    $removedThreadIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $outputMaps = [Collections.Generic.List[object]]::new()
    Invoke-JsonRetiredReferencePass -Value $document -RetiredProjectIds $RetiredProjectIds -RetiredProjectPaths $RetiredProjectPaths -RemovedThreadIds $removedThreadIds -OutputMaps $outputMaps -Changes $changes
    Remove-AssociatedThreadOutputs -OutputMaps $outputMaps -RemovedThreadIds $removedThreadIds -Changes $changes

    $remaining = Get-RetiredJsonReferenceCount -Value $document -RetiredProjectIds $RetiredProjectIds
    if ($remaining -gt 0) {
        throw "账户 global-state 仍有 $remaining 个未获允许的退休引用，已失败关闭。"
    }

    $content = $document | ConvertTo-Json -Depth 100
    $content = [regex]::Replace($content, "`r?`n", $layout.newLine)
    if ($layout.hasTrailingNewLine -and -not $content.EndsWith($layout.newLine, [StringComparison]::Ordinal)) {
        $content += $layout.newLine
    }
    return New-SanitizationResult -Source $source -Kind json -Content $content -Changes $changes.ToArray()
}

function Get-Sanitization {
    param(
        [Parameter(Mandatory)][psobject]$Target,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    switch ($Target.kind) {
        'toml' { return Get-TomlSanitization -Path $Target.path -RetiredProjectIds $RetiredProjectIds -RetiredProjectPaths $RetiredProjectPaths }
        'yaml' { return Get-YamlSanitization -Path $Target.path -RetiredProjectIds $RetiredProjectIds -RetiredProjectPaths $RetiredProjectPaths }
        'json' { return Get-JsonSanitization -Path $Target.path -RetiredProjectIds $RetiredProjectIds -RetiredProjectPaths $RetiredProjectPaths }
        default { throw "未知快照类型：$($Target.kind)" }
    }
}

function Assert-ValidToml {
    param([Parameter(Mandatory)][string]$Content)

    $pythonPath = Assert-PhysicalFile -Path 'D:\Codex\tools\python314-official\python.exe'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonPath
    foreach ($argument in @('-B', '-I', '-S', '-X', 'utf8', '-c', 'import sys, tomllib; tomllib.loads(sys.stdin.read())')) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = 'D:\Codex'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'TOML parser 未能启动。'
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Content)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000)) {
            throw 'TOML parser 超时。'
        }
        $stdout.GetAwaiter().GetResult() | Out-Null
        $stderr.GetAwaiter().GetResult() | Out-Null
        if ($process.ExitCode -ne 0) {
            throw 'TOML 快照未通过语法验证。'
        }
    } finally {
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch {}
            $process.WaitForExit(1000) | Out-Null
        }
        $process.Dispose()
    }
}

function Write-SanitizedCandidate {
    param(
        [Parameter(Mandatory)][psobject]$Candidate,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string[]]$AllowedExactPaths,
        [switch]$RequireColdMaintenance
    )

    $path = Assert-PhysicalFile -Path $Candidate.path
    $sanitization = $Candidate.sanitization
    $before = Get-CodexHookCapabilityFileSnapshot `
        -Path $path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name 'retired project snapshot sanitizer prewrite'
    if (-not $before.exists -or $before.state -cne 'regular-file' -or $before.sha256 -cne $sanitization.sourceSha256) {
        throw "目标在 Apply 前已变化，拒绝覆盖：$path"
    }
    if ($sanitization.kind -ceq 'toml') {
        Assert-ValidToml -Content $sanitization.content
    }
    if ($sanitization.kind -ceq 'json') {
        try { $null = $sanitization.content | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { throw '重写后的账户 global-state 未通过 JSON 验证。' }
    }

    $bytes = ConvertTo-Utf8Bytes -Content $sanitization.content -HasUtf8Bom ([bool]$sanitization.hasUtf8Bom)
    $expectedSha256 = Get-BytesSha256 -Bytes $bytes
    $beforeRename = if ($RequireColdMaintenance) {
        {
            param($TemporaryFile)
            Assert-GlobalCodexColdMaintenance
        }
    } else {
        $null
    }
    Set-CodexHookAtomicFileBytesWithCapability `
        -Path $path `
        -Bytes $bytes `
        -ExpectedExists $true `
        -ExpectedSha256 $sanitization.sourceSha256 `
        -ExpectedIdentity @($before.identity) `
        -AfterSha256 $expectedSha256 `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Scope 'retired project snapshot sanitizer' `
        -BeforeRename $beforeRename
}

function Get-Audit {
    param(
        [Parameter(Mandatory)][psobject]$Scope,
        [Parameter(Mandatory)][string[]]$RetiredProjectIds,
        [Parameter(Mandatory)][string[]]$RetiredProjectPaths
    )

    $records = [Collections.Generic.List[object]]::new()
    try {
        $targets = Get-SnapshotTargets -Scope $Scope
    } catch {
        $records.Add([pscustomobject]@{ path = $Scope.root; kind = 'scan'; status = 'blocked'; changes = @(); error = $_.Exception.Message; sanitization = $null })
        return @($records)
    }

    foreach ($target in $targets) {
        try {
            $sanitization = Get-Sanitization -Target $target -RetiredProjectIds $RetiredProjectIds -RetiredProjectPaths $RetiredProjectPaths
            if (-not $sanitization.changed) {
                continue
            }
            $records.Add([pscustomobject]@{
                path = $target.path
                kind = $target.kind
                status = 'ready'
                changes = @($sanitization.changes)
                error = $null
                sanitization = $sanitization
            })
        } catch {
            $records.Add([pscustomobject]@{
                path = $target.path
                kind = $target.kind
                status = 'blocked'
                changes = @()
                error = $_.Exception.Message
                sanitization = $null
            })
        }
    }
    return @($records | Sort-Object path)
}

function ConvertTo-PublicFinding {
    param([Parameter(Mandatory)][psobject]$Record)

    [pscustomobject]@{
        path = $Record.path
        kind = $Record.kind
        status = $Record.status
        changes = @($Record.changes)
        error = $Record.error
    }
}

$exitCode = 0
$result = $null
try {
    $scope = Resolve-Scope -RequestedFixtureRoot $FixtureRoot
    $retiredProjectTrusts = Get-RetiredProjectTrustConfiguration
    $retiredProjectIds = @($retiredProjectTrusts.ids)
    $retiredProjectPaths = @($retiredProjectTrusts.paths)
    $audit = @(Get-Audit -Scope $scope -RetiredProjectIds $retiredProjectIds -RetiredProjectPaths $retiredProjectPaths)
    $blocked = @($audit | Where-Object { $_.status -ceq 'blocked' })
    $ready = @($audit | Where-Object { $_.status -ceq 'ready' })
    $changedPaths = @()

    if ($Mode -ceq 'Apply') {
        Assert-ApplyConfirmation -RetiredProjectIds $retiredProjectIds
        if (-not $ColdMaintenance) {
            throw 'Apply 必须显式传入 -ColdMaintenance。'
        }
        if (-not $scope.fixture) {
            Assert-GlobalCodexColdMaintenance
        }
        if ($blocked.Count -gt 0) {
            throw '存在无法安全结构化清理的快照，拒绝部分 Apply。'
        }
        foreach ($record in $ready) {
            $path = Assert-PhysicalFile -Path $record.path
            if ((Get-FileSha256 -Path $path) -cne $record.sanitization.sourceSha256) {
                throw "目标在 Apply preflight 后发生变化，拒绝开始写入：$path"
            }
        }
        $allowedRewritePaths = @($ready | ForEach-Object { [string]$_.path })
        foreach ($record in $ready) {
            Write-SanitizedCandidate `
                -Candidate $record `
                -CapabilityRoot $scope.root `
                -AllowedExactPaths $allowedRewritePaths `
                -RequireColdMaintenance:(-not $scope.fixture)
            $changedPaths += $record.path
        }
        $postAudit = @(Get-Audit -Scope $scope -RetiredProjectIds $retiredProjectIds -RetiredProjectPaths $retiredProjectPaths)
        if ($postAudit.Count -gt 0) {
            throw 'Apply 后仍存在退休 project 快照引用或阻断项。'
        }
        $result = [pscustomobject]@{
            ok = $true
            mode = $Mode
            fixture = [bool]$scope.fixture
            retiredProjects = @($retiredProjectIds)
            findingCount = 0
            changed = $changedPaths.Count -gt 0
            changedPaths = @($changedPaths)
            findings = @()
        }
    } else {
        $result = [pscustomobject]@{
            ok = $audit.Count -eq 0
            mode = $Mode
            fixture = [bool]$scope.fixture
            retiredProjects = @($retiredProjectIds)
            findingCount = $audit.Count
            changed = $false
            changedPaths = @()
            findings = @($audit | ForEach-Object { ConvertTo-PublicFinding -Record $_ })
        }
        if ($audit.Count -gt 0) {
            $exitCode = 1
        }
    }
} catch {
    $exitCode = 1
    $result = [pscustomobject]@{
        ok = $false
        mode = $Mode
        fixture = -not [string]::IsNullOrWhiteSpace($FixtureRoot)
        retiredProjects = @()
        findingCount = 0
        changed = $false
        changedPaths = @()
        findings = @()
        error = $_.Exception.Message
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 12
} else {
    $result
}
exit $exitCode
