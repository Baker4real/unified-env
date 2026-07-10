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

function Assert-CanRemoveTestRoot {
    param([string]$Path)

    $projectReportsRoot = Join-Path $ProjectRoot "reports"
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullReportsRoot = [System.IO.Path]::GetFullPath($projectReportsRoot).TrimEnd("\", "/")
    Assert-True -Condition ($fullPath.StartsWith("$fullReportsRoot\", [System.StringComparison]::OrdinalIgnoreCase)) -Message "测试输出目录必须位于项目 reports 下：$Path"

    $current = $fullPath
    while ($current.StartsWith($fullReportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            Assert-True -Condition ((($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) -Message "测试输出路径不能穿过 junction、symlink 或 reparse point：$current"
        }

        if ($current.Equals($fullReportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($current)
        Assert-True -Condition ($null -ne $parent) -Message "无法解析测试输出目录父级：$current"
        $current = $parent.FullName.TrimEnd("\", "/")
    }
}

$scriptPath = Join-Path $ProjectRoot "scripts\New-BackupRetentionDryRun.ps1"
$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$testRoot = Join-Path $ProjectRoot "reports\backup-retention-dry-run-test"
$fixtureRoot = Join-Path $testRoot "fixture"
$fixtureCodexRoot = Join-Path $fixtureRoot ".codex"
$fixtureOutput = Join-Path $testRoot "fixture-output"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到备份保留 dry-run 脚本"

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    $result = & $scriptPath -OutputDir $testRoot
    Assert-True -Condition ([bool]$result.dryRun) -Message "脚本没有返回 dryRun=true"
    Assert-True -Condition ([bool]$result.readOnly) -Message "脚本没有返回 readOnly=true"
    Assert-True -Condition (-not [bool]$result.deleteAllowed) -Message "脚本不应允许删除"

    $jsonPath = Join-Path $testRoot "backup-retention-dry-run.json"
    $reportPath = Join-Path $testRoot "BACKUP-RETENTION-DRY-RUN.md"
    Assert-True -Condition (Test-Path -LiteralPath $jsonPath -PathType Leaf) -Message "缺少 backup-retention-dry-run.json"
    Assert-True -Condition (Test-Path -LiteralPath $reportPath -PathType Leaf) -Message "缺少 BACKUP-RETENTION-DRY-RUN.md"

    $plan = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    . $publisherPath
    Assert-True -Condition ($plan.artifactType -ceq 'env-governance.backup-retention-dry-run') -Message "artifactType 不正确"
    Assert-True -Condition ($plan.schemaVersion -eq 2) -Message "schemaVersion 必须为 2"
    Assert-True -Condition ($plan.artifactMode -ceq 'production') -Message "默认产物必须是 production"
    foreach ($property in @('declaredScanRoots', 'evaluatedRoots', 'coverageItems', 'retainedItems', 'coverageAccounted', 'coverageComplete', 'coverageNotes', 'unclassifiedCoverageGaps', 'errors')) {
        Assert-Property -Object $plan -Name $property
    }
    Assert-True -Condition ((Test-JsonMarkdownArtifactPair -JsonPath $jsonPath -MarkdownPath $reportPath).ok) -Message "JSON/Markdown 可信报告对校验失败"
    foreach ($property in @("schemaVersion", "generatedAtLocal", "dryRun", "readOnly", "deleteAllowed", "applySupported", "retainCount", "policy", "protected", "manualReview", "candidates", "summary")) {
        Assert-Property -Object $plan -Name $property
    }

    Assert-True -Condition ([bool]$plan.dryRun) -Message "JSON dryRun 不是 true"
    Assert-True -Condition ([bool]$plan.readOnly) -Message "JSON readOnly 不是 true"
    Assert-True -Condition (-not [bool]$plan.deleteAllowed) -Message "JSON deleteAllowed 应为 false"
    Assert-True -Condition (-not [bool]$plan.applySupported) -Message "JSON applySupported 应为 false"
    Assert-True -Condition ([bool]$plan.policy.explicitAuthorizationRequired) -Message "策略必须要求显式授权"
    Assert-True -Condition ([bool]$plan.policy.applyMustRegenerateDryRun) -Message "策略必须要求 apply 前重新 dry-run"
    Assert-True -Condition ([bool]$plan.policy.applyMustCheckReparsePoints) -Message "策略必须要求 reparse point 检查"
    Assert-True -Condition ([bool]$plan.policy.strictTimestampRequired) -Message "策略必须要求严格时间戳"
    Assert-True -Condition ([bool]$plan.policy.runtimeSharedDirsExcluded) -Message "策略必须排除 runtime shared dirs"
    Assert-True -Condition ([bool]$plan.policy.authAutosaveExcludedByDefault) -Message "策略必须默认排除 auth autosave"

    $protectedPaths = @($plan.protected | ForEach-Object { $_.path })
    foreach ($required in @(
        "D:\Codex\.codex\skills",
        "D:\Codex\.codex\plugins\cache",
        "D:\Codex\.codex\account_backup",
        "D:\Codex\.codex\account_backup\windows\auth.json",
        "D:\Codex\.codex\account_backup\windows\profile.json",
        "D:\Codex\.codex\account_backup\windows\install_state.json",
        "D:\Codex\.codex\account_backup\windows\quota_cache.json"
    )) {
        Assert-True -Condition ($protectedPaths -contains $required) -Message "缺少保护路径：$required"
    }

    foreach ($item in @($plan.manualReview)) {
        foreach ($property in @("bucket", "groupKey", "path", "risk", "reason", "rule", "automaticCandidate", "applyEligible", "requiresExplicitAuthorization", "blockedBy", "stats")) {
            Assert-Property -Object $item -Name $property
        }

        Assert-True -Condition (-not [bool]$item.automaticCandidate) -Message "人工审查项不得标记为 automaticCandidate：$($item.path)"
        Assert-True -Condition (-not [bool]$item.applyEligible) -Message "人工审查项不得标记为可直接 apply：$($item.path)"
        Assert-True -Condition ([bool]$item.requiresExplicitAuthorization) -Message "人工审查项必须要求显式授权：$($item.path)"
    }

    foreach ($candidate in @($plan.candidates)) {
        foreach ($property in @("bucket", "groupKey", "projectRoot", "backupType", "path", "risk", "reason", "rule", "selectedByRetention", "retainRank", "timestampUtc", "timestampSource", "applyEligible", "requiresExplicitAuthorization", "blockedBy", "stats")) {
            Assert-Property -Object $candidate -Name $property
        }

        Assert-True -Condition ([bool]$candidate.requiresExplicitAuthorization) -Message "候选项必须要求显式授权：$($candidate.path)"
        Assert-True -Condition (-not [bool]$candidate.applyEligible) -Message "dry-run 候选不得标记为可直接 apply：$($candidate.path)"
        Assert-True -Condition ((@($candidate.blockedBy) -join "`n").Contains("重新生成最新 dry-run")) -Message "候选项缺少重新 dry-run 阻塞：$($candidate.path)"
        Assert-True -Condition ([bool]$candidate.selectedByRetention) -Message "候选项必须来自保留规则：$($candidate.path)"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($candidate.timestampSource)) -Message "候选项必须有严格解析的时间戳来源：$($candidate.path)"
    }

    $candidatePaths = @($plan.candidates | ForEach-Object { $_.path })
    $candidateText = $candidatePaths -join "`n"
    foreach ($forbiddenCandidate in @(
        "D:\Codex\.codex\account_backup\windows\login_runtime\plugins",
        "D:\Codex\.codex\account_backup\windows\login_runtime\.tmp\plugins",
        "D:\Codex\.codex\account_backup\windows\refresh_runtime\plugins",
        "D:\Codex\.codex\account_backup\windows\refresh_runtime\.tmp",
        "D:\Codex\.codex\account_backup\_autosave",
        "D:\Codex\.codex\run-evidence",
        "D:\Codex\.codex\backups",
        "D:\Codex\.codex-c-backups"
    )) {
        $hasForbiddenCandidate = @($candidatePaths | Where-Object {
            $_.Equals($forbiddenCandidate, [System.StringComparison]::OrdinalIgnoreCase) -or
                $_.StartsWith("$forbiddenCandidate\", [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        Assert-True -Condition (-not $hasForbiddenCandidate) -Message "高风险或 runtime 路径不得进入保留规则候选：$forbiddenCandidate"
    }

    $manualReviewText = @($plan.manualReview | ForEach-Object { $_.path }) -join "`n"
    foreach ($expectedManual in @(
        "D:\Codex\.codex\account_backup\_autosave",
        "D:\Codex\.codex\run-evidence",
        "D:\Codex\.codex-c-backups"
    )) {
        if (Test-Path -LiteralPath $expectedManual) {
            Assert-True -Condition $manualReviewText.Contains($expectedManual) -Message "高风险路径应进入人工审查：$expectedManual"
        }
    }

    $report = Get-Content -LiteralPath $reportPath -Raw
    foreach ($expected in @("只读", "不删除", "deleteAllowed=false", "auth.json", "profile.json", "plugins", "cache", "sqlite", "人工审查", "严格目录名时间戳", "reparse point", "显式 allowlist")) {
        Assert-True -Condition $report.Contains($expected) -Message "报告缺少预期文本：$expected"
    }
    Assert-True -Condition (-not $report.Contains('$(@')) -Message "报告含有 PowerShell 插值残留"
    Assert-True -Condition (-not ($report -match "、\r?\nun-evidence")) -Message "报告含有 PowerShell 反引号转义污染"

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $blockedDOutput = "D:\Codex\backup-retention-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -OutputDir $blockedDOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于允许的报告目录*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止非授权 D 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedDOutput)) -Message "测试不应在非授权 D 盘目录创建输出目录"

    $unmarkedFixtureOutput = Join-Path $testRoot 'unmarked-fixture-output'
    $blocked = $false
    try {
        & $scriptPath -CodexRoot $fixtureCodexRoot -DDriveRoot $fixtureRoot -OutputDir $unmarkedFixtureOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like '*production context 必须精确使用*'
    }
    Assert-True -Condition $blocked -Message "fixture 根未显式 artifactMode=test 时必须失败"
    Assert-True -Condition (-not (Test-Path -LiteralPath $unmarkedFixtureOutput)) -Message "context 失败时不得创建输出目录"

    New-Item -ItemType Directory -Force -Path (Join-Path $fixtureCodexRoot "backups_state\provider-sync") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $fixtureCodexRoot "backups") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $fixtureCodexRoot "run-evidence\sample-evidence") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $fixtureCodexRoot "account_backup\windows") | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $fixtureCodexRoot "account_backup\windows\install_state.json") | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $fixtureCodexRoot "account_backup\windows\quota_cache.json") | Out-Null

    foreach ($name in @(
        "20260701T000008Z",
        "20260701T000007Z",
        "20260701T000006Z",
        "20260701T000005Z",
        "20260701T000004Z",
        "20260701T000003Z",
        "20260701T000002Z",
        "provider-sync-20260701T000009Z-extra"
    )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $fixtureCodexRoot "backups_state\provider-sync\$name") | Out-Null
    }
    foreach ($name in @(
        "remote-control-recovery-20260701-010101",
        "browser-computer-use-recovery-20260701-010102",
        "codex-plus-live-1781004455649"
    )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $fixtureCodexRoot "backups\$name") | Out-Null
    }

    $codexSwitchBackupRoot = Join-Path $fixtureRoot "apps\codex_switch\backups"
    New-Item -ItemType Directory -Force -Path $codexSwitchBackupRoot | Out-Null
    foreach ($name in @(
        "20260701-010007",
        "20260701-010006",
        "20260701-010005",
        "20260701-010004",
        "20260701-010003",
        "20260701-010002",
        "20260701-010001"
    )) {
        $dir = Join-Path $codexSwitchBackupRoot $name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "codex_switch.exe") -Value "fixture exe $name" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir "WebView2Loader.dll") -Value "fixture loader $name" -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $codexSwitchBackupRoot "codex_switch-before-local-patch-20260625-154636.exe") -Value "legacy flat exe" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $codexSwitchBackupRoot "WebView2Loader-before-local-patch-20260625-154636.dll") -Value "legacy flat loader" -Encoding UTF8
    $incompleteBackup = Join-Path $codexSwitchBackupRoot "before-incomplete-20260701-010008"
    New-Item -ItemType Directory -Force -Path $incompleteBackup | Out-Null
    Set-Content -LiteralPath (Join-Path $incompleteBackup "codex_switch.exe") -Value "missing loader" -Encoding UTF8
    $buildCacheDir = Join-Path $fixtureRoot "projects\codex-account-switch\src-tauri\target\release"
    New-Item -ItemType Directory -Force -Path $buildCacheDir | Out-Null
    Set-Content -LiteralPath (Join-Path $buildCacheDir "codex_switch.exe") -Value "build cache exe" -Encoding UTF8

    $junctionTarget = Join-Path $fixtureRoot "junction-target"
    $junctionPath = Join-Path $fixtureCodexRoot "backups_state\provider-sync\20260701T000003Z\nested-junction"
    New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    } catch {
        Write-Warning "无法创建 junction fixture，跳过嵌套 reparse 降级断言：$($_.Exception.Message)"
    }

    & $scriptPath -ArtifactMode TEST -CodexRoot $fixtureCodexRoot -DDriveRoot $fixtureRoot -OutputDir $fixtureOutput | Out-Null
    $fixturePlan = Get-Content -LiteralPath (Join-Path $fixtureOutput "backup-retention-dry-run.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($fixturePlan.artifactMode -ceq 'test') -Message "fixture 产物必须标记 artifactMode=test"
    Assert-True -Condition ([bool]$fixturePlan.coverageAccounted) -Message "fixture 已枚举直接子项必须计数守恒"
    Assert-True -Condition (-not [bool]$fixturePlan.coverageComplete) -Message "fixture 存在 gap/reparse 时必须 coverageComplete=false"
    foreach ($root in @($fixturePlan.evaluatedRoots)) {
        Assert-True -Condition ($root.directChildCount -eq $root.classificationCount) -Message "根分类数与直接子项数不守恒：$($root.path)"
        Assert-True -Condition ($root.snapshotSha256 -match '^[0-9a-f]{64}$') -Message "根快照缺少 SHA-256：$($root.path)"
    }
    $fixtureCandidatePaths = @($fixturePlan.candidates | ForEach-Object { $_.path }) -join "`n"
    $fixtureManualPaths = @($fixturePlan.manualReview | ForEach-Object { $_.path }) -join "`n"

    $expectedFixtureCandidateCount = if ($junctionCreated) { 3 } else { 4 }
    Assert-True -Condition ($fixturePlan.candidates.Count -eq $expectedFixtureCandidateCount) -Message "fixture 候选数不符合严格保留规则，实际：$($fixturePlan.candidates.Count)"
    Assert-True -Condition $fixtureCandidatePaths.Contains("20260701T000002Z") -Message "严格保留最近 5 个后，应只把第 7 个有效时间戳列为候选"
    Assert-True -Condition (-not $fixtureCandidatePaths.Contains("provider-sync-20260701T000009Z-extra")) -Message "模糊时间戳目录不得进入候选"
    Assert-True -Condition $fixtureManualPaths.Contains("provider-sync-20260701T000009Z-extra") -Message "模糊时间戳目录应进入人工审查"
    Assert-True -Condition (-not $fixtureCandidatePaths.Contains((Join-Path $fixtureCodexRoot "backups\"))) -Message ".codex backups 混合根不得进入候选"
    Assert-True -Condition $fixtureManualPaths.Contains((Join-Path $fixtureCodexRoot "backups")) -Message ".codex backups 混合根应进入人工审查"
    Assert-True -Condition $fixtureManualPaths.Contains((Join-Path $fixtureCodexRoot "run-evidence")) -Message "run-evidence 根应进入人工审查"
    Assert-True -Condition $fixtureCandidatePaths.Contains((Join-Path $codexSwitchBackupRoot "20260701-010002")) -Message "codex_switch 安装回滚备份超过最近 5 个后应进入候选"
    Assert-True -Condition $fixtureCandidatePaths.Contains((Join-Path $codexSwitchBackupRoot "20260701-010001")) -Message "codex_switch 安装回滚备份第 7 个应进入候选"
    Assert-True -Condition (-not $fixtureCandidatePaths.Contains((Join-Path $codexSwitchBackupRoot "20260701-010003"))) -Message "codex_switch 安装回滚备份最近 5 个不得进入候选"
    Assert-True -Condition $fixtureManualPaths.Contains("codex_switch-before-local-patch-20260625-154636.exe") -Message "codex_switch 旧平铺 exe 应进入人工审查"
    Assert-True -Condition $fixtureManualPaths.Contains("WebView2Loader-before-local-patch-20260625-154636.dll") -Message "codex_switch 旧平铺 dll 应进入人工审查"
    Assert-True -Condition $fixtureManualPaths.Contains("before-incomplete-20260701-010008") -Message "缺少 loader 的 codex_switch 回滚目录应进入人工审查"
    Assert-True -Condition (-not $fixtureCandidatePaths.Contains((Join-Path $buildCacheDir "codex_switch.exe"))) -Message "codex-account-switch 构建缓存 exe 不得混入安装回滚候选"

    if ($junctionCreated) {
        Assert-True -Condition (-not $fixtureCandidatePaths.Contains("20260701T000003Z")) -Message "含嵌套 junction 的目录不得进入候选"
        Assert-True -Condition $fixtureManualPaths.Contains("20260701T000003Z") -Message "含嵌套 junction 的目录应进入人工审查"
    }
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-CanRemoveTestRoot -Path $testRoot
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    jsonPath = $jsonPath
    reportPath = $reportPath
}
