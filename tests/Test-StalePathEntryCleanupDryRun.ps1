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
}

$scriptPath = Join-Path $ProjectRoot "scripts\New-StalePathEntryCleanupDryRun.ps1"
$testRoot = Join-Path $ProjectRoot "reports\stale-path-entry-cleanup-dry-run-test"
$fixtureRoot = Join-Path $testRoot "fixture"
$fixtureReadiness = Join-Path $fixtureRoot "readiness.json"
$outputDir = Join-Path $testRoot "out"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到失效 PATH 清理 dry-run 脚本"

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

    $missingVenvPath = "D:\missing-project\.venv\Scripts"
    $existingPath = Join-Path $fixtureRoot "existing-env\Scripts"
    New-Item -ItemType Directory -Force -Path $existingPath | Out-Null

    $fixture = [pscustomobject]@{
        generatedAt = (Get-Date).ToString("o")
        pathSummary = [pscustomobject]@{
            staleLocalEnvironmentEntries = @(
                [pscustomobject]@{
                    index = 1
                    path = $missingVenvPath
                    drive = "D:\"
                    isProjectLocalEnvEntry = $true
                    riskLevel = "medium"
                    recommendedAction = "先确认是否仍有项目依赖；若确认失效，再单独清理 PATH，不重建或删除环境目录。"
                },
                [pscustomobject]@{
                    index = 2
                    path = $existingPath
                    drive = "D:\"
                    isProjectLocalEnvEntry = $true
                    riskLevel = "medium"
                    recommendedAction = "先确认是否仍有项目依赖；若确认失效，再单独清理 PATH，不重建或删除环境目录。"
                }
            )
        }
    }
    $fixture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureReadiness -Encoding UTF8

    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    foreach ($forbidden in @("SetEnvironmentVariable", "Set-ItemProperty", "setx", "reg add", "Remove-Item", "Move-Item")) {
        Assert-True -Condition (-not $scriptText.Contains($forbidden)) -Message "脚本不应包含 PATH 写入、删除或移动命令：$forbidden"
    }

    $result = & $scriptPath -ReadinessPath $fixtureReadiness -OutputDir $outputDir
    Assert-True -Condition ([bool]$result.dryRun) -Message "脚本没有返回 dryRun=true"
    Assert-True -Condition ([bool]$result.readOnly) -Message "脚本没有返回 readOnly=true"
    Assert-True -Condition (-not [bool]$result.executionAllowed) -Message "脚本不应允许执行"

    $jsonPath = Join-Path $outputDir "plan.json"
    $markdownPath = Join-Path $outputDir "PLAN.md"
    Assert-True -Condition (Test-Path -LiteralPath $jsonPath -PathType Leaf) -Message "缺少 plan.json"
    Assert-True -Condition (Test-Path -LiteralPath $markdownPath -PathType Leaf) -Message "缺少 PLAN.md"

    $planJsonText = Get-Content -LiteralPath $jsonPath -Raw
    Assert-True -Condition ($planJsonText -match '"readinessGeneratedAt"\s*:\s*"[^"]*T[^"]*"') -Message "readinessGeneratedAt 应保持 ISO 可读格式"
    $plan = $planJsonText | ConvertFrom-Json
    foreach ($property in @("schemaVersion", "generatedAt", "dryRun", "readOnly", "readinessPath", "readinessGeneratedAt", "summary", "candidates", "policy")) {
        Assert-Property -Object $plan -Name $property
    }

    Assert-True -Condition ([bool]$plan.dryRun) -Message "plan JSON 的 dryRun 不是 true"
    Assert-True -Condition ([bool]$plan.readOnly) -Message "plan JSON 的 readOnly 不是 true"
    Assert-True -Condition (-not [bool]$plan.policy.executionAllowed) -Message "计划不应允许执行"
    Assert-True -Condition (-not [bool]$plan.policy.pathMutationAllowed) -Message "计划不应允许修改 PATH"
    Assert-True -Condition (-not [bool]$plan.policy.registryWriteAllowed) -Message "计划不应允许写系统配置"
    Assert-True -Condition (-not [bool]$plan.policy.deleteAllowed) -Message "计划不应允许删除"
    Assert-True -Condition (-not [bool]$plan.policy.environmentDirectoryWriteAllowed) -Message "计划不应允许写环境目录"
    Assert-True -Condition ($plan.summary.totalCandidates -eq 2) -Message "候选数量错误"
    Assert-True -Condition ($plan.summary.cleanupCandidates -eq 1) -Message "只有缺失路径应作为清理候选"
    Assert-True -Condition ($plan.summary.blockedCandidates -eq 1) -Message "已存在路径应阻塞"

    $cleanupCandidate = $plan.candidates | Where-Object { $_.path -eq $missingVenvPath } | Select-Object -First 1
    Assert-True -Condition ($null -ne $cleanupCandidate) -Message "缺少失效 .venv PATH 候选"
    Assert-True -Condition ($cleanupCandidate.status -eq "cleanup-candidate") -Message "缺失路径应为 cleanup-candidate"
    Assert-True -Condition (-not [bool]$cleanupCandidate.currentExists) -Message "缺失路径 currentExists 应为 false"
    Assert-True -Condition ($cleanupCandidate.proposedAction -like "*不删除、不重建*") -Message "候选动作必须明确不删除不重建"
    Assert-True -Condition ($cleanupCandidate.humanGates.Count -gt 0) -Message "候选缺少人工授权门"
    Assert-True -Condition ($cleanupCandidate.validationSteps.Count -gt 0) -Message "候选缺少验证步骤"
    Assert-True -Condition ($cleanupCandidate.rollbackSteps.Count -gt 0) -Message "候选缺少回滚步骤"

    $blockedCandidate = $plan.candidates | Where-Object { $_.path -eq $existingPath } | Select-Object -First 1
    Assert-True -Condition ($blockedCandidate.status -eq "blocked") -Message "已存在路径应阻塞"
    Assert-True -Condition ((@($blockedCandidate.blockedReasons) -join "`n").Contains("当前已经存在")) -Message "已存在路径缺少阻塞原因"

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    foreach ($expected in @("DRY-RUN", "执行允许：否", "不修改用户 PATH", "不删除或重建", "人工授权门", "回滚步骤", $missingVenvPath)) {
        Assert-True -Condition $markdown.Contains($expected) -Message "PLAN.md 缺少预期文本：$expected"
    }

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -ReadinessPath $fixtureReadiness -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $blockedDOutput = "D:\Codex\stale-path-entry-cleanup-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -ReadinessPath $fixtureReadiness -OutputDir $blockedDOutput | Out-Null
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
