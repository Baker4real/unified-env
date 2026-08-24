param(
    [string]$ReviewPath = "D:\agents\projects\统一环境\reports\project-local-env-review\review.json",
    [string]$ReviewMarkdownPath,
    [string]$OutputDir = "D:\agents\projects\统一环境\reports\project-local-env-rebuild-plan"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\ReportArtifactPublisher.ps1")
. (Join-Path $PSScriptRoot "lib\EnvPathSafety.ps1")
. (Join-Path $PSScriptRoot "lib\EnvMigrationPolicy.ps1")
. (Join-Path $PSScriptRoot "lib\TrustedReportInput.ps1")

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
        "D:\agents\projects\统一环境\reports",
        "D:\Codex\.codex\run-evidence\env-governance"
    )

    foreach ($allowedRoot in $allowedRoots) {
        if (Test-IsSubPath -Path $Path -BasePath $allowedRoot) {
            return
        }
    }

    throw "OutputDir 必须位于允许的报告目录：D:\agents\projects\统一环境\reports 或 D:\Codex\.codex\run-evidence\env-governance。当前值：$Path"
}

function Assert-AllowedReviewPath {
    param([string]$Path)

    $allowedRoots = @(
        "D:\agents\projects\统一环境\reports\project-local-env-review",
        "D:\Codex\.codex\run-evidence\env-governance"
    )

    foreach ($allowedRoot in $allowedRoots) {
        if (Test-IsSubPath -Path $Path -BasePath $allowedRoot) {
            return
        }
    }

    throw "ReviewPath 必须位于允许的审查包目录：D:\agents\projects\统一环境\reports\project-local-env-review 或 D:\Codex\.codex\run-evidence\env-governance。当前值：$Path"
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

function Get-PlanStatus {
    param([object]$ReviewItem)

    $files = @($ReviewItem.rebuildEvidence.projectFiles)
    $hasNodeLock = $files -contains "package-lock.json" -or $files -contains "pnpm-lock.yaml" -or $files -contains "yarn.lock"
    $hasPythonLock = $files -contains "uv.lock" -or $files -contains "poetry.lock" -or $files -contains "Pipfile.lock"
    $hasCondaEnvFile = $files -contains "environment.yml"
    $hasRecognizedRebuildSource =
        ($ReviewItem.marker -eq "node_modules" -and $hasNodeLock) -or
        ($ReviewItem.marker -in @(".venv", "venv") -and $hasPythonLock) -or
        ($ReviewItem.marker -eq ".conda" -and $hasCondaEnvFile)

    if (-not $hasRecognizedRebuildSource) {
        if ("$($ReviewItem.rebuildAssessment)".StartsWith("需项目 owner 决策")) {
            return "blocked-no-rebuild-source"
        }

        return "owner-decision-required"
    }

    if ([bool]$ReviewItem.isLongRunningOrStateful -or $ReviewItem.riskLevel -eq "high") {
        return "owner-decision-required"
    }

    return "planned-rebuild"
}

function Get-CandidateCommands {
    param(
        [object]$ReviewItem,
        [string]$PlanStatus
    )

    if ($PlanStatus -ne "planned-rebuild") {
        return @()
    }

    $commands = New-Object System.Collections.Generic.List[string]
    $commands.Add("候选命令预览：以下命令只能在独立项目级 issue、明确授权和完成前置检查后执行。")

    $files = @($ReviewItem.rebuildEvidence.projectFiles)
    if ($ReviewItem.marker -eq "node_modules" -and $files -contains "package-lock.json") {
        $commands.Add("在项目根确认 package-lock.json 后，候选命令：npm ci")
        $commands.Add("执行前必须确认 npm ci 会重建 node_modules，不能在本 dry-run 中运行。")
        return $commands
    }

    if ($ReviewItem.marker -in @(".venv", "venv")) {
        if ($files -contains "uv.lock") {
            $commands.Add("在项目根确认 uv.lock、Python 版本和项目文档后，候选命令：uv sync")
            $commands.Add("优先使用项目自己的 uv 配置；不得跨项目复用该 .venv。")
            return $commands
        }

    }

    if ($ReviewItem.marker -eq ".conda" -and $files -contains "environment.yml") {
        $commands.Add("在项目根确认 environment.yml 后，候选命令：conda env create --prefix .conda.rebuild-candidate --file environment.yml")
        $commands.Add("原 .conda 必须保持不变，验证通过前不得替换。")
        return $commands
    }

    @()
}

function Get-PreflightChecks {
    param([object]$ReviewItem)

    $items = New-Object System.Collections.Generic.List[string]
    $items.Add("读取项目 README、AGENTS 或等效项目说明。")
    $items.Add("确认该项目环境当前未被运行中的进程、服务或恢复链路占用。")
    $items.Add("确认项目锁文件、解释器版本、包管理器版本和测试命令。")
    $items.Add("记录当前环境路径和必要环境变量，保留原环境不变。")

    if ([bool]$ReviewItem.isLongRunningOrStateful -or $ReviewItem.riskLevel -eq "high") {
        $items.Add("高风险项目必须先确认 owner、停机窗口、启动命令、健康检查和回滚步骤。")
    }

    $items
}

function Get-ValidationSteps {
    param([object]$ReviewItem)

    $items = New-Object System.Collections.Generic.List[string]
    $items.Add("运行项目自己的最小测试或 smoke test。")
    $items.Add("确认新环境不会改变项目配置、绝对路径或运行账户。")

    if ($ReviewItem.marker -eq "node_modules") {
        $items.Add("运行 package.json 中的 lint/test/build 中至少一个项目级验证命令。")
    }

    if ($ReviewItem.marker -in @(".venv", "venv", ".conda")) {
        $items.Add("确认解释器路径、关键依赖版本和项目入口命令。")
    }

    if ([bool]$ReviewItem.isLongRunningOrStateful -or $ReviewItem.riskLevel -eq "high") {
        $items.Add("完成服务级健康检查，并确认状态文件、账号、队列或会话数据未丢失。")
    }

    $items
}

function Get-RollbackPrerequisites {
    param([object]$ReviewItem)

    $items = New-Object System.Collections.Generic.List[string]
    $items.Add("真实重建前必须保留原环境目录，不允许在 dry-run 阶段删除或覆盖。")
    $items.Add("记录恢复原环境的命令、环境变量和验证方式。")

    if ([bool]$ReviewItem.isLongRunningOrStateful -or $ReviewItem.riskLevel -eq "high") {
        $items.Add("高风险项目必须预先写明停止新实例、恢复旧环境、重新启动和健康检查的回滚顺序。")
    }

    $items
}

function Get-HumanGates {
    param(
        [object]$ReviewItem,
        [string]$PlanStatus
    )

    $items = New-Object System.Collections.Generic.List[string]
    $items.Add("项目 owner 明确授权后才能进入真实重建 issue。")

    if ($PlanStatus -eq "owner-decision-required") {
        $items.Add("owner 需要补充锁文件、Python/Node 版本和测试命令后才能生成可重建计划。")
    }

    if ($PlanStatus -eq "blocked-no-rebuild-source") {
        $items.Add("缺少足够重建来源，禁止自动处理，需 owner 决策是否保留或补充说明。")
    }

    if ([bool]$ReviewItem.isLongRunningOrStateful -or $ReviewItem.riskLevel -eq "high") {
        $items.Add("必须由 owner 确认停机窗口。")
        $items.Add("必须确认服务启动命令、健康检查、状态恢复和回滚负责人。")
    }

    $items
}

function ConvertTo-PlanMarkdown {
    param([object]$Plan)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 项目本地环境重建 DRY-RUN 计划")
    $lines.Add("")
    $lines.Add("生成时间：$($Plan.generatedAt)")
    $lines.Add("")
    $lines.Add("> DRY-RUN：本计划不执行命令、不删除目录、不迁移环境、不合并项目本地环境。候选命令预览只用于后续独立项目级 issue。")
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add("- 计划项数量：$($Plan.summary.totalPlans)")
    $lines.Add("- 可计划重建：$($Plan.summary.plannedRebuilds)")
    $lines.Add("- 需 owner 决策：$($Plan.summary.ownerDecisionRequired)")
    $lines.Add("- 缺少重建来源阻塞：$($Plan.summary.blockedNoRebuildSource)")
    $lines.Add("- 高风险或状态敏感：$($Plan.summary.highRiskPlans)")
    $lines.Add("")
    $lines.Add("## 计划清单")
    $lines.Add("")
    $lines.Add("| 项目或 app | 分类 | 标记 | 风险 | 状态 | 执行允许 | 需 owner | 说明 |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- |")
    foreach ($item in $Plan.plans) {
        $risk = Convert-RiskLevelToDisplay -RiskLevel $item.riskLevel
        $execution = if ($item.executionAllowed) { "是" } else { "否" }
        $owner = if ($item.requiresOwnerDecision) { "是" } else { "否" }
        $lines.Add("| $(Escape-MarkdownCell $item.project) | $(Escape-MarkdownCell $item.classification) | $(Escape-MarkdownCell $item.marker) | $(Escape-MarkdownCell $risk) | $(Escape-MarkdownCell $item.planStatus) | $execution | $owner | $(Escape-MarkdownCell $item.reason) |")
    }
    $lines.Add("")
    $lines.Add("## 逐项目计划")
    foreach ($item in $Plan.plans) {
        $lines.Add("")
        $lines.Add("### $(Escape-MarkdownCell $item.project) / $(Escape-MarkdownCell $item.marker)")
        $lines.Add("")
        $lines.Add(('- 路径：`{0}`' -f $item.path))
        $lines.Add(('- 父项目：`{0}`' -f $item.parentProject))
        $lines.Add(('- 分类：`{0}`' -f $item.classification))
        $lines.Add(('- 计划状态：`{0}`' -f $item.planStatus))
        $lines.Add("- 允许执行：否")
        $lines.Add("")
        $lines.Add("#### 人工决策门")
        foreach ($gate in $item.humanGates) {
            $lines.Add("- $gate")
        }
        $lines.Add("")
        $lines.Add("#### 前置检查")
        foreach ($check in $item.preflightChecks) {
            $lines.Add("- $check")
        }
        $lines.Add("")
        $lines.Add("#### 候选命令预览")
        if ($item.candidateCommands.Count -eq 0) {
            $lines.Add("- 无。当前项目缺少足够重建来源或必须先由 owner 决策。")
        } else {
            foreach ($command in $item.candidateCommands) {
                $lines.Add("- $command")
            }
        }
        $lines.Add("")
        $lines.Add("#### 验证步骤")
        foreach ($step in $item.validationSteps) {
            $lines.Add("- $step")
        }
        $lines.Add("")
        $lines.Add("#### 回滚前置条件")
        foreach ($step in $item.rollbackPrerequisites) {
            $lines.Add("- $step")
        }
    }
    $lines.Add("")
    $lines.Add("## 策略")
    foreach ($rule in $Plan.policy.rules) {
        $lines.Add("- $rule")
    }

    return ($lines -join "`n")
}

$trustedInput = Get-TrustedReportInputPair -JsonPath $ReviewPath -MarkdownPath $ReviewMarkdownPath -DefaultMarkdownFileName "REPORT.md" -JsonParameterName "ReviewPath" -MarkdownParameterName "ReviewMarkdownPath"
$review = Get-Content -LiteralPath $trustedInput.jsonPath -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
Assert-ProjectLocalReviewDocument -Review $review
$sourceInventoryInput = Get-TrustedReportInputPair -JsonPath $review.inventoryPath -MarkdownPath "" -DefaultMarkdownFileName "REPORT.md" -JsonParameterName "Review.inventoryPath" -MarkdownParameterName "Review inventory Markdown"
$sourceInventory = Get-Content -LiteralPath $sourceInventoryInput.jsonPath -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
Assert-EnvMigrationInventoryFacts -Inventory $sourceInventory
if ($review.sourceInventoryGenerationId -cne $sourceInventoryInput.generationId -or
    $review.sourceInventoryJsonSha256 -cne $sourceInventoryInput.sourceJsonSha256 -or
    $review.inventoryGeneratedAt -cne $sourceInventory.generatedAt) {
    throw "Review source inventory identity 与当前可信 inventory 报告对不一致。"
}
$expectedReviewItems = [object[]]@(Get-ProjectLocalReviewItems -Inventory $sourceInventory)
if ((@($review.items) | ConvertTo-Json -Depth 30) -cne ($expectedReviewItems | ConvertTo-Json -Depth 30)) {
    throw "Review items 必须与 source inventory 的 canonical 完整投影精确一致。"
}
Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"
Assert-AllowedOutputDir -Path $OutputDir
$plans = @(
    foreach ($item in @($review.items)) {
        $status = Get-PlanStatus -ReviewItem $item
        $commands = @(Get-CandidateCommands -ReviewItem $item -PlanStatus $status)
        $requiresOwner = $true

        [pscustomobject]@{
            project = $item.project
            parentProject = $item.parentProject
            marker = $item.marker
            path = $item.path
            classification = if ($item.PSObject.Properties.Name -contains "classification") { $item.classification } else { "project-root-local-env" }
            scope = if ($item.PSObject.Properties.Name -contains "scope") { $item.scope } else { "project-root" }
            riskLevel = $item.riskLevel
            planStatus = $status
            executionAllowed = $false
            requiresOwnerDecision = $requiresOwner
            rebuildAssessment = $item.rebuildAssessment
            candidateCommands = $commands
            preflightChecks = @(Get-PreflightChecks -ReviewItem $item)
            validationSteps = @(Get-ValidationSteps -ReviewItem $item)
            rollbackPrerequisites = @(Get-RollbackPrerequisites -ReviewItem $item)
            humanGates = @(Get-HumanGates -ReviewItem $item -PlanStatus $status)
            reason = if ($status -eq "planned-rebuild") { "存在锁文件或重建来源，但仍只能作为后续独立 issue 的候选计划。" } elseif ($status -eq "owner-decision-required") { "存在部分线索，但缺少足够版本、锁文件或测试信息。" } else { "缺少足够重建来源，禁止自动处理。" }
            sourceReviewGeneratedAt = $review.generatedAt
        }
    }
)

$plan = [pscustomobject]@{
    artifactType = "env-governance.project-local-env-rebuild-plan"
    schemaVersion = 2
    generatedAt = (Get-Date).ToString("o")
    dryRun = $true
    readOnly = $true
    reviewPath = $trustedInput.jsonPath
    reviewGeneratedAt = "$($review.generatedAt)"
    summary = [pscustomobject]@{
        totalPlans = $plans.Count
        plannedRebuilds = @($plans | Where-Object { $_.planStatus -eq "planned-rebuild" }).Count
        ownerDecisionRequired = @($plans | Where-Object { $_.requiresOwnerDecision }).Count
        blockedNoRebuildSource = @($plans | Where-Object { $_.planStatus -eq "blocked-no-rebuild-source" }).Count
        highRiskPlans = @($plans | Where-Object { $_.riskLevel -eq "high" }).Count
    }
    plans = $plans
    policy = [pscustomobject]@{
        executionAllowed = $false
        deleteAllowed = $false
        migrationAllowed = $false
        rules = @(
            "本计划是 dry-run，只生成说明和候选命令预览。",
            "本计划不执行、不删除、不迁移、不合并任何项目本地环境。",
            "嵌套 app 环境必须按所在 app 单独审查，不能并入父项目统一重建。",
            "插件 runtime/cache 和 repair backup 缓存不进入项目依赖重建计划。",
            "候选命令必须在独立项目级 issue、明确授权和项目验证计划下执行。",
            "高风险、长期服务或状态敏感项目必须先通过人工决策门。",
            "缺少锁文件或重建说明的项目不得输出可直接执行的重建命令。"
        )
    }
}

$published = Publish-JsonMarkdownArtifactPair `
    -Document $plan `
    -OutputDir $OutputDir `
    -JsonFileName "plan.json" `
    -MarkdownFileName "PLAN.md" `
    -RenderMarkdown {
        param($Document, $JsonSha256)
        ConvertTo-PlanMarkdown -Plan $Document
    }

[pscustomobject]@{
    planJson = $published.jsonPath
    planMarkdown = $published.markdownPath
    dryRun = $true
    readOnly = $true
}
