param(
    [string]$InventoryPath = "D:\Codex\projects\统一环境\reports\env-inventory\inventory.json",
    [string]$OutputDir = "D:\Codex\projects\统一环境\reports\env-update-readiness"
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

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        throw "$ParameterName 必须是目录路径，当前值是文件：$Path"
    }

    $current = $fullPath
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

function Get-LocationClass {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "unknown"
    }

    $normalized = $Path.ToLowerInvariant()
    if ($normalized.StartsWith("d:\")) {
        return "d-drive"
    }

    if ($normalized.StartsWith("c:\windows")) {
        return "windows-system"
    }

    if ($normalized.StartsWith("c:\program files")) {
        return "system-installer"
    }

    if ($normalized.Contains("\appdata\local\microsoft\winget\packages\")) {
        return "winget-package"
    }

    if ($normalized.StartsWith("c:\users\")) {
        return "user-profile"
    }

    return "other"
}

function Get-PathDisplay {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "未解析（inventory 未返回路径）"
    }

    return $Path
}

function Get-UpdatePolicy {
    param([object]$Tool)

    $locationClass = Get-LocationClass -Path $Tool.path
    $name = "$($Tool.name)".ToLowerInvariant()
    $entry = "人工确认"
    $action = "不自动更新；需要人工确认更新入口。"
    $risk = "medium"

    switch ($name) {
        "uv" {
            $entry = "uv self update 或重装到 D 盘工具根"
            $action = "先确认当前入口是否应迁到 D 盘；本项目只生成建议，不执行 uv 更新。"
            $risk = if ($locationClass -eq "user-profile") { "medium" } else { "low" }
        }
        "node" {
            $entry = "官方 Node 安装器、mise/fnm/nvm-windows 迁移方案或 winget"
            $action = "不要直接搬 C 盘安装目录；后续用独立 issue 选择 Node 管理器。"
            $risk = "medium"
        }
        "npm" {
            $entry = "随 Node 一起管理"
            $action = "跟随 Node 管理策略；不要单独改 npm 入口。"
            $risk = "medium"
        }
        "cargo" {
            $entry = "rustup 或官方 Rust 安装方式"
            $action = "当前入口在系统安装目录；不要直接搬目录。"
            $risk = "medium"
        }
        "rustc" {
            $entry = "rustup 或官方 Rust 安装方式"
            $action = "当前入口在系统安装目录；不要直接搬目录。"
            $risk = "medium"
        }
        "dotnet" {
            $entry = ".NET 官方安装器、winget 或已存在 D 盘 dotnet 策略"
            $action = "当前探测失败或入口位于系统安装目录；先诊断再更新。"
            $risk = "high"
        }
        "cmake" {
            $entry = "WinGet package 或 D 盘工具根重装"
            $action = "当前来自 WinGet 包目录；不要直接搬目录。"
            $risk = "medium"
        }
        "ninja" {
            $entry = "WinGet package 或 D 盘工具根重装"
            $action = "当前来自 WinGet 包目录；不要直接搬目录。"
            $risk = "medium"
        }
        "wsl" {
            $entry = "Windows 功能 / WSL 官方机制"
            $action = "系统组件，不由本项目自动更新。"
            $risk = "high"
        }
        "git" {
            $entry = "Git for Windows 安装器或现有 D 盘安装策略"
            $action = "当前已在 D 盘；后续可单独确认 Git 更新入口。"
            $risk = "low"
        }
        "python" {
            $entry = "官方 Python 安装器、uv python 或 D 盘工具根策略"
            $action = "当前已在 D 盘；后续优先统一 Python 管理策略。"
            $risk = "low"
        }
        "pwsh" {
            $entry = "D 盘 PowerShell 工具根策略"
            $action = "当前已在 D 盘；保持现有 host 策略，不自动更新。"
            $risk = "low"
        }
        "powershell" {
            $entry = "当前 PowerShell 解析入口"
            $action = "仅记录入口，不自动更新。"
            $risk = "low"
        }
        default {
            if ($locationClass -eq "d-drive") {
                $entry = "现有 D 盘工具策略"
                $action = "已在 D 盘；后续按工具所属生态单独确认。"
                $risk = "low"
            } elseif ($locationClass -in @("windows-system", "system-installer", "winget-package")) {
                $entry = "官方安装器、系统机制或包管理器"
                $action = "不直接搬迁；后续按官方更新入口处理。"
                $risk = "medium"
            }
        }
    }

    [pscustomobject]@{
        name = $Tool.name
        found = $Tool.found
        path = $Tool.path
        pathDisplay = Get-PathDisplay -Path $Tool.path
        pathStatus = if ([string]::IsNullOrWhiteSpace($Tool.path)) { "unresolved" } else { "resolved" }
        version = $Tool.version
        probeSucceeded = $Tool.probeSucceeded
        locationClass = $locationClass
        drive = Get-RootDrive -Path $Tool.path
        recommendedUpdateEntry = $entry
        recommendedAction = $action
        autoUpdateAllowed = $false
        riskLevel = $risk
        reason = "本报告只做更新准备分类，不执行任何更新命令。"
    }
}

function Get-PathSummary {
    param([object[]]$PathEntries)

    $existing = @($PathEntries | Where-Object { $_.exists })
    $cDrive = @($existing | Where-Object { $_.drive -like "C:\*" })
    $dDrive = @($existing | Where-Object { $_.drive -like "D:\*" })
    $missing = @($PathEntries | Where-Object { -not $_.exists })
    $duplicates = @(
        $PathEntries |
            Group-Object -Property path |
            Where-Object { $_.Count -gt 1 } |
            ForEach-Object {
                [pscustomobject]@{
                    path = $_.Name
                    count = $_.Count
                }
            }
    )

    [pscustomobject]@{
        total = $PathEntries.Count
        existing = $existing.Count
        cDrive = $cDrive.Count
        dDrive = $dDrive.Count
        missing = $missing.Count
        duplicates = $duplicates
        recommendations = @(
            "保留系统目录和官方安装器目录，不直接搬迁。",
            "对重复 PATH 入口单独建立清理 issue。",
            "对 C 盘工具入口先生成更新/重装方案，再决定是否切到 D 盘。",
            "对 D 盘 PATH 入口优先保留已验证工具根；如同一工具有多个 D 盘入口，再单独去重。",
            "对缺失 PATH 入口先确认是否仍有工具依赖，再决定删除。"
        )
    }
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function Convert-LocationClassToDisplay {
    param([string]$LocationClass)

    switch ($LocationClass) {
        "d-drive" { return "D 盘" }
        "windows-system" { return "Windows 系统目录" }
        "system-installer" { return "系统安装目录" }
        "winget-package" { return "WinGet 包目录" }
        "user-profile" { return "用户目录" }
        "unknown" { return "未解析" }
        "other" { return "其他位置" }
        default { return $LocationClass }
    }
}

function Convert-RiskLevelToDisplay {
    param([string]$RiskLevel)

    switch ($RiskLevel) {
        "low" { return "低" }
        "medium" { return "中" }
        "high" { return "高" }
        default { return $RiskLevel }
    }
}

function Write-ReadinessMarkdown {
    param(
        [object]$Readiness,
        [string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 统一更新准备报告")
    $lines.Add("")
    $lines.Add("生成时间：$($Readiness.generatedAt)")
    $lines.Add("")
    $lines.Add("> 只读报告：本报告不会执行 winget、Scoop、uv、npm、Cargo、Rustup 或任何其他更新命令。")
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add("- 工具项数量：$($Readiness.toolReadiness.Count)")
    $lines.Add("- 高风险对象：$($Readiness.highRiskItems.Count)")
    $lines.Add("- PATH 总入口：$($Readiness.pathSummary.total)")
    $lines.Add("- PATH C 盘入口：$($Readiness.pathSummary.cDrive)")
    $lines.Add("- PATH D 盘入口：$($Readiness.pathSummary.dDrive)")
    $lines.Add("")
    $lines.Add("## 工具更新准备")
    $lines.Add("")
    $lines.Add("| 工具 | 位置类型 | 当前入口 | 推荐更新入口 | 建议动作 | 风险 | 不自动更新 |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- |")
    foreach ($item in $Readiness.toolReadiness) {
        $locationDisplay = Convert-LocationClassToDisplay -LocationClass $item.locationClass
        $riskDisplay = Convert-RiskLevelToDisplay -RiskLevel $item.riskLevel
        $noAutoUpdateDisplay = if ($item.autoUpdateAllowed) { "否" } else { "是" }
        $lines.Add("| $(Escape-MarkdownCell $item.name) | $(Escape-MarkdownCell $locationDisplay) | $(Escape-MarkdownCell $item.pathDisplay) | $(Escape-MarkdownCell $item.recommendedUpdateEntry) | $(Escape-MarkdownCell $item.recommendedAction) | $(Escape-MarkdownCell $riskDisplay) | $(Escape-MarkdownCell $noAutoUpdateDisplay) |")
    }
    $lines.Add("")
    $lines.Add("## PATH 整理建议")
    $lines.Add("")
    foreach ($recommendation in $Readiness.pathSummary.recommendations) {
        $lines.Add("- $recommendation")
    }
    $lines.Add("")
    if ($Readiness.pathSummary.duplicates.Count -gt 0) {
        $lines.Add("### 重复 PATH 入口")
        $lines.Add("")
        $lines.Add("| 路径 | 次数 |")
        $lines.Add("| --- | --- |")
        foreach ($duplicate in $Readiness.pathSummary.duplicates) {
            $lines.Add("| $(Escape-MarkdownCell $duplicate.path) | $(Escape-MarkdownCell $duplicate.count) |")
        }
        $lines.Add("")
    }
    $lines.Add("## 高风险对象")
    $lines.Add("")
    if ($Readiness.highRiskItems.Count -eq 0) {
        $lines.Add("无。")
    } else {
        $lines.Add("| 工具 | 路径 | 原因 |")
        $lines.Add("| --- | --- | --- |")
        foreach ($item in $Readiness.highRiskItems) {
            $lines.Add("| $(Escape-MarkdownCell $item.name) | $(Escape-MarkdownCell $item.pathDisplay) | $(Escape-MarkdownCell $item.recommendedAction) |")
        }
    }
    $lines.Add("")
    $lines.Add("## 策略")
    $lines.Add("")
    foreach ($rule in $Readiness.policy.rules) {
        $lines.Add("- $rule")
    }

    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

if (-not (Test-Path -Path $InventoryPath -PathType Leaf)) {
    throw "Inventory not found: $InventoryPath"
}

Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"

$inventory = Get-Content -Path $InventoryPath -Raw | ConvertFrom-Json
$toolReadiness = @($inventory.tools | Where-Object { $_.found } | ForEach-Object { Get-UpdatePolicy -Tool $_ })
$pathSummary = Get-PathSummary -PathEntries @($inventory.pathEntries)
$highRiskItems = @($toolReadiness | Where-Object { $_.riskLevel -eq "high" })

$readiness = [pscustomobject]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    readOnly = $true
    inventoryPath = $InventoryPath
    inventoryGeneratedAt = "$($inventory.generatedAt)"
    toolReadiness = $toolReadiness
    pathSummary = $pathSummary
    highRiskItems = $highRiskItems
    policy = [pscustomobject]@{
        autoUpdateAllowed = $false
        rules = @(
            "本项目只生成更新准备报告，不执行任何更新命令。",
            "系统组件、MSI/官方安装器、WinGet 包目录和 Windows 功能不直接搬迁。",
            "D 盘工具入口优先保持现有策略，更新前需单独确认。",
            "高风险对象必须进入人工审查，不能进入自动更新候选。"
        )
    }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"

$jsonPath = Join-Path $OutputDir "readiness.json"
$markdownPath = Join-Path $OutputDir "REPORT.md"

$readiness | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
Write-ReadinessMarkdown -Readiness $readiness -Path $markdownPath

[pscustomobject]@{
    readinessJson = $jsonPath
    readinessMarkdown = $markdownPath
    readOnly = $true
}
