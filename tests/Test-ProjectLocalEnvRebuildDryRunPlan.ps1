param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境",
    [switch]$KeepOutputs
)

$ErrorActionPreference = "Stop"

. (Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1")

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

function Assert-RejectedPreservingRebuildPair {
    param([string]$Label, [string]$OutputDir, [scriptblock]$Action, [string]$ExpectedPattern)
    $old = Publish-JsonMarkdownArtifactPair -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "sentinel" }) -OutputDir $OutputDir -JsonFileName "plan.json" -MarkdownFileName "PLAN.md" -RenderMarkdown { "old-rebuild" }
    $oldJson = [IO.File]::ReadAllText($old.jsonPath); $oldMarkdown = [IO.File]::ReadAllText($old.markdownPath)
    $rejected = $false; $message = $null; try { & $Action | Out-Null } catch { $rejected = $true; $message = $_.Exception.Message }
    Assert-True $rejected "$Label 必须拒绝"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPattern)) { Assert-True ($message -like $ExpectedPattern) "$Label 必须保留具体根因，期望 $ExpectedPattern，实际：$message" }
    Assert-True (([IO.File]::ReadAllText($old.jsonPath)) -ceq $oldJson -and ([IO.File]::ReadAllText($old.markdownPath)) -ceq $oldMarkdown) "$Label 不得覆盖旧下游 pair"
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
$reviewSourcePath = Join-Path $ProjectRoot "reports\project-local-env-review\review.json"
$reviewPath = $null
$testRoot = Join-Path $ProjectRoot "reports\project-local-env-rebuild-plan-test"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到项目本地环境重建 dry-run 计划脚本"
Assert-True -Condition (Test-Path -LiteralPath $reviewSourcePath -PathType Leaf) -Message "找不到项目本地环境审查包"

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    $reviewFixture = Get-Content -LiteralPath $reviewSourcePath -Raw | ConvertFrom-Json -DateKind String
    $reviewFixture | Add-Member -MemberType NoteProperty -Name artifactType -Value "env-governance.project-local-env-review" -Force
    foreach ($item in @($reviewFixture.items)) {
        $item | Add-Member -MemberType NoteProperty -Name rebuildEvidence -Value ([pscustomobject]@{ marker = $item.marker; projectFiles = [object[]]@($item.existingProjectFiles) }) -Force
    }
    $reviewInput = Publish-JsonMarkdownArtifactPair -Document $reviewFixture -OutputDir (Join-Path $testRoot "review-input") -JsonFileName "review.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { "review fixture" }
    $reviewPath = $reviewInput.jsonPath

    $result = & $scriptPath -ReviewPath $reviewPath -OutputDir $testRoot
    Assert-True -Condition ([bool]$result.dryRun) -Message "脚本没有返回 dryRun=true"
    Assert-True -Condition ([bool]$result.readOnly) -Message "脚本没有返回 readOnly=true"

    $jsonPath = Join-Path $testRoot "plan.json"
    $markdownPath = Join-Path $testRoot "PLAN.md"
    Assert-True -Condition (Test-Path -LiteralPath $jsonPath -PathType Leaf) -Message "缺少 plan.json"
    Assert-True -Condition (Test-Path -LiteralPath $markdownPath -PathType Leaf) -Message "缺少 PLAN.md"

    $pair = Test-JsonMarkdownArtifactPair -JsonPath $jsonPath -MarkdownPath $markdownPath
    Assert-True -Condition $pair.ok -Message "重建计划 JSON/Markdown 报告对校验失败：$(@($pair.errors) -join '; ')"

    $plan = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json
    $reviewItems = @($review.items)
    Assert-True -Condition ($review.artifactType -ceq "env-governance.project-local-env-review") -Message "测试 review artifactType 非法"

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

    $reviewMarkdownPath = Join-Path ([IO.Path]::GetDirectoryName($reviewPath)) "REPORT.md"
    $heldReviewMarkdownPath = Join-Path $testRoot "held-review-report.md"
    $missingPairOutput = Join-Path $testRoot "missing-review-pair-output"
    $oldPair = Publish-JsonMarkdownArtifactPair -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "sentinel" }) -OutputDir $missingPairOutput -JsonFileName "plan.json" -MarkdownFileName "PLAN.md" -RenderMarkdown { "old-rebuild-plan" }
    $oldJson = [IO.File]::ReadAllText($oldPair.jsonPath)
    $oldMarkdown = [IO.File]::ReadAllText($oldPair.markdownPath)
    Move-Item -LiteralPath $reviewMarkdownPath -Destination $heldReviewMarkdownPath
    $missingPairRejected = $false
    try {
        & $scriptPath -ReviewPath $reviewPath -OutputDir $missingPairOutput | Out-Null
    } catch {
        $missingPairRejected = $true
    } finally {
        Move-Item -LiteralPath $heldReviewMarkdownPath -Destination $reviewMarkdownPath
    }
    Assert-True -Condition $missingPairRejected -Message "缺失 review Markdown 必须拒绝 rebuild 生成"
    Assert-True -Condition (([IO.File]::ReadAllText($oldPair.jsonPath)) -ceq $oldJson -and ([IO.File]::ReadAllText($oldPair.markdownPath)) -ceq $oldMarkdown) -Message "缺失 review Markdown 不得覆盖旧 rebuild pair"

    $originalReviewMarkdown = [IO.File]::ReadAllText($reviewMarkdownPath)
    $tamperedReviewMarkdown = [regex]::Replace($originalReviewMarkdown, '(?m)^sourceJsonSha256: .+$', 'sourceJsonSha256: 0000000000000000000000000000000000000000000000000000000000000000')
    [IO.File]::WriteAllText($reviewMarkdownPath, $tamperedReviewMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-RejectedPreservingRebuildPair "review Markdown hash 篡改" (Join-Path $testRoot "rebuild-hash-output") { & $scriptPath -ReviewPath $reviewPath -ReviewMarkdownPath $reviewMarkdownPath -OutputDir (Join-Path $testRoot "rebuild-hash-output") } '*sourceJsonSha256*'
    [IO.File]::WriteAllText($reviewMarkdownPath, $originalReviewMarkdown, [Text.UTF8Encoding]::new($false))
    $mismatchedMarkdown = [regex]::Replace($originalReviewMarkdown, '(?m)^generationId: .+$', 'generationId: 00000000-0000-0000-0000-000000000000')
    [IO.File]::WriteAllText($reviewMarkdownPath, $mismatchedMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-RejectedPreservingRebuildPair "review generationId 错配" (Join-Path $testRoot "rebuild-generation-output") { & $scriptPath -ReviewPath $reviewPath -ReviewMarkdownPath $reviewMarkdownPath -OutputDir (Join-Path $testRoot "rebuild-generation-output") } '*generationId*'
    [IO.File]::WriteAllText($reviewMarkdownPath, $originalReviewMarkdown, [Text.UTF8Encoding]::new($false))
    foreach ($leaf in @(@{ path = $reviewPath; label = 'JSON' }, @{ path = $reviewMarkdownPath; label = 'Markdown' })) {
        $held = "$($leaf.path).held"; $target = Join-Path $testRoot "rebuild-junction-target-$($leaf.label)"; New-Item -ItemType Directory -Path $target -Force | Out-Null
        Move-Item -LiteralPath $leaf.path -Destination $held
        try {
            New-Item -ItemType Junction -Path $leaf.path -Target $target | Out-Null
            Assert-RejectedPreservingRebuildPair "review $($leaf.label) junction" (Join-Path $testRoot "rebuild-junction-output-$($leaf.label)") { & $scriptPath -ReviewPath $reviewPath -ReviewMarkdownPath $reviewMarkdownPath -OutputDir (Join-Path $testRoot "rebuild-junction-output-$($leaf.label)") }
        } finally {
            if (Test-Path -LiteralPath $leaf.path) { Remove-Item -LiteralPath $leaf.path -Force }
            Move-Item -LiteralPath $held -Destination $leaf.path
        }
    }

    $invalidReviewCases = @(
        @{ name = "wrong-artifact"; mutate = { param($d) $d.artifactType = "forged" } },
        @{ name = "string-schema"; mutate = { param($d) $d.schemaVersion = "2" } },
        @{ name = "items-scalar"; mutate = { param($d) $d.items = "bad" } },
        @{ name = "path-scalar"; mutate = { param($d) $d.items[0].path = 42 } },
        @{ name = "classification-scalar"; mutate = { param($d) $d.items[0].classification = 42 } },
        @{ name = "classification-banana"; mutate = { param($d) $d.items[0].classification = "banana" } },
        @{ name = "coordination-disguise"; mutate = { param($d) $d.items[0].parentProject = $d.items[0].project } },
        @{ name = "marker-path-mismatch"; mutate = { param($d) $d.items[0].marker = ".venv"; $d.items[0].rebuildEvidence.marker = ".venv" } },
        @{ name = "risk-boolean-inconsistent"; mutate = { param($d) $d.items[0].isLongRunningOrStateful = $true; $d.items[0].riskLevel = "medium" } },
        @{ name = "owner-boolean-inconsistent"; mutate = { param($d) $d.items[0].requiresOwnerDecision = -not [bool]$d.items[0].requiresOwnerDecision } },
        @{ name = "automation-true"; mutate = { param($d) $d.items[0].automationAllowed = $true } },
        @{ name = "assessment-tamper"; mutate = { param($d) $d.items[0].rebuildAssessment = "可重建：banana" } },
        @{ name = "missing-rebuild-evidence"; mutate = { param($d) $d.items[0].PSObject.Properties.Remove("rebuildEvidence") } },
        @{ name = "rebuild-files-scalar"; mutate = { param($d) $d.items[0].rebuildEvidence.projectFiles = "package-lock.json" } }
    )
    foreach ($case in $invalidReviewCases) {
        $invalid = $review | ConvertTo-Json -Depth 30 | ConvertFrom-Json -DateKind String
        & $case.mutate $invalid
        $input = Publish-JsonMarkdownArtifactPair -Document $invalid -OutputDir (Join-Path $testRoot "invalid-input-$($case.name)") -JsonFileName "review.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { "invalid but paired" }
        $output = Join-Path $testRoot "invalid-output-$($case.name)"
        $sentinel = Publish-JsonMarkdownArtifactPair -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "sentinel" }) -OutputDir $output -JsonFileName "plan.json" -MarkdownFileName "PLAN.md" -RenderMarkdown { "old-rebuild" }
        $sentinelJson = [IO.File]::ReadAllText($sentinel.jsonPath); $sentinelMarkdown = [IO.File]::ReadAllText($sentinel.markdownPath)
        $rejected = $false
        try { & $scriptPath -ReviewPath $input.jsonPath -ReviewMarkdownPath $input.markdownPath -OutputDir $output | Out-Null } catch { $rejected = $true }
        Assert-True -Condition $rejected -Message "rebuild 未拒绝严格合同反例：$($case.name)"
        Assert-True -Condition (([IO.File]::ReadAllText($sentinel.jsonPath)) -ceq $sentinelJson -and ([IO.File]::ReadAllText($sentinel.markdownPath)) -ceq $sentinelMarkdown) -Message "严格合同失败不得覆盖旧pair：$($case.name)"
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
