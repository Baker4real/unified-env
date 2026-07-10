param(
    [string]$OutputDir = '',
    [int]$RetainCount = 5,
    [string]$CodexRoot = 'D:\Codex\.codex',
    [string]$DDriveRoot = 'D:\Codex',
    [ValidateSet('production', 'test')][string]$ArtifactMode = 'production'
)

$ErrorActionPreference = 'Stop'

$libraryRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libraryRoot 'BackupRetentionPolicy.ps1')
. (Join-Path $libraryRoot 'ReportArtifactPublisher.ps1')

function Test-BackupRetentionOutputSubPath {
    param([string]$Path, [string]$BasePath)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullBase = [IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    return $fullPath.Equals($fullBase, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$fullBase\", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-BackupRetentionOutputDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-BackupRetentionDPath -Path $Path -Name 'OutputDir'
    $allowedRoots = @(
        'D:\Codex\projects\统一环境\reports',
        'D:\Codex\.codex\run-evidence\env-governance'
    )
    if (@($allowedRoots | Where-Object { Test-BackupRetentionOutputSubPath -Path $fullPath -BasePath $_ }).Count -eq 0) {
        throw 'OutputDir 必须位于允许的报告目录：D:\Codex\projects\统一环境\reports 或 D:\Codex\.codex\run-evidence\env-governance。'
    }
    return $fullPath
}

function Escape-BackupRetentionMarkdownCell {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ("$Value" -replace '\|', '\|' -replace "`r", ' ' -replace "`n", ' ').Trim()
}

$context = New-BackupRetentionPolicyContext `
    -ArtifactMode $ArtifactMode `
    -CodexRoot $CodexRoot `
    -DDriveRoot $DDriveRoot `
    -RetainCount $RetainCount

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = "D:\Codex\.codex\run-evidence\env-governance\backup-retention-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
$OutputDir = Assert-BackupRetentionOutputDirectory -Path $OutputDir

$evaluation = Invoke-BackupRetentionEvaluation -PolicyContext $context
$candidateBytes = [int64](($evaluation.candidates | ForEach-Object { if ($null -ne $_.stats) { [int64]$_.stats.bytes } else { 0 } } | Measure-Object -Sum).Sum)
$manualBytes = [int64](($evaluation.manualReview | ForEach-Object { if ($null -ne $_.stats) { [int64]$_.stats.bytes } else { 0 } } | Measure-Object -Sum).Sum)

$policy = [pscustomobject][ordered]@{
    policyId = $context.policyId
    policyVersion = $context.policyVersion
    summary = '只读 dry-run；不删除、不移动、不迁移；真实清理必须另行显式授权。'
    protectedRootsCannotBeDeleted = $true
    explicitAuthorizationRequired = $true
    applyMustRegenerateDryRun = $true
    applyMustCheckReparsePoints = $true
    applyMustUseAllowlist = $true
    strictTimestampRequired = $true
    runtimeSharedDirsExcluded = $true
    authAutosaveExcludedByDefault = $true
}

$summary = [pscustomobject][ordered]@{
    declaredScanRootCount = @($evaluation.declaredScanRoots).Count
    evaluatedRootCount = @($evaluation.evaluatedRoots).Count
    coverageItemCount = @($evaluation.coverageItems).Count
    candidateCount = @($evaluation.candidates).Count
    retainedCount = @($evaluation.retainedItems).Count
    protectedCount = @($evaluation.protected).Count
    manualReviewCount = @($evaluation.manualReview).Count
    gapCount = @($evaluation.unclassifiedCoverageGaps).Count
    candidateBytes = $candidateBytes
    candidateMb = [math]::Round(($candidateBytes / 1MB), 2)
    manualReviewBytes = $manualBytes
    manualReviewMb = [math]::Round(($manualBytes / 1MB), 2)
    candidateSkillMd = [int](($evaluation.candidates | ForEach-Object { if ($null -ne $_.stats) { [int]$_.stats.skillMd } else { 0 } } | Measure-Object -Sum).Sum)
    selectedByRetentionCount = @($evaluation.candidates).Count
    lowRiskCount = @($evaluation.candidates | Where-Object risk -eq '低').Count
    mediumRiskCount = @($evaluation.candidates | Where-Object risk -eq '中').Count
    highRiskCount = @($evaluation.candidates | Where-Object risk -eq '高').Count
    byBucket = @($evaluation.candidates | Group-Object bucket | ForEach-Object { [pscustomobject]@{ bucket = $_.Name; count = $_.Count } })
    manualByBucket = @($evaluation.manualReview | Group-Object bucket | ForEach-Object { [pscustomobject]@{ bucket = $_.Name; count = $_.Count } })
}

$document = [pscustomobject][ordered]@{
    artifactType = 'env-governance.backup-retention-dry-run'
    schemaVersion = 2
    artifactMode = $context.artifactMode
    generatedAtLocal = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    dryRun = $true
    readOnly = $true
    deleteAllowed = $false
    applySupported = $false
    executionAllowed = $false
    CodexRoot = $context.CodexRoot
    DDriveRoot = $context.DDriveRoot
    retainCount = $context.retainCount
    policyId = $context.policyId
    policyVersion = $context.policyVersion
    policy = $policy
    declaredScanRoots = [object[]]$evaluation.declaredScanRoots
    evaluatedRoots = [object[]]$evaluation.evaluatedRoots
    coverageItems = [object[]]$evaluation.coverageItems
    candidates = [object[]]$evaluation.candidates
    retainedItems = [object[]]$evaluation.retainedItems
    protected = [object[]]$evaluation.protected
    manualReview = [object[]]$evaluation.manualReview
    unclassifiedCoverageGaps = [object[]]$evaluation.unclassifiedCoverageGaps
    coverageAccounted = [bool]$evaluation.coverageAccounted
    coverageComplete = [bool]$evaluation.coverageComplete
    coverageNotes = [object[]]$evaluation.coverageNotes
    errors = [object[]]$evaluation.errors
    summary = $summary
}

$published = Publish-JsonMarkdownArtifactPair `
    -Document $document `
    -OutputDir $OutputDir `
    -JsonFileName 'backup-retention-dry-run.json' `
    -MarkdownFileName 'BACKUP-RETENTION-DRY-RUN.md' `
    -RenderMarkdown {
        param($Document, $JsonSha256)

        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('# 备份保留清理 dry-run 报告')
        $lines.Add('')
        $lines.Add("生成时间：$($Document.generatedAtLocal)")
        $lines.Add('')
        $lines.Add("产物模式：$($Document.artifactMode)；覆盖完整：$($Document.coverageComplete)；源 JSON SHA-256：$JsonSha256")
        $lines.Add('')
        $lines.Add('本报告只读生成，不删除、不移动、不迁移任何文件。deleteAllowed=false。')
        $lines.Add('')
        $lines.Add('## 覆盖结论')
        $lines.Add('')
        $lines.Add("- coverageAccounted：$($Document.coverageAccounted)")
        $lines.Add("- coverageComplete：$($Document.coverageComplete)")
        $lines.Add("- 显式 allowlist 扫描根：$(@($Document.declaredScanRoots).Count) 个")
        $lines.Add("- 账本项：$(@($Document.coverageItems).Count) 个；未分类 gap：$(@($Document.unclassifiedCoverageGaps).Count) 个")
        foreach ($note in @($Document.coverageNotes)) { $lines.Add("- $note") }
        $lines.Add('')
        $lines.Add('## 分类汇总')
        $lines.Add('')
        $lines.Add("- 保留 retained：$(@($Document.retainedItems).Count) 个")
        $lines.Add("- 候选 candidate：$(@($Document.candidates).Count) 个")
        $lines.Add("- 保护 protected：$(@($Document.protected).Count) 个")
        $lines.Add("- 人工审查：$(@($Document.manualReview).Count) 个")
        $lines.Add('')
        $lines.Add('## 声明扫描根')
        $lines.Add('')
        $lines.Add('| 根 | 枚举 started/completed | 直接子项/分类 | 错误 | 快照 SHA-256 |')
        $lines.Add('| --- | --- | ---: | ---: | --- |')
        foreach ($root in @($Document.evaluatedRoots)) {
            $lines.Add("| $(Escape-BackupRetentionMarkdownCell $root.path) | $($root.enumerationStarted) / $($root.enumerationCompleted) | $($root.directChildCount) / $($root.classificationCount) | $(@($root.errors).Count) | $($root.snapshotSha256) |")
        }
        $lines.Add('')
        $lines.Add('## 候选项')
        $lines.Add('')
        $lines.Add('| 组 | 排名 | 严格目录名时间戳 | 路径 |')
        $lines.Add('| --- | ---: | --- | --- |')
        foreach ($item in @($Document.candidates)) {
            $lines.Add("| $(Escape-BackupRetentionMarkdownCell $item.groupKey) | $($item.retainRank) | $(Escape-BackupRetentionMarkdownCell $item.timestampSource) | $(Escape-BackupRetentionMarkdownCell $item.path) |")
        }
        $lines.Add('')
        $lines.Add('## 硬边界')
        $lines.Add('')
        $lines.Add('- 本脚本不支持 apply；任何真实删除都需要显式授权。')
        $lines.Add('- auth.json、profile.json、install_state.json、quota_cache.json、plugins、cache、sqlite 均受保护。')
        $lines.Add('- 命中 junction、symlink 或 reparse point 的根/子项失败关闭。')
        $lines.Add('- 保留规则只使用严格目录名时间戳，不使用 mtime 兜底。')
        $lines.Add('')
        return $lines.ToArray() -join "`n"
    }

[pscustomobject]@{
    ok = $true
    dryRun = $true
    readOnly = $true
    deleteAllowed = $false
    artifactMode = $context.artifactMode
    coverageAccounted = $document.coverageAccounted
    coverageComplete = $document.coverageComplete
    outputDir = $OutputDir
    jsonPath = $published.jsonPath
    reportPath = $published.markdownPath
    candidateCount = $summary.candidateCount
    candidateMb = $summary.candidateMb
    manualReviewCount = $summary.manualReviewCount
    manualReviewMb = $summary.manualReviewMb
}
