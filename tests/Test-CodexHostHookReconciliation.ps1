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

function Get-TreeFingerprint {
    param(
        [string]$CodexHome,
        [switch]$ExcludeEvidence
    )

    $root = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd("\", "/")
    $items = @(Get-Item -LiteralPath $root -Force) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    $entries = foreach ($item in $items) {
        Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "fixture 树中出现 reparse point：$($item.FullName)"
        $relativePath = [System.IO.Path]::GetRelativePath($root, $item.FullName)
        if ($ExcludeEvidence -and ($relativePath -eq "run-evidence" -or $relativePath.StartsWith("run-evidence\", [System.StringComparison]::OrdinalIgnoreCase))) {
            continue
        }
        $acl = Get-Acl -LiteralPath $item.FullName
        [ordered]@{
            path = $relativePath
            kind = if ($item.PSIsContainer) { "directory" } else { "file" }
            hash = if ($item.PSIsContainer) { $null } else { Get-Sha256 -Path $item.FullName }
            attributes = [string]$item.Attributes
            sddl = $acl.Sddl
        }
    }

    @($entries | Sort-Object path | ConvertTo-Json -Depth 5 -Compress) -join ""
}

function Assert-OnlyAllowedWriters {
    param([string]$Path)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($currentSid, "S-1-5-18", "S-1-5-32-544")
    $acl = Get-Acl -LiteralPath $Path
    Assert-True -Condition $acl.AreAccessRulesProtected -Message "ACL 仍继承宽泛权限：$Path"
    $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    Assert-True -Condition ($ownerSid -eq $currentSid) -Message "ACL owner 不是当前用户：$Path / $ownerSid"

    $writeMask = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    $writers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or ($rule.FileSystemRights -band $writeMask) -eq 0) {
            continue
        }

        $sid = $rule.IdentityReference.Value
        Assert-True -Condition ($allowed -contains $sid) -Message "ACL 仍允许非白名单主体写入：$Path / $sid"
        $writers.Add($sid) | Out-Null
    }

    foreach ($sid in $allowed) {
        Assert-True -Condition $writers.Contains($sid) -Message "ACL 缺少白名单写主体：$Path / $sid"
    }
}

function Get-CheckResult {
    param(
        [object]$Result,
        [string]$Name
    )

    $matches = @($Result.checks | Where-Object { $_.name -eq $Name })
    Assert-True -Condition ($matches.Count -eq 1) -Message "检查项必须恰好出现一次：$Name"
    $matches[0]
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
    "serena-dashboard-guard.ps1",
    "__pycache__\codex-mobile-permission-guard.cpython-313.pyc"
)

function New-FixtureCodexHome {
    param(
        [string]$Root,
        [ValidateSet("Drift", "MalformedHooks", "DuplicateSerena", "MissingSerenaArgs", "DuplicateSerenaArgs", "MalformedSerenaArgs", "MissingSerenaContext", "MissingSerenaContextValue", "WrongSerenaContext", "DuplicateSerenaContext", "InvalidSerenaContextPolicy", "MissingSerenaProjectValue", "DuplicateHookSection", "DuplicateQuotedApproval", "RootDottedHookKey", "SensitiveInvalidHeader", "MissingApproval", "MultilineToml")]
        [string]$Variant = "Drift"
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Set-Content -LiteralPath (Join-Path $Root ".codex-host-hook-reconciliation-fixture") -Value "codex-host-hook-reconciliation-fixture-v1" -Encoding UTF8
    $hookDirectory = Join-Path $Root "hooks"
    New-Item -ItemType Directory -Force -Path $hookDirectory | Out-Null

    $config = @'
model = "fixture-model-must-survive"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[mcp_servers.serena]
startup_timeout_sec = 60
command = "D:\\Codex\\tools\\uv\\bin\\serena.exe"
args = [ "start-mcp-server", "--context=D:\\Codex\\.serena\\contexts\\codex-file-tools.yml", "--project-from-cwd", "--project", "D:\\Codex\\projects\\yangyangzi-direct-qqbot", "--enable-web-dashboard=true", "--open-web-dashboard=false" ]

[mcp_servers.serena.env]
SERENA_HOME = "D:\\Codex\\.serena"
FIXTURE_ENV_SENTINEL = "must-survive"

[features]
hooks = false
unified_exec = false
apps = true
fixture_feature_sentinel = true

[hooks]
[hooks.state]
[ "hooks" . state . "D:\\Codex\\.codex\\hooks.json:session_start:0:0" ]
enabled = true
hash = "fixture-trust-hash"

[[fixture.array]] # 合法 array-of-tables 不能随 hooks section 被删除
name = "array-table-must-survive"

    [network]
enabled = true
fixture_network_sentinel = "must-survive"
'@

    $serenaContextPath = Join-Path ([System.IO.Directory]::GetParent($Root).FullName) ".serena\contexts\codex-file-tools.yml"
    $config = $config.Replace('D:\\Codex\\.serena\\contexts\\codex-file-tools.yml', $serenaContextPath.Replace('\', '\\'))

    if ($Variant -eq "DuplicateSerena") {
        $config += @'

[mcp_servers.serena]
args = [ "start-mcp-server", "--project-from-cwd" ]
'@
    } elseif ($Variant -eq "MissingSerenaArgs") {
        $config = $config -replace '(?m)^args\s*=.*\r?\n', ''
    } elseif ($Variant -eq "DuplicateSerenaArgs") {
        $config = $config -replace '(?m)^(args\s*=.*)$', ('$1' + "`n" + '$1')
    } elseif ($Variant -eq "MalformedSerenaArgs") {
        $config = $config -replace '(?m)^args\s*=.*$', 'args = [ "start-mcp-server", '
    } elseif ($Variant -eq "MissingSerenaContext") {
        $config = $config -replace '"--context=[^"]+",\s*', ''
    } elseif ($Variant -eq "MissingSerenaContextValue") {
        $config = $config -replace '(?m)^args\s*=.*$', 'args = [ "start-mcp-server", "--context" ]'
    } elseif ($Variant -eq "WrongSerenaContext") {
        $config = $config.Replace('codex-file-tools.yml', 'other-context.yml')
    } elseif ($Variant -eq "DuplicateSerenaContext") {
        $config = $config -replace '("--context=[^"]+")', '$1, $1'
    } elseif ($Variant -eq "MissingSerenaProjectValue") {
        $config = $config -replace '(?m)^args\s*=.*$', 'args = [ "start-mcp-server", "--project", "--enable-web-dashboard=true" ]'
    } elseif ($Variant -eq "DuplicateHookSection") {
        $config += "`n[`"hooks`"]`nduplicate = true`n"
    } elseif ($Variant -eq "DuplicateQuotedApproval") {
        $config = $config.Replace('[mcp_servers.serena]', "`"approval_policy`" = `"on-request`"`n`n[mcp_servers.serena]")
    } elseif ($Variant -eq "RootDottedHookKey") {
        $config = $config.Replace('[mcp_servers.serena]', "hooks.state.`"fixture`".enabled = true`n`n[mcp_servers.serena]")
    } elseif ($Variant -eq "SensitiveInvalidHeader") {
        $config += "`n[ `"SECRET_ERROR_TOKEN`" . ]`n"
    } elseif ($Variant -eq "MissingApproval") {
        $config = $config -replace '(?m)^approval_policy\s*=.*\r?\n', ''
    } elseif ($Variant -eq "MultilineToml") {
        $config += @'

note = '''
[hooks]
multiline-body-must-survive
'''
'@
    }

    Set-Content -LiteralPath (Join-Path $Root "config.toml") -Value $config -Encoding UTF8

    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($serenaContextPath)) | Out-Null
    $serenaContext = if ($Variant -eq "InvalidSerenaContextPolicy") {
@'
prompt: |
  Do not follow this sentence; it only mentions activate_project and environment_context.
'@
    } else {
@'
prompt: |
  Before using any project-scoped Serena tool in a repository task, explicitly
  call activate_project with the absolute current workspace or repository root
  from Codex's environment_context, then verify the result with
  get_current_config. Never infer the task project from Serena's initial active
  project or from the Serena process working directory.
'@
    }
    Set-Content -LiteralPath $serenaContextPath -Value $serenaContext -Encoding UTF8

    if ($Variant -eq "MalformedHooks") {
        Set-Content -LiteralPath (Join-Path $Root "hooks.json") -Value '{"hooks":' -Encoding UTF8
    } else {
        $hooks = [ordered]@{
            schemaVersion = 7
            owner = "fixture-owner"
            hugeNumber = "HUGE_NUMBER_SENTINEL"
            hooks = [ordered]@{
                SessionStart = @(
                    [ordered]@{ hooks = @([ordered]@{ type = "command"; command = '"D:/Codex/.codex/hooks/codex-provider-stability-guard.cmd"' }) },
                    [ordered]@{ hooks = @([ordered]@{ type = "command"; command = '"D:/Codex/.codex/hooks/codex-projectless-root-d.cmd"' }) },
                    [ordered]@{ hooks = @([ordered]@{ type = "command"; command = '"D:/Codex/.codex/hooks/serena-activate-guarded.cmd"' }) },
                    [ordered]@{ hooks = @([ordered]@{ type = "command"; command = '"D:/Codex/.codex/hooks/serena-dashboard-guard.cmd"' }) }
                )
                PreToolUse = @(
                    [ordered]@{ matcher = "Bash"; hooks = @([ordered]@{ type = "command"; command = "serena-hooks remind --client=codex" }) },
                    [ordered]@{ matcher = "mcp__serena__*"; hooks = @([ordered]@{ type = "command"; command = "serena-hooks auto-approve --client=codex" }) }
                )
                Stop = @([ordered]@{ hooks = @([ordered]@{ type = "command"; command = "serena-hooks cleanup --client=codex" }) })
            }
        }
        ($hooks | ConvertTo-Json -Depth 12).Replace('"HUGE_NUMBER_SENTINEL"', '1e400') | Set-Content -LiteralPath (Join-Path $Root "hooks.json") -Encoding UTF8
    }

    foreach ($name in $legacyNames) {
        $legacyPath = Join-Path $hookDirectory $name
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($legacyPath)) | Out-Null
        Set-Content -LiteralPath $legacyPath -Value "fixture:$name" -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $hookDirectory "keep-me.txt") -Value "unknown-file-must-survive" -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $hookDirectory "unknown-nested") | Out-Null
    Set-Content -LiteralPath (Join-Path $hookDirectory "unknown-nested\keep.bin") -Value "unknown-nested-must-survive" -Encoding UTF8
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

    $before = Get-TreeFingerprint -CodexHome $CodexHome
    $threw = $false
    try {
        Invoke-Reconciler -ScriptPath $ScriptPath -Mode Repair -CodexHome $CodexHome | Out-Null
    } catch {
        $threw = $true
    }
    $after = Get-TreeFingerprint -CodexHome $CodexHome
    Assert-True -Condition $threw -Message "$CaseName 没有拒绝 Repair"
    Assert-True -Condition ($before -eq $after) -Message "$CaseName 被拒绝后仍修改了核心文件"
}

$scriptPath = Join-Path $ProjectRoot "scripts\Invoke-CodexHostHookReconciliation.ps1"
$testRunId = [guid]::NewGuid().ToString("N")
$testRoot = Join-Path $ProjectRoot "reports\codex-host-hook-reconciliation-test-$testRunId"
$ownershipMarker = Join-Path $testRoot ".owned-by-test-$testRunId"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到待实现的冷路径修复器：$scriptPath"

try {
    Assert-SafeTestRoot -Path $testRoot
    Assert-True -Condition (-not (Test-Path -LiteralPath $testRoot)) -Message "唯一测试目录意外已存在：$testRoot"
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    Set-Content -LiteralPath $ownershipMarker -Value $testRunId -Encoding UTF8

    $healthyHome = Join-Path $testRoot "drift\.codex"
    New-FixtureCodexHome -Root $healthyHome

    $beforeCheck = Get-TreeFingerprint -CodexHome $healthyHome
    $check = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
    $afterCheck = Get-TreeFingerprint -CodexHome $healthyHome
    foreach ($property in @("schemaVersion", "mode", "ok", "changed", "driftCount", "checks", "evidencePath")) {
        Assert-Property -Object $check -Name $property
    }
    Assert-True -Condition ($check.mode -eq "Check") -Message "Check 结果 mode 错误"
    Assert-True -Condition (-not [bool]$check.ok) -Message "有 drift 的 fixture 不应通过 Check"
    Assert-True -Condition (-not [bool]$check.changed) -Message "Check 不得报告 changed=true"
    Assert-True -Condition ([int]$check.driftCount -gt 0) -Message "Check 未报告 drift"
    Assert-True -Condition ($beforeCheck -eq $afterCheck) -Message "Check 修改了 fixture"
    foreach ($name in @("config", "registrations", "legacyImplementations", "acl")) {
        Assert-True -Condition (-not [bool](Get-CheckResult -Result $check -Name $name).ok) -Message "漂移 fixture 的检查项不应健康：$name"
    }

    $originalConfigHash = Get-Sha256 -Path (Join-Path $healthyHome "config.toml")
    $originalHooksHash = Get-Sha256 -Path (Join-Path $healthyHome "hooks.json")
    $legacyHashes = @{}
    foreach ($name in $legacyNames) {
        $legacyHashes[$name] = Get-Sha256 -Path (Join-Path $healthyHome "hooks\$name")
    }
    $unknownFileHash = Get-Sha256 -Path (Join-Path $healthyHome "hooks\keep-me.txt")
    $unknownNestedHash = Get-Sha256 -Path (Join-Path $healthyHome "hooks\unknown-nested\keep.bin")
    $repair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    Assert-True -Condition ($repair.mode -eq "Repair") -Message "Repair 结果 mode 错误"
    Assert-True -Condition ([bool]$repair.ok) -Message "Repair 未形成健康终态"
    Assert-True -Condition ([bool]$repair.changed) -Message "首次 Repair 应报告 changed=true"
    Assert-True -Condition (Test-Path -LiteralPath $repair.evidencePath -PathType Container) -Message "Repair 未生成 evidence 目录"

    $hooks = Get-Content -LiteralPath (Join-Path $healthyHome "hooks.json") -Raw | ConvertFrom-Json -AsHashtable
    $hooksRaw = Get-Content -LiteralPath (Join-Path $healthyHome "hooks.json") -Raw
    Assert-True -Condition ([int]$hooks.schemaVersion -eq 7) -Message "hooks.json 未保留未知 schemaVersion"
    Assert-True -Condition ($hooks.owner -eq "fixture-owner") -Message "hooks.json 未保留未知 owner"
    Assert-True -Condition ($hooksRaw -match '"hugeNumber"\s*:\s*1e400') -Message "hooks.json 改写了未知大数值"
    Assert-True -Condition ($hooks.hooks -is [System.Collections.IDictionary]) -Message "hooks 必须是 JSON 空对象，不能是数组或 null"
    Assert-True -Condition ($hooks.hooks.Count -eq 0) -Message "hooks.json 的 hooks 不是空对象"

    $config = Get-Content -LiteralPath (Join-Path $healthyHome "config.toml") -Raw
    Assert-True -Condition (-not ($config -match '"--project-from-cwd(?:=|"\s*,)')) -Message "Serena 仍包含不可靠的 --project-from-cwd"
    Assert-True -Condition (-not ($config -match '"--project"\s*,')) -Message "Serena 仍包含固定 --project"
    Assert-True -Condition (-not ($config -match '"--project-file(?:=|"\s*,)')) -Message "Serena 仍包含 --project-file"
    Assert-True -Condition $config.Contains("codex-file-tools.yml") -Message "Serena custom context 被误删"
    foreach ($sentinel in @('fixture-model-must-survive', 'FIXTURE_ENV_SENTINEL = "must-survive"', 'fixture_feature_sentinel = true', 'array-table-must-survive', 'fixture_network_sentinel = "must-survive"')) {
        Assert-True -Condition $config.Contains($sentinel) -Message "无关 TOML 内容被误删或改写：$sentinel"
    }
    Assert-True -Condition ($config -match '(?m)^approval_policy\s*=\s*"never"\s*$') -Message "approval_policy 未归一化"
    Assert-True -Condition ($config -match '(?m)^sandbox_mode\s*=\s*"danger-full-access"\s*$') -Message "sandbox_mode 未归一化"
    Assert-True -Condition ($config -match '(?m)^hooks\s*=\s*true\s*$') -Message "features.hooks 未保持开启"
    Assert-True -Condition ($config -match '(?m)^unified_exec\s*=\s*true\s*$') -Message "features.unified_exec 未保持开启"
    Assert-True -Condition (-not ($config -match '(?m)^\[hooks(?:\.|\])')) -Message "旧 hook trust section 未删除"
    Assert-True -Condition (-not $config.Contains('fixture-trust-hash')) -Message "带点号空白的合法 hook trust section 未删除"

    foreach ($name in $legacyNames) {
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $healthyHome "hooks\$name"))) -Message "legacy 文件仍在 live 目录：$name"
        $archivedPath = Join-Path $repair.evidencePath "legacy-hooks\$name"
        Assert-True -Condition (Test-Path -LiteralPath $archivedPath -PathType Leaf) -Message "legacy 文件未先归档：$name"
        Assert-True -Condition ((Get-Sha256 -Path $archivedPath) -eq $legacyHashes[$name]) -Message "legacy evidence 内容不真实：$name"
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $healthyHome "hooks\__pycache__"))) -Message "空 legacy __pycache__ 目录未退役"
    foreach ($relative in @("config.toml", "hooks.json", "manifest.json")) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $repair.evidencePath $relative) -PathType Leaf) -Message "evidence 缺少：$relative"
    }
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $repair.evidencePath "config.toml")) -eq $originalConfigHash) -Message "config evidence 不是修复前快照"
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $repair.evidencePath "hooks.json")) -eq $originalHooksHash) -Message "hooks evidence 不是修复前快照"
    $manifest = Get-Content -LiteralPath (Join-Path $repair.evidencePath "manifest.json") -Raw | ConvertFrom-Json
    $unknownFileEvidence = @($manifest.preservedHookTree | Where-Object { $_.path -eq 'keep-me.txt' })
    $unknownNestedEvidence = @($manifest.preservedHookTree | Where-Object { $_.path -eq 'unknown-nested\keep.bin' })
    Assert-True -Condition ($unknownFileEvidence.Count -eq 1 -and $unknownFileEvidence[0].sha256 -eq $unknownFileHash) -Message "manifest 未记录未知 hook 文件及哈希"
    Assert-True -Condition ($unknownNestedEvidence.Count -eq 1 -and $unknownNestedEvidence[0].sha256 -eq $unknownNestedHash) -Message "manifest 未记录未知嵌套 hook 文件及哈希"
    $aclBefore = Get-Content -LiteralPath (Join-Path $repair.evidencePath "acl-before.json") -Raw | ConvertFrom-Json -AsHashtable
    foreach ($path in @(
        (Join-Path $healthyHome "config.toml"),
        (Join-Path $healthyHome "hooks.json"),
        (Join-Path $healthyHome "hooks"),
        (Join-Path $healthyHome "hooks\keep-me.txt"),
        (Join-Path $healthyHome "hooks\unknown-nested"),
        (Join-Path $healthyHome "hooks\unknown-nested\keep.bin"),
        (Join-Path ([System.IO.Directory]::GetParent($healthyHome).FullName) ".serena\contexts\codex-file-tools.yml")
    )) {
        Assert-True -Condition $aclBefore.Contains($path) -Message "acl-before 未覆盖完整 hooks tree：$path"
    }
    foreach ($item in @(Get-Item -LiteralPath $repair.evidencePath -Force) + @(Get-ChildItem -LiteralPath $repair.evidencePath -Recurse -Force)) {
        Assert-OnlyAllowedWriters -Path $item.FullName
    }
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $healthyHome "hooks\keep-me.txt")) -eq $unknownFileHash) -Message "未知 hook 文件被删除或改写"
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $healthyHome "hooks\unknown-nested\keep.bin")) -eq $unknownNestedHash) -Message "未知嵌套 hook 文件被删除或改写"

    foreach ($path in @((Join-Path $healthyHome "config.toml"), (Join-Path $healthyHome "hooks.json"), (Join-Path $healthyHome "hooks"))) {
        Assert-OnlyAllowedWriters -Path $path
    }
    Assert-OnlyAllowedWriters -Path (Join-Path ([System.IO.Directory]::GetParent($healthyHome).FullName) ".serena\contexts\codex-file-tools.yml")

    $healthyCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
    Assert-True -Condition ([bool]$healthyCheck.ok -and [int]$healthyCheck.driftCount -eq 0) -Message "Repair 后的直接 Check 不健康"
    foreach ($name in @("config", "registrations", "legacyImplementations", "acl")) {
        Assert-True -Condition ([bool](Get-CheckResult -Result $healthyCheck -Name $name).ok) -Message "Repair 后检查项不健康：$name"
    }

    $stableFingerprint = Get-TreeFingerprint -CodexHome $healthyHome
    $evidenceRoot = Join-Path $healthyHome "run-evidence\host-hook-remediation"
    $evidenceCount = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count
    $secondRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    Assert-True -Condition ([bool]$secondRepair.ok) -Message "第二次 Repair 未通过"
    Assert-True -Condition (-not [bool]$secondRepair.changed) -Message "第二次 Repair 不幂等"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $healthyHome) -eq $stableFingerprint) -Message "第二次 Repair 改变了核心文件"
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count -eq $evidenceCount) -Message "幂等 Repair 创建了无意义 evidence"

    $rollbackHome = Join-Path $testRoot "rollback\.codex"
    New-FixtureCodexHome -Root $rollbackHome
    $rollbackConfigHash = Get-Sha256 -Path (Join-Path $rollbackHome "config.toml")
    $rollbackHooksHash = Get-Sha256 -Path (Join-Path $rollbackHome "hooks.json")
    $rollbackBefore = Get-TreeFingerprint -CodexHome $rollbackHome -ExcludeEvidence
    $lockedHooksPath = Join-Path $rollbackHome "hooks.json"
    $lockStream = [System.IO.File]::Open(
        $lockedHooksPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $rollbackThrew = $false
    try {
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $rollbackHome | Out-Null
    } catch {
        $rollbackThrew = $true
    } finally {
        $lockStream.Dispose()
    }
    Assert-True -Condition $rollbackThrew -Message "hooks 原子替换被阻止时 Repair 未失败"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $rollbackHome -ExcludeEvidence) -eq $rollbackBefore) -Message "两文件半提交失败后未恢复原始状态"

    $rollbackEvidenceRoot = Join-Path $rollbackHome "run-evidence\host-hook-remediation"
    $rollbackEvidence = @(Get-ChildItem -LiteralPath $rollbackEvidenceRoot -Directory -Force)
    Assert-True -Condition ($rollbackEvidence.Count -eq 1) -Message "回滚 canary 必须恰好生成一份 evidence"
    $rollbackManifest = Get-Content -LiteralPath (Join-Path $rollbackEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($rollbackManifest.status -eq "rolled-back") -Message "回滚 evidence 未标记 rolled-back"
    Assert-True -Condition (@($rollbackManifest.attemptedResources) -contains "config.toml") -Message "回滚 manifest 未记录 config.toml 已进入提交阶段"
    Assert-True -Condition (@($rollbackManifest.attemptedResources) -contains "hooks.json") -Message "回滚 manifest 未记录 hooks.json 已进入提交阶段"
    Assert-True -Condition (@($rollbackManifest.committedResources) -contains "config.toml") -Message "回滚 canary 未证明 config.toml 曾进入提交阶段"
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $rollbackEvidence[0].FullName "config.toml")) -eq $rollbackConfigHash) -Message "回滚 evidence 的 config 快照不真实"
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $rollbackEvidence[0].FullName "hooks.json")) -eq $rollbackHooksHash) -Message "回滚 evidence 的 hooks 快照不真实"

    $legacyUnknownHome = Join-Path $testRoot "legacy-directory-unknown\.codex"
    New-FixtureCodexHome -Root $legacyUnknownHome
    $unknownCachePath = Join-Path $legacyUnknownHome "hooks\__pycache__\keep-me.pyc"
    Set-Content -LiteralPath $unknownCachePath -Value "unknown-cache-must-survive" -Encoding UTF8
    $unknownCacheHash = Get-Sha256 -Path $unknownCachePath
    $legacyUnknownThrew = $false
    try {
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $legacyUnknownHome | Out-Null
    } catch {
        $legacyUnknownThrew = $true
    }
    Assert-True -Condition $legacyUnknownThrew -Message "非空 legacy 目录应安全失败"
    Assert-True -Condition ((Get-Sha256 -Path $unknownCachePath) -eq $unknownCacheHash) -Message "legacy 目录中的未知文件被删除或改写"
    $legacyUnknownEvidence = @(Get-ChildItem -LiteralPath (Join-Path $legacyUnknownHome "run-evidence\host-hook-remediation") -Directory -Force)
    Assert-True -Condition ($legacyUnknownEvidence.Count -eq 1) -Message "legacy 目录未知文件 canary 必须恰好生成一份 evidence"
    $legacyUnknownManifest = Get-Content -LiteralPath (Join-Path $legacyUnknownEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
    $unknownCacheEvidence = @($legacyUnknownManifest.preservedHookTree | Where-Object { $_.path -eq '__pycache__\keep-me.pyc' })
    Assert-True -Condition ($unknownCacheEvidence.Count -eq 1 -and $unknownCacheEvidence[0].sha256 -eq $unknownCacheHash) -Message "manifest 漏记 legacy 目录中的未知文件"

    foreach ($case in @(
        @{ Name = "malformed-hooks"; Variant = "MalformedHooks" },
        @{ Name = "duplicate-serena"; Variant = "DuplicateSerena" },
        @{ Name = "missing-serena-args"; Variant = "MissingSerenaArgs" },
        @{ Name = "duplicate-serena-args"; Variant = "DuplicateSerenaArgs" },
        @{ Name = "malformed-serena-args"; Variant = "MalformedSerenaArgs" },
        @{ Name = "missing-serena-context"; Variant = "MissingSerenaContext" },
        @{ Name = "missing-serena-context-value"; Variant = "MissingSerenaContextValue" },
        @{ Name = "wrong-serena-context"; Variant = "WrongSerenaContext" },
        @{ Name = "duplicate-serena-context"; Variant = "DuplicateSerenaContext" },
        @{ Name = "invalid-serena-context-policy"; Variant = "InvalidSerenaContextPolicy" },
        @{ Name = "missing-serena-project-value"; Variant = "MissingSerenaProjectValue" },
        @{ Name = "duplicate-hook-section"; Variant = "DuplicateHookSection" },
        @{ Name = "duplicate-quoted-approval"; Variant = "DuplicateQuotedApproval" },
        @{ Name = "root-dotted-hook-key"; Variant = "RootDottedHookKey" },
        @{ Name = "missing-approval"; Variant = "MissingApproval" },
        @{ Name = "multiline-toml"; Variant = "MultilineToml" }
    )) {
        $caseHome = Join-Path $testRoot "$($case.Name)\.codex"
        New-FixtureCodexHome -Root $caseHome -Variant $case.Variant
        Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $caseHome -CaseName $case.Name
    }

    $sensitiveErrorHome = Join-Path $testRoot "sensitive-error\.codex"
    New-FixtureCodexHome -Root $sensitiveErrorHome -Variant SensitiveInvalidHeader
    $captured = [System.Collections.Generic.List[string]]::new()
    try {
        & $scriptPath -Mode Repair -CodexHome $sensitiveErrorHome -Json 2>&1 | ForEach-Object { $captured.Add([string]$_) }
    } catch {
        $captured.Add($_.ToString())
    }
    $capturedText = $captured -join "`n"
    Assert-True -Condition (-not $capturedText.Contains('SECRET_ERROR_TOKEN')) -Message "-Json 错误输出泄露了配置原文"
    $errorJsonLine = @($captured | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1)
    Assert-True -Condition ($errorJsonLine.Count -eq 1) -Message "-Json 失败未返回结构化 JSON"
    $errorJson = $errorJsonLine[0] | ConvertFrom-Json
    Assert-True -Condition (-not [bool]$errorJson.ok -and $errorJson.error.code -eq 'reconciliation-failed') -Message "-Json 失败结构不稳定"

    Write-Host "PASS: Codex host hook reconciliation"
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-SafeTestRoot -Path $testRoot
        Assert-True -Condition (Test-Path -LiteralPath $ownershipMarker -PathType Leaf) -Message "拒绝清理缺少 ownership marker 的测试目录"
        Assert-True -Condition ((Get-Content -LiteralPath $ownershipMarker -Raw).Trim() -eq $testRunId) -Message "拒绝清理 ownership marker 不匹配的测试目录"
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
