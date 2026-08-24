param(
    [string]$ProjectRoot = "D:\agents\projects\统一环境"
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

function Assert-FileContains {
    param(
        [string]$Path,
        [string[]]$ExpectedText
    )

    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "缺少文件：$Path"
    $content = Get-Content -LiteralPath $Path -Raw

    foreach ($expected in $ExpectedText) {
        Assert-True -Condition $content.Contains($expected) -Message "$Path 缺少预期文本：$expected"
    }
}

$policyPath = Join-Path $ProjectRoot "docs\env-governance\d-drive-layout-and-migration-policy.md"
$contextPath = Join-Path $ProjectRoot "CONTEXT.md"
$agentsPath = Join-Path $ProjectRoot "AGENTS.md"
$issuePath = Join-Path $ProjectRoot ".scratch\unified-env\issues\07-d-drive-layout-and-migration-policy.md"

Assert-FileContains -Path $policyPath -ExpectedText @(
    "D 盘目标布局",
    "D:\Codex\tools",
    "D:\Codex\envs",
    "D:\Codex\.cache",
    "reports\",
    "run-evidence",
    "共享运行时",
    "共享缓存",
    "全局 CLI",
    "项目本地环境",
    "人工审查项",
    "绝不自动迁移项",
    ".venv",
    "node_modules",
    "默认保留隔离",
    "dry-run",
    "显式授权",
    "验证",
    "回滚",
    "C:\Windows",
    "C:\ProgramData",
    "C:\Users",
    "junction",
    "symlink",
    "reparse point",
    "token",
    "DPAPI",
    "旧源目录默认保留",
    "单独步骤列明",
    '迁移授权”不自动包含删除或清理授权',
    '笼统的“继续”不等于授权真实迁移',
    "来源、目标、输出路径及其所有已存在父级"
)

Assert-FileContains -Path $contextPath -ExpectedText @(
    "统一环境治理",
    "docs/env-governance/d-drive-layout-and-migration-policy.md",
    "该共享的共享，该隔离的隔离"
)

Assert-FileContains -Path $agentsPath -ExpectedText @(
    "docs/env-governance/d-drive-layout-and-migration-policy.md",
    "真实迁移前"
)

Assert-FileContains -Path $issuePath -ExpectedText @(
    "Status: done",
    "- [x] 文档定义推荐的 D 盘根",
    "- [x] 文档被项目代理说明或 domain docs 指向"
)

[pscustomobject]@{
    ok = $true
    policy = $policyPath
    context = $contextPath
}
