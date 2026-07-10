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

$rebuildEvidenceFileNames = @(Get-EnvRebuildEvidenceFileNames)
Assert-True -Condition ($rebuildEvidenceFileNames -contains "package-lock.json") -Message "canonical rebuild evidence 文件表缺少 package-lock.json"
Assert-True -Condition (@($rebuildEvidenceFileNames | Sort-Object -Unique).Count -eq $rebuildEvidenceFileNames.Count) -Message "canonical rebuild evidence 文件表不得重复"

$workspaceRoot = "D:\fixture-workspace"
$specificAppRoot = "D:\fixture-workspace\app"
$nearestRoot = Get-EnvMostSpecificProjectRoot -Path "D:\fixture-workspace\app\node_modules" -ProjectRoots @($workspaceRoot, $specificAppRoot)
Assert-True -Condition ($nearestRoot -eq $specificAppRoot) -Message "marker 必须选择最近/最具体的显式 ProjectRoot"
$nestedRoot = Get-EnvMostSpecificProjectRoot -Path "D:\fixture-workspace\apps\web\node_modules" -ProjectRoots @($workspaceRoot, $specificAppRoot)
Assert-True -Condition ($nestedRoot -eq $workspaceRoot) -Message "深层 marker 必须选择实际包含它的最近显式 ProjectRoot"

$typedRootFacts = [object[]]@(
    [pscustomobject]@{ path = $workspaceRoot; kind = "collection" },
    [pscustomobject]@{ path = $specificAppRoot; kind = "project" }
)
Assert-EnvProjectRootFacts -ProjectRootFacts $typedRootFacts
$collectionTop = Get-EnvTopProjectRootForMarker -Path "D:\fixture-workspace\foo\node_modules" -ProjectRootFacts $typedRootFacts
Assert-True -Condition ($collectionTop -eq "D:\fixture-workspace\foo") -Message "collection root 的直接子项目必须成为 top project"
$collectionNestedTop = Get-EnvTopProjectRootForMarker -Path "D:\fixture-workspace\apps\web\node_modules" -ProjectRootFacts $typedRootFacts
Assert-True -Condition ($collectionNestedTop -eq "D:\fixture-workspace\apps") -Message "collection root 的深层 app 必须归属第一层 top project"
$explicitTop = Get-EnvTopProjectRootForMarker -Path "D:\fixture-workspace\app\node_modules" -ProjectRootFacts $typedRootFacts
Assert-True -Condition ($explicitTop -eq $specificAppRoot) -Message "更窄显式 project root 必须保持自身为 top project"

$specialDecision = Get-EnvLocalEnvironmentClassification -Path "D:\fixture-workspace\plugins\cache\plugin\node_modules" -Project "D:\fixture-workspace\plugins\cache\plugin" -ParentProject "D:\fixture-workspace\plugins\cache\plugin"
Assert-True -Condition ($specialDecision.classification -eq "plugin-runtime-cache" -and $specialDecision.owner -eq "plugin-runtime") -Message "特殊路径分类必须优先于 project==parentProject"

foreach ($devicePath in @('\\?\C:\Users\fixture\.cargo', '\\.\C:\Users\fixture\.cargo', '//?/C:/Users/fixture/.cargo', '//./C:/Users/fixture/.cargo', '\\??\C:\Users\fixture\.cargo', '\Device\HarddiskVolume1\Users\fixture', '\GLOBAL??\C:\Users\fixture', '\DosDevices\C:\Users\fixture', '/device/harddiskvolume1/users/fixture')) {
    Assert-Throws -Action { Assert-EnvAbsolutePathValue -Path $devicePath -FactName "device path fixture" } -Message "必须在 canonical/drive 判断前拒绝 Windows device namespace：$devicePath"
}
foreach ($unsafeRootedPath in @('\SystemRoot\System32', '\GLOBALROOT\Device\HarddiskVolume1', '\ObjectTypes', '\UnknownNamespace\value', 'C:relative\path')) {
    Assert-Throws -Action { Assert-EnvSafeAbsolutePath -Path $unsafeRootedPath -FactName "unsafe rooted fixture" } -Message "正向 allowlist 必须拒绝 root-relative/NT/drive-relative 路径：$unsafeRootedPath"
}
foreach ($safePath in @('C:\Windows', 'D:/Codex/tools', '\\server\share', '\\server\share\folder', '//server/share/folder')) {
    Assert-EnvSafeAbsolutePath -Path $safePath -FactName "safe absolute fixture"
}

$unsafeWin32Paths = @(
    'C:\CON', 'C:\con.txt', 'C:\dir\PRN.log', 'C:\AUX', 'C:\NUL.data', 'C:\CLOCK$',
    'C:\COM1', 'C:\com9.log', 'C:\LPT1', 'C:\lpt9.txt',
    '\\server\CON\file', '\\NUL\share\file',
    'C:\safe:file', 'C:\dir\file:stream',
    'C:\bad<name', 'C:\bad>name', 'C:\bad"name', 'C:\bad|name', 'C:\bad?name', 'C:\bad*name',
    "C:\bad$([char]1)name", 'C:\taildot.', 'C:\tailspace ',
    'C:\foo\\bar', '\\server\share\\bar'
)
foreach ($unsafeWin32Path in $unsafeWin32Paths) {
    Assert-Throws -Action { Assert-EnvSafeAbsolutePath -Path $unsafeWin32Path -FactName "unsafe Win32 segment fixture" } -Message "Win32 segment allowlist 必须拒绝：$unsafeWin32Path"
}
Assert-Throws -Action { Assert-EnvSafeReparseTarget -Path 'D:\links\NUL.txt' -FactName "unsafe reparse target fixture" } -Message "reparseTarget 必须应用相同 Win32 segment 规则"

foreach ($safeWin32Path in @(
    'C:\', 'C:\normal\', 'C:\console', 'C:\com10', 'C:\nulldata',
    'D:\项目\缓存', 'D:\Program Files\Tool Name',
    '\\server\share\', '\\server-name\共享 空间\folder'
)) {
    Assert-EnvSafeAbsolutePath -Path $safeWin32Path -FactName "safe Win32 segment fixture"
}

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

foreach ($masqueradeSource in @(
    "C:\Users",
    "C:\Users\fixture",
    "C:\Users\fixture\Documents\cache"
)) {
    $decision = Get-EnvRootPolicyDecision -Candidate ([pscustomobject]@{
        source = $masqueradeSource
        kind = "cache"
        owner = "fixture"
    })
    Assert-True -Condition ($decision.decision -eq "blocked-by-excluded-root") -Message "非 canonical 用户缓存不得绕过 C:\Users root policy：$masqueradeSource"
    Assert-True -Condition (-not [bool]$decision.allowDryRunPlan) -Message "非 canonical 用户缓存不得进入 dry-run：$masqueradeSource"
}

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
        notes = "NOTES-ATTACK 推荐候选"
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
    [pscustomobject]@{
        name = "cargo home"
        path = "C:\Users\fixture\.cargo"
        category = "tool-env"
        owner = "rust"
        exists = $true
        drive = "C:\"
        isReparsePoint = $false
        reparseTarget = $null
        sizeBytes = $null
        notes = "Cargo 用户工具根观察值"
    }
    [pscustomobject]@{
        name = "gradle user home"
        path = "C:\Users\fixture\.gradle"
        category = "cache"
        owner = "java"
        exists = $true
        drive = "C:\"
        isReparsePoint = $false
        reparseTarget = $null
        sizeBytes = $null
        notes = "Gradle 用户根观察值"
    }
    [pscustomobject]@{
        name = "gradle caches"
        path = "C:\Users\fixture\.gradle\caches"
        category = "cache"
        owner = "java"
        exists = $true
        drive = "C:\"
        isReparsePoint = $false
        reparseTarget = $null
        sizeBytes = $null
        notes = "Gradle 纯缓存子目录观察值"
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
        rebuildEvidence = [pscustomobject]@{
            marker = "node_modules"
            projectFiles = [object[]]@("package.json", "package-lock.json")
        }
    }
)
$fixtureProjectRootFacts = [object[]]@([pscustomobject]@{ path = "D:\Codex\projects\fixture-app"; kind = "project" })

$missingRebuildEvidence = [pscustomobject]@{
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
Assert-Throws -Action { Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings @($missingRebuildEvidence) -ProjectRootFacts $fixtureProjectRootFacts } -Message "本地环境 fact 必须包含严格 rebuildEvidence"

$duplicateDirectories = [object[]]@(
    $directories[0],
    ($directories[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
)
Assert-Throws -Action { Assert-EnvMigrationDirectoryFacts -Directories $duplicateDirectories } -Message "Directory facts 必须拒绝重复 canonical path"

$duplicateFindings = [object[]]@(
    $localEnvironmentFindings[0],
    ($localEnvironmentFindings[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
)
Assert-Throws -Action { Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings $duplicateFindings -ProjectRootFacts $fixtureProjectRootFacts } -Message "LocalEnvironmentFinding facts 必须拒绝重复 canonical path"

$masqueradeFinding = ($localEnvironmentFindings[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
$masqueradeFinding.classification = "plugin-runtime-cache"
$masqueradeFinding.scope = "plugin-runtime-cache"
$masqueradeFinding.owner = "plugin-runtime"
Assert-Throws -Action { Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings @($masqueradeFinding) -ProjectRootFacts $fixtureProjectRootFacts } -Message "普通项目 node_modules 不得协调伪装为 plugin-runtime-cache"

$wrongExplicitRootFinding = ($localEnvironmentFindings[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
Assert-Throws -Action { Assert-EnvLocalEnvironmentFindingFacts -LocalEnvironmentFindings @($wrongExplicitRootFinding) -ProjectRootFacts @([pscustomobject]@{ path = "D:\Codex\projects"; kind = "project" }) } -Message "strict validator 必须拒绝不等于最具体 typed root 的 parentProject"

$deviceDirectory = ($directories[5] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
$deviceDirectory.path = '\\?\C:\Users\fixture\.cargo'
$deviceDirectory.drive = '\\?\C:\'
Assert-Throws -Action { Assert-EnvMigrationDirectoryFacts -Directories @($deviceDirectory) } -Message "device namespace directory 单独出现时必须失败"
Assert-Throws -Action { Assert-EnvMigrationDirectoryFacts -Directories @($directories[5], $deviceDirectory) } -Message "device namespace 与普通路径并存时也必须失败，不能绕过去重"
$deviceReparseTarget = ($directories[3] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
$deviceReparseTarget.reparseTarget = '\Device\HarddiskVolume1\fixture-target'
Assert-Throws -Action { Assert-EnvMigrationDirectoryFacts -Directories @($deviceReparseTarget) } -Message "reparseTarget 必须拒绝扩展 NT device namespace"
Assert-Throws -Action { Assert-EnvProjectRootFacts -ProjectRootFacts @([pscustomobject]@{ path = '\\?\D:\fixture-workspace'; kind = 'project' }) } -Message "device namespace ProjectRoot 必须失败"

$candidates = @(Get-EnvMigrationCandidates -Directories $directories)
$manualReviewItems = @(Get-EnvManualReviewItems -Directories $directories -LocalEnvironmentFindings $localEnvironmentFindings -ProjectRootFacts $fixtureProjectRootFacts)
$emptyCandidates = @(Get-EnvMigrationCandidates -Directories @())
$emptyManualReviewItems = @(Get-EnvManualReviewItems -Directories @() -LocalEnvironmentFindings @() -ProjectRootFacts @())
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
Assert-True -Condition ($npmCache[0].reason -notmatch "NOTES-ATTACK|候选|推荐") -Message "迁移 reason 不得直接信任 directory.notes"

$gradleRootCandidate = @($candidates | Where-Object { $_.source -eq "C:\Users\fixture\.gradle" })
Assert-True -Condition ($gradleRootCandidate.Count -eq 0) -Message "整个 .gradle 根不得作为低风险 cache 候选"
$gradleCachesCandidate = @($candidates | Where-Object { $_.source -eq "C:\Users\fixture\.gradle\caches" })
Assert-True -Condition ($gradleCachesCandidate.Count -eq 1) -Message "明确 .gradle\caches 纯缓存子目录应保留为候选"

$masqueradeDirectories = @(
    foreach ($source in @("C:\Users", "C:\Users\fixture", "C:\Users\fixture\Documents\cache")) {
        [pscustomobject]@{
            name = "masquerade cache"
            path = $source
            category = "cache"
            owner = "fixture"
            exists = $true
            drive = "C:\"
            isReparsePoint = $false
            reparseTarget = $null
            sizeBytes = $null
            notes = "不得只因 category=cache 进入候选"
        }
    }
)
$masqueradeCandidates = @(Get-EnvMigrationCandidates -Directories $masqueradeDirectories)
Assert-True -Condition ($masqueradeCandidates.Count -eq 0) -Message "C:\Users、用户根或 Documents 伪装 cache 不得生成迁移候选"

$reparseCandidate = @($candidates | Where-Object { $_.source -eq "C:\Users\fixture\AppData\Local\linked-cache" })
Assert-True -Condition ($reparseCandidate.Count -eq 0) -Message "reparse 目录不得进入迁移候选"
$reparseReview = @($manualReviewItems | Where-Object { $_.source -eq "C:\Users\fixture\AppData\Local\linked-cache" })
Assert-True -Condition ($reparseReview.Count -eq 1) -Message "reparse 目录必须进入人工审查"
Assert-True -Condition ($reparseReview[0].risk -eq "high" -and $reparseReview[0].action -eq "不自动迁移") -Message "reparse 人工审查语义发生变化"

$dockerReview = @($manualReviewItems | Where-Object { $_.source -eq "C:\Users\fixture\.docker" })
Assert-True -Condition ($dockerReview.Count -eq 1) -Message "manual-only 目录必须进入人工审查"
Assert-True -Condition ($dockerReview[0].action -eq "仅人工处理") -Message "manual-only 目录动作发生变化"
Assert-True -Condition ($dockerReview[0].reason -cne $directories[4].notes) -Message "manual review reason 不得直接信任 directory.notes"

$cargoReview = @($manualReviewItems | Where-Object { $_.source -eq "C:\Users\fixture\.cargo" })
Assert-True -Condition ($cargoReview.Count -eq 1) -Message "C:\Users 下非 allowlist tool-env 必须进入人工审查"
Assert-True -Condition ($cargoReview[0].action -eq "不自动迁移") -Message "Cargo 用户工具根必须失败关闭"
$gradleRootReview = @($manualReviewItems | Where-Object { $_.source -eq "C:\Users\fixture\.gradle" })
Assert-True -Condition ($gradleRootReview.Count -eq 1) -Message "整个 .gradle 根必须进入人工审查"

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
