param(
    [string]$ReadinessPath = "D:\agents\projects\统一环境\reports\env-update-readiness\readiness.json",
    [string]$ReadinessMarkdownPath,
    [string]$OutputDir = "D:\agents\projects\统一环境\reports\stale-path-entry-cleanup-dry-run"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\EnvInventoryTrust.ps1")
. (Join-Path $PSScriptRoot "lib\ReportArtifactPublisher.ps1")

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

function Assert-DDrivePath {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    Assert-EnvSafeAbsolutePath -Path $Path -FactName $ParameterName

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($root -ine "D:\") {
        throw "$ParameterName 必须位于 D:\ 下，当前值：$Path"
    }

    $current = $fullPath
    if (-not (Test-Path -LiteralPath $current)) {
        $parent = [System.IO.Directory]::GetParent($current.TrimEnd("\", "/"))
        if ($null -ne $parent) {
            $current = $parent.FullName
        }
    }

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

function Assert-AllowedOutputDir {
    param([string]$Path)

    $allowedRoots = @(
        "D:\agents\projects\统一环境\reports",
        "D:\Codex\.codex\run-evidence\env-governance"
    )

    foreach ($allowedRoot in $allowedRoots) {
        if (Test-IsSubPath -Path $Path -BasePath $allowedRoot) {
            return
        }
    }

    throw "OutputDir 必须位于允许的报告目录：D:\agents\projects\统一环境\reports 或 D:\Codex\.codex\run-evidence\env-governance。当前值：$Path"
}

function Assert-ReadableDFile {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    Assert-DDrivePath -Path $Path -ParameterName $ParameterName
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$ParameterName 不存在：$Path"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$ParameterName 不能是 junction、symlink 或 reparse point：$Path"
    }
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

function Get-StableId {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hex = ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    return $hex.Substring(0, 12)
}

function Test-ReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function New-CleanupCandidate {
    param([object]$Entry)

    $path = "$($Entry.path)"
    Assert-EnvSafeAbsolutePath -Path $path -FactName "Stale PATH candidate.path"
    $metadata = Get-StalePathChainMetadata -Path $path
    $existsNow = if ($metadata.exists -is [bool]) { $metadata.exists } else { $null }
    $isReparsePoint = $metadata.status -eq "ok" -and $metadata.isReparsePoint -eq $true
    $isProjectLocalEnvEntry = [bool]$Entry.isProjectLocalEnvEntry
    $blockedReasons = New-Object System.Collections.Generic.List[string]

    if (-not $isProjectLocalEnvEntry) {
        $blockedReasons.Add("该入口不是项目本地环境 PATH 入口，本 dry-run 不处理。")
    }
    if ($metadata.status -ne "ok") {
        $blockedReasons.Add("候选路径或祖先 metadata 探测失败：$($metadata.error)")
    } elseif ($existsNow) {
        $blockedReasons.Add("该路径当前已经存在，不能继续按失效入口处理。")
    }
    if ($isReparsePoint) {
        $blockedReasons.Add("该路径或祖先当前是 reparse point，必须先人工确认目标。")
    }

    $status = if ($blockedReasons.Count -gt 0) { "blocked" } else { "cleanup-candidate" }

    [pscustomobject]@{
        candidateId = "stale-path-$($Entry.index)-$(Get-StableId -Text $path)"
        pathIndex = $Entry.index
        path = $path
        drive = $Entry.drive
        currentExists = $existsNow
        isReparsePoint = $isReparsePoint
        metadataStatus = $metadata.status
        metadataError = $metadata.error
        reparseAncestor = $metadata.reparseAncestor
        reparseTarget = $metadata.reparseTarget
        isProjectLocalEnvEntry = $isProjectLocalEnvEntry
        riskLevel = if ([string]::IsNullOrWhiteSpace($Entry.riskLevel)) { "medium" } else { "$($Entry.riskLevel)" }
        status = $status
        executionAllowed = $false
        proposedAction = "先定位持久来源（User、Machine、启动器配置或进程注入）；该条目仅来自 Process PATH 观察，本 dry-run 不推断也不修改任何 scope，且不删除、不重建对应环境目录。"
        sourceRecommendedAction = "$($Entry.recommendedAction)"
        blockedReasons = @($blockedReasons)
        preflightChecks = @(
            "重新生成 env-update-readiness 报告，确认该 PATH 入口仍缺失。",
            "对比 Process、User、Machine PATH 及启动器配置，记录明确的 persistenceScope；不得从 Process 观察结果推断持久来源。",
            "确认没有项目、服务或快捷方式仍依赖该失效入口。",
            "未来范围必须绑定已确认的 persistenceScope 与列出的 PATH 字符串，且不触碰 .venv、node_modules 或项目文件。"
        )
        validationSteps = @(
            "未来只有确认 persistenceScope 并获得独立授权后，才可由对应 scope 的执行计划定义验证步骤。",
            "确认相关项目和常用工具命令仍能按现有入口启动。",
            "重新运行 env-update-readiness 报告，确认该失效项目本地环境 PATH 入口数量下降。"
        )
        rollbackSteps = @(
            "本 dry-run 不预设要修改的持久 scope，因此不伪造具体 scope 的回滚动作。",
            "未来执行计划必须针对已确认的 persistenceScope 保存原始值、顺序和来源证据。",
            "若无法确认 persistenceScope，保持 executionAllowed=false 并停止。"
        )
        humanGates = @(
            "用户逐项确认 candidateId、路径数量、具体 PATH 字符串及 persistenceScope 后，才能另建真实清理计划。",
            "真实清理必须作为独立执行步骤，不得和依赖重建、目录删除或环境迁移合并。"
        )
    }
}

function Write-PlanMarkdown {
    param(
        [object]$Plan
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 失效 PATH 入口清理 DRY-RUN")
    $lines.Add("")
    $lines.Add("生成时间：$($Plan.generatedAt)")
    $lines.Add("")
    $lines.Add('> DRY-RUN：本计划只读取 Process scope 的 readiness 观察并生成待定位项，不推断持久来源、不修改任何 PATH scope、不写系统配置、不删除或重建任何 `.venv`、`node_modules`。')
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add(('- readiness：`{0}`' -f $Plan.readinessPath))
    $lines.Add("- 候选数量：$($Plan.summary.totalCandidates)")
    $lines.Add("- 可进入真实授权候选：$($Plan.summary.cleanupCandidates)")
    $lines.Add("- 阻塞候选：$($Plan.summary.blockedCandidates)")
    $lines.Add("- 执行允许：否")
    $lines.Add("")
    $lines.Add("## 候选清单")
    $lines.Add("")
    if ($Plan.candidates.Count -eq 0) {
        $lines.Add("当前没有失效项目本地环境 PATH 入口候选。")
    } else {
        $lines.Add("| candidateId | PATH 序号 | 路径 | 当前存在 | 状态 | 建议动作 |")
        $lines.Add("| --- | --- | --- | --- | --- | --- |")
        foreach ($candidate in $Plan.candidates) {
            $existsDisplay = if ($candidate.currentExists) { "是" } else { "否" }
            $lines.Add("| $(Escape-MarkdownCell $candidate.candidateId) | $(Escape-MarkdownCell $candidate.pathIndex) | $(Escape-MarkdownCell $candidate.path) | $existsDisplay | $(Escape-MarkdownCell $candidate.status) | $(Escape-MarkdownCell $candidate.proposedAction) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 逐项说明")
    foreach ($candidate in $Plan.candidates) {
        $lines.Add("")
        $lines.Add("### $($candidate.candidateId)")
        $lines.Add("")
        $lines.Add(('- 路径：`{0}`' -f $candidate.path))
        $lines.Add(("- 当前存在：{0}" -f $(if ($candidate.currentExists) { "是" } else { "否" })))
        $lines.Add(('- 状态：`{0}`' -f $candidate.status))
        if ($candidate.blockedReasons.Count -gt 0) {
            $lines.Add("")
            $lines.Add("#### 阻塞原因")
            foreach ($reason in $candidate.blockedReasons) {
                $lines.Add("- $reason")
            }
        }
        $lines.Add("")
        $lines.Add("#### 前置检查")
        foreach ($check in $candidate.preflightChecks) {
            $lines.Add("- $check")
        }
        $lines.Add("")
        $lines.Add("#### 验证步骤")
        foreach ($step in $candidate.validationSteps) {
            $lines.Add("- $step")
        }
        $lines.Add("")
        $lines.Add("#### 回滚步骤")
        foreach ($step in $candidate.rollbackSteps) {
            $lines.Add("- $step")
        }
        $lines.Add("")
        $lines.Add("#### 人工授权门")
        foreach ($gate in $candidate.humanGates) {
            $lines.Add("- $gate")
        }
    }
    $lines.Add("")
    $lines.Add("## 策略")
    $lines.Add("")
    foreach ($rule in $Plan.policy.rules) {
        $lines.Add("- $rule")
    }

    return @($lines) -join "`n"
}

function Get-StalePathFileSystemItemMetadata {
    param([Parameter(Mandatory)][string]$Path)
    Assert-EnvSafeAbsolutePath -Path $Path -FactName "Stale PATH metadata path"
    try {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
            return [pscustomobject]@{ status = "missing"; path = $Path }
        }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        $target = if ($isReparse -and $item.PSObject.Properties.Name -contains "Target") { $item.Target } else { $null }
        return [pscustomobject]@{ status = "ok"; path = $item.FullName; isReparsePoint = $isReparse; reparseTarget = $target }
    } catch {
        return [pscustomobject]@{ status = "error"; error = $_.Exception.Message }
    }
}

function Get-StalePathChainMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $resolver = { param([string]$CandidatePath) Get-StalePathFileSystemItemMetadata -Path $CandidatePath }
    return Get-InventoryReparseChainMetadata -Path $Path -ItemMetadataResolver $resolver
}

function Test-StalePathInteger {
    param([AllowNull()][object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Assert-StalePathReadinessV3 {
    param([Parameter(Mandatory)][object]$Readiness)
    if ($Readiness -isnot [pscustomobject]) { throw "Readiness 必须是 JSON object。" }
    foreach ($name in @("artifactType", "schemaVersion", "generatedAt", "pathSummary")) {
        if (-not ($Readiness.PSObject.Properties.Name -contains $name)) { throw "Readiness 缺少字段：$name" }
    }
    if ($Readiness.artifactType -isnot [string] -or $Readiness.artifactType -cne "env-governance.update-readiness") { throw "Readiness artifactType 必须为 env-governance.update-readiness。" }
    if (-not (Test-StalePathInteger $Readiness.schemaVersion) -or $Readiness.schemaVersion -ne 3) { throw "Readiness schemaVersion 必须是整数 3。" }
    if ($Readiness.generatedAt -isnot [string] -or [string]::IsNullOrWhiteSpace($Readiness.generatedAt)) { throw "Readiness generatedAt 必须是非空字符串。" }
    if ($Readiness.pathSummary -isnot [pscustomobject]) { throw "Readiness pathSummary 必须是 object。" }
    foreach ($name in @("sourceScope", "complete", "cleanupAdviceAllowed", "staleLocalEnvironmentEntries")) {
        if (-not ($Readiness.pathSummary.PSObject.Properties.Name -contains $name)) { throw "Readiness pathSummary 缺少字段：$name" }
    }
    if ($Readiness.pathSummary.sourceScope -isnot [string] -or $Readiness.pathSummary.sourceScope -cne "process") { throw "Readiness pathSummary.sourceScope 必须为 process。" }
    if ($Readiness.pathSummary.complete -isnot [bool]) { throw "Readiness pathSummary.complete 必须是 Boolean。" }
    if (-not $Readiness.pathSummary.complete) { throw "Readiness Process PATH scope 不完整，拒绝生成 stale PATH dry-run。" }
    if ($Readiness.pathSummary.cleanupAdviceAllowed -isnot [bool] -or -not $Readiness.pathSummary.cleanupAdviceAllowed) { throw "Readiness 未授权基于完整 Process PATH scope 生成 cleanup advice。" }
    if ($Readiness.pathSummary.staleLocalEnvironmentEntries -isnot [array]) { throw "Readiness staleLocalEnvironmentEntries 必须是数组。" }
    foreach ($entry in @($Readiness.pathSummary.staleLocalEnvironmentEntries)) {
        if ($entry -isnot [pscustomobject]) { throw "Stale PATH entry 必须是 object。" }
        foreach ($name in @("index", "path", "drive", "isProjectLocalEnvEntry", "riskLevel", "recommendedAction")) {
            if (-not ($entry.PSObject.Properties.Name -contains $name)) { throw "Stale PATH entry 缺少字段：$name" }
        }
        if (-not (Test-StalePathInteger $entry.index)) { throw "Stale PATH entry.index 必须是整数。" }
        Assert-EnvSafeAbsolutePath -Path $entry.path -FactName "Stale PATH entry.path"
        if ($entry.isProjectLocalEnvEntry -isnot [bool]) { throw "Stale PATH entry.isProjectLocalEnvEntry 必须是 Boolean。" }
        if ($entry.riskLevel -isnot [string] -or $entry.recommendedAction -isnot [string]) { throw "Stale PATH entry 文本字段类型无效。" }
    }
}

Assert-ReadableDFile -Path $ReadinessPath -ParameterName "ReadinessPath"
$effectiveReadinessMarkdownPath = if ([string]::IsNullOrWhiteSpace($ReadinessMarkdownPath)) {
    Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReadinessPath))) "REPORT.md"
} else {
    $ReadinessMarkdownPath
}
Assert-ReadableDFile -Path $effectiveReadinessMarkdownPath -ParameterName "ReadinessMarkdownPath"
$readinessPair = Test-JsonMarkdownArtifactPair -JsonPath $ReadinessPath -MarkdownPath $effectiveReadinessMarkdownPath
if (-not $readinessPair.ok) { throw "Readiness JSON/Markdown pair 校验失败：$($readinessPair.error)" }
$readiness = Get-Content -LiteralPath $ReadinessPath -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
Assert-StalePathReadinessV3 -Readiness $readiness
# readiness contract 通过后才校验/发布 OutputDir；失败不得创建或覆盖旧产物。
Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"
Assert-AllowedOutputDir -Path $OutputDir
$readinessGeneratedAt = if ($readiness.generatedAt -is [datetime]) {
    $readiness.generatedAt.ToString("o")
} else {
    "$($readiness.generatedAt)"
}
$staleEntries = @($readiness.pathSummary.staleLocalEnvironmentEntries)
$candidates = @(
    foreach ($entry in $staleEntries) {
        New-CleanupCandidate -Entry $entry
    }
)
$candidateIds = @($candidates | ForEach-Object { $_.candidateId })
if (@($candidateIds | Sort-Object -Unique).Count -ne $candidateIds.Count) {
    throw "Stale PATH candidates 包含重复 candidateId，拒绝发布。"
}

$plan = [pscustomobject]@{
    artifactType = "env-governance.stale-path-entry-cleanup-dry-run"
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    dryRun = $true
    readOnly = $true
    readinessPath = $ReadinessPath
    readinessGeneratedAt = $readinessGeneratedAt
    summary = [pscustomobject]@{
        totalCandidates = $candidates.Count
        cleanupCandidates = @($candidates | Where-Object { $_.status -eq "cleanup-candidate" }).Count
        blockedCandidates = @($candidates | Where-Object { $_.status -eq "blocked" }).Count
        pathMutationAllowed = $false
        registryWriteAllowed = $false
        executionReady = $false
    }
    candidates = $candidates
    policy = [pscustomobject]@{
        executionAllowed = $false
        pathMutationAllowed = $false
        registryWriteAllowed = $false
        deleteAllowed = $false
        environmentDirectoryWriteAllowed = $false
        rules = @(
            "本计划只记录 Process PATH 观察，不推断持久来源，不修改任何 PATH scope。",
            "本计划不删除、不移动、不重建任何 .venv、node_modules 或项目目录。",
            "未来真实清理前必须重新生成 readiness 和本 dry-run，并逐项确认 candidateId、路径数量、PATH 字符串与 persistenceScope。",
            "未来执行计划必须按已确认 persistenceScope 保存原始值与顺序作为回滚依据。",
            "输出只能位于 D 盘允许报告目录。"
        )
    }
}

$published = Publish-JsonMarkdownArtifactPair -Document $plan -OutputDir $OutputDir -JsonFileName "plan.json" -MarkdownFileName "PLAN.md" -RenderMarkdown {
    param($Document, $JsonSha256)
    Write-PlanMarkdown -Plan $Document
}

[pscustomobject]@{
    planJson = $published.jsonPath
    planMarkdown = $published.markdownPath
    generationId = $published.generationId
    dryRun = $true
    readOnly = $true
    executionAllowed = $false
}
