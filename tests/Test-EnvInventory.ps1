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
    Assert-True -Condition $hasProperty -Message "Missing property: $Name"
}

$scriptPath = Join-Path $ProjectRoot "scripts\Invoke-EnvInventory.ps1"
$testRoot = Join-Path $ProjectRoot "reports\env-inventory-test"
$quickOutput = Join-Path $testRoot "quick"
$fullOutput = Join-Path $testRoot "full"
$canonicalPipOutput = Join-Path $testRoot "canonical-pip"

Assert-True -Condition (Test-Path -Path $scriptPath -PathType Leaf) -Message "Inventory script not found: $scriptPath"

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
foreach ($property in @("readOnly", "tools", "directories", "pathEntries", "migrationCandidates", "manualReviewItems", "excludedRoots", "projectEnvironmentMarkers", "localEnvironmentFindings")) {
    Assert-Property -Object $quickInventory -Name $property
}

Assert-True -Condition ([bool]$quickInventory.readOnly) -Message "Quick inventory readOnly was not true"
Assert-True -Condition ([bool]$quickInventory.skipVersionProbe) -Message "Quick inventory did not record skipVersionProbe=true"
Assert-True -Condition ($quickInventory.tools.Count -gt 0) -Message "Quick inventory has no tools"

$quickReport = Get-Content -Path $quickReportPath -Raw
foreach ($expected in @("本报告由只读盘点脚本生成", "## 绝不自动迁移", "## 迁移候选", "## 人工审查项")) {
    Assert-True -Condition $quickReport.Contains($expected) -Message "Quick report missing expected text: $expected"
}
foreach ($expected in @("## 本地环境分类发现", "project-root-local-env")) {
    Assert-True -Condition $quickReport.Contains($expected) -Message "Quick report missing local env classification text: $expected"
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

$nestedAppPath = "D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager\node_modules"
if (Test-Path -LiteralPath $nestedAppPath -PathType Container) {
    $nestedApp = $quickFindings | Where-Object { $_.path -ieq $nestedAppPath } | Select-Object -First 1
    Assert-True -Condition ($null -ne $nestedApp) -Message "递归扫描应发现嵌套 app node_modules：$nestedAppPath"
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
Assert-True -Condition ([bool]$fullInventory.readOnly) -Message "Full inventory readOnly was not true"
Assert-True -Condition (-not [bool]$fullInventory.skipVersionProbe) -Message "Full inventory recorded skipVersionProbe=true"

foreach ($tool in $fullInventory.tools | Where-Object { $_.found }) {
    Assert-Property -Object $tool -Name "probeSucceeded"
    Assert-Property -Object $tool -Name "evidence"
    Assert-Property -Object $tool -Name "error"

    if (-not [bool]$tool.probeSucceeded) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($tool.error)) -Message "$($tool.name) failed without error evidence"
        Assert-True -Condition ([string]::IsNullOrWhiteSpace($tool.version)) -Message "$($tool.name) failure was recorded as a version"
    }
}

$gitProbe = $fullInventory.tools | Where-Object { $_.name -eq "git" } | Select-Object -First 1
if ($gitProbe -and $gitProbe.found) {
    Assert-True -Condition ($gitProbe.version -like "git version*") -Message "git version probe did not receive --version"
}

$pythonProbe = $fullInventory.tools | Where-Object { $_.name -eq "python" } | Select-Object -First 1
if ($pythonProbe -and $pythonProbe.found) {
    Assert-True -Condition ($pythonProbe.version -like "Python *") -Message "python version probe did not receive --version"
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
