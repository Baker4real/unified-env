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

    $reportsRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot ".scratch")).TrimEnd("\", "/")
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    Assert-True -Condition ($fullPath.StartsWith("$reportsRoot\host-hook-reconciliation-tests-", [System.StringComparison]::OrdinalIgnoreCase)) -Message "测试目录必须位于项目 .scratch 专用前缀下：$fullPath"
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

function Set-TestProtectedFileAcl {
    param([string]$Path)

    $security = [System.Security.AccessControl.FileSecurity]::new()
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in @($currentSid.Value, "S-1-5-18", "S-1-5-32-544")) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new($sidValue),
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule) | Out-Null
    }
    Set-Acl -LiteralPath $Path -AclObject $security
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
    "codex-mobile-permission-guard.cmd",
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

$reconcilerSource = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot "scripts\Invoke-CodexHostHookReconciliation.ps1")
Assert-True -Condition ($reconcilerSource.Contains('Read-CodexHookHostPreflightManifest')) -Message '生产 reconciler 必须读取固定 host-preflight manifest 作为唯一 ownership 边界'
Assert-True -Condition (-not $reconcilerSource.Contains('legacy-fixture-manifest.json')) -Message '生产 reconciler 不得读取 legacy fixture manifest'
foreach ($mobileRetiredClosure in @("codex-mobile-permission-guard.cmd", "codex-mobile-permission-guard.py")) {
    Assert-True -Condition ([regex]::Matches($reconcilerSource, [regex]::Escape('"' + $mobileRetiredClosure + '"')).Count -eq 1) -Message "mobile permission retired wrapper/implementation 必须各在 exact legacy allowlist 出现一次：$mobileRetiredClosure"
}

function Set-TestInheritedFileAcl {
    param([string]$Path)

    $security = Get-Acl -LiteralPath $Path
    $security.SetAccessRuleProtection($false, $true)
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]::new($Path), $security)
}

function New-FixtureCodexHome {
    param(
        [string]$Root,
        [ValidateSet("Drift", "MalformedHooks", "DuplicateSerena", "MissingSerenaArgs", "MissingSerenaCommand", "HermesCommandDrift", "SingleQuotedSerenaArgs", "EmptySerenaSectionAtEof", "DuplicateSerenaArgs", "DuplicateSerenaCommand", "MalformedSerenaArgs", "MissingSerenaContext", "MissingSerenaContextValue", "WrongSerenaContext", "DuplicateSerenaContext", "LegacySerenaContext", "NegatedSerenaPolicy", "InvalidSerenaContextPolicy", "MalformedSerenaIndent", "BareCrSerenaContext", "NullSerenaScalar", "DuplicateSerenaMarker", "ExternalSerenaMarker", "QuotedSerenaScalar", "QuotedSerenaListScalar", "DuplicateSerenaPrompt", "MissingSerenaProjectValue", "DuplicateHookSection", "DuplicateQuotedApproval", "RootDottedHookKey", "SensitiveInvalidHeader", "MissingApproval", "MultilineToml", "InvalidUnmanagedToml", "InvalidUtf8Toml", "BomToml")]
        [string]$Variant = "Drift"
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Set-Content -LiteralPath (Join-Path $Root ".codex-host-hook-reconciliation-fixture") -Value "codex-host-hook-reconciliation-fixture-v1" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Root ".fixture-user-environment.json") -Value '{"SERENA_HOME":"D:\\hermes-data\\.serena"}' -Encoding UTF8
    $hookDirectory = Join-Path $Root "hooks"
    New-Item -ItemType Directory -Force -Path $hookDirectory | Out-Null

    $config = @'
model = "fixture-model-must-survive"
fixture_unicode = "中文必须通过"
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
    } elseif ($Variant -eq "MissingSerenaCommand") {
        $config = $config -replace '(?m)^command\s*=.*\r?\n', ''
    } elseif ($Variant -eq "HermesCommandDrift") {
        $config = $config -replace '(?m)^command\s*=.*$', 'command = "D:\\hermes-data\\serena-wrapper.cmd"'
    } elseif ($Variant -eq "SingleQuotedSerenaArgs") {
        $literalContext = $serenaContextPath
        $config = $config -replace '(?m)^args\s*=.*$', "args = ['start-mcp-server', '--context=$literalContext', '--enable-web-dashboard=true', '--open-web-dashboard=false']"
    } elseif ($Variant -eq "DuplicateSerenaArgs") {
        $config = $config -replace '(?m)^(args\s*=.*)$', ('$1' + "`n" + '$1')
    } elseif ($Variant -eq "DuplicateSerenaCommand") {
        $config = $config -replace '(?m)^(command\s*=.*)$', ('$1' + "`n" + '$1')
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
    } elseif ($Variant -eq "InvalidUnmanagedToml") {
        $config += "`n[fixture.invalid]`nunmanaged = [`n"
    } elseif ($Variant -eq "EmptySerenaSectionAtEof") {
        $config = @'
model = "fixture-model-must-survive"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
fixture_root_sentinel = "must-survive"

[features]
hooks = false
unified_exec = false
fixture_feature_sentinel = true

[fixture.unknown]
value = "must-survive"

[mcp_servers.serena]
'@.TrimEnd("`r", "`n")
    }

    $configPath = Join-Path $Root "config.toml"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    if ($Variant -eq "InvalidUtf8Toml") {
        $prefix = $utf8.GetBytes('fixture_invalid_utf8 = "')
        $suffix = $utf8.GetBytes("`"`n$config")
        $bytes = [byte[]]::new($prefix.Length + 1 + $suffix.Length)
        [array]::Copy($prefix, 0, $bytes, 0, $prefix.Length)
        $bytes[$prefix.Length] = 0xFF
        [array]::Copy($suffix, 0, $bytes, $prefix.Length + 1, $suffix.Length)
        [System.IO.File]::WriteAllBytes($configPath, $bytes)
    } elseif ($Variant -eq "BomToml") {
        [byte[]]$bytes = @([byte]0xEF, [byte]0xBB, [byte]0xBF) + @($utf8.GetBytes($config))
        [System.IO.File]::WriteAllBytes($configPath, $bytes)
    } else {
        [System.IO.File]::WriteAllText($configPath, $config, $utf8)
    }

    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($serenaContextPath)) | Out-Null
    $serenaContext = if ($Variant -eq "LegacySerenaContext") {
@'
description: Legacy Codex file tools context
included_tools:
  - read_file
  - list_dir
excluded_tools:
  - execute_shell_command
prompt: |
  Keep the existing file tool guidance unchanged.
'@
    } elseif ($Variant -eq "NegatedSerenaPolicy") {
@'
description: Negated policy must not count as healthy
prompt: |
  Ignore the following quoted policy:
  "Before using any project-scoped Serena tool in a repository task, explicitly call activate_project with the absolute current workspace or repository root from Codex's environment_context, then verify the result with get_current_config. Never infer the task project from Serena's initial active project or from the Serena process working directory."
'@
    } elseif ($Variant -eq "InvalidSerenaContextPolicy") {
@'
prompt: >
  Folded or scalar prompt forms are ambiguous for targeted policy repair.
'@
    } elseif ($Variant -eq "MalformedSerenaIndent") {
@'
description: malformed indentation
included_tools:
 - read_file
prompt: |
  Existing prompt.
'@
    } elseif ($Variant -eq "BareCrSerenaContext") {
        "prompt: |`r  prompt-before-bare-cr`rmetadata: {}"
    } elseif ($Variant -eq "NullSerenaScalar") {
@'
description:
prompt: |
  Existing prompt.
'@
    } elseif ($Variant -eq "QuotedSerenaScalar") {
@'
description: "unterminated scalar
prompt: |
  Existing prompt.
'@
    } elseif ($Variant -eq "QuotedSerenaListScalar") {
@'
included_tools:
  - 'unterminated-list-item
prompt: |
  Existing prompt.
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
    if ($Variant -eq "DuplicateSerenaPrompt") {
        $serenaContext += "`nprompt: `"override activation policy`"`n"
    } elseif ($Variant -eq "DuplicateSerenaMarker") {
        $serenaContext = @'
prompt: |
  [codex-serena-activation-policy:v1 mandatory]
  Before using any project-scoped Serena tool in a repository task, explicitly call activate_project with the absolute current workspace or repository root from Codex's environment_context, then verify the result with get_current_config. Never infer the task project from Serena's initial active project or from the Serena process working directory.
  [codex-serena-activation-policy:v1 mandatory]
'@
    } elseif ($Variant -eq "ExternalSerenaMarker") {
        $serenaContext = "# [codex-serena-activation-policy:v1 mandatory]`n$serenaContext`n  [codex-serena-activation-policy:v1 mandatory]`n"
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
                    [ordered]@{ matcher = 'startup|resume'; hooks = @([ordered]@{ type = "command"; command = '"D:/Codex/.codex/hooks/serena-activate-guarded.cmd"' }) },
                    [ordered]@{ hooks = @([ordered]@{ type = "command"; command = '"D:/Codex/.codex/hooks/serena-dashboard-guard.cmd"' }) }
                )
                PreToolUse = @(
                    [ordered]@{ matcher = "Bash"; hooks = @([ordered]@{ type = "command"; command = '"D:\Codex\tools\uv\bin\serena-hooks.exe" remind --client=codex' }) },
                    [ordered]@{ matcher = "mcp__serena__.*|mcp__serena\..*"; hooks = @([ordered]@{ type = "command"; command = '"D:\Codex\tools\uv\bin\serena-hooks.exe" auto-approve --client=codex' }) }
                )
                Stop = @([ordered]@{ hooks = @([ordered]@{ type = "command"; command = '"D:\Codex\tools\uv\bin\serena-hooks.exe" cleanup --client=codex' }) })
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
        [string]$CodexHome,
        [string]$EvidencePath
    )

    $arguments = @{ Mode=$Mode; CodexHome=$CodexHome; Json=$true }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) { $arguments.EvidencePath = $EvidencePath }
    $raw = & $ScriptPath @arguments
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
$testRoot = Join-Path $ProjectRoot ".scratch\host-hook-reconciliation-tests-$testRunId"
$ownershipMarker = Join-Path $testRoot ".owned-by-test-$testRunId"

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "找不到待实现的冷路径修复器：$scriptPath"

try {
    Assert-SafeTestRoot -Path $testRoot
    Assert-True -Condition (-not (Test-Path -LiteralPath $testRoot)) -Message "唯一测试目录意外已存在：$testRoot"
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    Set-Content -LiteralPath $ownershipMarker -Value $testRunId -Encoding UTF8

    $manifestGateRoot = Join-Path $testRoot 'manifest-gate-canary'
    $manifestGateLib = Join-Path $manifestGateRoot 'lib'
    New-Item -ItemType Directory -Force -Path $manifestGateLib | Out-Null
    $isolatedReconcilerPath = Join-Path $manifestGateRoot 'Invoke-CodexHostHookReconciliation.ps1'
    Copy-Item -LiteralPath $scriptPath -Destination $isolatedReconcilerPath
    [IO.File]::WriteAllText(
        (Join-Path $manifestGateLib 'CodexHookPolicy.ps1'),
        "function Read-CodexHookHostPreflightManifest { throw 'host-preflight manifest identity 漂移：isolated-canary' }`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    $manifestGateError = $null
    try {
        & $isolatedReconcilerPath -Mode Check -CodexHome (Join-Path $testRoot 'must-not-be-read\.codex') -Json | Out-Null
    } catch {
        $manifestGateError = $_.Exception.Message
    }
    Assert-True `
        -Condition ($manifestGateError -ceq 'host-preflight manifest identity 漂移：isolated-canary') `
        -Message "reconciler 必须在读取/处理 live state 前执行 host manifest gate，实际错误：$manifestGateError"

    $healthyHome = Join-Path $testRoot "drift\.codex"
    New-FixtureCodexHome -Root $healthyHome
    $serenaContextDirectory = Join-Path ([System.IO.Directory]::GetParent($healthyHome).FullName) ".serena\contexts"
    $serenaSiblingPath = Join-Path $serenaContextDirectory "other-context.yml"
    Set-Content -LiteralPath $serenaSiblingPath -Value "prompt: sibling-context-must-survive" -Encoding UTF8
    $serenaContextDirectoryAclBefore = (Get-Acl -LiteralPath $serenaContextDirectory).Sddl
    $serenaSiblingAclBefore = (Get-Acl -LiteralPath $serenaSiblingPath).Sddl
    $serenaSiblingHashBefore = Get-Sha256 -Path $serenaSiblingPath
    $configPath = Join-Path $healthyHome "config.toml"
    Set-TestProtectedFileAcl -Path $configPath
    $originalConfigAclSddl = (Get-Acl -LiteralPath $configPath).Sddl
    $unmanagedDirectory = Join-Path $healthyHome "unmanaged"
    $unmanagedDeepDirectory = Join-Path $unmanagedDirectory "deep"
    $unmanagedSentinel = Join-Path $unmanagedDeepDirectory "sentinel.txt"
    New-Item -ItemType Directory -Force -Path $unmanagedDeepDirectory | Out-Null
    Set-Content -LiteralPath $unmanagedSentinel -Value "unmanaged-sentinel" -Encoding UTF8
    $unmanagedAclBefore = [ordered]@{}
    foreach ($path in @($healthyHome, $unmanagedDirectory, $unmanagedDeepDirectory, $unmanagedSentinel)) {
        $unmanagedAclBefore[$path] = (Get-Acl -LiteralPath $path).Sddl
    }

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
    try {
        $env:CODEX_HOST_HOOK_TEST_FORBID_ACL_PATH = Join-Path $healthyHome "hooks\$($legacyNames[0])"
        $repair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_FORBID_ACL_PATH -ErrorAction SilentlyContinue
    }
    Assert-True -Condition ($repair.mode -eq "Repair") -Message "Repair 结果 mode 错误"
    Assert-True -Condition ([bool]$repair.ok) -Message "Repair 未形成健康终态"
    Assert-True -Condition ([bool]$repair.changed) -Message "首次 Repair 应报告 changed=true"
    Assert-True -Condition (Test-Path -LiteralPath $repair.evidencePath -PathType Container) -Message "Repair 未生成 evidence 目录"
    Assert-True -Condition ((Get-Acl -LiteralPath $configPath).Sddl -ceq $originalConfigAclSddl) -Message "语义 Repair 未保持 config.toml 修复前 ACL"

    $hooks = Get-Content -LiteralPath (Join-Path $healthyHome "hooks.json") -Raw | ConvertFrom-Json -AsHashtable
    $hooksRaw = Get-Content -LiteralPath (Join-Path $healthyHome "hooks.json") -Raw
    Assert-True -Condition ([int]$hooks.schemaVersion -eq 7) -Message "hooks.json 未保留未知 schemaVersion"
    Assert-True -Condition ($hooks.owner -eq "fixture-owner") -Message "hooks.json 未保留未知 owner"
    Assert-True -Condition ($hooksRaw -match '"hugeNumber"\s*:\s*1e400') -Message "hooks.json 改写了未知大数值"
    Assert-True -Condition ($hooks.hooks -is [System.Collections.IDictionary]) -Message "hooks 必须是 JSON 对象，不能是数组或 null"
    Assert-True -Condition ($hooks.hooks.Keys.Count -eq 3) -Message "hooks.json 必须只包含三个受管事件"
    Assert-True -Condition (@($hooks.hooks.SessionStart).Count -eq 2) -Message "SessionStart 必须包含 state preflight 与 activation reminder"
    Assert-True -Condition ($hooks.hooks.PreToolUse.matcher -ceq 'Bash') -Message "PreToolUse 必须只注册 Bash reminder"
    Assert-True -Condition (@($hooks.hooks.Stop).Count -eq 1) -Message "Stop 必须只注册 cleanup"

    $config = Get-Content -LiteralPath (Join-Path $healthyHome "config.toml") -Raw
    Assert-True -Condition (-not ($config -match '"--project-from-cwd(?:=|"\s*,)')) -Message "Serena 仍包含不可靠的 --project-from-cwd"
    Assert-True -Condition (-not ($config -match '"--project"\s*,')) -Message "Serena 仍包含固定 --project"
    Assert-True -Condition (-not ($config -match '"--project-file(?:=|"\s*,)')) -Message "Serena 仍包含 --project-file"
    Assert-True -Condition $config.Contains("codex-file-tools.yml") -Message "Serena custom context 被误删"
    foreach ($sentinel in @('fixture-model-must-survive', 'fixture_unicode = "中文必须通过"', 'FIXTURE_ENV_SENTINEL = "must-survive"', 'fixture_feature_sentinel = true', 'array-table-must-survive', 'fixture_network_sentinel = "must-survive"')) {
        Assert-True -Condition $config.Contains($sentinel) -Message "无关 TOML 内容被误删或改写：$sentinel"
    }
    Assert-True -Condition ($config -match '(?m)^approval_policy\s*=\s*"never"\s*$') -Message "approval_policy 未归一化"
    Assert-True -Condition ($config -match '(?m)^sandbox_mode\s*=\s*"danger-full-access"\s*$') -Message "sandbox_mode 未归一化"
    Assert-True -Condition ($config -match '(?m)^hooks\s*=\s*true\s*$') -Message "features.hooks 未保持开启"
    Assert-True -Condition ($config -match '(?m)^unified_exec\s*=\s*true\s*$') -Message "features.unified_exec 未保持开启"
    foreach ($trustedProject in @(
        'D:\Codex\projects\时钟倒计时',
        'D:\Codex\projects\统一环境',
        'D:\Codex\projects\杨杨子',
        'D:\Codex\projects\codex-account-switch',
        'D:\Codex\projects\codex-gsd-codex-c-skill',
        'D:\Codex\projects\CodexProviderSync',
        'D:\Codex\projects\minmin-calendar'
    )) {
        $header = [regex]::Escape("[projects.'$($trustedProject.ToLowerInvariant())']")
        Assert-True -Condition ([regex]::IsMatch($config, "(?m)^$header\s*\r?\ntrust_level\s*=\s*`"trusted`"\s*$")) -Message "项目 trust 未收敛：$trustedProject"
    }
    Assert-True -Condition (-not $config.Contains("[projects.'d:\codex\projects']")) -Message '不得把 projects 集合根设为 trusted'
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
    foreach ($path in @($healthyHome, $configPath)) {
        Assert-True -Condition (@($manifest.aclTargets) -notcontains $path) -Message "manifest.aclTargets 不应包含非托管 ACL：$path"
    }
    foreach ($path in @(
        (Join-Path $healthyHome "hooks.json"),
        (Join-Path $healthyHome "hooks"),
        (Join-Path ([System.IO.Directory]::GetParent($healthyHome).FullName) ".serena\contexts\codex-file-tools.yml")
    )) {
        Assert-True -Condition (@($manifest.aclTargets) -contains $path) -Message "manifest.aclTargets 漏记托管 ACL：$path"
    }
    foreach ($name in $legacyNames) {
        $retiredPath = Join-Path $healthyHome "hooks\$name"
        Assert-True -Condition (@($manifest.aclTargets) -notcontains $retiredPath) -Message "manifest.aclTargets 不得包含待退役路径：$retiredPath"
    }
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
    foreach ($path in @($healthyHome, $unmanagedDirectory, $unmanagedDeepDirectory, $unmanagedSentinel)) {
        Assert-True -Condition (-not $aclBefore.Contains($path)) -Message "acl-before 不应把非托管 CodexHome 路径纳入 ACL 边界：$path"
        Assert-True -Condition ((Get-Acl -LiteralPath $path).Sddl -ceq $unmanagedAclBefore[$path]) -Message "Repair 改写了非托管 CodexHome ACL：$path"
    }
    foreach ($path in @($serenaContextDirectory, $serenaSiblingPath)) {
        Assert-True -Condition (-not $aclBefore.Contains($path)) -Message "acl-before 不应纳入未托管 Serena context 路径：$path"
        Assert-True -Condition (@($manifest.aclTargets) -notcontains $path) -Message "manifest.aclTargets 不应纳入未托管 Serena context 路径：$path"
    }
    Assert-True -Condition ((Get-Acl -LiteralPath $serenaContextDirectory).Sddl -ceq $serenaContextDirectoryAclBefore) -Message "Repair 改写了 Serena contexts 目录 ACL"
    Assert-True -Condition ((Get-Acl -LiteralPath $serenaSiblingPath).Sddl -ceq $serenaSiblingAclBefore) -Message "Repair 改写了 sibling Serena context ACL"
    Assert-True -Condition ((Get-Sha256 -Path $serenaSiblingPath) -eq $serenaSiblingHashBefore) -Message "Repair 改写了 sibling Serena context 内容"
    foreach ($item in @(Get-Item -LiteralPath $repair.evidencePath -Force) + @(Get-ChildItem -LiteralPath $repair.evidencePath -Recurse -Force)) {
        Assert-OnlyAllowedWriters -Path $item.FullName
    }
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $healthyHome "hooks\keep-me.txt")) -eq $unknownFileHash) -Message "未知 hook 文件被删除或改写"
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $healthyHome "hooks\unknown-nested\keep.bin")) -eq $unknownNestedHash) -Message "未知嵌套 hook 文件被删除或改写"

    foreach ($path in @((Join-Path $healthyHome "hooks.json"), (Join-Path $healthyHome "hooks"))) {
        Assert-OnlyAllowedWriters -Path $path
    }
    Assert-OnlyAllowedWriters -Path (Join-Path ([System.IO.Directory]::GetParent($healthyHome).FullName) ".serena\contexts\codex-file-tools.yml")

    $legacyContextHome = Join-Path $testRoot "legacy-serena-context\.codex"
    New-FixtureCodexHome -Root $legacyContextHome -Variant "LegacySerenaContext"
    $legacyContextPath = Join-Path ([System.IO.Directory]::GetParent($legacyContextHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $legacyContextSiblingPath = Join-Path ([System.IO.Path]::GetDirectoryName($legacyContextPath)) "legacy-sibling.yml"
    [System.IO.File]::WriteAllText($legacyContextSiblingPath, "description: sibling-must-survive`n", [System.Text.UTF8Encoding]::new($false))
    $legacyContextSiblingHash = Get-Sha256 -Path $legacyContextSiblingPath
    $legacyContextSiblingAcl = (Get-Acl -LiteralPath $legacyContextSiblingPath).Sddl
    $legacyContextBefore = [System.IO.File]::ReadAllText($legacyContextPath)
    $legacyContextBeforeHash = Get-Sha256 -Path $legacyContextPath
    $legacyContextCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $legacyContextHome
    Assert-True -Condition (-not [bool]$legacyContextCheck.ok -and -not [bool](Get-CheckResult -Result $legacyContextCheck -Name "serenaContext").ok) -Message "合法旧 Serena context 的 Check 应报告可修复 drift，而不是 fatal"
    $legacyContextRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $legacyContextHome
    Assert-True -Condition ([bool]$legacyContextRepair.ok -and [bool]$legacyContextRepair.changed) -Message "合法旧 Serena context 未被 Repair 收敛"
    $legacyContextAfter = [System.IO.File]::ReadAllText($legacyContextPath)
    foreach ($sentinel in @("description: Legacy Codex file tools context", "  - read_file", "  - list_dir", "  - execute_shell_command")) {
        Assert-True -Condition $legacyContextAfter.Contains($sentinel) -Message "Serena context Repair 未保留旧 YAML 内容：$sentinel"
    }
    Assert-True -Condition (-not $legacyContextAfter.Contains("Keep the existing file tool guidance unchanged.")) -Message "协调器完整拥有 prompt，不得保留旧 prompt 文本"
    Assert-True -Condition $legacyContextAfter.Contains("Before using any project-scoped Serena tool") -Message "Serena context Repair 未追加规范激活契约"
    Assert-True -Condition ([regex]::Matches($legacyContextAfter, '\[codex-serena-activation-policy:v1 mandatory\]').Count -eq 1) -Message "Serena context Repair 未追加唯一 mandatory marker"
    Assert-True -Condition ((Get-Sha256 -Path $legacyContextSiblingPath) -eq $legacyContextSiblingHash -and (Get-Acl -LiteralPath $legacyContextSiblingPath).Sddl -ceq $legacyContextSiblingAcl) -Message "Serena context Repair 改写了 sibling context 内容或 ACL"
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $legacyContextRepair.evidencePath "codex-file-tools.yml")) -eq $legacyContextBeforeHash) -Message "Serena context evidence 不是修复前快照"
    $legacyContextManifest = Get-Content -Raw -LiteralPath (Join-Path $legacyContextRepair.evidencePath "manifest.json") | ConvertFrom-Json
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$legacyContextManifest.intendedResources.'codex-file-tools.yml')) -Message "manifest intendedResources 漏记 Serena context"
    Assert-True -Condition (@($legacyContextManifest.attemptedResources) -contains "codex-file-tools.yml" -and @($legacyContextManifest.committedResources) -contains "codex-file-tools.yml") -Message "manifest 未记录 Serena context 事务"
    $legacyContextSecondRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $legacyContextHome
    Assert-True -Condition ([bool]$legacyContextSecondRepair.ok -and -not [bool]$legacyContextSecondRepair.changed -and $null -eq $legacyContextSecondRepair.evidencePath) -Message "Serena context 第二次 Repair 不是 no-op"

    $contextRollbackHome = Join-Path $testRoot "context-rollback\.codex"
    New-FixtureCodexHome -Root $contextRollbackHome -Variant "LegacySerenaContext"
    $contextRollbackPath = Join-Path ([System.IO.Directory]::GetParent($contextRollbackHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $contextRollbackContentBefore = [System.IO.File]::ReadAllText($contextRollbackPath)
    $contextRollbackAclBefore = (Get-Acl -LiteralPath $contextRollbackPath).Sddl
    $contextRollbackConfigPath = Join-Path $contextRollbackHome "config.toml"
    $contextRollbackLock = [System.IO.File]::Open($contextRollbackConfigPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $contextRollbackThrew = $false
    try {
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $contextRollbackHome | Out-Null
    } catch {
        $contextRollbackThrew = $true
    } finally {
        $contextRollbackLock.Dispose()
    }
    Assert-True -Condition $contextRollbackThrew -Message "Serena context 后续 config 失败未触发事务回滚"
    Assert-True -Condition ([System.IO.File]::ReadAllText($contextRollbackPath) -ceq $contextRollbackContentBefore) -Message "三资源失败未精确回滚 Serena context 内容"
    Assert-True -Condition ((Get-Acl -LiteralPath $contextRollbackPath).Sddl -ceq $contextRollbackAclBefore) -Message "三资源失败未精确回滚 Serena context ACL"
    $contextRollbackEvidence = @(Get-ChildItem -LiteralPath (Join-Path $contextRollbackHome "run-evidence\host-hook-remediation") -Directory -Force)
    $contextRollbackManifest = Get-Content -Raw -LiteralPath (Join-Path $contextRollbackEvidence[0].FullName "manifest.json") | ConvertFrom-Json
    Assert-True -Condition ($contextRollbackManifest.status -eq "rolled-back" -and @($contextRollbackManifest.attemptedResources) -contains "codex-file-tools.yml" -and @($contextRollbackManifest.committedResources) -contains "codex-file-tools.yml") -Message "三资源失败 manifest 未记录 Serena context 提交与完整回滚"

    $contextConcurrentHome = Join-Path $testRoot "context-concurrent\.codex"
    New-FixtureCodexHome -Root $contextConcurrentHome -Variant "LegacySerenaContext"
    $contextConcurrentPath = Join-Path ([System.IO.Directory]::GetParent($contextConcurrentHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $contextConcurrentThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE = $contextConcurrentPath
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $contextConcurrentHome | Out-Null
    } catch {
        $contextConcurrentThrew = $true
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $contextConcurrentThrew -Message "Serena context 并发替换未 fail closed"
    $contextConcurrentEvidence = @(Get-ChildItem -LiteralPath (Join-Path $contextConcurrentHome "run-evidence\host-hook-remediation") -Directory -Force)
    $contextConcurrentManifest = Get-Content -Raw -LiteralPath (Join-Path $contextConcurrentEvidence[0].FullName "manifest.json") | ConvertFrom-Json
    Assert-True -Condition ($contextConcurrentManifest.status -eq "unsafe-partial" -and $contextConcurrentManifest.concurrentReplace.path -eq $contextConcurrentPath) -Message "Serena context 并发替换未标记 unsafe-partial"
    Assert-True -Condition ([System.IO.File]::ReadAllText($contextConcurrentManifest.concurrentReplace.backupPath) -ceq "# fixture concurrent replacement`n") -Message "Serena context 并发版本未保存在 replacement backup"

    $unauthorizedHome = Join-Path $testRoot "unauthorized-marker\nested\.codex"
    New-FixtureCodexHome -Root $unauthorizedHome -Variant "LegacySerenaContext"
    $unauthorizedSiblingPath = Join-Path ([System.IO.Directory]::GetParent($unauthorizedHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $unauthorizedSiblingBefore = [System.IO.File]::ReadAllText($unauthorizedSiblingPath)
    $unauthorizedBefore = Get-TreeFingerprint -CodexHome $unauthorizedHome
    $unauthorizedThrew = $false
    try { Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $unauthorizedHome | Out-Null } catch { $unauthorizedThrew = $true }
    Assert-True -Condition $unauthorizedThrew -Message "fixture marker 绕过了 .scratch 专用测试根授权"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $unauthorizedHome) -eq $unauthorizedBefore) -Message "未授权 marker home 被 Repair 修改"
    Assert-True -Condition ([System.IO.File]::ReadAllText($unauthorizedSiblingPath) -ceq $unauthorizedSiblingBefore) -Message "未授权 marker home 导致 sibling context 被读取后改写"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $unauthorizedHome "run-evidence"))) -Message "未授权 marker home 在授权前产生 evidence"

    $trailingChildHome = Join-Path $testRoot "trailing-child\.codex\child"
    New-FixtureCodexHome -Root $trailingChildHome -Variant "LegacySerenaContext"
    $trailingChildBefore = Get-TreeFingerprint -CodexHome $trailingChildHome
    $trailingChildThrew = $false
    try { Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $trailingChildHome | Out-Null } catch { $trailingChildThrew = $true }
    Assert-True -Condition $trailingChildThrew -Message "fixture auth 接受了 .codex\\child trailing path"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $trailingChildHome) -eq $trailingChildBefore -and -not (Test-Path -LiteralPath (Join-Path $trailingChildHome "run-evidence"))) -Message "trailing child 越权 fixture 被修改或产生 evidence"
    $scriptText = Get-Content -Raw -LiteralPath $scriptPath
    $repairAuthorizationIndex = $scriptText.IndexOf('Assert-RepairHomeAuthorized -ResolvedCodexHome $resolvedHome', [System.StringComparison]::Ordinal)
    $repairStateIndex = $scriptText.IndexOf('$state = Get-ReconciliationState -ResolvedCodexHome $resolvedHome', $repairAuthorizationIndex, [System.StringComparison]::Ordinal)
    Assert-True -Condition ($repairAuthorizationIndex -ge 0 -and $repairStateIndex -gt $repairAuthorizationIndex) -Message "Repair 授权必须发生在任何 sibling context 状态读取前"
    Assert-True -Condition $scriptText.Contains('^host-hook-reconciliation-tests-[0-9a-f]{32}') -Message "静态授权门未固定 .scratch 专用测试根，D:\Codex\fake-home 可能被 marker 绕过"

    $negatedContextHome = Join-Path $testRoot "negated-serena-policy\.codex"
    New-FixtureCodexHome -Root $negatedContextHome -Variant "NegatedSerenaPolicy"
    $negatedContextPath = Join-Path ([System.IO.Directory]::GetParent($negatedContextHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $negatedRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $negatedContextHome
    $negatedAfter = [System.IO.File]::ReadAllText($negatedContextPath)
    Assert-True -Condition ([bool]$negatedRepair.ok -and [regex]::Matches($negatedAfter, '\[codex-serena-activation-policy:v1 mandatory\]').Count -eq 1) -Message "否定/引用契约未被视为 drift 并追加 canonical marker"
    Assert-True -Condition (-not $negatedAfter.Contains('Ignore the following quoted policy:')) -Message "否定/引用旧 prompt 应被 canonical block 完整替换"

    $mixedContextHome = Join-Path $testRoot "mixed-newline-serena-context\.codex"
    New-FixtureCodexHome -Root $mixedContextHome -Variant "LegacySerenaContext"
    $mixedContextPath = Join-Path ([System.IO.Directory]::GetParent($mixedContextHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $mixedPrefix = "description: mixed-newlines-must-survive`r`nincluded_tools:`r`n  - read_file`r`nprompt: |`n"
    $mixedSuffix = "metadata: {}`r`n"
    [System.IO.File]::WriteAllText($mixedContextPath, $mixedPrefix + "  old-guidance-must-be-replaced`n" + $mixedSuffix, [System.Text.UTF8Encoding]::new($false))
    $mixedRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $mixedContextHome
    $mixedAfter = [System.IO.File]::ReadAllText($mixedContextPath)
    Assert-True -Condition ([bool]$mixedRepair.ok -and $mixedAfter.StartsWith($mixedPrefix, [System.StringComparison]::Ordinal) -and $mixedAfter.EndsWith($mixedSuffix, [System.StringComparison]::Ordinal) -and -not $mixedAfter.Contains('old-guidance-must-be-replaced')) -Message "Serena context 替换改写了 prompt 外混合换行或未移除旧 prompt"

    $replacementPath = Join-Path $healthyHome ".config.toml.desktop-replacement"
    try {
        [System.IO.File]::WriteAllText($replacementPath, [System.IO.File]::ReadAllText($configPath), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($replacementPath, $configPath, $true)
    } finally {
        if (Test-Path -LiteralPath $replacementPath -PathType Leaf) {
            Remove-Item -LiteralPath $replacementPath -Force
        }
    }
    Assert-True -Condition ((Get-Acl -LiteralPath $configPath).Sddl -cne $originalConfigAclSddl) -Message "vendor 原子替换 canary 未实际改变 config.toml ACL"
    Assert-True -Condition (-not (Get-Acl -LiteralPath $configPath).AreAccessRulesProtected) -Message "vendor 原子替换 canary 未恢复父目录继承 ACL"
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

    $vendorAclSddl = (Get-Acl -LiteralPath $configPath).Sddl
    $vendorDriftedConfig = [System.IO.File]::ReadAllText($configPath).Replace('approval_policy = "never"', 'approval_policy = "on-request"')
    [System.IO.File]::WriteAllText($configPath, $vendorDriftedConfig, [System.Text.UTF8Encoding]::new($false))
    $vendorDriftCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
    Assert-True -Condition (-not [bool](Get-CheckResult -Result $vendorDriftCheck -Name "config").ok) -Message "vendor 语义漂移未让 config 检查变红"
    foreach ($name in @("registrations", "legacyImplementations", "acl")) {
        Assert-True -Condition ([bool](Get-CheckResult -Result $vendorDriftCheck -Name $name).ok) -Message "vendor 语义漂移误伤无关检查项：$name"
    }
    $vendorRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    Assert-True -Condition ([bool]$vendorRepair.ok -and [bool]$vendorRepair.changed) -Message "vendor 语义漂移未被 Repair 修复"
    Assert-True -Condition ((Get-Acl -LiteralPath $configPath).Sddl -ceq $vendorAclSddl) -Message "vendor 语义 Repair 改变了 config.toml 既有 ACL"

    $hooksPath = Join-Path $healthyHome "hooks.json"
    $weakenedHooksAcl = [System.Security.AccessControl.FileSecurity]::new()
    $weakenedHooksAcl.SetSecurityDescriptorBinaryForm(
        (Get-Acl -LiteralPath $hooksPath).GetSecurityDescriptorBinaryForm(),
        [System.Security.AccessControl.AccessControlSections]::Access
    )
    $weakenedHooksAcl.SetAccessRuleProtection($false, $true)
    [System.IO.FileSystemAclExtensions]::SetAccessControl(
        [System.IO.FileInfo]::new($hooksPath),
        $weakenedHooksAcl
    )
    $hooksAclDriftCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
    Assert-True -Condition (-not [bool](Get-CheckResult -Result $hooksAclDriftCheck -Name "acl").ok) -Message "hooks.json ACL 放宽后 acl 检查未变红"
    $hooksAclRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    Assert-True -Condition ([bool]$hooksAclRepair.ok -and [bool]$hooksAclRepair.changed) -Message "hooks.json ACL drift 未被 Repair 修复"
    Assert-OnlyAllowedWriters -Path $hooksPath

    $inheritedAclHome = Join-Path $testRoot "inherited-config-acl\.codex"
    New-FixtureCodexHome -Root $inheritedAclHome
    $inheritedConfigPath = Join-Path $inheritedAclHome "config.toml"
    $inheritedConfigAclBefore = (Get-Acl -LiteralPath $inheritedConfigPath).Sddl
    Assert-True -Condition (-not (Get-Acl -LiteralPath $inheritedConfigPath).AreAccessRulesProtected) -Message "继承型 config ACL canary 前置条件不成立"
    $inheritedAclRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $inheritedAclHome
    Assert-True -Condition ([bool]$inheritedAclRepair.ok -and [bool]$inheritedAclRepair.changed) -Message "继承型 config ACL fixture 未成功 Repair"
    Assert-True -Condition ((Get-Acl -LiteralPath $inheritedConfigPath).Sddl -ceq $inheritedConfigAclBefore) -Message "Repair 改写了普通继承型 config ACL control flags"

    $protectedRestoreHome = Join-Path $testRoot 'protected-config-restore-acl\.codex'
    New-FixtureCodexHome -Root $protectedRestoreHome -Variant 'MissingSerenaArgs'
    $protectedRestoreConfig = Join-Path $protectedRestoreHome 'config.toml'
    Set-TestProtectedFileAcl -Path $protectedRestoreConfig
    $protectedRestoreSddl = (Get-Acl -LiteralPath $protectedRestoreConfig).Sddl
    try { $protectedRestoreRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $protectedRestoreHome }
    catch {
        $debugManifest = Get-ChildItem -LiteralPath (Join-Path $protectedRestoreHome 'run-evidence\host-hook-remediation') -Filter manifest.json -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $debugError = if ($null -eq $debugManifest) { 'no evidence' } else { (Get-Content -Raw -LiteralPath $debugManifest.FullName | ConvertFrom-Json).error }
        throw "protected config Repair failed: $debugError"
    }
    Assert-True -Condition ((Get-Acl -LiteralPath $protectedRestoreConfig).Sddl -ceq $protectedRestoreSddl) -Message 'protected config Repair 必须保持事务前 ACL'
    try { $protectedRestoreResult = Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $protectedRestoreHome -EvidencePath ([string]$protectedRestoreRepair.evidencePath) }
    catch {
        $debugManifest = Get-Content -Raw -LiteralPath (Join-Path ([string]$protectedRestoreRepair.evidencePath) 'manifest.json') | ConvertFrom-Json
        throw "protected config Restore failed: $($_.Exception.Message) evidence=$($debugManifest.error) status=$($debugManifest.status) blocked=$(@($debugManifest.restoreBlocked)-join ',')"
    }
    Assert-True -Condition ([bool]$protectedRestoreResult.ok -and [bool]$protectedRestoreResult.changed) -Message 'protected config Restore 未成功'
    Assert-True -Condition ((Get-Acl -LiteralPath $protectedRestoreConfig).Sddl -ceq $protectedRestoreSddl) -Message 'protected config Restore 未精确恢复事务前 ACL'
    Set-TestInheritedFileAcl -Path $protectedRestoreConfig
    Assert-True -Condition ((Get-Acl -LiteralPath $protectedRestoreConfig).Sddl -cne $protectedRestoreSddl) -Message 'content same-bytes different-ACL fixture 未形成真实漂移'
    $protectedRestoreAclDriftThrew = $false
    try { Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $protectedRestoreHome -EvidencePath ([string]$protectedRestoreRepair.evidencePath) | Out-Null } catch { $protectedRestoreAclDriftThrew = $true }
    Assert-True -Condition $protectedRestoreAclDriftThrew -Message 'content same-bytes different-ACL 不得通过 restored shortcut/final postcheck'

    $legacyAclRestoreHome = Join-Path $testRoot 'legacy-file-restore-acl\.codex'
    New-FixtureCodexHome -Root $legacyAclRestoreHome
    $legacyAclRestorePath = Join-Path $legacyAclRestoreHome "hooks\$($legacyNames[0])"
    Set-TestProtectedFileAcl -Path $legacyAclRestorePath
    $legacyAclRestoreSddl = (Get-Acl -LiteralPath $legacyAclRestorePath).Sddl
    try { $legacyAclRestoreRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $legacyAclRestoreHome }
    catch { throw 'explicit ACL legacy Repair failed' }
    try { $legacyAclRestoreResult = Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $legacyAclRestoreHome -EvidencePath ([string]$legacyAclRestoreRepair.evidencePath) }
    catch {
        $debugManifest = Get-Content -Raw -LiteralPath (Join-Path ([string]$legacyAclRestoreRepair.evidencePath) 'manifest.json') | ConvertFrom-Json
        throw "explicit ACL legacy Restore failed: $($debugManifest.error) status=$($debugManifest.status) blocked=$(@($debugManifest.restoreBlocked)-join ',')"
    }
    Assert-True -Condition ([bool]$legacyAclRestoreResult.ok -and [bool]$legacyAclRestoreResult.changed) -Message 'explicit ACL legacy file Restore 未成功'
    Assert-True -Condition ((Get-Acl -LiteralPath $legacyAclRestorePath).Sddl -ceq $legacyAclRestoreSddl) -Message 'explicit ACL legacy file Restore 未精确恢复事务前 ACL'
    $legacyFinalDirectoryPath = Join-Path $legacyAclRestoreHome 'hooks\__pycache__'
    $legacyFinalExternal = Join-Path $testRoot 'legacy-final-postcheck-race-external'
    New-Item -ItemType Directory -Path $legacyFinalExternal | Out-Null
    $legacyFinalExternalBefore = Get-TreeFingerprint -CodexHome $legacyFinalExternal
    $legacyFinalRaceThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_RESTORE_LEGACY_DIRECTORY_FINAL_REPLACE = [ordered]@{ targetPath=$legacyFinalDirectoryPath; externalParent=$legacyFinalExternal } | ConvertTo-Json -Compress
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $legacyAclRestoreHome -EvidencePath ([string]$legacyAclRestoreRepair.evidencePath) | Out-Null
    } catch { $legacyFinalRaceThrew = $true }
    finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_LEGACY_DIRECTORY_FINAL_REPLACE -ErrorAction SilentlyContinue }
    Assert-True -Condition $legacyFinalRaceThrew -Message 'legacy final postcheck 目录替换竞态必须被持有中的 directory lease 拒绝'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $legacyFinalExternal) -ceq $legacyFinalExternalBefore) -Message 'legacy final postcheck 目录替换不得触碰外部目录'
    Assert-True -Condition (-not (Test-Path -LiteralPath "$legacyFinalDirectoryPath.fixture-moved")) -Message 'legacy final postcheck 目录替换不得移走认证目录'
    Set-TestInheritedFileAcl -Path $legacyAclRestorePath
    Assert-True -Condition ((Get-Acl -LiteralPath $legacyAclRestorePath).Sddl -cne $legacyAclRestoreSddl) -Message 'legacy same-bytes different-ACL fixture 未形成真实漂移'
    $legacyRestoreAclDriftThrew = $false
    try { Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $legacyAclRestoreHome -EvidencePath ([string]$legacyAclRestoreRepair.evidencePath) | Out-Null } catch { $legacyRestoreAclDriftThrew = $true }
    Assert-True -Condition $legacyRestoreAclDriftThrew -Message 'legacy same-bytes different-ACL 不得通过 restored shortcut/final postcheck'

    $managedAclRollbackHome = Join-Path $testRoot 'managed-file-rollback-acl\.codex'
    New-FixtureCodexHome -Root $managedAclRollbackHome
    $managedAclRollbackPath = Join-Path $managedAclRollbackHome 'hooks\codex-state-preflight.cmd'
    [IO.File]::WriteAllText($managedAclRollbackPath, "@echo off`r`nrem fixture before`r`n", [Text.UTF8Encoding]::new($false))
    Set-TestProtectedFileAcl -Path $managedAclRollbackPath
    $managedAclRollbackHash = Get-Sha256 -Path $managedAclRollbackPath
    $managedAclRollbackSddl = (Get-Acl -LiteralPath $managedAclRollbackPath).Sddl
    $managedAclRollbackLock = [IO.File]::Open((Join-Path $managedAclRollbackHome 'hooks.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $managedAclRollbackThrew = $false
    try { Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $managedAclRollbackHome | Out-Null } catch { $managedAclRollbackThrew = $true } finally { $managedAclRollbackLock.Dispose() }
    Assert-True -Condition $managedAclRollbackThrew -Message 'managed file post-publish failure seam 未触发'
    Assert-True -Condition ((Get-Sha256 -Path $managedAclRollbackPath) -ceq $managedAclRollbackHash) -Message 'managed file 自动回滚未恢复原 bytes'
    Assert-True -Condition ((Get-Acl -LiteralPath $managedAclRollbackPath).Sddl -ceq $managedAclRollbackSddl) -Message 'managed file 自动回滚未精确恢复事务前 ACL'

    $concurrentHome = Join-Path $testRoot "concurrent-config\.codex"
    New-FixtureCodexHome -Root $concurrentHome
    $concurrentConfigPath = Join-Path $concurrentHome "config.toml"
    $concurrentConfigAclBefore = (Get-Acl -LiteralPath $concurrentConfigPath).Sddl
    $concurrentThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE = $concurrentConfigPath
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $concurrentHome | Out-Null
    } catch {
        $concurrentThrew = $true
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $concurrentThrew -Message "config 提交窗口并发写入未让 Repair 失败"
    $concurrentEvidence = @(Get-ChildItem -LiteralPath (Join-Path $concurrentHome "run-evidence\host-hook-remediation") -Directory -Force)
    Assert-True -Condition ($concurrentEvidence.Count -eq 1) -Message "config 并发 canary 必须生成一份 evidence"
    $concurrentManifest = Get-Content -LiteralPath (Join-Path $concurrentEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($concurrentManifest.status -eq "unsafe-partial") -Message "config 并发 manifest 未标记 unsafe-partial"
    Assert-True -Condition (-not [bool]$concurrentManifest.concurrentReplace.backupRestored) -Message "config 并发 backup 不应覆盖 active path"
    Assert-True -Condition (Test-Path -LiteralPath $concurrentManifest.concurrentReplace.backupPath -PathType Leaf) -Message "config 并发 canary 未保留 backup"
    Assert-True -Condition ([System.IO.File]::ReadAllText($concurrentManifest.concurrentReplace.backupPath) -ceq "# fixture concurrent replacement`n") -Message "config 并发 backup 未保留提交窗口版本"
    Assert-True -Condition ((Get-Acl -LiteralPath $concurrentManifest.concurrentReplace.backupPath).Sddl -ceq $concurrentConfigAclBefore) -Message "config 并发 backup 未保留提交窗口 ACL"

    foreach ($failureMode in @("replace", "hash")) {
        $casFailureHome = Join-Path $testRoot "cas-$failureMode\.codex"
        New-FixtureCodexHome -Root $casFailureHome
        $casFailureConfigPath = Join-Path $casFailureHome "config.toml"
        $casFailureThrew = $false
        try {
            $env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE = $casFailureConfigPath
            $env:CODEX_HOST_HOOK_TEST_CAS_FAILURE_MODE = $failureMode
            Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $casFailureHome | Out-Null
        } catch {
            $casFailureThrew = $true
        } finally {
            Remove-Item Env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE -ErrorAction SilentlyContinue
            Remove-Item Env:CODEX_HOST_HOOK_TEST_CAS_FAILURE_MODE -ErrorAction SilentlyContinue
        }
        Assert-True -Condition $casFailureThrew -Message "CAS $failureMode failure seam 未让 Repair 失败"
        $casFailureEvidence = @(Get-ChildItem -LiteralPath (Join-Path $casFailureHome "run-evidence\host-hook-remediation") -Directory -Force)
        $casFailureManifest = Get-Content -LiteralPath (Join-Path $casFailureEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
        Assert-True -Condition ($casFailureManifest.status -eq "unsafe-partial") -Message "CAS $failureMode failure manifest 未标记 unsafe-partial"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$casFailureManifest.concurrentReplace.backupPath)) -Message "CAS $failureMode failure 未记录保留的 backup path"
        Assert-True -Condition (Test-Path -LiteralPath $casFailureManifest.concurrentReplace.backupPath -PathType Leaf) -Message "CAS $failureMode failure 未保留 backup 文件"
        Assert-True -Condition ([System.IO.File]::ReadAllText($casFailureManifest.concurrentReplace.backupPath) -ceq "# fixture concurrent replacement`n") -Message "CAS $failureMode failure backup 不含并发版本"
    }

    $aclConcurrentHome = Join-Path $testRoot "concurrent-config-acl\.codex"
    New-FixtureCodexHome -Root $aclConcurrentHome
    $aclConcurrentConfigPath = Join-Path $aclConcurrentHome "config.toml"
    $aclConcurrentSddlBefore = (Get-Acl -LiteralPath $aclConcurrentConfigPath).Sddl
    $aclConcurrentThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE = $aclConcurrentConfigPath
        $env:CODEX_HOST_HOOK_TEST_CONCURRENT_KIND = "acl"
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $aclConcurrentHome | Out-Null
    } catch {
        $aclConcurrentThrew = $true
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_HOST_HOOK_TEST_CONCURRENT_KIND -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $aclConcurrentThrew -Message "ACL-only 并发未让 Repair 失败"
    $aclConcurrentEvidence = @(Get-ChildItem -LiteralPath (Join-Path $aclConcurrentHome "run-evidence\host-hook-remediation") -Directory -Force)
    $aclConcurrentManifest = Get-Content -LiteralPath (Join-Path $aclConcurrentEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($aclConcurrentManifest.status -eq "unsafe-partial") -Message "ACL-only 并发未标记 unsafe-partial"
    Assert-True -Condition (Test-Path -LiteralPath $aclConcurrentManifest.concurrentReplace.backupPath -PathType Leaf) -Message "ACL-only 并发未保留 backup"
    Assert-True -Condition ((Get-Acl -LiteralPath $aclConcurrentManifest.concurrentReplace.backupPath).Sddl -cne $aclConcurrentSddlBefore) -Message "ACL-only 并发 canary 未实际改变 backup ACL"

    $rollbackCasHome = Join-Path $testRoot "rollback-cas\.codex"
    New-FixtureCodexHome -Root $rollbackCasHome
    $rollbackCasConfigPath = Join-Path $rollbackCasHome "config.toml"
    $rollbackCasHooksPath = Join-Path $rollbackCasHome "hooks.json"
    $rollbackCasLock = [System.IO.File]::Open($rollbackCasHooksPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $rollbackCasThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE = $rollbackCasConfigPath
        $env:CODEX_HOST_HOOK_TEST_CONCURRENT_OCCURRENCE = "2"
        try {
            Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $rollbackCasHome | Out-Null
        } catch {
            $rollbackCasThrew = $true
        }
    } finally {
        $rollbackCasLock.Dispose()
        Remove-Item Env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_HOST_HOOK_TEST_CONCURRENT_OCCURRENCE -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $rollbackCasThrew -Message "rollback CAS conflict 未让 Repair 失败"
    $rollbackCasEvidence = @(Get-ChildItem -LiteralPath (Join-Path $rollbackCasHome "run-evidence\host-hook-remediation") -Directory -Force)
    $rollbackCasManifest = Get-Content -LiteralPath (Join-Path $rollbackCasEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($rollbackCasManifest.status -eq "unsafe-partial") -Message "rollback CAS conflict 未标记 unsafe-partial"
    Assert-True -Condition (@($rollbackCasManifest.rollbackConcurrentReplaces).Count -eq 1) -Message "rollback CAS conflict 未写入 per-resource manifest"
    $rollbackCasBackup = $rollbackCasManifest.rollbackConcurrentReplaces[0].backupPath
    Assert-True -Condition (Test-Path -LiteralPath $rollbackCasBackup -PathType Leaf) -Message "rollback CAS conflict 未保留 backup"
    Assert-True -Condition ([System.IO.File]::ReadAllText($rollbackCasBackup) -ceq "# fixture concurrent replacement`n") -Message "rollback CAS backup 未保留并发版本"

    $rollbackHome = Join-Path $testRoot "rollback\.codex"
    New-FixtureCodexHome -Root $rollbackHome
    $rollbackConfigPath = Join-Path $rollbackHome "config.toml"
    Set-TestProtectedFileAcl -Path $rollbackConfigPath
    $rollbackConfigAclSddl = (Get-Acl -LiteralPath $rollbackConfigPath).Sddl
    $rollbackConfigHash = Get-Sha256 -Path $rollbackConfigPath
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
    Assert-True -Condition ((Get-Acl -LiteralPath $rollbackConfigPath).Sddl -ceq $rollbackConfigAclSddl) -Message "两文件半提交回滚未精确恢复 config.toml ACL"

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

    foreach ($phase in @("acl", "legacy")) {
        $postCommitHome = Join-Path $testRoot "post-commit-$phase-failure\.codex"
        New-FixtureCodexHome -Root $postCommitHome
        $firstAclPath = Join-Path $postCommitHome "hooks.json"
        $firstAclBefore = (Get-Acl -LiteralPath $firstAclPath).Sddl
        $postCommitThrew = $false
        try {
            $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = $phase
            Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $postCommitHome | Out-Null
        } catch {
            $postCommitThrew = $true
        } finally {
            Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
        }
        Assert-True -Condition $postCommitThrew -Message "post-commit $phase fixture 未触发失败"
        $postCommitEvidence = @(Get-ChildItem -LiteralPath (Join-Path $postCommitHome "run-evidence\host-hook-remediation") -Directory -Force)
        Assert-True -Condition ($postCommitEvidence.Count -eq 1) -Message "post-commit $phase failure 必须恰好生成一份 evidence"
        $postCommitManifest = Get-Content -LiteralPath (Join-Path $postCommitEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
        Assert-True -Condition ($postCommitManifest.status -eq "rolled-back") -Message "post-commit $phase failure 未完成统一回滚"
        foreach ($resource in @("config.toml", "hooks.json")) {
            Assert-True -Condition (@($postCommitManifest.committedResources) -contains $resource) -Message "post-commit $phase failure 漏记已提交资源：$resource"
        }
        if ($phase -eq "acl") {
            Assert-True -Condition (@($postCommitManifest.aclTargets).Count -eq 1 -and $postCommitManifest.aclTargets[0] -eq $firstAclPath) -Message "ACL failure seam 未精确记录首个 ACL mutation"
            Assert-True -Condition ((Get-Acl -LiteralPath $firstAclPath).Sddl -ceq $firstAclBefore) -Message "ACL failure seam 未恢复首个 ACL"
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $postCommitHome "hooks\$($legacyNames[0])") -PathType Leaf) -Message "ACL failure seam 不应提前退役 legacy 文件"
        } else {
            Assert-True -Condition (@($postCommitManifest.retiredResources).Count -eq 1 -and $postCommitManifest.retiredResources[0] -eq $legacyNames[0]) -Message "legacy failure seam 未精确记录首个退役 mutation"
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $postCommitHome "hooks\$($legacyNames[0])") -PathType Leaf) -Message "legacy failure seam 未恢复首个已删除 legacy 文件"
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $postCommitHome "hooks\$($legacyNames[1])") -PathType Leaf) -Message "legacy failure seam 多删了后续 legacy 文件"
        }
    }

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
    Assert-True -Condition (@($legacyUnknownManifest.aclTargets) -contains $unknownCachePath) -Message "未知 legacy 目录后代必须作为 preserved path 进入 aclTargets"
    Assert-True -Condition (@($legacyUnknownManifest.aclTargets) -notcontains (Join-Path $legacyUnknownHome "hooks\__pycache__")) -Message "exact retired legacy 目录不得进入 aclTargets"
    Assert-True -Condition (@($legacyUnknownManifest.aclTargets) -notcontains (Join-Path $legacyUnknownHome "hooks\__pycache__\codex-mobile-permission-guard.cpython-313.pyc")) -Message "known retired pyc 不得进入 aclTargets"

    $evidenceRaceHome = Join-Path $testRoot 'evidence-ancestor-race\.codex'
    New-FixtureCodexHome -Root $evidenceRaceHome
    $evidenceRaceExternal = Join-Path $testRoot 'evidence-ancestor-race-external'
    New-Item -ItemType Directory -Path $evidenceRaceExternal | Out-Null
    $evidenceRaceExternalBefore = Get-TreeFingerprint -CodexHome $evidenceRaceExternal
    $evidenceRaceThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_EVIDENCE_ANCESTOR_REPLACE = [ordered]@{ targetParent=(Join-Path $evidenceRaceHome 'run-evidence\host-hook-remediation'); externalParent=$evidenceRaceExternal } | ConvertTo-Json -Compress
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $evidenceRaceHome | Out-Null
    } catch { $evidenceRaceThrew = $true }
    finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_EVIDENCE_ANCESTOR_REPLACE -ErrorAction SilentlyContinue }
    Assert-True -Condition $evidenceRaceThrew -Message 'evidence ancestor replacement seam 必须真实触发并 fail closed'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $evidenceRaceExternal) -ceq $evidenceRaceExternalBefore) -Message 'evidence ancestor replacement 不得写入或改 ACL 到外部目录'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $evidenceRaceHome 'run-evidence\host-hook-remediation.fixture-moved'))) -Message 'evidence ancestor replacement 不得移走受管 evidence root'

    $legacyDirectoryDeleteHome = Join-Path $testRoot 'legacy-directory-delete-race\.codex'
    New-FixtureCodexHome -Root $legacyDirectoryDeleteHome
    $legacyDirectoryDeleteExternal = Join-Path $testRoot 'legacy-directory-delete-race-external'
    New-Item -ItemType Directory -Path $legacyDirectoryDeleteExternal | Out-Null
    $legacyDirectoryDeleteExternalBefore = Get-TreeFingerprint -CodexHome $legacyDirectoryDeleteExternal
    $legacyDirectoryDeleteTarget = Join-Path $legacyDirectoryDeleteHome 'hooks\__pycache__'
    $legacyDirectoryDeleteThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_LEGACY_DIRECTORY_DELETE_REPLACE = [ordered]@{ targetPath=$legacyDirectoryDeleteTarget; externalParent=$legacyDirectoryDeleteExternal } | ConvertTo-Json -Compress
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $legacyDirectoryDeleteHome | Out-Null
    } catch { $legacyDirectoryDeleteThrew = $true }
    finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_LEGACY_DIRECTORY_DELETE_REPLACE -ErrorAction SilentlyContinue }
    Assert-True -Condition $legacyDirectoryDeleteThrew -Message 'legacy empty-directory replacement seam 必须真实触发并 fail closed'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $legacyDirectoryDeleteExternal) -ceq $legacyDirectoryDeleteExternalBefore) -Message 'legacy empty-directory replacement 不得删除或写入外部目录'
    Assert-True -Condition (-not (Test-Path -LiteralPath "$legacyDirectoryDeleteTarget.fixture-moved")) -Message 'legacy empty-directory replacement 不得移走已验证目录'

    $aclCasHome = Join-Path $testRoot 'repair-acl-cas-race\.codex'
    New-FixtureCodexHome -Root $aclCasHome
    $aclCasTarget = Join-Path $aclCasHome 'hooks.json'
    $aclCasThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_ACL_CAS_REPLACE = $aclCasTarget
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $aclCasHome | Out-Null
    } catch { $aclCasThrew = $true }
    finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_ACL_CAS_REPLACE -ErrorAction SilentlyContinue }
    Assert-True -Condition $aclCasThrew -Message 'Repair ACL expected-SDDL race 必须拒绝竞争 ACL'

    $rollbackAclCasHome = Join-Path $testRoot 'rollback-acl-cas-race\.codex'
    New-FixtureCodexHome -Root $rollbackAclCasHome
    $rollbackAclCasTarget = Join-Path $rollbackAclCasHome 'hooks.json'
    $rollbackAclCasThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = 'acl'
        $env:CODEX_HOST_HOOK_TEST_ROLLBACK_ACL_CAS_REPLACE = $rollbackAclCasTarget
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $rollbackAclCasHome | Out-Null
    } catch { $rollbackAclCasThrew = $true }
    finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_HOST_HOOK_TEST_ROLLBACK_ACL_CAS_REPLACE -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $rollbackAclCasThrew -Message 'Repair rollback ACL expected-SDDL race 必须拒绝竞争 ACL'
    $rollbackAclCasEvidence = @(Get-ChildItem -LiteralPath (Join-Path $rollbackAclCasHome 'run-evidence\host-hook-remediation') -Directory -Force)
    $rollbackAclCasManifest = Get-Content -Raw -LiteralPath (Join-Path $rollbackAclCasEvidence[0].FullName 'manifest.json') | ConvertFrom-Json
    Assert-True -Condition ($rollbackAclCasManifest.status -eq 'unsafe-partial') -Message 'rollback ACL CAS 竞争必须标记 unsafe-partial'
    Assert-True -Condition (@($rollbackAclCasManifest.recoveryRequired) -contains "acl:$rollbackAclCasTarget") -Message 'rollback ACL CAS 竞争必须记录 recoveryRequired'

    $legacyCreateRollbackHome = Join-Path $testRoot 'legacy-directory-create-rollback-race\.codex'
    New-FixtureCodexHome -Root $legacyCreateRollbackHome
    $legacyCreateRollbackExternal = Join-Path $testRoot 'legacy-directory-create-rollback-race-external'
    New-Item -ItemType Directory -Path $legacyCreateRollbackExternal | Out-Null
    $legacyCreateRollbackExternalBefore = Get-TreeFingerprint -CodexHome $legacyCreateRollbackExternal
    $legacyCreateRollbackTarget = Join-Path $legacyCreateRollbackHome 'hooks\__pycache__'
    $legacyCreateRollbackThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = 'final'
        $env:CODEX_HOST_HOOK_TEST_LEGACY_DIRECTORY_CREATE_REPLACE = [ordered]@{ targetPath=$legacyCreateRollbackTarget; externalParent=$legacyCreateRollbackExternal } | ConvertTo-Json -Compress
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $legacyCreateRollbackHome | Out-Null
    } catch { $legacyCreateRollbackThrew = $true }
    finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_HOST_HOOK_TEST_LEGACY_DIRECTORY_CREATE_REPLACE -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $legacyCreateRollbackThrew -Message 'legacy rollback create replacement seam 必须触发失败'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $legacyCreateRollbackExternal) -ceq $legacyCreateRollbackExternalBefore) -Message 'legacy rollback create replacement 不得写外部 ACL'
    Assert-True -Condition (-not (Test-Path -LiteralPath "$legacyCreateRollbackTarget.fixture-moved")) -Message 'legacy rollback create replacement 不得移走受管目录'

    $legacyCreateRestoreHome = Join-Path $testRoot 'legacy-directory-create-restore-race\.codex'
    New-FixtureCodexHome -Root $legacyCreateRestoreHome
    $legacyCreateRestoreRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $legacyCreateRestoreHome
    $legacyCreateRestoreExternal = Join-Path $testRoot 'legacy-directory-create-restore-race-external'
    New-Item -ItemType Directory -Path $legacyCreateRestoreExternal | Out-Null
    $legacyCreateRestoreExternalBefore = Get-TreeFingerprint -CodexHome $legacyCreateRestoreExternal
    $legacyCreateRestoreTarget = Join-Path $legacyCreateRestoreHome 'hooks\__pycache__'
    $legacyCreateRestoreThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_LEGACY_DIRECTORY_CREATE_REPLACE = [ordered]@{ targetPath=$legacyCreateRestoreTarget; externalParent=$legacyCreateRestoreExternal } | ConvertTo-Json -Compress
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $legacyCreateRestoreHome -EvidencePath ([string]$legacyCreateRestoreRepair.evidencePath) | Out-Null
    } catch { $legacyCreateRestoreThrew = $true }
    finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_LEGACY_DIRECTORY_CREATE_REPLACE -ErrorAction SilentlyContinue }
    Assert-True -Condition $legacyCreateRestoreThrew -Message 'legacy manual Restore create replacement seam 必须触发失败'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $legacyCreateRestoreExternal) -ceq $legacyCreateRestoreExternalBefore) -Message 'legacy manual Restore create replacement 不得写外部 ACL'
    Assert-True -Condition (-not (Test-Path -LiteralPath "$legacyCreateRestoreTarget.fixture-moved")) -Message 'legacy manual Restore create replacement 不得移走受管目录'

    # Run the manifest race before content races so both independent RED/GREEN
    # contracts remain observable when either class regresses.
    $restoreManifestAclHome = Join-Path $testRoot 'restore-manifest-acl-race\.codex'
    New-FixtureCodexHome -Root $restoreManifestAclHome
    $restoreManifestAclRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $restoreManifestAclHome
    $restoreManifestAclTarget = Join-Path ([string]$restoreManifestAclRepair.evidencePath) 'manifest.json'
    $restoreManifestAclParked = "$restoreManifestAclTarget.fixture-moved"
    $restoreManifestAclExternal = Join-Path $testRoot 'restore-manifest-acl-external.json'
    Set-Content -LiteralPath $restoreManifestAclExternal -Value '{"external":true}' -Encoding UTF8
    $restoreManifestAclExternalHashBefore = Get-Sha256 -Path $restoreManifestAclExternal
    $restoreManifestAclExternalAclBefore = (Get-Acl -LiteralPath $restoreManifestAclExternal).Sddl
    $restoreManifestAclThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_RESTORE_MANIFEST_ACL_REPLACE = [ordered]@{ targetPath=$restoreManifestAclTarget; parkedPath=$restoreManifestAclParked; externalPath=$restoreManifestAclExternal } | ConvertTo-Json -Compress
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $restoreManifestAclHome -EvidencePath ([string]$restoreManifestAclRepair.evidencePath) | Out-Null
    } catch { $restoreManifestAclThrew = $true }
    finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_MANIFEST_ACL_REPLACE -ErrorAction SilentlyContinue }
    Assert-True -Condition $restoreManifestAclThrew -Message 'Restore manifest capability publish→ACL replacement 必须 fail closed'
    Assert-True -Condition ((Get-Sha256 -Path $restoreManifestAclExternal) -ceq $restoreManifestAclExternalHashBefore) -Message 'Restore manifest replacement 不得改写外部 bytes'
    Assert-True -Condition ((Get-Acl -LiteralPath $restoreManifestAclExternal).Sddl -ceq $restoreManifestAclExternalAclBefore) -Message 'Restore manifest replacement 不得改写外部 ACL'
    Assert-True -Condition (-not (Test-Path -LiteralPath $restoreManifestAclParked)) -Message 'Restore manifest replacement 不得移走 evidence manifest'

    foreach ($restoreContentCase in @(
        [pscustomobject]@{ name='hooks.json'; relativePath='hooks.json' },
        [pscustomobject]@{ name='config.toml'; relativePath='config.toml' },
        [pscustomobject]@{ name='codex-file-tools.yml'; relativePath='..\.serena\contexts\codex-file-tools.yml' }
    )) {
        $restoreContentHome = Join-Path $testRoot "restore-content-parent-$($restoreContentCase.name)\.codex"
        New-FixtureCodexHome -Root $restoreContentHome
        $restoreContentRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $restoreContentHome
        $restoreContentTarget = [IO.Path]::GetFullPath((Join-Path $restoreContentHome ([string]$restoreContentCase.relativePath)))
        $restoreContentParent = [IO.Path]::GetDirectoryName($restoreContentTarget)
        $restoreContentParked = "$restoreContentParent.fixture-moved"
        $restoreContentExternal = Join-Path $testRoot "restore-content-parent-$($restoreContentCase.name)-external"
        New-Item -ItemType Directory -Path $restoreContentExternal | Out-Null
        Set-Content -LiteralPath (Join-Path $restoreContentExternal 'sentinel.txt') -Value 'external-must-not-change' -Encoding UTF8
        $restoreContentExternalBefore = Get-TreeFingerprint -CodexHome $restoreContentExternal
        $restoreContentThrew = $false
        try {
            $env:CODEX_HOST_HOOK_TEST_RESTORE_CONTENT_PARENT_REPLACE = [ordered]@{ targetPath=$restoreContentParent; parkedPath=$restoreContentParked; externalPath=$restoreContentExternal } | ConvertTo-Json -Compress
            Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $restoreContentHome -EvidencePath ([string]$restoreContentRepair.evidencePath) | Out-Null
        } catch { $restoreContentThrew = $true }
        finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_CONTENT_PARENT_REPLACE -ErrorAction SilentlyContinue }
        Assert-True -Condition $restoreContentThrew -Message "Restore $($restoreContentCase.name) parent replacement 必须 fail closed"
        Assert-True -Condition ((Get-TreeFingerprint -CodexHome $restoreContentExternal) -ceq $restoreContentExternalBefore) -Message "Restore $($restoreContentCase.name) parent replacement 不得改写外部 bytes/ACL"
        Assert-True -Condition (-not (Test-Path -LiteralPath $restoreContentParked)) -Message "Restore $($restoreContentCase.name) parent replacement 不得移走受管 parent"
    }

    $forbidOnlyHome = Join-Path $testRoot "forbid-only-seam\.codex"
    New-FixtureCodexHome -Root $forbidOnlyHome
    $forbidOnlyThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_FORBID_ACL_PATH = Join-Path $forbidOnlyHome "hooks\keep-me.txt"
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $forbidOnlyHome | Out-Null
    } catch {
        $forbidOnlyThrew = $true
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_FORBID_ACL_PATH -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $forbidOnlyThrew -Message "仅设置 forbidden ACL env 时 seam 未在 early return 前解析/授权"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $forbidOnlyHome "run-evidence"))) -Message "非法 forbid-only seam 在拒绝前产生 evidence"

    foreach ($serenaConfigCase in @(
        @{ Name = "missing-serena-args-repair"; Variant = "MissingSerenaArgs" },
        @{ Name = "missing-serena-command-repair"; Variant = "MissingSerenaCommand" },
        @{ Name = "hermes-command-drift-repair"; Variant = "HermesCommandDrift" },
        @{ Name = "single-quoted-serena-args-repair"; Variant = "SingleQuotedSerenaArgs" }
    )) {
        $serenaConfigHome = Join-Path $testRoot "$($serenaConfigCase.Name)\.codex"
        New-FixtureCodexHome -Root $serenaConfigHome -Variant $serenaConfigCase.Variant
        $serenaConfigContextPath = Join-Path ([System.IO.Directory]::GetParent($serenaConfigHome).FullName) ".serena\contexts\codex-file-tools.yml"
        $serenaConfigRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $serenaConfigHome
        Assert-True -Condition ([bool]$serenaConfigRepair.ok -and [bool]$serenaConfigRepair.changed) -Message "$($serenaConfigCase.Name) 未被 Repair 收敛"
        $serenaConfigText = Get-Content -Raw -LiteralPath (Join-Path $serenaConfigHome "config.toml")
        Assert-True -Condition ($serenaConfigText -match '(?m)^command\s*=\s*"D:\\\\Codex\\\\\.codex\\\\scripts\\\\start-serena-mcp\.cmd"\s*$') -Message "$($serenaConfigCase.Name) command 未规范为固定 wrapper"
        $argsMatch = [regex]::Match($serenaConfigText, '(?m)^args\s*=\s*(?<rhs>\[.*\])\s*$')
        Assert-True -Condition $argsMatch.Success -Message "$($serenaConfigCase.Name) 缺少 canonical args"
        $argsTokens = @((ConvertFrom-Json -InputObject $argsMatch.Groups['rhs'].Value -NoEnumerate))
        $expectedArgs = @("start-mcp-server", "--context=$serenaConfigContextPath", "--enable-web-dashboard=true", "--open-web-dashboard=false")
        Assert-True -Condition (($argsTokens -join "`n") -ceq ($expectedArgs -join "`n")) -Message "$($serenaConfigCase.Name) args 目标不精确"
        foreach ($sentinel in @('startup_timeout_sec = 60', 'FIXTURE_ENV_SENTINEL = "must-survive"', 'fixture_feature_sentinel = true')) {
            Assert-True -Condition $serenaConfigText.Contains($sentinel) -Message "$($serenaConfigCase.Name) 未保留 Serena/全文件未知 key：$sentinel"
        }
        $serenaConfigSecond = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $serenaConfigHome
        Assert-True -Condition ([bool]$serenaConfigSecond.ok -and -not [bool]$serenaConfigSecond.changed) -Message "$($serenaConfigCase.Name) 第二次 Repair 不是 no-op"
    }

    $emptySerenaHome = Join-Path $testRoot "empty-serena-section-eof\.codex"
    New-FixtureCodexHome -Root $emptySerenaHome -Variant "EmptySerenaSectionAtEof"
    $emptySerenaContextPath = Join-Path ([System.IO.Directory]::GetParent($emptySerenaHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $emptySerenaRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $emptySerenaHome
    Assert-True -Condition ([bool]$emptySerenaRepair.ok -and [bool]$emptySerenaRepair.changed) -Message "EOF 空 Serena section 未被 Repair 收敛"
    $emptySerenaConfig = Get-Content -Raw -LiteralPath (Join-Path $emptySerenaHome "config.toml")
    $emptyCommandCount = [regex]::Matches($emptySerenaConfig, '(?m)^command\s*=').Count
    $emptyArgsCount = [regex]::Matches($emptySerenaConfig, '(?m)^args\s*=').Count
    Assert-True -Condition ($emptyCommandCount -eq 1 -and $emptyArgsCount -eq 1) -Message "EOF 空 Serena section Repair 后 command/args 不是各1：command=$emptyCommandCount args=$emptyArgsCount config=$emptySerenaConfig"
    foreach ($sentinel in @('model = "fixture-model-must-survive"', 'fixture_root_sentinel = "must-survive"', 'fixture_feature_sentinel = true', 'value = "must-survive"')) {
        Assert-True -Condition $emptySerenaConfig.Contains($sentinel) -Message "EOF 插入改写了无关/root 状态：$sentinel"
    }
    $emptySerenaArgs = [regex]::Match($emptySerenaConfig, '(?m)^args\s*=\s*(?<rhs>\[.*\])\s*$').Groups['rhs'].Value | ConvertFrom-Json -NoEnumerate
    Assert-True -Condition (@($emptySerenaArgs).Count -eq 4 -and @($emptySerenaArgs)[1] -ceq "--context=$emptySerenaContextPath") -Message "EOF 空 Serena section canonical args 不精确"
    $emptySerenaSecond = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $emptySerenaHome
    Assert-True -Condition ([bool]$emptySerenaSecond.ok -and -not [bool]$emptySerenaSecond.changed) -Message "EOF 空 Serena section 第二次 Repair 不是 no-op"

    foreach ($case in @(
        @{ Name = "malformed-hooks"; Variant = "MalformedHooks" },
        @{ Name = "duplicate-serena"; Variant = "DuplicateSerena" },
        @{ Name = "duplicate-serena-args"; Variant = "DuplicateSerenaArgs" },
        @{ Name = "duplicate-serena-command"; Variant = "DuplicateSerenaCommand" },
        @{ Name = "malformed-serena-args"; Variant = "MalformedSerenaArgs" },
        @{ Name = "missing-serena-context"; Variant = "MissingSerenaContext" },
        @{ Name = "missing-serena-context-value"; Variant = "MissingSerenaContextValue" },
        @{ Name = "wrong-serena-context"; Variant = "WrongSerenaContext" },
        @{ Name = "duplicate-serena-context"; Variant = "DuplicateSerenaContext" },
        @{ Name = "invalid-serena-context-policy"; Variant = "InvalidSerenaContextPolicy" },
        @{ Name = "malformed-serena-indent"; Variant = "MalformedSerenaIndent" },
        @{ Name = "bare-cr-serena-context"; Variant = "BareCrSerenaContext" },
        @{ Name = "null-serena-scalar"; Variant = "NullSerenaScalar" },
        @{ Name = "duplicate-serena-marker"; Variant = "DuplicateSerenaMarker" },
        @{ Name = "external-serena-marker"; Variant = "ExternalSerenaMarker" },
        @{ Name = "quoted-serena-scalar"; Variant = "QuotedSerenaScalar" },
        @{ Name = "quoted-serena-list-scalar"; Variant = "QuotedSerenaListScalar" },
        @{ Name = "duplicate-serena-prompt"; Variant = "DuplicateSerenaPrompt" },
        @{ Name = "missing-serena-project-value"; Variant = "MissingSerenaProjectValue" },
        @{ Name = "duplicate-hook-section"; Variant = "DuplicateHookSection" },
        @{ Name = "duplicate-quoted-approval"; Variant = "DuplicateQuotedApproval" },
        @{ Name = "root-dotted-hook-key"; Variant = "RootDottedHookKey" },
        @{ Name = "missing-approval"; Variant = "MissingApproval" },
        @{ Name = "multiline-toml"; Variant = "MultilineToml" },
        @{ Name = "invalid-unmanaged-toml"; Variant = "InvalidUnmanagedToml" },
        @{ Name = "invalid-utf8-toml"; Variant = "InvalidUtf8Toml" },
        @{ Name = "bom-toml"; Variant = "BomToml" }
    )) {
        $caseHome = Join-Path $testRoot "$($case.Name)\.codex"
        New-FixtureCodexHome -Root $caseHome -Variant $case.Variant
        Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $caseHome -CaseName $case.Name
    }

    $headerLikeArrayHome = Join-Path $testRoot "header-like-array-toml\.codex"
    New-FixtureCodexHome -Root $headerLikeArrayHome
    $headerLikeBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $headerLikeArrayHome
    Assert-True -Condition ([bool]$headerLikeBaselineRepair.ok) -Message "header-like-array 基准 Repair 未形成健康状态"
    $headerLikeConfigPath = Join-Path $headerLikeArrayHome "config.toml"
    $headerLikeConfig = Get-Content -LiteralPath $headerLikeConfigPath -Raw
    Assert-True -Condition (-not ($headerLikeConfig -match '(?m)^\s*\[\s*["'']?hooks["'']?(?:\.|\s*\])')) -Message "header-like-array 基准仍包含真实 hook section"
    $headerLikeConfig += @'

[fixture.header_like_array]
values = [
  ["keep"],
  ["hooks"]
]
'@
    [System.IO.File]::WriteAllText($headerLikeConfigPath, $headerLikeConfig, [System.Text.UTF8Encoding]::new($false))
    & "D:\Codex\tools\python314-official\python.exe" -B -I -S -X utf8 -c 'import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $headerLikeConfigPath
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "header-like-array 输入本身不是合法 TOML"
    Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $headerLikeArrayHome -CaseName "header-like-array-toml"

    $hardLinkHome = Join-Path $testRoot "hard-link\.codex"
    New-FixtureCodexHome -Root $hardLinkHome
    $externalSentinelPath = Join-Path $testRoot "hard-link-external-sentinel.txt"
    Set-Content -LiteralPath $externalSentinelPath -Value "external-hard-link-sentinel" -Encoding UTF8
    $hardLinkPath = Join-Path $hardLinkHome "hooks\linked-sentinel.txt"
    New-Item -ItemType HardLink -Path $hardLinkPath -Target $externalSentinelPath | Out-Null
    $externalSentinelHashBefore = Get-Sha256 -Path $externalSentinelPath
    $externalSentinelAclBefore = (Get-Acl -LiteralPath $externalSentinelPath).Sddl
    Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $hardLinkHome -CaseName "hard-link"
    Assert-True -Condition ((Get-Sha256 -Path $externalSentinelPath) -eq $externalSentinelHashBefore) -Message "hard-link 拒绝路径改写了外部 sentinel 内容"
    Assert-True -Condition ((Get-Acl -LiteralPath $externalSentinelPath).Sddl -ceq $externalSentinelAclBefore) -Message "hard-link 拒绝路径改写了外部 sentinel ACL"

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
        try {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        } catch {
            if (Test-Path -LiteralPath $testRoot) {
                throw
            }
        }
    }
}
