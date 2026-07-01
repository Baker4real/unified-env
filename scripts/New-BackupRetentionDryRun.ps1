param(
    [string]$OutputDir = "",
    [int]$RetainCount = 5,
    [string]$CodexRoot = "D:\Codex\.codex",
    [string]$DDriveRoot = "D:\Codex"
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

function Assert-AllowedOutputDir {
    param([string]$Path)

    $allowedRoots = @(
        "D:\Codex\projects\统一环境\reports",
        "D:\Codex\.codex\run-evidence\env-governance"
    )

    foreach ($allowedRoot in $allowedRoots) {
        if (Test-IsSubPath -Path $Path -BasePath $allowedRoot) {
            return
        }
    }

    throw "OutputDir 必须位于允许的报告目录：D:\Codex\projects\统一环境\reports 或 D:\Codex\.codex\run-evidence\env-governance。当前值：$Path"
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

function Get-StrictBackupTimestamp {
    param([string]$Name)

    foreach ($pattern in @(
        "^(?<ts>20\d{6}T\d{6})(?<fraction>\d{3,7})?Z?$",
        "^.+[-_](?<ts>20\d{6}T\d{6})(?<fraction>\d{3,7})?Z?$"
    )) {
        $match = [regex]::Match($Name, $pattern)
        if (-not $match.Success) {
            continue
        }

        try {
            $timestamp = [datetime]::ParseExact(
                $match.Groups["ts"].Value,
                "yyyyMMdd'T'HHmmss",
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal
            ).ToUniversalTime()

            if ($match.Groups["fraction"].Success) {
                $ticksText = $match.Groups["fraction"].Value.PadRight(7, "0").Substring(0, 7)
                $timestamp = $timestamp.AddTicks([int64]$ticksText)
            }

            return [pscustomobject]@{
                ok = $true
                timestampUtc = $timestamp
                source = $match.Value
            }
        } catch {
        }
    }

    foreach ($format in @("yyyyMMdd-HHmmss", "yyyyMMddHHmmss")) {
        $patterns = if ($format -eq "yyyyMMdd-HHmmss") {
            @("^(?<ts>20\d{6}-\d{6})$", "^.+[-_](?<ts>20\d{6}-\d{6})$")
        } else {
            @("^(?<ts>20\d{12})$", "^.+[-_](?<ts>20\d{12})$")
        }

        foreach ($pattern in $patterns) {
            $match = [regex]::Match($Name, $pattern)
            if (-not $match.Success) {
                continue
            }

            try {
                return [pscustomobject]@{
                    ok = $true
                    timestampUtc = [datetime]::ParseExact(
                        $match.Groups["ts"].Value,
                        $format,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeLocal
                    ).ToUniversalTime()
                    source = $match.Value
                }
            } catch {
            }
        }
    }

    [pscustomobject]@{
        ok = $false
        timestampUtc = $null
        source = $null
    }
}

function Get-ReparseReviewReason {
    param([string]$Path)

    $reparse = Get-ReparseInfo -Path $Path
    if ($reparse.hasReparsePoint) {
        return "路径或其已存在父级命中 reparse point，不能自动处理：$($reparse.firstReparsePoint)"
    }

    return "路径命中 reparse point，不能自动处理。"
}

function Get-ReplicatorBackupType {
    param([string]$Name)

    $phase = [regex]::Match($Name, "^(phase\d+)")
    if ($phase.Success) {
        return $phase.Groups[1].Value
    }

    if ($Name -like "review-*") {
        return "review"
    }

    return $null
}

function New-Protection {
    param(
        [string]$Path,
        [string]$Reason
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [pscustomobject]@{
        path = $fullPath
        reason = $Reason
        stats = Get-SafePathStats -Path $fullPath
    }
}

function New-ReviewItem {
    param(
        [string]$Bucket,
        [string]$GroupKey,
        [string]$Path,
        [string]$Risk,
        [string]$Reason,
        [string]$Rule
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [pscustomobject]@{
        bucket = $Bucket
        groupKey = $GroupKey
        path = $fullPath
        risk = $Risk
        reason = $Reason
        rule = $Rule
        automaticCandidate = $false
        applyEligible = $false
        requiresExplicitAuthorization = $true
        blockedBy = @(
            "必须人工确认路径用途和 owner",
            "必须确认不是认证、profile、quota、install state、凭据或运行态共享状态",
            "必须确认不会删除审计证据或回滚边界"
        )
        reparse = Get-ReparseInfo -Path $fullPath
        stats = Get-SafePathStats -Path $fullPath
    }
}

function New-Candidate {
    param(
        [string]$Bucket,
        [string]$GroupKey,
        [string]$ProjectRoot,
        [string]$BackupType,
        [string]$Path,
        [string]$Risk,
        [string]$Reason,
        [datetime]$TimestampUtc,
        [string]$TimestampSource,
        [int]$RetainRank
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [pscustomobject]@{
        bucket = $Bucket
        groupKey = $GroupKey
        projectRoot = $ProjectRoot
        backupType = $BackupType
        path = $fullPath
        risk = $Risk
        reason = $Reason
        rule = "按项目根和备份类型保留最近 $RetainCount 个；本脚本只输出候选，不执行删除。"
        selectedByRetention = $true
        retainRank = $RetainRank
        timestampUtc = $TimestampUtc.ToString("o")
        timestampSource = $TimestampSource
        applyEligible = $false
        requiresExplicitAuthorization = $true
        blockedBy = @(
            "必须重新生成最新 dry-run",
            "必须由用户确认 manifest id、路径集合、候选数量和预计体积",
            "apply 阶段必须二次检查路径、大小、mtime、目录项数量、D 盘边界和 reparse point"
        )
        reparse = Get-ReparseInfo -Path $fullPath
        stats = Get-SafePathStats -Path $fullPath
    }
}

function Add-ReviewItemIfExists {
    param(
        [System.Collections.Generic.List[object]]$ManualReview,
        [string]$Bucket,
        [string]$GroupKey,
        [string]$Path,
        [string]$Risk,
        [string]$Reason,
        [string]$Rule
    )

    if (Test-Path -LiteralPath $Path) {
        $ManualReview.Add((New-ReviewItem -Bucket $Bucket -GroupKey $GroupKey -Path $Path -Risk $Risk -Reason $Reason -Rule $Rule))
    }
}

function Add-RetentionCandidates {
    param(
        [System.Collections.Generic.List[object]]$Candidates,
        [System.Collections.Generic.List[object]]$ManualReview,
        [string]$Root,
        [string]$Bucket,
        [string]$ProjectRootLabel,
        [scriptblock]$BackupTypeSelector,
        [string]$Risk,
        [string]$Reason
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    $rootReparse = Get-ReparseInfo -Path $Root
    if ($rootReparse.hasReparsePoint) {
        $ManualReview.Add((New-ReviewItem -Bucket $Bucket -GroupKey $ProjectRootLabel -Path $Root -Risk "高" -Reason (Get-ReparseReviewReason -Path $Root) -Rule "人工审查。"))
        return
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($child in Get-ChildItem -LiteralPath $Root -Force -Directory) {
        $childReparse = Get-ReparseInfo -Path $child.FullName
        if ($childReparse.hasReparsePoint) {
            $ManualReview.Add((New-ReviewItem -Bucket $Bucket -GroupKey $ProjectRootLabel -Path $child.FullName -Risk "高" -Reason (Get-ReparseReviewReason -Path $child.FullName) -Rule "人工审查。"))
            continue
        }

        $backupType = & $BackupTypeSelector $child.Name
        if ($backupType -eq "__skip__") {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($backupType)) {
            $ManualReview.Add((New-ReviewItem -Bucket $Bucket -GroupKey $ProjectRootLabel -Path $child.FullName -Risk "中" -Reason "无法稳定识别同项目同备份类型分组。" -Rule "人工审查。"))
            continue
        }

        $timestamp = Get-StrictBackupTimestamp -Name $child.Name
        if (-not [bool]$timestamp.ok) {
            $ManualReview.Add((New-ReviewItem -Bucket $Bucket -GroupKey "$ProjectRootLabel::$backupType" -Path $child.FullName -Risk "中" -Reason "无法严格解析目录名时间戳，不能用 mtime 兜底进入保留删除候选。" -Rule "人工审查。"))
            continue
        }

        $groupKey = "$ProjectRootLabel::$backupType"
        $records.Add([pscustomobject]@{
            item = $child
            groupKey = $groupKey
            projectRoot = $ProjectRootLabel
            backupType = $backupType
            timestampUtc = $timestamp.timestampUtc
            timestampSource = $timestamp.source
        })
    }

    foreach ($group in ($records | Group-Object groupKey)) {
        $ordered = @($group.Group | Sort-Object @{ Expression = { $_.timestampUtc }; Descending = $true }, @{ Expression = { $_.item.Name }; Descending = $true })
        for ($index = $RetainCount; $index -lt $ordered.Count; $index++) {
            $record = $ordered[$index]
            $candidate = New-Candidate -Bucket $Bucket -GroupKey $record.groupKey -ProjectRoot $record.projectRoot -BackupType $record.backupType -Path $record.item.FullName -Risk $Risk -Reason $Reason -TimestampUtc $record.timestampUtc -TimestampSource $record.timestampSource -RetainRank ($index + 1)
            if ($candidate.reparse.hasReparsePoint -or [int]$candidate.stats.reparsePointsSkipped -gt 0 -or [int]$candidate.stats.inaccessibleItems -gt 0) {
                $ManualReview.Add((New-ReviewItem -Bucket $Bucket -GroupKey $record.groupKey -Path $record.item.FullName -Risk "高" -Reason "候选目录内部存在 reparse point 或不可访问项，不能作为 apply 候选。" -Rule "人工审查。"))
                continue
            }

            $Candidates.Add($candidate)
        }
    }
}

Assert-DDrivePath -Path $CodexRoot -ParameterName "CodexRoot"
Assert-DDrivePath -Path $DDriveRoot -ParameterName "DDriveRoot"
if ($RetainCount -lt 1) {
    throw "RetainCount 必须大于等于 1。"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = "D:\Codex\.codex\run-evidence\env-governance\backup-retention-$stamp"
}

Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"
Assert-AllowedOutputDir -Path $OutputDir

$protected = New-Object System.Collections.Generic.List[object]
$manualReview = New-Object System.Collections.Generic.List[object]
$candidates = New-Object System.Collections.Generic.List[object]

$protected.Add((New-Protection -Path (Join-Path $CodexRoot "skills") -Reason "当前用户安装 skill 活跃层，不能按备份清理。"))
$protected.Add((New-Protection -Path (Join-Path $CodexRoot "plugins\cache") -Reason "当前插件缓存活跃层，包含官方或已安装插件 skill。"))
$protected.Add((New-Protection -Path (Join-Path $CodexRoot "account_backup") -Reason "账号备份根不能整体删除；只允许显式 allowlist 子树进入人工审查或候选。"))
$protected.Add((New-Protection -Path (Join-Path $CodexRoot "account_backup\windows\plugins") -Reason "runtime 共享 plugins 目录，不能按备份清理。"))
$protected.Add((New-Protection -Path (Join-Path $CodexRoot "account_backup\windows\cache") -Reason "runtime 共享 cache 目录，不能按备份清理。"))
$protected.Add((New-Protection -Path (Join-Path $CodexRoot "account_backup\windows\sqlite") -Reason "runtime 共享 sqlite 目录，不能按备份清理。"))
foreach ($sensitive in @("auth.json", "profile.json", "install_state.json", "quota_cache.json")) {
    $protected.Add((New-Protection -Path (Join-Path $CodexRoot "account_backup\windows\$sensitive") -Reason "账号敏感文件，保护。"))
}

Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "runtime/shared-cache" -GroupKey "account_backup/windows/login_runtime" -Path (Join-Path $CodexRoot "account_backup\windows\login_runtime\plugins") -Risk "高" -Reason "login runtime 插件缓存邻近账号 runtime，不能作为低风险备份候选。" -Rule "人工确认，不进入自动保留清理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "runtime/shared-cache" -GroupKey "account_backup/windows/login_runtime" -Path (Join-Path $CodexRoot "account_backup\windows\login_runtime\.tmp\plugins") -Risk "高" -Reason ".tmp/plugins 可能是 runtime 或安装流程中间态，不能整体自动 prune。" -Rule "人工确认，不进入自动保留清理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "runtime/shared-cache" -GroupKey "account_backup/windows/refresh_runtime" -Path (Join-Path $CodexRoot "account_backup\windows\refresh_runtime\plugins") -Risk "高" -Reason "refresh runtime 插件缓存属于上游共享行为边界，不能作为低风险备份候选。" -Rule "人工确认，不进入自动保留清理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "runtime/shared-cache" -GroupKey "account_backup/windows/refresh_runtime" -Path (Join-Path $CodexRoot "account_backup\windows\refresh_runtime\.tmp") -Risk "高" -Reason ".tmp 目录不能整体加入登录、refresh、autosave 生命周期自动 prune。" -Rule "人工确认，不进入自动保留清理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "历史账号临时缓存" -GroupKey "account_backup/c" -Path (Join-Path $CodexRoot "account_backup\c\.tmp\plugins") -Risk "中" -Reason "旧 profile 临时插件缓存，需确认 profile 状态。" -Rule "人工确认后另行处理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "历史账号临时缓存" -GroupKey "account_backup/c" -Path (Join-Path $CodexRoot "account_backup\c\.tmp\bundled-marketplaces") -Risk "中" -Reason "旧 profile marketplace staging，需确认没有安装或更新进程使用。" -Rule "人工确认后另行处理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "历史账号临时缓存" -GroupKey "account_backup/b" -Path (Join-Path $CodexRoot "account_backup\b\tmp") -Risk "中" -Reason "历史 tmp/codex-temp-import skill 安装缓存，需确认账号/profile 归属。" -Rule "人工确认后另行处理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "全局临时 staging" -GroupKey ".codex/.tmp" -Path (Join-Path $CodexRoot ".tmp\bundled-marketplaces") -Risk "中" -Reason "全局 marketplace staging 可重建但可能被安装或更新流程占用。" -Rule "人工确认后另行处理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "全局备份根" -GroupKey ".codex/backups" -Path (Join-Path $CodexRoot "backups") -Risk "中" -Reason "全局 backups 根混有不同回滚语义，不能合并为同一种备份类型。" -Rule "人工确认或显式分组 allowlist 后另行处理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "旧 skill 备份" -GroupKey ".codex/skills-backups" -Path (Join-Path $CodexRoot "skills-backups") -Risk "中" -Reason "旧 skill 备份目录，需确认是否仍是回滚边界。" -Rule "人工确认后另行处理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "旧本地备份" -GroupKey ".codex/.backups" -Path (Join-Path $CodexRoot ".backups") -Risk "中" -Reason "旧本地备份目录，需确认用途。" -Rule "人工确认后另行处理。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "历史迁移备份" -GroupKey ".codex-c-backups" -Path (Join-Path $DDriveRoot ".codex-c-backups") -Risk "高" -Reason "旧 C 盘或迁移备份可能有审计价值，默认不能自动删除。" -Rule "单独人工确认。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "运行证据" -GroupKey "run-evidence" -Path (Join-Path $CodexRoot "run-evidence") -Risk "高" -Reason "run-evidence 是审计证据根，默认不能自动删除。" -Rule "单独人工确认。"
Add-ReviewItemIfExists -ManualReview $manualReview -Bucket "账号自动快照" -GroupKey "account_backup/_autosave" -Path (Join-Path $CodexRoot "account_backup\_autosave") -Risk "高" -Reason "_autosave 是 auth/profile 回滚边界，不能进入默认保留删除候选。" -Rule "单独人工确认。"

Add-RetentionCandidates -Candidates $candidates -ManualReview $manualReview -Root (Join-Path $CodexRoot "backups_state\provider-sync") -Bucket "按组保留最近 5 个" -ProjectRootLabel ".codex/backups_state/provider-sync" -BackupTypeSelector { param($Name) "provider-sync" } -Risk "低" -Reason "provider-sync 状态备份超过保留数。"
Add-RetentionCandidates -Candidates $candidates -ManualReview $manualReview -Root (Join-Path $DDriveRoot ".gsd\backups\replicator") -Bucket "按组保留最近 5 个" -ProjectRootLabel ".gsd/backups/replicator" -BackupTypeSelector { param($Name) Get-ReplicatorBackupType -Name $Name } -Risk "中" -Reason "GSD replicator 备份超过保留数。"
Add-RetentionCandidates -Candidates $candidates -ManualReview $manualReview -Root (Join-Path $DDriveRoot "projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator") -Bucket "按组保留最近 5 个" -ProjectRootLabel "projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator" -BackupTypeSelector { param($Name) Get-ReplicatorBackupType -Name $Name } -Risk "中" -Reason "历史归档 replicator 临时备份超过保留数。"
Add-RetentionCandidates -Candidates $candidates -ManualReview $manualReview -Root (Join-Path $CodexRoot "backups_state") -Bucket "按组保留最近 5 个" -ProjectRootLabel ".codex/backups_state/root-sidecars" -BackupTypeSelector {
    param($Name)
    if ($Name -like "config.toml*") { return "config.toml sidecars" }
    if ($Name -like ".codex-global-state.json*") { return ".codex-global-state.json sidecars" }
    return "__skip__"
} -Risk "低" -Reason "backups_state 根侧车备份超过保留数。"

$candidateBytes = [int64]0
$candidateSkillMd = 0
foreach ($candidate in $candidates) {
    $candidateBytes += [int64]$candidate.stats.bytes
    $candidateSkillMd += [int]$candidate.stats.skillMd
}

$manualReviewBytes = [int64]0
foreach ($item in $manualReview) {
    $manualReviewBytes += [int64]$item.stats.bytes
}

$byBucket = @($candidates | Group-Object bucket | ForEach-Object {
    $items = @($_.Group)
    $bytes = [int64](($items | ForEach-Object { [int64]$_.stats.bytes } | Measure-Object -Sum).Sum)
    [pscustomobject]@{
        bucket = $_.Name
        count = $items.Count
        bytes = $bytes
        mb = ConvertTo-Mb -Bytes $bytes
        skillMd = [int](($items | ForEach-Object { [int]$_.stats.skillMd } | Measure-Object -Sum).Sum)
    }
} | Sort-Object count -Descending)

$manualByBucket = @($manualReview | Group-Object bucket | ForEach-Object {
    $items = @($_.Group)
    $bytes = [int64](($items | ForEach-Object { [int64]$_.stats.bytes } | Measure-Object -Sum).Sum)
    [pscustomobject]@{
        bucket = $_.Name
        count = $items.Count
        bytes = $bytes
        mb = ConvertTo-Mb -Bytes $bytes
        skillMd = [int](($items | ForEach-Object { [int]$_.stats.skillMd } | Measure-Object -Sum).Sum)
    }
} | Sort-Object count -Descending)

$protectedItems = @($protected.ToArray())
$manualReviewItems = @($manualReview.ToArray() | Sort-Object @{ Expression = { [int64]$_.stats.bytes }; Descending = $true }, path)
$candidateItems = @($candidates.ToArray() | Sort-Object groupKey, @{ Expression = { $_.retainRank }; Descending = $false }, path)

$policy = New-Object psobject -Property ([ordered]@{
    "summary" = "只读 dry-run；不删除、不移动、不迁移；真实清理必须另行显式授权。"
    "protectedRootsCannotBeDeleted" = $true
    "explicitAuthorizationRequired" = $true
    "applyMustRegenerateDryRun" = $true
    "applyMustCheckReparsePoints" = $true
    "applyMustUseAllowlist" = $true
    "strictTimestampRequired" = $true
    "runtimeSharedDirsExcluded" = $true
    "authAutosaveExcludedByDefault" = $true
})

$summary = New-Object psobject -Property ([ordered]@{
    "protectedCount" = $protected.Count
    "manualReviewCount" = $manualReview.Count
    "manualReviewBytes" = $manualReviewBytes
    "manualReviewMb" = ConvertTo-Mb -Bytes $manualReviewBytes
    "candidateCount" = $candidates.Count
    "candidateBytes" = $candidateBytes
    "candidateMb" = ConvertTo-Mb -Bytes $candidateBytes
    "candidateSkillMd" = $candidateSkillMd
    "selectedByRetentionCount" = $candidates.Count
    "lowRiskCount" = @($candidates | Where-Object { $_.risk -eq "低" }).Count
    "mediumRiskCount" = @($candidates | Where-Object { $_.risk -eq "中" }).Count
    "highRiskCount" = @($candidates | Where-Object { $_.risk -eq "高" }).Count
    "byBucket" = @($byBucket)
    "manualByBucket" = @($manualByBucket)
})

$result = New-Object psobject -Property ([ordered]@{
    "schemaVersion" = 1
    "generatedAtLocal" = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
    "generatedAtUtc" = (Get-Date).ToUniversalTime().ToString("o")
    "dryRun" = $true
    "readOnly" = $true
    "deleteAllowed" = $false
    "applySupported" = $false
    "retainCount" = $RetainCount
    "policy" = $policy
    "protected" = $protectedItems
    "manualReview" = $manualReviewItems
    "candidates" = $candidateItems
    "summary" = $summary
})

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$jsonPath = Join-Path $OutputDir "backup-retention-dry-run.json"
$reportPath = Join-Path $OutputDir "BACKUP-RETENTION-DRY-RUN.md"

$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 备份保留清理 dry-run 报告")
$lines.Add("")
$lines.Add("生成时间：$($result.generatedAtLocal)")
$lines.Add("")
$lines.Add("本报告只读生成，不删除、不移动、不迁移任何文件。真实清理前必须重新生成 dry-run，并由用户确认具体 manifest、路径集合、候选数量和预计体积。")
$lines.Add("")
$lines.Add("## 汇总")
$lines.Add("")
$lines.Add("- 保护项：$($result.summary.protectedCount) 个")
$lines.Add("- 人工审查项：$($result.summary.manualReviewCount) 个，$($result.summary.manualReviewMb) MB")
$lines.Add("- 保留规则候选项：$($result.summary.candidateCount) 个")
$lines.Add("- 候选体积：$($result.summary.candidateMb) MB")
$lines.Add("- 候选项内 SKILL.md 数：$($result.summary.candidateSkillMd) 个")
$lines.Add("- 完整 JSON：$jsonPath")
$lines.Add("")
$lines.Add("## 硬边界")
$lines.Add("")
$lines.Add("- 本脚本不支持 apply，deleteAllowed=false。")
$lines.Add("- 不能删除 auth.json、profile.json、install_state.json、quota_cache.json、当前 skills、当前 plugins/cache 或 account_backup 根。")
$lines.Add("- runtime shared dirs plugins、cache、sqlite 不进入保留清理候选。")
$lines.Add("- plugins、.tmp、_autosave、run-evidence、.codex-c-backups 默认只进入人工审查，不进入自动 prune。")
$lines.Add("- 保留规则必须有项目根、备份类型、严格目录名时间戳；不能用 mtime 或模糊正则兜底。")
$lines.Add("- 命中 junction、symlink 或 reparse point 的路径只能人工审查。")
$lines.Add("")
$lines.Add("## 候选类别汇总")
$lines.Add("")
$lines.Add("| 类别 | 项数 | 体积 MB | SKILL.md 数 |")
$lines.Add("| --- | ---: | ---: | ---: |")
foreach ($bucket in $result.summary.byBucket) {
    $lines.Add("| $(Escape-MarkdownCell $bucket.bucket) | $($bucket.count) | $($bucket.mb) | $($bucket.skillMd) |")
}
$lines.Add("")
$lines.Add("## 人工审查类别汇总")
$lines.Add("")
$lines.Add("| 类别 | 项数 | 体积 MB | SKILL.md 数 |")
$lines.Add("| --- | ---: | ---: | ---: |")
foreach ($bucket in $result.summary.manualByBucket) {
    $lines.Add("| $(Escape-MarkdownCell $bucket.bucket) | $($bucket.count) | $($bucket.mb) | $($bucket.skillMd) |")
}
$lines.Add("")
$lines.Add("## 保护项")
$lines.Add("")
foreach ($item in $result.protected) {
    $exists = if ($item.stats.exists) { "存在" } else { "不存在" }
    $lines.Add("- $($item.path)：$($item.reason)（$exists）")
}
$lines.Add("")
$lines.Add("## 最大人工审查项")
$lines.Add("")
$lines.Add("| 风险 | 类别 | 体积 MB | SKILL.md 数 | 路径 |")
$lines.Add("| --- | --- | ---: | ---: | --- |")
foreach ($item in @($result.manualReview | Sort-Object @{ Expression = { [int64]$_.stats.bytes }; Descending = $true } | Select-Object -First 20)) {
    $lines.Add("| $(Escape-MarkdownCell $item.risk) | $(Escape-MarkdownCell $item.bucket) | $($item.stats.mb) | $($item.stats.skillMd) | $($item.path) |")
}
$lines.Add("")
$lines.Add("## 最大保留规则候选项")
$lines.Add("")
$lines.Add("| 风险 | 组 | 排名 | 时间戳 | 体积 MB | SKILL.md 数 | 路径 |")
$lines.Add("| --- | --- | ---: | --- | ---: | ---: | --- |")
foreach ($candidate in @($result.candidates | Sort-Object @{ Expression = { [int64]$_.stats.bytes }; Descending = $true } | Select-Object -First 30)) {
    $lines.Add("| $(Escape-MarkdownCell $candidate.risk) | $(Escape-MarkdownCell $candidate.groupKey) | $($candidate.retainRank) | $(Escape-MarkdownCell $candidate.timestampSource) | $($candidate.stats.mb) | $($candidate.stats.skillMd) | $($candidate.path) |")
}
$lines.Add("")
$lines.Add("## 下一步")
$lines.Add("")
$lines.Add("1. 由用户确认是否继续到 apply 设计；笼统的继续不等于删除授权。")
$lines.Add("2. 若要 apply，必须基于最新 JSON 生成显式 allowlist，并二次验证 path、size、mtime、目录计数、D 盘边界和 reparse point。")
$lines.Add("3. 人工审查项不能混入一键清理；永久删除必须作为单独显式授权。")
$lines.Add("")

$lines | Set-Content -LiteralPath $reportPath -Encoding UTF8

[pscustomobject]@{
    ok = $true
    dryRun = $true
    readOnly = $true
    deleteAllowed = $false
    outputDir = $OutputDir
    jsonPath = $jsonPath
    reportPath = $reportPath
    candidateCount = $result.summary.candidateCount
    candidateMb = $result.summary.candidateMb
    manualReviewCount = $result.summary.manualReviewCount
    manualReviewMb = $result.summary.manualReviewMb
}
