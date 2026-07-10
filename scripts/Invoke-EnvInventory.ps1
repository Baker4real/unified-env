param(
    [string]$OutputDir = "D:\Codex\projects\统一环境\reports\env-inventory",
    [string[]]$ProjectRoots = @("D:\Codex\projects"),
    [string[]]$ToolOwnerRoots = @("D:\Codex\projects", "D:\hermes-data\hermes-agent"),
    [int]$VersionProbeTimeoutSeconds = 12,
    [switch]$IncludeSizes,
    [switch]$SkipVersionProbe
)

$ErrorActionPreference = "Continue"

. (Join-Path $PSScriptRoot "lib\ReportArtifactPublisher.ps1")
. (Join-Path $PSScriptRoot "lib\EnvInventoryTrust.ps1")

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

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandType -eq [Management.Automation.CommandTypes]::Application -and
            -not [string]::IsNullOrWhiteSpace($_.Path) -and
            [IO.Path]::IsPathFullyQualified($_.Path) -and
            (Test-Path -LiteralPath $_.Path -PathType Leaf)
        } |
        Select-Object -First 1
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

    $path = $command.Path

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
        $probe = Invoke-CommandWithTimeout -Executable $path -Arguments $Arguments -TimeoutSeconds $VersionProbeTimeoutSeconds
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

function Get-PathScopeSourceValues {
    param(
        [ValidateSet("process", "user", "machine")][string]$Source
    )

    $readErrors = [Collections.Generic.List[string]]::new()
    $rawValue = $null
    $dotNetValue = $null

    try {
        $target = switch ($Source) {
            "process" { [EnvironmentVariableTarget]::Process }
            "user" { [EnvironmentVariableTarget]::User }
            "machine" { [EnvironmentVariableTarget]::Machine }
        }
        $dotNetValue = [Environment]::GetEnvironmentVariable("Path", $target)
    } catch {
        $readErrors.Add(".NET $Source PATH read failed: $($_.Exception.Message)")
    }

    if ($Source -eq "process") {
        try {
            $rawValue = $env:Path
        } catch {
            $readErrors.Add("Process PATH read failed: $($_.Exception.Message)")
        }
    } else {
        $baseKey = $null
        $environmentKey = $null
        try {
            $hive = if ($Source -eq "user") {
                [Microsoft.Win32.RegistryHive]::CurrentUser
            } else {
                [Microsoft.Win32.RegistryHive]::LocalMachine
            }
            $subKey = if ($Source -eq "user") {
                "Environment"
            } else {
                "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
            }
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
            $environmentKey = $baseKey.OpenSubKey($subKey, $false)
            if ($null -eq $environmentKey) {
                throw "Registry key not found: $subKey"
            }
            $rawValue = $environmentKey.GetValue("Path", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } catch {
            $readErrors.Add("Registry $Source PATH read failed: $($_.Exception.Message)")
        } finally {
            if ($null -ne $environmentKey) {
                $environmentKey.Dispose()
            }
            if ($null -ne $baseKey) {
                $baseKey.Dispose()
            }
        }
    }

    return [pscustomobject]@{
        rawValue = $rawValue
        dotNetValue = $dotNetValue
        readErrors = @($readErrors)
    }
}

function Get-InventoryPathMetadata {
    param([string]$Path)

    try {
        $exists = Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop
        if (-not $exists) {
            return [pscustomobject]@{
                status = "ok"
                exists = $false
                isReparsePoint = $false
                reparseTarget = $null
            }
        }

        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $isReparsePoint = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        $target = if ($isReparsePoint -and $item.PSObject.Properties.Name -contains "Target") { $item.Target } else { $null }
        return [pscustomobject]@{
            status = "ok"
            exists = $true
            isReparsePoint = $isReparsePoint
            reparseTarget = $target
        }
    } catch {
        return [pscustomobject]@{
            status = "error"
            error = $_.Exception.Message
            exists = $null
            isReparsePoint = $null
            reparseTarget = $null
        }
    }
}

function Get-InventoryToolMetadata {
    param([string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) {
            throw "Tool path does not exist: $Path"
        }

        $currentPath = $Path
        while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $target = if ($item.PSObject.Properties.Name -contains "Target") { $item.Target } else { $null }
                return [pscustomobject]@{
                    status = "ok"
                    isReparsePoint = $true
                    reparseTarget = $target
                }
            }

            $parent = [IO.Directory]::GetParent($currentPath)
            if ($null -eq $parent) {
                break
            }
            $currentPath = $parent.FullName
        }

        return [pscustomobject]@{
            status = "ok"
            isReparsePoint = $false
            reparseTarget = $null
        }
    } catch {
        return [pscustomobject]@{
            status = "error"
            error = $_.Exception.Message
            isReparsePoint = $null
            reparseTarget = $null
        }
    }
}

function Get-PathScopeRecords {
    $resolver = {
        param([string]$Path)
        Get-InventoryPathMetadata -Path $Path
    }
    $records = [ordered]@{}
    foreach ($source in @("process", "user", "machine")) {
        $values = Get-PathScopeSourceValues -Source $source
        $records[$source] = New-PathScopeRecord -Source $source -RawValue $values.rawValue -DotNetValue $values.dotNetValue -ReadErrors $values.readErrors -MetadataResolver $resolver
    }
    return [pscustomobject]$records
}

function Invoke-PythonRuntimeProbe {
    param([Parameter(Mandatory)][string]$PythonPath)

    $arguments = @(
        "-I",
        "-S",
        "-c",
        'import json,sys; print(json.dumps({"executable":sys.executable,"prefix":sys.prefix,"basePrefix":sys.base_prefix}))'
    )
    $probe = Invoke-CommandWithTimeout -Executable $PythonPath -Arguments $arguments -TimeoutSeconds $VersionProbeTimeoutSeconds
    if ($probe.timedOut) {
        return ConvertFrom-PythonRuntimeProbe -Json $null -TimedOut
    }
    if ($probe.exitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($probe.error)) {
        $errorMessage = if (-not [string]::IsNullOrWhiteSpace($probe.error)) {
            $probe.error
        } else {
            "Python runtime probe exited with code $($probe.exitCode)"
        }
        return ConvertFrom-PythonRuntimeProbe -Json $null -ErrorMessage $errorMessage
    }

    $json = (@($probe.output | ForEach-Object { "$_" }) -join [Environment]::NewLine)
    return ConvertFrom-PythonRuntimeProbe -Json $json
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

function ConvertTo-MarkdownReport {
    param(
        [object]$Inventory
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
    $lines.Add("工具解析作用域：process。")
    $lines.Add("")
    $lines.Add("| 工具 | 是否存在 | 探测成功 | Launcher | Launcher originClass | Launcher matchedRule | Launcher matchedRoot | Launcher reparse | Runtime | Runtime originClass | Runtime matchedRule | Runtime matchedRoot | Runtime reparse | 最终归属 | 需人工审查 | 版本输出 | 错误 |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    foreach ($tool in $Inventory.tools) {
        $launcherReparse = "isReparsePoint=$($tool.launcher.isReparsePoint); target=$($tool.launcher.reparseTarget); metadataStatus=$($tool.launcher.metadataStatus)"
        $runtimeReparse = if ($null -eq $tool.runtime) { "" } else { "isReparsePoint=$($tool.runtime.isReparsePoint); target=$($tool.runtime.reparseTarget); metadataStatus=$($tool.runtime.metadataStatus)" }
        $lines.Add("| $(Escape-MarkdownCell $tool.name) | $(Escape-MarkdownCell $tool.found) | $(Escape-MarkdownCell $tool.probeSucceeded) | $(Escape-MarkdownCell $tool.launcher.path) | $(Escape-MarkdownCell $tool.launcher.originClass) | $(Escape-MarkdownCell $tool.launcher.matchedRule) | $(Escape-MarkdownCell $tool.launcher.matchedRoot) | $(Escape-MarkdownCell $launcherReparse) | $(Escape-MarkdownCell $tool.runtime.path) | $(Escape-MarkdownCell $tool.runtime.originClass) | $(Escape-MarkdownCell $tool.runtime.matchedRule) | $(Escape-MarkdownCell $tool.runtime.matchedRoot) | $(Escape-MarkdownCell $runtimeReparse) | $(Escape-MarkdownCell $tool.originClass) | $(Escape-MarkdownCell $tool.requiresManualReview) | $(Escape-MarkdownCell $tool.version) | $(Escape-MarkdownCell $tool.error) |")
    }
    $lines.Add("")
    $lines.Add("## PATH 作用域")
    $lines.Add("")
    $lines.Add("| 作用域 | 完整 | 条目数 | 重复数 | Raw SHA-256 |")
    $lines.Add("| --- | --- | --- | --- | --- |")
    foreach ($scopeName in @("process", "user", "machine")) {
        $scope = $Inventory.pathScopes.$scopeName
        $lines.Add("| $scopeName | $(Escape-MarkdownCell $scope.complete) | $($scope.entries.Count) | $($scope.duplicates.Count) | $(Escape-MarkdownCell $scope.rawValueSha256) |")
    }
    $lines.Add("")
    foreach ($scopeName in @("process", "user", "machine")) {
        $scope = $Inventory.pathScopes.$scopeName
        $lines.Add("### PATH scope: $scopeName")
        $lines.Add("")
        $lines.Add("- readStatus: $(Escape-MarkdownCell $scope.readStatus)")
        $lines.Add("- complete: $(Escape-MarkdownCell $scope.complete)")
        $errorSummary = if (@($scope.errors).Count -eq 0) { "none" } else { @($scope.errors | ForEach-Object { Escape-MarkdownCell $_ }) -join "; " }
        $lines.Add("- errors: $errorSummary")
        $lines.Add("")
        if (@($scope.entries).Count -eq 0) {
            $lines.Add("无 PATH 条目。")
        } else {
            $lines.Add("| index | rawPath | expandedPath | expansionStatus | exists | drive | isReparsePoint | reparseTarget |")
            $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- |")
            foreach ($entry in $scope.entries) {
                $lines.Add("| $(Escape-MarkdownCell $entry.index) | $(Escape-MarkdownCell $entry.rawPath) | $(Escape-MarkdownCell $entry.expandedPath) | $(Escape-MarkdownCell $entry.expansionStatus) | $(Escape-MarkdownCell $entry.exists) | $(Escape-MarkdownCell $entry.drive) | $(Escape-MarkdownCell $entry.isReparsePoint) | $(Escape-MarkdownCell $entry.reparseTarget) |")
            }
        }
        $lines.Add("")
    }
    $lines.Add("## PATH 入口（process 兼容投影）")
    $lines.Add("")
    $lines.Add("| 序号 | 是否存在 | 路径 |")
    $lines.Add("| --- | --- | --- |")
    foreach ($entry in $Inventory.pathEntries) {
        $lines.Add("| $(Escape-MarkdownCell $entry.index) | $(Escape-MarkdownCell $entry.exists) | $(Escape-MarkdownCell $entry.path) |")
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

    return $lines -join [Environment]::NewLine
}

Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"

$rawTools = @(
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

$toolMetadataResolver = {
    param([string]$Path)
    Get-InventoryToolMetadata -Path $Path
}
$sharedRoots = @(
    "D:\Codex\tools"
    "D:\Codex\envs"
    "D:\hermes-data\.local"
    "D:\hermes-data\.npm-global"
)
$vendorRoots = @(
    "D:\Codex\.codex\plugins"
    "D:\Codex\.codex\vendor"
)
$windowsSystemRoots = @(
    $env:SystemRoot
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Join-Path $env:ProgramFiles "WindowsApps"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    }
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$systemInstallerRoots = @(
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "Microsoft\WinGet"
    }
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$userProfileRoots = @(
    $env:USERPROFILE
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$tools = @(
    foreach ($tool in $rawTools) {
        $pythonRuntime = $null
        $runtimeProbeFailed = $false
        if ($tool.name -eq "python") {
            if ($tool.found -and -not $SkipVersionProbe) {
                $pythonRuntime = Invoke-PythonRuntimeProbe -PythonPath $tool.path
            } else {
                $pythonRuntime = ConvertFrom-PythonRuntimeProbe -Json $null -ErrorMessage $(if ($SkipVersionProbe) { "Skipped" } else { "Python launcher not found" })
            }
            $runtimeProbeFailed = -not [bool]$pythonRuntime.succeeded
        }

        $decisionArguments = @{
            LauncherPath = $tool.path
            RuntimePath = if ($null -ne $pythonRuntime -and $pythonRuntime.succeeded) { $pythonRuntime.executable } else { $null }
            RuntimePrefix = if ($null -ne $pythonRuntime -and $pythonRuntime.succeeded) { $pythonRuntime.prefix } else { $null }
            RuntimeBasePrefix = if ($null -ne $pythonRuntime -and $pythonRuntime.succeeded) { $pythonRuntime.basePrefix } else { $null }
            ProjectRoots = $ToolOwnerRoots
            SharedRoots = $sharedRoots
            VendorRoots = $vendorRoots
            WindowsSystemRoots = $windowsSystemRoots
            SystemInstallerRoots = $systemInstallerRoots
            UserProfileRoots = $userProfileRoots
            MetadataResolver = $toolMetadataResolver
            LauncherProbeSucceeded = [bool]$tool.probeSucceeded
            RuntimeProbeSucceeded = [bool]($null -ne $pythonRuntime -and $pythonRuntime.succeeded)
        }
        if ($runtimeProbeFailed) {
            $decisionArguments.RuntimeProbeFailed = $true
        }
        $origin = Get-ToolOriginDecision @decisionArguments
        if ($null -ne $pythonRuntime -and $null -ne $origin.runtime) {
            $origin.runtime | Add-Member -MemberType NoteProperty -Name prefix -Value $pythonRuntime.prefix -Force
            $origin.runtime | Add-Member -MemberType NoteProperty -Name basePrefix -Value $pythonRuntime.basePrefix -Force
            $origin.runtime | Add-Member -MemberType NoteProperty -Name probeError -Value $pythonRuntime.error -Force
        }

        [pscustomobject][ordered]@{
            name = $tool.name
            found = $tool.found
            path = $tool.path
            version = $tool.version
            evidence = $tool.evidence
            exitCode = $tool.exitCode
            probeSucceeded = $tool.probeSucceeded
            error = $tool.error
            launcher = $origin.launcher
            runtime = $origin.runtime
            originClass = $origin.originClass
            originEvidence = $origin.originEvidence
            resolutionScope = $origin.resolutionScope
            requiresManualReview = $origin.requiresManualReview
        }
    }
)

$directories = @(Get-KnownDirectories)
$localEnvironmentFindings = @(Get-LocalEnvironmentFindings -Roots $ProjectRoots)
$projectMarkers = @(Get-ProjectEnvironmentMarkers -LocalEnvironmentFindings $localEnvironmentFindings)
$candidates = @(Get-MigrationCandidates -Directories $directories)
$manualReviewItems = @(Get-ManualReviewItems -Directories $directories -LocalEnvironmentFindings $localEnvironmentFindings)
$envVars = @(Get-SelectedEnvironmentVariables)
$pathScopes = Get-PathScopeRecords

$inventory = New-InventoryV3Document -Facts @{
    generatedAt = (Get-Date).ToString("o")
    host = Get-HostSummary
    outputDir = $OutputDir
    projectRoots = $ProjectRoots
    toolOwnerRoots = $ToolOwnerRoots
    excludedRoots = @(Get-ExcludedRoots)
    versionProbeTimeoutSeconds = $VersionProbeTimeoutSeconds
    includeSizes = [bool]$IncludeSizes
    skipVersionProbe = [bool]$SkipVersionProbe
    tools = $tools
    selectedEnvironmentVariables = $envVars
    pathScopes = $pathScopes
    directories = $directories
    projectEnvironmentMarkers = $projectMarkers
    localEnvironmentFindings = $localEnvironmentFindings
    migrationCandidates = $candidates
    manualReviewItems = $manualReviewItems
}

$published = Publish-JsonMarkdownArtifactPair -Document $inventory -OutputDir $OutputDir -JsonFileName "inventory.json" -MarkdownFileName "REPORT.md" -RenderMarkdown {
    param($Document, $SourceJsonSha256)
    ConvertTo-MarkdownReport -Inventory $Document
}

[pscustomobject]@{
    inventory = $published.jsonPath
    report = $published.markdownPath
    generationId = $published.generationId
    readOnly = $true
}
