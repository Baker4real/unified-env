param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境",
    [switch]$KeepOutputs
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Property {
    param(
        [object]$Object,
        [string]$Name
    )

    $hasProperty = $Object.PSObject.Properties.Name -contains $Name
    Assert-True -Condition $hasProperty -Message "缺少属性：$Name"
}

function New-MarkerKey {
    param([object]$Item)

    "$($Item.project)|$($Item.marker)|$($Item.path)"
}

$scriptPath = Join-Path $ProjectRoot "scripts\New-ProjectLocalEnvReviewPack.ps1"
$inventoryPath = Join-Path $ProjectRoot "reports\env-inventory\inventory.json"
$testRoot = Join-Path $ProjectRoot "reports\project-local-env-review-test"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到项目本地环境审查包脚本"
Assert-True -Condition (Test-Path -LiteralPath $inventoryPath -PathType Leaf) -Message "找不到 inventory.json"

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    $result = & $scriptPath -InventoryPath $inventoryPath -OutputDir $testRoot
    Assert-True -Condition ([bool]$result.readOnly) -Message "审查包脚本没有返回 readOnly=true"

    $jsonPath = Join-Path $testRoot "review.json"
    $markdownPath = Join-Path $testRoot "REPORT.md"
    Assert-True -Condition (Test-Path -LiteralPath $jsonPath -PathType Leaf) -Message "缺少 review.json"
    Assert-True -Condition (Test-Path -LiteralPath $markdownPath -PathType Leaf) -Message "缺少 REPORT.md"

    $review = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $inventoryMarkers = @($inventory.projectEnvironmentMarkers)
    foreach ($property in @("readOnly", "inventoryPath", "items", "policy", "summary")) {
        Assert-Property -Object $review -Name $property
    }

    Assert-True -Condition ([bool]$review.readOnly) -Message "review JSON 的 readOnly 不是 true"
    Assert-True -Condition (-not [bool]$review.policy.autoMigrationAllowed) -Message "项目本地环境不应允许自动迁移"
    Assert-True -Condition ($review.items.Count -eq $inventoryMarkers.Count) -Message "审查项数量必须与 inventory.projectEnvironmentMarkers 精确一致"

    $inventoryKeys = @{}
    foreach ($marker in $inventoryMarkers) {
        $key = New-MarkerKey -Item $marker
        Assert-True -Condition (-not $inventoryKeys.ContainsKey($key)) -Message "inventory 中存在重复项目本地环境标记：$key"
        $inventoryKeys[$key] = $true
    }

    $reviewKeys = @{}
    foreach ($item in $review.items) {
        $key = New-MarkerKey -Item $item
        Assert-True -Condition $inventoryKeys.ContainsKey($key) -Message "审查项不是从 inventory 标记生成：$key"
        Assert-True -Condition (-not $reviewKeys.ContainsKey($key)) -Message "审查包中存在重复项目本地环境标记：$key"
        $reviewKeys[$key] = $true
    }

    foreach ($item in $review.items) {
        foreach ($property in @("project", "parentProject", "classification", "marker", "path", "recommendedAction", "automationAllowed", "rebuildAssessment", "verificationPrerequisites", "riskLevel")) {
            Assert-Property -Object $item -Name $property
        }

        Assert-True -Condition (-not [bool]$item.automationAllowed) -Message "$($item.path) 不应允许自动处理"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($item.recommendedAction)) -Message "$($item.path) 缺少建议动作"
        $decisionText = "$($item.recommendedAction) $($item.rebuildAssessment)"
        $hasAllowedDecision = $decisionText.Contains("保留") -or
            $decisionText.Contains("可重建") -or
            $decisionText.Contains("owner 决策") -or
            $decisionText.Contains("禁止自动处理")
        Assert-True -Condition $hasAllowedDecision -Message "$($item.path) 建议动作不属于允许语义"
        Assert-True -Condition ($item.verificationPrerequisites.Count -gt 0) -Message "$($item.path) 缺少验证前置条件"
    }

    $nodeModules = $review.items | Where-Object { $_.marker -eq "node_modules" } | Select-Object -First 1
    Assert-True -Condition ($nodeModules.rebuildAssessment -like "*package-lock.json*") -Message "node_modules 审查项应识别 package-lock.json 重建线索"

    $gsdItems = @($review.items | Where-Object { ([string] $_.path).StartsWith("D:\Codex\.gsd\", [System.StringComparison]::OrdinalIgnoreCase) })
    Assert-True -Condition ($gsdItems.Count -eq 0) -Message "审查包不应把 .gsd 下内容当作普通 Codex 项目本地环境"

    $nestedApp = $review.items | Where-Object { $_.classification -eq "nested-app-local-env" -and $_.marker -eq "node_modules" } | Select-Object -First 1
    if ($nestedApp) {
        Assert-True -Condition ($nestedApp.classification -eq "nested-app-local-env") -Message "嵌套 app 审查分类错误"
        Assert-True -Condition (@("medium", "high") -contains $nestedApp.riskLevel) -Message "嵌套 app 风险等级应至少为 medium"
    }

    foreach ($excludedClassification in @("plugin-runtime-cache", "plugin-cache-backup", "archived-project-cache")) {
        $excludedItems = @($review.items | Where-Object { $_.classification -eq $excludedClassification })
        Assert-True -Condition ($excludedItems.Count -eq 0) -Message "$excludedClassification 不应进入项目本地环境审查包"
    }

    $serviceItems = @($review.items | Where-Object { $_.isLongRunningOrStateful })
    foreach ($serviceItem in $serviceItems) {
        Assert-True -Condition ([bool]$serviceItem.isLongRunningOrStateful) -Message "$($serviceItem.project) 应标为长期服务或状态敏感"
        Assert-True -Condition ($serviceItem.riskLevel -eq "high") -Message "$($serviceItem.project) 应标为 high 风险"
        Assert-True -Condition ((@($serviceItem.verificationPrerequisites) -join "`n").Contains("长期服务或状态敏感项目")) -Message "$($serviceItem.project) 缺少长期服务验证前置条件"
    }

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    foreach ($expected in @("只读", "默认不自动迁移", "不移动、不删除、不合并", "node_modules", "验证前置条件", "项目 owner 决策", "长期服务", "嵌套 app", "插件 runtime/cache")) {
        Assert-True -Condition $markdown.Contains($expected) -Message "REPORT.md 缺少预期文本：$expected"
    }
    foreach ($unexpected in @("ode_modules、", "| medium |", "| high |", "| low |")) {
        Assert-True -Condition (-not $markdown.Contains($unexpected)) -Message "REPORT.md 不应包含未转义或未本地化文本：$unexpected"
    }

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -InventoryPath $inventoryPath -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "审查包脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $blockedDOutput = "D:\Codex\project-local-env-review-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -InventoryPath $inventoryPath -OutputDir $blockedDOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于允许的报告目录*"
    }
    Assert-True -Condition $blocked -Message "审查包脚本没有阻止非授权 D 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedDOutput)) -Message "测试不应在非授权 D 盘目录创建输出目录"

    $leafGuardRoot = Join-Path $testRoot "leaf-reparse-guard"
    New-Item -ItemType Directory -Force -Path $leafGuardRoot | Out-Null
    $leafTarget = Join-Path $testRoot "leaf-target.json"
    Set-Content -LiteralPath $leafTarget -Value "{}" -Encoding UTF8
    $leafLink = Join-Path $leafGuardRoot "review.json"
    $leafLinkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $leafLink -Target $leafTarget -ErrorAction Stop | Out-Null
        $leafLinkCreated = $true
    } catch {
        $leafLinkCreated = $false
    }

    if ($leafLinkCreated) {
        $blocked = $false
        try {
            & $scriptPath -InventoryPath $inventoryPath -OutputDir $leafGuardRoot | Out-Null
        } catch {
            $blocked = $_.Exception.Message -like "*review.json 不能穿过*reparse point*"
        }
        Assert-True -Condition $blocked -Message "审查包脚本没有阻止最终输出文件 symlink/reparse point"
    }
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    reviewJson = $jsonPath
    reviewMarkdown = $markdownPath
}
