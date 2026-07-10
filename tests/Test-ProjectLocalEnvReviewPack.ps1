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
$inventoryScript = Join-Path $ProjectRoot "scripts\Invoke-EnvInventory.ps1"
$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$testRoot = Join-Path $ProjectRoot "reports\project-local-env-review-test"
$inventoryOutput = Join-Path $testRoot "inventory"
$reviewOutput = Join-Path $testRoot "review"
$reviewAfterMutationOutput = Join-Path $testRoot "review-after-mutation"
$inventoryPath = Join-Path $inventoryOutput "inventory.json"
$fixtureProject = Join-Path $testRoot "fixture-project"
$fixtureNodeModules = Join-Path $fixtureProject "node_modules"
$fixturePackageJson = Join-Path $fixtureProject "package.json"
$fixturePackageLock = Join-Path $fixtureProject "package-lock.json"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到项目本地环境审查包脚本"
Assert-True -Condition (Test-Path -LiteralPath $inventoryScript -PathType Leaf) -Message "找不到 inventory 脚本"
Assert-True -Condition (Test-Path -LiteralPath $publisherPath -PathType Leaf) -Message "找不到共享报告发布器"
. $publisherPath

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $fixtureNodeModules -Force | Out-Null
    Set-Content -LiteralPath $fixturePackageJson -Value '{"name":"fixture-project"}' -Encoding UTF8
    Set-Content -LiteralPath $fixturePackageLock -Value '{"lockfileVersion":3}' -Encoding UTF8

    & $inventoryScript -OutputDir $inventoryOutput -ProjectRoots @($fixtureProject) -SkipVersionProbe | Out-Null
    Assert-True -Condition (Test-Path -LiteralPath $inventoryPath -PathType Leaf) -Message "测试 inventory 未生成"

    $result = & $scriptPath -InventoryPath $inventoryPath -OutputDir $reviewOutput
    Assert-True -Condition ([bool]$result.readOnly) -Message "审查包脚本没有返回 readOnly=true"
    Assert-True -Condition ($result.generationId -match '^[0-9a-f-]{36}$') -Message "审查包未通过共享发布器生成 generationId"

    $jsonPath = Join-Path $reviewOutput "review.json"
    $markdownPath = Join-Path $reviewOutput "REPORT.md"
    Assert-True -Condition (Test-Path -LiteralPath $jsonPath -PathType Leaf) -Message "缺少 review.json"
    Assert-True -Condition (Test-Path -LiteralPath $markdownPath -PathType Leaf) -Message "缺少 REPORT.md"
    $pair = Test-JsonMarkdownArtifactPair -JsonPath $jsonPath -MarkdownPath $markdownPath
    Assert-True -Condition ([bool]$pair.ok) -Message "审查包 JSON/Markdown pair 校验失败：$($pair.error)"

    $review = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $inventoryMarkers = @($inventory.localEnvironmentFindings | Where-Object { $_.classification -in @("project-root-local-env", "nested-app-local-env") -and $_.owner -eq "project" })
    foreach ($finding in @($inventory.localEnvironmentFindings)) {
        foreach ($policyProperty in @("risk", "recommendation", "reason", "includeInReviewPack")) {
            Assert-True -Condition (-not ($finding.PSObject.Properties.Name -contains $policyProperty)) -Message "Inventory 本地环境事实不应包含策略字段 $policyProperty：$($finding.path)"
        }
        Assert-Property -Object $finding -Name "rebuildEvidence"
        Assert-True -Condition ($finding.rebuildEvidence.marker -ceq $finding.marker) -Message "rebuildEvidence.marker 必须与 finding.marker 一致：$($finding.path)"
        Assert-True -Condition ($finding.rebuildEvidence.projectFiles -is [array]) -Message "rebuildEvidence.projectFiles 必须是数组：$($finding.path)"
    }
    Assert-True -Condition (-not ($inventory.PSObject.Properties.Name -contains "projectEnvironmentMarkers")) -Message "Inventory 不应输出 projectEnvironmentMarkers 策略投影"
    foreach ($property in @("readOnly", "inventoryPath", "items", "policy", "summary")) {
        Assert-Property -Object $review -Name $property
    }

    Assert-True -Condition ([bool]$review.readOnly) -Message "review JSON 的 readOnly 不是 true"
    Assert-True -Condition (-not [bool]$review.policy.autoMigrationAllowed) -Message "项目本地环境不应允许自动迁移"
    Assert-True -Condition ($review.items.Count -eq $inventoryMarkers.Count) -Message "审查项数量必须与纳入审查的 inventory.localEnvironmentFindings 精确一致"

    $inventoryKeys = @{}
    foreach ($marker in $inventoryMarkers) {
        $key = New-MarkerKey -Item $marker
        Assert-True -Condition (-not $inventoryKeys.ContainsKey($key)) -Message "inventory facts 中存在重复项目本地环境标记：$key"
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

    Remove-Item -LiteralPath $fixturePackageLock -Force
    Set-Content -LiteralPath $fixturePackageJson -Value '{"name":"fixture-project","changed":true}' -Encoding UTF8
    & $scriptPath -InventoryPath $inventoryPath -OutputDir $reviewAfterMutationOutput | Out-Null
    $reviewAfterMutation = Get-Content -LiteralPath (Join-Path $reviewAfterMutationOutput "review.json") -Raw | ConvertFrom-Json
    Assert-True -Condition (($review.items | ConvertTo-Json -Depth 30) -ceq ($reviewAfterMutation.items | ConvertTo-Json -Depth 30)) -Message "同一 inventory 在项目文件变化后必须生成相同 review items"
    Assert-True -Condition (($review.summary | ConvertTo-Json -Depth 10) -ceq ($reviewAfterMutation.summary | ConvertTo-Json -Depth 10)) -Message "同一 inventory 在项目文件变化后必须生成相同 review summary"
    $reviewScriptText = Get-Content -LiteralPath $scriptPath -Raw
    Assert-True -Condition (-not $reviewScriptText.Contains("Get-ExistingProjectFiles")) -Message "review consumer 不得在 inventory 后实时探测项目文件"

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

    $localFactsOnlyInventory = ($inventory | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $legacyFalseIndex = -1
    for ($index = 0; $index -lt @($localFactsOnlyInventory.localEnvironmentFindings).Count; $index++) {
        $finding = $localFactsOnlyInventory.localEnvironmentFindings[$index]
        if ($finding.classification -in @("project-root-local-env", "nested-app-local-env") -and $finding.owner -eq "project") {
            $legacyFalseIndex = $index
            break
        }
    }
    Assert-True -Condition ($legacyFalseIndex -ge 0) -Message "测试 inventory 缺少可审查本地环境 fact"
    $localFactsOnlyInventory.localEnvironmentFindings[$legacyFalseIndex] | Add-Member -MemberType NoteProperty -Name includeInReviewPack -Value $false -Force
    $localFactsOnlyInventory.PSObject.Properties.Remove("projectEnvironmentMarkers")
    $localFactsOnlyPath = Join-Path $testRoot "local-findings-only-inventory.json"
    $localFactsOnlyInventory | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $localFactsOnlyPath -Encoding UTF8
    $localFactsOnlyOutput = Join-Path $testRoot "local-findings-only-review"
    & $scriptPath -InventoryPath $localFactsOnlyPath -OutputDir $localFactsOnlyOutput | Out-Null
    $localFactsOnlyReview = Get-Content -LiteralPath (Join-Path $localFactsOnlyOutput "review.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($localFactsOnlyReview.items.Count -eq $inventoryMarkers.Count) -Message "审查包必须按裸 facts 派生纳入；legacy includeInReviewPack=false 不得导致遗漏"

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
