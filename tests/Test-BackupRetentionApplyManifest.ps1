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

$dryRunScriptPath = Join-Path $ProjectRoot "scripts\New-BackupRetentionDryRun.ps1"
$manifestScriptPath = Join-Path $ProjectRoot "scripts\New-BackupRetentionApplyManifest.ps1"
$testRoot = Join-Path $ProjectRoot "reports\backup-retention-apply-manifest-test"
$fixtureRoot = Join-Path $testRoot "fixture"
$fixtureCodexRoot = Join-Path $fixtureRoot ".codex"
$dryRunOutput = Join-Path $testRoot "dry-run"
$manifestOutput = Join-Path $testRoot "manifest"

Assert-True -Condition (Test-Path -LiteralPath $dryRunScriptPath -PathType Leaf) -Message "找不到备份保留 dry-run 脚本"
Assert-True -Condition (Test-Path -LiteralPath $manifestScriptPath -PathType Leaf) -Message "找不到 apply manifest 脚本"

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    $scriptSource = Get-Content -LiteralPath $manifestScriptPath -Raw
    Assert-True -Condition (-not ($scriptSource -match "\bRemove-Item\b")) -Message "apply manifest 脚本不得包含 Remove-Item"
    Assert-True -Condition (-not ($scriptSource -match "\bMove-Item\b")) -Message "apply manifest 脚本不得包含 Move-Item"

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
        "20260701T000002Z"
    )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $fixtureCodexRoot "backups_state\provider-sync\$name") | Out-Null
    }

    & $dryRunScriptPath -CodexRoot $fixtureCodexRoot -DDriveRoot $fixtureRoot -OutputDir $dryRunOutput | Out-Null
    $dryRunJson = Join-Path $dryRunOutput "backup-retention-dry-run.json"
    $dryRunPlan = Get-Content -LiteralPath $dryRunJson -Raw | ConvertFrom-Json
    Assert-True -Condition (@($dryRunPlan.candidates).Count -eq 2) -Message "fixture 应生成 2 个保留规则候选"

    $result = & $manifestScriptPath -DryRunJson $dryRunJson -UseAllDryRunCandidates -OutputDir $manifestOutput
    Assert-True -Condition ([bool]$result.applyManifestOnly) -Message "脚本没有返回 applyManifestOnly=true"
    Assert-True -Condition ([bool]$result.readOnly) -Message "脚本没有返回 readOnly=true"
    Assert-True -Condition (-not [bool]$result.deleteAllowed) -Message "脚本不应允许删除"
    Assert-True -Condition (-not [bool]$result.executionReady) -Message "manifest 不应直接进入执行态"
    Assert-True -Condition ([int]$result.readyForFinalAuthorizationCount -eq 2) -Message "fixture manifest 应有 2 个通过二次校验的路径"

    $manifestPath = Join-Path $manifestOutput "backup-retention-apply-manifest.json"
    $reportPath = Join-Path $manifestOutput "BACKUP-RETENTION-APPLY-MANIFEST.md"
    Assert-True -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Message "缺少 backup-retention-apply-manifest.json"
    Assert-True -Condition (Test-Path -LiteralPath $reportPath -PathType Leaf) -Message "缺少 BACKUP-RETENTION-APPLY-MANIFEST.md"

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($property in @("schemaVersion", "manifestId", "applyManifestOnly", "readOnly", "deleteAllowed", "executionReady", "selectionMode", "sourceDryRun", "policy", "summary", "items", "blockedItems")) {
        Assert-Property -Object $manifest -Name $property
    }

    Assert-True -Condition ([bool]$manifest.applyManifestOnly) -Message "JSON applyManifestOnly 不是 true"
    Assert-True -Condition ([bool]$manifest.readOnly) -Message "JSON readOnly 不是 true"
    Assert-True -Condition (-not [bool]$manifest.deleteAllowed) -Message "JSON deleteAllowed 应为 false"
    Assert-True -Condition (-not [bool]$manifest.executionReady) -Message "JSON executionReady 应为 false"
    Assert-True -Condition ([bool]$manifest.policy.requiresFinalUserAuthorization) -Message "策略必须要求最终授权"
    Assert-True -Condition ([bool]$manifest.policy.stateFingerprintRequired) -Message "策略必须要求状态指纹"
    Assert-True -Condition ([bool]$manifest.policy.reparsePointCheckRequired) -Message "策略必须要求 reparse point 检查"

    foreach ($item in @($manifest.items)) {
        foreach ($property in @("candidateId", "selected", "validationStatus", "blockers", "path", "risk", "retainRank", "timestampUtc", "timestampSource", "plannedOperation", "originalStats", "currentStats", "reparse")) {
            Assert-Property -Object $item -Name $property
        }

        Assert-True -Condition ([bool]$item.selected) -Message "manifest item 必须显式 selected"
        Assert-True -Condition ($item.validationStatus -eq "ready-for-final-authorization") -Message "fixture item 应通过二次校验：$($item.path)"
        Assert-True -Condition ($item.plannedOperation -eq "recursive-delete-directory-after-final-confirmation") -Message "plannedOperation 不符合预期"
        Assert-True -Condition (-not [bool]$item.reparse.hasReparsePoint) -Message "fixture item 不应命中 reparse point"
    }

    $report = Get-Content -LiteralPath $reportPath -Raw
    foreach ($expected in @("deleteAllowed=false", "executionReady=false", "最终授权", "二次校验", "manifest id", "不删除")) {
        Assert-True -Condition $report.Contains($expected) -Message "报告缺少预期文本：$expected"
    }

    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $dryRunJson -OutputDir (Join-Path $testRoot "missing-selection") | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须指定 -UseAllDryRunCandidates*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止缺少选择模式的 manifest 生成"

    $manualReviewPath = Join-Path $fixtureCodexRoot "run-evidence"
    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $dryRunJson -AllowPath $manualReviewPath -OutputDir (Join-Path $testRoot "manual-review-blocked") | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*不在 dry-run candidates 中*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止人工审查路径进入 manifest"

    $candidatePath = @($dryRunPlan.candidates | Select-Object -First 1)[0].path
    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $dryRunJson -AllowPath @($candidatePath, $candidatePath) -OutputDir (Join-Path $testRoot "duplicate-allowpath-blocked") | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*AllowPath 重复*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止重复 AllowPath"

    $forgedCDrivePlan = $dryRunPlan | ConvertTo-Json -Depth 18 | ConvertFrom-Json
    $forgedCDrivePlan.candidates[0].path = "C:\Codex-forged-candidate"
    $forgedCDriveJson = Join-Path $testRoot "forged-c-drive-dry-run.json"
    $forgedCDrivePlan | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $forgedCDriveJson -Encoding UTF8
    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $forgedCDriveJson -UseAllDryRunCandidates -OutputDir (Join-Path $testRoot "forged-c-drive-blocked") | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*Candidate.path 必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止伪造 C 盘 candidate"

    $forgedAncestorPlan = $dryRunPlan | ConvertTo-Json -Depth 18 | ConvertFrom-Json
    $forgedAncestorPlan.candidates[0].path = $fixtureCodexRoot
    $forgedAncestorJson = Join-Path $testRoot "forged-ancestor-dry-run.json"
    $forgedAncestorPlan | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $forgedAncestorJson -Encoding UTF8
    $forgedAncestorOutput = Join-Path $testRoot "forged-ancestor-manifest"
    & $manifestScriptPath -DryRunJson $forgedAncestorJson -UseAllDryRunCandidates -OutputDir $forgedAncestorOutput | Out-Null
    $forgedAncestorManifest = Get-Content -LiteralPath (Join-Path $forgedAncestorOutput "backup-retention-apply-manifest.json") -Raw | ConvertFrom-Json
    $ancestorBlockers = @($forgedAncestorManifest.blockedItems | ForEach-Object { @($_.blockers) -join "`n" }) -join "`n"
    Assert-True -Condition $ancestorBlockers.Contains("候选路径是保护路径的祖先") -Message "脚本没有阻止保护路径祖先 candidate"
    Assert-True -Condition $ancestorBlockers.Contains("候选路径是人工审查路径的祖先") -Message "脚本没有阻止人工审查路径祖先 candidate"

    $futurePlan = $dryRunPlan | ConvertTo-Json -Depth 18 | ConvertFrom-Json
    $futurePlan.generatedAtUtc = (Get-Date).ToUniversalTime().AddHours(1).ToString("o")
    $futureJson = Join-Path $testRoot "future-dry-run.json"
    $futurePlan | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $futureJson -Encoding UTF8
    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $futureJson -UseAllDryRunCandidates -OutputDir (Join-Path $testRoot "future-blocked") | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*生成时间来自未来*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止未来 dry-run"

    $oldPlan = $dryRunPlan | ConvertTo-Json -Depth 18 | ConvertFrom-Json
    $oldPlan.generatedAtUtc = (Get-Date).ToUniversalTime().AddHours(-25).ToString("o")
    $oldJson = Join-Path $testRoot "old-dry-run.json"
    $oldPlan | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $oldJson -Encoding UTF8
    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $oldJson -UseAllDryRunCandidates -OutputDir (Join-Path $testRoot "old-blocked") | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*已超过*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止过期 dry-run"

    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $dryRunJson -UseAllDryRunCandidates -MaxDryRunAgeHours 72 -OutputDir (Join-Path $testRoot "too-wide-age-blocked") | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*不能超过 24*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止过大的 MaxDryRunAgeHours"

    $blockedOutput = "C:\Codex-apply-manifest-should-not-be-created"
    $blocked = $false
    try {
        & $manifestScriptPath -DryRunJson $dryRunJson -UseAllDryRunCandidates -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $driftCandidate = @($dryRunPlan.candidates | Select-Object -First 1)[0]
    New-Item -ItemType File -Force -Path (Join-Path $driftCandidate.path "state-drift.txt") | Out-Null
    $driftOutput = Join-Path $testRoot "manifest-drift"
    & $manifestScriptPath -DryRunJson $dryRunJson -UseAllDryRunCandidates -OutputDir $driftOutput | Out-Null
    $driftManifest = Get-Content -LiteralPath (Join-Path $driftOutput "backup-retention-apply-manifest.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ([int]$driftManifest.summary.blockedCount -ge 1) -Message "当前状态漂移后应产生阻塞项"
    $driftText = @($driftManifest.blockedItems | ForEach-Object { @($_.blockers) -join "`n" }) -join "`n"
    Assert-True -Condition $driftText.Contains("dry-run 快照不一致") -Message "状态漂移阻塞原因应说明快照不一致"
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-CanRemoveTestRoot -Path $testRoot
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    manifestPath = $manifestPath
    reportPath = $reportPath
}
