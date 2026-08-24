param(
    [string]$InventoryPath = "D:\agents\projects\统一环境\reports\env-inventory\inventory.json",
    [string]$InventoryMarkdownPath,
    [string]$OutputDir = "D:\agents\projects\统一环境\reports\env-update-readiness"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\EnvPathSafety.ps1")
. (Join-Path $PSScriptRoot "lib\EnvUpdateReadinessPolicy.ps1")
. (Join-Path $PSScriptRoot "lib\ReportArtifactPublisher.ps1")

function Assert-ReadinessInputFile {
    param([Parameter(Mandatory)][string]$Path)
    Assert-EnvSafeAbsolutePath -Path $Path -FactName "InventoryPath"
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not ([IO.Path]::GetPathRoot($fullPath) -ieq "D:\")) { throw "InventoryPath 必须位于 D:\：$Path" }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf -ErrorAction Stop)) { throw "Inventory not found: $fullPath" }
    $current = $fullPath
    while ($null -ne $current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "InventoryPath 不能穿过 junction、symlink 或 reparse point：$current" }
        $parent = [IO.Directory]::GetParent($item.FullName)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
    return $fullPath
}

function Escape-MarkdownCell {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function Convert-LocationClassToDisplay {
    param([string]$LocationClass)
    switch ($LocationClass) {
        "d-drive" { "D 盘" }
        "windows-system" { "Windows 系统目录" }
        "system-installer" { "系统安装目录" }
        "winget-package" { "WinGet 包目录" }
        "user-profile" { "用户目录" }
        "unknown" { "未解析" }
        default { "其他位置" }
    }
}

function Convert-RiskLevelToDisplay {
    param([string]$RiskLevel)
    switch ($RiskLevel) { "low" { "低" }; "medium" { "中" }; "high" { "高" }; default { $RiskLevel } }
}

function Convert-ReadinessToMarkdown {
    param([Parameter(Mandatory)][object]$Readiness)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# 统一更新准备报告")
    $lines.Add("")
    $lines.Add("生成时间：$($Readiness.generatedAt)")
    $lines.Add("")
    $lines.Add("> 只读报告：本报告不会执行 winget、uv、npm、Cargo、Rustup 或其他更新命令。")
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add("- Inventory schema：$($Readiness.inventorySchemaVersion)")
    $lines.Add("- PATH 来源作用域：$($Readiness.pathSummary.sourceScope)")
    $lines.Add("- PATH 作用域完整：$($Readiness.pathSummary.complete)")
    $lines.Add("- 工具项数量：$($Readiness.toolReadiness.Count)")
    $lines.Add("- 高风险对象：$($Readiness.highRiskItems.Count)")
    $lines.Add("- PATH 总入口：$($Readiness.pathSummary.total)")
    $lines.Add("- PATH C 盘入口：$($Readiness.pathSummary.cDrive)")
    $lines.Add("- PATH D 盘入口：$($Readiness.pathSummary.dDrive)")
    $lines.Add("- PATH 缺失事实：$($Readiness.pathSummary.missing)")
    $lines.Add("")
    $lines.Add("## 工具更新准备")
    $lines.Add("")
    $lines.Add("| 工具 | 位置类型 | 事实归属 | 当前入口 | 官方更新入口 | 条件策略建议 | 风险 | 人工审查 | 不自动更新 |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    foreach ($item in $Readiness.toolReadiness) {
        $manual = if ($item.requiresManualReview) { "是" } else { "否" }
        $noAuto = if ($item.autoUpdateAllowed) { "否" } else { "是" }
        $lines.Add("| $(Escape-MarkdownCell $item.name) | $(Escape-MarkdownCell (Convert-LocationClassToDisplay $item.locationClass)) | $(Escape-MarkdownCell $item.originClass) | $(Escape-MarkdownCell $item.pathDisplay) | $(Escape-MarkdownCell $item.recommendedUpdateEntry) | $(Escape-MarkdownCell $item.recommendedAction) | $(Escape-MarkdownCell (Convert-RiskLevelToDisplay $item.riskLevel)) | $manual | $noAuto |")
    }
    $lines.Add("")
    $lines.Add("## PATH 整理建议")
    $lines.Add("")
    foreach ($recommendation in $Readiness.pathSummary.recommendations) { $lines.Add("- $recommendation") }
    if ($Readiness.pathSummary.missingEntries.Count -gt 0) {
        $lines.Add("")
        $lines.Add("### 缺失 PATH 入口")
        $lines.Add("")
        $lines.Add("| 序号 | 路径 | 项目本地环境入口 | 建议动作 |")
        $lines.Add("| --- | --- | --- | --- |")
        foreach ($entry in $Readiness.pathSummary.missingEntries) {
            $local = if ($entry.isProjectLocalEnvEntry) { "是" } else { "否" }
            $lines.Add("| $($entry.index) | $(Escape-MarkdownCell $entry.path) | $local | $(Escape-MarkdownCell $entry.recommendedAction) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 高风险对象")
    $lines.Add("")
    if ($Readiness.highRiskItems.Count -eq 0) { $lines.Add("无。") } else {
        $lines.Add("| 工具 | 路径 | 原因 |")
        $lines.Add("| --- | --- | --- |")
        foreach ($item in $Readiness.highRiskItems) { $lines.Add("| $(Escape-MarkdownCell $item.name) | $(Escape-MarkdownCell $item.pathDisplay) | $(Escape-MarkdownCell $item.recommendedAction) |") }
    }
    $lines.Add("")
    $lines.Add("## 策略")
    $lines.Add("")
    foreach ($rule in $Readiness.policy.rules) { $lines.Add("- $rule") }
    return @($lines) -join "`n"
}

# 输入事实必须在任何 OutputDir 创建或覆盖之前完成严格校验。
$trustedInventoryPath = Assert-ReadinessInputFile -Path $InventoryPath
$effectiveInventoryMarkdownPath = if ([string]::IsNullOrWhiteSpace($InventoryMarkdownPath)) {
    Join-Path ([IO.Path]::GetDirectoryName($trustedInventoryPath)) "REPORT.md"
} else {
    $InventoryMarkdownPath
}
$trustedInventoryMarkdownPath = Assert-ReadinessInputFile -Path $effectiveInventoryMarkdownPath
$inventoryPair = Test-JsonMarkdownArtifactPair -JsonPath $trustedInventoryPath -MarkdownPath $trustedInventoryMarkdownPath
if (-not $inventoryPair.ok) { throw "Inventory JSON/Markdown pair 校验失败：$($inventoryPair.error)" }
$inventoryText = [IO.File]::ReadAllText($trustedInventoryPath)
$inventory = $inventoryText | ConvertFrom-Json -DateKind String -ErrorAction Stop
Assert-InventoryV3Document -Document $inventory
Assert-EnvSafeAbsolutePath -Path $OutputDir -FactName "OutputDir"

$toolReadiness = @($inventory.tools | Where-Object { $_.found -is [bool] -and $_.found } | ForEach-Object { Get-UpdatePolicy -Tool $_ })
$pathSummary = Get-ReadinessPathSummary -ProcessScope $inventory.pathScopes.process
$readiness = [pscustomobject][ordered]@{
    artifactType = "env-governance.update-readiness"
    schemaVersion = 3
    generatedAt = (Get-Date).ToString("o")
    readOnly = $true
    executionAllowed = $false
    inventoryPath = $trustedInventoryPath
    inventoryGeneratedAt = $inventory.generatedAt
    inventorySchemaVersion = 3
    toolReadiness = $toolReadiness
    pathSummary = $pathSummary
    highRiskItems = @($toolReadiness | Where-Object { $_.riskLevel -eq "high" })
    policy = [pscustomobject]@{
        autoUpdateAllowed = $false
        rules = @(
            "本项目只生成更新准备报告，不执行任何更新命令。",
            "位置、归属与探测结论只由共享条件策略生成；工具专属层只命名官方更新入口。",
            "系统组件、安装器管理目录和 WinGet 包只通过官方机制更新，不直接搬迁。",
            "项目本地环境、vendor runtime、未知归属或探测失败必须人工审查。",
            "只有完整的 Process PATH scope 才能生成缺失、重复或失效入口清理建议。"
        )
    }
}

$published = Publish-JsonMarkdownArtifactPair -Document $readiness -OutputDir $OutputDir -JsonFileName "readiness.json" -MarkdownFileName "REPORT.md" -RenderMarkdown {
    param($Document, $JsonSha256)
    Convert-ReadinessToMarkdown -Readiness $Document
}

[pscustomobject]@{
    readinessJson = $published.jsonPath
    readinessMarkdown = $published.markdownPath
    generationId = $published.generationId
    readOnly = $true
}
