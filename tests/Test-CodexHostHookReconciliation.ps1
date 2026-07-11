param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境",
    [switch]$KeepOutputs
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

    Assert-True -Condition ($Object.PSObject.Properties.Name -contains $Name) -Message "缺少结果属性：$Name"
}

function Assert-SafeTestRoot {
    param([string]$Path)

    $reportsRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot "reports")).TrimEnd("\", "/")
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    Assert-True -Condition ($fullPath.StartsWith("$reportsRoot\", [System.StringComparison]::OrdinalIgnoreCase)) -Message "测试目录必须位于项目 reports 下：$fullPath"
    Assert-True -Condition ([System.IO.Path]::GetPathRoot($fullPath) -eq "D:\") -Message "测试目录必须位于 D 盘：$fullPath"

    $cursor = $fullPath
    while ($cursor.StartsWith($reportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "测试路径不能穿过 reparse point：$cursor"
        }

        if ($cursor.Equals($reportsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($cursor)
        Assert-True -Condition ($null -ne $parent) -Message "无法解析测试目录父级：$cursor"
        $cursor = $parent.FullName.TrimEnd("\", "/")
    }
}

function Get-Sha256 {
    param([string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-CoreFingerprint {
    param([string]$CodexHome)

    [ordered]@{
        config = Get-Sha256 -Path (Join-Path $CodexHome "config.toml")
        hooks = Get-Sha256 -Path (Join-Path $CodexHome "hooks.json")
        legacy = @(
            Get-ChildItem -LiteralPath (Join-Path $CodexHome "hooks") -File -Force |
                Sort-Object Name |
                ForEach-Object { "$($_.Name):$(Get-Sha256 -Path $_.FullName)" }
        ) -join "|"
    } | ConvertTo-Json -Compress
}

$legacyNames = @(
    "codex-mobile-permission-guard.py",
    "codex-projectless-root-d.cmd",
    "codex-projectless-root-d.js",
    "codex-provider-stability-guard.cmd",
    "codex-provider-stability-guard.ps1",
    "serena-activate-guarded.cmd",
    "serena-activate-guarded.ps1",
    "serena-dashboard-guard.cmd",
    "serena-dashboard-guard.ps1"
)

function New-FixtureCodexHome {
    param(
        [string]$Root,
        [ValidateSet("Drift", "MalformedHooks", "DuplicateSerena", "MissingSerenaArgs")]
        [string]$Variant = "Drift"
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $hookDirectory = Join-Path $Root "hooks"
    New-Item -ItemType Directory -Force -Path $hookDirectory | Out-Null

    $config = @'
model = "gpt-5.4"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[mcp_servers.serena]
startup_timeout_sec = 60
command = "D:\\Codex\\tools\\uv\\bin\\serena.exe"
args = [ "start-mcp-server", "--context=D:\\Codex\\.serena\\contexts\\codex-file-tools.yml", "--project", "D:\\Codex\\projects\\yangyangzi-direct-qqbot", "--enable-web-dashboard=true", "--open-web-dashboard=false" ]

[mcp_servers.serena.env]
SERENA_HOME = "D:\\Codex\\.serena"

[features]
hooks = false
unified_exec = false
apps = true

[hooks]
[hooks.state]
[hooks.state."D:\\Codex\\.codex\\hooks.json:session_start:0:0"]
enabled = true
hash = "fixture-trust-hash"

[network]
enabled = true
'@

    if ($Variant -eq "DuplicateSerena") {
        $config += @'

[mcp_servers.serena]
args = [ "start-mcp-server", "--project-from-cwd" ]
'@
    } elseif ($Variant -eq "MissingSerenaArgs") {
        $config = $config -replace '(?m)^args\s*=.*\r?\n', ''
    }

    Set-Content -LiteralPath (Join-Path $Root "config.toml") -Value $config -Encoding UTF8

    if ($Variant -eq "MalformedHooks") {
        Set-Content -LiteralPath (Join-Path $Root "hooks.json") -Value '{"hooks":' -Encoding UTF8
    } else {
        $hooks = [ordered]@{
            schemaVersion = 7
            owner = "fixture-owner"
            hooks = [ordered]@{
                SessionStart = @([ordered]@{ hooks = @([ordered]@{ type = "command"; command = '"D:/Codex/.codex/hooks/codex-provider-stability-guard.cmd"' }) })
                PreToolUse = @([ordered]@{ matcher = "Bash"; hooks = @([ordered]@{ type = "command"; command = "serena-hooks remind --client=codex" }) })
                Stop = @([ordered]@{ hooks = @([ordered]@{ type = "command"; command = "serena-hooks cleanup --client=codex" }) })
            }
        }
        $hooks | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Root "hooks.json") -Encoding UTF8
    }

    foreach ($name in $legacyNames) {
        Set-Content -LiteralPath (Join-Path $hookDirectory $name) -Value "fixture:$name" -Encoding UTF8
    }
}

function Invoke-Reconciler {
    param(
        [string]$ScriptPath,
        [string]$Mode,
        [string]$CodexHome
    )

    $raw = & $ScriptPath -Mode $Mode -CodexHome $CodexHome -Json
    $json = ($raw | Out-String).Trim()
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($json)) -Message "$Mode 没有返回 JSON"
    $json | ConvertFrom-Json
}

function Assert-RepairWasRejectedWithoutMutation {
    param(
        [string]$ScriptPath,
        [string]$CodexHome,
        [string]$CaseName
    )

    $before = Get-CoreFingerprint -CodexHome $CodexHome
    $threw = $false
    try {
        Invoke-Reconciler -ScriptPath $ScriptPath -Mode Repair -CodexHome $CodexHome | Out-Null
    } catch {
        $threw = $true
    }
    $after = Get-CoreFingerprint -CodexHome $CodexHome
    Assert-True -Condition $threw -Message "$CaseName 没有拒绝 Repair"
    Assert-True -Condition ($before -eq $after) -Message "$CaseName 被拒绝后仍修改了核心文件"
}

$scriptPath = Join-Path $ProjectRoot "scripts\Invoke-CodexHostHookReconciliation.ps1"
$testRoot = Join-Path $ProjectRoot "reports\codex-host-hook-reconciliation-test"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到待实现的冷路径修复器：$scriptPath"

try {
    Assert-SafeTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

    $healthyHome = Join-Path $testRoot "drift\.codex"
    New-FixtureCodexHome -Root $healthyHome

    $beforeCheck = Get-CoreFingerprint -CodexHome $healthyHome
    $check = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
    $afterCheck = Get-CoreFingerprint -CodexHome $healthyHome
    foreach ($property in @("schemaVersion", "mode", "ok", "changed", "driftCount", "checks", "evidencePath")) {
        Assert-Property -Object $check -Name $property
    }
    Assert-True -Condition ($check.mode -eq "Check") -Message "Check 结果 mode 错误"
    Assert-True -Condition (-not [bool]$check.ok) -Message "有 drift 的 fixture 不应通过 Check"
    Assert-True -Condition (-not [bool]$check.changed) -Message "Check 不得报告 changed=true"
    Assert-True -Condition ([int]$check.driftCount -gt 0) -Message "Check 未报告 drift"
    Assert-True -Condition ($beforeCheck -eq $afterCheck) -Message "Check 修改了 fixture"

    $repair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    Assert-True -Condition ($repair.mode -eq "Repair") -Message "Repair 结果 mode 错误"
    Assert-True -Condition ([bool]$repair.ok) -Message "Repair 未形成健康终态"
    Assert-True -Condition ([bool]$repair.changed) -Message "首次 Repair 应报告 changed=true"
    Assert-True -Condition (Test-Path -LiteralPath $repair.evidencePath -PathType Container) -Message "Repair 未生成 evidence 目录"

    $hooks = Get-Content -LiteralPath (Join-Path $healthyHome "hooks.json") -Raw | ConvertFrom-Json -AsHashtable
    Assert-True -Condition ([int]$hooks.schemaVersion -eq 7) -Message "hooks.json 未保留未知 schemaVersion"
    Assert-True -Condition ($hooks.owner -eq "fixture-owner") -Message "hooks.json 未保留未知 owner"
    Assert-True -Condition ($hooks.hooks.Count -eq 0) -Message "hooks.json 的 hooks 不是空对象"

    $config = Get-Content -LiteralPath (Join-Path $healthyHome "config.toml") -Raw
    Assert-True -Condition (([regex]::Matches($config, [regex]::Escape('"--project-from-cwd"'))).Count -eq 1) -Message "Serena 必须恰好包含一个 --project-from-cwd"
    Assert-True -Condition (-not ($config -match '"--project"\s*,')) -Message "Serena 仍包含固定 --project"
    Assert-True -Condition (-not ($config -match '"--project-file(?:=|"\s*,)')) -Message "Serena 仍包含 --project-file"
    Assert-True -Condition $config.Contains("codex-file-tools.yml") -Message "Serena custom context 被误删"
    Assert-True -Condition $config.Contains("[network]") -Message "无关 TOML section 被误删"
    Assert-True -Condition ($config -match '(?m)^approval_policy\s*=\s*"never"\s*$') -Message "approval_policy 未归一化"
    Assert-True -Condition ($config -match '(?m)^sandbox_mode\s*=\s*"danger-full-access"\s*$') -Message "sandbox_mode 未归一化"
    Assert-True -Condition ($config -match '(?m)^hooks\s*=\s*true\s*$') -Message "features.hooks 未保持开启"
    Assert-True -Condition ($config -match '(?m)^unified_exec\s*=\s*true\s*$') -Message "features.unified_exec 未保持开启"
    Assert-True -Condition (-not ($config -match '(?m)^\[hooks(?:\.|\])')) -Message "旧 hook trust section 未删除"

    foreach ($name in $legacyNames) {
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $healthyHome "hooks\$name"))) -Message "legacy 文件仍在 live 目录：$name"
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $repair.evidencePath "legacy-hooks\$name") -PathType Leaf) -Message "legacy 文件未先归档：$name"
    }
    foreach ($relative in @("config.toml", "hooks.json", "manifest.json")) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $repair.evidencePath $relative) -PathType Leaf) -Message "evidence 缺少：$relative"
    }

    foreach ($path in @((Join-Path $healthyHome "config.toml"), (Join-Path $healthyHome "hooks.json"), (Join-Path $healthyHome "hooks"))) {
        $acl = Get-Acl -LiteralPath $path
        Assert-True -Condition $acl.AreAccessRulesProtected -Message "ACL 仍继承宽泛写权限：$path"
        Assert-True -Condition (-not $acl.Sddl.Contains(";;;AU)")) -Message "ACL 仍包含 Authenticated Users：$path"
    }

    $stableFingerprint = Get-CoreFingerprint -CodexHome $healthyHome
    $evidenceRoot = Join-Path $healthyHome "run-evidence\host-hook-remediation"
    $evidenceCount = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count
    $secondRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    Assert-True -Condition ([bool]$secondRepair.ok) -Message "第二次 Repair 未通过"
    Assert-True -Condition (-not [bool]$secondRepair.changed) -Message "第二次 Repair 不幂等"
    Assert-True -Condition ((Get-CoreFingerprint -CodexHome $healthyHome) -eq $stableFingerprint) -Message "第二次 Repair 改变了核心文件"
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count -eq $evidenceCount) -Message "幂等 Repair 创建了无意义 evidence"

    foreach ($case in @(
        @{ Name = "malformed-hooks"; Variant = "MalformedHooks" },
        @{ Name = "duplicate-serena"; Variant = "DuplicateSerena" },
        @{ Name = "missing-serena-args"; Variant = "MissingSerenaArgs" }
    )) {
        $caseHome = Join-Path $testRoot "$($case.Name)\.codex"
        New-FixtureCodexHome -Root $caseHome -Variant $case.Variant
        Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $caseHome -CaseName $case.Name
    }

    Write-Host "PASS: Codex host hook reconciliation"
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-SafeTestRoot -Path $testRoot
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
