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

Assert-True -Condition (Test-Path -Path $scriptPath -PathType Leaf) -Message "Inventory script not found: $scriptPath"

if (Test-Path -Path $testRoot) {
    Remove-Item -Path $testRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $quickOutput | Out-Null
New-Item -ItemType Directory -Force -Path $fullOutput | Out-Null

$quickResult = & $scriptPath -OutputDir $quickOutput -SkipVersionProbe
Assert-True -Condition ([bool]$quickResult.readOnly) -Message "Quick run did not report readOnly=true"

$quickJsonPath = Join-Path $quickOutput "inventory.json"
$quickReportPath = Join-Path $quickOutput "REPORT.md"
Assert-True -Condition (Test-Path -Path $quickJsonPath -PathType Leaf) -Message "Quick inventory.json missing"
Assert-True -Condition (Test-Path -Path $quickReportPath -PathType Leaf) -Message "Quick REPORT.md missing"

$quickInventory = Get-Content -Path $quickJsonPath -Raw | ConvertFrom-Json
foreach ($property in @("readOnly", "tools", "directories", "pathEntries", "migrationCandidates", "manualReviewItems", "excludedRoots")) {
    Assert-Property -Object $quickInventory -Name $property
}

Assert-True -Condition ([bool]$quickInventory.readOnly) -Message "Quick inventory readOnly was not true"
Assert-True -Condition ([bool]$quickInventory.skipVersionProbe) -Message "Quick inventory did not record skipVersionProbe=true"
Assert-True -Condition ($quickInventory.tools.Count -gt 0) -Message "Quick inventory has no tools"

$quickReport = Get-Content -Path $quickReportPath -Raw
foreach ($expected in @("本报告由只读盘点脚本生成", "## 绝不自动迁移", "## 迁移候选", "## 人工审查项")) {
    Assert-True -Condition $quickReport.Contains($expected) -Message "Quick report missing expected text: $expected"
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

if (-not $KeepOutputs) {
    Remove-Item -Path $testRoot -Recurse -Force
}

[pscustomobject]@{
    ok = $true
    quickInventory = $quickJsonPath
    fullInventory = $fullJsonPath
}
