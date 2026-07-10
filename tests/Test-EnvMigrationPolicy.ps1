param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境"
)

$ErrorActionPreference = "Stop"
$WarningPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    $threw = $false
    try {
        & $Action
    } catch {
        $threw = $true
    }
    Assert-True -Condition $threw -Message $Message
}

$policyPath = Join-Path $ProjectRoot "scripts\lib\EnvMigrationPolicy.ps1"
Assert-True -Condition (Test-Path -LiteralPath $policyPath -PathType Leaf) -Message "找不到迁移策略库：$policyPath"
. $policyPath

$canonicalExcludedRoots = @(Get-EnvCanonicalExcludedRoots)
$excludedRootFacts = @(Get-EnvExcludedRootFacts)
Assert-True -Condition ($canonicalExcludedRoots.Count -eq 5) -Message "canonical excluded-root 规则数量发生变化"
Assert-True -Condition (@($canonicalExcludedRoots | Where-Object { $_.path -eq "C:\ProgramData" }).Count -eq 1) -Message "canonical excluded-root 必须包含 C:\ProgramData"
Assert-True -Condition ($excludedRootFacts.Count -eq $canonicalExcludedRoots.Count) -Message "excluded-root facts 必须完整投影 canonical roots"
foreach ($rootFact in $excludedRootFacts) {
    Assert-True -Condition ((@($rootFact.PSObject.Properties.Name) -join ",") -ceq "path") -Message "Inventory excluded-root fact 只能包含 path"
}

$programDataDecision = Get-EnvRootPolicyDecision -Candidate ([pscustomobject]@{
    source = "C:\ProgramData\fixture-cache"
    kind = "cache"
    owner = "fixture"
})
Assert-True -Condition ($programDataDecision.decision -eq "blocked-by-excluded-root") -Message "C:\ProgramData 必须由单一 root policy 阻止"
Assert-True -Condition (-not [bool]$programDataDecision.allowDryRunPlan) -Message "C:\ProgramData 不得进入 dry-run 迁移计划"

$userCacheDecision = Get-EnvRootPolicyDecision -Candidate ([pscustomobject]@{
    source = "C:\Users\fixture\AppData\Local\npm-cache"
    kind = "cache"
    owner = "node"
})
Assert-True -Condition ($userCacheDecision.decision -eq "targeted-cache-under-excluded-user-root") -Message "C 用户缓存应保留 targeted cache 旧语义"

$directories = @(
    [pscustomobject]@{
        name = "pip cache env"
        path = "D:\Codex\.cache\pip"
        category = "cache"
        owner = "python"
        exists = $true
        drive = "D:\"
        isReparsePoint = $false
        reparseTarget = $null
        sizeBytes = $null
        notes = "显式 PIP_CACHE_DIR"
    }
    [pscustomobject]@{
        name = "pip cache default"
        path = "C:\Users\fixture\AppData\Local\pip\Cache"
        category = "cache"
        owner = "python"
        exists = $true
        drive = "C:\"
        isReparsePoint = $false
        reparseTarget = $null
        sizeBytes = $null
        notes = "pip 默认用户缓存候选"
    }
    [pscustomobject]@{
        name = "npm cache default"
        path = "C:\Users\fixture\AppData\Local\npm-cache"
        category = "cache"
        owner = "node"
        exists = $true
        drive = "C:\"
        isReparsePoint = $false
        reparseTarget = $null
        sizeBytes = $null
        notes = "npm 常见缓存位置"
    }
    [pscustomobject]@{
        name = "reparse cache"
        path = "C:\Users\fixture\AppData\Local\linked-cache"
        category = "cache"
        owner = "node"
        exists = $true
        drive = "C:\"
        isReparsePoint = $true
        reparseTarget = "D:\fixture-target"
        sizeBytes = $null
        notes = "reparse fixture"
    }
    [pscustomobject]@{
        name = "docker user config"
        path = "C:\Users\fixture\.docker"
        category = "manual-only"
        owner = "container"
        exists = $true
        drive = "C:\"
        isReparsePoint = $false
        reparseTarget = $null
        sizeBytes = $null
        notes = "Docker 用户配置，可能包含上下文和凭据引用"
    }
)

$localEnvironmentFindings = @(
    [pscustomobject]@{
        project = "D:\Codex\projects\fixture-app"
        parentProject = "D:\Codex\projects\fixture-app"
        marker = "node_modules"
        path = "D:\Codex\projects\fixture-app\node_modules"
        drive = "D:\"
        sizeBytes = 42
        classification = "project-root-local-env"
        scope = "project-root"
        owner = "project"
    }
)

$candidates = @(Get-EnvMigrationCandidates -Directories $directories)
$manualReviewItems = @(Get-EnvManualReviewItems -Directories $directories -LocalEnvironmentFindings $localEnvironmentFindings)
$emptyCandidates = @(Get-EnvMigrationCandidates -Directories @())
$emptyManualReviewItems = @(Get-EnvManualReviewItems -Directories @() -LocalEnvironmentFindings @())
Assert-True -Condition ($emptyCandidates.Count -eq 0) -Message "空目录事实应得到空迁移候选"
Assert-True -Condition ($emptyManualReviewItems.Count -eq 0) -Message "空事实应得到空人工审查项"

$invalidBooleanDirectory = [pscustomobject]@{
    name = "invalid cache"
    path = "C:\Users\fixture\invalid-cache"
    category = "cache"
    owner = "node"
    exists = "false"
    drive = "C:\"
    isReparsePoint = $false
    reparseTarget = $null
    sizeBytes = $null
    notes = "invalid boolean fixture"
}
Assert-Throws -Action { Get-EnvMigrationCandidates -Directories @($invalidBooleanDirectory) | Out-Null } -Message "纯策略必须拒绝字符串 exists，不能宽松强转"

$pipDefault = @($candidates | Where-Object { $_.source -eq "C:\Users\fixture\AppData\Local\pip\Cache" })
Assert-True -Condition ($pipDefault.Count -eq 0) -Message "canonical D 盘 pip cache 已配置时，不应再建议迁移旧默认 pip cache"

$npmCache = @($candidates | Where-Object { $_.source -eq "C:\Users\fixture\AppData\Local\npm-cache" })
Assert-True -Condition ($npmCache.Count -eq 1) -Message "C 用户缓存应保留旧迁移候选语义"
Assert-True -Condition ($npmCache[0].risk -eq "low") -Message "C 用户缓存风险应为 low"
Assert-True -Condition ($npmCache[0].action -eq "可考虑迁移到 D:\Codex\.cache") -Message "C 用户缓存建议动作发生变化"

$reparseCandidate = @($candidates | Where-Object { $_.source -eq "C:\Users\fixture\AppData\Local\linked-cache" })
Assert-True -Condition ($reparseCandidate.Count -eq 0) -Message "reparse 目录不得进入迁移候选"
$reparseReview = @($manualReviewItems | Where-Object { $_.source -eq "C:\Users\fixture\AppData\Local\linked-cache" })
Assert-True -Condition ($reparseReview.Count -eq 1) -Message "reparse 目录必须进入人工审查"
Assert-True -Condition ($reparseReview[0].risk -eq "high" -and $reparseReview[0].action -eq "不自动迁移") -Message "reparse 人工审查语义发生变化"

$dockerReview = @($manualReviewItems | Where-Object { $_.source -eq "C:\Users\fixture\.docker" })
Assert-True -Condition ($dockerReview.Count -eq 1) -Message "manual-only 目录必须进入人工审查"
Assert-True -Condition ($dockerReview[0].action -eq "仅人工处理") -Message "manual-only 目录动作发生变化"

$nodeModulesReview = @($manualReviewItems | Where-Object { $_.source -eq "D:\Codex\projects\fixture-app\node_modules" })
Assert-True -Condition ($nodeModulesReview.Count -eq 1) -Message "项目 node_modules 必须进入人工审查"
Assert-True -Condition ($nodeModulesReview[0].kind -eq "project-root-local-env") -Message "项目 node_modules 分类发生变化"
Assert-True -Condition ($nodeModulesReview[0].risk -eq "high" -and $nodeModulesReview[0].action -eq "不自动迁移") -Message "项目 node_modules 审查语义发生变化"
Assert-True -Condition ($nodeModulesReview[0].reason -like "*项目根本地依赖环境*") -Message "项目 node_modules 应由策略层派生原因"

[pscustomobject]@{
    ok = $true
    migrationCandidates = $candidates.Count
    manualReviewItems = $manualReviewItems.Count
}
