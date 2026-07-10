. (Join-Path $PSScriptRoot "EnvPathSafety.ps1")

function Test-ReadinessInteger {
    param([AllowNull()][object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Assert-ReadinessProperty {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FactName
    )
    if (-not ($Value.PSObject.Properties.Name -contains $Name)) {
        throw "$FactName 缺少字段：$Name"
    }
}

function Assert-ReadinessOriginEvidence {
    param(
        [Parameter(Mandatory)][object]$Evidence,
        [Parameter(Mandatory)][string]$FactName
    )
    if ($Evidence -isnot [pscustomobject]) { throw "$FactName 必须是 object。" }
    foreach ($name in @("path", "originClass", "matchedRule", "matchedRoot", "metadataStatus", "metadataError", "isReparsePoint", "reparseAncestor", "reparseTarget")) {
        Assert-ReadinessProperty -Value $Evidence -Name $name -FactName $FactName
    }
    if ($Evidence.originClass -isnot [string] -or $Evidence.originClass -notin @("shared-tool", "system-installer", "windows-system", "user-profile", "vendor-runtime", "project-local-env", "unknown")) {
        throw "$FactName.originClass 无效。"
    }
    if ($Evidence.metadataStatus -isnot [string] -or $Evidence.metadataStatus -notin @("ok", "error", "not-run")) {
        throw "$FactName.metadataStatus 无效。"
    }
    if ($null -ne $Evidence.path -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.path)) {
        Assert-EnvSafeAbsolutePath -Path $Evidence.path -FactName "$FactName.path"
    }
    if ($Evidence.isReparsePoint -isnot [bool] -and $null -ne $Evidence.isReparsePoint) {
        throw "$FactName.isReparsePoint 必须是 Boolean 或 null。"
    }
    foreach ($pathField in @("matchedRoot", "reparseAncestor", "reparseTarget")) {
        if ($null -ne $Evidence.$pathField -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.$pathField)) {
            Assert-EnvSafeAbsolutePath -Path $Evidence.$pathField -FactName "$FactName.$pathField"
        }
    }
}

function Assert-ReadinessPathScope {
    param(
        [Parameter(Mandatory)][object]$Scope,
        [Parameter(Mandatory)][string]$ScopeName
    )
    $factName = "Inventory pathScopes.$ScopeName"
    if ($Scope -isnot [pscustomobject]) { throw "$factName 必须是 object。" }
    foreach ($name in @("source", "readStatus", "complete", "errors", "entries", "duplicates", "missingPathCleanupCandidates")) {
        Assert-ReadinessProperty -Value $Scope -Name $name -FactName $factName
    }
    if ($Scope.source -isnot [string] -or $Scope.source -cne $ScopeName) { throw "$factName.source 必须为 $ScopeName。" }
    if ($Scope.readStatus -isnot [string] -or $Scope.readStatus -notin @("ok", "error")) { throw "$factName.readStatus 无效。" }
    if ($Scope.complete -isnot [bool]) { throw "$factName.complete 必须是 Boolean。" }
    foreach ($arrayName in @("errors", "entries", "duplicates", "missingPathCleanupCandidates")) {
        if ($Scope.$arrayName -isnot [array]) { throw "$factName.$arrayName 必须是数组。" }
    }
    foreach ($errorText in @($Scope.errors)) {
        if ($errorText -isnot [string]) { throw "$factName.errors 只能包含字符串。" }
    }
    foreach ($entry in @($Scope.entries)) {
        if ($entry -isnot [pscustomobject]) { throw "$factName entry 必须是 object。" }
        foreach ($name in @("index", "rawPath", "expandedPath", "expansionStatus", "exists", "drive", "isReparsePoint", "reparseTarget")) {
            Assert-ReadinessProperty -Value $entry -Name $name -FactName "$factName entry"
        }
        if (-not (Test-ReadinessInteger $entry.index) -or $entry.index -lt 0) { throw "$factName entry.index 必须是非负整数。" }
        if ($entry.rawPath -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.rawPath)) { throw "$factName entry.rawPath 必须是非空字符串。" }
        if ($entry.expandedPath -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.expandedPath)) { throw "$factName entry.expandedPath 必须是非空字符串。" }
        if ($entry.expansionStatus -isnot [string] -or $entry.expansionStatus -notin @("expanded", "not-required", "failed")) { throw "$factName entry.expansionStatus 无效。" }
        if ($entry.exists -isnot [bool] -and $null -ne $entry.exists) { throw "$factName entry.exists 必须是 Boolean 或 null。" }
        if ($entry.isReparsePoint -isnot [bool] -and $null -ne $entry.isReparsePoint) { throw "$factName entry.isReparsePoint 必须是 Boolean 或 null。" }
        if ($entry.expansionStatus -ne "failed") {
            Assert-EnvSafeAbsolutePath -Path $entry.expandedPath -FactName "$factName entry.expandedPath"
        }
        if ($null -ne $entry.drive) { Assert-EnvSafeAbsolutePath -Path $entry.drive -FactName "$factName entry.drive" }
        if ($null -ne $entry.reparseTarget) { Assert-EnvSafeReparseTarget -Path $entry.reparseTarget -FactName "$factName entry.reparseTarget" }
        if ($Scope.complete -and ($entry.expansionStatus -eq "failed" -or $entry.exists -isnot [bool] -or $entry.isReparsePoint -isnot [bool] -or $entry.isReparsePoint)) {
            throw "$factName.complete=true 与 entry 的未知/失败/reparse 事实矛盾。"
        }
    }
    foreach ($duplicate in @($Scope.duplicates)) {
        if ($duplicate -isnot [pscustomobject]) { throw "$factName duplicate 必须是 object。" }
        foreach ($name in @("firstIndex", "duplicateIndex", "expandedPath")) { Assert-ReadinessProperty -Value $duplicate -Name $name -FactName "$factName duplicate" }
        if (-not (Test-ReadinessInteger $duplicate.firstIndex) -or -not (Test-ReadinessInteger $duplicate.duplicateIndex)) { throw "$factName duplicate index 必须是整数。" }
        Assert-EnvSafeAbsolutePath -Path $duplicate.expandedPath -FactName "$factName duplicate.expandedPath"
    }
    if ($Scope.complete -and ($Scope.readStatus -cne "ok" -or @($Scope.errors).Count -gt 0)) {
        throw "$factName.complete=true 与 readStatus/errors 矛盾。"
    }
}

function Assert-InventoryV3Document {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Document)

    if ($Document -isnot [pscustomobject]) { throw "Inventory 必须是 JSON object。" }
    foreach ($name in @("artifactType", "schemaVersion", "generatedAt", "tools", "pathScopes")) {
        Assert-ReadinessProperty -Value $Document -Name $name -FactName "Inventory"
    }
    if ($Document.artifactType -isnot [string] -or $Document.artifactType -cne "env-governance.inventory") {
        throw "Inventory artifactType 必须为 env-governance.inventory。"
    }
    if (-not (Test-ReadinessInteger -Value $Document.schemaVersion) -or $Document.schemaVersion -ne 3) {
        throw "Inventory schemaVersion 必须是整数 3。"
    }
    if ($Document.generatedAt -isnot [string] -or [string]::IsNullOrWhiteSpace($Document.generatedAt)) {
        throw "Inventory generatedAt 必须是非空字符串。"
    }
    if ($Document.tools -isnot [array]) { throw "Inventory tools 必须是数组。" }
    if ($Document.pathScopes -isnot [pscustomobject]) { throw "Inventory pathScopes 必须是 object。" }

    foreach ($scopeName in @("process", "user", "machine")) {
        Assert-ReadinessProperty -Value $Document.pathScopes -Name $scopeName -FactName "Inventory pathScopes"
        Assert-ReadinessPathScope -Scope $Document.pathScopes.$scopeName -ScopeName $scopeName
    }

    $allowedOrigins = @("shared-tool", "system-installer", "windows-system", "user-profile", "vendor-runtime", "project-local-env", "unknown")
    foreach ($tool in @($Document.tools)) {
        if ($tool -isnot [pscustomobject]) { throw "Inventory tool 必须是 object。" }
        foreach ($name in @("name", "found", "path", "version", "probeSucceeded", "error", "launcher", "runtime", "originClass", "originEvidence", "resolutionScope", "requiresManualReview")) {
            Assert-ReadinessProperty -Value $tool -Name $name -FactName "Inventory tool"
        }
        if ($tool.name -isnot [string] -or [string]::IsNullOrWhiteSpace($tool.name)) { throw "Inventory tool.name 必须是非空字符串。" }
        foreach ($booleanName in @("found", "probeSucceeded", "requiresManualReview")) {
            if ($tool.$booleanName -isnot [bool]) { throw "Inventory tool.$booleanName 必须是 Boolean。" }
        }
        if ($null -ne $tool.path -and -not [string]::IsNullOrWhiteSpace([string]$tool.path)) { Assert-EnvSafeAbsolutePath -Path $tool.path -FactName "Inventory tool.path" }
        if ($tool.originClass -isnot [string] -or $tool.originClass -notin $allowedOrigins) { throw "Inventory tool.originClass 无效。" }
        if ($tool.resolutionScope -isnot [string] -or $tool.resolutionScope -cne "process") { throw "Inventory tool.resolutionScope 必须为 process。" }
        if ($tool.originEvidence -isnot [array]) { throw "Inventory tool.originEvidence 必须是数组。" }
        Assert-ReadinessOriginEvidence -Evidence $tool.launcher -FactName "Inventory tool.launcher"
        if ($null -ne $tool.runtime) { Assert-ReadinessOriginEvidence -Evidence $tool.runtime -FactName "Inventory tool.runtime" }
        if ([string]$tool.path -cne [string]$tool.launcher.path) { throw "Inventory tool.path 必须与 launcher.path 一致。" }
        foreach ($originItem in @($tool.originEvidence)) {
            if ($originItem -isnot [pscustomobject]) { throw "Inventory tool.originEvidence item 必须是 object。" }
            foreach ($name in @("role", "evidence")) { Assert-ReadinessProperty -Value $originItem -Name $name -FactName "Inventory tool.originEvidence item" }
            if ($originItem.role -isnot [string] -or $originItem.role -notin @("launcher", "runtime")) { throw "Inventory tool.originEvidence role 无效。" }
            Assert-ReadinessOriginEvidence -Evidence $originItem.evidence -FactName "Inventory tool.originEvidence.evidence"
        }
        $launcherItems = @($tool.originEvidence | Where-Object { $_.role -ceq "launcher" })
        $runtimeItems = @($tool.originEvidence | Where-Object { $_.role -ceq "runtime" })
        if ($launcherItems.Count -ne 1 -or (($null -eq $tool.runtime) -and $runtimeItems.Count -ne 0) -or (($null -ne $tool.runtime) -and $runtimeItems.Count -ne 1)) {
            throw "Inventory tool.originEvidence 必须与 launcher/runtime 角色一一对应。"
        }
        $expectedFinalOrigin = if ($null -ne $tool.runtime) { $tool.runtime.originClass } else { $tool.launcher.originClass }
        if ($tool.originClass -cne $expectedFinalOrigin) { throw "Inventory tool.originClass 与 launcher/runtime 最终归属不一致。" }
        $roleEvidence = @($tool.launcher)
        if ($null -ne $tool.runtime) { $roleEvidence += $tool.runtime }
        $riskOrigins = @("project-local-env", "vendor-runtime", "system-installer", "windows-system", "user-profile", "unknown")
        $mustReview = @($roleEvidence | Where-Object {
            $_.originClass -in $riskOrigins -or $_.metadataStatus -cne "ok" -or $_.isReparsePoint -ne $false
        }).Count -gt 0
        if ($mustReview -and -not $tool.requiresManualReview) { throw "Inventory tool.requiresManualReview 与 origin/reparse/metadata 风险证据矛盾。" }
    }
}

function Get-ReadinessLocationClass {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "unknown" }
    Assert-EnvSafeAbsolutePath -Path $Path -FactName "Tool decision path"
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($normalized -match '(?i)^D:\\') { return "d-drive" }
    if ($normalized -match '(?i)^C:\\Users\\[^\\]+\\AppData\\Local\\Microsoft\\WinGet\\Packages(?:\\|$)') { return "winget-package" }
    if ($normalized -match '(?i)^C:\\Windows(?:\\|$)') { return "windows-system" }
    if ($normalized -match '(?i)^C:\\Program Files(?: \(x86\))?(?:\\|$)') { return "system-installer" }
    if ($normalized -match '(?i)^C:\\Users(?:\\|$)') { return "user-profile" }
    return "other"
}

function Get-ToolDecisionInputs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Tool)

    foreach ($name in @("path", "originClass", "probeSucceeded", "requiresManualReview", "resolutionScope")) {
        Assert-ReadinessProperty -Value $Tool -Name $name -FactName "Tool"
    }
    if ($Tool.probeSucceeded -isnot [bool] -or $Tool.requiresManualReview -isnot [bool]) {
        throw "Tool probeSucceeded/requiresManualReview 必须是 Boolean。"
    }
    if ($Tool.originClass -isnot [string] -or $Tool.resolutionScope -isnot [string] -or $Tool.resolutionScope -cne "process") {
        throw "Tool originClass/resolutionScope 无效。"
    }
    [pscustomobject][ordered]@{
        locationClass = Get-ReadinessLocationClass -Path $Tool.path
        originClass = $Tool.originClass
        probeSucceeded = $Tool.probeSucceeded
        requiresManualReview = $Tool.requiresManualReview
        resolutionScope = $Tool.resolutionScope
    }
}

function Get-BaseUpdateDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$DecisionInputs)

    $origin = [string]$DecisionInputs.originClass
    $location = [string]$DecisionInputs.locationClass
    $probeSucceeded = $DecisionInputs.probeSucceeded
    $inventoryManual = $DecisionInputs.requiresManualReview
    if ($probeSucceeded -isnot [bool] -or $inventoryManual -isnot [bool]) { throw "DecisionInputs Boolean 字段类型无效。" }

    if (-not $probeSucceeded) {
        $risk = "high"; $manual = $true
        $action = "工具探测未成功；先诊断探测错误，再决定是否通过官方机制更新。"
    } elseif ($origin -eq "project-local-env") {
        $risk = "high"; $manual = $true
        $action = "归属项目本地环境；保持项目隔离，按项目重建流程人工审查，不作为共享默认入口。"
    } elseif ($origin -eq "vendor-runtime") {
        $risk = "high"; $manual = $true
        $action = "归属 vendor runtime；由所属产品的官方机制管理，不作为共享默认入口。"
    } elseif ($origin -eq "unknown") {
        $risk = "high"; $manual = $true
        $action = "工具归属未知；先确认真实 launcher、runtime 与管理机制。"
    } elseif ($origin -eq "user-profile") {
        $risk = "high"; $manual = $true
        $action = "工具归属用户目录；先确认包管理器和 owner，再选择官方更新机制。"
    } elseif ($origin -in @("windows-system", "system-installer") -or $location -in @("windows-system", "system-installer", "winget-package")) {
        $risk = "medium"; $manual = $true
        $action = "位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。"
    } elseif ($origin -eq "shared-tool" -and $location -eq "d-drive") {
        $risk = "low"; $manual = $false
        $action = "位于明确的 D 盘共享工具根；保持现有位置策略，后续按工具生态单独审查更新。"
    } else {
        $risk = "medium"; $manual = $true
        $action = "位置或归属未满足共享工具信任条件；先人工确认管理机制。"
    }

    if ($inventoryManual -and -not $manual) {
        $manual = $true
        $risk = "high"
        $action = "$action Inventory 已标记人工审查，必须先核对 origin/reparse 证据。"
    }
    [pscustomobject]@{ riskLevel = $risk; requiresManualReview = $manual; recommendedAction = $action }
}

function Get-ToolUpdateEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name.ToLowerInvariant()) {
        "python" { "Python 官方安装器或 uv python" }
        "py" { "Python 官方安装器" }
        "uv" { "uv self update 或 uv 官方安装方式" }
        "node" { "Node.js 官方安装器或已批准的版本管理器" }
        "npm" { "随 Node.js 官方更新机制管理" }
        "cargo" { "rustup 或 Rust 官方安装器" }
        "rustc" { "rustup 或 Rust 官方安装器" }
        "rust" { "rustup 或 Rust 官方安装器" }
        "dotnet" { ".NET 官方安装器或官方包管理入口" }
        "cmake" { "CMake 官方发行包或已批准的包管理器" }
        "ninja" { "Ninja 官方发行包或已批准的包管理器" }
        "wsl" { "Windows 功能和 WSL 官方机制" }
        "git" { "Git for Windows 官方安装器" }
        "pwsh" { "PowerShell 官方发布或已批准的包管理器" }
        "powershell" { "Windows 系统维护机制" }
        default { "该工具的官方更新机制" }
    }
}

function Get-ToolUpdateEntryObject {
    param([Parameter(Mandatory)][object]$Tool)
    [pscustomobject]@{ name = $Tool.name; recommendedUpdateEntry = Get-ToolUpdateEntry -Name $Tool.name }
}

function Get-UpdatePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Tool)
    $inputs = Get-ToolDecisionInputs -Tool $Tool
    $base = Get-BaseUpdateDecision -DecisionInputs $inputs
    $entry = Get-ToolUpdateEntryObject -Tool $Tool
    [pscustomobject][ordered]@{
        name = $Tool.name
        found = $Tool.found
        path = $Tool.path
        pathDisplay = if ([string]::IsNullOrWhiteSpace([string]$Tool.path)) { "未解析（inventory 未返回路径）" } else { $Tool.path }
        pathStatus = if ([string]::IsNullOrWhiteSpace([string]$Tool.path)) { "unresolved" } else { "resolved" }
        version = $Tool.version
        probeSucceeded = $Tool.probeSucceeded
        locationClass = $inputs.locationClass
        originClass = $inputs.originClass
        decisionInputs = $inputs
        recommendedUpdateEntry = $entry.recommendedUpdateEntry
        recommendedAction = $base.recommendedAction
        requiresManualReview = $base.requiresManualReview
        autoUpdateAllowed = $false
        riskLevel = $base.riskLevel
        reason = "本报告只做更新准备分类，不执行任何更新命令。"
    }
}

function Get-ReadinessPathSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ProcessScope)
    if ($ProcessScope.source -isnot [string] -or $ProcessScope.source -cne "process" -or $ProcessScope.complete -isnot [bool] -or $ProcessScope.entries -isnot [array] -or $ProcessScope.duplicates -isnot [array]) {
        throw "Process PATH scope contract 无效。"
    }
    $entries = @($ProcessScope.entries)
    $existing = @($entries | Where-Object { $_.exists -is [bool] -and $_.exists })
    $missingFacts = @($entries | Where-Object { $_.exists -is [bool] -and -not $_.exists })
    $cleanupAllowed = [bool]$ProcessScope.complete
    $missingEntries = @(
        if ($cleanupAllowed) {
            foreach ($entry in $missingFacts) {
                $path = [string]$entry.expandedPath
                Assert-EnvSafeAbsolutePath -Path $path -FactName "Process PATH entry"
                $isLocal = $path -match '(?i)\\(?:\.venv|venv(?:-[^\\]+)?)\\Scripts\\?$' -or $path -match '(?i)\\node_modules(?:\\\.bin)?\\?$'
                [pscustomobject]@{
                    index = $entry.index
                    path = $path
                    drive = $entry.drive
                    isProjectLocalEnvEntry = $isLocal
                    riskLevel = if ($isLocal) { "medium" } else { "low" }
                    recommendedAction = if ($isLocal) { "先确认是否仍有项目依赖；若确认失效，再单独清理 PATH，不重建或删除环境目录。" } else { "先确认工具是否仍需要该入口；不得作为迁移副作用直接删除。" }
                }
            }
        }
    )
    [object[]]$duplicateItems = if ($cleanupAllowed) { @($ProcessScope.duplicates) } else { @() }
    [string[]]$summaryErrors = @($ProcessScope.errors)
    [string[]]$recommendations = if ($cleanupAllowed) {
        @(
            "仅基于完整的 Process PATH scope 生成清理建议。",
            "保留系统目录和官方安装器目录，不直接搬迁。",
            "对重复或缺失 PATH 入口单独建立清理 issue，不作为迁移副作用删除。"
        )
    } else {
        @("Process PATH scope 不完整；本报告不生成缺失、重复或失效入口清理建议。")
    }
    [pscustomobject][ordered]@{
        sourceScope = "process"
        complete = $ProcessScope.complete
        cleanupAdviceAllowed = $cleanupAllowed
        errors = $summaryErrors
        total = $entries.Count
        existing = $existing.Count
        cDrive = @($existing | Where-Object { $_.drive -like "C:\*" }).Count
        dDrive = @($existing | Where-Object { $_.drive -like "D:\*" }).Count
        missing = $missingFacts.Count
        missingEntries = $missingEntries
        staleLocalEnvironmentEntries = @($missingEntries | Where-Object { $_.isProjectLocalEnvEntry })
        duplicates = $duplicateItems
        recommendations = $recommendations
    }
}
