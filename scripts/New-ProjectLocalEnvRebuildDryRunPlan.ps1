param(
    [string]$ReviewPath = "D:\Codex\projects\统一环境\reports\project-local-env-review\review.json",
    [string]$ReviewMarkdownPath,
    [string]$OutputDir = "D:\Codex\projects\统一环境\reports\project-local-env-rebuild-plan"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\ReportArtifactPublisher.ps1")
. (Join-Path $PSScriptRoot "lib\EnvPathSafety.ps1")
. (Join-Path $PSScriptRoot "lib\TrustedReportInput.ps1")

function Test-RebuildNativeInteger {
    param([AllowNull()][object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Assert-ProjectLocalEnvReviewDocument {
    param([Parameter(Mandatory)][object]$Review)
    if ($Review -isnot [pscustomobject]) { throw "Review 必须是 JSON object。" }
    if ($Review.artifactType -isnot [string] -or $Review.artifactType -cne "env-governance.project-local-env-review") { throw "Review artifactType 不正确。" }
    if (-not (Test-RebuildNativeInteger $Review.schemaVersion) -or $Review.schemaVersion -ne 2) { throw "Review schemaVersion 必须是原生整数 2。" }
    foreach ($name in @("generationId", "generatedAt", "inventoryPath", "inventoryGeneratedAt")) {
        if (-not ($Review.PSObject.Properties.Name -contains $name) -or $Review.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Review.$name)) { throw "Review $name 必须是非空字符串。" }
    }
    if ($Review.generationId -notmatch '^[0-9a-f-]{36}$') { throw "Review generationId 非法。" }
    if ($Review.readOnly -isnot [bool] -or -not $Review.readOnly) { throw "Review readOnly 必须是 true boolean。" }
    if ($Review.items -isnot [array]) { throw "Review items 必须是数组。" }
    foreach ($item in $Review.items) {
        if ($item -isnot [pscustomobject]) { throw "Review item 必须是 object。" }
        foreach ($name in @("project", "parentProject", "marker", "path", "classification", "scope", "riskLevel", "rebuildAssessment")) {
            if (-not ($item.PSObject.Properties.Name -contains $name) -or $item.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.$name)) { throw "Review item.$name 必须是非空字符串。" }
        }
        Assert-EnvSafeAbsolutePath -Path $item.project -FactName "Review item.project"
        Assert-EnvSafeAbsolutePath -Path $item.parentProject -FactName "Review item.parentProject"
        Assert-EnvSafeAbsolutePath -Path $item.path -FactName "Review item.path"
        if ($item.isLongRunningOrStateful -isnot [bool]) { throw "Review item.isLongRunningOrStateful 必须是 boolean。" }
        if ($item.existingProjectFiles -isnot [array]) { throw "Review item.existingProjectFiles 必须是数组。" }
        if ($item.rebuildEvidence -isnot [pscustomobject] -or $item.rebuildEvidence.marker -isnot [string] -or $item.rebuildEvidence.marker -cne $item.marker -or $item.rebuildEvidence.projectFiles -isnot [array]) { throw "Review item.rebuildEvidence 合同非法。" }
        foreach ($file in @($item.existingProjectFiles) + @($item.rebuildEvidence.projectFiles)) {
            if ($file -isnot [string] -or [string]::IsNullOrWhiteSpace($file)) { throw "Review rebuild evidence 文件名必须是非空字符串。" }
        }
        if ((@($item.existingProjectFiles) -join "`n") -cne (@($item.rebuildEvidence.projectFiles) -join "`n")) { throw "Review rebuildEvidence 与 existingProjectFiles 不一致。" }
    }
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

function Assert-AllowedReviewPath {
    param([string]$Path)

    $allowedRoots = @(
        "D:\Codex\projects\统一环境\reports\project-local-env-review",
        "D:\Codex\.codex\run-evidence\env-governance"
    )

    foreach ($allowedRoot in $allowedRoots) {
        if (Test-IsSubPath -Path $Path -BasePath $allowedRoot) {
            return
        }
    }

    throw "ReviewPath 必须位于允许的审查包目录：D:\Codex\projects\统一环境\reports\project-local-env-review 或 D:\Codex\.codex\run-evidence\env-governance。当前值：$Path"
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
Assert-ProjectLocalEnvReviewDocument -Review $review
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
