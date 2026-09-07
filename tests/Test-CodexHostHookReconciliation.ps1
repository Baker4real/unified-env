param(
    [string]$ProjectRoot = "D:\agents\projects\统一环境",
    [switch]$KeepOutputs,
    [switch]$OnlyEnvironmentPostCommitRollback,
    [string]$CleanupFixturePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptProjectRoot = [System.IO.Path]::GetFullPath((Split-Path -Path $PSScriptRoot -Parent)).TrimEnd("\", "/")
try {
    $requestedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd("\", "/")
} catch {
    throw "ProjectRoot 无法规范化：$ProjectRoot"
}
if (-not $requestedProjectRoot.Equals($scriptProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ProjectRoot 必须匹配测试文件所在项目根：$scriptProjectRoot"
}
$ProjectRoot = $scriptProjectRoot

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

. (Join-Path $ProjectRoot 'modules\codex-host\CodexHostHookEvidence.ps1')
$liveScope = Resolve-CodexHostHookEvidenceScope -ResolvedCodexHome 'D:\Codex\.codex'
Assert-True -Condition ($liveScope.isLive -eq $true -and $liveScope.isFixture -eq $false) -Message 'live CodexHome 必须解析为 production scope'
Assert-True -Condition ($liveScope.runEvidenceRoot -eq ([IO.Path]::GetFullPath('D:\agents\run-evidence'))) -Message 'live runEvidenceRoot 必须锚定新根'
Assert-True -Condition ($liveScope.remediationRoot -eq ([IO.Path]::GetFullPath('D:\agents\run-evidence\host-hook-remediation'))) -Message 'live remediationRoot 必须锚定新根'
Assert-True -Condition ($liveScope.capabilityRoot -eq $liveScope.runEvidenceRoot) -Message 'live capabilityRoot 必须与 runEvidenceRoot 配对'
$fxHome = 'D:\agents\projects\统一环境\.scratch\host-hook-reconciliation-tests-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\case\.codex'
$fxScope = Resolve-CodexHostHookEvidenceScope -ResolvedCodexHome $fxHome
Assert-True -Condition ($fxScope.isFixture -eq $true -and $fxScope.isLive -eq $false) -Message '非 live CodexHome 必须解析为 fixture scope'
Assert-True -Condition ($fxScope.runEvidenceRoot -eq ([IO.Path]::GetFullPath((Join-Path $fxHome 'run-evidence')))) -Message 'fixture runEvidenceRoot 必须仍派生自 fixture CodexHome'
Assert-True -Condition ($fxScope.capabilityRoot -eq ([IO.Path]::GetFullPath($fxHome))) -Message 'fixture capabilityRoot 必须保持 fixture CodexHome'
$productionPycacheScope = Resolve-CodexHostHookEvidenceScope -ForceProduction
Assert-True -Condition ($productionPycacheScope.runEvidenceRoot -eq ([IO.Path]::GetFullPath('D:\agents\run-evidence'))) -Message 'TOML pycache production scope 必须使用新根'

function Remove-OwnedHostHookReconciliationFixture {
    param([Parameter(Mandatory)][string]$Path)

    $reportsRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot ".scratch")).TrimEnd("\", "/")
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $pattern = '^' + [regex]::Escape($reportsRoot) + '\\host-hook-reconciliation-tests-(?<runId>[0-9a-f]{32})$'
    $match = [regex]::Match($fullPath, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    Assert-True -Condition $match.Success -Message "拒绝清理非专属测试目录：$fullPath"
    Assert-SafeTestRoot -Path $fullPath

    $runId = $match.Groups['runId'].Value
    $ownershipMarker = Join-Path $fullPath ".owned-by-test-$runId"
    Assert-True -Condition (Test-Path -LiteralPath $ownershipMarker -PathType Leaf) -Message "拒绝清理缺少 ownership marker 的测试目录：$fullPath"
    Assert-True -Condition ((Get-Content -LiteralPath $ownershipMarker -Raw).Trim() -ceq $runId) -Message "拒绝清理 ownership marker 不匹配的测试目录：$fullPath"

    $items = @(Get-Item -LiteralPath $fullPath -Force) + @(Get-ChildItem -LiteralPath $fullPath -Recurse -Force)
    foreach ($item in $items) {
        Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "拒绝清理含 reparse point 的测试树：$($item.FullName)"
    }

    Remove-Item -LiteralPath $fullPath -Recurse -Force
    Assert-True -Condition (-not (Test-Path -LiteralPath $fullPath)) -Message "专属测试清理后路径仍存在：$fullPath"
}

function Remove-ProjectRootMismatchFixture {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
        [Parameter(Mandatory)][string]$Path
    )

    # This cleanup path exists only for the negative ProjectRoot-authority
    # regression. It can delete exactly one marker-owned D:\Codex\.scratch
    # fixture root, never an arbitrary caller-supplied project root.
    $negativeBase = [System.IO.Path]::GetFullPath('D:\Codex\.scratch').TrimEnd("\", "/")
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $expectedPath = Join-Path $negativeBase "host-hook-projectroot-mismatch-$RunId"
    Assert-True -Condition ($fullPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) -Message "拒绝清理非显式 ProjectRoot mismatch fixture：$fullPath"
    Assert-True -Condition ([System.IO.Path]::GetPathRoot($fullPath) -eq 'D:\') -Message "ProjectRoot mismatch fixture 必须位于 D 盘：$fullPath"

    $cursor = $fullPath
    while ($cursor.StartsWith($negativeBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "ProjectRoot mismatch fixture 路径不能穿过 reparse point：$cursor"
        }

        if ($cursor.Equals($negativeBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($cursor)
        Assert-True -Condition ($null -ne $parent) -Message "无法解析 ProjectRoot mismatch fixture 父级：$cursor"
        $cursor = $parent.FullName.TrimEnd("\", "/")
    }

    $ownershipMarker = Join-Path $fullPath ".owned-by-projectroot-mismatch-$RunId"
    Assert-True -Condition (Test-Path -LiteralPath $ownershipMarker -PathType Leaf) -Message "拒绝清理缺少 ProjectRoot mismatch ownership marker 的目录：$fullPath"
    Assert-True -Condition ((Get-Content -LiteralPath $ownershipMarker -Raw).Trim() -ceq $RunId) -Message "拒绝清理 ProjectRoot mismatch ownership marker 不匹配的目录：$fullPath"

    $items = @(Get-Item -LiteralPath $fullPath -Force) + @(Get-ChildItem -LiteralPath $fullPath -Recurse -Force)
    foreach ($item in $items) {
        Assert-True -Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -Message "拒绝清理含 reparse point 的 ProjectRoot mismatch fixture：$($item.FullName)"
    }

    Remove-Item -LiteralPath $fullPath -Recurse -Force
    Assert-True -Condition (-not (Test-Path -LiteralPath $fullPath)) -Message "ProjectRoot mismatch fixture 清理后路径仍存在：$fullPath"
}

if (-not [string]::IsNullOrWhiteSpace($CleanupFixturePath)) {
    Remove-OwnedHostHookReconciliationFixture -Path $CleanupFixturePath
    Write-Host "PASS: owned Codex host hook reconciliation fixture cleanup"
    return
}

function Get-Sha256 {
    param([string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Invoke-SilentProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutMilliseconds = 10000
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "静默进程启动失败：$FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill($true) } catch {}
            [void]$process.WaitForExit(1000)
            throw "静默进程超时：$FilePath"
        }
        [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
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

    $matchingChecks = @($Result.checks | Where-Object { $_.name -eq $Name })
    Assert-True -Condition ($matchingChecks.Count -eq 1) -Message "检查项必须恰好出现一次：$Name"
    $matchingChecks[0]
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
$hostPreflightManifest = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'managed\codex-hooks\host-preflight-manifest.json') | ConvertFrom-Json

$reconcilerSource = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot "scripts\Invoke-CodexHostHookReconciliation.ps1")
Assert-True -Condition ($reconcilerSource.Contains('Read-CodexHookHostPreflightManifest')) -Message '生产 reconciler 必须读取固定 host-preflight manifest 作为唯一 ownership 边界'
Assert-True -Condition (-not $reconcilerSource.Contains('legacy-fixture-manifest.json')) -Message '生产 reconciler 不得读取 legacy fixture manifest'
$managedRollbackOrderingPattern = '(?m)^\s*\$managedRollbackStates = @\(Get-OrderedManagedHookItems -Items @\(\$InitialState\.managedFileStates \| Where-Object \{ \$attempted\.Contains\("managed:\$\(\$_.liveRelativePath\)"\) \}\) -Direction Restore\)\r?\n\s*foreach \(\$fileState in \$managedRollbackStates\) \{'
Assert-True -Condition ([regex]::Matches($reconcilerSource, $managedRollbackOrderingPattern).Count -eq 2) -Message 'Repair 的 transaction catch 与 post-commit catch 必须各自先筛 attempted managed files，再按 Restore 顺序回滚'
$unorderedManagedRollbackPattern = 'foreach \(\$fileState in @\(\$InitialState\.managedFileStates \| Where-Object \{ \$attempted\.Contains\("managed:\$\(\$_.liveRelativePath\)"\) \}\)\)'
Assert-True -Condition (-not [regex]::IsMatch($reconcilerSource, $unorderedManagedRollbackPattern)) -Message 'Repair rollback 不得直接按 manifest 顺序遍历 attempted managed files'
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
        [ValidateSet("Drift", "MalformedHooks", "LegacySerenaContext", "NegatedSerenaPolicy", "InvalidSerenaContextPolicy", "MalformedSerenaIndent", "BareCrSerenaContext", "NullSerenaScalar", "DuplicateSerenaMarker", "ExternalSerenaMarker", "QuotedSerenaScalar", "QuotedSerenaListScalar", "DuplicateSerenaPrompt")]
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

[mcp_servers.serena]
startup_timeout_sec = 60
command = "D:\\Codex\\tools\\uv\\bin\\serena.exe"
args = [ "start-mcp-server", "--context=D:\\Codex\\.serena\\contexts\\codex-file-tools.yml", "--project-from-cwd", "--project", "D:\\Codex\\projects\\yangyangzi-direct-qqbot", "--enable-web-dashboard=true", "--open-web-dashboard=false" ]

[mcp_servers.serena.env]
SERENA_HOME = "D:\\Codex\\.serena"
FIXTURE_ENV_SENTINEL = "must-survive"

[features]
apps = true
fixture_feature_sentinel = true

[projects.'D:\Codex\projects\user-owned-project']
trust_level = "trusted"
fixture_user_project_sentinel = "must-survive"

[fixture.project-trust-neighbor]
value = "must-survive"

[hooks]
[hooks.state]
[ "hooks" . state . "D:\\Codex\\.codex\\hooks.json:session_start:0:0" ]
enabled = true
hash = "fixture-trust-hash"

[[fixture.array]] # 合法 array-of-tables 不能随 hooks section 被删除
name = "array-table-must-survive"
safe_multiline_values = [
  "multiline-array-must-survive [hooks]",
  "literal # [hooks] must survive"
]

    [network]
enabled = true
fixture_network_sentinel = "must-survive"
'@

    $serenaContextPath = Join-Path ([System.IO.Directory]::GetParent($Root).FullName) ".serena\contexts\codex-file-tools.yml"
    $config = $config.Replace('D:\\Codex\\.serena\\contexts\\codex-file-tools.yml', $serenaContextPath.Replace('\', '\\'))

    $configPath = Join-Path $Root "config.toml"
    [System.IO.File]::WriteAllText($configPath, $config, [System.Text.UTF8Encoding]::new($false))

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

    $arguments = @{ Mode=$Mode; CodexHome=$CodexHome }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) { $arguments.EvidencePath = $EvidencePath }
    try {
        $results = @(& $ScriptPath @arguments)
    } catch {
        throw "Reconciler 调用失败（caller line $($MyInvocation.ScriptLineNumber), mode=$Mode, home=$CodexHome）：$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    }
    Assert-True -Condition ($results.Count -eq 1 -and $null -ne $results[0]) -Message "$Mode 必须恰好返回一个结果对象"
    $results[0]
}

function Invoke-ReconcilerJson {
    param(
        [string]$ScriptPath,
        [string]$Mode,
        [string]$CodexHome,
        [string]$EvidencePath
    )

    $arguments = @{ Mode=$Mode; CodexHome=$CodexHome; Json=$true }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) { $arguments.EvidencePath = $EvidencePath }
    $captured = [System.Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        & $ScriptPath @arguments 2>&1 | ForEach-Object { [void]$captured.Add([string]$_) }
    } catch {
        $failure = $_
    }
    $json = ($captured -join [Environment]::NewLine).Trim()
    if ($null -ne $failure) {
        throw "Reconciler JSON 调用失败（caller line $($MyInvocation.ScriptLineNumber), mode=$Mode, home=$CodexHome）：$json"
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($json)) -Message "$Mode 没有返回 JSON"
    try {
        $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "$Mode 返回了无效 JSON：$($_.Exception.Message)"
    }
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

function Assert-CheckWasRejectedWithoutMutation {
    param(
        [string]$ScriptPath,
        [string]$CodexHome,
        [string]$CaseName
    )

    $before = Get-TreeFingerprint -CodexHome $CodexHome
    $captured = [System.Collections.Generic.List[string]]::new()
    $threw = $false
    try {
        & $ScriptPath -Mode Check -CodexHome $CodexHome -Json 2>&1 | ForEach-Object { $captured.Add([string]$_) }
    } catch {
        $threw = $true
        $captured.Add($_.ToString())
    }
    $after = Get-TreeFingerprint -CodexHome $CodexHome
    Assert-True -Condition $threw -Message "$CaseName 没有拒绝 Check"
    Assert-True -Condition ($before -eq $after) -Message "$CaseName 的 Check 修改了核心文件"
    $jsonLine = @($captured | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1)
    Assert-True -Condition ($jsonLine.Count -eq 1) -Message "$CaseName 的 Check 未返回结构化失败 JSON"
    $result = $jsonLine[0] | ConvertFrom-Json
    Assert-True -Condition ($result.mode -eq 'Check' -and -not [bool]$result.ok -and $result.error.code -eq 'reconciliation-failed') -Message "$CaseName 的 Check 失败结果不稳定"
}

function Invoke-EnvironmentPostCommitRollbackTest {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][object]$HostPreflightManifest
    )

    $environmentRollbackHome = Join-Path $TestRoot 'environment-post-commit-rollback\.codex'
    New-FixtureCodexHome -Root $environmentRollbackHome
    $environmentRollbackBefore = Get-TreeFingerprint -CodexHome $environmentRollbackHome -ExcludeEvidence
    $environmentRollbackError = $null
    try {
        $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = 'environment'
        Invoke-Reconciler -ScriptPath $ScriptPath -Mode Repair -CodexHome $environmentRollbackHome | Out-Null
    } catch {
        $environmentRollbackError = $_.Exception.Message
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
    }

    Assert-True -Condition ($environmentRollbackError -match 'fixture-only post-commit environment failure') -Message "environment post-commit failure 未经第一层 transaction catch 原样返回：$environmentRollbackError"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $environmentRollbackHome -ExcludeEvidence) -ceq $environmentRollbackBefore) -Message 'environment post-commit failure 未完整恢复 managed files 与环境 fixture'
    $environmentRollbackEvidence = @(Get-ChildItem -LiteralPath (Join-Path $environmentRollbackHome 'run-evidence\host-hook-remediation') -Directory -Force)
    Assert-True -Condition ($environmentRollbackEvidence.Count -eq 1) -Message 'environment post-commit failure 必须恰好生成一份 evidence'
    $environmentRollbackManifest = Get-Content -Raw -LiteralPath (Join-Path $environmentRollbackEvidence[0].FullName 'manifest.json') | ConvertFrom-Json
    $expectedManagedResources = @($HostPreflightManifest.files | ForEach-Object { "managed:$($_.liveRelativePath)" })
    $attemptedManagedResources = @($environmentRollbackManifest.attemptedResources | Where-Object { [string]$_ -clike 'managed:*' })
    $committedManagedResources = @($environmentRollbackManifest.committedResources | Where-Object { [string]$_ -clike 'managed:*' })
    $expectedManagedSet = @($expectedManagedResources | Sort-Object) -join "`n"
    Assert-True -Condition (
        $environmentRollbackManifest.status -ceq 'rolled-back' -and
        @($environmentRollbackManifest.attemptedResources) -ccontains 'environment:SERENA_HOME' -and
        @($environmentRollbackManifest.committedResources) -ccontains 'environment:SERENA_HOME' -and
        @($environmentRollbackManifest.attemptedResources) -cnotcontains 'hooks.json' -and
        (@($attemptedManagedResources | Sort-Object) -join "`n") -ceq $expectedManagedSet -and
        (@($committedManagedResources | Sort-Object) -join "`n") -ceq $expectedManagedSet
    ) -Message 'environment post-commit failure 未证明第一层 catch 回滚了全部已提交 managed closure 与环境写入'
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
    $selectorCount = @($OnlyEnvironmentPostCommitRollback | Where-Object { $_ }).Count
    Assert-True -Condition ($selectorCount -le 1) -Message '定向 selector 不能组合使用'

    if ($OnlyEnvironmentPostCommitRollback) {
        Invoke-EnvironmentPostCommitRollbackTest -ScriptPath $scriptPath -TestRoot $testRoot -HostPreflightManifest $hostPreflightManifest
        Write-Host 'PASS: Codex host hook environment post-commit rollback'
        return
    }

    # Cleanup mode must not accept an arbitrary caller-supplied ProjectRoot.
    # This foreign D:\ root has the exact legacy-looking layout and markers
    # that the old parameter-trusting implementation would have deleted.
    $foreignProjectRoot = Join-Path 'D:\Codex\.scratch' "host-hook-projectroot-mismatch-$testRunId"
    $foreignFixtureRoot = Join-Path $foreignProjectRoot ".scratch\host-hook-reconciliation-tests-$testRunId"
    $foreignProjectMarker = Join-Path $foreignProjectRoot ".owned-by-projectroot-mismatch-$testRunId"
    $foreignFixtureMarker = Join-Path $foreignFixtureRoot ".owned-by-test-$testRunId"
    try {
        New-Item -ItemType Directory -Force -Path $foreignFixtureRoot | Out-Null
        Set-Content -LiteralPath $foreignProjectMarker -Value $testRunId -Encoding UTF8
        Set-Content -LiteralPath $foreignFixtureMarker -Value $testRunId -Encoding UTF8

        $foreignCleanupError = $null
        try {
            & $PSCommandPath -ProjectRoot $foreignProjectRoot -CleanupFixturePath $foreignFixtureRoot | Out-Null
        } catch {
            $foreignCleanupError = $_.Exception.Message
        }
        Assert-True -Condition ($foreignCleanupError -match 'ProjectRoot 必须匹配测试文件所在项目根') -Message "外部 D 盘 ProjectRoot cleanup 未在任何删除前拒绝：$foreignCleanupError"
        Assert-True -Condition (Test-Path -LiteralPath $foreignFixtureRoot -PathType Container) -Message '外部 D 盘 ProjectRoot cleanup 错误删除了合法形状 fixture'
        Assert-True -Condition (Test-Path -LiteralPath $foreignFixtureMarker -PathType Leaf) -Message '外部 D 盘 ProjectRoot cleanup 错误删除了 ownership marker'
    } finally {
        if (Test-Path -LiteralPath $foreignProjectRoot) {
            Remove-ProjectRootMismatchFixture -RunId $testRunId -Path $foreignProjectRoot
        }
    }

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
    foreach ($name in @("registrations", "legacyImplementations", "acl")) {
        Assert-True -Condition (-not [bool](Get-CheckResult -Result $check -Name $name).ok) -Message "漂移 fixture 的检查项不应健康：$name"
    }

    $originalHooksHash = Get-Sha256 -Path (Join-Path $healthyHome "hooks.json")
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

    $hooks = Get-Content -LiteralPath (Join-Path $healthyHome "hooks.json") -Raw | ConvertFrom-Json -AsHashtable
    $hooksRaw = Get-Content -LiteralPath (Join-Path $healthyHome "hooks.json") -Raw
    Assert-True -Condition ([int]$hooks.schemaVersion -eq 7) -Message "hooks.json 未保留未知 schemaVersion"
    Assert-True -Condition ($hooks.owner -eq "fixture-owner") -Message "hooks.json 未保留未知 owner"
    Assert-True -Condition ($hooksRaw -match '"hugeNumber"\s*:\s*1e400') -Message "hooks.json 改写了未知大数值"
    Assert-True -Condition ($hooks.hooks -is [System.Collections.IDictionary]) -Message "hooks 必须是 JSON 对象，不能是数组或 null"
    Assert-True -Condition ($hooks.hooks.Keys.Count -eq 3) -Message "hooks.json 必须只包含三个受管事件"
    Assert-True -Condition (@($hooks.hooks.SessionStart).Count -eq 3) -Message "SessionStart 必须包含 state preflight、activation reminder 与 github-cli"
    Assert-True -Condition ($hooks.hooks.PreToolUse.matcher -ceq 'Bash') -Message "PreToolUse 必须只注册 Bash reminder"
    Assert-True -Condition (@($hooks.hooks.Stop).Count -eq 1) -Message "Stop 必须只注册 cleanup"

    foreach ($name in $legacyNames) {
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $healthyHome "hooks\$name"))) -Message "legacy 文件仍在 live 目录：$name"
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $repair.evidencePath 'legacy-hooks'))) -Message '退役 Hook 不得保留可恢复 evidence 备份'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $healthyHome "hooks\__pycache__"))) -Message "空 legacy __pycache__ 目录未退役"
    foreach ($relative in @("hooks.json", "manifest.json")) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $repair.evidencePath $relative) -PathType Leaf) -Message "evidence 缺少：$relative"
    }
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $repair.evidencePath "hooks.json")) -eq $originalHooksHash) -Message "hooks evidence 不是修复前快照"
    $manifest = Get-Content -LiteralPath (Join-Path $repair.evidencePath "manifest.json") -Raw | ConvertFrom-Json
    $wrapperManagedNames = @($hostPreflightManifest.hooks | ForEach-Object { "managed:$([IO.Path]::GetFileName([string]$_.wrapperPath))" })
    $dependencyManagedNames = @($hostPreflightManifest.files | Where-Object { "managed:$($_.liveRelativePath)" -cnotin $wrapperManagedNames } | ForEach-Object { "managed:$($_.liveRelativePath)" })
    $repairManagedOrder = [string[]]@($manifest.committedResources | Where-Object { [string]$_ -clike 'managed:*' })
    $repairWrapperPositions = @($wrapperManagedNames | ForEach-Object { [Array]::IndexOf($repairManagedOrder, [string]$_) })
    $repairDependencyPositions = @($dependencyManagedNames | ForEach-Object { [Array]::IndexOf($repairManagedOrder, [string]$_) })
    Assert-True -Condition (
        $repairManagedOrder.Count -eq @($hostPreflightManifest.files).Count -and
        @($repairWrapperPositions | Where-Object { $_ -lt 0 }).Count -eq 0 -and
        @($repairDependencyPositions | Where-Object { $_ -lt 0 }).Count -eq 0 -and
        ($repairDependencyPositions | Measure-Object -Maximum).Maximum -lt ($repairWrapperPositions | Measure-Object -Minimum).Minimum
    ) -Message 'Repair 必须先发布 launcher/implementation dependencies，最后发布 wrappers'
    Assert-True -Condition ($manifest.originalHashes.PSObject.Properties.Name -cnotcontains 'legacyHooks') -Message 'evidence 不得记录可用于恢复的 legacy Hook 备份'
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
    $contextRollbackHooksPath = Join-Path $contextRollbackHome "hooks.json"
    $contextRollbackLock = [System.IO.File]::Open($contextRollbackHooksPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $contextRollbackThrew = $false
    try {
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $contextRollbackHome | Out-Null
    } catch {
        $contextRollbackThrew = $true
    } finally {
        $contextRollbackLock.Dispose()
    }
    Assert-True -Condition $contextRollbackThrew -Message "Serena context 后续 hooks 资源失败未触发事务回滚"
    Assert-True -Condition ([System.IO.File]::ReadAllText($contextRollbackPath) -ceq $contextRollbackContentBefore) -Message "事务失败未精确回滚 Serena context 内容"
    Assert-True -Condition ((Get-Acl -LiteralPath $contextRollbackPath).Sddl -ceq $contextRollbackAclBefore) -Message "事务失败未精确回滚 Serena context ACL"
    $contextRollbackEvidence = @(Get-ChildItem -LiteralPath (Join-Path $contextRollbackHome "run-evidence\host-hook-remediation") -Directory -Force)
    $contextRollbackManifest = Get-Content -Raw -LiteralPath (Join-Path $contextRollbackEvidence[0].FullName "manifest.json") | ConvertFrom-Json
    Assert-True -Condition ($contextRollbackManifest.status -eq "rolled-back" -and @($contextRollbackManifest.attemptedResources) -contains "codex-file-tools.yml" -and @($contextRollbackManifest.committedResources) -contains "codex-file-tools.yml") -Message "事务失败 manifest 未记录 Serena context 提交与完整回滚"

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

    $healthyCheck = Invoke-ReconcilerJson -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
    Assert-True -Condition ([bool]$healthyCheck.ok -and [int]$healthyCheck.driftCount -eq 0) -Message "Repair 后的直接 Check 不健康"
    foreach ($name in @("serenaContext", "registrations", "legacyImplementations", "acl")) {
        Assert-True -Condition ([bool](Get-CheckResult -Result $healthyCheck -Name $name).ok) -Message "Repair 后检查项不健康：$name"
    }

    $stableFingerprint = Get-TreeFingerprint -CodexHome $healthyHome
    $evidenceRoot = Join-Path $healthyHome "run-evidence\host-hook-remediation"
    $evidenceCount = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count
    $secondRepair = Invoke-ReconcilerJson -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome
    Assert-True -Condition ([bool]$secondRepair.ok) -Message "第二次 Repair 未通过"
    Assert-True -Condition (-not [bool]$secondRepair.changed) -Message "第二次 Repair 不幂等"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $healthyHome) -eq $stableFingerprint) -Message "第二次 Repair 改变了核心文件"
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count -eq $evidenceCount) -Message "幂等 Repair 创建了无意义 evidence"

    $runtimeFailureFingerprint = Get-TreeFingerprint -CodexHome $healthyHome
    $runtimeFailureEvidenceCount = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count
    $runtimeRepairThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_MISSING_RUNTIME_ID = 'pythonw'
        $missingRuntimeCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
        $runtimeDependencyCheck = Get-CheckResult -Result $missingRuntimeCheck -Name 'runtimeDependencies'
        Assert-True -Condition (
            -not [bool]$missingRuntimeCheck.ok -and
            [int]$missingRuntimeCheck.driftCount -eq 1 -and
            -not [bool]$runtimeDependencyCheck.ok -and
            (@($runtimeDependencyCheck.unavailableRuntimeIds) -join ',') -ceq 'pythonw'
        ) -Message 'launcher runtime 缺失时 Check 必须只让 runtimeDependencies 变红'
        foreach ($name in @('serenaContext','registrations','managedFiles','environment','legacyImplementations','acl')) {
            Assert-True -Condition ([bool](Get-CheckResult -Result $missingRuntimeCheck -Name $name).ok) -Message "launcher runtime 缺失误伤检查项：$name"
        }
        Assert-True -Condition (@($missingRuntimeCheck.registrationProjection | Where-Object { $null -ne $_.launcherRuntimeSha256 }).Count -eq 0) -Message '缺失 launcher runtime 不得伪造 projection hash'
        try {
            Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $healthyHome | Out-Null
        } catch {
            $runtimeRepairThrew = $true
        }
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_MISSING_RUNTIME_ID -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $runtimeRepairThrew -Message 'launcher runtime 缺失时 Repair 未 fail closed'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $healthyHome) -ceq $runtimeFailureFingerprint) -Message 'launcher runtime Repair 拒绝后修改了 fixture tree'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force).Count -eq $runtimeFailureEvidenceCount) -Message 'launcher runtime Repair 拒绝后仍创建 evidence'

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

    $rawManagedRestoreHome = Join-Path $testRoot 'raw-managed-restore\.codex'
    New-FixtureCodexHome -Root $rawManagedRestoreHome
    $rawManagedRelativePath = 'codex-state-preflight.cmd'
    $rawManagedSourcePath = Join-Path $ProjectRoot 'managed\codex-hooks\hooks\codex-state-preflight.cmd'
    $rawManagedTargetPath = Join-Path $rawManagedRestoreHome "hooks\$rawManagedRelativePath"
    $rawManagedManifestHash = [string](@($hostPreflightManifest.files | Where-Object liveRelativePath -ceq $rawManagedRelativePath)[0].sha256)
    $rawManagedSourceHash = (Get-Sha256 -Path $rawManagedSourcePath).ToLowerInvariant()
    Assert-True -Condition ($rawManagedSourceHash -cne $rawManagedManifestHash) -Message '本 Windows fixture 必须以 CRLF raw bytes 覆盖 LF manifest identity'
    $rawManagedRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $rawManagedRestoreHome
    Assert-True -Condition ([bool]$rawManagedRepair.ok -and (Test-Path -LiteralPath $rawManagedTargetPath -PathType Leaf)) -Message 'raw managed Restore fixture 未部署受管 wrapper'
    $rawManagedEvidence = Get-Content -Raw -LiteralPath (Join-Path $rawManagedRepair.evidencePath 'manifest.json') | ConvertFrom-Json
    Assert-True -Condition ([string]$rawManagedEvidence.intendedResources.managedHooks.$rawManagedRelativePath -ceq $rawManagedSourceHash) -Message 'evidence 必须记录本次发布的 raw managed bytes hash'
    $rawManagedRestore = Invoke-ReconcilerJson -ScriptPath $scriptPath -Mode Restore -CodexHome $rawManagedRestoreHome -EvidencePath ([string]$rawManagedRepair.evidencePath)
    Assert-True -Condition ([bool]$rawManagedRestore.ok -and [bool]$rawManagedRestore.changed -and -not (Test-Path -LiteralPath $rawManagedTargetPath -PathType Leaf)) -Message 'Restore 必须用 evidence 中的 raw deployed hash 回滚 CRLF 受管 wrapper'
    $rawManagedRestoredEvidence = Get-Content -Raw -LiteralPath (Join-Path $rawManagedRepair.evidencePath 'manifest.json') | ConvertFrom-Json
    $restoreProgress = [string[]]@($rawManagedRestoredEvidence.restoreProgress)
    $restoreManagedOrder = [string[]]@($restoreProgress | Where-Object { [string]$_ -clike 'managed:*' })
    $restoreWrapperPositions = @($wrapperManagedNames | ForEach-Object { [Array]::IndexOf($restoreManagedOrder, [string]$_) })
    $restoreDependencyPositions = @($dependencyManagedNames | ForEach-Object { [Array]::IndexOf($restoreManagedOrder, [string]$_) })
    Assert-True -Condition (
        $restoreProgress.Count -gt 0 -and $restoreProgress[0] -ceq 'hooks.json' -and
        $restoreManagedOrder.Count -eq @($hostPreflightManifest.files).Count -and
        @($restoreWrapperPositions | Where-Object { $_ -lt 0 }).Count -eq 0 -and
        @($restoreDependencyPositions | Where-Object { $_ -lt 0 }).Count -eq 0 -and
        ($restoreWrapperPositions | Measure-Object -Maximum).Maximum -lt ($restoreDependencyPositions | Measure-Object -Minimum).Minimum
    ) -Message 'Restore 必须先撤销 hooks.json 和 wrappers，最后撤销 launcher/implementation dependencies'

    $nestedManagedRestoreHome = Join-Path $testRoot 'nested-managed-restore\.codex'
    New-FixtureCodexHome -Root $nestedManagedRestoreHome
    $nestedManagedRelativePath = 'lib/CodexHookRuntime.ps1'
    $nestedManagedSourcePath = Join-Path $ProjectRoot 'managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
    $nestedManagedTargetPath = Join-Path $nestedManagedRestoreHome "hooks\$nestedManagedRelativePath"
    $nestedManagedSourceHash = (Get-Sha256 -Path $nestedManagedSourcePath).ToLowerInvariant()
    $nestedManagedRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $nestedManagedRestoreHome
    Assert-True -Condition ([bool]$nestedManagedRepair.ok -and (Test-Path -LiteralPath $nestedManagedTargetPath -PathType Leaf)) -Message 'nested managed Restore fixture 未部署受管 runtime'
    $nestedManagedEvidence = Get-Content -Raw -LiteralPath (Join-Path $nestedManagedRepair.evidencePath 'manifest.json') | ConvertFrom-Json
    $nestedManagedEvidenceKey = $nestedManagedRelativePath.Replace('/', '\')
    $nestedManagedEvidenceRecord = $nestedManagedEvidence.intendedResources.managedHooks.PSObject.Properties[$nestedManagedEvidenceKey]
    Assert-True -Condition ($null -ne $nestedManagedEvidenceRecord -and [string]$nestedManagedEvidenceRecord.Value -ceq $nestedManagedSourceHash) -Message 'nested managed evidence 必须使用反斜杠键并记录 raw managed bytes hash'
    Assert-True -Condition ($null -eq $nestedManagedEvidence.intendedResources.managedHooks.PSObject.Properties[$nestedManagedRelativePath]) -Message 'nested managed evidence 不得保留 slash 键别名'
    $nestedManagedRestore = Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $nestedManagedRestoreHome -EvidencePath ([string]$nestedManagedRepair.evidencePath)
    Assert-True -Condition ([bool]$nestedManagedRestore.ok -and [bool]$nestedManagedRestore.changed -and -not (Test-Path -LiteralPath $nestedManagedTargetPath -PathType Leaf)) -Message 'Restore 必须回滚嵌套 managed runtime'

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
    $concurrentConfigPath = Join-Path $concurrentHome "hooks.json"
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
    Assert-True -Condition $concurrentThrew -Message "hooks.json 提交窗口并发写入未让 Repair 失败"
    $concurrentEvidence = @(Get-ChildItem -LiteralPath (Join-Path $concurrentHome "run-evidence\host-hook-remediation") -Directory -Force)
    Assert-True -Condition ($concurrentEvidence.Count -eq 1) -Message "hooks.json 并发 canary 必须生成一份 evidence"
    $concurrentManifest = Get-Content -LiteralPath (Join-Path $concurrentEvidence[0].FullName "manifest.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ($concurrentManifest.status -eq "unsafe-partial") -Message "hooks.json 并发 manifest 未标记 unsafe-partial"
    Assert-True -Condition (-not [bool]$concurrentManifest.concurrentReplace.backupRestored) -Message "hooks.json 并发 backup 不应覆盖 active path"
    Assert-True -Condition (Test-Path -LiteralPath $concurrentManifest.concurrentReplace.backupPath -PathType Leaf) -Message "hooks.json 并发 canary 未保留 backup"
    Assert-True -Condition ([System.IO.File]::ReadAllText($concurrentManifest.concurrentReplace.backupPath) -ceq "# fixture concurrent replacement`n") -Message "hooks.json 并发 backup 未保留提交窗口版本"
    Assert-True -Condition ((Get-Acl -LiteralPath $concurrentManifest.concurrentReplace.backupPath).Sddl -ceq $concurrentConfigAclBefore) -Message "hooks.json 并发 backup 未保留提交窗口 ACL"

    foreach ($failureMode in @("replace", "hash")) {
        $casFailureHome = Join-Path $testRoot "cas-$failureMode\.codex"
        New-FixtureCodexHome -Root $casFailureHome
        $casFailureConfigPath = Join-Path $casFailureHome "hooks.json"
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
    $aclConcurrentConfigPath = Join-Path $aclConcurrentHome "hooks.json"
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
    $rollbackCasConfigPath = Join-Path ([System.IO.Directory]::GetParent($rollbackCasHome).FullName) ".serena\contexts\codex-file-tools.yml"
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
    Assert-True -Condition (@($rollbackManifest.attemptedResources) -contains "hooks.json") -Message "回滚 manifest 未记录 hooks.json 已进入提交阶段"
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $rollbackEvidence[0].FullName "hooks.json")) -eq $rollbackHooksHash) -Message "回滚 evidence 的 hooks 快照不真实"

    Invoke-EnvironmentPostCommitRollbackTest -ScriptPath $scriptPath -TestRoot $testRoot -HostPreflightManifest $hostPreflightManifest

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
        $expectedPostCommitStatus = if ($phase -eq 'legacy') { 'unsafe-partial' } else { 'rolled-back' }
        Assert-True -Condition ($postCommitManifest.status -eq $expectedPostCommitStatus) -Message "post-commit $phase failure 状态错误：$($postCommitManifest.status)"
        foreach ($resource in @("hooks.json")) {
            Assert-True -Condition (@($postCommitManifest.committedResources) -contains $resource) -Message "post-commit $phase failure 漏记已提交资源：$resource"
        }
        if ($phase -eq "acl") {
            Assert-True -Condition (@($postCommitManifest.aclTargets).Count -eq 1 -and $postCommitManifest.aclTargets[0] -eq $firstAclPath) -Message "ACL failure seam 未精确记录首个 ACL mutation"
            Assert-True -Condition ((Get-Acl -LiteralPath $firstAclPath).Sddl -ceq $firstAclBefore) -Message "ACL failure seam 未恢复首个 ACL"
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $postCommitHome "hooks\$($legacyNames[0])") -PathType Leaf) -Message "ACL failure seam 不应提前退役 legacy 文件"
        } else {
            Assert-True -Condition (@($postCommitManifest.retiredResources).Count -eq 1 -and $postCommitManifest.retiredResources[0] -eq $legacyNames[0]) -Message "legacy failure seam 未精确记录首个退役 mutation"
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $postCommitHome "hooks\$($legacyNames[0])") -PathType Leaf)) -Message "legacy failure seam 不得复活首个已删除 legacy 文件"
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

    foreach ($case in @(
        @{ Name = "malformed-hooks"; Variant = "MalformedHooks" },
        @{ Name = "invalid-serena-context-policy"; Variant = "InvalidSerenaContextPolicy" },
        @{ Name = "malformed-serena-indent"; Variant = "MalformedSerenaIndent" },
        @{ Name = "bare-cr-serena-context"; Variant = "BareCrSerenaContext" },
        @{ Name = "null-serena-scalar"; Variant = "NullSerenaScalar" },
        @{ Name = "duplicate-serena-marker"; Variant = "DuplicateSerenaMarker" },
        @{ Name = "external-serena-marker"; Variant = "ExternalSerenaMarker" },
        @{ Name = "quoted-serena-scalar"; Variant = "QuotedSerenaScalar" },
        @{ Name = "quoted-serena-list-scalar"; Variant = "QuotedSerenaListScalar" },
        @{ Name = "duplicate-serena-prompt"; Variant = "DuplicateSerenaPrompt" }
    )) {
        $caseHome = Join-Path $testRoot "$($case.Name)\.codex"
        New-FixtureCodexHome -Root $caseHome -Variant $case.Variant
        Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $caseHome -CaseName $case.Name
    }

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
