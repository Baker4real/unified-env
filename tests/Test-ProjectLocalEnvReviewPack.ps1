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

function Assert-RejectedPreservingReviewPair {
    param([string]$Label, [string]$OutputDir, [scriptblock]$Action, [string]$ExpectedPattern)
    $old = Publish-JsonMarkdownArtifactPair -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "sentinel" }) -OutputDir $OutputDir -JsonFileName "review.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { "old-review" }
    $oldJson = [IO.File]::ReadAllText($old.jsonPath); $oldMarkdown = [IO.File]::ReadAllText($old.markdownPath)
    $rejected = $false; $message = $null; try { & $Action | Out-Null } catch { $rejected = $true; $message = $_.Exception.Message }
    Assert-True $rejected "$Label 必须拒绝"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPattern)) { Assert-True ($message -like $ExpectedPattern) "$Label 必须保留具体根因，期望 $ExpectedPattern，实际：$message" }
    Assert-True (([IO.File]::ReadAllText($old.jsonPath)) -ceq $oldJson -and ([IO.File]::ReadAllText($old.markdownPath)) -ceq $oldMarkdown) "$Label 不得覆盖旧下游 pair"
}

function New-MarkerKey {
    param([object]$Item)

    "$($Item.project)|$($Item.marker)|$($Item.path)"
}

$scriptPath = Join-Path $ProjectRoot "scripts\New-ProjectLocalEnvReviewPack.ps1"
$inventoryScript = Join-Path $ProjectRoot "scripts\Invoke-EnvInventory.ps1"
$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$migrationPolicyPath = Join-Path $ProjectRoot "scripts\lib\EnvMigrationPolicy.ps1"
$testRoot = Join-Path $ProjectRoot ("reports\project-local-env-review-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$inventoryOutput = Join-Path $testRoot "inventory"
$reviewOutput = Join-Path $testRoot "review"
$reviewAfterMutationOutput = Join-Path $testRoot "review-after-mutation"
$inventoryPath = Join-Path $inventoryOutput "inventory.json"
$fixtureWorkspace = Join-Path $testRoot "fixture-workspace"
$fixtureProject = Join-Path $fixtureWorkspace "app"
$fixtureFooProject = Join-Path $fixtureWorkspace "foo"
$fixtureWebProject = Join-Path $fixtureWorkspace "apps\web"
$fixturePluginProject = Join-Path $fixtureWorkspace "plugins\cache\fixture-plugin"
$fixtureNodeModules = Join-Path $fixtureProject "node_modules"
$fixtureFooNodeModules = Join-Path $fixtureFooProject "node_modules"
$fixtureWebNodeModules = Join-Path $fixtureWebProject "node_modules"
$fixturePluginNodeModules = Join-Path $fixturePluginProject "node_modules"
$fixturePackageJson = Join-Path $fixtureProject "package.json"
$fixturePackageLock = Join-Path $fixtureProject "package-lock.json"
$fixtureWebPackageJson = Join-Path $fixtureWebProject "package.json"
$fixtureWebPackageLock = Join-Path $fixtureWebProject "package-lock.json"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到项目本地环境审查包脚本"
Assert-True -Condition (Test-Path -LiteralPath $inventoryScript -PathType Leaf) -Message "找不到 inventory 脚本"
Assert-True -Condition (Test-Path -LiteralPath $publisherPath -PathType Leaf) -Message "找不到共享报告发布器"
. $publisherPath
. $migrationPolicyPath

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $fixtureNodeModules -Force | Out-Null
    New-Item -ItemType Directory -Path $fixtureFooNodeModules -Force | Out-Null
    New-Item -ItemType Directory -Path $fixtureWebNodeModules -Force | Out-Null
    New-Item -ItemType Directory -Path $fixturePluginNodeModules -Force | Out-Null
    Set-Content -LiteralPath $fixturePackageJson -Value '{"name":"fixture-project"}' -Encoding UTF8
    Set-Content -LiteralPath $fixturePackageLock -Value '{"lockfileVersion":3}' -Encoding UTF8
    Set-Content -LiteralPath $fixtureWebPackageJson -Value '{"name":"fixture-web-project"}' -Encoding UTF8
    Set-Content -LiteralPath $fixtureWebPackageLock -Value '{"lockfileVersion":3}' -Encoding UTF8

    $projectRootFacts = [object[]]@(
        [pscustomobject]@{ path = $fixtureWorkspace; kind = "collection" },
        [pscustomobject]@{ path = $fixtureProject; kind = "project" },
        [pscustomobject]@{ path = $fixturePluginProject; kind = "project" }
    )
    & $inventoryScript -OutputDir $inventoryOutput -ProjectRootFacts $projectRootFacts -SkipVersionProbe | Out-Null
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

    $review = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -DateKind String
    Assert-ProjectLocalReviewDocument -Review $review
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $inventoryPair = Test-JsonMarkdownArtifactPair -JsonPath $inventoryPath -MarkdownPath (Join-Path $inventoryOutput "REPORT.md")
    Assert-True -Condition ($review.sourceInventoryGenerationId -ceq $inventoryPair.generationId) -Message "review 未绑定 source inventory generationId"
    Assert-True -Condition ($review.sourceInventoryJsonSha256 -ceq $inventoryPair.sourceJsonSha256) -Message "review 未绑定 source inventory JSON SHA-256"
    $inventoryMarkers = @($inventory.localEnvironmentFindings | Where-Object { $_.classification -in @("project-root-local-env", "nested-app-local-env") -and $_.owner -eq "project" })
    Assert-True -Condition ($review.artifactType -ceq "env-governance.project-local-env-review") -Message "review artifactType 不正确"
    $appFinding = $inventoryMarkers | Where-Object { $_.path -ieq $fixtureNodeModules } | Select-Object -First 1
    Assert-True -Condition ($null -ne $appFinding) -Message "overlapping roots 下缺少 app node_modules finding"
    Assert-True -Condition ($appFinding.parentProject -ieq $fixtureProject -and $appFinding.project -ieq $fixtureProject) -Message "app marker 必须选择最具体显式 app root"
    Assert-True -Condition ($appFinding.classification -eq "project-root-local-env" -and $appFinding.scope -eq "project-root") -Message "app marker 分类必须与最具体显式 root 一致"
    $fooFinding = $inventoryMarkers | Where-Object { $_.path -ieq $fixtureFooNodeModules } | Select-Object -First 1
    Assert-True -Condition ($null -ne $fooFinding) -Message "collection root 下缺少直接子项目 finding"
    Assert-True -Condition ($fooFinding.parentProject -ieq $fixtureFooProject -and $fooFinding.project -ieq $fixtureFooProject) -Message "collection root 不得直接绑定其子项目 marker；top project 应为 foo"
    Assert-True -Condition ($fooFinding.classification -eq "project-root-local-env" -and $fooFinding.scope -eq "project-root") -Message "collection root 直接子项目必须分类为 project-root"
    $webFinding = $inventoryMarkers | Where-Object { $_.path -ieq $fixtureWebNodeModules } | Select-Object -First 1
    Assert-True -Condition ($null -ne $webFinding) -Message "workspace 深层 web node_modules finding 缺失"
    Assert-True -Condition ($webFinding.parentProject -ieq (Join-Path $fixtureWorkspace "apps") -and $webFinding.project -ieq $fixtureWebProject) -Message "collection root 深层 web marker 必须归属于第一层 top project"
    Assert-True -Condition ($webFinding.classification -eq "nested-app-local-env" -and $webFinding.scope -eq "nested-app") -Message "web marker 分类必须与 workspace root 一致"
    $pluginFinding = $inventory.localEnvironmentFindings | Where-Object { $_.path -ieq $fixturePluginNodeModules } | Select-Object -First 1
    Assert-True -Condition ($null -ne $pluginFinding) -Message "特殊 plugin cache finding 缺失"
    Assert-True -Condition ($pluginFinding.classification -eq "plugin-runtime-cache" -and $pluginFinding.owner -eq "plugin-runtime") -Message "特殊路径分类必须优先于更窄显式 project root"
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
    Assert-True -Condition ($review.summary.totalItems -eq 3 -and $review.summary.nestedAppItems -eq 1) -Message "review summary 必须与 collection/project root 分类一致且排除 plugin cache"

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

    $inventoryMarkdownPath = Join-Path $inventoryOutput "REPORT.md"
    $heldInventoryMarkdownPath = Join-Path $testRoot "held-review-inventory-report.md"
    $missingPairOutput = Join-Path $testRoot "missing-review-input-pair-output"
    $oldPair = Publish-JsonMarkdownArtifactPair -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "sentinel" }) -OutputDir $missingPairOutput -JsonFileName "review.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { "old-review" }
    $oldJson = [IO.File]::ReadAllText($oldPair.jsonPath)
    $oldMarkdown = [IO.File]::ReadAllText($oldPair.markdownPath)
    Move-Item -LiteralPath $inventoryMarkdownPath -Destination $heldInventoryMarkdownPath
    $missingPairRejected = $false
    try {
        & $scriptPath -InventoryPath $inventoryPath -OutputDir $missingPairOutput | Out-Null
    } catch {
        $missingPairRejected = $true
    } finally {
        Move-Item -LiteralPath $heldInventoryMarkdownPath -Destination $inventoryMarkdownPath
    }
    Assert-True -Condition $missingPairRejected -Message "缺失 inventory Markdown 必须拒绝 review 生成"
    Assert-True -Condition (([IO.File]::ReadAllText($oldPair.jsonPath)) -ceq $oldJson -and ([IO.File]::ReadAllText($oldPair.markdownPath)) -ceq $oldMarkdown) -Message "缺失 inventory Markdown 不得覆盖旧 review pair"

    $originalInventoryMarkdown = [IO.File]::ReadAllText($inventoryMarkdownPath)
    $tamperedInventoryMarkdown = [regex]::Replace($originalInventoryMarkdown, '(?m)^sourceJsonSha256: .+$', 'sourceJsonSha256: 0000000000000000000000000000000000000000000000000000000000000000')
    [IO.File]::WriteAllText($inventoryMarkdownPath, $tamperedInventoryMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-RejectedPreservingReviewPair "review inventory Markdown hash 篡改" (Join-Path $testRoot "review-hash-output") { & $scriptPath -InventoryPath $inventoryPath -InventoryMarkdownPath $inventoryMarkdownPath -OutputDir (Join-Path $testRoot "review-hash-output") } '*sourceJsonSha256*'
    [IO.File]::WriteAllText($inventoryMarkdownPath, $originalInventoryMarkdown, [Text.UTF8Encoding]::new($false))
    $mismatchedMarkdown = [regex]::Replace($originalInventoryMarkdown, '(?m)^generationId: .+$', 'generationId: 00000000-0000-0000-0000-000000000000')
    [IO.File]::WriteAllText($inventoryMarkdownPath, $mismatchedMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-RejectedPreservingReviewPair "review inventory generationId 错配" (Join-Path $testRoot "review-generation-output") { & $scriptPath -InventoryPath $inventoryPath -InventoryMarkdownPath $inventoryMarkdownPath -OutputDir (Join-Path $testRoot "review-generation-output") } '*generationId*'
    [IO.File]::WriteAllText($inventoryMarkdownPath, $originalInventoryMarkdown, [Text.UTF8Encoding]::new($false))
    foreach ($leaf in @(@{ path = $inventoryPath; label = 'JSON' }, @{ path = $inventoryMarkdownPath; label = 'Markdown' })) {
        $held = "$($leaf.path).held"; $target = Join-Path $testRoot "review-junction-target-$($leaf.label)"; New-Item -ItemType Directory -Path $target -Force | Out-Null
        Move-Item -LiteralPath $leaf.path -Destination $held
        try {
            New-Item -ItemType Junction -Path $leaf.path -Target $target | Out-Null
            Assert-RejectedPreservingReviewPair "review inventory $($leaf.label) junction" (Join-Path $testRoot "review-junction-output-$($leaf.label)") { & $scriptPath -InventoryPath $inventoryPath -InventoryMarkdownPath $inventoryMarkdownPath -OutputDir (Join-Path $testRoot "review-junction-output-$($leaf.label)") }
        } finally {
            if (Test-Path -LiteralPath $leaf.path) { Remove-Item -LiteralPath $leaf.path -Force }
            Move-Item -LiteralPath $held -Destination $leaf.path
        }
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
    $localFactsOnlyPair = Publish-JsonMarkdownArtifactPair -Document $localFactsOnlyInventory -OutputDir (Join-Path $testRoot "local-findings-only-input") -JsonFileName "inventory.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { "fixture inventory" }
    $localFactsOnlyPath = $localFactsOnlyPair.jsonPath
    $localFactsOnlyOutput = Join-Path $testRoot "local-findings-only-review"
    & $scriptPath -InventoryPath $localFactsOnlyPath -InventoryMarkdownPath $localFactsOnlyPair.markdownPath -OutputDir $localFactsOnlyOutput | Out-Null
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
