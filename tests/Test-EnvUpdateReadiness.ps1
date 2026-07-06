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
    Assert-True -Condition $hasProperty -Message "缺少属性：$Name"
}

$inventoryScript = Join-Path $ProjectRoot "scripts\Invoke-EnvInventory.ps1"
$readinessScript = Join-Path $ProjectRoot "scripts\New-EnvUpdateReadinessReport.ps1"
$testRoot = Join-Path $ProjectRoot "reports\env-update-readiness-test"
$inventoryOutput = Join-Path $testRoot "inventory"
$readinessOutput = Join-Path $testRoot "readiness"
$fixtureInventoryPath = Join-Path $testRoot "fixture-inventory.json"
$fixtureOutput = Join-Path $testRoot "fixture-readiness"
$junctionTarget = Join-Path $testRoot "junction-target"
$junctionPath = Join-Path $testRoot "junction-link"

Assert-True -Condition (Test-Path -Path $inventoryScript -PathType Leaf) -Message "找不到 inventory 脚本"
Assert-True -Condition (Test-Path -Path $readinessScript -PathType Leaf) -Message "找不到更新准备报告脚本"

try {
    if (Test-Path -Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $inventoryOutput | Out-Null
    New-Item -ItemType Directory -Force -Path $readinessOutput | Out-Null

    & $inventoryScript -OutputDir $inventoryOutput -SkipVersionProbe | Out-Null
    $inventoryPath = Join-Path $inventoryOutput "inventory.json"
    Assert-True -Condition (Test-Path -Path $inventoryPath -PathType Leaf) -Message "测试 inventory 未生成"

    $result = & $readinessScript -InventoryPath $inventoryPath -OutputDir $readinessOutput
    Assert-True -Condition ([bool]$result.readOnly) -Message "更新准备报告脚本没有返回 readOnly=true"

    $jsonPath = Join-Path $readinessOutput "readiness.json"
    $markdownPath = Join-Path $readinessOutput "REPORT.md"
    Assert-True -Condition (Test-Path -Path $jsonPath -PathType Leaf) -Message "缺少 readiness.json"
    Assert-True -Condition (Test-Path -Path $markdownPath -PathType Leaf) -Message "缺少 REPORT.md"

    $readiness = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
    foreach ($property in @("readOnly", "inventoryPath", "toolReadiness", "pathSummary", "highRiskItems", "policy")) {
        Assert-Property -Object $readiness -Name $property
    }
    foreach ($property in @("missingEntries", "staleLocalEnvironmentEntries", "duplicates", "recommendations")) {
        Assert-Property -Object $readiness.pathSummary -Name $property
    }

    Assert-True -Condition ([bool]$readiness.readOnly) -Message "readiness JSON 的 readOnly 不是 true"
    Assert-True -Condition ($readiness.inventoryPath -eq $inventoryPath) -Message "readiness 没有记录 inventory 路径"
    Assert-True -Condition ($readiness.toolReadiness.Count -gt 0) -Message "没有生成工具更新准备项"

    foreach ($entry in $readiness.toolReadiness) {
        foreach ($property in @("name", "path", "pathDisplay", "pathStatus", "locationClass", "recommendedUpdateEntry", "recommendedAction", "autoUpdateAllowed", "riskLevel")) {
            Assert-Property -Object $entry -Name $property
        }

        Assert-True -Condition (-not [bool]$entry.autoUpdateAllowed) -Message "$($entry.name) 不应允许自动更新"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($entry.pathDisplay)) -Message "$($entry.name) 缺少当前入口展示文本"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($entry.recommendedAction)) -Message "$($entry.name) 缺少建议动作"
    }

    $markdown = Get-Content -Path $markdownPath -Raw
    foreach ($expected in @("只读", "不会执行", "工具更新准备", "当前入口", "PATH 整理建议", "D 盘 PATH 入口", "PATH 缺失入口", "缺失 PATH 入口", "高风险对象", "不自动更新")) {
        Assert-True -Condition $markdown.Contains($expected) -Message "REPORT.md 缺少预期文本：$expected"
    }

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $readinessScript -InventoryPath $inventoryPath -OutputDir $blockedOutput | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "更新准备报告脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -Path $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    $junctionBlocked = $false
    try {
        & $readinessScript -InventoryPath $inventoryPath -OutputDir (Join-Path $junctionPath "readiness") | Out-Null
    } catch {
        $junctionBlocked = $_.Exception.Message -like "*不能穿过 junction*"
    }
    Assert-True -Condition $junctionBlocked -Message "更新准备报告脚本没有阻止穿过 junction 的 OutputDir"
    Assert-True -Condition (-not (Test-Path -Path (Join-Path $junctionTarget "readiness\readiness.json"))) -Message "测试不应通过 junction 写入目标目录"

    $fixtureInventory = [pscustomobject]@{
        generatedAt = (Get-Date).ToString("o")
        tools = @(
            [pscustomobject]@{
                name = "fixture-resolved"
                found = $true
                path = "D:\Codex\tools\fixture\tool.exe"
                version = ""
                probeSucceeded = $false
            },
            [pscustomobject]@{
                name = "fixture-unresolved"
                found = $true
                path = ""
                version = ""
                probeSucceeded = $false
            }
        )
        pathEntries = @(
            [pscustomobject]@{
                index = 0
                path = "D:\Codex\tools"
                exists = $true
                drive = "D:\"
            },
            [pscustomobject]@{
                index = 1
                path = "D:\missing-project\.venv\Scripts"
                exists = $false
                drive = "D:\"
            }
        )
    }
    $fixtureInventory | ConvertTo-Json -Depth 10 | Set-Content -Path $fixtureInventoryPath -Encoding UTF8
    & $readinessScript -InventoryPath $fixtureInventoryPath -OutputDir $fixtureOutput | Out-Null
    $fixtureReadiness = Get-Content -Path (Join-Path $fixtureOutput "readiness.json") -Raw | ConvertFrom-Json
    $resolvedEntry = $fixtureReadiness.toolReadiness | Where-Object { $_.name -eq "fixture-resolved" } | Select-Object -First 1
    $unresolvedEntry = $fixtureReadiness.toolReadiness | Where-Object { $_.name -eq "fixture-unresolved" } | Select-Object -First 1
    Assert-True -Condition ($resolvedEntry.pathStatus -eq "resolved") -Message "有路径工具应标记为 resolved"
    Assert-True -Condition ($resolvedEntry.pathDisplay -eq $resolvedEntry.path) -Message "有路径工具的 pathDisplay 应等于原始路径"
    Assert-True -Condition ($unresolvedEntry.pathStatus -eq "unresolved") -Message "空路径工具应标记为 unresolved"
    Assert-True -Condition ($unresolvedEntry.pathDisplay -eq "未解析（inventory 未返回路径）") -Message "空路径工具应显示未解析说明"
    $fixtureStaleEnvEntry = $fixtureReadiness.pathSummary.staleLocalEnvironmentEntries | Where-Object { $_.path -eq "D:\missing-project\.venv\Scripts" } | Select-Object -First 1
    Assert-True -Condition ($null -ne $fixtureStaleEnvEntry) -Message "fixture 中失效 .venv PATH 入口应被分类"
    Assert-True -Condition ($fixtureStaleEnvEntry.recommendedAction -like "*不重建或删除环境目录*") -Message "fixture 失效 .venv PATH 入口建议动作错误"

    $fixtureMarkdown = Get-Content -Path (Join-Path $fixtureOutput "REPORT.md") -Raw
    Assert-True -Condition $fixtureMarkdown.Contains("D:\missing-project\.venv\Scripts") -Message "fixture REPORT.md 应列出缺失 .venv PATH 入口"
    foreach ($unexpected in @("| d-drive |", "| user-profile |", "| low |", "| medium |", "| high |", "| True |")) {
        Assert-True -Condition (-not $fixtureMarkdown.Contains($unexpected)) -Message "REPORT.md 不应直接展示内部枚举或布尔值：$unexpected"
    }
} finally {
    if (Test-Path -LiteralPath $junctionPath) {
        $junctionItem = Get-Item -LiteralPath $junctionPath -Force
        if (($junctionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $junctionItem.Delete()
        }
    }

    if (-not $KeepOutputs -and (Test-Path -Path $testRoot)) {
        Remove-Item -Path $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    readinessJson = $jsonPath
    readinessMarkdown = $markdownPath
}
