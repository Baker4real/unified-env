$backupRetentionLibraryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $backupRetentionLibraryRoot 'lib\EnvPathSafety.ps1')

function Get-BackupRetentionCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)

    Assert-EnvSafeAbsolutePath -Path $Path -FactName 'backup retention path'
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ieq $root) { return $root }
    return $fullPath.TrimEnd('\', '/')
}

function Test-BackupRetentionReparseAncestor {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-BackupRetentionCanonicalPath -Path $Path
    $current = $fullPath
    while (-not (Test-Path -LiteralPath $current -ErrorAction Stop)) {
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ ok = $false; firstReparsePoint = $item.FullName }
        }
        $parent = [IO.Directory]::GetParent($item.FullName)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
    return [pscustomobject]@{ ok = $true; firstReparsePoint = $null }
}

function Assert-BackupRetentionDPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Get-BackupRetentionCanonicalPath -Path $Path
    if ([IO.Path]::GetPathRoot($fullPath) -ine 'D:\') {
        throw "$Name 必须位于 D:\ 下：$fullPath"
    }
    $reparse = Test-BackupRetentionReparseAncestor -Path $fullPath
    if (-not $reparse.ok) {
        throw "$Name 不得穿过 reparse point：$($reparse.firstReparsePoint)"
    }
    return $fullPath
}

function New-BackupRetentionPolicyContext {
    [CmdletBinding()]
    param(
        [ValidateSet('production', 'test')][string]$ArtifactMode = 'production',
        [string]$CodexRoot = 'D:\Codex\.codex',
        [string]$DDriveRoot = 'D:\Codex',
        [int]$RetainCount = 5
    )

    $canonicalCodexRoot = Assert-BackupRetentionDPath -Path $CodexRoot -Name 'CodexRoot'
    $canonicalDDriveRoot = Assert-BackupRetentionDPath -Path $DDriveRoot -Name 'DDriveRoot'
    if ($RetainCount -lt 1) { throw 'RetainCount 必须大于等于 1。' }

    if ($ArtifactMode -ceq 'production') {
        if ($canonicalCodexRoot -cne 'D:\Codex\.codex' -or
            $canonicalDDriveRoot -cne 'D:\Codex' -or
            $RetainCount -ne 5) {
            throw 'production context 必须精确使用 CodexRoot=D:\Codex\.codex、DDriveRoot=D:\Codex、retainCount=5。'
        }
    }

    return [pscustomobject][ordered]@{
        artifactMode = $ArtifactMode
        CodexRoot = $canonicalCodexRoot
        DDriveRoot = $canonicalDDriveRoot
        retainCount = $RetainCount
        policyId = 'env-governance.backup-retention'
        policyVersion = 2
    }
}

function Get-BackupRetentionDeclaredScanRoots {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$PolicyContext)

    return @(
        [pscustomobject]@{ rootId = 'codex-backups-state'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.CodexRoot 'backups_state'); rule = 'backups-state-root' },
        [pscustomobject]@{ rootId = 'provider-sync'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.CodexRoot 'backups_state\provider-sync'); rule = 'provider-sync' },
        [pscustomobject]@{ rootId = 'gsd-replicator'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.DDriveRoot '.gsd\backups\replicator'); rule = 'replicator' },
        [pscustomobject]@{ rootId = 'archive-replicator'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.DDriveRoot 'projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator'); rule = 'replicator' },
        [pscustomobject]@{ rootId = 'codex-switch-installed-backups'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.DDriveRoot 'apps\codex_switch\backups'); rule = 'codex-switch' }
    )
}

function Get-BackupRetentionSha256 {
    param([Parameter(Mandatory)][string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-BackupRetentionReparseMetadata {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)

    $isReparse = ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    $target = $null
    if ($isReparse -and $Item.PSObject.Properties.Name -contains 'Target') {
        $targetValue = $Item.Target
        if ($targetValue -is [array]) { $target = @($targetValue) -join ';' } else { $target = [string]$targetValue }
    }
    return [pscustomobject]@{ isReparsePoint = $isReparse; reparseTarget = $target }
}

function Get-BackupRetentionRootSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$DeclaredScanRoot)

    $path = Get-BackupRetentionCanonicalPath -Path ([string]$DeclaredScanRoot.path)
    $started = (Get-Date).ToUniversalTime().ToString('o')
    $errors = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[object]]::new()
    $exists = $false
    $rootIsReparse = $false
    $completed = $false

    try {
        $exists = Test-Path -LiteralPath $path -ErrorAction Stop
        if (-not $exists) {
            $completed = $true
        } else {
            $rootItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $rootItem.PSIsContainer) {
                $errors.Add("声明扫描根已被非目录项占用：$path")
            } else {
                $rootIsReparse = ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            }
            if ($rootIsReparse) {
                $errors.Add("声明扫描根是 reparse point：$path")
            } elseif ($rootItem.PSIsContainer) {
                foreach ($child in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)) {
                    $reparse = Get-BackupRetentionReparseMetadata -Item $child
                    $items.Add([pscustomobject][ordered]@{
                        path = Get-BackupRetentionCanonicalPath -Path $child.FullName
                        name = $child.Name
                        itemType = if ($child.PSIsContainer) { 'directory' } else { 'file' }
                        isReparsePoint = $reparse.isReparsePoint
                        reparseTarget = $reparse.reparseTarget
                    })
                }
                $completed = $true
            }
        }
    } catch {
        $errors.Add($_.Exception.Message)
    }

    $canonicalItems = @($items.ToArray() | Sort-Object path)
    $snapshotJson = ConvertTo-Json -InputObject @($canonicalItems) -Depth 5 -Compress
    if ($null -eq $snapshotJson) { $snapshotJson = '[]' }
    return [pscustomobject][ordered]@{
        rootId = [string]$DeclaredScanRoot.rootId
        path = $path
        rule = [string]$DeclaredScanRoot.rule
        exists = $exists
        rootIsReparsePoint = $rootIsReparse
        enumerationStarted = $started
        enumerationCompleted = $completed
        errors = [object[]]$errors.ToArray()
        directChildCount = $canonicalItems.Count
        directChildren = [object[]]$canonicalItems
        snapshotSha256 = Get-BackupRetentionSha256 -Value $snapshotJson
        classificationCount = 0
        classificationCounts = [pscustomobject]@{ candidate = 0; retained = 0; protected = 0; 'delegated-root' = 0; gap = 0 }
    }
}

function Get-BackupRetentionStrictTimestamp {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($definition in @(
        @{ Pattern = '^(?<ts>20\d{6}T\d{6})(?<fraction>\d{3,7})?Z?$'; Format = "yyyyMMdd'T'HHmmss"; Universal = $true },
        @{ Pattern = '^.+[-_](?<ts>20\d{6}T\d{6})(?<fraction>\d{3,7})?Z?$'; Format = "yyyyMMdd'T'HHmmss"; Universal = $true },
        @{ Pattern = '^(?<ts>20\d{6}-\d{6})$'; Format = 'yyyyMMdd-HHmmss'; Universal = $false },
        @{ Pattern = '^.+[-_](?<ts>20\d{6}-\d{6})$'; Format = 'yyyyMMdd-HHmmss'; Universal = $false },
        @{ Pattern = '^(?<ts>20\d{12})$'; Format = 'yyyyMMddHHmmss'; Universal = $false },
        @{ Pattern = '^.+[-_](?<ts>20\d{12})$'; Format = 'yyyyMMddHHmmss'; Universal = $false }
    )) {
        $match = [regex]::Match($Name, $definition.Pattern)
        if (-not $match.Success) { continue }
        try {
            $styles = if ($definition.Universal) { [Globalization.DateTimeStyles]::AssumeUniversal } else { [Globalization.DateTimeStyles]::AssumeLocal }
            $timestamp = [datetime]::ParseExact($match.Groups['ts'].Value, $definition.Format, [Globalization.CultureInfo]::InvariantCulture, $styles).ToUniversalTime()
            if ($match.Groups['fraction'].Success) {
                $timestamp = $timestamp.AddTicks([int64]$match.Groups['fraction'].Value.PadRight(7, '0').Substring(0, 7))
            }
            return [pscustomobject]@{ ok = $true; timestampUtc = $timestamp; source = $match.Value }
        } catch { }
    }
    return [pscustomobject]@{ ok = $false; timestampUtc = $null; source = $null }
}

function Get-BackupRetentionSafeStats {
    param([Parameter(Mandatory)][string]$Path)

    $result = [ordered]@{ exists = $false; bytes = [int64]0; mb = 0.0; files = 0; dirs = 0; skillMd = 0; newestUtc = $null; oldestUtc = $null; reparsePointsSkipped = 0; inaccessibleItems = 0 }
    try {
        $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $result.exists = $true
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.reparsePointsSkipped++; return [pscustomobject]$result }
        $stack = [Collections.Generic.Stack[string]]::new()
        if ($rootItem.PSIsContainer) { $stack.Push($rootItem.FullName) } else {
            $result.files = 1; $result.bytes = [int64]$rootItem.Length
            $result.skillMd = if ($rootItem.Name -ieq 'SKILL.md') { 1 } else { 0 }
            $result.newestUtc = $rootItem.LastWriteTimeUtc.ToString('o'); $result.oldestUtc = $result.newestUtc
        }
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try { $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) } catch { $result.inaccessibleItems++; continue }
            foreach ($child in $children) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.reparsePointsSkipped++; continue }
                $last = $child.LastWriteTimeUtc
                if ($null -eq $result.newestUtc -or $last -gt [datetime]$result.newestUtc) { $result.newestUtc = $last.ToString('o') }
                if ($null -eq $result.oldestUtc -or $last -lt [datetime]$result.oldestUtc) { $result.oldestUtc = $last.ToString('o') }
                if ($child.PSIsContainer) { $result.dirs++; $stack.Push($child.FullName) } else {
                    $result.files++; $result.bytes += [int64]$child.Length
                    if ($child.Name -ieq 'SKILL.md') { $result.skillMd++ }
                }
            }
        }
    } catch { $result.inaccessibleItems++ }
    $result.mb = [math]::Round(($result.bytes / 1MB), 2)
    return [pscustomobject]$result
}

function New-BackupRetentionCoverageItem {
    param(
        [string]$Path, [AllowNull()][string]$ScanRoot, [string]$ItemType,
        [string]$Disposition, [string]$Reason, [bool]$Manual,
        [bool]$Blocks, [string]$Bucket = '', [string]$GroupKey = '',
        [string]$ProjectRoot = '', [string]$BackupType = '',
        [AllowNull()][object]$Timestamp = $null, [int]$RetainRank = 0,
        [string]$Risk = '低', [AllowNull()][string]$DelegatedScanRoot = $null,
        [bool]$IsReparsePoint = $false, [AllowNull()][string]$ReparseTarget = $null,
        [AllowNull()][object]$Stats = $null, [string]$CoverageOrigin = 'scan'
    )

    return [pscustomobject][ordered]@{
        path = Get-BackupRetentionCanonicalPath -Path $Path
        scanRoot = if ([string]::IsNullOrWhiteSpace($ScanRoot)) { $null } else { Get-BackupRetentionCanonicalPath -Path $ScanRoot }
        itemType = $ItemType
        coverageOrigin = $CoverageOrigin
        coverageDisposition = $Disposition
        coverageAccounted = $true
        requiresManualReview = $Manual
        blocksCoverage = $Blocks
        reason = $Reason
        rule = if ($Disposition -ceq 'candidate' -or $Disposition -ceq 'retained') { "按项目根和备份类型保留最近项；当前 retainCount 由 policy context 固定。" } elseif ($Manual) { '人工审查。' } else { '显式保护。' }
        bucket = $Bucket
        groupKey = $GroupKey
        projectRoot = $ProjectRoot
        backupType = $BackupType
        timestampUtc = if ($null -eq $Timestamp) { $null } else { $Timestamp.timestampUtc.ToString('o') }
        timestampSource = if ($null -eq $Timestamp) { $null } else { $Timestamp.source }
        retainRank = if ($RetainRank -gt 0) { $RetainRank } else { $null }
        risk = $Risk
        delegatedScanRoot = if ([string]::IsNullOrWhiteSpace($DelegatedScanRoot)) { $null } else { Get-BackupRetentionCanonicalPath -Path $DelegatedScanRoot }
        isReparsePoint = $IsReparsePoint
        reparseTarget = $ReparseTarget
        reparse = [pscustomobject]@{
            isReparsePoint = $IsReparsePoint
            hasReparsePoint = $IsReparsePoint
            firstReparsePoint = if ($IsReparsePoint) { Get-BackupRetentionCanonicalPath -Path $Path } else { $null }
            target = $ReparseTarget
        }
        automaticCandidate = $Disposition -ceq 'candidate'
        selectedByRetention = $Disposition -ceq 'candidate'
        applyEligible = $false
        requiresExplicitAuthorization = $Disposition -ceq 'candidate' -or $Manual
        blockedBy = if ($Disposition -ceq 'candidate') { @('必须重新生成最新 dry-run', '必须由用户确认 manifest 和路径集合', 'apply 阶段必须二次检查状态指纹') } elseif ($Manual) { @('必须人工确认路径用途和 owner') } else { @() }
        stats = $Stats
    }
}

function Test-BackupRetentionDirectChild {
    param([string]$Parent, [string]$Child)
    try {
        $parentPath = Get-BackupRetentionCanonicalPath $Parent
        $childPath = Get-BackupRetentionCanonicalPath $Child
        $childParent = [IO.Directory]::GetParent($childPath)
        return $null -ne $childParent -and $childParent.FullName.TrimEnd('\') -ieq $parentPath.TrimEnd('\')
    } catch { return $false }
}

function Test-BackupRetentionDelegationGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DeclaredScanRoots,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CoverageItems
    )

    $errors = [Collections.Generic.List[string]]::new()
    $roots = @{}
    foreach ($root in $DeclaredScanRoots) {
        $path = Get-BackupRetentionCanonicalPath ([string]$root.path)
        $roots[$path.ToLowerInvariant()] = $root
    }
    $edges = @{}
    $parentsByTarget = @{}
    foreach ($item in @($CoverageItems | Where-Object { $_.coverageDisposition -ceq 'delegated-root' })) {
        $parent = Get-BackupRetentionCanonicalPath ([string]$item.scanRoot)
        $itemPath = Get-BackupRetentionCanonicalPath ([string]$item.path)
        $target = Get-BackupRetentionCanonicalPath ([string]$item.delegatedScanRoot)
        if ($parent -ieq $target) { $errors.Add("委托不得自引用：$parent") }
        if ($itemPath -ine $target) { $errors.Add("委托目标必须等于当前子项：$itemPath") }
        if (-not (Test-BackupRetentionDirectChild -Parent $parent -Child $target)) { $errors.Add("委托目标必须是父根的直接子项：$target") }
        $targetKey = $target.ToLowerInvariant(); $parentKey = $parent.ToLowerInvariant()
        if (-not $roots.ContainsKey($targetKey)) { $errors.Add("委托目标不在 declaredScanRoots：$target") }
        elseif (($roots[$targetKey].PSObject.Properties.Name -contains 'exists' -and -not [bool]$roots[$targetKey].exists) -or
            ($roots[$targetKey].PSObject.Properties.Name -contains 'enumerationCompleted' -and -not [bool]$roots[$targetKey].enumerationCompleted)) {
            $errors.Add("委托目标不存在或未成功枚举：$target")
        }
        if ($parentsByTarget.ContainsKey($targetKey) -and $parentsByTarget[$targetKey] -ine $parentKey) { $errors.Add("被委托根不得有多个父级：$target") }
        $parentsByTarget[$targetKey] = $parentKey
        if (-not $edges.ContainsKey($parentKey)) { $edges[$parentKey] = [Collections.Generic.List[string]]::new() }
        $edges[$parentKey].Add($targetKey)
    }

    foreach ($start in @($edges.Keys)) {
        $stack = [Collections.Generic.Stack[object]]::new()
        $stack.Push([pscustomobject]@{ node = $start; ancestry = @() })
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            if (@($frame.ancestry | Where-Object { $_ -ceq $frame.node }).Count -gt 0) {
                $errors.Add("委托图不得有环：$start")
                break
            }
            if (-not $edges.ContainsKey($frame.node)) { continue }
            $nextAncestry = @($frame.ancestry) + @($frame.node)
            foreach ($target in @($edges[$frame.node])) {
                $stack.Push([pscustomobject]@{ node = $target; ancestry = $nextAncestry })
            }
        }
    }
    return [pscustomobject]@{ valid = $errors.Count -eq 0; errors = [object[]]$errors.ToArray() }
}

function Get-BackupRetentionGuardrailItems {
    param([Parameter(Mandatory)][psobject]$PolicyContext)

    $definitions = @(
        @{ Relative = 'skills'; Reason = '当前用户 skill 活跃层，不能按备份清理。'; Manual = $false },
        @{ Relative = 'plugins\cache'; Reason = '当前插件缓存活跃层，不能按备份清理。'; Manual = $false },
        @{ Relative = 'account_backup'; Reason = '账号备份根不能整体删除。'; Manual = $false },
        @{ Relative = 'account_backup\windows\plugins'; Reason = 'runtime 共享 plugins 目录，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\cache'; Reason = 'runtime 共享 cache 目录，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\sqlite'; Reason = 'runtime 共享 sqlite 目录，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\auth.json'; Reason = '账号敏感文件，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\profile.json'; Reason = '账号敏感文件，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\install_state.json'; Reason = '安装状态文件，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\quota_cache.json'; Reason = '配额状态文件，保护。'; Manual = $false },
        @{ Relative = 'backups'; Reason = '全局 backups 根混有不同回滚语义，仅人工审查。'; Manual = $true },
        @{ Relative = 'run-evidence'; Reason = '运行证据根不得自动清理。'; Manual = $true },
        @{ Relative = 'account_backup\_autosave'; Reason = '账号自动快照是回滚边界，仅人工审查。'; Manual = $true }
        @{ Relative = 'account_backup\windows\login_runtime\plugins'; Reason = 'login runtime 插件目录邻近账号运行时，仅人工审查。'; Manual = $true },
        @{ Relative = 'account_backup\windows\login_runtime\.tmp\plugins'; Reason = 'login runtime 中间态不得自动 prune。'; Manual = $true },
        @{ Relative = 'account_backup\windows\refresh_runtime\plugins'; Reason = 'refresh runtime 共享插件目录，仅人工审查。'; Manual = $true },
        @{ Relative = 'account_backup\windows\refresh_runtime\.tmp'; Reason = 'refresh runtime 中间态不得自动 prune。'; Manual = $true },
        @{ Relative = 'skills-backups'; Reason = '旧 skill 备份可能仍是回滚边界，仅人工审查。'; Manual = $true },
        @{ Relative = '.backups'; Reason = '旧本地备份用途不明，仅人工审查。'; Manual = $true },
        @{ Relative = '.tmp\bundled-marketplaces'; Reason = '全局 marketplace staging 可能在使用中，仅人工审查。'; Manual = $true }
    )
    $items = [Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $path = Join-Path $PolicyContext.CodexRoot $definition.Relative
        $stats = Get-BackupRetentionSafeStats -Path $path
        $risk = if ($definition.Manual) { '高' } else { '低' }
        $items.Add((New-BackupRetentionCoverageItem -Path $path -ScanRoot $null -ItemType 'policy-path' -Disposition 'protected' -Reason $definition.Reason -Manual $definition.Manual -Blocks $false -Risk $risk -Stats $stats -CoverageOrigin 'policy-guardrail'))
    }
    $legacy = Join-Path $PolicyContext.DDriveRoot '.codex-c-backups'
    $items.Add((New-BackupRetentionCoverageItem -Path $legacy -ScanRoot $null -ItemType 'policy-path' -Disposition 'protected' -Reason '历史迁移备份可能有审计价值，仅人工审查。' -Manual $true -Blocks $false -Risk '高' -Stats (Get-BackupRetentionSafeStats $legacy) -CoverageOrigin 'policy-guardrail'))
    return [object[]]$items.ToArray()
}

function Invoke-BackupRetentionEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$PolicyContext)

    foreach ($required in @('artifactMode', 'CodexRoot', 'DDriveRoot', 'retainCount', 'policyId', 'policyVersion')) {
        if ($PolicyContext.PSObject.Properties.Name -notcontains $required) { throw "PolicyContext 缺少必需字段：$required" }
    }
    if ([string]$PolicyContext.policyId -cne 'env-governance.backup-retention' -or [int]$PolicyContext.policyVersion -ne 2) {
        throw 'PolicyContext policyId/policyVersion 不受信任。'
    }
    $PolicyContext = New-BackupRetentionPolicyContext -ArtifactMode ([string]$PolicyContext.artifactMode) -CodexRoot ([string]$PolicyContext.CodexRoot) -DDriveRoot ([string]$PolicyContext.DDriveRoot) -RetainCount ([int]$PolicyContext.retainCount)

    $declared = @(Get-BackupRetentionDeclaredScanRoots -PolicyContext $PolicyContext)
    $evaluated = @($declared | ForEach-Object { Get-BackupRetentionRootSnapshot -DeclaredScanRoot $_ })
    $items = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.List[object]]::new()

    foreach ($root in $evaluated) {
        if (-not $root.enumerationCompleted -or @($root.errors).Count -gt 0) {
            $rootReason = if ($root.rootIsReparsePoint) { '声明扫描根是 reparse point，覆盖失败关闭。' } else { '声明扫描根枚举未完成，覆盖失败关闭。' }
            $items.Add((New-BackupRetentionCoverageItem -Path $root.path -ScanRoot $null -ItemType 'scan-root' -Disposition 'gap' -Reason $rootReason -Manual $true -Blocks $true -Risk '高' -IsReparsePoint ([bool]$root.rootIsReparsePoint) -CoverageOrigin 'scan-root-error'))
        }
        foreach ($child in @($root.directChildren)) {
            if ($child.isReparsePoint) {
                $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '直接子项是 reparse point，不能进入保留规则。' -Manual $true -Blocks $true -Risk '高' -IsReparsePoint $true -ReparseTarget $child.reparseTarget))
                continue
            }

            if ($root.rule -ceq 'backups-state-root') {
                if ($child.name -ceq 'provider-sync' -and $child.itemType -ceq 'directory') {
                    $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'delegated-root' -Reason '由更窄的 provider-sync 扫描根负责分类。' -Manual $false -Blocks $false -DelegatedScanRoot $child.path))
                    continue
                }
                $backupType = if ($child.name -like 'config.toml*') { 'config.toml-sidecar' } elseif ($child.name -like '.codex-global-state.json*') { 'global-state-sidecar' } else { $null }
                if ($null -eq $backupType) {
                    $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '未知 backups_state 直接子项。' -Manual $true -Blocks $true -Risk '中'))
                    continue
                }
                $timestamp = Get-BackupRetentionStrictTimestamp -Name $child.name
                if (-not $timestamp.ok) {
                    $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '无法严格解析侧车备份时间戳。' -Manual $true -Blocks $true -Risk '中' -GroupKey ".codex/backups_state/root-sidecars::$backupType" -BackupType $backupType))
                    continue
                }
                $pending.Add([pscustomobject]@{ child = $child; root = $root; timestamp = $timestamp; bucket = '按组保留最近 5 个'; groupKey = ".codex/backups_state/root-sidecars::$backupType"; projectRoot = '.codex/backups_state/root-sidecars'; backupType = $backupType; risk = '低'; reason = '侧车备份按类型保留。' })
                continue
            }

            if ($child.itemType -cne 'directory') {
                $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '保留规则扫描根中出现未分类文件。' -Manual $true -Blocks $true -Risk '中'))
                continue
            }

            $timestamp = Get-BackupRetentionStrictTimestamp -Name $child.name
            $backupType = $null; $projectRoot = ''; $bucket = '按组保留最近 5 个'; $risk = '低'; $reason = ''
            switch ($root.rule) {
                'provider-sync' {
                    if ($child.name -match '^20\d{6}T\d{6}(?:\d{3,7})?Z?$') { $backupType = 'provider-sync' }
                    $projectRoot = '.codex/backups_state/provider-sync'; $reason = 'provider-sync 状态备份按固定数量保留。'
                }
                'replicator' {
                    $phase = [regex]::Match($child.name, '^(phase\d+)')
                    if ($phase.Success) { $backupType = $phase.Groups[1].Value } elseif ($child.name -like 'review-*') { $backupType = 'review' }
                    $projectRoot = $root.rootId; $risk = '中'; $reason = 'replicator 备份超过保留数。'
                }
                'codex-switch' {
                    $backupType = 'codex-switch-installed-binary'; $projectRoot = 'apps/codex_switch/backups'; $risk = '中'; $bucket = 'codex_switch 安装回滚备份'; $reason = 'codex_switch 安装版回滚备份超过保留数。'
                    if (-not (Test-Path -LiteralPath (Join-Path $child.path 'codex_switch.exe') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $child.path 'WebView2Loader.dll') -PathType Leaf)) { $backupType = $null }
                }
            }
            if ([string]::IsNullOrWhiteSpace($backupType) -or -not $timestamp.ok) {
                $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '目录不符合严格备份类型、时间戳或完整性规则。' -Manual $true -Blocks $true -Risk '中'))
                continue
            }
            $pending.Add([pscustomobject]@{ child = $child; root = $root; timestamp = $timestamp; bucket = $bucket; groupKey = "$projectRoot::$backupType"; projectRoot = $projectRoot; backupType = $backupType; risk = $risk; reason = $reason })
        }
    }

    foreach ($group in @($pending.ToArray() | Group-Object groupKey)) {
        $ordered = @($group.Group | Sort-Object @{ Expression = { $_.timestamp.timestampUtc }; Descending = $true }, @{ Expression = { $_.child.name }; Descending = $true })
        for ($index = 0; $index -lt $ordered.Count; $index++) {
            $record = $ordered[$index]
            $rank = $index + 1
            $stats = Get-BackupRetentionSafeStats -Path $record.child.path
            if ($stats.reparsePointsSkipped -gt 0 -or $stats.inaccessibleItems -gt 0) {
                $items.Add((New-BackupRetentionCoverageItem -Path $record.child.path -ScanRoot $record.root.path -ItemType $record.child.itemType -Disposition 'gap' -Reason '目录内部存在 reparse point 或不可访问项。' -Manual $true -Blocks $true -Risk '高' -GroupKey $record.groupKey -ProjectRoot $record.projectRoot -BackupType $record.backupType -Timestamp $record.timestamp -RetainRank $rank -Stats $stats))
                continue
            }
            $disposition = if ($rank -le [int]$PolicyContext.retainCount) { 'retained' } else { 'candidate' }
            $items.Add((New-BackupRetentionCoverageItem -Path $record.child.path -ScanRoot $record.root.path -ItemType $record.child.itemType -Disposition $disposition -Reason $record.reason -Manual $false -Blocks $false -Bucket $record.bucket -GroupKey $record.groupKey -ProjectRoot $record.projectRoot -BackupType $record.backupType -Timestamp $record.timestamp -RetainRank $rank -Risk $record.risk -Stats $stats))
        }
    }

    foreach ($guardrail in @(Get-BackupRetentionGuardrailItems -PolicyContext $PolicyContext)) { $items.Add($guardrail) }
    $coverageItems = @($items.ToArray() | Sort-Object @{ Expression = { if ($null -eq $_.scanRoot) { '~' } else { $_.scanRoot } } }, path)

    foreach ($root in $evaluated) {
        $rootItems = @($coverageItems | Where-Object { $null -ne $_.scanRoot -and $_.scanRoot -ieq $root.path })
        $root.classificationCount = $rootItems.Count
        $counts = [ordered]@{ candidate = 0; retained = 0; protected = 0; 'delegated-root' = 0; gap = 0 }
        foreach ($item in $rootItems) { $counts[$item.coverageDisposition] = [int]$counts[$item.coverageDisposition] + 1 }
        $root.classificationCounts = [pscustomobject]$counts
    }

    $accounted = $true
    foreach ($root in $evaluated) {
        $snapshotPaths = @($root.directChildren | ForEach-Object { $_.path.ToLowerInvariant() } | Sort-Object)
        $ledgerPaths = @($coverageItems | Where-Object { $null -ne $_.scanRoot -and $_.scanRoot -ieq $root.path } | ForEach-Object { $_.path.ToLowerInvariant() } | Sort-Object)
        if ($snapshotPaths.Count -ne $ledgerPaths.Count -or (Compare-Object -ReferenceObject $snapshotPaths -DifferenceObject $ledgerPaths).Count -gt 0 -or @($ledgerPaths | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
            $accounted = $false
            break
        }
    }
    $graph = Test-BackupRetentionDelegationGraph -DeclaredScanRoots $evaluated -CoverageItems $coverageItems
    $blocked = @($coverageItems | Where-Object blocksCoverage).Count -gt 0
    $rootFailure = @($evaluated | Where-Object { -not $_.enumerationCompleted -or @($_.errors).Count -gt 0 }).Count -gt 0
    $complete = $accounted -and $graph.valid -and -not $blocked -and -not $rootFailure

    $candidates = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'candidate' })
    $retained = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'retained' })
    $protected = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'protected' })
    $manual = @($coverageItems | Where-Object requiresManualReview)
    $gaps = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'gap' } | ForEach-Object { [pscustomobject]@{ path = $_.path; scanRoot = $_.scanRoot; reason = $_.reason } })
    $errors = @($evaluated | ForEach-Object { $_.errors } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) + @($graph.errors)

    return [pscustomobject][ordered]@{
        declaredScanRoots = [object[]]$declared
        evaluatedRoots = [object[]]$evaluated
        coverageItems = [object[]]$coverageItems
        candidates = [object[]]$candidates
        retainedItems = [object[]]$retained
        protected = [object[]]$protected
        manualReview = [object[]]$manual
        unclassifiedCoverageGaps = [object[]]$gaps
        coverageAccounted = $accounted
        coverageComplete = $complete
        coverageNotes = @('覆盖证明仅适用于显式 declaredScanRoots，不声称扫描全盘。', '每个成功枚举的直接子项恰好分类一次。')
        errors = [object[]]$errors
        delegationGraph = $graph
    }
}
