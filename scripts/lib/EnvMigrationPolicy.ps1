function Test-EnvMigrationInteger {
    param([AllowNull()][object]$Value)

    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Assert-EnvFactObject {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$FactName
    )

    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$FactName 必须是 JSON object。"
    }
}

function Assert-EnvFactPropertySet {
    param(
        [Parameter(Mandatory)][psobject]$Value,
        [Parameter(Mandatory)][string[]]$ExpectedProperties,
        [Parameter(Mandatory)][string]$FactName
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($ExpectedProperties | Sort-Object)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw "$FactName 字段结构无效。Expected=$($expected -join ','); Actual=$($actual -join ',')"
    }
}

function Assert-EnvNonEmptyStringProperty {
    param(
        [Parameter(Mandatory)][psobject]$Value,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][string]$FactName,
        [switch]$AllowNull
    )

    $propertyValue = $Value.$PropertyName
    if ($AllowNull -and $null -eq $propertyValue) {
        return
    }
    if ($propertyValue -isnot [string] -or [string]::IsNullOrWhiteSpace($propertyValue)) {
        throw "$FactName.$PropertyName 必须是非空字符串。"
    }
}

function Assert-EnvAbsolutePathValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FactName
    )

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$FactName 必须是绝对路径：$Path"
    }
    try {
        [void][IO.Path]::GetFullPath($Path)
    } catch {
        throw "$FactName 不是有效绝对路径：$Path"
    }
}

function Get-EnvCanonicalExcludedRoots {
    @(
        [pscustomobject][ordered]@{ path = "C:\Windows"; reason = "系统目录，绝不自动迁移" }
        [pscustomobject][ordered]@{ path = "C:\Program Files"; reason = "MSI/系统级安装目录，绝不直接搬迁" }
        [pscustomobject][ordered]@{ path = "C:\Program Files (x86)"; reason = "MSI/系统级安装目录，绝不直接搬迁" }
        [pscustomobject][ordered]@{ path = "C:\ProgramData"; reason = "服务和机器级状态常驻位置，仅按官方迁移流程处理" }
        [pscustomobject][ordered]@{ path = "C:\Users"; reason = "不批量迁移用户目录或 AppData" }
    )
}

function Get-EnvExcludedRootFacts {
    foreach ($rule in @(Get-EnvCanonicalExcludedRoots)) {
        [pscustomobject][ordered]@{ path = $rule.path }
    }
}

function Test-EnvMigrationSubPath {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-EnvRootPolicyDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Candidate)

    foreach ($root in @(Get-EnvCanonicalExcludedRoots)) {
        if (-not (Test-EnvMigrationSubPath -Path $Candidate.source -Root $root.path)) {
            continue
        }

        if ($root.path -ieq "C:\Users" -and $Candidate.kind -eq "cache") {
            return [pscustomobject]@{
                matchedExcludedRoot = $root.path
                excludedRootReason = $root.reason
                allowDryRunPlan = $true
                executionAllowed = $false
                requiresExplicitUserApproval = $true
                decision = "targeted-cache-under-excluded-user-root"
                note = "来源位于不批量迁移的用户根目录下；仅允许生成具体缓存子目录 dry-run 计划，真实执行必须另行显式授权。"
            }
        }

        return [pscustomobject]@{
            matchedExcludedRoot = $root.path
            excludedRootReason = $root.reason
            allowDryRunPlan = $false
            executionAllowed = $false
            requiresExplicitUserApproval = $true
            decision = "blocked-by-excluded-root"
            note = "来源命中绝不自动迁移根，不能进入迁移执行计划。"
        }
    }

    return [pscustomobject]@{
        matchedExcludedRoot = $null
        excludedRootReason = $null
        allowDryRunPlan = $true
        executionAllowed = $false
        requiresExplicitUserApproval = $true
        decision = "dry-run-candidate"
        note = "dry-run 计划仅供审查；真实执行必须另行显式授权。"
    }
}

function Test-EnvCanonicalPipCacheConfigured {
    param([object[]]$Directories)

    $canonicalPath = [IO.Path]::GetFullPath("D:\Codex\.cache\pip").TrimEnd("\", "/")
    foreach ($directory in @($Directories)) {
        if ($null -eq $directory -or $directory.name -ne "pip cache env" -or [string]::IsNullOrWhiteSpace($directory.path)) {
            continue
        }

        try {
            $configuredPath = [IO.Path]::GetFullPath([string]$directory.path).TrimEnd("\", "/")
            if ($configuredPath.Equals($canonicalPath, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch {
            continue
        }
    }

    return $false
}

function Assert-EnvMigrationDirectoryFacts {
    param([AllowEmptyCollection()][object[]]$Directories)

    foreach ($directory in @($Directories)) {
        Assert-EnvFactObject -Value $directory -FactName "Directory fact"
        $expectedProperties = @(
            "name", "path", "category", "owner", "exists", "drive",
            "isReparsePoint", "reparseTarget", "sizeBytes", "notes"
        )
        Assert-EnvFactPropertySet -Value $directory -ExpectedProperties $expectedProperties -FactName "Directory fact"
        foreach ($name in @("name", "path", "category", "owner", "drive", "notes")) {
            Assert-EnvNonEmptyStringProperty -Value $directory -PropertyName $name -FactName "Directory fact"
        }
        Assert-EnvAbsolutePathValue -Path $directory.path -FactName "Directory fact.path"
        $expectedDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($directory.path))
        if (-not $directory.drive.Equals($expectedDrive, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Directory fact.drive 与 path 根不一致：$($directory.path)"
        }
        if ($directory.category -notin @("d-target", "cache", "tool-env", "manual-only")) {
            throw "Directory fact.category 枚举无效：$($directory.category)"
        }
        foreach ($name in @("exists", "isReparsePoint")) {
            if ($directory.$name -isnot [bool]) {
                throw "Directory fact 字段必须是 boolean：$name"
            }
        }
        if ($null -ne $directory.sizeBytes -and
            (-not (Test-EnvMigrationInteger -Value $directory.sizeBytes) -or [int64]$directory.sizeBytes -lt 0)) {
            throw "Directory fact.sizeBytes 必须是 null 或非负整数。"
        }
        if ($null -ne $directory.reparseTarget) {
            if ($directory.reparseTarget -is [string]) {
                if ([string]::IsNullOrWhiteSpace($directory.reparseTarget)) {
                    throw "Directory fact.reparseTarget 字符串不能为空。"
                }
            } elseif ($directory.reparseTarget -is [array]) {
                foreach ($target in $directory.reparseTarget) {
                    if ($target -isnot [string] -or [string]::IsNullOrWhiteSpace($target)) {
                        throw "Directory fact.reparseTarget 数组只能包含非空字符串。"
                    }
                }
            } else {
                throw "Directory fact.reparseTarget 必须是 null、字符串或字符串数组。"
            }
        }
    }
}

function Assert-EnvLocalEnvironmentFindingFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalEnvironmentFindings,
        [switch]$AllowLegacyReviewFlag
    )

    $classificationPolicies = @{
        "project-root-local-env" = @{ scope = "project-root"; owner = "project" }
        "nested-app-local-env" = @{ scope = "nested-app"; owner = "project" }
        "archived-project-cache" = @{ scope = "archive-cache"; owner = "archive" }
        "plugin-cache-backup" = @{ scope = "backup-cache"; owner = "backup" }
        "plugin-runtime-cache" = @{ scope = "plugin-runtime-cache"; owner = "plugin-runtime" }
    }
    $baseProperties = @(
        "project", "parentProject", "marker", "path", "drive", "sizeBytes",
        "classification", "scope", "owner"
    )

    foreach ($finding in @($LocalEnvironmentFindings)) {
        Assert-EnvFactObject -Value $finding -FactName "LocalEnvironmentFinding fact"
        $expectedProperties = @($baseProperties)
        if ($AllowLegacyReviewFlag -and $finding.PSObject.Properties.Name -contains "includeInReviewPack") {
            $expectedProperties += "includeInReviewPack"
        }
        Assert-EnvFactPropertySet -Value $finding -ExpectedProperties $expectedProperties -FactName "LocalEnvironmentFinding fact"
        foreach ($name in @("project", "marker", "path", "drive", "classification", "scope", "owner")) {
            Assert-EnvNonEmptyStringProperty -Value $finding -PropertyName $name -FactName "LocalEnvironmentFinding fact"
        }
        Assert-EnvNonEmptyStringProperty -Value $finding -PropertyName "parentProject" -FactName "LocalEnvironmentFinding fact" -AllowNull
        Assert-EnvAbsolutePathValue -Path $finding.project -FactName "LocalEnvironmentFinding fact.project"
        Assert-EnvAbsolutePathValue -Path $finding.path -FactName "LocalEnvironmentFinding fact.path"
        if ($null -ne $finding.parentProject) {
            Assert-EnvAbsolutePathValue -Path $finding.parentProject -FactName "LocalEnvironmentFinding fact.parentProject"
        }
        $expectedDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($finding.path))
        if (-not $finding.drive.Equals($expectedDrive, [StringComparison]::OrdinalIgnoreCase)) {
            throw "LocalEnvironmentFinding fact.drive 与 path 根不一致：$($finding.path)"
        }
        if ($finding.marker -notin @(".venv", "venv", "node_modules", ".conda")) {
            throw "LocalEnvironmentFinding fact.marker 枚举无效：$($finding.marker)"
        }
        if (-not $classificationPolicies.ContainsKey($finding.classification)) {
            throw "LocalEnvironmentFinding fact.classification 枚举无效：$($finding.classification)"
        }
        $policy = $classificationPolicies[$finding.classification]
        if ($finding.scope -cne $policy.scope -or $finding.owner -cne $policy.owner) {
            throw "LocalEnvironmentFinding fact classification/scope/owner 不一致：$($finding.classification)"
        }
        if ($null -ne $finding.sizeBytes -and
            (-not (Test-EnvMigrationInteger -Value $finding.sizeBytes) -or [int64]$finding.sizeBytes -lt 0)) {
            throw "LocalEnvironmentFinding fact.sizeBytes 必须是 null 或非负整数。"
        }
        if ($finding.PSObject.Properties.Name -contains "includeInReviewPack" -and $finding.includeInReviewPack -isnot [bool]) {
            throw "Legacy includeInReviewPack 必须是 boolean。"
        }
    }
}

function Test-EnvLocalEnvironmentFindingReviewEligible {
    param([Parameter(Mandatory)][psobject]$Finding)

    return $Finding.owner -ceq "project" -and
        $Finding.classification -in @("project-root-local-env", "nested-app-local-env")
}

function Assert-EnvExcludedRootFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExcludedRoots)

    $actualKeys = @()
    foreach ($root in @($ExcludedRoots)) {
        Assert-EnvFactObject -Value $root -FactName "ExcludedRoot fact"
        Assert-EnvFactPropertySet -Value $root -ExpectedProperties @("path") -FactName "ExcludedRoot fact"
        Assert-EnvNonEmptyStringProperty -Value $root -PropertyName "path" -FactName "ExcludedRoot fact"
        Assert-EnvAbsolutePathValue -Path $root.path -FactName "ExcludedRoot fact.path"
        $actualKeys += [IO.Path]::GetFullPath($root.path).TrimEnd('\', '/').ToLowerInvariant()
    }

    if (@($actualKeys | Sort-Object -Unique).Count -ne $actualKeys.Count) {
        throw "ExcludedRoot facts 包含重复 canonical path。"
    }
    $expectedKeys = @(
        Get-EnvExcludedRootFacts | ForEach-Object {
            [IO.Path]::GetFullPath($_.path).TrimEnd('\', '/').ToLowerInvariant()
        }
    )
    if ((@($actualKeys | Sort-Object) -join "`n") -cne (@($expectedKeys | Sort-Object) -join "`n")) {
        throw "ExcludedRoot facts 必须与 canonical root 集合完全一致。"
    }
}

function Assert-EnvMigrationInventoryFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Inventory)

    if ($Inventory -isnot [pscustomobject]) {
        throw "Inventory 必须是 JSON object。"
    }
    if (-not ($Inventory.PSObject.Properties.Name -contains "artifactType") -or
        $Inventory.artifactType -isnot [string] -or
        $Inventory.artifactType -cne "env-governance.inventory") {
        throw "Inventory artifactType 必须为 env-governance.inventory。"
    }
    if (-not ($Inventory.PSObject.Properties.Name -contains "schemaVersion") -or
        -not (Test-EnvMigrationInteger -Value $Inventory.schemaVersion) -or
        $Inventory.schemaVersion -ne 3) {
        throw "Inventory schemaVersion 必须是整数 3。"
    }
    foreach ($name in @("generatedAt", "directories", "excludedRoots", "localEnvironmentFindings")) {
        if (-not ($Inventory.PSObject.Properties.Name -contains $name)) {
            throw "Inventory 缺少迁移计划所需事实字段：$name"
        }
    }
    if ($Inventory.generatedAt -isnot [string] -or [string]::IsNullOrWhiteSpace($Inventory.generatedAt)) {
        throw "Inventory generatedAt 必须是非空字符串。"
    }
    foreach ($name in @("directories", "excludedRoots", "localEnvironmentFindings")) {
        if ($Inventory.$name -isnot [array]) {
            throw "Inventory 事实字段必须是数组：$name"
        }
    }
    foreach ($policyProperty in @("migrationCandidates", "manualReviewItems", "projectEnvironmentMarkers")) {
        if ($Inventory.PSObject.Properties.Name -contains $policyProperty) {
            throw "Inventory 不得包含策略投影：$policyProperty"
        }
    }

    Assert-EnvMigrationDirectoryFacts -Directories @($Inventory.directories)
    Assert-EnvExcludedRootFacts -ExcludedRoots @($Inventory.excludedRoots)
    Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings @($Inventory.localEnvironmentFindings)
}

function Get-EnvMigrationCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Directories
    )

    Assert-EnvMigrationDirectoryFacts -Directories $Directories
    $canonicalPipCacheConfigured = Test-EnvCanonicalPipCacheConfigured -Directories $Directories
    foreach ($directory in @($Directories)) {
        if (-not $directory.exists -or $directory.isReparsePoint -or $directory.category -eq "manual-only") {
            continue
        }

        if ($canonicalPipCacheConfigured -and $directory.name -eq "pip cache default") {
            continue
        }

        if ($directory.drive -notlike "C:\*") {
            continue
        }

        $risk = "medium"
        $action = "需要人工确认"
        if ($directory.category -eq "cache") {
            $risk = "low"
            $action = "可考虑迁移到 D:\Codex\.cache"
        } elseif ($directory.category -eq "tool-env") {
            $action = "可考虑迁移到 D:\Codex\tools 或 D:\Codex\envs，但需按工具官方方式切换"
        }

        [pscustomobject]@{
            source = $directory.path
            kind = $directory.category
            owner = $directory.owner
            risk = $risk
            action = $action
            reason = $directory.notes
        }
    }
}

function Get-EnvLocalEnvironmentReviewReason {
    param([string]$Classification)

    switch ($Classification) {
        "project-root-local-env" { return "项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。" }
        "nested-app-local-env" { return "嵌套 app 的项目本地依赖环境，需按所在 app 的锁文件、验证命令和 owner 决策单独处理。" }
        "archived-project-cache" { return "项目文档或历史归档中的依赖缓存副本，不属于当前项目依赖重建。" }
        "plugin-cache-backup" { return "repair backup 内的插件缓存副本，不属于项目依赖重建；只能走备份保留或清理治理。" }
        "plugin-runtime-cache" { return "插件 runtime/cache 内的依赖目录，不属于项目本地依赖重建；可能由插件安装或运行时管理。" }
        default { return "本地环境目录可能绑定解释器、绝对路径、构建产物或运行状态，需人工确认归属和处理方式。" }
    }
}

function Get-EnvManualReviewItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Directories,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalEnvironmentFindings
    )

    Assert-EnvMigrationDirectoryFacts -Directories $Directories
    Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings $LocalEnvironmentFindings
    foreach ($directory in @($Directories)) {
        if (-not $directory.exists) {
            continue
        }

        if ($directory.isReparsePoint) {
            [pscustomobject]@{
                source = $directory.path
                kind = $directory.category
                owner = $directory.owner
                risk = "high"
                action = "不自动迁移"
                reason = "该目录是 reparse point/junction/symlink，需先确认目标和循环风险。"
            }
        } elseif ($directory.category -eq "manual-only") {
            [pscustomobject]@{
                source = $directory.path
                kind = $directory.category
                owner = $directory.owner
                risk = "high"
                action = "仅人工处理"
                reason = $directory.notes
            }
        }
    }

    foreach ($finding in @($LocalEnvironmentFindings)) {
        [pscustomobject]@{
            source = $finding.path
            kind = $finding.classification
            owner = $finding.owner
            risk = "high"
            action = "不自动迁移"
            reason = Get-EnvLocalEnvironmentReviewReason -Classification $finding.classification
        }
    }
}
