. (Join-Path $PSScriptRoot "EnvPathSafety.ps1")

function Test-EnvMigrationInteger {
    param([AllowNull()][object]$Value)

    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Get-EnvRebuildEvidenceFileNames {
    @(
        "pyproject.toml", "uv.lock", "requirements.txt", "requirements-dev.txt",
        "Pipfile.lock", "poetry.lock", "environment.yml", "package.json",
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "README.md", "AGENTS.md"
    )
}

function Test-EnvProjectLongRunningOrStateful {
    param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Marker)
    $normalized = $Project.ToLowerInvariant()
    if ($normalized.Contains("\.gsd\projects\")) { return $true }
    foreach ($token in @("bot", "qqbot", "agent", "service", "daemon", "worker", "hermes")) {
        if ($normalized.Contains($token)) { return $true }
    }
    return $Marker -ceq ".venv" -and $normalized.Contains("direct")
}

function Get-EnvProjectReviewRebuildAssessment {
    param([Parameter(Mandatory)][string]$Marker, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files)
    if ($Marker -ceq "node_modules") {
        if ($Files -ccontains "package-lock.json") { return "可重建：发现 package-lock.json；可在独立 issue 中用 npm ci 重建并运行项目测试。" }
        if ($Files -ccontains "pnpm-lock.yaml") { return "可重建：发现 pnpm-lock.yaml；可在独立 issue 中用 pnpm install --frozen-lockfile 重建并运行项目测试。" }
        if ($Files -ccontains "yarn.lock") { return "可重建：发现 yarn.lock；可在独立 issue 中用 yarn install --frozen-lockfile 重建并运行项目测试。" }
        if ($Files -ccontains "package.json") { return "需项目 owner 决策：只有 package.json，缺少锁文件，不能自动重建。" }
    }
    if ($Marker -in @(".venv", "venv")) {
        if ($Files -ccontains "uv.lock") { return "可重建：发现 uv.lock；可在独立 issue 中按项目文档重建虚拟环境并运行测试。" }
        if ($Files -ccontains "requirements.txt") { return "可重建：发现 requirements.txt；可在独立 issue 中重建虚拟环境并运行项目测试。" }
        if ($Files -ccontains "pyproject.toml") { return "可能可重建：发现 pyproject.toml；需确认锁文件、Python 版本和项目测试命令。" }
    }
    if ($Marker -ceq ".conda" -and $Files -ccontains "environment.yml") { return "可重建：发现 environment.yml；需用项目级 Conda 流程单独验证。" }
    return "需项目 owner 决策：缺少足够的锁文件或重建说明，不能自动处理。"
}

function Get-EnvProjectReviewRecommendedAction {
    param([Parameter(Mandatory)][bool]$IsLongRunningOrStateful, [Parameter(Mandatory)][string]$RebuildAssessment)
    if ($IsLongRunningOrStateful) { return "保留；需项目 owner 决策；真实重建前必须确认服务停启、状态恢复和项目级验证。" }
    if ($RebuildAssessment.StartsWith("可重建", [StringComparison]::Ordinal)) { return "默认保留；可单独开重建 issue，但不得在本项目中自动迁移或合并。" }
    return "保留；需项目 owner 决策；禁止自动处理。"
}

function Get-EnvProjectReviewVerificationPrerequisites {
    param([Parameter(Mandatory)][string]$Marker, [Parameter(Mandatory)][bool]$IsLongRunningOrStateful, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files)
    $items = @("读取项目 README/AGENTS 或等效项目说明。", "确认项目自己的依赖安装命令、锁文件和测试命令。", "确认当前环境不是正在运行的服务或恢复链路的一部分。", "先在项目内生成独立 dry-run 或重建计划，不跨项目复用该目录。")
    if ($Marker -ceq "node_modules") { $items += "确认 package manager 与锁文件一致，例如 npm/package-lock、pnpm/pnpm-lock 或 yarn/yarn.lock。" }
    if ($Marker -in @(".venv", "venv", ".conda")) { $items += "确认 Python/Conda 版本、解释器路径、原环境变量和项目测试命令。" }
    if ($IsLongRunningOrStateful) { $items += "长期服务或状态敏感项目必须先确认停机窗口、启动命令、健康检查、回滚步骤和 owner 决策。" }
    if ($Files.Count -eq 0) { $items += "缺少项目配置线索时，必须先由项目 owner 补充重建说明。" }
    return [object[]]$items
}

function Assert-ProjectLocalReviewDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Review)
    Assert-EnvFactObject -Value $Review -FactName "Review"
    if ($Review.artifactType -isnot [string] -or $Review.artifactType -cne "env-governance.project-local-env-review") { throw "Review artifactType 不正确。" }
    if (-not (Test-EnvMigrationInteger $Review.schemaVersion) -or $Review.schemaVersion -ne 2) { throw "Review schemaVersion 必须是原生整数 2。" }
    foreach ($name in @("generationId", "generatedAt", "inventoryPath", "inventoryGeneratedAt")) {
        if (-not ($Review.PSObject.Properties.Name -contains $name) -or $Review.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Review.$name)) { throw "Review $name 必须是非空字符串。" }
    }
    if ($Review.generationId -notmatch '^[0-9a-f-]{36}$') { throw "Review generationId 非法。" }
    if ($Review.readOnly -isnot [bool] -or -not $Review.readOnly) { throw "Review readOnly 必须是 true boolean。" }
    if ($Review.items -isnot [array]) { throw "Review items 必须是数组。" }
    $allowedFiles = @(Get-EnvRebuildEvidenceFileNames)
    foreach ($item in @($Review.items)) {
        Assert-EnvFactObject -Value $item -FactName "Review item"
        foreach ($name in @("project", "parentProject", "marker", "path", "classification", "scope", "riskLevel", "recommendedAction", "rebuildAssessment", "futureIssueRecommendation", "reason")) {
            Assert-EnvNonEmptyStringProperty -Value $item -PropertyName $name -FactName "Review item"
        }
        foreach ($pathName in @("project", "parentProject", "path")) { Assert-EnvAbsolutePathValue -Path $item.$pathName -FactName "Review item.$pathName" }
        if ($item.marker -notin @(".venv", "venv", "node_modules", ".conda")) { throw "Review item.marker 枚举无效。" }
        $project = [IO.Path]::GetFullPath($item.project).TrimEnd('\', '/'); $parent = [IO.Path]::GetFullPath($item.parentProject).TrimEnd('\', '/'); $path = [IO.Path]::GetFullPath($item.path).TrimEnd('\', '/')
        if (-not (Test-EnvMigrationSubPath -Path $project -Root $parent)) { throw "Review item.project 必须等于或位于 parentProject 下。" }
        $expectedPath = [IO.Path]::GetFullPath((Join-Path $project $item.marker)).TrimEnd('\', '/')
        if (-not $path.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) { throw "Review item.path 必须是 project 下的 marker 直接子目录。" }
        $decision = Get-EnvLocalEnvironmentClassification -Path $path -Project $project -ParentProject $parent
        if ($decision.owner -cne "project" -or $item.classification -cne $decision.classification -or $item.scope -cne $decision.scope) { throw "Review item classification/scope 与路径事实不一致。" }
        foreach ($boolName in @("automationAllowed", "isLongRunningOrStateful", "requiresOwnerDecision")) { if ($item.$boolName -isnot [bool]) { throw "Review item.$boolName 必须是 boolean。" } }
        if ($item.automationAllowed) { throw "Review item.automationAllowed 必须为 false。" }
        $expectedLongRunning = Test-EnvProjectLongRunningOrStateful -Project $project -Marker $item.marker
        if ($item.isLongRunningOrStateful -ne $expectedLongRunning) { throw "Review item.isLongRunningOrStateful 与项目事实不一致。" }
        $expectedRisk = if ($expectedLongRunning) { "high" } else { "medium" }
        if ($item.riskLevel -cne $expectedRisk) { throw "Review item.riskLevel 必须与状态敏感性一致。" }
        Assert-EnvFactObject -Value $item.rebuildEvidence -FactName "Review item.rebuildEvidence"
        if ($item.rebuildEvidence.marker -isnot [string] -or $item.rebuildEvidence.marker -cne $item.marker -or $item.rebuildEvidence.projectFiles -isnot [array] -or $item.existingProjectFiles -isnot [array]) { throw "Review item.rebuildEvidence 合同非法。" }
        $files = @($item.rebuildEvidence.projectFiles)
        foreach ($file in $files) { if ($file -isnot [string] -or [string]::IsNullOrWhiteSpace($file) -or $file -cnotin $allowedFiles) { throw "Review item.rebuildEvidence 包含非法文件。" } }
        if (@($files | Sort-Object -Unique).Count -ne $files.Count -or (@($item.existingProjectFiles) -join "`n") -cne ($files -join "`n")) { throw "Review item rebuild evidence 数组不一致或重复。" }
        $assessment = Get-EnvProjectReviewRebuildAssessment -Marker $item.marker -Files $files
        $action = Get-EnvProjectReviewRecommendedAction -IsLongRunningOrStateful $expectedLongRunning -RebuildAssessment $assessment
        $requiresOwner = $action -like "*owner 决策*" -or $assessment -like "*owner 决策*"
        $future = if ($assessment.StartsWith("可重建", [StringComparison]::Ordinal)) { "可单独开项目级重建 issue。" } else { "先由项目 owner 补充重建和验证说明。" }
        if ($item.rebuildAssessment -cne $assessment -or $item.recommendedAction -cne $action -or $item.requiresOwnerDecision -ne $requiresOwner -or $item.futureIssueRecommendation -cne $future -or $item.reason -cne "项目本地环境可能绑定解释器、绝对路径、构建产物、平台依赖或服务状态。") { throw "Review item 派生策略字段与 canonical producer 规则不一致。" }
        if ($item.verificationPrerequisites -isnot [array]) { throw "Review item.verificationPrerequisites 必须是数组。" }
        $expectedPrerequisites = @(Get-EnvProjectReviewVerificationPrerequisites -Marker $item.marker -IsLongRunningOrStateful $expectedLongRunning -Files $files)
        foreach ($entry in @($item.verificationPrerequisites)) { if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) { throw "Review item.verificationPrerequisites 必须是非空字符串数组。" } }
        if ((@($item.verificationPrerequisites) -join "`n") -cne ($expectedPrerequisites -join "`n")) { throw "Review item.verificationPrerequisites 与 canonical producer 规则不一致。" }
    }
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

    Assert-EnvSafeAbsolutePath -Path $Path -FactName $FactName
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

function ConvertTo-EnvProjectRootFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRoots,
        [Parameter(Mandatory)][ValidateSet("collection", "project")][string]$Kind
    )

    foreach ($root in @($ProjectRoots)) {
        [pscustomobject][ordered]@{
            path = $root
            kind = $Kind
        }
    }
}

function Assert-EnvProjectRootFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRootFacts)

    $canonicalRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fact in @($ProjectRootFacts)) {
        Assert-EnvFactObject -Value $fact -FactName "ProjectRoot fact"
        Assert-EnvFactPropertySet -Value $fact -ExpectedProperties @("path", "kind") -FactName "ProjectRoot fact"
        Assert-EnvNonEmptyStringProperty -Value $fact -PropertyName "path" -FactName "ProjectRoot fact"
        Assert-EnvNonEmptyStringProperty -Value $fact -PropertyName "kind" -FactName "ProjectRoot fact"
        if ($fact.kind -cnotin @("collection", "project")) {
            throw "ProjectRoot fact.kind 必须是 collection 或 project。"
        }
        Assert-EnvAbsolutePathValue -Path $fact.path -FactName "ProjectRoot fact.path"
        $canonicalRoot = [IO.Path]::GetFullPath($fact.path).TrimEnd('\', '/')
        if (-not $canonicalRoots.Add($canonicalRoot)) {
            throw "ProjectRoot facts 包含重复 canonical path：$($fact.path)"
        }
    }
}

function Assert-EnvProjectRootCompatibility {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRoots,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRootFacts
    )

    Assert-EnvProjectRootFacts -ProjectRootFacts $ProjectRootFacts
    $compatibilityPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($ProjectRoots)) {
        if ($root -isnot [string] -or [string]::IsNullOrWhiteSpace($root)) {
            throw "projectRoots compatibility fact 必须是非空字符串。"
        }
        Assert-EnvAbsolutePathValue -Path $root -FactName "projectRoots compatibility fact"
        $canonicalRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        if (-not $compatibilityPaths.Add($canonicalRoot)) {
            throw "projectRoots compatibility facts 包含重复 canonical path：$root"
        }
    }
    $typedPaths = @($ProjectRootFacts | ForEach-Object { [IO.Path]::GetFullPath($_.path).TrimEnd('\', '/') } | Sort-Object)
    $compatPaths = @($compatibilityPaths | Sort-Object)
    if (($typedPaths -join "`n") -cne ($compatPaths -join "`n")) {
        throw "projectRoots 必须与 projectRootFacts path 集合完全一致。"
    }
}

function Get-EnvMostSpecificProjectRootFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRootFacts
    )

    Assert-EnvAbsolutePathValue -Path $Path -FactName "ProjectRoot match path"
    Assert-EnvProjectRootFacts -ProjectRootFacts $ProjectRootFacts
    $bestMatch = $null
    foreach ($fact in @($ProjectRootFacts)) {
        $canonicalRoot = [IO.Path]::GetFullPath($fact.path).TrimEnd('\', '/')
        if ((Test-EnvMigrationSubPath -Path $Path -Root $canonicalRoot) -and
            ($null -eq $bestMatch -or $canonicalRoot.Length -gt $bestMatch.path.Length)) {
            $bestMatch = [pscustomobject][ordered]@{ path = $canonicalRoot; kind = $fact.kind }
        }
    }
    return $bestMatch
}

function Get-EnvMostSpecificProjectRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRoots
    )

    $facts = @(ConvertTo-EnvProjectRootFacts -ProjectRoots $ProjectRoots -Kind "project")
    $match = Get-EnvMostSpecificProjectRootFact -Path $Path -ProjectRootFacts $facts
    if ($null -eq $match) {
        return $null
    }
    return $match.path
}

function Get-EnvTopProjectRootForMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRootFacts
    )

    $match = Get-EnvMostSpecificProjectRootFact -Path $Path -ProjectRootFacts $ProjectRootFacts
    if ($null -eq $match) {
        return $null
    }
    if ($match.kind -eq "project") {
        return $match.path
    }

    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $relative = [IO.Path]::GetRelativePath($match.path, $canonicalPath)
    $segments = @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -le 1) {
        return $match.path
    }
    return [IO.Path]::GetFullPath((Join-Path $match.path $segments[0])).TrimEnd('\', '/')
}

function Get-EnvLocalEnvironmentClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ParentProject
    )

    Assert-EnvAbsolutePathValue -Path $Path -FactName "Local environment classification path"
    Assert-EnvAbsolutePathValue -Path $Project -FactName "Local environment classification project"
    Assert-EnvAbsolutePathValue -Path $ParentProject -FactName "Local environment classification parentProject"
    foreach ($entry in @(
        @{ tokens = @('\docs\gsd-archive\', '\docs\archive\', '\docs\archived\'); classification = 'archived-project-cache'; scope = 'archive-cache'; owner = 'archive' },
        @{ tokens = @('\data\repair_backups\', '\repair_backups\'); classification = 'plugin-cache-backup'; scope = 'backup-cache'; owner = 'backup' },
        @{ tokens = @('\plugins\cache\'); classification = 'plugin-runtime-cache'; scope = 'plugin-runtime-cache'; owner = 'plugin-runtime' }
    )) {
        $normalizedPath = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
        if (@($entry.tokens | Where-Object { $normalizedPath.Contains($_) }).Count -gt 0) {
            return [pscustomobject][ordered]@{ classification = $entry.classification; scope = $entry.scope; owner = $entry.owner }
        }
    }
    $canonicalProject = [IO.Path]::GetFullPath($Project).TrimEnd('\', '/')
    $canonicalParent = [IO.Path]::GetFullPath($ParentProject).TrimEnd('\', '/')
    if ($canonicalProject.Equals($canonicalParent, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject][ordered]@{ classification = 'project-root-local-env'; scope = 'project-root'; owner = 'project' }
    }
    return [pscustomobject][ordered]@{ classification = 'nested-app-local-env'; scope = 'nested-app'; owner = 'project' }
}

function Test-EnvApprovedUserCachePath {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        return $false
    }

    $approvedPatterns = @(
        '^C:\\Users\\[^\\]+\\AppData\\Local\\pip\\Cache$',
        '^C:\\Users\\[^\\]+\\AppData\\Local\\npm-cache$',
        '^C:\\Users\\[^\\]+\\AppData\\Local\\pnpm\\store$',
        '^C:\\Users\\[^\\]+\\AppData\\Local\\pypoetry\\Cache$',
        '^C:\\Users\\[^\\]+\\AppData\\Local\\uv\\cache$',
        '^C:\\Users\\[^\\]+\\\.nuget\\packages$',
        '^C:\\Users\\[^\\]+\\\.m2\\repository$',
        '^C:\\Users\\[^\\]+\\\.gradle\\caches$'
    )
    foreach ($pattern in $approvedPatterns) {
        if ($canonicalPath -imatch $pattern) {
            return $true
        }
    }

    return $false
}

function Get-EnvRootPolicyDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Candidate)

    Assert-EnvFactObject -Value $Candidate -FactName "Migration candidate"
    foreach ($name in @("source", "kind")) {
        Assert-EnvNonEmptyStringProperty -Value $Candidate -PropertyName $name -FactName "Migration candidate"
    }
    Assert-EnvAbsolutePathValue -Path $Candidate.source -FactName "Migration candidate.source"

    foreach ($root in @(Get-EnvCanonicalExcludedRoots)) {
        if (-not (Test-EnvMigrationSubPath -Path $Candidate.source -Root $root.path)) {
            continue
        }

        if ($root.path -ieq "C:\Users" -and
            $Candidate.kind -eq "cache" -and
            (Test-EnvApprovedUserCachePath -Path $Candidate.source)) {
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

    $canonicalPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
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
        Assert-EnvAbsolutePathValue -Path $directory.drive -FactName "Directory fact.drive"
        $canonicalPath = [IO.Path]::GetFullPath($directory.path).TrimEnd('\', '/')
        if (-not $canonicalPaths.Add($canonicalPath)) {
            throw "Directory facts 包含重复 canonical path：$($directory.path)"
        }
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
                Assert-EnvSafeReparseTarget -Path $directory.reparseTarget -FactName "Directory fact.reparseTarget"
            } elseif ($directory.reparseTarget -is [array]) {
                foreach ($target in $directory.reparseTarget) {
                    if ($target -isnot [string] -or [string]::IsNullOrWhiteSpace($target)) {
                        throw "Directory fact.reparseTarget 数组只能包含非空字符串。"
                    }
                    Assert-EnvSafeReparseTarget -Path $target -FactName "Directory fact.reparseTarget"
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
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRootFacts,
        [switch]$AllowLegacyReviewFlag
    )

    $baseProperties = @(
        "project", "parentProject", "marker", "path", "drive", "sizeBytes",
        "classification", "scope", "owner", "rebuildEvidence"
    )
    $allowedProjectFiles = @(Get-EnvRebuildEvidenceFileNames)
    $canonicalPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Assert-EnvProjectRootFacts -ProjectRootFacts $ProjectRootFacts

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
        Assert-EnvAbsolutePathValue -Path $finding.drive -FactName "LocalEnvironmentFinding fact.drive"
        if ($null -eq $finding.parentProject) {
            throw "LocalEnvironmentFinding fact.parentProject 不能为空。"
        }
        Assert-EnvAbsolutePathValue -Path $finding.parentProject -FactName "LocalEnvironmentFinding fact.parentProject"
        $canonicalPath = [IO.Path]::GetFullPath($finding.path).TrimEnd('\', '/')
        if (-not $canonicalPaths.Add($canonicalPath)) {
            throw "LocalEnvironmentFinding facts 包含重复 canonical path：$($finding.path)"
        }
        $expectedDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($finding.path))
        if (-not $finding.drive.Equals($expectedDrive, [StringComparison]::OrdinalIgnoreCase)) {
            throw "LocalEnvironmentFinding fact.drive 与 path 根不一致：$($finding.path)"
        }
        if ($finding.marker -notin @(".venv", "venv", "node_modules", ".conda")) {
            throw "LocalEnvironmentFinding fact.marker 枚举无效：$($finding.marker)"
        }
        $canonicalProject = [IO.Path]::GetFullPath($finding.project).TrimEnd('\', '/')
        $canonicalParentProject = [IO.Path]::GetFullPath($finding.parentProject).TrimEnd('\', '/')
        $expectedParentProject = Get-EnvTopProjectRootForMarker -Path $canonicalPath -ProjectRootFacts $ProjectRootFacts
        if ($null -eq $expectedParentProject -or
            -not $canonicalParentProject.Equals($expectedParentProject, [StringComparison]::OrdinalIgnoreCase)) {
            throw "LocalEnvironmentFinding fact.parentProject 必须符合最具体 typed ProjectRoot 的 top-project 规则。"
        }
        $expectedPath = [IO.Path]::GetFullPath((Join-Path $canonicalProject $finding.marker)).TrimEnd('\', '/')
        if (-not $canonicalPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "LocalEnvironmentFinding fact.path 必须是 project 下的 marker 直接子目录。"
        }

        if (-not (Test-EnvMigrationSubPath -Path $canonicalProject -Root $canonicalParentProject)) {
            throw "LocalEnvironmentFinding fact.project 必须等于或位于 parentProject 下。"
        }
        $classificationDecision = Get-EnvLocalEnvironmentClassification -Path $canonicalPath -Project $canonicalProject -ParentProject $canonicalParentProject
        if ($finding.classification -cne $classificationDecision.classification) {
            throw "LocalEnvironmentFinding fact.classification 与 path/project/parentProject 事实不一致：Expected=$($classificationDecision.classification); Actual=$($finding.classification)"
        }
        if ($finding.scope -cne $classificationDecision.scope -or $finding.owner -cne $classificationDecision.owner) {
            throw "LocalEnvironmentFinding fact classification/scope/owner 不一致：$($finding.classification)"
        }
        if ($null -ne $finding.sizeBytes -and
            (-not (Test-EnvMigrationInteger -Value $finding.sizeBytes) -or [int64]$finding.sizeBytes -lt 0)) {
            throw "LocalEnvironmentFinding fact.sizeBytes 必须是 null 或非负整数。"
        }
        if ($finding.PSObject.Properties.Name -contains "includeInReviewPack" -and $finding.includeInReviewPack -isnot [bool]) {
            throw "Legacy includeInReviewPack 必须是 boolean。"
        }

        Assert-EnvFactObject -Value $finding.rebuildEvidence -FactName "LocalEnvironmentFinding fact.rebuildEvidence"
        Assert-EnvFactPropertySet -Value $finding.rebuildEvidence -ExpectedProperties @("marker", "projectFiles") -FactName "LocalEnvironmentFinding fact.rebuildEvidence"
        Assert-EnvNonEmptyStringProperty -Value $finding.rebuildEvidence -PropertyName "marker" -FactName "LocalEnvironmentFinding fact.rebuildEvidence"
        if ($finding.rebuildEvidence.marker -cne $finding.marker) {
            throw "LocalEnvironmentFinding fact.rebuildEvidence.marker 必须与 marker 一致。"
        }
        if ($finding.rebuildEvidence.projectFiles -isnot [array]) {
            throw "LocalEnvironmentFinding fact.rebuildEvidence.projectFiles 必须是数组。"
        }
        $projectFileKeys = @()
        foreach ($projectFile in @($finding.rebuildEvidence.projectFiles)) {
            if ($projectFile -isnot [string] -or [string]::IsNullOrWhiteSpace($projectFile)) {
                throw "LocalEnvironmentFinding fact.rebuildEvidence.projectFiles 只能包含非空字符串。"
            }
            if ($projectFile -cnotin $allowedProjectFiles) {
                throw "LocalEnvironmentFinding fact.rebuildEvidence.projectFiles 包含未知文件：$projectFile"
            }
            $projectFileKeys += $projectFile.ToLowerInvariant()
        }
        if (@($projectFileKeys | Sort-Object -Unique).Count -ne $projectFileKeys.Count) {
            throw "LocalEnvironmentFinding fact.rebuildEvidence.projectFiles 包含重复项。"
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
    foreach ($name in @("generatedAt", "directories", "excludedRoots", "localEnvironmentFindings", "projectRoots", "projectRootFacts")) {
        if (-not ($Inventory.PSObject.Properties.Name -contains $name)) {
            throw "Inventory 缺少迁移计划所需事实字段：$name"
        }
    }
    if ($Inventory.generatedAt -isnot [string] -or [string]::IsNullOrWhiteSpace($Inventory.generatedAt)) {
        throw "Inventory generatedAt 必须是非空字符串。"
    }
    foreach ($name in @("directories", "excludedRoots", "localEnvironmentFindings", "projectRoots", "projectRootFacts")) {
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
    Assert-EnvProjectRootCompatibility -ProjectRoots @($Inventory.projectRoots) -ProjectRootFacts @($Inventory.projectRootFacts)
    Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings @($Inventory.localEnvironmentFindings) -ProjectRootFacts @($Inventory.projectRootFacts)
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

        if ((Test-EnvMigrationSubPath -Path $directory.path -Root "C:\Users") -and
            -not (Test-EnvApprovedUserCachePath -Path $directory.path)) {
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
            reason = Get-EnvDirectoryPolicyReason -Directory $directory -Disposition "candidate"
        }
    }
}

function Get-EnvDirectoryPolicyReason {
    param(
        [Parameter(Mandatory)][psobject]$Directory,
        [Parameter(Mandatory)][ValidateSet("candidate", "manual")][string]$Disposition
    )

    $location = if (Test-EnvMigrationSubPath -Path $Directory.path -Root "C:\Users") {
        "C 盘用户目录"
    } else {
        "C 盘目录"
    }
    if ($Disposition -eq "manual") {
        switch ($Directory.category) {
            "cache" { return "$location 下的路径未被证明为纯缓存 allowlist 根，必须人工确认内容和归属。" }
            "tool-env" { return "$location 下的工具或环境根可能包含可执行文件、配置或状态，必须按官方机制人工处理。" }
            "manual-only" { return "$location 属于明确人工治理类别，可能包含配置、状态或敏感材料。" }
            default { return "$location 的用途和迁移边界不足以支持自动建议，必须人工确认。" }
        }
    }

    switch ($Directory.category) {
        "cache" { return "$location 已被识别为明确缓存目录；仅允许生成保留源目录的 dry-run 建议。" }
        "tool-env" { return "$location 已被识别为工具或环境根；只能按工具官方机制生成 dry-run 建议。" }
        default { return "$location 已通过目录事实与 root policy 检查；仍只允许生成 dry-run 建议。" }
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
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalEnvironmentFindings,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProjectRootFacts
    )

    Assert-EnvMigrationDirectoryFacts -Directories $Directories
    Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings $LocalEnvironmentFindings -ProjectRootFacts $ProjectRootFacts
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
                reason = Get-EnvDirectoryPolicyReason -Directory $directory -Disposition "manual"
            }
        } elseif ((Test-EnvMigrationSubPath -Path $directory.path -Root "C:\Users") -and
            -not ($directory.category -eq "cache" -and (Test-EnvApprovedUserCachePath -Path $directory.path))) {
            [pscustomobject]@{
                source = $directory.path
                kind = $directory.category
                owner = $directory.owner
                risk = "high"
                action = "不自动迁移"
                reason = Get-EnvDirectoryPolicyReason -Directory $directory -Disposition "manual"
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
