param(
    [string]$ProjectRoot = "D:\agents\projects\统一环境",
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
$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$testRoot = Join-Path $ProjectRoot "reports\stale-path-entry-cleanup-dry-run-test"
$fixtureRoot = Join-Path $testRoot "fixture"
$fixtureReadiness = Join-Path $fixtureRoot "readiness.json"
$fixtureReadinessMarkdown = Join-Path $fixtureRoot "REPORT.md"
$outputDir = Join-Path $testRoot "out"
$candidateJunctionTarget = Join-Path $testRoot "candidate-junction-target"
$candidateJunction = Join-Path $testRoot "candidate-junction"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到失效 PATH 清理 dry-run 脚本"
. $publisherPath

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

    $missingVenvPath = "D:\missing-project\.venv\Scripts"
    $existingPath = Join-Path $fixtureRoot "existing-env\Scripts"
    New-Item -ItemType Directory -Force -Path $existingPath | Out-Null
    New-Item -ItemType Directory -Force -Path $candidateJunctionTarget | Out-Null
    New-Item -ItemType Junction -Path $candidateJunction -Target $candidateJunctionTarget | Out-Null
    $missingUnderJunction = Join-Path $candidateJunction "missing\.venv\Scripts"

    $fixture = [pscustomobject]@{
        artifactType = "env-governance.update-readiness"
        schemaVersion = 3
        generatedAt = (Get-Date).ToString("o")
        pathSummary = [pscustomobject]@{
            sourceScope = "process"
            complete = $true
            cleanupAdviceAllowed = $true
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
                },
                [pscustomobject]@{
                    index = 3
                    path = $missingUnderJunction
                    drive = "D:\"
                    isProjectLocalEnvEntry = $true
                    riskLevel = "medium"
                    recommendedAction = "先确认持久来源。"
                }
            )
        }
    }
    $fixturePair = Publish-JsonMarkdownArtifactPair -Document $fixture -OutputDir $fixtureRoot -JsonFileName "readiness.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { param($d,$h) "# readiness fixture" }

    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    foreach ($forbidden in @("SetEnvironmentVariable", "Set-ItemProperty", "setx", "reg add", "Remove-Item", "Move-Item")) {
        Assert-True -Condition (-not $scriptText.Contains($forbidden)) -Message "脚本不应包含 PATH 写入、删除或移动命令：$forbidden"
    }

    $result = & $scriptPath -ReadinessPath $fixtureReadiness -ReadinessMarkdownPath $fixtureReadinessMarkdown -OutputDir $outputDir
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
    foreach ($property in @("artifactType", "schemaVersion", "generationId", "generatedAt", "dryRun", "readOnly", "readinessPath", "readinessGeneratedAt", "summary", "candidates", "policy")) {
        Assert-Property -Object $plan -Name $property
    }
    $pair = Test-JsonMarkdownArtifactPair -JsonPath $jsonPath -MarkdownPath $markdownPath
    Assert-True -Condition ([bool]$pair.ok) -Message "stale PATH JSON/Markdown pair 校验失败：$($pair.error)"

    Assert-True -Condition ([bool]$plan.dryRun) -Message "plan JSON 的 dryRun 不是 true"
    Assert-True -Condition ([bool]$plan.readOnly) -Message "plan JSON 的 readOnly 不是 true"
    Assert-True -Condition (-not [bool]$plan.policy.executionAllowed) -Message "计划不应允许执行"
    Assert-True -Condition (-not [bool]$plan.policy.pathMutationAllowed) -Message "计划不应允许修改 PATH"
    Assert-True -Condition (-not [bool]$plan.policy.registryWriteAllowed) -Message "计划不应允许写系统配置"
    Assert-True -Condition (-not [bool]$plan.policy.deleteAllowed) -Message "计划不应允许删除"
    Assert-True -Condition (-not [bool]$plan.policy.environmentDirectoryWriteAllowed) -Message "计划不应允许写环境目录"
    Assert-True -Condition ($plan.summary.totalCandidates -eq 3) -Message "候选数量错误"
    Assert-True -Condition ($plan.summary.cleanupCandidates -eq 1) -Message "只有缺失路径应作为清理候选"
    Assert-True -Condition ($plan.summary.blockedCandidates -eq 2) -Message "已存在或 reparse 父链路径应阻塞"

    $cleanupCandidate = $plan.candidates | Where-Object { $_.path -eq $missingVenvPath } | Select-Object -First 1
    Assert-True -Condition ($null -ne $cleanupCandidate) -Message "缺少失效 .venv PATH 候选"
    Assert-True -Condition ($cleanupCandidate.status -eq "cleanup-candidate") -Message "缺失路径应为 cleanup-candidate"
    Assert-True -Condition (-not [bool]$cleanupCandidate.currentExists) -Message "缺失路径 currentExists 应为 false"
    Assert-True -Condition ($cleanupCandidate.proposedAction -like "*不删除、不重建*") -Message "候选动作必须明确不删除不重建"
    Assert-True -Condition ($cleanupCandidate.humanGates.Count -gt 0) -Message "候选缺少人工授权门"
    Assert-True -Condition ($cleanupCandidate.validationSteps.Count -gt 0) -Message "候选缺少验证步骤"
    Assert-True -Condition ($cleanupCandidate.rollbackSteps.Count -gt 0) -Message "候选缺少回滚步骤"
    Assert-True -Condition $cleanupCandidate.proposedAction.Contains("定位持久来源") -Message "Process scope 候选必须先定位持久来源"
    foreach ($forbiddenScopePromise in @("从用户 PATH 中移除", "User scope PATH")) {
        Assert-True -Condition (-not ((@($cleanupCandidate.proposedAction) + @($cleanupCandidate.preflightChecks) + @($cleanupCandidate.rollbackSteps) -join "`n").Contains($forbiddenScopePromise))) -Message "Process scope 不得承诺 User PATH 操作：$forbiddenScopePromise"
    }

    $blockedCandidate = $plan.candidates | Where-Object { $_.path -eq $existingPath } | Select-Object -First 1
    Assert-True -Condition ($blockedCandidate.status -eq "blocked") -Message "已存在路径应阻塞"
    Assert-True -Condition ((@($blockedCandidate.blockedReasons) -join "`n").Contains("当前已经存在")) -Message "已存在路径缺少阻塞原因"
    $reparseCandidate = $plan.candidates | Where-Object { $_.path -eq $missingUnderJunction } | Select-Object -First 1
    Assert-True -Condition ($reparseCandidate.status -eq "blocked") -Message "reparse 父链下缺失路径必须阻塞"
    Assert-True -Condition ((@($reparseCandidate.blockedReasons) -join "`n") -match "reparse|探测") -Message "reparse 父链阻塞必须保留原因"

    foreach ($case in @(
        @{ name = "schema2"; artifactType = "env-governance.update-readiness"; schemaVersion = 2; sourceScope = "process"; complete = $true },
        @{ name = "wrong-artifact"; artifactType = "wrong"; schemaVersion = 3; sourceScope = "process"; complete = $true },
        @{ name = "wrong-scope"; artifactType = "env-governance.update-readiness"; schemaVersion = 3; sourceScope = "user"; complete = $true },
        @{ name = "incomplete"; artifactType = "env-governance.update-readiness"; schemaVersion = 3; sourceScope = "process"; complete = $false; cleanupAdviceAllowed = $true },
        @{ name = "advice-disabled"; artifactType = "env-governance.update-readiness"; schemaVersion = 3; sourceScope = "process"; complete = $true; cleanupAdviceAllowed = $false }
    )) {
        $invalid = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $invalid.artifactType = $case.artifactType
        $invalid.schemaVersion = $case.schemaVersion
        $invalid.pathSummary.sourceScope = $case.sourceScope
        $invalid.pathSummary.complete = $case.complete
        if ($case.ContainsKey("cleanupAdviceAllowed")) { $invalid.pathSummary.cleanupAdviceAllowed = $case.cleanupAdviceAllowed }
        if ($case.name -eq "duplicate-candidate") { $invalid.pathSummary.staleLocalEnvironmentEntries = @($invalid.pathSummary.staleLocalEnvironmentEntries) + @($invalid.pathSummary.staleLocalEnvironmentEntries[0]) }
        $invalidInputDir = Join-Path $testRoot "input-$($case.name)"
        $invalidPair = Publish-JsonMarkdownArtifactPair -Document $invalid -OutputDir $invalidInputDir -JsonFileName "readiness.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { param($d,$h) "# invalid fixture" }
        $invalidPath = $invalidPair.jsonPath
        $invalidOutput = Join-Path $testRoot "reject-$($case.name)"
        New-Item -ItemType Directory -Force -Path $invalidOutput | Out-Null
        $sentinelJson = Join-Path $invalidOutput "plan.json"
        $sentinelMarkdown = Join-Path $invalidOutput "PLAN.md"
        Set-Content -LiteralPath $sentinelJson -Value "old-json" -NoNewline
        Set-Content -LiteralPath $sentinelMarkdown -Value "old-markdown" -NoNewline
        $rejected = $false
        try { & $scriptPath -ReadinessPath $invalidPath -ReadinessMarkdownPath $invalidPair.markdownPath -OutputDir $invalidOutput | Out-Null } catch { $rejected = $true }
        Assert-True -Condition $rejected -Message "stale PATH 未拒绝不可信 readiness：$($case.name)"
        Assert-True -Condition ((Get-Content -LiteralPath $sentinelJson -Raw) -ceq "old-json") -Message "失败关闭不得覆盖旧 plan.json：$($case.name)"
        Assert-True -Condition ((Get-Content -LiteralPath $sentinelMarkdown -Raw) -ceq "old-markdown") -Message "失败关闭不得覆盖旧 PLAN.md：$($case.name)"
    }

    $duplicateInvalid = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String
    $duplicateInvalid.pathSummary.staleLocalEnvironmentEntries = @($duplicateInvalid.pathSummary.staleLocalEnvironmentEntries) + @($duplicateInvalid.pathSummary.staleLocalEnvironmentEntries[0])
    $duplicatePair = Publish-JsonMarkdownArtifactPair -Document $duplicateInvalid -OutputDir (Join-Path $testRoot "input-duplicate-candidate") -JsonFileName "readiness.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { param($d,$h) "# duplicate fixture" }
    $duplicateOutput = Join-Path $testRoot "reject-duplicate-candidate"
    $duplicateBlocked = $false
    try { & $scriptPath -ReadinessPath $duplicatePair.jsonPath -ReadinessMarkdownPath $duplicatePair.markdownPath -OutputDir $duplicateOutput | Out-Null } catch { $duplicateBlocked = $true }
    Assert-True -Condition $duplicateBlocked -Message "重复 candidateId 必须失败关闭或去重"
    Assert-True -Condition (-not (Test-Path -LiteralPath $duplicateOutput)) -Message "重复 candidateId 不得创建输出"

    $tamperedPair = Publish-JsonMarkdownArtifactPair -Document ($fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String) -OutputDir (Join-Path $testRoot "input-tampered-pair") -JsonFileName "readiness.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { param($d,$h) "# tampered fixture" }
    $tamperedReadinessMarkdown = (Get-Content -LiteralPath $tamperedPair.markdownPath -Raw) -replace '(?m)^generationId:\s*[^\r\n]+$', 'generationId: 00000000-0000-0000-0000-000000000000'
    Set-Content -LiteralPath $tamperedPair.markdownPath -Value $tamperedReadinessMarkdown -NoNewline
    $tamperedOutput = Join-Path $testRoot "reject-tampered-pair"
    New-Item -ItemType Directory -Force -Path $tamperedOutput | Out-Null
    Set-Content -LiteralPath (Join-Path $tamperedOutput "plan.json") -Value "old-json" -NoNewline
    Set-Content -LiteralPath (Join-Path $tamperedOutput "PLAN.md") -Value "old-markdown" -NoNewline
    $tamperedBlocked = $false
    try { & $scriptPath -ReadinessPath $tamperedPair.jsonPath -ReadinessMarkdownPath $tamperedPair.markdownPath -OutputDir $tamperedOutput | Out-Null } catch { $tamperedBlocked = $true }
    Assert-True -Condition $tamperedBlocked -Message "stale PATH 必须拒绝篡改的 readiness pair"
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $tamperedOutput "plan.json") -Raw) -ceq "old-json") -Message "篡改 pair 不得覆盖旧 plan.json"
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $tamperedOutput "PLAN.md") -Raw) -ceq "old-markdown") -Message "篡改 pair 不得覆盖旧 PLAN.md"

    $missingPairOutput = Join-Path $testRoot "reject-missing-pair"
    $missingPairBlocked = $false
    try { & $scriptPath -ReadinessPath $fixtureReadiness -ReadinessMarkdownPath (Join-Path $testRoot "missing-REPORT.md") -OutputDir $missingPairOutput | Out-Null } catch { $missingPairBlocked = $true }
    Assert-True -Condition $missingPairBlocked -Message "stale PATH 必须拒绝缺失的 readiness Markdown"
    Assert-True -Condition (-not (Test-Path -LiteralPath $missingPairOutput)) -Message "缺失 pair 不得创建输出"

    $mismatchA = Publish-JsonMarkdownArtifactPair -Document ($fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String) -OutputDir (Join-Path $testRoot "input-mismatch-a") -JsonFileName "readiness.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { param($d,$h) "# mismatch A" }
    $mismatchB = Publish-JsonMarkdownArtifactPair -Document ($fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String) -OutputDir (Join-Path $testRoot "input-mismatch-b") -JsonFileName "readiness.json" -MarkdownFileName "REPORT.md" -RenderMarkdown { param($d,$h) "# mismatch B" }
    $mismatchOutput = Join-Path $testRoot "reject-mismatch-pair"
    $mismatchBlocked = $false
    try { & $scriptPath -ReadinessPath $mismatchA.jsonPath -ReadinessMarkdownPath $mismatchB.markdownPath -OutputDir $mismatchOutput | Out-Null } catch { $mismatchBlocked = $true }
    Assert-True -Condition $mismatchBlocked -Message "stale PATH 必须拒绝跨 generation 的 readiness pair"
    Assert-True -Condition (-not (Test-Path -LiteralPath $mismatchOutput)) -Message "错配 pair 不得创建输出"

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    foreach ($expected in @("DRY-RUN", "执行允许：否", "不修改任何 PATH scope", "不删除或重建", "人工授权门", "回滚步骤", $missingVenvPath)) {
        Assert-True -Condition $markdown.Contains($expected) -Message "PLAN.md 缺少预期文本：$expected"
    }

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -ReadinessPath $fixtureReadiness -ReadinessMarkdownPath $fixtureReadinessMarkdown -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $blockedDOutput = "D:\Codex\stale-path-entry-cleanup-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -ReadinessPath $fixtureReadiness -ReadinessMarkdownPath $fixtureReadinessMarkdown -OutputDir $blockedDOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于允许的报告目录*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止非授权 D 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedDOutput)) -Message "测试不应在非授权 D 盘目录创建输出目录"
} finally {
    if (Test-Path -LiteralPath $candidateJunction) {
        $junctionItem = Get-Item -LiteralPath $candidateJunction -Force
        if (($junctionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $junctionItem.Delete() }
    }
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
