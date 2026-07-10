function Test-EnvCanonicalPipCacheConfigured {
    param([object[]]$Directories)

    $canonicalPath = [IO.Path]::GetFullPath("D:\Codex\.cache\pip").TrimEnd("\", "/")
    foreach ($directory in @($Directories)) {
        if ($null -eq $directory -or $directory.name -ne "pip cache env" -or [string]::IsNullOrWhiteSpace($directory.path)) {
            continue
        }

        try {
            $configuredPath = [IO.Path]::GetFullPath([string]$directory.path).TrimEnd("\", "/")
            if ($configuredPath.Equals($canonicalPath, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch {
            continue
        }
    }

    return $false
}

function Assert-EnvMigrationDirectoryFacts {
    param([AllowEmptyCollection()][object[]]$Directories)

    foreach ($directory in @($Directories)) {
        if ($null -eq $directory) {
            throw "Directory fact 不能为空。"
        }
        foreach ($name in @("exists", "isReparsePoint")) {
            if (-not ($directory.PSObject.Properties.Name -contains $name) -or $directory.$name -isnot [bool]) {
                throw "Directory fact 字段必须是 boolean：$name"
            }
        }
    }
}

function Get-EnvMigrationCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Directories
    )

    Assert-EnvMigrationDirectoryFacts -Directories $Directories
    $canonicalPipCacheConfigured = Test-EnvCanonicalPipCacheConfigured -Directories $Directories
    foreach ($directory in @($Directories)) {
        if (-not $directory.exists -or $directory.isReparsePoint -or $directory.category -eq "manual-only") {
            continue
        }

        if ($canonicalPipCacheConfigured -and $directory.name -eq "pip cache default") {
            continue
        }

        if ($directory.drive -notlike "C:\*") {
            continue
        }

        $risk = "medium"
        $action = "需要人工确认"
        if ($directory.category -eq "cache") {
            $risk = "low"
            $action = "可考虑迁移到 D:\Codex\.cache"
        } elseif ($directory.category -eq "tool-env") {
            $action = "可考虑迁移到 D:\Codex\tools 或 D:\Codex\envs，但需按工具官方方式切换"
        }

        [pscustomobject]@{
            source = $directory.path
            kind = $directory.category
            owner = $directory.owner
            risk = $risk
            action = $action
            reason = $directory.notes
        }
    }
}

function Get-EnvLocalEnvironmentReviewReason {
    param([string]$Classification)

    switch ($Classification) {
        "project-root-local-env" { return "项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。" }
        "nested-app-local-env" { return "嵌套 app 的项目本地依赖环境，需按所在 app 的锁文件、验证命令和 owner 决策单独处理。" }
        "archived-project-cache" { return "项目文档或历史归档中的依赖缓存副本，不属于当前项目依赖重建。" }
        "plugin-cache-backup" { return "repair backup 内的插件缓存副本，不属于项目依赖重建；只能走备份保留或清理治理。" }
        "plugin-runtime-cache" { return "插件 runtime/cache 内的依赖目录，不属于项目本地依赖重建；可能由插件安装或运行时管理。" }
        default { return "本地环境目录可能绑定解释器、绝对路径、构建产物或运行状态，需人工确认归属和处理方式。" }
    }
}

function Get-EnvManualReviewItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Directories,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalEnvironmentFindings
    )

    Assert-EnvMigrationDirectoryFacts -Directories $Directories
    foreach ($directory in @($Directories)) {
        if (-not $directory.exists) {
            continue
        }

        if ($directory.isReparsePoint) {
            [pscustomobject]@{
                source = $directory.path
                kind = $directory.category
                owner = $directory.owner
                risk = "high"
                action = "不自动迁移"
                reason = "该目录是 reparse point/junction/symlink，需先确认目标和循环风险。"
            }
        } elseif ($directory.category -eq "manual-only") {
            [pscustomobject]@{
                source = $directory.path
                kind = $directory.category
                owner = $directory.owner
                risk = "high"
                action = "仅人工处理"
                reason = $directory.notes
            }
        }
    }

    foreach ($finding in @($LocalEnvironmentFindings)) {
        if ($null -eq $finding -or [string]::IsNullOrWhiteSpace($finding.path)) {
            continue
        }

        [pscustomobject]@{
            source = $finding.path
            kind = $finding.classification
            owner = $finding.owner
            risk = "high"
            action = "不自动迁移"
            reason = Get-EnvLocalEnvironmentReviewReason -Classification $finding.classification
        }
    }
}
