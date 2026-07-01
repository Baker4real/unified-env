param(
    [Parameter(Mandatory = $true)]
    [string]$DryRunJson,
    [string]$OutputDir = "",
    [switch]$UseAllDryRunCandidates,
    [string[]]$AllowPath = @(),
    [int]$MaxDryRunAgeHours = 24
)

$ErrorActionPreference = "Stop"

function Test-IsSubPath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullBasePath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd("\", "/")
    return $fullPath.Equals($fullBasePath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$fullBasePath\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-DDrivePath {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$ParameterName 不能为空。"
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($root -ine "D:\") {
        throw "$ParameterName 必须位于 D:\ 下，当前值：$Path"
    }

    $current = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$ParameterName 不能穿过 junction、symlink 或 reparse point：$current"
            }
        }

        if ($current.TrimEnd("\", "/") -ieq $root.TrimEnd("\", "/")) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($current.TrimEnd("\", "/"))
        if ($null -eq $parent) {
            break
        }

        $current = $parent.FullName
    }
}

function Assert-AllowedEvidencePath {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    $allowedRoots = @(
        "D:\Codex\projects\统一环境\reports",
        "D:\Codex\.codex\run-evidence\env-governance"
    )

    foreach ($allowedRoot in $allowedRoots) {
        if (Test-IsSubPath -Path $Path -BasePath $allowedRoot) {
            return
        }
    }

    throw "$ParameterName 必须位于允许的证据目录：D:\Codex\projects\统一环境\reports 或 D:\Codex\.codex\run-evidence\env-governance。当前值：$Path"
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function ConvertTo-Mb {
    param([int64]$Bytes)

    return [math]::Round(($Bytes / 1MB), 2)
}

function Get-ReparseInfo {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $current = $fullPath
    $leafIsReparsePoint = $false
    $firstReparsePoint = $null
    $target = $null

    if (-not (Test-Path -LiteralPath $current)) {
        $parent = [System.IO.Directory]::GetParent($current.TrimEnd("\", "/"))
        if ($null -ne $parent) {
            $current = $parent.FullName
        }
    }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isReparsePoint) {
                if ($fullPath.TrimEnd("\", "/").Equals($item.FullName.TrimEnd("\", "/"), [System.StringComparison]::OrdinalIgnoreCase)) {
                    $leafIsReparsePoint = $true
                }

                $firstReparsePoint = $item.FullName
                if ($item.PSObject.Properties.Name -contains "Target") {
                    $target = $item.Target
                }
                break
            }
        }

        if ($current.TrimEnd("\", "/") -ieq $root.TrimEnd("\", "/")) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($current.TrimEnd("\", "/"))
        if ($null -eq $parent) {
            break
        }

        $current = $parent.FullName
    }

    [pscustomobject]@{
        isReparsePoint = $leafIsReparsePoint
        hasReparsePoint = $null -ne $firstReparsePoint
        firstReparsePoint = $firstReparsePoint
        target = $target
    }
}

function Get-SafePathStats {
    param([string]$Path)

    $result = [ordered]@{
        exists = Test-Path -LiteralPath $Path
        bytes = [int64]0
        mb = 0.0
        files = 0
        dirs = 0
        skillMd = 0
        newestUtc = $null
        oldestUtc = $null
        reparsePointsSkipped = 0
        inaccessibleItems = 0
    }

    if (-not $result.exists) {
        return [pscustomobject]$result
    }

    $stack = New-Object System.Collections.Generic.Stack[string]
    $rootItem = Get-Item -LiteralPath $Path -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $result.reparsePointsSkipped++
        return [pscustomobject]$result
    }

    if ($rootItem.PSIsContainer) {
        $stack.Push($rootItem.FullName)
    } else {
        $result.files++
        $result.bytes += [int64]$rootItem.Length
        if ($rootItem.Name -ieq "SKILL.md") {
            $result.skillMd++
        }
        $result.newestUtc = $rootItem.LastWriteTimeUtc.ToString("o")
        $result.oldestUtc = $rootItem.LastWriteTimeUtc.ToString("o")
        $result.mb = ConvertTo-Mb -Bytes $result.bytes
        return [pscustomobject]$result
    }

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            $children = Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop
        } catch {
            $result.inaccessibleItems++
            continue
        }

        foreach ($child in $children) {
            try {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $result.reparsePointsSkipped++
                    continue
                }

                $lastWriteUtc = $child.LastWriteTimeUtc
                if ($null -eq $result.newestUtc -or $lastWriteUtc -gt ([datetime]$result.newestUtc)) {
                    $result.newestUtc = $lastWriteUtc.ToString("o")
                }
                if ($null -eq $result.oldestUtc -or $lastWriteUtc -lt ([datetime]$result.oldestUtc)) {
                    $result.oldestUtc = $lastWriteUtc.ToString("o")
                }

                if ($child.PSIsContainer) {
                    $result.dirs++
                    $stack.Push($child.FullName)
                    continue
                }

                $result.files++
                $result.bytes += [int64]$child.Length
                if ($child.Name -ieq "SKILL.md") {
                    $result.skillMd++
                }
            } catch {
                $result.inaccessibleItems++
            }
        }
    }

    $result.mb = ConvertTo-Mb -Bytes $result.bytes
    [pscustomobject]$result
}

function Get-StringSha256 {
    param([string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes) -replace "-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-ComparableText {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("o")
    }

    return "$Value"
}

function Get-RawJsonStringProperty {
    param(
        [string]$JsonText,
        [string]$Name
    )

    $match = [regex]::Match($JsonText, '"' + [regex]::Escape($Name) + '"\s*:\s*"(?<value>(?:\\.|[^"\\])*)"')
    if (-not $match.Success) {
        return $null
    }

    return [System.Text.RegularExpressions.Regex]::Unescape($match.Groups["value"].Value)
}

function Test-StatsMatch {
    param(
        [object]$Expected,
        [object]$Actual,
        [System.Collections.Generic.List[string]]$Blockers
    )

    foreach ($field in @("bytes", "files", "dirs", "skillMd", "newestUtc", "oldestUtc")) {
        $expectedValue = ConvertTo-ComparableText -Value $Expected.$field
        $actualValue = ConvertTo-ComparableText -Value $Actual.$field
        if ($expectedValue -ne $actualValue) {
            $Blockers.Add("当前 $field 与 dry-run 快照不一致：dry-run=$expectedValue，current=$actualValue")
        }
    }
}

function New-ManifestItem {
    param(
        [object]$Candidate,
        [object[]]$ProtectedItems,
        [object[]]$ManualReviewItems,
        [int]$RetainCount
    )

    $fullPath = [System.IO.Path]::GetFullPath($Candidate.path)
    $blockers = New-Object System.Collections.Generic.List[string]
    Assert-DDrivePath -Path $fullPath -ParameterName "Candidate.path"

    $reparse = Get-ReparseInfo -Path $fullPath
    $currentStats = Get-SafePathStats -Path $fullPath

    if (-not [bool]$currentStats.exists) {
        $blockers.Add("候选路径当前不存在。")
    }

    if ($reparse.hasReparsePoint) {
        $blockers.Add("候选路径或父级命中 reparse point：$($reparse.firstReparsePoint)")
    }

    if ([int]$currentStats.reparsePointsSkipped -gt 0) {
        $blockers.Add("候选目录内部包含 reparse point，不能自动删除。")
    }

    if ([int]$currentStats.inaccessibleItems -gt 0) {
        $blockers.Add("候选目录内部存在不可访问项，不能自动删除。")
    }

    foreach ($protected in @($ProtectedItems)) {
        if (Test-IsSubPath -Path $fullPath -BasePath $protected.path) {
            $blockers.Add("候选路径落在保护路径内：$($protected.path)")
        }
        if (Test-IsSubPath -Path $protected.path -BasePath $fullPath) {
            $blockers.Add("候选路径是保护路径的祖先：$($protected.path)")
        }
    }

    foreach ($manual in @($ManualReviewItems)) {
        if (Test-IsSubPath -Path $fullPath -BasePath $manual.path) {
            $blockers.Add("候选路径落在人工审查路径内：$($manual.path)")
        }
        if (Test-IsSubPath -Path $manual.path -BasePath $fullPath) {
            $blockers.Add("候选路径是人工审查路径的祖先：$($manual.path)")
        }
    }

    if (-not [bool]$Candidate.selectedByRetention) {
        $blockers.Add("候选项不是保留规则选出的路径。")
    }

    if ([int]$Candidate.retainRank -le $RetainCount) {
        $blockers.Add("候选排名仍在保留最近 $RetainCount 个范围内。")
    }

    if ([string]::IsNullOrWhiteSpace($Candidate.timestampUtc) -or [string]::IsNullOrWhiteSpace($Candidate.timestampSource)) {
        $blockers.Add("候选项缺少严格目录名时间戳。")
    }

    Test-StatsMatch -Expected $Candidate.stats -Actual $currentStats -Blockers $blockers

    $candidateHashInput = @(
        $Candidate.groupKey,
        $fullPath,
        (ConvertTo-ComparableText -Value $Candidate.timestampUtc),
        $Candidate.timestampSource,
        $Candidate.stats.bytes,
        $Candidate.stats.files,
        $Candidate.stats.dirs,
        (ConvertTo-ComparableText -Value $Candidate.stats.newestUtc),
        (ConvertTo-ComparableText -Value $Candidate.stats.oldestUtc)
    ) -join "`n"
    $candidateId = (Get-StringSha256 -Value $candidateHashInput).Substring(0, 16)
    $validationStatus = if ($blockers.Count -eq 0) { "ready-for-final-authorization" } else { "blocked-current-state-mismatch" }

    [pscustomobject]@{
        candidateId = $candidateId
        selected = $true
        validationStatus = $validationStatus
        blockers = @($blockers.ToArray())
        bucket = $Candidate.bucket
        groupKey = $Candidate.groupKey
        projectRoot = $Candidate.projectRoot
        backupType = $Candidate.backupType
        path = $fullPath
        risk = $Candidate.risk
        reason = $Candidate.reason
        retainRank = [int]$Candidate.retainRank
        timestampUtc = $Candidate.timestampUtc
        timestampSource = $Candidate.timestampSource
        plannedOperation = "recursive-delete-directory-after-final-confirmation"
        originalStats = $Candidate.stats
        currentStats = $currentStats
        reparse = $reparse
    }
}

Assert-DDrivePath -Path $DryRunJson -ParameterName "DryRunJson"
Assert-AllowedEvidencePath -Path $DryRunJson -ParameterName "DryRunJson"
if (-not (Test-Path -LiteralPath $DryRunJson -PathType Leaf)) {
    throw "DryRunJson 不存在：$DryRunJson"
}

if (-not $UseAllDryRunCandidates -and @($AllowPath).Count -eq 0) {
    throw "必须指定 -UseAllDryRunCandidates 或至少一个 -AllowPath。生成 manifest 不等于删除授权。"
}

if ($UseAllDryRunCandidates -and @($AllowPath).Count -gt 0) {
    throw "-UseAllDryRunCandidates 和 -AllowPath 不能同时使用。"
}

if ($MaxDryRunAgeHours -lt 1) {
    throw "MaxDryRunAgeHours 必须大于等于 1。"
}
if ($MaxDryRunAgeHours -gt 24) {
    throw "MaxDryRunAgeHours 不能超过 24。真实删除前必须重新生成 dry-run。"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = "D:\Codex\projects\统一环境\reports\backup-retention-apply-manifest-$stamp"
}

Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"
Assert-AllowedEvidencePath -Path $OutputDir -ParameterName "OutputDir"

$dryRunJsonText = Get-Content -LiteralPath $DryRunJson -Raw
$dryRun = $dryRunJsonText | ConvertFrom-Json
foreach ($property in @("schemaVersion", "generatedAtUtc", "dryRun", "readOnly", "deleteAllowed", "retainCount", "policy", "protected", "manualReview", "candidates", "summary")) {
    if ($dryRun.PSObject.Properties.Name -notcontains $property) {
        throw "DryRunJson 缺少字段：$property"
    }
}

if (-not [bool]$dryRun.dryRun -or -not [bool]$dryRun.readOnly -or [bool]$dryRun.deleteAllowed) {
    throw "DryRunJson 不是只读 dry-run，拒绝生成 apply manifest。"
}

if (-not [bool]$dryRun.policy.applyMustUseAllowlist -or -not [bool]$dryRun.policy.applyMustCheckReparsePoints) {
    throw "DryRunJson 缺少 apply allowlist/reparse 安全策略，拒绝生成 manifest。"
}

$rawGeneratedAtUtc = Get-RawJsonStringProperty -JsonText $dryRunJsonText -Name "generatedAtUtc"
if ([string]::IsNullOrWhiteSpace($rawGeneratedAtUtc)) {
    throw "DryRunJson generatedAtUtc 必须是 ISO 字符串。"
}
$generatedAtUtc = [datetimeoffset]::Parse(
    $rawGeneratedAtUtc,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal
).UtcDateTime
$dryRunAgeHours = [math]::Round(((Get-Date).ToUniversalTime() - $generatedAtUtc).TotalHours, 2)
if ($dryRunAgeHours -lt -0.05) {
    throw "DryRunJson 生成时间来自未来，拒绝生成 apply manifest：$rawGeneratedAtUtc"
}
if ($dryRunAgeHours -gt $MaxDryRunAgeHours) {
    throw "DryRunJson 已超过 $MaxDryRunAgeHours 小时，必须重新生成最新 dry-run。当前年龄：$dryRunAgeHours 小时。"
}

$candidateByPath = @{}
foreach ($candidate in @($dryRun.candidates)) {
    $path = [System.IO.Path]::GetFullPath($candidate.path)
    $candidateByPath[$path.ToLowerInvariant()] = $candidate
}

$selectedCandidates = @()
if ($UseAllDryRunCandidates) {
    $selectedCandidates = @($dryRun.candidates)
} else {
    $seenAllowPath = @{}
    foreach ($path in @($AllowPath)) {
        Assert-DDrivePath -Path $path -ParameterName "AllowPath"
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $key = $fullPath.ToLowerInvariant()
        if ($seenAllowPath.ContainsKey($key)) {
            throw "AllowPath 重复，不能生成含重复删除目标的 manifest：$fullPath"
        }
        $seenAllowPath[$key] = $true

        if (-not $candidateByPath.ContainsKey($key)) {
            throw "AllowPath 不在 dry-run candidates 中，不能生成 apply manifest：$fullPath"
        }
        $selectedCandidates += $candidateByPath[$key]
    }
}

$manifestItems = @($selectedCandidates | ForEach-Object {
    New-ManifestItem -Candidate $_ -ProtectedItems @($dryRun.protected) -ManualReviewItems @($dryRun.manualReview) -RetainCount ([int]$dryRun.retainCount)
})

$readyItems = @($manifestItems | Where-Object { $_.validationStatus -eq "ready-for-final-authorization" })
$blockedItems = @($manifestItems | Where-Object { $_.validationStatus -ne "ready-for-final-authorization" })
$selectedBytes = [int64](($manifestItems | ForEach-Object { [int64]$_.currentStats.bytes } | Measure-Object -Sum).Sum)
$readyBytes = [int64](($readyItems | ForEach-Object { [int64]$_.currentStats.bytes } | Measure-Object -Sum).Sum)
$manifestHashInput = @(
    $DryRunJson,
    $dryRun.generatedAtUtc,
    (@($manifestItems | Sort-Object path | ForEach-Object { "$($_.candidateId)|$($_.path)|$($_.currentStats.bytes)|$($_.currentStats.files)|$($_.currentStats.dirs)|$(ConvertTo-ComparableText -Value $_.currentStats.newestUtc)|$(ConvertTo-ComparableText -Value $_.currentStats.oldestUtc)" }) -join "`n")
) -join "`n"
$manifestId = "backup-retention-apply-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + (Get-StringSha256 -Value $manifestHashInput).Substring(0, 8)

$policy = [pscustomobject]@{
    summary = "apply manifest 只做删除前二次校验和显式 allowlist 固化；本脚本不删除任何文件。"
    deleteAllowed = $false
    executionReady = $false
    requiresFinalUserAuthorization = $true
    finalAuthorizationMustNameManifestId = $true
    finalAuthorizationMustConfirmPathCount = $true
    finalAuthorizationMustConfirmEstimatedMb = $true
    manualReviewExcluded = $true
    protectedPathsExcluded = $true
    dryRunMustBeFresh = $true
    dryRunMaxAgeHours = $MaxDryRunAgeHours
    reparsePointCheckRequired = $true
    stateFingerprintRequired = $true
    futureApplyConfirmationPhrase = "我确认删除 manifest $manifestId 中的 $($readyItems.Count) 个已验证路径，预计释放 $([math]::Round(($readyBytes / 1MB), 2)) MB"
}

$summary = [pscustomobject]@{
    sourceCandidateCount = @($dryRun.candidates).Count
    selectedCount = @($manifestItems).Count
    readyForFinalAuthorizationCount = @($readyItems).Count
    blockedCount = @($blockedItems).Count
    selectedBytes = $selectedBytes
    selectedMb = ConvertTo-Mb -Bytes $selectedBytes
    readyBytes = $readyBytes
    readyMb = ConvertTo-Mb -Bytes $readyBytes
    lowRiskCount = @($manifestItems | Where-Object { $_.risk -eq "低" }).Count
    mediumRiskCount = @($manifestItems | Where-Object { $_.risk -eq "中" }).Count
    highRiskCount = @($manifestItems | Where-Object { $_.risk -eq "高" }).Count
    dryRunAgeHours = $dryRunAgeHours
}

$manifest = [pscustomobject]@{
    schemaVersion = 1
    manifestId = $manifestId
    generatedAtLocal = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    applyManifestOnly = $true
    readOnly = $true
    deleteAllowed = $false
    executionReady = $false
    selectionMode = if ($UseAllDryRunCandidates) { "all-dry-run-candidates" } else { "explicit-allow-paths" }
    sourceDryRun = [pscustomobject]@{
        jsonPath = [System.IO.Path]::GetFullPath($DryRunJson)
        generatedAtUtc = $dryRun.generatedAtUtc
        generatedAtLocal = $dryRun.generatedAtLocal
        retainCount = [int]$dryRun.retainCount
        candidateCount = @($dryRun.candidates).Count
        manualReviewCount = @($dryRun.manualReview).Count
        candidateMb = $dryRun.summary.candidateMb
        manualReviewMb = $dryRun.summary.manualReviewMb
    }
    policy = $policy
    summary = $summary
    items = @($manifestItems | Sort-Object groupKey, retainRank, path)
    blockedItems = @($blockedItems | Sort-Object groupKey, retainRank, path)
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$manifestPath = Join-Path $OutputDir "backup-retention-apply-manifest.json"
$reportPath = Join-Path $OutputDir "BACKUP-RETENTION-APPLY-MANIFEST.md"

$manifest | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 备份清理 apply manifest 设计")
$lines.Add("")
$lines.Add("生成时间：$($manifest.generatedAtLocal)")
$lines.Add("")
$lines.Add("本文件是删除前 manifest 设计和二次校验结果，不删除、不移动、不迁移任何文件。即使所有路径验证通过，真实删除仍需要用户再次明确确认 manifest id、路径数量和预计释放体积。")
$lines.Add("")
$lines.Add("## 汇总")
$lines.Add("")
$lines.Add("- manifest id：$($manifest.manifestId)")
$lines.Add("- source dry-run：$($manifest.sourceDryRun.jsonPath)")
$lines.Add("- dry-run 年龄：$($manifest.summary.dryRunAgeHours) 小时")
$lines.Add("- 选择模式：$($manifest.selectionMode)")
$lines.Add("- 选中路径：$($manifest.summary.selectedCount) 个，$($manifest.summary.selectedMb) MB")
$lines.Add("- 通过二次校验：$($manifest.summary.readyForFinalAuthorizationCount) 个，$($manifest.summary.readyMb) MB")
$lines.Add("- 阻塞路径：$($manifest.summary.blockedCount) 个")
$lines.Add("- deleteAllowed=false")
$lines.Add("- executionReady=false")
$lines.Add("")
$lines.Add("## 硬边界")
$lines.Add("")
$lines.Add("- 本脚本只生成 manifest，不包含删除实现。")
$lines.Add("- 人工审查项和保护路径不会进入可删除集合。")
$lines.Add("- 每个路径都必须仍存在、仍在 D 盘、未命中 reparse point，且当前 bytes/files/dirs/SKILL.md/newestUtc/oldestUtc 与 dry-run 快照一致。")
$lines.Add("- 下一阶段如果实现真实 apply，必须要求用户逐字确认 manifest id、路径数量和预计释放体积。")
$lines.Add("")
$lines.Add("## 最终授权短语")
$lines.Add("")
$lines.Add('```text')
$lines.Add($manifest.policy.futureApplyConfirmationPhrase)
$lines.Add('```')
$lines.Add("")
$lines.Add("## 已验证路径")
$lines.Add("")
$lines.Add("| id | 风险 | 组 | 排名 | 体积 MB | 路径 |")
$lines.Add("| --- | --- | --- | ---: | ---: | --- |")
foreach ($item in @($manifest.items | Where-Object { $_.validationStatus -eq "ready-for-final-authorization" } | Sort-Object @{ Expression = { [int64]$_.currentStats.bytes }; Descending = $true }, path)) {
    $lines.Add("| $($item.candidateId) | $(Escape-MarkdownCell $item.risk) | $(Escape-MarkdownCell $item.groupKey) | $($item.retainRank) | $($item.currentStats.mb) | $($item.path) |")
}
$lines.Add("")
$lines.Add("## 阻塞路径")
$lines.Add("")
$lines.Add("| id | 状态 | 原因 | 路径 |")
$lines.Add("| --- | --- | --- | --- |")
foreach ($item in @($manifest.blockedItems)) {
    $lines.Add("| $($item.candidateId) | $(Escape-MarkdownCell $item.validationStatus) | $(Escape-MarkdownCell (@($item.blockers) -join '; ')) | $($item.path) |")
}
$lines.Add("")
$lines.Add("## 下一步")
$lines.Add("")
$lines.Add("1. 人工审查本 manifest 的路径集合、数量和体积。")
$lines.Add("2. 如需真实删除，先实现单独的 apply 执行脚本，并要求用户使用上面的最终授权短语确认。")
$lines.Add("3. 真实删除前再次重新生成 dry-run 和 manifest；本 manifest 过期后不能直接执行。")
$lines.Add("")

$lines | Set-Content -LiteralPath $reportPath -Encoding UTF8

[pscustomobject]@{
    ok = $true
    applyManifestOnly = $true
    readOnly = $true
    deleteAllowed = $false
    executionReady = $false
    manifestId = $manifestId
    outputDir = $OutputDir
    manifestPath = $manifestPath
    reportPath = $reportPath
    selectedCount = $manifest.summary.selectedCount
    readyForFinalAuthorizationCount = $manifest.summary.readyForFinalAuthorizationCount
    blockedCount = $manifest.summary.blockedCount
    readyMb = $manifest.summary.readyMb
}
