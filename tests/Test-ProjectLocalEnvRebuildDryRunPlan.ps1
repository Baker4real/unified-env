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

function New-ReviewKey {
    param([object]$Item)

    "$($Item.project)|$($Item.marker)|$($Item.path)"
}

function Assert-CanRemoveTestRoot {
    param([string]$Path)

    $projectReportsRoot = Join-Path $ProjectRoot "reports"
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullReportsRoot = [System.IO.Path]::GetFullPath($projectReportsRoot).TrimEnd("\", "/")
    $isUnderReports = $fullPath.StartsWith("$fullReportsRoot\", [System.StringComparison]::OrdinalIgnoreCase)
    Assert-True -Condition $isUnderReports -Message "测试输出目录必须位于项目 reports 下：$Path"

    $current = $fullPath
    while ($current.StartsWith($fullReportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            Assert-True -Condition (-not $isReparse) -Message "测试输出路径不能穿过 junction、symlink 或 reparse point：$current"
        }

        if ($current.Equals($fullReportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($current)
        Assert-True -Condition ($null -ne $parent) -Message "无法解析测试输出目录父级：$current"
        $current = $parent.FullName.TrimEnd("\", "/")
    }

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        Assert-True -Condition (-not $isReparse) -Message "测试输出目录不能是 junction、symlink 或 reparse point：$Path"
    }
}

$scriptPath = Join-Path $ProjectRoot "scripts\New-ProjectLocalEnvRebuildDryRunPlan.ps1"
$reviewPath = Join-Path $ProjectRoot "reports\project-local-env-review\review.json"
$testRoot = Join-Path $ProjectRoot "reports\project-local-env-rebuild-plan-test"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到项目本地环境重建 dry-run 计划脚本"
Assert-True -Condition (Test-Path -LiteralPath $reviewPath -PathType Leaf) -Message "找不到项目本地环境审查包"

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    $result = & $scriptPath -ReviewPath $reviewPath -OutputDir $testRoot
    Assert-True -Condition ([bool]$result.dryRun) -Message "脚本没有返回 dryRun=true"
    Assert-True -Condition ([bool]$result.readOnly) -Message "脚本没有返回 readOnly=true"

    $jsonPath = Join-Path $testRoot "plan.json"
    $markdownPath = Join-Path $testRoot "PLAN.md"
    Assert-True -Condition (Test-Path -LiteralPath $jsonPath -PathType Leaf) -Message "缺少 plan.json"
    Assert-True -Condition (Test-Path -LiteralPath $markdownPath -PathType Leaf) -Message "缺少 PLAN.md"

    $plan = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json
    $reviewItems = @($review.items)

    foreach ($property in @("schemaVersion", "generatedAt", "dryRun", "readOnly", "reviewPath", "summary", "plans", "policy")) {
        Assert-Property -Object $plan -Name $property
    }

    Assert-True -Condition ([bool]$plan.dryRun) -Message "plan JSON 的 dryRun 不是 true"
    Assert-True -Condition ([bool]$plan.readOnly) -Message "plan JSON 的 readOnly 不是 true"
    Assert-True -Condition (-not [bool]$plan.policy.executionAllowed) -Message "计划不应允许执行"
    Assert-True -Condition (-not [bool]$plan.policy.deleteAllowed) -Message "计划不应允许删除"
    Assert-True -Condition (-not [bool]$plan.policy.migrationAllowed) -Message "计划不应允许迁移"
    Assert-True -Condition ($plan.plans.Count -eq $reviewItems.Count) -Message "计划项数量必须与 review.items 精确一致"

    $reviewKeys = @{}
    $reviewKeyOrder = @()
    foreach ($item in $reviewItems) {
        $key = New-ReviewKey -Item $item
        $reviewKeys[$key] = $true
        $reviewKeyOrder += $key
    }

    $planKeyOrder = @()
    foreach ($item in $plan.plans) {
        foreach ($property in @("project", "parentProject", "classification", "marker", "path", "planStatus", "executionAllowed", "requiresOwnerDecision", "riskLevel", "candidateCommands", "preflightChecks", "validationSteps", "rollbackPrerequisites", "humanGates")) {
            Assert-Property -Object $item -Name $property
        }

        $key = New-ReviewKey -Item $item
        $planKeyOrder += $key
        Assert-True -Condition $reviewKeys.ContainsKey($key) -Message "计划项不是从审查包生成：$key"
        Assert-True -Condition (-not [bool]$item.executionAllowed) -Message "$($item.path) 不应允许执行"
        Assert-True -Condition (@("planned-rebuild", "owner-decision-required", "blocked-no-rebuild-source") -contains $item.planStatus) -Message "$($item.path) 计划状态非法：$($item.planStatus)"
        Assert-True -Condition ($item.preflightChecks.Count -gt 0) -Message "$($item.path) 缺少前置检查"
        Assert-True -Condition ($item.validationSteps.Count -gt 0) -Message "$($item.path) 缺少验证步骤"
        Assert-True -Condition ($item.rollbackPrerequisites.Count -gt 0) -Message "$($item.path) 缺少回滚前置条件"
    }
    Assert-True -Condition ((($reviewKeyOrder -join "`n") -ceq ($planKeyOrder -join "`n"))) -Message "计划项顺序和数量必须与 review.items 完全一致"

    $gsdPlans = @($plan.plans | Where-Object { ([string] $_.path).StartsWith("D:\Codex\.gsd\", [System.StringComparison]::OrdinalIgnoreCase) })
    Assert-True -Condition ($gsdPlans.Count -eq 0) -Message "重建计划不应把 .gsd 下内容当作普通 Codex 项目本地环境"

    $nodePlan = $plan.plans | Where-Object { $_.marker -eq "node_modules" -and $_.planStatus -eq "planned-rebuild" } | Select-Object -First 1
    Assert-True -Condition ($null -ne $nodePlan) -Message "缺少可计划重建的 node_modules 计划"
    Assert-True -Condition ($nodePlan.planStatus -eq "planned-rebuild") -Message "package-lock 项目应可计划重建"
    Assert-True -Condition ((@($nodePlan.candidateCommands) -join "`n").Contains("npm ci")) -Message "node_modules 计划应包含 npm ci 候选命令"
    Assert-True -Condition ((@($nodePlan.candidateCommands) -join "`n").Contains("候选命令预览")) -Message "候选命令必须明确只是预览"

    $highRiskPlans = @($plan.plans | Where-Object { $_.riskLevel -eq "high" })
    foreach ($highRiskPlan in $highRiskPlans) {
        Assert-True -Condition ([bool]$highRiskPlan.requiresOwnerDecision) -Message "$($highRiskPlan.project) 高风险项目应需要 owner 决策"
        Assert-True -Condition ((@($highRiskPlan.humanGates) -join "`n").Contains("停机窗口")) -Message "$($highRiskPlan.project) 高风险项目缺少停机窗口 gate"
        Assert-True -Condition ((@($highRiskPlan.validationSteps) -join "`n").Contains("健康检查")) -Message "$($highRiskPlan.project) 高风险项目缺少健康检查"
    }

    $nestedAppPlan = $plan.plans | Where-Object { $_.classification -eq "nested-app-local-env" -and $_.marker -eq "node_modules" } | Select-Object -First 1
    if ($nestedAppPlan) {
        Assert-True -Condition ($nestedAppPlan.classification -eq "nested-app-local-env") -Message "嵌套 app 计划分类错误"
        Assert-True -Condition (@("planned-rebuild", "owner-decision-required") -contains $nestedAppPlan.planStatus) -Message "嵌套 app 计划状态非法"
        Assert-True -Condition ([bool]$nestedAppPlan.requiresOwnerDecision) -Message "嵌套 app 仍需要 owner 决策"
    }

    foreach ($excludedClassification in @("plugin-runtime-cache", "plugin-cache-backup", "archived-project-cache")) {
        $excludedItems = @($plan.plans | Where-Object { $_.classification -eq $excludedClassification })
        Assert-True -Condition ($excludedItems.Count -eq 0) -Message "$excludedClassification 不应进入项目本地环境重建计划"
    }

    foreach ($reviewItem in $reviewItems) {
        $recognizedLockFiles = @("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "uv.lock", "poetry.lock", "Pipfile.lock", "environment.yml")
        $hasRecognizedLock = @($reviewItem.existingProjectFiles | Where-Object { $recognizedLockFiles -contains $_ }).Count -gt 0
        $matchingPlan = $plan.plans | Where-Object { (New-ReviewKey -Item $_) -eq (New-ReviewKey -Item $reviewItem) } | Select-Object -First 1
        if (-not $hasRecognizedLock) {
            Assert-True -Condition ($matchingPlan.candidateCommands.Count -eq 0) -Message "$($reviewItem.path) 缺少认可锁文件时不得输出候选重建命令"
        }
    }

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    foreach ($expected in @("DRY-RUN", "不执行", "不删除", "不迁移", "候选命令预览", "人工决策门", "回滚", "嵌套 app", "插件 runtime/cache")) {
        Assert-True -Condition $markdown.Contains($expected) -Message "PLAN.md 缺少预期文本：$expected"
    }
    if ($highRiskPlans.Count -gt 0) {
        foreach ($expected in @("停机窗口", "健康检查")) {
            Assert-True -Condition $markdown.Contains($expected) -Message "PLAN.md 缺少高风险项目预期文本：$expected"
        }
    }

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -ReviewPath $reviewPath -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $blockedDOutput = "D:\Codex\project-local-env-rebuild-plan-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -ReviewPath $reviewPath -OutputDir $blockedDOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于允许的报告目录*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止非授权 D 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedDOutput)) -Message "测试不应在非授权 D 盘目录创建输出目录"
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-CanRemoveTestRoot -Path $testRoot
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    planJson = $jsonPath
    planMarkdown = $markdownPath
}
