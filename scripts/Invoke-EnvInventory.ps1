param(
    [string]$OutputDir = "D:\Codex\projects\统一环境\reports\env-inventory",
    [string[]]$ProjectRoots = @("D:\Codex\projects"),
    [int]$VersionProbeTimeoutSeconds = 12,
    [switch]$IncludeSizes,
    [switch]$SkipVersionProbe
)

$ErrorActionPreference = "Continue"

function Get-RootDrive {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return [System.IO.Path]::GetPathRoot($Path)
    } catch {
        return $null
    }
}

function Assert-DDrivePath {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$ParameterName 不能为空。"
    }

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    if ($root -ine "D:\") {
        throw "$ParameterName 必须位于 D:\ 下，当前值：$Path"
    }
}

function Get-ReparsePointInfo {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path)) {
        return [pscustomobject]@{
            isReparsePoint = $false
            target = $null
        }
    }

    try {
        $item = Get-Item -Path $Path -Force -ErrorAction Stop
        $isReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        $target = $null
        if ($isReparsePoint -and ($item.PSObject.Properties.Name -contains "Target")) {
            $target = $item.Target
        }

        return [pscustomobject]@{
            isReparsePoint = $isReparsePoint
            target = $target
        }
    } catch {
        return [pscustomobject]@{
            isReparsePoint = $false
            target = $null
        }
    }
}

function Get-DirectorySize {
    param([string]$Path)

    if (-not $IncludeSizes) {
        return $null
    }

    if (-not (Test-Path -Path $Path -PathType Container)) {
        return $null
    }

    try {
        $sum = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum

        return [int64]($sum.Sum)
    } catch {
        return $null
    }
}

function New-DirectoryRecord {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Category,
        [string]$Owner,
        [string]$Notes
    )

    $exists = $false
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $exists = Test-Path -Path $Path -PathType Container
    }
    $reparse = Get-ReparsePointInfo -Path $Path

    [pscustomobject]@{
        name = $Name
        path = $Path
        category = $Category
        owner = $Owner
        exists = $exists
        drive = Get-RootDrive -Path $Path
        isReparsePoint = $reparse.isReparsePoint
        reparseTarget = $reparse.target
        sizeBytes = Get-DirectorySize -Path $Path
        notes = $Notes
    }
}

function Test-IsResolvedPipDefaultCache {
    param([object]$Directory)

    if ($Directory.name -ne "pip cache default") {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($env:PIP_CACHE_DIR)) {
        return $false
    }

    try {
        $configured = [System.IO.Path]::GetFullPath($env:PIP_CACHE_DIR).TrimEnd("\", "/")
        $canonical = [System.IO.Path]::GetFullPath("D:\Codex\.cache\pip").TrimEnd("\", "/")
        return $configured -ieq $canonical
    } catch {
        return $false
    }
}

function Invoke-CommandWithTimeout {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [int]$TimeoutSeconds
    )

    $job = Start-Job -ScriptBlock {
        param(
            [string]$JobExecutable,
            [string[]]$JobArguments
        )

        try {
            $global:LASTEXITCODE = $null
            & $JobExecutable @JobArguments 2>&1
            $exitCode = $LASTEXITCODE
            if ($null -eq $exitCode) {
                $exitCode = 0
            }

            [pscustomobject]@{
                __CodexProbeExitCode = $exitCode
            }
        } catch {
            [pscustomobject]@{
                __CodexProbeExitCode = $null
                __CodexProbeError = $_.Exception.Message
            }
        }
    } -ArgumentList $Executable, $Arguments

    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job | Out-Null
        Remove-Job -Job $job -Force | Out-Null

        return [pscustomobject]@{
            timedOut = $true
            output = @()
            exitCode = $null
            error = "Version probe timed out after $TimeoutSeconds seconds"
        }
    }

    $received = @(Receive-Job -Job $job)
    Remove-Job -Job $job -Force | Out-Null

    $exitRecord = $received |
        Where-Object { $_.PSObject.Properties.Name -contains "__CodexProbeExitCode" } |
        Select-Object -First 1

    $output = @(
        $received | Where-Object {
            -not ($_.PSObject.Properties.Name -contains "__CodexProbeExitCode")
        }
    )

    return [pscustomobject]@{
        timedOut = $false
        output = $output
        exitCode = if ($exitRecord) { $exitRecord.__CodexProbeExitCode } else { 0 }
        error = if ($exitRecord -and ($exitRecord.PSObject.Properties.Name -contains "__CodexProbeError")) { $exitRecord.__CodexProbeError } else { $null }
    }
}

function Invoke-VersionProbe {
    param(
        [string]$Name,
        [string[]]$Arguments
    )

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        return [pscustomobject]@{
            name = $Name
            found = $false
            path = $null
            version = $null
            evidence = $null
            exitCode = $null
            probeSucceeded = $false
            error = $null
        }
    }

    $path = $command.Source
    if ($command.Path) {
        $path = $command.Path
    }

    if ($SkipVersionProbe) {
        return [pscustomobject]@{
            name = $Name
            found = $true
            path = $path
            version = $null
            evidence = $null
            exitCode = $null
            probeSucceeded = $false
            error = "Skipped"
        }
    }

    try {
        $executable = if (-not [string]::IsNullOrWhiteSpace($path)) { $path } else { $Name }
        $probe = Invoke-CommandWithTimeout -Executable $executable -Arguments $Arguments -TimeoutSeconds $VersionProbeTimeoutSeconds
        $output = $probe.output | Select-Object -First 4
        $exitCode = $probe.exitCode
        $evidence = (($output | ForEach-Object { "$_" }) -join " ").Trim()
        $succeeded = (-not $probe.timedOut) -and ($exitCode -eq 0) -and ([string]::IsNullOrWhiteSpace($probe.error))

        [pscustomobject]@{
            name = $Name
            found = $true
            path = $path
            version = if ($succeeded) { $evidence } else { $null }
            evidence = $evidence
            exitCode = $exitCode
            probeSucceeded = $succeeded
            error = if ($succeeded) { $null } elseif (-not [string]::IsNullOrWhiteSpace($probe.error)) { $probe.error } else { "Version probe exited with code $exitCode" }
        }
    } catch {
        [pscustomobject]@{
            name = $Name
            found = $true
            path = $path
            version = $null
            evidence = $null
            exitCode = $null
            probeSucceeded = $false
            error = $_.Exception.Message
        }
    }
}

function Get-SelectedEnvironmentVariables {
    $names = @(
        "Path",
        "UV_CACHE_DIR",
        "UV_TOOL_DIR",
        "PIP_CACHE_DIR",
        "PIPX_HOME",
        "PIPX_BIN_DIR",
        "POETRY_HOME",
        "POETRY_CACHE_DIR",
        "CONDA_ENVS_PATH",
        "CONDA_PKGS_DIRS",
        "NPM_CONFIG_CACHE",
        "PNPM_HOME",
        "CARGO_HOME",
        "RUSTUP_HOME",
        "NUGET_PACKAGES",
        "MAVEN_USER_HOME",
        "GRADLE_USER_HOME",
        "GOPATH",
        "GOMODCACHE",
        "SCOOP",
        "SCOOP_GLOBAL",
        "MISE_DATA_DIR",
        "MISE_CACHE_DIR"
    )

    foreach ($name in $names) {
        $item = Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            name = $name
            value = if ($item) { $item.Value } else { $null }
            isSet = [bool]$item
        }
    }
}

function Get-PathEntries {
    $rawPath = $env:Path
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return @()
    }

    $entries = $rawPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $path = $entries[$i].Trim()
        $reparse = Get-ReparsePointInfo -Path $path
        [pscustomobject]@{
            index = $i
            path = $path
            exists = Test-Path -Path $path -PathType Container
            drive = Get-RootDrive -Path $path
            isReparsePoint = $reparse.isReparsePoint
            reparseTarget = $reparse.target
        }
    }
}

function Test-IsSubPath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($BasePath)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullBasePath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd("\", "/")
    return $fullPath.Equals($fullBasePath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$fullBasePath\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullBasePath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd("\", "/")
    if ($fullPath.Equals($fullBasePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }

    if (-not $fullPath.StartsWith("$fullBasePath\", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    return $fullPath.Substring($fullBasePath.Length + 1)
}

function Get-KnownDirectories {
    $userHome = $env:USERPROFILE
    $local = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    $programData = $env:ProgramData

    $items = @(
        @{ Name = "Codex tools root"; Path = "D:\Codex\tools"; Category = "d-target"; Owner = "host"; Notes = "推荐工具根目录" },
        @{ Name = "Codex envs root"; Path = "D:\Codex\envs"; Category = "d-target"; Owner = "host"; Notes = "推荐共享环境根目录" },
        @{ Name = "Codex cache root"; Path = "D:\Codex\.cache"; Category = "d-target"; Owner = "host"; Notes = "推荐共享缓存根目录" },
        @{ Name = "uv cache env"; Path = $env:UV_CACHE_DIR; Category = "cache"; Owner = "python"; Notes = "显式 UV_CACHE_DIR" },
        @{ Name = "uv tools env"; Path = $env:UV_TOOL_DIR; Category = "tool-env"; Owner = "python"; Notes = "显式 UV_TOOL_DIR" },
        @{ Name = "pip cache env"; Path = $env:PIP_CACHE_DIR; Category = "cache"; Owner = "python"; Notes = "显式 PIP_CACHE_DIR" },
        @{ Name = "pip cache default"; Path = (Join-Path $local "pip\Cache"); Category = "cache"; Owner = "python"; Notes = "pip 默认用户缓存候选" },
        @{ Name = "pipx home"; Path = $env:PIPX_HOME; Category = "tool-env"; Owner = "python"; Notes = "显式 PIPX_HOME" },
        @{ Name = "pipx default home"; Path = (Join-Path $userHome ".local\pipx"); Category = "tool-env"; Owner = "python"; Notes = "pipx 常见默认位置" },
        @{ Name = "poetry home"; Path = $env:POETRY_HOME; Category = "tool-env"; Owner = "python"; Notes = "显式 POETRY_HOME" },
        @{ Name = "poetry cache"; Path = $env:POETRY_CACHE_DIR; Category = "cache"; Owner = "python"; Notes = "显式 POETRY_CACHE_DIR" },
        @{ Name = "poetry cache default"; Path = (Join-Path $local "pypoetry\Cache"); Category = "cache"; Owner = "python"; Notes = "Poetry 常见缓存位置" },
        @{ Name = "conda envs env"; Path = $env:CONDA_ENVS_PATH; Category = "tool-env"; Owner = "conda"; Notes = "显式 CONDA_ENVS_PATH" },
        @{ Name = "conda pkgs env"; Path = $env:CONDA_PKGS_DIRS; Category = "cache"; Owner = "conda"; Notes = "显式 CONDA_PKGS_DIRS" },
        @{ Name = "conda user root"; Path = (Join-Path $userHome ".conda"); Category = "tool-env"; Owner = "conda"; Notes = "Conda 用户目录" },
        @{ Name = "npm cache env"; Path = $env:NPM_CONFIG_CACHE; Category = "cache"; Owner = "node"; Notes = "显式 NPM_CONFIG_CACHE" },
        @{ Name = "npm cache default"; Path = (Join-Path $local "npm-cache"); Category = "cache"; Owner = "node"; Notes = "npm 常见缓存位置" },
        @{ Name = "pnpm home"; Path = $env:PNPM_HOME; Category = "tool-env"; Owner = "node"; Notes = "显式 PNPM_HOME" },
        @{ Name = "pnpm store default"; Path = (Join-Path $local "pnpm\store"); Category = "cache"; Owner = "node"; Notes = "pnpm 常见 store 位置" },
        @{ Name = "cargo home"; Path = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $userHome ".cargo" }; Category = "tool-env"; Owner = "rust"; Notes = "Cargo 工具和缓存根" },
        @{ Name = "rustup home"; Path = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME } else { Join-Path $userHome ".rustup" }; Category = "tool-env"; Owner = "rust"; Notes = "Rustup 工具链根" },
        @{ Name = "go path"; Path = if ($env:GOPATH) { $env:GOPATH } else { Join-Path $userHome "go" }; Category = "tool-env"; Owner = "go"; Notes = "Go GOPATH" },
        @{ Name = "go module cache"; Path = $env:GOMODCACHE; Category = "cache"; Owner = "go"; Notes = "显式 GOMODCACHE" },
        @{ Name = "scoop user"; Path = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $userHome "scoop" }; Category = "tool-env"; Owner = "windows"; Notes = "Scoop 用户安装根" },
        @{ Name = "scoop global"; Path = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { Join-Path $programData "scoop" }; Category = "tool-env"; Owner = "windows"; Notes = "Scoop 全局安装根" },
        @{ Name = "mise data"; Path = $env:MISE_DATA_DIR; Category = "tool-env"; Owner = "multi-runtime"; Notes = "显式 MISE_DATA_DIR" },
        @{ Name = "mise cache"; Path = $env:MISE_CACHE_DIR; Category = "cache"; Owner = "multi-runtime"; Notes = "显式 MISE_CACHE_DIR" },
        @{ Name = "nuget packages"; Path = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $userHome ".nuget\packages" }; Category = "cache"; Owner = "dotnet"; Notes = "NuGet 包缓存" },
        @{ Name = "maven repository"; Path = if ($env:MAVEN_USER_HOME) { Join-Path $env:MAVEN_USER_HOME "repository" } else { Join-Path $userHome ".m2\repository" }; Category = "cache"; Owner = "java"; Notes = "Maven 本地仓库常见位置" },
        @{ Name = "gradle user home"; Path = if ($env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME } else { Join-Path $userHome ".gradle" }; Category = "cache"; Owner = "java"; Notes = "Gradle 用户缓存和 wrapper 根" },
        @{ Name = "docker user config"; Path = (Join-Path $userHome ".docker"); Category = "manual-only"; Owner = "container"; Notes = "Docker 用户配置，可能包含上下文和凭据引用" },
        @{ Name = "vscode extensions"; Path = (Join-Path $userHome ".vscode\extensions"); Category = "tool-env"; Owner = "editor"; Notes = "VS Code 用户扩展目录" }
    )

    foreach ($item in $items) {
        if (-not [string]::IsNullOrWhiteSpace($item.Path)) {
            New-DirectoryRecord -Name $item.Name -Path $item.Path -Category $item.Category -Owner $item.Owner -Notes $item.Notes
        }
    }
}

function Get-TopProjectRoot {
    param(
        [string]$Path,
        [string[]]$Roots
    )

    foreach ($root in $Roots) {
        if (-not (Test-IsSubPath -Path $Path -BasePath $root)) {
            continue
        }

        $relative = Get-RelativePath -Path $Path -BasePath $root
        $segments = @($relative -split "[\\/]" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($segments.Count -eq 0) {
            return $null
        }

        return (Join-Path $root $segments[0])
    }

    return $null
}

function New-LocalEnvironmentFinding {
    param(
        [string]$MarkerPath,
        [string[]]$Roots
    )

    $item = Get-Item -LiteralPath $MarkerPath -Force
    $marker = $item.Name
    $container = [System.IO.Directory]::GetParent($item.FullName).FullName
    $topProjectRoot = Get-TopProjectRoot -Path $item.FullName -Roots $Roots
    $normalized = $item.FullName.ToLowerInvariant()

    $classification = "nested-app-local-env"
    $scope = "nested-app"
    $owner = "project"
    $risk = "high"
    $includeInReviewPack = $true
    $reason = "嵌套 app 的项目本地依赖环境，需按所在 app 的锁文件、验证命令和 owner 决策单独处理。"
    $recommendation = "不自动迁移；纳入项目级审查，但不得跨项目复用。"

    if ($topProjectRoot -and $container.Equals($topProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $classification = "project-root-local-env"
        $scope = "project-root"
        $risk = "high"
        $reason = "项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。"
        $recommendation = "不自动迁移；这是项目本地依赖环境，需逐项目评估。"
    } elseif ($normalized.Contains("\docs\gsd-archive\") -or $normalized.Contains("\docs\archive\") -or $normalized.Contains("\docs\archived\")) {
        $classification = "archived-project-cache"
        $scope = "archive-cache"
        $owner = "archive"
        $risk = "high"
        $includeInReviewPack = $false
        $reason = "项目文档或历史归档中的依赖缓存副本，不属于当前项目依赖重建。"
        $recommendation = "不按当前项目依赖重建；如需处理，进入归档或产物清理 dry-run。"
    } elseif ($normalized.Contains("\data\repair_backups\") -or $normalized.Contains("\repair_backups\")) {
        $classification = "plugin-cache-backup"
        $scope = "backup-cache"
        $owner = "backup"
        $risk = "high"
        $includeInReviewPack = $false
        $reason = "repair backup 内的插件缓存副本，不属于项目依赖重建；只能走备份保留或清理治理。"
        $recommendation = "不按项目依赖重建；如需处理，进入备份治理 dry-run。"
    } elseif ($normalized.Contains("\plugins\cache\")) {
        $classification = "plugin-runtime-cache"
        $scope = "plugin-runtime-cache"
        $owner = "plugin-runtime"
        $risk = "high"
        $includeInReviewPack = $false
        $reason = "插件 runtime/cache 内的依赖目录，不属于项目本地依赖重建；可能由插件安装或运行时管理。"
        $recommendation = "不按项目依赖重建；如需处理，进入插件 runtime/cache 治理。"
    }

    [pscustomobject]@{
        project = $container
        parentProject = $topProjectRoot
        marker = $marker
        path = $item.FullName
        drive = Get-RootDrive -Path $item.FullName
        sizeBytes = Get-DirectorySize -Path $item.FullName
        classification = $classification
        scope = $scope
        owner = $owner
        risk = $risk
        includeInReviewPack = $includeInReviewPack
        recommendation = $recommendation
        reason = $reason
    }
}

function Get-LocalEnvironmentFindings {
    param([string[]]$Roots)

    $markerNames = @(".venv", "venv", "node_modules", ".conda")
    $skipDirectoryNames = @(".git", ".codegraph", ".scratch", "reports", "target", "dist", "build")

    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $queue = [System.Collections.Queue]::new()
        $queue.Enqueue((Get-Item -LiteralPath $root -Force))

        while ($queue.Count -gt 0) {
            $dir = $queue.Dequeue()
            if ($skipDirectoryNames -contains $dir.Name) {
                continue
            }

            if ($markerNames -contains $dir.Name) {
                New-LocalEnvironmentFinding -MarkerPath $dir.FullName -Roots $Roots
                continue
            }

            Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $queue.Enqueue($_)
                }
            }
        }
    }
}

function Get-ProjectEnvironmentMarkers {
    param([object[]]$LocalEnvironmentFindings)

    foreach ($finding in $LocalEnvironmentFindings) {
        if ([bool]$finding.includeInReviewPack) {
            $finding
        }
    }
}

function Get-MigrationCandidates {
    param(
        [object[]]$Directories
    )

    foreach ($dir in $Directories) {
        if (-not $dir.exists) {
            continue
        }

        if ($dir.isReparsePoint) {
            continue
        }

        if ($dir.category -eq "manual-only") {
            continue
        }

        if (Test-IsResolvedPipDefaultCache -Directory $dir) {
            continue
        }

        if ($dir.drive -like "C:\*") {
            $risk = "medium"
            $action = "需要人工确认"

            if ($dir.category -eq "cache") {
                $risk = "low"
                $action = "可考虑迁移到 D:\Codex\.cache"
            } elseif ($dir.category -eq "tool-env") {
                $risk = "medium"
                $action = "可考虑迁移到 D:\Codex\tools 或 D:\Codex\envs，但需按工具官方方式切换"
            }

            [pscustomobject]@{
                source = $dir.path
                kind = $dir.category
                owner = $dir.owner
                risk = $risk
                action = $action
                reason = $dir.notes
            }
        }
    }
}

function Get-ManualReviewItems {
    param(
        [object[]]$Directories,
        [object[]]$LocalEnvironmentFindings
    )

    foreach ($dir in $Directories) {
        if (-not $dir.exists) {
            continue
        }

        if ($dir.isReparsePoint) {
            [pscustomobject]@{
                source = $dir.path
                kind = $dir.category
                owner = $dir.owner
                risk = "high"
                action = "不自动迁移"
                reason = "该目录是 reparse point/junction/symlink，需先确认目标和循环风险。"
            }
        } elseif ($dir.category -eq "manual-only") {
            [pscustomobject]@{
                source = $dir.path
                kind = $dir.category
                owner = $dir.owner
                risk = "high"
                action = "仅人工处理"
                reason = $dir.notes
            }
        }
    }

    foreach ($marker in $LocalEnvironmentFindings) {
        [pscustomobject]@{
            source = $marker.path
            kind = $marker.classification
            owner = $marker.owner
            risk = $marker.risk
            action = "不自动迁移"
            reason = $marker.reason
        }
    }
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function Get-HostSummary {
    [pscustomobject]@{
        computerName = $env:COMPUTERNAME
        userName = $env:USERNAME
        osVersion = [System.Environment]::OSVersion.VersionString
        is64BitOperatingSystem = [System.Environment]::Is64BitOperatingSystem
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        currentDirectory = (Get-Location).Path
    }
}

function Get-ExcludedRoots {
    @(
        [pscustomobject]@{ path = "C:\Windows"; reason = "系统目录，绝不自动迁移" }
        [pscustomobject]@{ path = "C:\Program Files"; reason = "MSI/系统级安装目录，绝不直接搬迁" }
        [pscustomobject]@{ path = "C:\Program Files (x86)"; reason = "MSI/系统级安装目录，绝不直接搬迁" }
        [pscustomobject]@{ path = "C:\ProgramData"; reason = "服务和机器级状态常驻位置，仅按官方迁移流程处理" }
        [pscustomobject]@{ path = "C:\Users"; reason = "不批量迁移用户目录或 AppData" }
    )
}

function Write-MarkdownReport {
    param(
        [object]$Inventory,
        [string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 本机环境资产盘点报告")
    $lines.Add("")
    $lines.Add("生成时间：$($Inventory.generatedAt)")
    $lines.Add("")
    $lines.Add("> 本报告由只读盘点脚本生成。脚本未移动文件、未修改环境变量、未执行软件更新。")
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add("- 工具探测数量：$($Inventory.tools.Count)")
    $lines.Add("- 已存在目录数量：$(($Inventory.directories | Where-Object { $_.exists }).Count)")
    $lines.Add("- 项目级审查环境数量：$($Inventory.projectEnvironmentMarkers.Count)")
    $lines.Add("- 本地环境相关发现数量：$($Inventory.localEnvironmentFindings.Count)")
    $lines.Add("- 迁移候选数量：$($Inventory.migrationCandidates.Count)")
    $lines.Add("- 人工审查项数量：$($Inventory.manualReviewItems.Count)")
    $lines.Add("")
    $lines.Add("## 绝不自动迁移")
    $lines.Add("")
    $lines.Add("| 路径 | 原因 |")
    $lines.Add("| --- | --- |")
    foreach ($root in $Inventory.excludedRoots) {
        $lines.Add("| $(Escape-MarkdownCell $root.path) | $(Escape-MarkdownCell $root.reason) |")
    }
    $lines.Add("")
    $lines.Add("## 工具探测")
    $lines.Add("")
    $lines.Add("| 工具 | 是否存在 | 探测成功 | 路径 | 版本输出 | 错误 |")
    $lines.Add("| --- | --- | --- | --- | --- | --- |")
    foreach ($tool in $Inventory.tools) {
        $lines.Add("| $(Escape-MarkdownCell $tool.name) | $(Escape-MarkdownCell $tool.found) | $(Escape-MarkdownCell $tool.probeSucceeded) | $(Escape-MarkdownCell $tool.path) | $(Escape-MarkdownCell $tool.version) | $(Escape-MarkdownCell $tool.error) |")
    }
    $lines.Add("")
    $lines.Add("## PATH 入口")
    $lines.Add("")
    $lines.Add("| 序号 | 是否存在 | 路径 | Reparse Point |")
    $lines.Add("| --- | --- | --- | --- |")
    foreach ($entry in $Inventory.pathEntries) {
        $lines.Add("| $(Escape-MarkdownCell $entry.index) | $(Escape-MarkdownCell $entry.exists) | $(Escape-MarkdownCell $entry.path) | $(Escape-MarkdownCell $entry.isReparsePoint) |")
    }
    $lines.Add("")
    $lines.Add("## 目录探测")
    $lines.Add("")
    $lines.Add("| 名称 | 类别 | 是否存在 | 路径 | 说明 |")
    $lines.Add("| --- | --- | --- | --- | --- |")
    foreach ($dir in $Inventory.directories) {
        $lines.Add("| $(Escape-MarkdownCell $dir.name) | $(Escape-MarkdownCell $dir.category) | $(Escape-MarkdownCell $dir.exists) | $(Escape-MarkdownCell $dir.path) | $(Escape-MarkdownCell $dir.notes) |")
    }
    $lines.Add("")
    $lines.Add("## 项目本地环境")
    $lines.Add("")
    if ($Inventory.projectEnvironmentMarkers.Count -eq 0) {
        $lines.Add("未发现需要纳入项目级审查的 `.venv`、`venv`、`node_modules` 或 `.conda`。")
    } else {
        $lines.Add("| 项目或 app | 父项目 | 分类 | 标记 | 路径 | 建议 |")
        $lines.Add("| --- | --- | --- | --- | --- | --- |")
        foreach ($marker in $Inventory.projectEnvironmentMarkers) {
            $lines.Add("| $(Escape-MarkdownCell $marker.project) | $(Escape-MarkdownCell $marker.parentProject) | $(Escape-MarkdownCell $marker.classification) | $(Escape-MarkdownCell $marker.marker) | $(Escape-MarkdownCell $marker.path) | $(Escape-MarkdownCell $marker.recommendation) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 本地环境分类发现")
    $lines.Add("")
    if ($Inventory.localEnvironmentFindings.Count -eq 0) {
        $lines.Add("未发现本地环境相关目录。")
    } else {
        $lines.Add("| 分类 | 纳入项目级审查 | 所属项目或容器 | 标记 | 路径 | 建议 |")
        $lines.Add("| --- | --- | --- | --- | --- | --- |")
        foreach ($finding in $Inventory.localEnvironmentFindings) {
            $reviewDisplay = if ($finding.includeInReviewPack) { "是" } else { "否" }
            $lines.Add("| $(Escape-MarkdownCell $finding.classification) | $reviewDisplay | $(Escape-MarkdownCell $finding.project) | $(Escape-MarkdownCell $finding.marker) | $(Escape-MarkdownCell $finding.path) | $(Escape-MarkdownCell $finding.recommendation) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 迁移候选")
    $lines.Add("")
    if ($Inventory.migrationCandidates.Count -eq 0) {
        $lines.Add("当前未发现明确迁移候选。")
    } else {
        $lines.Add("| 来源 | 类型 | 风险 | 建议动作 | 原因 |")
        $lines.Add("| --- | --- | --- | --- | --- |")
        foreach ($candidate in $Inventory.migrationCandidates) {
            $lines.Add("| $(Escape-MarkdownCell $candidate.source) | $(Escape-MarkdownCell $candidate.kind) | $(Escape-MarkdownCell $candidate.risk) | $(Escape-MarkdownCell $candidate.action) | $(Escape-MarkdownCell $candidate.reason) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 人工审查项")
    $lines.Add("")
    if ($Inventory.manualReviewItems.Count -eq 0) {
        $lines.Add("当前未发现需要单独人工审查的项目。")
    } else {
        $lines.Add("| 来源 | 类型 | 风险 | 建议动作 | 原因 |")
        $lines.Add("| --- | --- | --- | --- | --- |")
        foreach ($item in $Inventory.manualReviewItems) {
            $lines.Add("| $(Escape-MarkdownCell $item.source) | $(Escape-MarkdownCell $item.kind) | $(Escape-MarkdownCell $item.risk) | $(Escape-MarkdownCell $item.action) | $(Escape-MarkdownCell $item.reason) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 下一步")
    $lines.Add("")
    $lines.Add("1. 人工审查 risk=medium 和 risk=high 的候选项。")
    $lines.Add("2. 为低风险缓存迁移单独建立迁移 issue。")
    $lines.Add("3. 对任何工具根目录迁移，优先使用工具官方配置或重装方式，不直接搬目录。")

    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$tools = @(
    Invoke-VersionProbe -Name "python" -Arguments @("--version")
    Invoke-VersionProbe -Name "py" -Arguments @("--version")
    Invoke-VersionProbe -Name "uv" -Arguments @("--version")
    Invoke-VersionProbe -Name "pipx" -Arguments @("--version")
    Invoke-VersionProbe -Name "poetry" -Arguments @("--version")
    Invoke-VersionProbe -Name "conda" -Arguments @("--version")
    Invoke-VersionProbe -Name "mamba" -Arguments @("--version")
    Invoke-VersionProbe -Name "node" -Arguments @("--version")
    Invoke-VersionProbe -Name "npm" -Arguments @("--version")
    Invoke-VersionProbe -Name "pnpm" -Arguments @("--version")
    Invoke-VersionProbe -Name "yarn" -Arguments @("--version")
    Invoke-VersionProbe -Name "nvm" -Arguments @("version")
    Invoke-VersionProbe -Name "fnm" -Arguments @("--version")
    Invoke-VersionProbe -Name "mise" -Arguments @("--version")
    Invoke-VersionProbe -Name "scoop" -Arguments @("--version")
    Invoke-VersionProbe -Name "winget" -Arguments @("--version")
    Invoke-VersionProbe -Name "choco" -Arguments @("--version")
    Invoke-VersionProbe -Name "git" -Arguments @("--version")
    Invoke-VersionProbe -Name "cargo" -Arguments @("--version")
    Invoke-VersionProbe -Name "rustc" -Arguments @("--version")
    Invoke-VersionProbe -Name "go" -Arguments @("version")
    Invoke-VersionProbe -Name "dotnet" -Arguments @("--version")
    Invoke-VersionProbe -Name "java" -Arguments @("-version")
    Invoke-VersionProbe -Name "javac" -Arguments @("-version")
    Invoke-VersionProbe -Name "mvn" -Arguments @("--version")
    Invoke-VersionProbe -Name "gradle" -Arguments @("--version")
    Invoke-VersionProbe -Name "cmake" -Arguments @("--version")
    Invoke-VersionProbe -Name "ninja" -Arguments @("--version")
    Invoke-VersionProbe -Name "docker" -Arguments @("--version")
    Invoke-VersionProbe -Name "wsl" -Arguments @("--version")
    Invoke-VersionProbe -Name "code" -Arguments @("--version")
    Invoke-VersionProbe -Name "pwsh" -Arguments @("--version")
    Invoke-VersionProbe -Name "powershell" -Arguments @("-NoProfile", "-Command", "`$PSVersionTable.PSVersion.ToString()")
)

$directories = @(Get-KnownDirectories)
$localEnvironmentFindings = @(Get-LocalEnvironmentFindings -Roots $ProjectRoots)
$projectMarkers = @(Get-ProjectEnvironmentMarkers -LocalEnvironmentFindings $localEnvironmentFindings)
$candidates = @(Get-MigrationCandidates -Directories $directories)
$manualReviewItems = @(Get-ManualReviewItems -Directories $directories -LocalEnvironmentFindings $localEnvironmentFindings)
$envVars = @(Get-SelectedEnvironmentVariables)
$pathEntries = @(Get-PathEntries)

$inventory = [pscustomobject]@{
    schemaVersion = 2
    generatedAt = (Get-Date).ToString("o")
    readOnly = $true
    host = Get-HostSummary
    outputDir = $OutputDir
    projectRoots = $ProjectRoots
    excludedRoots = @(Get-ExcludedRoots)
    versionProbeTimeoutSeconds = $VersionProbeTimeoutSeconds
    includeSizes = [bool]$IncludeSizes
    skipVersionProbe = [bool]$SkipVersionProbe
    tools = $tools
    selectedEnvironmentVariables = $envVars
    pathEntries = $pathEntries
    directories = $directories
    projectEnvironmentMarkers = $projectMarkers
    localEnvironmentFindings = $localEnvironmentFindings
    migrationCandidates = $candidates
    manualReviewItems = $manualReviewItems
}

$jsonPath = Join-Path $OutputDir "inventory.json"
$reportPath = Join-Path $OutputDir "REPORT.md"

$inventory | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
Write-MarkdownReport -Inventory $inventory -Path $reportPath

[pscustomobject]@{
    inventory = $jsonPath
    report = $reportPath
    readOnly = $true
}
