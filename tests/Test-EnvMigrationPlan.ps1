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

$inventoryScript = Join-Path $ProjectRoot "scripts\Invoke-EnvInventory.ps1"
$planScript = Join-Path $ProjectRoot "scripts\New-EnvMigrationPlan.ps1"
$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$testRoot = Join-Path $ProjectRoot "reports\env-migration-plan-test"
$inventoryOutput = Join-Path $testRoot "inventory"
$planOutput = Join-Path $testRoot "plan"

Assert-True -Condition (Test-Path -Path $inventoryScript -PathType Leaf) -Message "找不到 inventory 脚本"
Assert-True -Condition (Test-Path -Path $planScript -PathType Leaf) -Message "找不到迁移计划脚本"
Assert-True -Condition (Test-Path -LiteralPath $publisherPath -PathType Leaf) -Message "找不到共享报告发布器"
. $publisherPath

try {
    if (Test-Path -Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $inventoryOutput | Out-Null
    New-Item -ItemType Directory -Force -Path $planOutput | Out-Null

    & $inventoryScript -OutputDir $inventoryOutput -SkipVersionProbe | Out-Null
    $inventoryPath = Join-Path $inventoryOutput "inventory.json"
    Assert-True -Condition (Test-Path -Path $inventoryPath -PathType Leaf) -Message "测试 inventory 未生成"
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    Assert-True -Condition (-not ($inventory.PSObject.Properties.Name -contains "migrationCandidates")) -Message "迁移计划输入不应依赖 inventory.migrationCandidates"
    Assert-True -Condition (-not ($inventory.PSObject.Properties.Name -contains "manualReviewItems")) -Message "迁移计划输入不应依赖 inventory.manualReviewItems"

    $result = & $planScript -InventoryPath $inventoryPath -OutputDir $planOutput
    Assert-True -Condition ([bool]$result.readOnly) -Message "计划脚本没有返回 readOnly=true"
    Assert-True -Condition ($result.generationId -match '^[0-9a-f-]{36}$') -Message "迁移计划未通过共享发布器生成 generationId"

    $planJsonPath = Join-Path $planOutput "plan.json"
    $planMarkdownPath = Join-Path $planOutput "PLAN.md"
    Assert-True -Condition (Test-Path -Path $planJsonPath -PathType Leaf) -Message "缺少 plan.json"
    Assert-True -Condition (Test-Path -Path $planMarkdownPath -PathType Leaf) -Message "缺少 PLAN.md"
    $pair = Test-JsonMarkdownArtifactPair -JsonPath $planJsonPath -MarkdownPath $planMarkdownPath
    Assert-True -Condition ([bool]$pair.ok) -Message "迁移计划 JSON/Markdown pair 校验失败：$($pair.error)"

    $plan = Get-Content -Path $planJsonPath -Raw | ConvertFrom-Json
    foreach ($property in @("readOnly", "inventoryPath", "migrationPlans", "blockedByRootPolicy", "blockedByManualReview", "excludedManualReviewItems", "excludedRoots")) {
        Assert-Property -Object $plan -Name $property
    }

    Assert-True -Condition ([bool]$plan.readOnly) -Message "plan JSON 的 readOnly 不是 true"
    Assert-True -Condition ($plan.inventoryPath -eq $inventoryPath) -Message "计划没有记录 inventory 路径"
    Assert-True -Condition (@($plan.excludedManualReviewItems).Count -ge @($inventory.localEnvironmentFindings).Count) -Message "迁移计划应从 localEnvironmentFindings 派生人工审查项"

    foreach ($entry in $plan.migrationPlans) {
        foreach ($property in @("source", "target", "risk", "preChecks", "executionSteps", "validationSteps", "rollbackSteps", "status", "executionAllowed", "requiresExplicitUserApproval", "rootPolicy")) {
            Assert-Property -Object $entry -Name $property
        }

        Assert-True -Condition ($entry.status -eq "dry-run-only") -Message "迁移计划不是 dry-run-only"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($entry.target)) -Message "迁移计划缺少目标路径"
        Assert-True -Condition ($entry.preChecks.Count -gt 0) -Message "迁移计划缺少前置检查"
        Assert-True -Condition ($entry.executionSteps.Count -gt 0) -Message "迁移计划缺少执行步骤"
        Assert-True -Condition ($entry.validationSteps.Count -gt 0) -Message "迁移计划缺少验证步骤"
        Assert-True -Condition ($entry.rollbackSteps.Count -gt 0) -Message "迁移计划缺少回滚步骤"
        Assert-True -Condition (-not [bool]$entry.executionAllowed) -Message "dry-run 计划不应允许直接执行"
        Assert-True -Condition ([bool]$entry.requiresExplicitUserApproval) -Message "迁移计划未要求显式授权"
    }

    $manualSources = @($plan.excludedManualReviewItems | ForEach-Object { $_.source })
    $plannedSources = @($plan.migrationPlans | ForEach-Object { $_.source })
    foreach ($source in $manualSources) {
        Assert-True -Condition (-not ($plannedSources -contains $source)) -Message "人工审查项进入了迁移计划：$source"
    }

    foreach ($entry in $plan.migrationPlans) {
        if ($entry.source -like "C:\Users\*") {
            Assert-True -Condition (-not [bool]$entry.executionAllowed) -Message "C:\Users 下候选不应直接允许执行"
            Assert-True -Condition ($entry.rootPolicy.decision -eq "targeted-cache-under-excluded-user-root") -Message "C:\Users 下缓存候选缺少 root policy 标记"
        }
    }

    $markdown = Get-Content -Path $planMarkdownPath -Raw
    foreach ($expected in @("DRY-RUN", "只读", "排除项")) {
        Assert-True -Condition $markdown.Contains($expected) -Message "PLAN.md 缺少预期文本：$expected"
    }

    if ($plan.migrationPlans.Count -gt 0) {
        foreach ($expected in @("前置检查", "执行步骤", "验证步骤", "回滚步骤", "Root policy")) {
            Assert-True -Condition $markdown.Contains($expected) -Message "PLAN.md 缺少预期文本：$expected"
        }
    } else {
        Assert-True -Condition $markdown.Contains("当前没有可生成 dry-run 计划的迁移候选") -Message "PLAN.md 缺少无候选说明"
    }

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $planScript -InventoryPath $inventoryPath -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "迁移计划脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -Path $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $invalidCases = @(
        @{ name = "wrong-artifact"; mutate = { param($document) $document.artifactType = "wrong.inventory" } },
        @{ name = "string-schema"; mutate = { param($document) $document.schemaVersion = "3" } },
        @{ name = "future-schema"; mutate = { param($document) $document.schemaVersion = 4 } },
        @{ name = "missing-directories"; mutate = { param($document) $document.PSObject.Properties.Remove("directories") } },
        @{ name = "missing-local-findings"; mutate = { param($document) $document.PSObject.Properties.Remove("localEnvironmentFindings") } },
        @{ name = "string-exists"; mutate = { param($document) $document.directories[0].exists = "false" } },
        @{ name = "string-reparse"; mutate = { param($document) $document.directories[0].isReparsePoint = "false" } }
    )
    foreach ($case in $invalidCases) {
        $fixture = ($inventory | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        & $case.mutate $fixture
        $fixturePath = Join-Path $testRoot "$($case.name).json"
        $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixturePath -Encoding UTF8
        $invalidOutput = Join-Path $testRoot "invalid-$($case.name)"
        $failed = $false
        try {
            & $planScript -InventoryPath $fixturePath -OutputDir $invalidOutput | Out-Null
        } catch {
            $failed = $true
        }
        Assert-True -Condition $failed -Message "迁移计划未拒绝非法 inventory：$($case.name)"
        Assert-True -Condition (-not (Test-Path -LiteralPath $invalidOutput)) -Message "非法 inventory 不得创建输出目录：$($case.name)"
    }
} finally {
    if (-not $KeepOutputs -and (Test-Path -Path $testRoot)) {
        Remove-Item -Path $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    planJson = $planJsonPath
    planMarkdown = $planMarkdownPath
}
