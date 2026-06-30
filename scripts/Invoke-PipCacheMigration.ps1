param(
    [ValidateSet("Execute", "Rollback")]
    [string]$Mode = "Execute",
    [string]$MigrationPlanPath = "D:\Codex\projects\统一环境\reports\env-migration-plan\plan.json",
    [string]$MigrationId = "migration-01-python-cache",
    [string]$EvidenceDir = "D:\Codex\projects\统一环境\reports\env-migration-execution\pip-cache",
    [string]$StatePath,
    [ValidateSet("Process", "User")]
    [string]$EnvironmentScope = "Process",
    [string]$EnvironmentVariableName,
    [switch]$ConfirmAuthorized
)

$ErrorActionPreference = "Stop"

function Assert-DDrivePath {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$ParameterName 不能为空。"
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($root -ine "D:\") {
        throw "$ParameterName 必须位于 D:\ 下，当前值：$Path"
    }
}

function Assert-NoReparsePointInPath {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$ParameterName 不能为空。"
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $current = $fullPath
    $root = [System.IO.Path]::GetPathRoot($fullPath)

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

function Assert-NoNestedReparsePoint {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $items = Get-ChildItemsStrict -Path $Path -ParameterName $ParameterName
    $nested = $items |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1

    if ($nested) {
        throw "$ParameterName 内部包含 junction、symlink 或 reparse point：$($nested.FullName)"
    }
}

function Get-ChildItemsStrict {
    param(
        [string]$Path,
        [string]$ParameterName,
        [switch]$File,
        [switch]$Directory
    )

    $enumerationErrors = @()
    $parameters = @{
        LiteralPath = $Path
        Recurse = $true
        Force = $true
        ErrorAction = "SilentlyContinue"
        ErrorVariable = "enumerationErrors"
    }

    if ($File) {
        $parameters.File = $true
    }

    if ($Directory) {
        $parameters.Directory = $true
    }

    $items = @(Get-ChildItem @parameters)
    if ($enumerationErrors.Count -gt 0) {
        throw "$ParameterName 枚举失败，不能安全迁移：$($enumerationErrors[0].Exception.Message)"
    }

    $items
}

function Get-DirectoryState {
    param([string]$Path)

    $exists = Test-Path -LiteralPath $Path -PathType Container
    $fileCount = 0
    $directoryCount = 0
    $totalBytes = 0L
    $isReparsePoint = $false

    if ($exists) {
        $item = Get-Item -LiteralPath $Path -Force
        $isReparsePoint = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $children = @(Get-ChildItemsStrict -Path $Path -ParameterName $Path)
        $fileCount = @($children | Where-Object { -not $_.PSIsContainer }).Count
        $directoryCount = @($children | Where-Object { $_.PSIsContainer }).Count
        $totalBytes = [int64](($children | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum)
    }

    [pscustomobject]@{
        path = $Path
        exists = $exists
        isReparsePoint = $isReparsePoint
        fileCount = $fileCount
        directoryCount = $directoryCount
        totalBytes = $totalBytes
    }
}

function Assert-PipCacheScope {
    param(
        [string]$Name,
        [string]$Scope
    )

    if ($Scope -eq "User" -and $Name -ne "PIP_CACHE_DIR") {
        throw "User 作用域真实迁移只允许写入 PIP_CACHE_DIR，拒绝写入：$Name"
    }
}

function Assert-CanonicalPipMigration {
    param(
        [string]$Name,
        [string]$Source,
        [string]$Target
    )

    if ($Name -ne "PIP_CACHE_DIR") {
        return
    }

    $expectedSource = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "pip\Cache")).TrimEnd("\", "/")
    $expectedTarget = [System.IO.Path]::GetFullPath("D:\Codex\.cache\pip").TrimEnd("\", "/")
    $actualSource = [System.IO.Path]::GetFullPath($Source).TrimEnd("\", "/")
    $actualTarget = [System.IO.Path]::GetFullPath($Target).TrimEnd("\", "/")

    if ($actualSource -ine $expectedSource) {
        throw "PIP_CACHE_DIR 迁移的 source 必须是当前用户 pip 默认缓存：$expectedSource；当前为：$Source"
    }

    if ($actualTarget -ine $expectedTarget) {
        throw "PIP_CACHE_DIR 迁移的 target 必须是 canonical D 盘缓存：$expectedTarget；当前为：$Target"
    }
}

function Get-ScopedEnvironmentVariable {
    param(
        [string]$Name,
        [string]$Scope
    )

    [Environment]::GetEnvironmentVariable($Name, $Scope)
}

function Set-ScopedEnvironmentVariable {
    param(
        [string]$Name,
        [AllowNull()][string]$Value,
        [string]$Scope
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
    if ($Scope -eq "Process") {
        if ($null -eq $Value) {
            Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$Name" -Value $Value
        }
    } elseif ($Name -eq "PIP_CACHE_DIR") {
        if ($null -eq $Value) {
            Remove-Item -Path "Env:PIP_CACHE_DIR" -ErrorAction SilentlyContinue
        } else {
            $env:PIP_CACHE_DIR = $Value
        }
    }
}

function Copy-MissingTreeItems {
    param(
        [string]$Source,
        [string]$Target
    )

    New-Item -ItemType Directory -Force -Path $Target | Out-Null

    $createdDirectories = 0
    $copiedFiles = 0
    $skippedExistingFiles = 0

    foreach ($directory in @(Get-ChildItemsStrict -Path $Source -ParameterName "source" -Directory)) {
        $relative = [System.IO.Path]::GetRelativePath($Source, $directory.FullName)
        $targetDirectory = Join-Path $Target $relative
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            $createdDirectories++
        }
    }

    foreach ($file in @(Get-ChildItemsStrict -Path $Source -ParameterName "source" -File)) {
        $relative = [System.IO.Path]::GetRelativePath($Source, $file.FullName)
        $targetFile = Join-Path $Target $relative
        $targetDirectory = Split-Path -Path $targetFile -Parent
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            $createdDirectories++
        }

        if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
            $skippedExistingFiles++
            continue
        }

        Copy-Item -LiteralPath $file.FullName -Destination $targetFile
        $copiedFiles++
    }

    [pscustomobject]@{
        copiedFiles = $copiedFiles
        skippedExistingFiles = $skippedExistingFiles
        createdDirectories = $createdDirectories
    }
}

function Write-ExecutionMarkdown {
    param(
        [object]$Execution,
        [string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# pip cache 迁移执行记录")
    $lines.Add("")
    $lines.Add("执行时间：$($Execution.executedAt)")
    $lines.Add("")
    $lines.Add('> 本次只执行 `migration-01-python-cache`。旧源目录默认保留；本脚本不删除 C 盘目录，不处理项目本地 `.venv` 或其他人工审查项。')
    $lines.Add("")
    $lines.Add("## 范围")
    $lines.Add("")
    $lines.Add("- 来源：$($Execution.source)")
    $lines.Add("- 目标：$($Execution.target)")
    $lines.Add("- 环境变量：$($Execution.environmentVariableName)")
    $lines.Add("- 环境变量作用域：$($Execution.environmentScope)")
    $lines.Add("- 执行前 dry-run 计划项数量：$($Execution.preExecutionPlanMigrationCount)")
    $lines.Add("- 执行前 dry-run 计划项：$($Execution.preExecutionPlanIds -join ', ')")
    $lines.Add("- 执行前 root policy：$($Execution.preExecutionPlanEntry.rootPolicy.decision)")
    $lines.Add("- 执行前计划要求显式授权：$(if ($Execution.preExecutionPlanEntry.requiresExplicitUserApproval) { '是' } else { '否' })")
    $lines.Add("")
    $lines.Add("## 结果")
    $lines.Add("")
    $lines.Add("- 复制文件数：$($Execution.copySummary.copiedFiles)")
    $lines.Add("- 已存在而跳过的文件数：$($Execution.copySummary.skippedExistingFiles)")
    $lines.Add("- 创建目录数：$($Execution.copySummary.createdDirectories)")
    $lines.Add("- 旧源目录保留：$(if ($Execution.sourceRetained) { '是' } else { '否' })")
    $lines.Add("- 回滚状态文件：$($Execution.rollbackStatePath)")
    $lines.Add("")
    $lines.Add("## 回滚")
    $lines.Add("")
    $lines.Add("如需回滚环境变量策略，执行：")
    $lines.Add("")
    $lines.Add('```powershell')
    $lines.Add("& '$($Execution.scriptPath)' -Mode Rollback -StatePath '$($Execution.rollbackStatePath)' -EnvironmentScope $($Execution.environmentScope) -EnvironmentVariableName '$($Execution.environmentVariableName)'")
    $lines.Add('```')

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

if ($Mode -eq "Rollback") {
    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        throw "Rollback 模式必须提供 StatePath。"
    }

    Assert-DDrivePath -Path $StatePath -ParameterName "StatePath"
    Assert-NoReparsePointInPath -Path $StatePath -ParameterName "StatePath"
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $rollbackScope = if ($PSBoundParameters.ContainsKey("EnvironmentScope")) { $EnvironmentScope } else { "$($state.environmentScope)" }
    $rollbackName = if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariableName)) { $EnvironmentVariableName } else { "$($state.environmentVariableName)" }
    Assert-PipCacheScope -Name $rollbackName -Scope $rollbackScope
    $value = if ($null -eq $state.previousScopedValue -or "$($state.previousScopedValue)" -eq "") { $null } else { "$($state.previousScopedValue)" }
    Set-ScopedEnvironmentVariable -Name $rollbackName -Value $value -Scope $rollbackScope

    return [pscustomobject]@{
        mode = "Rollback"
        restoredValue = $value
        environmentScope = $rollbackScope
        environmentVariableName = $rollbackName
        sourceDeleted = $false
        targetDeleted = $false
    }
}

$EnvironmentVariableName = if ([string]::IsNullOrWhiteSpace($EnvironmentVariableName)) { "PIP_CACHE_DIR" } else { $EnvironmentVariableName }
Assert-PipCacheScope -Name $EnvironmentVariableName -Scope $EnvironmentScope

if (-not $ConfirmAuthorized) {
    throw "真实迁移需要传入 -ConfirmAuthorized，表示用户已明确授权当前迁移项。"
}

Assert-DDrivePath -Path $MigrationPlanPath -ParameterName "MigrationPlanPath"
Assert-DDrivePath -Path $EvidenceDir -ParameterName "EvidenceDir"
Assert-NoReparsePointInPath -Path $MigrationPlanPath -ParameterName "MigrationPlanPath"
Assert-NoReparsePointInPath -Path $EvidenceDir -ParameterName "EvidenceDir"

if (-not (Test-Path -LiteralPath $MigrationPlanPath -PathType Leaf)) {
    throw "找不到迁移计划：$MigrationPlanPath"
}

$plan = Get-Content -LiteralPath $MigrationPlanPath -Raw | ConvertFrom-Json
$preExecutionPlanIds = @($plan.migrationPlans | ForEach-Object { $_.id })
$entry = @($plan.migrationPlans | Where-Object { $_.id -eq $MigrationId }) | Select-Object -First 1
if (-not $entry) {
    throw "迁移计划中找不到迁移项：$MigrationId"
}

if ($entry.kind -ne "cache" -or $entry.owner -ne "python" -or $entry.id -ne "migration-01-python-cache") {
    throw "本脚本只允许执行 migration-01-python-cache。"
}

$source = "$($entry.source)"
$target = "$($entry.target)"
Assert-CanonicalPipMigration -Name $EnvironmentVariableName -Source $source -Target $target
Assert-DDrivePath -Path $target -ParameterName "target"
Assert-NoReparsePointInPath -Path $source -ParameterName "source"
Assert-NoReparsePointInPath -Path $target -ParameterName "target"

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "来源目录不存在：$source"
}

Assert-NoNestedReparsePoint -Path $source -ParameterName "source"
if (Test-Path -LiteralPath $target -PathType Container) {
    Assert-NoNestedReparsePoint -Path $target -ParameterName "target"
}

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Assert-NoReparsePointInPath -Path $EvidenceDir -ParameterName "EvidenceDir"

$beforeSource = Get-DirectoryState -Path $source
$beforeTarget = Get-DirectoryState -Path $target
$previousScopedValue = Get-ScopedEnvironmentVariable -Name $EnvironmentVariableName -Scope $EnvironmentScope
$previousProcessValue = Get-ScopedEnvironmentVariable -Name $EnvironmentVariableName -Scope "Process"

$copySummary = Copy-MissingTreeItems -Source $source -Target $target
Set-ScopedEnvironmentVariable -Name $EnvironmentVariableName -Value $target -Scope $EnvironmentScope

$afterSource = Get-DirectoryState -Path $source
$afterTarget = Get-DirectoryState -Path $target
$currentScopedValue = Get-ScopedEnvironmentVariable -Name $EnvironmentVariableName -Scope $EnvironmentScope

$rollbackStatePath = Join-Path $EvidenceDir "rollback-state.json"
$executionJsonPath = Join-Path $EvidenceDir "execution.json"
$executionMarkdownPath = Join-Path $EvidenceDir "EXECUTION.md"

$state = [pscustomobject]@{
    schemaVersion = 1
    migrationId = $MigrationId
    generatedAt = (Get-Date).ToString("o")
    environmentVariableName = $EnvironmentVariableName
    environmentScope = $EnvironmentScope
    previousScopedValue = $previousScopedValue
    previousProcessValue = $previousProcessValue
    migratedValue = $target
    source = $source
    target = $target
    sourceRetained = (Test-Path -LiteralPath $source -PathType Container)
}

$execution = [pscustomobject]@{
    schemaVersion = 1
    migrationId = $MigrationId
    executedAt = (Get-Date).ToString("o")
    scriptPath = $PSCommandPath
    migrationPlanPath = $MigrationPlanPath
    preExecutionPlanMigrationCount = @($plan.migrationPlans).Count
    preExecutionPlanIds = $preExecutionPlanIds
    preExecutionManualReviewCount = @($plan.excludedManualReviewItems).Count
    preExecutionPlanEntry = $entry
    preExecutionExcludedManualReviewItems = @($plan.excludedManualReviewItems)
    source = $source
    target = $target
    evidenceDir = $EvidenceDir
    environmentVariableName = $EnvironmentVariableName
    environmentScope = $EnvironmentScope
    previousScopedValue = $previousScopedValue
    currentScopedValue = $currentScopedValue
    sourceStateBefore = $beforeSource
    targetStateBefore = $beforeTarget
    sourceStateAfter = $afterSource
    targetStateAfter = $afterTarget
    copySummary = $copySummary
    sourceRetained = (Test-Path -LiteralPath $source -PathType Container)
    sourceDeleted = $false
    targetDeleted = $false
    rollbackStatePath = $rollbackStatePath
}

$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rollbackStatePath -Encoding UTF8
$execution | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $executionJsonPath -Encoding UTF8
Write-ExecutionMarkdown -Execution $execution -Path $executionMarkdownPath

[pscustomobject]@{
    mode = "Execute"
    migrationId = $MigrationId
    source = $source
    target = $target
    evidenceDir = $EvidenceDir
    executionJson = $executionJsonPath
    executionMarkdown = $executionMarkdownPath
    rollbackState = $rollbackStatePath
    copiedFiles = $copySummary.copiedFiles
    skippedExistingFiles = $copySummary.skippedExistingFiles
    sourceRetained = $execution.sourceRetained
    currentScopedValue = $currentScopedValue
}
