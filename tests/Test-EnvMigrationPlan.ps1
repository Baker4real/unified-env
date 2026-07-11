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

function Assert-RejectedPreservingMigrationPair {
    param([string]$Label, [string]$OutputDir, [scriptblock]$Action, [string]$ExpectedPattern)
    $old = Publish-JsonMarkdownArtifactPair -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "sentinel" }) -OutputDir $OutputDir -JsonFileName "plan.json" -MarkdownFileName "PLAN.md" -RenderMarkdown { "old-plan" }
    $oldJson = [IO.File]::ReadAllText($old.jsonPath); $oldMarkdown = [IO.File]::ReadAllText($old.markdownPath)
    $rejected = $false; $message = $null; try { & $Action | Out-Null } catch { $rejected = $true; $message = $_.Exception.Message }
    Assert-True $rejected "$Label 必须拒绝"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPattern)) { Assert-True ($message -like $ExpectedPattern) "$Label 必须保留具体根因，期望 $ExpectedPattern，实际：$message" }
    Assert-True (([IO.File]::ReadAllText($old.jsonPath)) -ceq $oldJson -and ([IO.File]::ReadAllText($old.markdownPath)) -ceq $oldMarkdown) "$Label 不得覆盖旧下游 pair"
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
        Assert-True -Condition ((@($entry.validationSteps) -join "`n").Contains("重新生成 migration plan")) -Message "验证步骤应重新生成 migration plan"
        Assert-True -Condition (-not ((@($entry.validationSteps) -join "`n").Contains("inventory 不再把来源路径列为待处理迁移候选"))) -Message "验证步骤不得再依赖 inventory candidate"
        Assert-True -Condition ((@($entry.validationSteps) -join "`n").Contains("版本探测")) -Message "验证步骤必须包含工具版本探测"
        Assert-True -Condition ((@($entry.validationSteps) -join "`n").Contains("迁移前后 inventory 事实")) -Message "验证步骤必须包含迁移前后 inventory 事实对比"
        Assert-True -Condition ((@($entry.validationSteps) -join "`n").Contains("报告对比")) -Message "验证步骤必须包含报告对比"
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

    $inventoryMarkdownPath = Join-Path $inventoryOutput "REPORT.md"
    $heldInventoryMarkdownPath = Join-Path $testRoot "held-inventory-report.md"
    $missingPairOutput = Join-Path $testRoot "missing-inventory-pair-output"
    $oldPair = Publish-JsonMarkdownArtifactPair -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "sentinel" }) -OutputDir $missingPairOutput -JsonFileName "plan.json" -MarkdownFileName "PLAN.md" -RenderMarkdown { "old-plan" }
    $oldJson = [IO.File]::ReadAllText($oldPair.jsonPath)
    $oldMarkdown = [IO.File]::ReadAllText($oldPair.markdownPath)
    Move-Item -LiteralPath $inventoryMarkdownPath -Destination $heldInventoryMarkdownPath
    $missingPairRejected = $false
    try {
        & $planScript -InventoryPath $inventoryPath -OutputDir $missingPairOutput | Out-Null
    } catch {
        $missingPairRejected = $true
    } finally {
        Move-Item -LiteralPath $heldInventoryMarkdownPath -Destination $inventoryMarkdownPath
    }
    Assert-True -Condition $missingPairRejected -Message "缺失 inventory Markdown 必须拒绝"
    Assert-True -Condition (([IO.File]::ReadAllText($oldPair.jsonPath)) -ceq $oldJson -and ([IO.File]::ReadAllText($oldPair.markdownPath)) -ceq $oldMarkdown) -Message "缺失 inventory Markdown 不得覆盖旧迁移计划 pair"

    $originalInventoryMarkdown = [IO.File]::ReadAllText($inventoryMarkdownPath)
    $tamperedInventoryMarkdown = [regex]::Replace($originalInventoryMarkdown, '(?m)^sourceJsonSha256: .+$', 'sourceJsonSha256: 0000000000000000000000000000000000000000000000000000000000000000')
    [IO.File]::WriteAllText($inventoryMarkdownPath, $tamperedInventoryMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-RejectedPreservingMigrationPair "inventory Markdown hash 篡改" (Join-Path $testRoot "hash-tamper-output") { & $planScript -InventoryPath $inventoryPath -InventoryMarkdownPath $inventoryMarkdownPath -OutputDir (Join-Path $testRoot "hash-tamper-output") } '*sourceJsonSha256*'
    [IO.File]::WriteAllText($inventoryMarkdownPath, $originalInventoryMarkdown, [Text.UTF8Encoding]::new($false))
    $mismatchedMarkdown = [regex]::Replace($originalInventoryMarkdown, '(?m)^generationId: .+$', 'generationId: 00000000-0000-0000-0000-000000000000')
    [IO.File]::WriteAllText($inventoryMarkdownPath, $mismatchedMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-RejectedPreservingMigrationPair "inventory generationId 错配" (Join-Path $testRoot "generation-mismatch-output") { & $planScript -InventoryPath $inventoryPath -InventoryMarkdownPath $inventoryMarkdownPath -OutputDir (Join-Path $testRoot "generation-mismatch-output") } '*generationId*'
    [IO.File]::WriteAllText($inventoryMarkdownPath, $originalInventoryMarkdown, [Text.UTF8Encoding]::new($false))

    foreach ($leaf in @(@{ path = $inventoryPath; label = 'JSON' }, @{ path = $inventoryMarkdownPath; label = 'Markdown' })) {
        $held = "$($leaf.path).held"; $target = Join-Path $testRoot "junction-target-$($leaf.label)"; New-Item -ItemType Directory -Path $target -Force | Out-Null
        Move-Item -LiteralPath $leaf.path -Destination $held
        try {
            New-Item -ItemType Junction -Path $leaf.path -Target $target | Out-Null
            Assert-RejectedPreservingMigrationPair "inventory $($leaf.label) junction" (Join-Path $testRoot "junction-output-$($leaf.label)") { & $planScript -InventoryPath $inventoryPath -InventoryMarkdownPath $inventoryMarkdownPath -OutputDir (Join-Path $testRoot "junction-output-$($leaf.label)") }
        } finally {
            if (Test-Path -LiteralPath $leaf.path) { Remove-Item -LiteralPath $leaf.path -Force }
            Move-Item -LiteralPath $held -Destination $leaf.path
        }
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
        @{ name = "string-reparse"; mutate = { param($document) $document.directories[0].isReparsePoint = "false" } },
        @{ name = "directory-null-element"; mutate = { param($document) $document.directories = [object[]]@($null) } },
        @{ name = "directory-null-path"; mutate = { param($document) $document.directories[0].path = $null } },
        @{ name = "directory-scalar-category"; mutate = { param($document) $document.directories[0].category = 42 } },
        @{ name = "directory-duplicate-canonical-path"; mutate = { param($document) $duplicate = ($document.directories[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json); $duplicate.path = $document.directories[0].path.ToUpperInvariant().TrimEnd('\') + '\'; $document.directories = [object[]]@($document.directories + $duplicate) } },
        @{ name = "directory-device-namespace"; mutate = { param($document) $document.directories[0].path = '\\?\C:\Users\fixture\.cargo'; $document.directories[0].drive = '\\?\C:\' } },
        @{ name = "project-root-device-namespace"; mutate = { param($document) $document.projectRoots = [object[]]@('\\?\D:\Codex\projects') } },
        @{ name = "missing-project-root-facts"; mutate = { param($document) $document.PSObject.Properties.Remove("projectRootFacts") } },
        @{ name = "project-root-fact-bad-kind"; mutate = { param($document) $document.projectRootFacts[0].kind = "workspace" } },
        @{ name = "project-root-fact-device-namespace"; mutate = { param($document) $document.projectRootFacts[0].path = '\\??\D:\Codex\projects' } },
        @{ name = "project-root-compat-mismatch"; mutate = { param($document) $document.projectRoots[0] = "D:\Different" } },
        @{ name = "roots-not-array"; mutate = { param($document) $document.excludedRoots = "C:\Windows" } },
        @{ name = "root-scalar-element"; preserve = $true; mutate = { param($document) $document.excludedRoots = [object[]]@("C:\Windows") } },
        @{ name = "root-null-path"; preserve = $true; mutate = { param($document) $document.excludedRoots[0].path = $null } },
        @{ name = "root-missing-programdata"; preserve = $true; mutate = { param($document) $document.excludedRoots = @($document.excludedRoots | Where-Object { $_.path -ne "C:\ProgramData" }) } },
        @{ name = "finding-scalar-element"; mutate = { param($document) $document.localEnvironmentFindings = [object[]]@("bad-finding") } },
        @{ name = "finding-null-path"; mutate = { param($document) $document.localEnvironmentFindings[0].path = $null } },
        @{ name = "finding-scalar-owner"; mutate = { param($document) $document.localEnvironmentFindings[0].owner = 42 } },
        @{ name = "finding-bad-classification"; mutate = { param($document) $document.localEnvironmentFindings[0].classification = "unknown" } },
        @{ name = "finding-missing-rebuild-evidence"; mutate = { param($document) $document.localEnvironmentFindings[0].PSObject.Properties.Remove("rebuildEvidence") } },
        @{ name = "finding-scalar-rebuild-evidence"; mutate = { param($document) $document.localEnvironmentFindings[0].rebuildEvidence = "package-lock.json" } },
        @{ name = "finding-rebuild-marker-mismatch"; mutate = { param($document) $document.localEnvironmentFindings[0].rebuildEvidence.marker = ".venv" } },
        @{ name = "finding-project-files-not-array"; mutate = { param($document) $document.localEnvironmentFindings[0].rebuildEvidence.projectFiles = "package-lock.json" } },
        @{ name = "finding-project-files-unknown"; mutate = { param($document) $document.localEnvironmentFindings[0].rebuildEvidence.projectFiles = [object[]]@("secrets.txt") } },
        @{ name = "finding-duplicate-canonical-path"; mutate = { param($document) $duplicate = ($document.localEnvironmentFindings[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json); $document.localEnvironmentFindings = [object[]]@($document.localEnvironmentFindings + $duplicate) } },
        @{ name = "finding-node-modules-plugin-masquerade"; mutate = { param($document) $finding = $document.localEnvironmentFindings | Where-Object { $_.marker -eq "node_modules" -and $_.classification -in @("project-root-local-env", "nested-app-local-env") } | Select-Object -First 1; $finding.classification = "plugin-runtime-cache"; $finding.scope = "plugin-runtime-cache"; $finding.owner = "plugin-runtime" } }
    )
    foreach ($case in $invalidCases) {
        $fixture = ($inventory | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        & $case.mutate $fixture
        $fixtureInput = Publish-JsonMarkdownArtifactPair -Document $fixture -OutputDir (Join-Path $testRoot "input-$($case.name)") -JsonFileName "inventory.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { "fixture inventory" }
        $fixturePath = $fixtureInput.jsonPath
        $invalidOutput = Join-Path $testRoot "invalid-$($case.name)"
        $sentinelJson = "old-json-$($case.name)"
        $sentinelMarkdown = "old-markdown-$($case.name)"
        if ([bool]$case.preserve) {
            New-Item -ItemType Directory -Path $invalidOutput -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $invalidOutput "plan.json") -Value $sentinelJson -NoNewline -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $invalidOutput "PLAN.md") -Value $sentinelMarkdown -NoNewline -Encoding UTF8
        }
        $failed = $false
        try {
            & $planScript -InventoryPath $fixturePath -InventoryMarkdownPath $fixtureInput.markdownPath -OutputDir $invalidOutput | Out-Null
        } catch {
            $failed = $true
        }
        Assert-True -Condition $failed -Message "迁移计划未拒绝非法 inventory：$($case.name)"
        if ([bool]$case.preserve) {
            Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $invalidOutput "plan.json") -Raw) -ceq $sentinelJson) -Message "非法 inventory 覆盖了旧 plan.json：$($case.name)"
            Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $invalidOutput "PLAN.md") -Raw) -ceq $sentinelMarkdown) -Message "非法 inventory 覆盖了旧 PLAN.md：$($case.name)"
        } else {
            Assert-True -Condition (-not (Test-Path -LiteralPath $invalidOutput)) -Message "非法 inventory 不得创建输出目录：$($case.name)"
        }
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
