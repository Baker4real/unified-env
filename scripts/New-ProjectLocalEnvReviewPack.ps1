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

    return Test-EnvProjectLongRunningOrStateful -Project $Project -Marker $Marker
}

function Get-RebuildAssessment {
    param(
        [string]$Marker,
        [string[]]$Files
    )

    return Get-EnvProjectReviewRebuildAssessment -Marker $Marker -Files $Files
}

function Get-RecommendedAction {
    param(
        [bool]$IsLongRunningOrStateful,
        [string]$RebuildAssessment
    )

    return Get-EnvProjectReviewRecommendedAction -IsLongRunningOrStateful $IsLongRunningOrStateful -RebuildAssessment $RebuildAssessment
}

function Get-VerificationPrerequisites {
    param(
        [string]$Marker,
        [bool]$IsLongRunningOrStateful,
        [string[]]$Files
    )

    return Get-EnvProjectReviewVerificationPrerequisites -Marker $Marker -IsLongRunningOrStateful $IsLongRunningOrStateful -Files $Files
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
$items = [object[]]@(Get-ProjectLocalReviewItems -Inventory $inventory)

$review = [pscustomobject]@{
    artifactType = "env-governance.project-local-env-review"
    schemaVersion = 2
    generatedAt = (Get-Date).ToString("o")
    readOnly = $true
    inventoryPath = $trustedInput.jsonPath
    inventoryGeneratedAt = "$($inventory.generatedAt)"
    sourceInventoryGenerationId = $trustedInput.generationId
    sourceInventoryJsonSha256 = $trustedInput.sourceJsonSha256
    summary = Get-ProjectLocalReviewSummary -Items $items
    items = $items
    policy = Get-ProjectLocalReviewPolicy
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
