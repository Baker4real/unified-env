param(
    [string]$ProjectRoot = "D:\agents\projects\统一环境",
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

function Assert-CanRemoveTestRoot {
    param([string]$Path)

    $projectReportsRoot = Join-Path $ProjectRoot "reports"
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullReportsRoot = [System.IO.Path]::GetFullPath($projectReportsRoot).TrimEnd("\", "/")
    $isUnderReports = $fullPath.StartsWith("$fullReportsRoot\", [System.StringComparison]::OrdinalIgnoreCase)
    Assert-True -Condition $isUnderReports -Message "测试输出目录必须位于项目 reports 下：$Path"

    $current = $fullPath
    while ($current.StartsWith($fullReportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            Assert-True -Condition (-not $isReparse) -Message "测试输出路径不能穿过 junction、symlink 或 reparse point：$current"
        }

        if ($current.Equals($fullReportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($current)
        Assert-True -Condition ($null -ne $parent) -Message "无法解析测试输出目录父级：$current"
        $current = $parent.FullName.TrimEnd("\", "/")
    }

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        Assert-True -Condition (-not $isReparse) -Message "测试输出目录不能是 junction、symlink 或 reparse point：$Path"
    }
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Value
    )

    Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
}

$scriptPath = Join-Path $ProjectRoot "scripts\New-CodexAccountSwitchDependencyUpdateDryRun.ps1"
$testRoot = Join-Path $ProjectRoot "reports\codex-account-switch-dependency-update-dry-run-test"
$fixtureRoot = Join-Path $testRoot "fixture"
$fixtureProject = Join-Path $fixtureRoot "codex-account-switch"
$fixtureInputs = Join-Path $fixtureRoot "inputs"
$outputDir = Join-Path $testRoot "out"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到 codex-account-switch 依赖更新 dry-run 脚本"

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $fixtureProject | Out-Null
    New-Item -ItemType Directory -Force -Path $fixtureInputs | Out-Null

    Write-Utf8File -Path (Join-Path $fixtureProject "package.json") -Value @'
{
  "name": "codex_switch",
  "private": true,
  "version": "1.5.12",
  "type": "module",
  "dependencies": {
    "@tauri-apps/api": "2.10.1"
  },
  "devDependencies": {
    "@tauri-apps/cli": "2.10.1",
    "typescript": "5.9.2",
    "vite": "7.1.4"
  }
}
'@

    Write-Utf8File -Path (Join-Path $fixtureProject "package-lock.json") -Value @'
{
  "name": "codex_switch",
  "version": "1.5.12",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "codex_switch",
      "version": "1.5.12"
    },
    "node_modules/vite": {
      "version": "7.1.4"
    }
  }
}
'@

    $npmLsPath = Join-Path $fixtureInputs "npm-ls.json"
    $npmOutdatedPath = Join-Path $fixtureInputs "npm-outdated.json"
    $npmAuditPath = Join-Path $fixtureInputs "npm-audit.json"
    $gitStatusPath = Join-Path $fixtureInputs "git-status.txt"

    Write-Utf8File -Path $npmLsPath -Value @'
{
  "version": "1.5.12",
  "name": "codex_switch",
  "dependencies": {
    "@tauri-apps/api": { "version": "2.10.1" },
    "@tauri-apps/cli": { "version": "2.10.1" },
    "typescript": { "version": "5.9.2" },
    "vite": { "version": "7.1.4" }
  }
}
'@

    Write-Utf8File -Path $npmOutdatedPath -Value @'
{
  "@tauri-apps/api": { "current": "2.10.1", "wanted": "2.10.1", "latest": "2.11.1", "dependent": "codex-account-switch" },
  "@tauri-apps/cli": { "current": "2.10.1", "wanted": "2.10.1", "latest": "2.11.4", "dependent": "codex-account-switch" },
  "typescript": { "current": "5.9.2", "wanted": "5.9.2", "latest": "6.0.3", "dependent": "codex-account-switch" },
  "vite": { "current": "7.1.4", "wanted": "7.1.4", "latest": "8.1.2", "dependent": "codex-account-switch" }
}
'@

    Write-Utf8File -Path $npmAuditPath -Value @'
{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "postcss": {
      "name": "postcss",
      "severity": "moderate",
      "isDirect": false,
      "via": [],
      "range": "<8.5.10",
      "fixAvailable": true
    },
    "vite": {
      "name": "vite",
      "severity": "high",
      "isDirect": true,
      "via": [
        { "title": "Vite test advisory", "severity": "high", "range": "7.0.0 - 7.3.3" }
      ],
      "range": "7.0.0 - 7.3.3",
      "fixAvailable": {
        "name": "vite",
        "version": "7.3.6",
        "isSemVerMajor": false
      }
    }
  },
  "metadata": {
    "vulnerabilities": {
      "moderate": 1,
      "high": 1,
      "total": 2
    }
  }
}
'@

    Write-Utf8File -Path $gitStatusPath -Value "## main`n M src-tauri/shared/runtime/models.rs"

    $packageBefore = Get-Content -LiteralPath (Join-Path $fixtureProject "package.json") -Raw
    $result = & $scriptPath `
        -ProjectPath $fixtureProject `
        -OutputDir $outputDir `
        -NpmLsJsonPath $npmLsPath `
        -NpmOutdatedJsonPath $npmOutdatedPath `
        -NpmAuditJsonPath $npmAuditPath `
        -GitStatusTextPath $gitStatusPath `
        -NodeVersion "v24.15.0" `
        -NpmVersion "11.12.1" `
        -NpmCache "D:\Codex\tools\npm-cache"

    Assert-True -Condition ([bool]$result.dryRun) -Message "脚本没有返回 dryRun=true"
    Assert-True -Condition ([bool]$result.readOnly) -Message "脚本没有返回 readOnly=true"
    Assert-True -Condition (-not [bool]$result.executionAllowed) -Message "脚本不应允许执行"

    $jsonPath = Join-Path $outputDir "plan.json"
    $markdownPath = Join-Path $outputDir "PLAN.md"
    Assert-True -Condition (Test-Path -LiteralPath $jsonPath -PathType Leaf) -Message "缺少 plan.json"
    Assert-True -Condition (Test-Path -LiteralPath $markdownPath -PathType Leaf) -Message "缺少 PLAN.md"

    $plan = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    foreach ($property in @("schemaVersion", "generatedAt", "dryRun", "readOnly", "targetProject", "runtime", "package", "projectState", "npmState", "recommendation", "policy")) {
        Assert-Property -Object $plan -Name $property
    }

    Assert-True -Condition ([bool]$plan.dryRun) -Message "plan JSON 的 dryRun 不是 true"
    Assert-True -Condition ([bool]$plan.readOnly) -Message "plan JSON 的 readOnly 不是 true"
    Assert-True -Condition (-not [bool]$plan.policy.executionAllowed) -Message "计划不应允许执行"
    Assert-True -Condition (-not [bool]$plan.policy.deleteAllowed) -Message "计划不应允许删除"
    Assert-True -Condition (-not [bool]$plan.policy.migrationAllowed) -Message "计划不应允许迁移"
    Assert-True -Condition (-not [bool]$plan.policy.targetProjectWriteAllowed) -Message "计划不应允许写目标项目"
    Assert-True -Condition (-not [bool]$plan.projectState.isClean) -Message "fixture dirty 状态应被识别"
    Assert-True -Condition ([bool]$plan.recommendation.blockedByDirtyWorktree) -Message "dirty worktree 应阻塞真实更新"
    Assert-True -Condition ($plan.recommendation.status -eq "blocked-target-dirty") -Message "dirty 状态应输出 blocked-target-dirty"
    Assert-True -Condition ($plan.recommendation.primaryCandidate.auditFixVersion -eq "7.3.6") -Message "应读取 npm audit 的 vite fix 版本"

    $commands = @($plan.recommendation.candidateCommands) -join "`n"
    Assert-True -Condition $commands.Contains("npm install vite@7.3.6 --save-dev --package-lock-only --ignore-scripts") -Message "缺少 vite 安全补丁候选命令预览"
    Assert-True -Condition (-not $commands.Contains("npm audit fix")) -Message "不得建议 npm audit fix"

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    foreach ($expected in @("DRY-RUN", "执行允许：否", "npm ci", "vite 8.1.2", "typescript 6.0.3", "npm run version:check", "npm run check:rust:windows", '不得删除现有 `node_modules`')) {
        Assert-True -Condition $markdown.Contains($expected) -Message "PLAN.md 缺少预期文本：$expected"
    }

    $packageAfter = Get-Content -LiteralPath (Join-Path $fixtureProject "package.json") -Raw
    Assert-True -Condition ($packageBefore -eq $packageAfter) -Message "脚本不应修改 fixture package.json"

    $blockedOutput = "C:\Codex-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath `
            -ProjectPath $fixtureProject `
            -OutputDir $blockedOutput `
            -NpmLsJsonPath $npmLsPath `
            -NpmOutdatedJsonPath $npmOutdatedPath `
            -NpmAuditJsonPath $npmAuditPath `
            -GitStatusTextPath $gitStatusPath `
            -NodeVersion "v24.15.0" `
            -NpmVersion "11.12.1" `
            -NpmCache "D:\Codex\tools\npm-cache" | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止 C 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedOutput)) -Message "测试不应在 C 盘创建输出目录"

    $blockedDOutput = "D:\Codex\codex-account-switch-dependency-update-should-not-be-created"
    $blocked = $false
    try {
        & $scriptPath `
            -ProjectPath $fixtureProject `
            -OutputDir $blockedDOutput `
            -NpmLsJsonPath $npmLsPath `
            -NpmOutdatedJsonPath $npmOutdatedPath `
            -NpmAuditJsonPath $npmAuditPath `
            -GitStatusTextPath $gitStatusPath `
            -NodeVersion "v24.15.0" `
            -NpmVersion "11.12.1" `
            -NpmCache "D:\Codex\tools\npm-cache" | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于允许的报告目录*"
    }
    Assert-True -Condition $blocked -Message "脚本没有阻止非授权 D 盘 OutputDir"
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedDOutput)) -Message "测试不应在非授权 D 盘目录创建输出目录"
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-CanRemoveTestRoot -Path $testRoot
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    planJson = $jsonPath
    planMarkdown = $markdownPath
}
