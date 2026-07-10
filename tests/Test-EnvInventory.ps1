param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境",
    [switch]$KeepOutputs
)

$ErrorActionPreference = "Stop"
$WarningPreference = "Stop"

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
    Assert-True -Condition $hasProperty -Message "Missing property: $Name"
}

$scriptPath = Join-Path $ProjectRoot "scripts\Invoke-EnvInventory.ps1"
$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$testRoot = Join-Path $ProjectRoot "reports\env-inventory-test"
$quickOutput = Join-Path $testRoot "quick"
$fullOutput = Join-Path $testRoot "full"
$canonicalPipOutput = Join-Path $testRoot "canonical-pip"

Assert-True -Condition (Test-Path -Path $scriptPath -PathType Leaf) -Message "Inventory script not found: $scriptPath"
Assert-True -Condition (Test-Path -LiteralPath $publisherPath -PathType Leaf) -Message "Report publisher not found: $publisherPath"
. $publisherPath

if (Test-Path -Path $testRoot) {
    Remove-Item -Path $testRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $quickOutput | Out-Null
New-Item -ItemType Directory -Force -Path $fullOutput | Out-Null
New-Item -ItemType Directory -Force -Path $canonicalPipOutput | Out-Null

$quickResult = & $scriptPath -OutputDir $quickOutput -SkipVersionProbe
Assert-True -Condition ([bool]$quickResult.readOnly) -Message "Quick run did not report readOnly=true"

$quickJsonPath = Join-Path $quickOutput "inventory.json"
$quickReportPath = Join-Path $quickOutput "REPORT.md"
Assert-True -Condition (Test-Path -Path $quickJsonPath -PathType Leaf) -Message "Quick inventory.json missing"
Assert-True -Condition (Test-Path -Path $quickReportPath -PathType Leaf) -Message "Quick REPORT.md missing"

$quickInventory = Get-Content -Path $quickJsonPath -Raw | ConvertFrom-Json
foreach ($property in @("artifactType", "schemaVersion", "executionAllowed", "generationId", "readOnly", "tools", "directories", "pathScopes", "pathEntries", "toolOwnerRoots", "migrationCandidates", "manualReviewItems", "excludedRoots", "projectEnvironmentMarkers", "localEnvironmentFindings")) {
    Assert-Property -Object $quickInventory -Name $property
}

Assert-True -Condition ($quickInventory.artifactType -eq "env-governance.inventory") -Message "Quick inventory artifactType 错误"
Assert-True -Condition ($quickInventory.schemaVersion -eq 3) -Message "Quick inventory schemaVersion 必须为 3"
Assert-True -Condition (-not [bool]$quickInventory.executionAllowed) -Message "Quick inventory 不得授权执行"
Assert-True -Condition ([bool]$quickInventory.readOnly) -Message "Quick inventory readOnly was not true"
Assert-True -Condition ([bool]$quickInventory.skipVersionProbe) -Message "Quick inventory did not record skipVersionProbe=true"
Assert-True -Condition ($quickInventory.tools.Count -gt 0) -Message "Quick inventory has no tools"
Assert-True -Condition (@($quickInventory.toolOwnerRoots | Where-Object { $_ -ieq "D:\hermes-data\hermes-agent" }).Count -eq 1) -Message "默认显式 tool owner roots 必须包含 Hermes owner 根"
$quickPair = Test-JsonMarkdownArtifactPair -JsonPath $quickJsonPath -MarkdownPath $quickReportPath
Assert-True -Condition ([bool]$quickPair.ok) -Message "Quick JSON/Markdown pair 校验失败: $($quickPair.error)"

foreach ($scopeName in @("process", "user", "machine")) {
    Assert-Property -Object $quickInventory.pathScopes -Name $scopeName
    $scopeRecord = $quickInventory.pathScopes.$scopeName
    foreach ($property in @("readStatus", "complete", "errors", "rawValueSha256", "entries", "duplicates", "missingPathCleanupCandidates")) {
        Assert-Property -Object $scopeRecord -Name $property
    }
    Assert-True -Condition ($scopeRecord.source -eq $scopeName) -Message "$scopeName PATH scope 不得与其他 scope 串联"
    if (-not [bool]$scopeRecord.complete) {
        Assert-True -Condition (@($scopeRecord.missingPathCleanupCandidates).Count -eq 0) -Message "$scopeName PATH scope 不完整时不得生成 cleanup 建议"
    }
}

$processEntries = @($quickInventory.pathScopes.process.entries)
Assert-True -Condition ($quickInventory.pathEntries.Count -eq $processEntries.Count) -Message "兼容 pathEntries 必须投影 process PATH"
for ($index = 0; $index -lt $processEntries.Count; $index++) {
    $compatEntry = $quickInventory.pathEntries[$index]
    Assert-True -Condition ((@($compatEntry.PSObject.Properties.Name) -join ",") -ceq "index,path,exists,drive") -Message "兼容 pathEntries 只能包含四个旧字段"
    Assert-True -Condition ($compatEntry.path -ceq $processEntries[$index].expandedPath) -Message "兼容 pathEntries.path 必须投影 expandedPath"
}
Assert-True -Condition (@($quickInventory.selectedEnvironmentVariables | Where-Object { $_.name -eq "Path" }).Count -eq 0) -Message "selectedEnvironmentVariables 不得输出完整 Path"
foreach ($tool in $quickInventory.tools) {
    foreach ($property in @("launcher", "runtime", "originClass", "originEvidence", "resolutionScope", "requiresManualReview")) {
        Assert-Property -Object $tool -Name $property
    }
    Assert-True -Condition ($tool.resolutionScope -eq "process") -Message "$($tool.name) resolutionScope 必须为 process"
    Assert-Property -Object $tool.launcher -Name "metadataStatus"
    if ($null -ne $tool.runtime) {
        Assert-Property -Object $tool.runtime -Name "metadataStatus"
    }
}

$quickReport = Get-Content -Path $quickReportPath -Raw
foreach ($expected in @("本报告由只读盘点脚本生成", "工具解析作用域：process", "## 绝不自动迁移", "## 迁移候选", "## 人工审查项")) {
    Assert-True -Condition $quickReport.Contains($expected) -Message "Quick report missing expected text: $expected"
}
foreach ($expected in @("Launcher originClass", "Launcher matchedRule", "Launcher matchedRoot", "Launcher reparse", "Runtime originClass", "Runtime matchedRule", "Runtime matchedRoot", "Runtime reparse")) {
    Assert-True -Condition $quickReport.Contains($expected) -Message "Quick report missing tool audit column: $expected"
}
foreach ($expected in @("## 本地环境分类发现")) {
    Assert-True -Condition $quickReport.Contains($expected) -Message "Quick report missing local env classification text: $expected"
}
foreach ($scopeName in @("process", "user", "machine")) {
    foreach ($expected in @("### PATH scope: $scopeName", "readStatus", "complete", "errors", "rawPath", "expandedPath", "expansionStatus")) {
        Assert-True -Condition $quickReport.Contains($expected) -Message "Quick report missing $scopeName PATH detail: $expected"
    }
}

$quickFindings = @($quickInventory.localEnvironmentFindings)
$quickProjectMarkers = @($quickInventory.projectEnvironmentMarkers)
foreach ($classification in @($quickFindings | ForEach-Object { $_.classification } | Sort-Object -Unique)) {
    Assert-True -Condition $quickReport.Contains($classification) -Message "Quick report missing discovered local env classification: $classification"
}
Assert-True -Condition ($quickFindings.Count -ge $quickProjectMarkers.Count) -Message "localEnvironmentFindings 不应少于 projectEnvironmentMarkers"
foreach ($marker in $quickProjectMarkers) {
    Assert-True -Condition ([bool]$marker.includeInReviewPack) -Message "projectEnvironmentMarkers 只能包含纳入项目级审查的项：$($marker.path)"
    Assert-True -Condition (@("project-root-local-env", "nested-app-local-env") -contains $marker.classification) -Message "projectEnvironmentMarkers 不应包含缓存或归档分类：$($marker.path)"
}

$nestedAppMarker = $quickProjectMarkers | Where-Object { $_.classification -eq "nested-app-local-env" -and $_.marker -eq "node_modules" } | Select-Object -First 1
if ($nestedAppMarker) {
    $nestedApp = $quickFindings | Where-Object { $_.path -ieq $nestedAppMarker.path } | Select-Object -First 1
    Assert-True -Condition ($null -ne $nestedApp) -Message "递归扫描应发现嵌套 app node_modules：$($nestedAppMarker.path)"
    Assert-True -Condition ($nestedApp.classification -eq "nested-app-local-env") -Message "嵌套 app node_modules 分类错误"
    Assert-True -Condition ([bool]$nestedApp.includeInReviewPack) -Message "嵌套 app node_modules 应纳入项目级审查"
}

$pluginCachePath = "D:\Codex\projects\yangyangzi-direct-qqbot\data\codex_home_yangyangzi\plugins\cache\openai-bundled\browser\26.616.51431\scripts\node_modules"
if (Test-Path -LiteralPath $pluginCachePath -PathType Container) {
    $pluginCache = $quickFindings | Where-Object { $_.path -ieq $pluginCachePath } | Select-Object -First 1
    Assert-True -Condition ($null -ne $pluginCache) -Message "递归扫描应发现插件 runtime cache node_modules：$pluginCachePath"
    Assert-True -Condition ($pluginCache.classification -eq "plugin-runtime-cache") -Message "插件 runtime cache 分类错误"
    Assert-True -Condition (-not [bool]$pluginCache.includeInReviewPack) -Message "插件 runtime cache 不应纳入项目级重建审查"
}

$repairBackupPath = "D:\Codex\projects\yangyangzi-direct-qqbot\data\repair_backups\plugin-cache-20260610-123718\openai-bundled\chrome\26.602.71036\scripts\node_modules"
if (Test-Path -LiteralPath $repairBackupPath -PathType Container) {
    $repairBackup = $quickFindings | Where-Object { $_.path -ieq $repairBackupPath } | Select-Object -First 1
    Assert-True -Condition ($null -ne $repairBackup) -Message "递归扫描应发现 repair backup node_modules：$repairBackupPath"
    Assert-True -Condition ($repairBackup.classification -eq "plugin-cache-backup") -Message "repair backup 分类错误"
    Assert-True -Condition (-not [bool]$repairBackup.includeInReviewPack) -Message "repair backup 不应纳入项目级重建审查"
}

$archiveCachePath = "D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase6-skills\source-skills\shared-skill\node_modules"
if (Test-Path -LiteralPath $archiveCachePath -PathType Container) {
    $archiveCache = $quickFindings | Where-Object { $_.path -ieq $archiveCachePath } | Select-Object -First 1
    Assert-True -Condition ($null -ne $archiveCache) -Message "递归扫描应发现归档缓存 node_modules：$archiveCachePath"
    Assert-True -Condition ($archiveCache.classification -eq "archived-project-cache") -Message "归档缓存分类错误"
    Assert-True -Condition (-not [bool]$archiveCache.includeInReviewPack) -Message "归档缓存不应纳入项目级重建审查"
}

$fullResult = & $scriptPath -OutputDir $fullOutput
Assert-True -Condition ([bool]$fullResult.readOnly) -Message "Full run did not report readOnly=true"

$fullJsonPath = Join-Path $fullOutput "inventory.json"
$fullReportPath = Join-Path $fullOutput "REPORT.md"
Assert-True -Condition (Test-Path -Path $fullJsonPath -PathType Leaf) -Message "Full inventory.json missing"
Assert-True -Condition (Test-Path -Path $fullReportPath -PathType Leaf) -Message "Full REPORT.md missing"

$fullInventory = Get-Content -Path $fullJsonPath -Raw | ConvertFrom-Json
Assert-True -Condition ($fullInventory.schemaVersion -eq 3) -Message "Full inventory schemaVersion 必须为 3"
Assert-True -Condition ([bool]$fullInventory.readOnly) -Message "Full inventory readOnly was not true"
Assert-True -Condition (-not [bool]$fullInventory.skipVersionProbe) -Message "Full inventory recorded skipVersionProbe=true"
$fullPair = Test-JsonMarkdownArtifactPair -JsonPath $fullJsonPath -MarkdownPath $fullReportPath
Assert-True -Condition ([bool]$fullPair.ok) -Message "Full JSON/Markdown pair 校验失败: $($fullPair.error)"

foreach ($tool in $fullInventory.tools | Where-Object { $_.found }) {
    Assert-Property -Object $tool -Name "probeSucceeded"
    Assert-Property -Object $tool -Name "evidence"
    Assert-Property -Object $tool -Name "error"

    if (-not [bool]$tool.probeSucceeded) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($tool.error)) -Message "$($tool.name) failed without error evidence"
        Assert-True -Condition ([string]::IsNullOrWhiteSpace($tool.version)) -Message "$($tool.name) failure was recorded as a version"
    }
}

$riskOrigins = @("vendor-runtime", "system-installer", "windows-system", "user-profile", "project-local-env", "unknown")
foreach ($tool in $fullInventory.tools) {
    $roleOrigins = @($tool.launcher.originClass)
    if ($null -ne $tool.runtime) {
        $roleOrigins += $tool.runtime.originClass
    }
    $hasRiskOrigin = @($roleOrigins | Where-Object { $riskOrigins -contains $_ }).Count -gt 0
    $hasReparse = [bool]$tool.launcher.isReparsePoint -or ($null -ne $tool.runtime -and [bool]$tool.runtime.isReparsePoint)
    if ($hasRiskOrigin -or $hasReparse) {
        Assert-True -Condition ([bool]$tool.requiresManualReview) -Message "$($tool.name) launcher/runtime 风险未聚合到人工审查门"
    }
}

$gitProbe = $fullInventory.tools | Where-Object { $_.name -eq "git" } | Select-Object -First 1
if ($gitProbe -and $gitProbe.found) {
    Assert-True -Condition ($gitProbe.version -like "git version*") -Message "git version probe did not receive --version"
}

$pythonProbe = $fullInventory.tools | Where-Object { $_.name -eq "python" } | Select-Object -First 1
if ($pythonProbe -and $pythonProbe.found) {
    Assert-True -Condition ($pythonProbe.version -like "Python *") -Message "python version probe did not receive --version"
    foreach ($property in @("launcher", "runtime", "originClass", "originEvidence", "resolutionScope", "requiresManualReview")) {
        Assert-Property -Object $pythonProbe -Name $property
    }
    $pythonRolesTrustedShared = $pythonProbe.launcher.originClass -eq "shared-tool" -and
        $null -ne $pythonProbe.runtime -and
        $pythonProbe.runtime.originClass -eq "shared-tool" -and
        $pythonProbe.launcher.metadataStatus -eq "ok" -and
        $pythonProbe.runtime.metadataStatus -eq "ok" -and
        -not [bool]$pythonProbe.launcher.isReparsePoint -and
        -not [bool]$pythonProbe.runtime.isReparsePoint
    if ($pythonProbe.originClass -eq "shared-tool" -and $pythonRolesTrustedShared) {
        Assert-True -Condition (-not [bool]$pythonProbe.requiresManualReview) -Message "launcher/runtime 都是可信 shared 且无 reparse 时才可免人工审查"
    } elseif ($pythonProbe.originClass -eq "shared-tool") {
        Assert-True -Condition ([bool]$pythonProbe.requiresManualReview) -Message "最终 shared-tool 不能覆盖 launcher/runtime 风险证据"
    } else {
        Assert-True -Condition ([bool]$pythonProbe.requiresManualReview) -Message "非 shared-tool Python 归属必须人工审查"
    }
    if ($pythonProbe.launcher.path -ieq "D:\hermes-data\.npm-global\python.exe") {
        Assert-True -Condition ($pythonProbe.runtime.path -like "D:\hermes-data\hermes-agent\*") -Message "Hermes launcher 存在时应探测到 Hermes 项目 runtime"
        Assert-True -Condition ($pythonProbe.runtime.originClass -eq "project-local-env") -Message "Hermes runtime 必须分类为 project-local-env"
        Assert-True -Condition ($pythonProbe.originClass -eq "project-local-env") -Message "Hermes Python 最终归属必须为 project-local-env"
        Assert-True -Condition ([bool]$pythonProbe.requiresManualReview) -Message "Hermes project-local Python 必须人工审查"
    }
}

$blockedOutput = "C:\Codex-should-not-be-created"
$blocked = $false
try {
    & $scriptPath -OutputDir $blockedOutput -SkipVersionProbe | Out-Null
} catch {
    $blocked = $_.Exception.Message -like "*必须位于 D:\*"
}
Assert-True -Condition $blocked -Message "Inventory 脚本没有阻止 C 盘 OutputDir"
Assert-True -Condition (-not (Test-Path -Path $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

$reparseTarget = Join-Path $testRoot "reparse-target"
$reparseOutput = Join-Path $testRoot "reparse-output"
New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
New-Item -ItemType Junction -Path $reparseOutput -Target $reparseTarget | Out-Null
try {
    $reparseBlocked = $false
    try {
        & $scriptPath -OutputDir $reparseOutput -SkipVersionProbe | Out-Null
    } catch {
        $reparseBlocked = $_.Exception.Message -like "*reparse point*"
    }
    Assert-True -Condition $reparseBlocked -Message "Inventory 脚本没有阻止 reparse OutputDir"
} finally {
    Remove-Item -LiteralPath $reparseOutput -Force
}

$previousProcessPipCache = $env:PIP_CACHE_DIR
try {
    $env:PIP_CACHE_DIR = "D:\Codex\.cache\pip"
    & $scriptPath -OutputDir $canonicalPipOutput -SkipVersionProbe | Out-Null
    $canonicalInventory = Get-Content -Path (Join-Path $canonicalPipOutput "inventory.json") -Raw | ConvertFrom-Json
    $pipDefaultPath = Join-Path $env:LOCALAPPDATA "pip\Cache"
    $pipDefaultCandidate = @($canonicalInventory.migrationCandidates | Where-Object { $_.source -eq $pipDefaultPath })
    Assert-True -Condition ($pipDefaultCandidate.Count -eq 0) -Message "PIP_CACHE_DIR 指向 canonical D 盘缓存后，不应继续把旧默认 pip cache 作为迁移候选"
} finally {
    $env:PIP_CACHE_DIR = $previousProcessPipCache
}

if (-not $KeepOutputs) {
    Remove-Item -Path $testRoot -Recurse -Force
}

[pscustomobject]@{
    ok = $true
    quickInventory = $quickJsonPath
    fullInventory = $fullJsonPath
}
