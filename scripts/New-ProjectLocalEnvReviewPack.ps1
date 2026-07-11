param(
    [string]$InventoryPath = "D:\Codex\projects\统一环境\reports\env-inventory\inventory.json",
    [string]$InventoryMarkdownPath,
    [string]$OutputDir = "D:\Codex\projects\统一环境\reports\project-local-env-review"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\ReportArtifactPublisher.ps1")
. (Join-Path $PSScriptRoot "lib\EnvMigrationPolicy.ps1")
. (Join-Path $PSScriptRoot "lib\TrustedReportInput.ps1")

function Assert-ProjectLocalEnvInventoryFacts {
    param([Parameter(Mandatory)][psobject]$Inventory)

    if ($Inventory -isnot [pscustomobject] -or
        -not ($Inventory.PSObject.Properties.Name -contains "artifactType") -or
        $Inventory.artifactType -isnot [string] -or
        $Inventory.artifactType -cne "env-governance.inventory") {
        throw "Inventory artifactType 必须为 env-governance.inventory。"
    }
    if (-not ($Inventory.PSObject.Properties.Name -contains "schemaVersion") -or
        -not (Test-EnvMigrationInteger -Value $Inventory.schemaVersion) -or
        $Inventory.schemaVersion -ne 3) {
        throw "Inventory schemaVersion 必须是整数 3。"
    }
    foreach ($name in @("localEnvironmentFindings", "projectRoots", "projectRootFacts")) {
        if (-not ($Inventory.PSObject.Properties.Name -contains $name) -or
            $Inventory.$name -isnot [array]) {
            throw "Inventory $name 必须是事实数组。"
        }
    }

    Assert-EnvProjectRootCompatibility -ProjectRoots @($Inventory.projectRoots) -ProjectRootFacts @($Inventory.projectRootFacts)
    Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings @($Inventory.localEnvironmentFindings) -ProjectRootFacts @($Inventory.projectRootFacts) -AllowLegacyReviewFlag
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

function Assert-ExistingLeafIsNotReparsePoint {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$ParameterName 不能穿过 junction、symlink 或 reparse point：$Path"
    }
}

function Test-IsLongRunningOrStatefulProject {
    param(
        [string]$Project,
        [string]$Marker
    )

    $normalized = $Project.ToLowerInvariant()
    if ($normalized.Contains("\.gsd\projects\")) {
        return $true
    }

    foreach ($token in @("bot", "qqbot", "agent", "service", "daemon", "worker", "hermes")) {
        if ($normalized.Contains($token)) {
            return $true
        }
    }

    if ($Marker -eq ".venv" -and $normalized.Contains("direct")) {
        return $true
    }

    return $false
}

function Get-RebuildAssessment {
    param(
        [string]$Marker,
        [string[]]$Files
    )

    if ($Marker -eq "node_modules") {
        if ($Files -contains "package-lock.json") {
            return "可重建：发现 package-lock.json；可在独立 issue 中用 npm ci 重建并运行项目测试。"
        }

        if ($Files -contains "pnpm-lock.yaml") {
            return "可重建：发现 pnpm-lock.yaml；可在独立 issue 中用 pnpm install --frozen-lockfile 重建并运行项目测试。"
        }

        if ($Files -contains "yarn.lock") {
            return "可重建：发现 yarn.lock；可在独立 issue 中用 yarn install --frozen-lockfile 重建并运行项目测试。"
        }

        if ($Files -contains "package.json") {
            return "需项目 owner 决策：只有 package.json，缺少锁文件，不能自动重建。"
        }
    }

    if ($Marker -in @(".venv", "venv")) {
        if ($Files -contains "uv.lock") {
            return "可重建：发现 uv.lock；可在独立 issue 中按项目文档重建虚拟环境并运行测试。"
        }

        if ($Files -contains "requirements.txt") {
            return "可重建：发现 requirements.txt；可在独立 issue 中重建虚拟环境并运行项目测试。"
        }

        if ($Files -contains "pyproject.toml") {
            return "可能可重建：发现 pyproject.toml；需确认锁文件、Python 版本和项目测试命令。"
        }
    }

    if ($Marker -eq ".conda") {
        if ($Files -contains "environment.yml") {
            return "可重建：发现 environment.yml；需用项目级 Conda 流程单独验证。"
        }
    }

    return "需项目 owner 决策：缺少足够的锁文件或重建说明，不能自动处理。"
}

function Get-RecommendedAction {
    param(
        [bool]$IsLongRunningOrStateful,
        [string]$RebuildAssessment
    )

    if ($IsLongRunningOrStateful) {
        return "保留；需项目 owner 决策；真实重建前必须确认服务停启、状态恢复和项目级验证。"
    }

    if ($RebuildAssessment.StartsWith("可重建")) {
        return "默认保留；可单独开重建 issue，但不得在本项目中自动迁移或合并。"
    }

    return "保留；需项目 owner 决策；禁止自动处理。"
}

function Get-VerificationPrerequisites {
    param(
        [string]$Marker,
        [bool]$IsLongRunningOrStateful,
        [string[]]$Files
    )

    $items = @(
        "读取项目 README/AGENTS 或等效项目说明。",
        "确认项目自己的依赖安装命令、锁文件和测试命令。",
        "确认当前环境不是正在运行的服务或恢复链路的一部分。",
        "先在项目内生成独立 dry-run 或重建计划，不跨项目复用该目录。"
    )

    if ($Marker -eq "node_modules") {
        $items += "确认 package manager 与锁文件一致，例如 npm/package-lock、pnpm/pnpm-lock 或 yarn/yarn.lock。"
    }

    if ($Marker -in @(".venv", "venv", ".conda")) {
        $items += "确认 Python/Conda 版本、解释器路径、原环境变量和项目测试命令。"
    }

    if ($IsLongRunningOrStateful) {
        $items += "长期服务或状态敏感项目必须先确认停机窗口、启动命令、健康检查、回滚步骤和 owner 决策。"
    }

    if ($Files.Count -eq 0) {
        $items += "缺少项目配置线索时，必须先由项目 owner 补充重建说明。"
    }

    $items
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function Convert-RiskLevelToDisplay {
    param([string]$RiskLevel)

    switch ($RiskLevel) {
        "high" { return "高" }
        "medium" { return "中" }
        "low" { return "低" }
        default { return $RiskLevel }
    }
}

function ConvertTo-ReviewMarkdown {
    param(
        [object]$Review
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 项目本地环境审查包")
    $lines.Add("")
    $lines.Add("生成时间：$($Review.generatedAt)")
    $lines.Add("")
    $lines.Add('> 只读报告：项目本地环境默认不自动迁移；本报告不移动、不删除、不合并任何 `.venv`、`node_modules`、`.conda` 或其他项目本地环境。')
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add("- 审查项数量：$($Review.summary.totalItems)")
    $lines.Add("- 长期服务或状态敏感项目：$($Review.summary.longRunningOrStatefulItems)")
    $lines.Add("- 可重建线索项：$($Review.summary.rebuildableItems)")
    $lines.Add("- 需项目 owner 决策项：$($Review.summary.ownerDecisionItems)")
    $lines.Add("- 嵌套 app 环境项：$($Review.summary.nestedAppItems)")
    $lines.Add("")
    $lines.Add("## 审查清单")
    $lines.Add("")
    $lines.Add("| 项目或 app | 父项目 | 分类 | 标记 | 路径 | 风险 | 建议动作 | 重建判断 | 长期服务 |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    foreach ($item in $Review.items) {
        $longRunning = if ($item.isLongRunningOrStateful) { "是" } else { "否" }
        $riskDisplay = Convert-RiskLevelToDisplay -RiskLevel $item.riskLevel
        $lines.Add("| $(Escape-MarkdownCell $item.project) | $(Escape-MarkdownCell $item.parentProject) | $(Escape-MarkdownCell $item.classification) | $(Escape-MarkdownCell $item.marker) | $(Escape-MarkdownCell $item.path) | $(Escape-MarkdownCell $riskDisplay) | $(Escape-MarkdownCell $item.recommendedAction) | $(Escape-MarkdownCell $item.rebuildAssessment) | $longRunning |")
    }
    $lines.Add("")
    $lines.Add("## 验证前置条件")
    foreach ($item in $Review.items) {
        $lines.Add("")
        $lines.Add("### $(Escape-MarkdownCell $item.project) / $(Escape-MarkdownCell $item.marker)")
        foreach ($prerequisite in $item.verificationPrerequisites) {
            $lines.Add("- $prerequisite")
        }
    }
    $lines.Add("")
    $lines.Add("## 策略")
    foreach ($rule in $Review.policy.rules) {
        $lines.Add("- $rule")
    }

    return $lines -join [Environment]::NewLine
}

$trustedInput = Get-TrustedReportInputPair -JsonPath $InventoryPath -MarkdownPath $InventoryMarkdownPath -DefaultMarkdownFileName "REPORT.md" -JsonParameterName "InventoryPath" -MarkdownParameterName "InventoryMarkdownPath"
$inventory = Get-Content -LiteralPath $trustedInput.jsonPath -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
Assert-ProjectLocalEnvInventoryFacts -Inventory $inventory
Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"
Assert-AllowedOutputDir -Path $OutputDir
$items = @(
    foreach ($marker in @($inventory.localEnvironmentFindings | Where-Object { Test-EnvLocalEnvironmentFindingReviewEligible -Finding $_ })) {
        $files = @($marker.rebuildEvidence.projectFiles)
        $isLongRunning = Test-IsLongRunningOrStatefulProject -Project $marker.project -Marker $marker.marker
        $rebuildAssessment = Get-RebuildAssessment -Marker $marker.marker -Files $files
        $recommendedAction = Get-RecommendedAction -IsLongRunningOrStateful $isLongRunning -RebuildAssessment $rebuildAssessment
        $verificationPrerequisites = @(Get-VerificationPrerequisites -Marker $marker.marker -IsLongRunningOrStateful $isLongRunning -Files $files)
        $needsOwnerDecision = $recommendedAction -like "*owner 决策*" -or $rebuildAssessment -like "*owner 决策*"

        [pscustomobject]@{
            project = $marker.project
            parentProject = $marker.parentProject
            marker = $marker.marker
            path = $marker.path
            classification = if ($marker.PSObject.Properties.Name -contains "classification") { $marker.classification } else { "project-root-local-env" }
            scope = if ($marker.PSObject.Properties.Name -contains "scope") { $marker.scope } else { "project-root" }
            existingProjectFiles = $files
            rebuildEvidence = [pscustomobject]@{ marker = $marker.rebuildEvidence.marker; projectFiles = [object[]]@($files) }
            riskLevel = if ($isLongRunning) { "high" } else { "medium" }
            recommendedAction = $recommendedAction
            automationAllowed = $false
            rebuildAssessment = $rebuildAssessment
            verificationPrerequisites = $verificationPrerequisites
            isLongRunningOrStateful = $isLongRunning
            requiresOwnerDecision = $needsOwnerDecision
            futureIssueRecommendation = if ($rebuildAssessment.StartsWith("可重建")) { "可单独开项目级重建 issue。" } else { "先由项目 owner 补充重建和验证说明。" }
            reason = "项目本地环境可能绑定解释器、绝对路径、构建产物、平台依赖或服务状态。"
        }
    }
)

$review = [pscustomobject]@{
    artifactType = "env-governance.project-local-env-review"
    schemaVersion = 2
    generatedAt = (Get-Date).ToString("o")
    readOnly = $true
    inventoryPath = $trustedInput.jsonPath
    inventoryGeneratedAt = "$($inventory.generatedAt)"
    summary = [pscustomobject]@{
        totalItems = $items.Count
        longRunningOrStatefulItems = @($items | Where-Object { $_.isLongRunningOrStateful }).Count
        rebuildableItems = @($items | Where-Object { $_.rebuildAssessment -like "可重建*" }).Count
        ownerDecisionItems = @($items | Where-Object { $_.requiresOwnerDecision }).Count
        nestedAppItems = @($items | Where-Object { $_.classification -eq "nested-app-local-env" }).Count
    }
    items = $items
    policy = [pscustomobject]@{
        autoMigrationAllowed = $false
        rules = @(
            "项目本地环境默认不自动迁移。",
            "本审查包不移动、不删除、不合并任何项目本地环境。",
            "嵌套 app 的本地环境只能按所在 app 的项目级流程审查，不能并入父项目或共享环境。",
            "插件 runtime/cache 和 repair backup 缓存不属于本审查包的可重建项目依赖。",
            "长期服务或状态敏感项目必须先有项目 owner 决策和项目级验证。",
            "可重建只表示存在锁文件或配置线索，不等于允许自动重建。",
            "任何重建都必须作为独立项目级 issue 执行。"
        )
    }
}

$jsonPath = Join-Path $OutputDir "review.json"
$markdownPath = Join-Path $OutputDir "REPORT.md"
Assert-ExistingLeafIsNotReparsePoint -Path $jsonPath -ParameterName "review.json"
Assert-ExistingLeafIsNotReparsePoint -Path $markdownPath -ParameterName "REPORT.md"
$published = Publish-JsonMarkdownArtifactPair -Document $review -OutputDir $OutputDir -JsonFileName "review.json" -MarkdownFileName "REPORT.md" -RenderMarkdown {
    param($Document, $SourceJsonSha256)
    ConvertTo-ReviewMarkdown -Review $Document
}

[pscustomobject]@{
    reviewJson = $published.jsonPath
    reviewMarkdown = $published.markdownPath
    generationId = $published.generationId
    readOnly = $true
}
