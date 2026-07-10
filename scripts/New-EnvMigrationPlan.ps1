param(
    [string]$InventoryPath = "D:\Codex\projects\统一环境\reports\env-inventory\inventory.json",
    [string]$OutputDir = "D:\Codex\projects\统一环境\reports\env-migration-plan"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\ReportArtifactPublisher.ps1")
. (Join-Path $PSScriptRoot "lib\EnvMigrationPolicy.ps1")

function Get-SafeSlug {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "unknown"
    }

    $slug = $Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    $slug = $slug.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "unknown"
    }

    return $slug
}

function Assert-DDrivePath {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$ParameterName 不能为空。"
    }

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    if ($root -ine "D:\") {
        throw "$ParameterName 必须位于 D:\ 下，当前值：$Path"
    }
}

function Get-TargetPath {
    param([object]$Candidate)

    $cacheRoot = "D:\Codex\.cache"
    $toolsRoot = "D:\Codex\tools"
    $envsRoot = "D:\Codex\envs"

    if ($Candidate.kind -eq "cache") {
        if ($Candidate.owner -eq "python" -and $Candidate.reason -like "*pip*") {
            return Join-Path $cacheRoot "pip"
        }

        $owner = Get-SafeSlug -Value $Candidate.owner
        return Join-Path $cacheRoot "$owner-cache"
    }

    if ($Candidate.kind -eq "tool-env") {
        $owner = Get-SafeSlug -Value $Candidate.owner
        if ($owner -in @("python", "node", "rust", "go", "dotnet", "java")) {
            return Join-Path $envsRoot $owner
        }

        return Join-Path $toolsRoot $owner
    }

    $kind = Get-SafeSlug -Value $Candidate.kind
    return Join-Path $envsRoot $kind
}

function New-MigrationPlanEntry {
    param(
        [object]$Candidate,
        [int]$Index,
        [object]$RootPolicy
    )

    $target = Get-TargetPath -Candidate $Candidate
    $id = "migration-{0:D2}-{1}-{2}" -f $Index, (Get-SafeSlug -Value $Candidate.owner), (Get-SafeSlug -Value $Candidate.kind)

    [pscustomobject]@{
        id = $id
        status = "dry-run-only"
        source = $Candidate.source
        target = $target
        kind = $Candidate.kind
        owner = $Candidate.owner
        risk = $Candidate.risk
        reason = $Candidate.reason
        executionAllowed = $RootPolicy.executionAllowed
        requiresExplicitUserApproval = $RootPolicy.requiresExplicitUserApproval
        rootPolicy = $RootPolicy
        preChecks = @(
            "确认 inventory 是最新生成的基线。",
            "确认来源路径存在且不是 reparse point、junction 或 symlink。",
            "确认目标路径位于 D 盘，并且不会覆盖已有非空目录。",
            "确认没有正在运行的进程写入来源路径。",
            "确认 root policy 允许继续；若命中不批量迁移根，必须取得显式授权。"
        )
        executionSteps = @(
            "创建目标目录：$target。",
            "复制来源内容到目标目录，保留原来源目录不删除。",
            "按工具官方方式切换配置或环境变量，指向目标目录。",
            "重新运行只读 inventory，确认新配置生效。"
        )
        validationSteps = @(
            "执行工具命令和版本探测，确认入口、版本与迁移前基线一致。",
            "对比迁移前后 inventory 事实，包括路径、归属、版本、reparse 状态和人工审查项。",
            "执行迁移前后报告对比，确认没有新增矛盾建议、缺失项或风险升级。",
            "重新生成 migration plan，确认来源路径不再列为待处理迁移候选。",
            "验证报告中没有新增人工审查风险。",
            "保留迁移证据和前后对比。"
        )
        rollbackSteps = @(
            "撤销新增配置或环境变量，恢复到迁移前值。",
            "重新运行只读 inventory，确认工具回到迁移前策略。",
            "确认目标目录不再被工具使用后，再人工决定是否删除目标副本。",
            "保留回滚证据。"
        )
    }
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function ConvertTo-MigrationPlanMarkdown {
    param(
        [object]$Plan
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 环境迁移 dry-run 计划")
    $lines.Add("")
    $lines.Add("生成时间：$($Plan.generatedAt)")
    $lines.Add("")
    $lines.Add("> DRY-RUN：本计划为只读迁移计划。生成过程没有移动文件、没有修改环境变量、没有执行更新。")
    $lines.Add("")
    $lines.Add("## 来源")
    $lines.Add("")
    $lines.Add("- inventory：$($Plan.inventoryPath)")
    $lines.Add("- inventory 生成时间：$($Plan.inventoryGeneratedAt)")
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add("- 可计划迁移项：$($Plan.migrationPlans.Count)")
    $lines.Add("- 排除的人工审查项：$($Plan.excludedManualReviewItems.Count)")
    $lines.Add("- 排除的根目录规则：$($Plan.excludedRoots.Count)")
    $lines.Add("")

    if ($Plan.migrationPlans.Count -eq 0) {
        $lines.Add("## 迁移计划")
        $lines.Add("")
        $lines.Add("当前没有可生成 dry-run 计划的迁移候选。")
    } else {
        $lines.Add("## 迁移计划")
        $lines.Add("")
        foreach ($entry in $Plan.migrationPlans) {
            $lines.Add("### $($entry.id)")
            $lines.Add("")
            $lines.Add("| 字段 | 值 |")
            $lines.Add("| --- | --- |")
            $lines.Add("| 来源 | $(Escape-MarkdownCell $entry.source) |")
            $lines.Add("| 目标 | $(Escape-MarkdownCell $entry.target) |")
            $lines.Add("| 类型 | $(Escape-MarkdownCell $entry.kind) |")
            $lines.Add("| 所属生态 | $(Escape-MarkdownCell $entry.owner) |")
            $lines.Add("| 风险 | $(Escape-MarkdownCell $entry.risk) |")
            $lines.Add("| 原因 | $(Escape-MarkdownCell $entry.reason) |")
            $lines.Add("| 允许执行 | $(Escape-MarkdownCell $entry.executionAllowed) |")
            $lines.Add("| 需要显式授权 | $(Escape-MarkdownCell $entry.requiresExplicitUserApproval) |")
            $lines.Add("| Root policy | $(Escape-MarkdownCell $entry.rootPolicy.decision) |")
            $lines.Add("| Root policy 说明 | $(Escape-MarkdownCell $entry.rootPolicy.note) |")
            $lines.Add("")

            foreach ($section in @(
                @{ Title = "前置检查"; Values = $entry.preChecks },
                @{ Title = "执行步骤"; Values = $entry.executionSteps },
                @{ Title = "验证步骤"; Values = $entry.validationSteps },
                @{ Title = "回滚步骤"; Values = $entry.rollbackSteps }
            )) {
                $lines.Add("#### $($section.Title)")
                $lines.Add("")
                foreach ($value in $section.Values) {
                    $lines.Add("- $value")
                }
                $lines.Add("")
            }
        }
    }

    $lines.Add("## 排除项")
    $lines.Add("")
    $lines.Add("### 被人工审查项阻止的候选")
    $lines.Add("")
    if ($Plan.blockedByManualReview.Count -eq 0) {
        $lines.Add("无。")
    } else {
        $lines.Add("| 来源 | 类型 | 风险 | 原因 |")
        $lines.Add("| --- | --- | --- | --- |")
        foreach ($item in $Plan.blockedByManualReview) {
            $lines.Add("| $(Escape-MarkdownCell $item.source) | $(Escape-MarkdownCell $item.kind) | $(Escape-MarkdownCell $item.risk) | $(Escape-MarkdownCell $item.reason) |")
        }
    }
    $lines.Add("")
    $lines.Add("### 人工审查项")
    $lines.Add("")
    if ($Plan.excludedManualReviewItems.Count -eq 0) {
        $lines.Add("无。")
    } else {
        $lines.Add("| 来源 | 类型 | 风险 | 原因 |")
        $lines.Add("| --- | --- | --- | --- |")
        foreach ($item in $Plan.excludedManualReviewItems) {
            $lines.Add("| $(Escape-MarkdownCell $item.source) | $(Escape-MarkdownCell $item.kind) | $(Escape-MarkdownCell $item.risk) | $(Escape-MarkdownCell $item.reason) |")
        }
    }
    $lines.Add("")
    $lines.Add("### 绝不自动迁移根")
    $lines.Add("")
    $lines.Add("| 路径 | 原因 |")
    $lines.Add("| --- | --- |")
    foreach ($root in $Plan.excludedRoots) {
        $lines.Add("| $(Escape-MarkdownCell $root.path) | $(Escape-MarkdownCell $root.reason) |")
    }
    $lines.Add("")
    $lines.Add("### 被根策略阻止的候选")
    $lines.Add("")
    if ($Plan.blockedByRootPolicy.Count -eq 0) {
        $lines.Add("无。")
    } else {
        $lines.Add("| 来源 | 类型 | 命中根 | 原因 |")
        $lines.Add("| --- | --- | --- | --- |")
        foreach ($item in $Plan.blockedByRootPolicy) {
            $lines.Add("| $(Escape-MarkdownCell $item.source) | $(Escape-MarkdownCell $item.kind) | $(Escape-MarkdownCell $item.rootPolicy.matchedExcludedRoot) | $(Escape-MarkdownCell $item.rootPolicy.note) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 下一步")
    $lines.Add("")
    $lines.Add("1. 人工审查本计划。")
    $lines.Add("2. 只对通过审查的低风险项执行真实迁移 issue。")
    $lines.Add("3. 执行前再次运行 inventory，避免基线过期。")

    return $lines -join [Environment]::NewLine
}

if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
    throw "Inventory not found: $InventoryPath"
}

Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"

$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
Assert-EnvMigrationInventoryFacts -Inventory $inventory
$inventoryGeneratedAt = if ($inventory.generatedAt -is [datetime]) {
    $inventory.generatedAt.ToString("o")
} else {
    "$($inventory.generatedAt)"
}

$migrationCandidates = @(Get-EnvMigrationCandidates -Directories @($inventory.directories))
$manualReviewItems = @(Get-EnvManualReviewItems -Directories @($inventory.directories) -LocalEnvironmentFindings @($inventory.localEnvironmentFindings))
$manualReviewSources = @($manualReviewItems | ForEach-Object { $_.source })
$migrationPlans = @()
$blockedByRootPolicy = @()
$blockedByManualReview = @()
$index = 1
foreach ($candidate in $migrationCandidates) {
    if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace($candidate.source)) {
        continue
    }

    if ($manualReviewSources -contains $candidate.source) {
        $blockedByManualReview += [pscustomobject]@{
            source = $candidate.source
            kind = $candidate.kind
            owner = $candidate.owner
            risk = $candidate.risk
            reason = "该来源同时出现在人工审查项中，优先按人工审查处理。"
        }
        continue
    }

    $rootPolicy = Get-EnvRootPolicyDecision -Candidate $candidate
    if ($rootPolicy.allowDryRunPlan) {
        $migrationPlans += New-MigrationPlanEntry -Candidate $candidate -Index $index -RootPolicy $rootPolicy
        $index++
    } else {
        $blockedByRootPolicy += [pscustomobject]@{
            source = $candidate.source
            kind = $candidate.kind
            owner = $candidate.owner
            risk = $candidate.risk
            reason = $candidate.reason
            rootPolicy = $rootPolicy
        }
    }
}

$plan = [pscustomobject]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    readOnly = $true
    inventoryPath = $InventoryPath
    inventoryGeneratedAt = $inventoryGeneratedAt
    migrationPlans = $migrationPlans
    blockedByRootPolicy = $blockedByRootPolicy
    blockedByManualReview = $blockedByManualReview
    excludedManualReviewItems = $manualReviewItems
    excludedRoots = @(Get-EnvCanonicalExcludedRoots)
}

$published = Publish-JsonMarkdownArtifactPair -Document $plan -OutputDir $OutputDir -JsonFileName "plan.json" -MarkdownFileName "PLAN.md" -RenderMarkdown {
    param($Document, $SourceJsonSha256)
    ConvertTo-MigrationPlanMarkdown -Plan $Document
}

[pscustomobject]@{
    planJson = $published.jsonPath
    planMarkdown = $published.markdownPath
    generationId = $published.generationId
    readOnly = $true
}
