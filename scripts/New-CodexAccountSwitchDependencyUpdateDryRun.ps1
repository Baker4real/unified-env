param(
    [string]$ProjectPath = "D:\Codex\projects\codex-account-switch",
    [string]$OutputDir = "D:\Codex\projects\统一环境\reports\codex-account-switch-dependency-update-dry-run",
    [string]$NpmLsJsonPath,
    [string]$NpmOutdatedJsonPath,
    [string]$NpmAuditJsonPath,
    [string]$GitStatusTextPath,
    [string]$NodeVersion,
    [string]$NpmVersion,
    [string]$NpmCache,
    [string]$NodeCommand = "node",
    [string]$NpmCommand = "npm",
    [string]$GitCommand = "git"
)

$ErrorActionPreference = "Stop"

function Test-IsSubPath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullBasePath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd("\", "/")
    return $fullPath.Equals($fullBasePath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith("$fullBasePath\", [System.StringComparison]::OrdinalIgnoreCase)
}

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

    $current = $fullPath
    if (-not (Test-Path -LiteralPath $current)) {
        $parent = [System.IO.Directory]::GetParent($current.TrimEnd("\", "/"))
        if ($null -ne $parent) {
            $current = $parent.FullName
        }
    }

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

function Assert-AllowedOutputDir {
    param([string]$Path)

    $allowedRoots = @(
        "D:\Codex\projects\统一环境\reports",
        "D:\Codex\.codex\run-evidence\env-governance"
    )

    foreach ($allowedRoot in $allowedRoots) {
        if (Test-IsSubPath -Path $Path -BasePath $allowedRoot) {
            return
        }
    }

    throw "OutputDir 必须位于允许的报告目录：D:\Codex\projects\统一环境\reports 或 D:\Codex\.codex\run-evidence\env-governance。当前值：$Path"
}

function Assert-ReadableDFile {
    param(
        [string]$Path,
        [string]$ParameterName
    )

    Assert-DDrivePath -Path $Path -ParameterName $ParameterName
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$ParameterName 不存在：$Path"
    }
}

function Test-ReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ("$Value" -replace "\|", "\|" -replace "`r", " " -replace "`n", " ").Trim()
}

function Invoke-NativeCommand {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }
    } finally {
        Pop-Location
    }

    [pscustomobject]@{
        command = "$Command $($Arguments -join ' ')"
        workingDirectory = $WorkingDirectory
        exitCode = $exitCode
        output = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
        source = "command"
    }
}

function ConvertFrom-JsonOutput {
    param(
        [string]$Text,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{}
    }

    $trimmed = $Text.Trim()
    try {
        return $trimmed | ConvertFrom-Json
    } catch {
        $start = $trimmed.IndexOf("{")
        $end = $trimmed.LastIndexOf("}")
        if ($start -ge 0 -and $end -gt $start) {
            return $trimmed.Substring($start, $end - $start + 1) | ConvertFrom-Json
        }

        throw "$Label 输出不是可解析 JSON。"
    }
}

function Read-JsonInputOrCommand {
    param(
        [string]$Path,
        [string]$Label,
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        Assert-ReadableDFile -Path $Path -ParameterName $Label
        $text = Get-Content -LiteralPath $Path -Raw
        return [pscustomobject]@{
            data = ConvertFrom-JsonOutput -Text $text -Label $Label
            result = [pscustomobject]@{
                command = "file:$Path"
                workingDirectory = $WorkingDirectory
                exitCode = 0
                output = ""
                source = "file"
            }
        }
    }

    $result = Invoke-NativeCommand -Command $Command -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    return [pscustomobject]@{
        data = ConvertFrom-JsonOutput -Text $result.output -Label $Label
        result = $result
    }
}

function Read-TextInputOrCommand {
    param(
        [string]$Path,
        [string]$Label,
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        Assert-ReadableDFile -Path $Path -ParameterName $Label
        return [pscustomobject]@{
            text = (Get-Content -LiteralPath $Path -Raw).Trim()
            result = [pscustomobject]@{
                command = "file:$Path"
                workingDirectory = $WorkingDirectory
                exitCode = 0
                output = ""
                source = "file"
            }
        }
    }

    $result = Invoke-NativeCommand -Command $Command -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    return [pscustomobject]@{
        text = $result.output
        result = $result
    }
}

function Read-TextValueOrCommand {
    param(
        [string]$Value,
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{
            text = $Value.Trim()
            result = [pscustomobject]@{
                command = "provided"
                workingDirectory = $WorkingDirectory
                exitCode = 0
                output = ""
                source = "provided"
            }
        }
    }

    $result = Invoke-NativeCommand -Command $Command -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    return [pscustomobject]@{
        text = $result.output
        result = $result
    }
}

function Convert-DependencyObject {
    param(
        [object]$Object,
        [string]$Section
    )

    if ($null -eq $Object) {
        return @()
    }

    @(
        foreach ($property in @($Object.PSObject.Properties)) {
            [pscustomobject]@{
                name = $property.Name
                version = "$($property.Value)"
                section = $Section
            }
        }
    )
}

function Convert-OutdatedObject {
    param([object]$Object)

    if ($null -eq $Object) {
        return @()
    }

    @(
        foreach ($property in @($Object.PSObject.Properties)) {
            $value = $property.Value
            [pscustomobject]@{
                name = $property.Name
                current = "$($value.current)"
                wanted = "$($value.wanted)"
                latest = "$($value.latest)"
                dependent = "$($value.dependent)"
            }
        }
    )
}

function Convert-InstalledTopLevel {
    param([object]$NpmLs)

    if ($null -eq $NpmLs -or $null -eq $NpmLs.dependencies) {
        return @()
    }

    @(
        foreach ($property in @($NpmLs.dependencies.PSObject.Properties)) {
            [pscustomobject]@{
                name = $property.Name
                version = "$($property.Value.version)"
                resolved = "$($property.Value.resolved)"
            }
        }
    )
}

function Get-FixAvailableDisplay {
    param([object]$FixAvailable)

    if ($null -eq $FixAvailable) {
        return [pscustomobject]@{
            available = $false
            package = ""
            version = ""
            isSemVerMajor = $false
        }
    }

    if ($FixAvailable -is [bool]) {
        return [pscustomobject]@{
            available = [bool]$FixAvailable
            package = ""
            version = ""
            isSemVerMajor = $false
        }
    }

    [pscustomobject]@{
        available = $true
        package = "$($FixAvailable.name)"
        version = "$($FixAvailable.version)"
        isSemVerMajor = [bool]$FixAvailable.isSemVerMajor
    }
}

function Convert-AuditObject {
    param([object]$Audit)

    if ($null -eq $Audit -or $null -eq $Audit.vulnerabilities) {
        return @()
    }

    @(
        foreach ($property in @($Audit.vulnerabilities.PSObject.Properties)) {
            $value = $property.Value
            $fix = Get-FixAvailableDisplay -FixAvailable $value.fixAvailable
            $viaItems = @(
                foreach ($via in @($value.via)) {
                    if ($via -is [string]) {
                        $via
                    } else {
                        "$($via.title) [$($via.severity)] $($via.range)"
                    }
                }
            )

            [pscustomobject]@{
                name = $property.Name
                severity = "$($value.severity)"
                isDirect = [bool]$value.isDirect
                range = "$($value.range)"
                fixAvailable = [bool]$fix.available
                fixPackage = "$($fix.package)"
                fixVersion = "$($fix.version)"
                fixIsSemVerMajor = [bool]$fix.isSemVerMajor
                via = $viaItems
            }
        }
    )
}

function Get-SemVerMajor {
    param([string]$Version)

    if ($Version -match "^(\d+)") {
        return [int]$Matches[1]
    }

    return $null
}

function Get-ByName {
    param(
        [object[]]$Items,
        [string]$Name
    )

    @($Items | Where-Object { $_.name -eq $Name } | Select-Object -First 1)[0]
}

function Write-PlanMarkdown {
    param(
        [object]$Plan,
        [string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# codex-account-switch 依赖更新 DRY-RUN 计划")
    $lines.Add("")
    $lines.Add("生成时间：$($Plan.generatedAt)")
    $lines.Add("")
    $lines.Add('> DRY-RUN：本计划只读取目标项目状态并生成候选方案，不执行依赖更新、不修改 `package.json` / `package-lock.json`、不重建或删除 `node_modules`。')
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add(('- 目标项目：`{0}`' -f $Plan.targetProject.path))
    $lines.Add(('- 项目版本：`{0}@{1}`' -f $Plan.package.name, $Plan.package.version))
    $lines.Add(('- 当前 Node：`{0}`' -f $Plan.runtime.nodeVersion))
    $lines.Add(('- 当前 npm：`{0}`' -f $Plan.runtime.npmVersion))
    $lines.Add(('- npm cache：`{0}`' -f $Plan.runtime.npmCache))
    $lines.Add("- 目标项目 dirty：$(if ($Plan.projectState.isClean) { "否" } else { "是" })")
    $lines.Add("- 执行允许：否")
    $lines.Add("")
    $lines.Add("## 当前事实")
    $lines.Add("")
    $lines.Add(('- `package-lock.json` lockfileVersion：`{0}`' -f $Plan.package.lockfileVersion))
    $lines.Add(('- `package-lock.json` package entries：`{0}`' -f $Plan.package.lockPackageEntries))
    $lines.Add("- 项目根 reparse point：$(if ($Plan.targetProject.projectRootIsReparsePoint) { "是" } else { "否" })")
    $lines.Add(('- `node_modules` reparse point：{0}' -f $(if ($Plan.targetProject.nodeModulesIsReparsePoint) { "是" } else { "否" })))
    $lines.Add("")
    $lines.Add("### 顶层依赖")
    $lines.Add("")
    $lines.Add("| 名称 | 类型 | package.json 版本 | 当前安装版本 | latest |")
    $lines.Add("| --- | --- | --- | --- | --- |")
    foreach ($dep in $Plan.package.declaredDependencies) {
        $installed = Get-ByName -Items $Plan.package.installedTopLevel -Name $dep.name
        $outdated = Get-ByName -Items $Plan.npmState.outdated -Name $dep.name
        $lines.Add("| $(Escape-MarkdownCell $dep.name) | $(Escape-MarkdownCell $dep.section) | $(Escape-MarkdownCell $dep.version) | $(Escape-MarkdownCell $installed.version) | $(Escape-MarkdownCell $outdated.latest) |")
    }
    $lines.Add("")
    $lines.Add("### npm audit")
    $lines.Add("")
    $lines.Add("| 包 | 严重级别 | 直接依赖 | 范围 | fixAvailable | fix 版本 |")
    $lines.Add("| --- | --- | --- | --- | --- | --- |")
    foreach ($vuln in $Plan.npmState.vulnerabilities) {
        $lines.Add("| $(Escape-MarkdownCell $vuln.name) | $(Escape-MarkdownCell $vuln.severity) | $(Escape-MarkdownCell $vuln.isDirect) | $(Escape-MarkdownCell $vuln.range) | $(Escape-MarkdownCell $vuln.fixAvailable) | $(Escape-MarkdownCell $vuln.fixVersion) |")
    }
    $lines.Add("")
    $lines.Add("## 建议")
    $lines.Add("")
    $lines.Add("- 更新策略：$($Plan.recommendation.strategy)")
    $lines.Add(('- 当前状态：`{0}`' -f $Plan.recommendation.status))
    foreach ($reason in $Plan.recommendation.reasons) {
        $lines.Add("- $reason")
    }
    $lines.Add("")
    $lines.Add("### 候选命令预览")
    $lines.Add("")
    foreach ($command in $Plan.recommendation.candidateCommands) {
        $lines.Add(('- `{0}`' -f $command))
    }
    $lines.Add("")
    $lines.Add("### 暂不执行的动作")
    $lines.Add("")
    foreach ($item in $Plan.recommendation.deferReasons) {
        $lines.Add("- $item")
    }
    $lines.Add("")
    $lines.Add("## 执行前 gate")
    $lines.Add("")
    foreach ($gate in $Plan.recommendation.humanGates) {
        $lines.Add("- $gate")
    }
    $lines.Add("")
    $lines.Add("## 验证命令预览")
    $lines.Add("")
    foreach ($command in $Plan.recommendation.validationCommands) {
        $lines.Add(('- `{0}`' -f $command))
    }
    $lines.Add("")
    $lines.Add("## 回滚边界")
    $lines.Add("")
    foreach ($step in $Plan.recommendation.rollbackBoundaries) {
        $lines.Add("- $step")
    }
    $lines.Add("")
    $lines.Add("## 策略")
    $lines.Add("")
    foreach ($rule in $Plan.policy.rules) {
        $lines.Add("- $rule")
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

Assert-DDrivePath -Path $ProjectPath -ParameterName "ProjectPath"
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "ProjectPath 不存在：$ProjectPath"
}

Assert-DDrivePath -Path $OutputDir -ParameterName "OutputDir"
Assert-AllowedOutputDir -Path $OutputDir

$packageJsonPath = Join-Path $ProjectPath "package.json"
$packageLockPath = Join-Path $ProjectPath "package-lock.json"
Assert-ReadableDFile -Path $packageJsonPath -ParameterName "package.json"
Assert-ReadableDFile -Path $packageLockPath -ParameterName "package-lock.json"

$packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
$packageLock = Get-Content -LiteralPath $packageLockPath -Raw | ConvertFrom-Json -AsHashtable

$nodeVersionResult = Read-TextValueOrCommand -Value $NodeVersion -Command $NodeCommand -Arguments @("--version") -WorkingDirectory $ProjectPath
$npmVersionResult = Read-TextValueOrCommand -Value $NpmVersion -Command $NpmCommand -Arguments @("--version") -WorkingDirectory $ProjectPath
$npmCacheResult = Read-TextValueOrCommand -Value $NpmCache -Command $NpmCommand -Arguments @("config", "get", "cache") -WorkingDirectory $ProjectPath
$gitStatusResult = Read-TextInputOrCommand -Path $GitStatusTextPath -Label "GitStatusTextPath" -Command $GitCommand -Arguments @("status", "--short", "--branch") -WorkingDirectory $ProjectPath
$npmLsResult = Read-JsonInputOrCommand -Path $NpmLsJsonPath -Label "NpmLsJsonPath" -Command $NpmCommand -Arguments @("ls", "--depth=0", "--json") -WorkingDirectory $ProjectPath
$npmOutdatedResult = Read-JsonInputOrCommand -Path $NpmOutdatedJsonPath -Label "NpmOutdatedJsonPath" -Command $NpmCommand -Arguments @("outdated", "--json", "--depth=0") -WorkingDirectory $ProjectPath
$npmAuditResult = Read-JsonInputOrCommand -Path $NpmAuditJsonPath -Label "NpmAuditJsonPath" -Command $NpmCommand -Arguments @("audit", "--json") -WorkingDirectory $ProjectPath

$declaredDependencies = @(
    Convert-DependencyObject -Object $packageJson.dependencies -Section "dependencies"
    Convert-DependencyObject -Object $packageJson.devDependencies -Section "devDependencies"
)
$installedTopLevel = @(Convert-InstalledTopLevel -NpmLs $npmLsResult.data)
$outdatedItems = @(Convert-OutdatedObject -Object $npmOutdatedResult.data)
$vulnerabilities = @(Convert-AuditObject -Audit $npmAuditResult.data)

$statusLines = @($gitStatusResult.text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$dirtyLines = @($statusLines | Where-Object { -not $_.StartsWith("##") })
$branchLine = @($statusLines | Where-Object { $_.StartsWith("##") } | Select-Object -First 1)[0]
$isClean = $dirtyLines.Count -eq 0

$viteAudit = Get-ByName -Items $vulnerabilities -Name "vite"
$viteOutdated = Get-ByName -Items $outdatedItems -Name "vite"
$typescriptOutdated = Get-ByName -Items $outdatedItems -Name "typescript"
$viteDeclared = Get-ByName -Items $declaredDependencies -Name "vite"
$typescriptDeclared = Get-ByName -Items $declaredDependencies -Name "typescript"

$viteFixVersion = ""
if ($null -ne $viteAudit -and -not [string]::IsNullOrWhiteSpace($viteAudit.fixVersion)) {
    $viteFixVersion = $viteAudit.fixVersion
}

$hasVulnerabilities = $vulnerabilities.Count -gt 0

$candidateCommands = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($viteFixVersion)) {
    $candidateCommands.Add("npm install vite@$viteFixVersion --save-dev --package-lock-only --ignore-scripts")
    $candidateCommands.Add("git diff -- package.json package-lock.json")
} elseif (-not $hasVulnerabilities) {
    $candidateCommands.Add("无自动候选命令。当前 npm audit 未发现漏洞。")
} else {
    $candidateCommands.Add("无自动候选命令。当前 npm audit 未返回可用的 vite 安全补丁版本。")
}

$reasons = New-Object System.Collections.Generic.List[string]
if (-not $hasVulnerabilities) {
    $reasons.Add("当前 npm audit 未发现漏洞，安全补丁候选已经不需要继续执行。")
} else {
    $reasons.Add("当前建议只做安全补丁 dry-run，优先处理 npm audit 指向的 Vite 漏洞。")
}
if (-not $isClean) {
    $reasons.Add("目标项目当前 dirty，真实更新必须阻塞，避免覆盖或混入既有改动。")
} else {
    $reasons.Add("目标项目当前 git status clean；真实执行前仍必须重新检查 dirty 状态。")
}
if (-not [string]::IsNullOrWhiteSpace($viteFixVersion)) {
    $reasons.Add("npm audit 当前给出的 Vite 修复版本是 $viteFixVersion，属于本次 dry-run 的首选候选。")
}

$deferReasons = New-Object System.Collections.Generic.List[string]
$deferReasons.Add('不执行 `npm ci` 作为更新手段：它只会按当前 lockfile 重建旧依赖，不能让依赖保持最新。')
if ($null -ne $viteOutdated -and -not [string]::IsNullOrWhiteSpace($viteOutdated.latest)) {
    $deferReasons.Add(('暂不直接跳到 `vite {0}`：当前项目声明为 `vite {1}`，latest 是潜在大版本升级，应单独评估构建和 Tauri 开发服务器兼容性。' -f $viteOutdated.latest, $viteDeclared.version))
}
if ($null -ne $typescriptOutdated -and -not [string]::IsNullOrWhiteSpace($typescriptOutdated.latest)) {
    $deferReasons.Add(('暂不直接跳到 `typescript {0}`：当前项目声明为 `typescript {1}`，latest 是潜在大版本升级，应单独评估类型检查变化。' -f $typescriptOutdated.latest, $typescriptDeclared.version))
}
$deferReasons.Add('暂不合并 Tauri minor 更新：`@tauri-apps/api` 和 `@tauri-apps/cli` 可后续独立评估，避免把安全补丁和框架更新混在一次变更里。')
$deferReasons.Add('不删除、不重建现有 `node_modules`；真实更新前先只改锁文件和声明文件，再通过项目验证确认。')

$humanGates = @(
    "用户明确授权真实依赖更新范围，且确认目标项目当前不是 dirty。",
    '真实执行前重新运行 `git status --short --branch`、`npm outdated --json --depth=0` 和 `npm audit --json`。',
    '先审查 `package.json` / `package-lock.json` diff，再决定是否重建 `node_modules`。',
    "若目标项目出现未提交业务改动，必须先由 owner 决定保留、提交或搁置这些改动。"
)

$validationCommands = @(
    "npm ls --depth=0",
    "npm audit",
    "npm run version:check",
    "npm run build",
    "npm run check:rust:windows"
)

$rollbackBoundaries = @(
    '回滚只恢复 `package.json` 和 `package-lock.json` 到更新前版本。',
    '不得删除现有 `node_modules` 作为回滚手段。',
    "如果后续真实执行曾重建依赖，先用 git diff 和 npm 验证确认影响，再按目标项目自己的流程恢复。",
    "本 dry-run 不生成可直接 apply 的删除、迁移或重装步骤。"
)

$lockPackageEntries = 0
if ($packageLock.ContainsKey("packages") -and $null -ne $packageLock["packages"]) {
    $lockPackageEntries = $packageLock["packages"].Count
}

$status = if (-not $isClean) { "blocked-target-dirty" } elseif (-not $hasVulnerabilities) { "no-action-required" } elseif ([string]::IsNullOrWhiteSpace($viteFixVersion)) { "needs-manual-review" } else { "ready-for-owner-review" }
$strategy = if (-not $hasVulnerabilities) { "当前安全补丁已满足；后续只单独评估大版本或框架 minor 更新。" } else { "安全补丁优先；先处理 Vite audit fix，再单独评估大版本或框架 minor 更新。" }

$plan = [pscustomobject]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    dryRun = $true
    readOnly = $true
    targetProject = [pscustomobject]@{
        path = [System.IO.Path]::GetFullPath($ProjectPath)
        packageJsonPath = $packageJsonPath
        packageLockPath = $packageLockPath
        projectRootIsReparsePoint = Test-ReparsePoint -Path $ProjectPath
        nodeModulesPath = (Join-Path $ProjectPath "node_modules")
        nodeModulesIsReparsePoint = Test-ReparsePoint -Path (Join-Path $ProjectPath "node_modules")
    }
    runtime = [pscustomobject]@{
        nodeVersion = $nodeVersionResult.text
        npmVersion = $npmVersionResult.text
        npmCache = $npmCacheResult.text
    }
    package = [pscustomobject]@{
        name = "$($packageJson.name)"
        version = "$($packageJson.version)"
        lockfileVersion = "$($packageLock["lockfileVersion"])"
        lockPackageEntries = $lockPackageEntries
        declaredDependencies = $declaredDependencies
        installedTopLevel = $installedTopLevel
    }
    projectState = [pscustomobject]@{
        branchLine = "$branchLine"
        isClean = $isClean
        dirtyEntries = $dirtyLines
        statusLines = $statusLines
    }
    npmState = [pscustomobject]@{
        outdated = $outdatedItems
        vulnerabilities = $vulnerabilities
        auditSummary = $npmAuditResult.data.metadata.vulnerabilities
        commandResults = [pscustomobject]@{
            nodeVersion = $nodeVersionResult.result
            npmVersion = $npmVersionResult.result
            npmCache = $npmCacheResult.result
            gitStatus = $gitStatusResult.result
            npmLs = $npmLsResult.result
            npmOutdated = $npmOutdatedResult.result
            npmAudit = $npmAuditResult.result
        }
    }
    recommendation = [pscustomobject]@{
        strategy = $strategy
        status = $status
        blockedByDirtyWorktree = -not $isClean
        primaryCandidate = [pscustomobject]@{
            package = "vite"
            current = "$($viteDeclared.version)"
            auditFixVersion = "$viteFixVersion"
            latest = "$($viteOutdated.latest)"
            currentMajor = Get-SemVerMajor -Version "$($viteDeclared.version)"
            latestMajor = Get-SemVerMajor -Version "$($viteOutdated.latest)"
        }
        reasons = $reasons
        candidateCommands = $candidateCommands
        deferReasons = $deferReasons
        humanGates = $humanGates
        validationCommands = $validationCommands
        rollbackBoundaries = $rollbackBoundaries
    }
    policy = [pscustomobject]@{
        executionAllowed = $false
        deleteAllowed = $false
        migrationAllowed = $false
        targetProjectWriteAllowed = $false
        rules = @(
            "本计划只读查询目标项目状态，不执行 npm install、npm ci、npm audit fix 或依赖更新。",
            "候选命令只是后续真实授权 issue 的预览，不代表当前可以执行。",
            "真实更新前必须重新确认目标项目 dirty 状态和 npm audit 输出。",
            "输出只能位于 D 盘允许报告目录。",
            "回滚边界限定在 package.json 和 package-lock.json；不得删除现有 node_modules。"
        )
    }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$jsonPath = Join-Path $OutputDir "plan.json"
$markdownPath = Join-Path $OutputDir "PLAN.md"
Assert-DDrivePath -Path $jsonPath -ParameterName "plan.json"
Assert-DDrivePath -Path $markdownPath -ParameterName "PLAN.md"

$plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-PlanMarkdown -Plan $plan -Path $markdownPath

[pscustomobject]@{
    planJson = $jsonPath
    planMarkdown = $markdownPath
    dryRun = $true
    readOnly = $true
    executionAllowed = $false
}
