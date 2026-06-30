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

$scriptPath = Join-Path $ProjectRoot "scripts\Invoke-PipCacheMigration.ps1"
$testRoot = Join-Path $ProjectRoot "reports\env-migration-execution-test"
$source = Join-Path $testRoot "source-pip-cache"
$target = Join-Path $testRoot "target-pip-cache"
$evidence = Join-Path $testRoot "evidence"
$planPath = Join-Path $testRoot "plan.json"
$badPlanPath = Join-Path $testRoot "bad-plan.json"
$envName = "CODEX_TEST_PIP_CACHE_DIR"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到 pip cache 迁移脚本"

$previousEnvValue = [Environment]::GetEnvironmentVariable($envName, "Process")

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $source "http") | Out-Null
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Set-Content -LiteralPath (Join-Path $source "http\new-cache-file.txt") -Value "new" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $source "existing-cache-file.txt") -Value "source-existing" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target "existing-cache-file.txt") -Value "target-existing" -Encoding UTF8

    $plan = [pscustomobject]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString("o")
        readOnly = $true
        migrationPlans = @(
            [pscustomobject]@{
                id = "migration-01-python-cache"
                source = $source
                target = $target
                kind = "cache"
                owner = "python"
                risk = "low"
                requiresExplicitUserApproval = $true
            }
        )
    }
    $plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding UTF8

    [Environment]::SetEnvironmentVariable($envName, "D:\Codex\previous-test-cache", "Process")

    $result = & $scriptPath `
        -MigrationPlanPath $planPath `
        -EvidenceDir $evidence `
        -EnvironmentScope Process `
        -EnvironmentVariableName $envName `
        -ConfirmAuthorized

    Assert-True -Condition ($result.mode -eq "Execute") -Message "迁移脚本未返回 Execute 结果"
    Assert-True -Condition ($result.currentScopedValue -eq $target) -Message "迁移后环境变量未指向目标缓存"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $target "http\new-cache-file.txt") -PathType Leaf) -Message "目标缺少复制的新缓存文件"
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $target "existing-cache-file.txt") -Raw).Trim() -eq "target-existing") -Message "目标已有文件不应被覆盖"
    Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message "源目录必须保留"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $evidence "execution.json") -PathType Leaf) -Message "缺少 execution.json"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $evidence "EXECUTION.md") -PathType Leaf) -Message "缺少 EXECUTION.md"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $evidence "rollback-state.json") -PathType Leaf) -Message "缺少 rollback-state.json"

    $execution = Get-Content -LiteralPath (Join-Path $evidence "execution.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($execution.preExecutionPlanMigrationCount -eq 1) -Message "execution.json 必须记录执行前 dry-run 计划项数量"
    Assert-True -Condition (($execution.preExecutionPlanIds | Select-Object -First 1) -eq "migration-01-python-cache") -Message "execution.json 必须记录执行前 dry-run 计划项"
    Assert-True -Condition ($execution.preExecutionPlanEntry.source -eq $source) -Message "execution.json 必须嵌入执行前 dry-run source"
    Assert-True -Condition ($execution.preExecutionPlanEntry.target -eq $target) -Message "execution.json 必须嵌入执行前 dry-run target"
    Assert-True -Condition ([bool]$execution.sourceRetained) -Message "execution.json 必须记录源目录保留"
    Assert-True -Condition (-not [bool]$execution.sourceDeleted) -Message "execution.json 不应记录源目录删除"
    Assert-True -Condition ($execution.copySummary.copiedFiles -eq 1) -Message "应只复制缺失文件"
    Assert-True -Condition ($execution.copySummary.skippedExistingFiles -eq 1) -Message "应跳过目标已有文件"

    $report = Get-Content -LiteralPath (Join-Path $evidence "EXECUTION.md") -Raw
    foreach ($expected in @("旧源目录默认保留", "不删除 C 盘目录", "执行前 dry-run", "回滚")) {
        Assert-True -Condition $report.Contains($expected) -Message "EXECUTION.md 缺少预期文本：$expected"
    }

    $rollback = & $scriptPath `
        -Mode Rollback `
        -StatePath (Join-Path $evidence "rollback-state.json")

    Assert-True -Condition ($rollback.mode -eq "Rollback") -Message "回滚脚本未返回 Rollback 结果"
    Assert-True -Condition ($rollback.environmentVariableName -eq $envName) -Message "回滚应默认读取 state 中的环境变量名"
    Assert-True -Condition ($rollback.environmentScope -eq "Process") -Message "回滚应默认读取 state 中的作用域"
    Assert-True -Condition ([Environment]::GetEnvironmentVariable($envName, "Process") -eq "D:\Codex\previous-test-cache") -Message "回滚未恢复迁移前环境变量"

    $badUserScopeBlocked = $false
    try {
        & $scriptPath -MigrationPlanPath $planPath -EvidenceDir $evidence -EnvironmentScope User -EnvironmentVariableName "Path" -ConfirmAuthorized | Out-Null
    } catch {
        $badUserScopeBlocked = $_.Exception.Message -like "*只允许写入 PIP_CACHE_DIR*"
    }
    Assert-True -Condition $badUserScopeBlocked -Message "User 作用域不应允许写入非 PIP_CACHE_DIR 环境变量"

    $badPlan = [pscustomobject]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString("o")
        readOnly = $true
        migrationPlans = @(
            [pscustomobject]@{
                id = "migration-01-python-cache"
                source = $source
                target = $target
                kind = "cache"
                owner = "python"
                risk = "low"
                requiresExplicitUserApproval = $true
            }
        )
    }
    $badPlan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $badPlanPath -Encoding UTF8
    $badSourceBlocked = $false
    try {
        & $scriptPath -MigrationPlanPath $badPlanPath -EvidenceDir $evidence -EnvironmentScope Process -ConfirmAuthorized | Out-Null
    } catch {
        $badSourceBlocked = $_.Exception.Message -like "*source 必须是当前用户 pip 默认缓存*"
    }
    Assert-True -Condition $badSourceBlocked -Message "PIP_CACHE_DIR 迁移必须强校验 source 是当前用户 pip 默认缓存"

    $blockedEvidence = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath -MigrationPlanPath $planPath -EvidenceDir $blockedEvidence -EnvironmentScope Process -EnvironmentVariableName $envName -ConfirmAuthorized | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "迁移脚本没有阻止 C 盘 EvidenceDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedEvidence)) -Message "测试不应在 C 盘创建证据目录"
} finally {
    [Environment]::SetEnvironmentVariable($envName, $previousEnvValue, "Process")

    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    evidence = $evidence
}
