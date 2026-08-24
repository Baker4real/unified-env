param(
    [string]$ProjectRoot = "D:\agents\projects\统一环境",
    [switch]$KeepOutputs,
    [switch]$OnlyFeatureDisableVariants,
    [string]$OnlyFeatureDisableVariant,
    [switch]$OnlyHeaderLikeArrayToml,
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

function Assert-TomlParsesWithPython {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $result = Invoke-SilentProcess `
        -FilePath 'D:\Codex\tools\python314-official\python.exe' `
        -Arguments @('-B','-I','-S','-X','utf8','-c','import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))',$Path)
    Assert-True -Condition ($result.exitCode -eq 0) -Message "$Message stderr=$($result.stderr.Trim())"
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
Assert-True -Condition ($reconcilerSource.Contains('完整 TOML 语法验证失败：TOML parser Python 超时')) -Message 'TOML parser timeout 必须在非 JSON 诊断中保留安全的高层原因'
foreach ($mobileRetiredClosure in @("codex-mobile-permission-guard.cmd", "codex-mobile-permission-guard.py")) {
    Assert-True -Condition ([regex]::Matches($reconcilerSource, [regex]::Escape('"' + $mobileRetiredClosure + '"')).Count -eq 1) -Message "mobile permission retired wrapper/implementation 必须各在 exact legacy allowlist 出现一次：$mobileRetiredClosure"
}

function Set-TestInheritedFileAcl {
    param([string]$Path)

    $security = Get-Acl -LiteralPath $Path
    $security.SetAccessRuleProtection($false, $true)
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]::new($Path), $security)
}

function Replace-FixtureHooksTableHeader {
    param(
        [string]$Config,
        [string]$Replacement,
        [string]$Variant
    )

    $hooksHeaderPattern = '(?m)^\[hooks\][ \t]*\r?$'
    if ([regex]::Matches($Config, $hooksHeaderPattern).Count -ne 1) {
        throw "fixture 必须恰好包含一个真实 [hooks] header：$Variant"
    }
    [regex]::Replace($Config, $hooksHeaderPattern, $Replacement)
}

function New-FixtureCodexHome {
    param(
        [string]$Root,
        [ValidateSet("Drift", "MalformedHooks", "DuplicateSerena", "MissingSerenaArgs", "MissingSerenaCommand", "MissingSerenaSection", "HermesCommandDrift", "SingleQuotedSerenaArgs", "EmptySerenaSectionAtEof", "DuplicateSerenaArgs", "DuplicateSerenaCommand", "MalformedSerenaArgs", "MissingSerenaContext", "MissingSerenaContextValue", "WrongSerenaContext", "DuplicateSerenaContext", "LegacySerenaContext", "NegatedSerenaPolicy", "InvalidSerenaContextPolicy", "MalformedSerenaIndent", "BareCrSerenaContext", "NullSerenaScalar", "DuplicateSerenaMarker", "ExternalSerenaMarker", "QuotedSerenaScalar", "QuotedSerenaListScalar", "DuplicateSerenaPrompt", "MissingSerenaProjectValue", "DuplicateHookSection", "DuplicateQuotedApproval", "RootDottedHookKey", "SensitiveInvalidHeader", "MissingApproval", "HooksDisabled", "RootDottedHooksDisabled", "RootQuotedDottedHooksDisabled", "RootDottedDeprecatedHooksDisabled", "RootInlineFeaturesDisabled", "FeaturesDottedHooksDescendant", "FeaturesQuotedHooksTable", "FeaturesDeprecatedHooksDescendant", "FeaturesHooksArrayTable", "UserPolicyChoices", "InlineUserHooks", "MultilineToml", "InvalidUnmanagedToml", "InvalidUtf8Toml", "BomToml")]
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

    if ($Variant -eq "DuplicateSerena") {
        $config += @'

[mcp_servers.serena]
args = [ "start-mcp-server", "--project-from-cwd" ]
'@
    } elseif ($Variant -eq "MissingSerenaArgs") {
        $config = $config -replace '(?m)^args\s*=.*\r?\n', ''
    } elseif ($Variant -eq "MissingSerenaCommand") {
        $config = $config -replace '(?m)^command\s*=.*\r?\n', ''
    } elseif ($Variant -eq "MissingSerenaSection") {
        $config = $config -replace '(?ms)^\[mcp_servers\.serena\]\r?\n.*?(?=^\[features\])', ''
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
        $config = $config.Replace('[mcp_servers.serena]', "`"approval_policy`" = `"on-request`"`n`"approval_policy`" = `"on-request`"`n`n[mcp_servers.serena]")
    } elseif ($Variant -eq "RootDottedHookKey") {
        $config = $config.Replace('[mcp_servers.serena]', "hooks.state.`"fixture`".enabled = true`n`n[mcp_servers.serena]")
    } elseif ($Variant -eq "SensitiveInvalidHeader") {
        $config += "`n[ `"SECRET_ERROR_TOKEN`" . ]`n"
    } elseif ($Variant -eq "HooksDisabled") {
       $config = $config.Replace('apps = true', "hooks = false`napps = true")
    } elseif ($Variant -in @("RootDottedHooksDisabled", "RootQuotedDottedHooksDisabled", "RootDottedDeprecatedHooksDisabled", "RootInlineFeaturesDisabled")) {
        $withoutFeaturesTable = [regex]::Replace($config, '(?ms)\[features\]\r?\napps = true\r?\nfixture_feature_sentinel = true\r?\n\r?\n', '')
        if ($withoutFeaturesTable -ceq $config -or $withoutFeaturesTable -match '(?m)^\[features\]\s*$') {
            throw "root features fixture 未精确移除 [features] table：$Variant"
        }
        $config = $withoutFeaturesTable
        $rootFeatureLiteral = if ($Variant -eq "RootDottedHooksDisabled") { 'features.hooks = false' } elseif ($Variant -eq "RootQuotedDottedHooksDisabled") { 'features."hooks" = false' } elseif ($Variant -eq "RootDottedDeprecatedHooksDisabled") { 'features.codex_hooks = false' } else { 'features = { hooks = false }' }
        $config = $config.Replace('[mcp_servers.serena]', "$rootFeatureLiteral`n`n[mcp_servers.serena]")
        if ([regex]::Matches($config, [regex]::Escape($rootFeatureLiteral)).Count -ne 1) {
            throw "root features fixture 未精确插入目标 literal：$Variant"
        }
    } elseif ($Variant -eq 'FeaturesDottedHooksDescendant') {
        $config = $config.Replace('fixture_feature_sentinel = true', "fixture_feature_sentinel = true`nhooks.enabled = false")
    } elseif ($Variant -eq 'FeaturesQuotedHooksTable') {
        $config = Replace-FixtureHooksTableHeader -Config $config -Replacement "[features.`"hooks`"]`nenabled = false`n`n[hooks]" -Variant $Variant
    } elseif ($Variant -eq 'FeaturesDeprecatedHooksDescendant') {
        $config = $config.Replace('fixture_feature_sentinel = true', "fixture_feature_sentinel = true`ncodex_hooks.enabled = false")
    } elseif ($Variant -eq 'FeaturesHooksArrayTable') {
        $config = Replace-FixtureHooksTableHeader -Config $config -Replacement "[[features.hooks]]`nenabled = false`n`n[hooks]" -Variant $Variant
    } elseif ($Variant -eq "UserPolicyChoices") {
        $config = $config.Replace('fixture_unicode = "中文必须通过"', "fixture_unicode = `"中文必须通过`"`napproval_policy = `"on-request`"`nsandbox_mode = `"workspace-write`"")
        $config = $config.Replace('apps = true', "unified_exec = false`napps = true")
    } elseif ($Variant -eq "InlineUserHooks") {
        $config += @'

[[hooks.PreToolUse]]
matcher = "Bash"
hooks = [{ type = "command", command = "D:\\fixture\\user-hook.cmd" }]
'@
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
fixture_root_sentinel = "must-survive"

[features]
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
    $featureSafetyVariants = @(
        'HooksDisabled',
        'RootDottedHooksDisabled',
        'RootQuotedDottedHooksDisabled',
        'RootDottedDeprecatedHooksDisabled',
        'RootInlineFeaturesDisabled',
        'FeaturesDottedHooksDescendant',
        'FeaturesQuotedHooksTable',
        'FeaturesDeprecatedHooksDescendant',
        'FeaturesHooksArrayTable'
    )
    if ($Variant -in $featureSafetyVariants) {
        Assert-TomlParsesWithPython -Path $configPath -Message "feature safety fixture 必须是合法 TOML：$Variant"
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

function Invoke-HeaderLikeArrayTomlRejectionTest {
    param(
        [string]$ScriptPath,
        [string]$TestRoot
    )

    $headerLikeArrayHome = Join-Path $TestRoot 'header-like-array-toml\.codex'
    New-FixtureCodexHome -Root $headerLikeArrayHome
    $headerLikeBaselineRepair = Invoke-Reconciler -ScriptPath $ScriptPath -Mode Repair -CodexHome $headerLikeArrayHome
    Assert-True -Condition ([bool]$headerLikeBaselineRepair.ok) -Message 'header-like-array 基准 Repair 未形成健康状态'
    $headerLikeConfigPath = Join-Path $headerLikeArrayHome 'config.toml'
    $headerLikeBaselineConfig = Get-Content -LiteralPath $headerLikeConfigPath -Raw
    Assert-True -Condition (-not ($headerLikeBaselineConfig -match '(?m)^\s*\[\s*["'']?hooks["'']?(?:\.|\s*\])')) -Message 'header-like-array 基准仍包含真实 hook section'
    Assert-True -Condition $headerLikeBaselineConfig.Contains('multiline-array-must-survive [hooks]') -Message '安全多行数组被误拒绝或改写'
    Assert-True -Condition $headerLikeBaselineConfig.Contains('literal # [hooks] must survive') -Message '安全多行数组中的注释样文本被误拒绝或改写'
    $headerLikeConfig = $headerLikeBaselineConfig + @'

[fixture.header_like_array]
values = [
  ["keep"],
  ["hooks"]
]
'@
    [System.IO.File]::WriteAllText($headerLikeConfigPath, $headerLikeConfig, [System.Text.UTF8Encoding]::new($false))
    Assert-TomlParsesWithPython -Path $headerLikeConfigPath -Message 'header-like-array 输入本身不是合法 TOML'
    Assert-CheckWasRejectedWithoutMutation -ScriptPath $ScriptPath -CodexHome $headerLikeArrayHome -CaseName 'header-like-array-toml'
    Assert-RepairWasRejectedWithoutMutation -ScriptPath $ScriptPath -CodexHome $headerLikeArrayHome -CaseName 'header-like-array-toml'

    $headerLikeArrayTableConfig = $headerLikeBaselineConfig + @'

[fixture.header_like_array_table]
values = [
  [["keep"]],
  [["hooks"]]
]
'@
    Assert-True -Condition ($headerLikeArrayTableConfig -match '(?m)^\s*\[\["hooks"\]\]\s*$') -Message 'header-like-array-table fixture 未形成独立的 array-table-like 元素'
    [System.IO.File]::WriteAllText($headerLikeConfigPath, $headerLikeArrayTableConfig, [System.Text.UTF8Encoding]::new($false))
    Assert-TomlParsesWithPython -Path $headerLikeConfigPath -Message 'header-like-array-table 输入本身不是合法 TOML'
    Assert-CheckWasRejectedWithoutMutation -ScriptPath $ScriptPath -CodexHome $headerLikeArrayHome -CaseName 'header-like-array-table-toml'
    Assert-RepairWasRejectedWithoutMutation -ScriptPath $ScriptPath -CodexHome $headerLikeArrayHome -CaseName 'header-like-array-table-toml'
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
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $environmentRollbackHome -ExcludeEvidence) -ceq $environmentRollbackBefore) -Message 'environment post-commit failure 未完整恢复 config、managed files 与环境 fixture'
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

$featureDisableCases = @(
    @{ Name = 'features.hooks=false'; Directory = 'features-hooks-disabled'; Variant = 'HooksDisabled' },
    @{ Name = 'root-features.hooks=false'; Directory = 'root-features-hooks-disabled'; Variant = 'RootDottedHooksDisabled' },
    @{ Name = 'root-features."hooks"=false'; Directory = 'root-features-quoted-hooks-disabled'; Variant = 'RootQuotedDottedHooksDisabled' },
    @{ Name = 'root-features.codex_hooks=false'; Directory = 'root-features-codex-hooks-disabled'; Variant = 'RootDottedDeprecatedHooksDisabled' },
    @{ Name = 'root-features-inline-hooks=false'; Directory = 'root-features-inline-hooks-disabled'; Variant = 'RootInlineFeaturesDisabled' },
    @{ Name = 'features-hooks-descendant=false'; Directory = 'features-hooks-descendant-disabled'; Variant = 'FeaturesDottedHooksDescendant' },
    @{ Name = 'features-quoted-hooks-table=false'; Directory = 'features-quoted-hooks-table-disabled'; Variant = 'FeaturesQuotedHooksTable' },
    @{ Name = 'features-codex-hooks-descendant=false'; Directory = 'features-codex-hooks-descendant-disabled'; Variant = 'FeaturesDeprecatedHooksDescendant' },
    @{ Name = 'features-hooks-array-table=false'; Directory = 'features-hooks-array-table-disabled'; Variant = 'FeaturesHooksArrayTable' }
)

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
    $selectorCount = @($OnlyHeaderLikeArrayToml, $OnlyFeatureDisableVariants, $OnlyEnvironmentPostCommitRollback, -not [string]::IsNullOrWhiteSpace($OnlyFeatureDisableVariant) | Where-Object { $_ }).Count
    Assert-True -Condition ($selectorCount -le 1) -Message '定向 selector 不能组合使用'

    if ($OnlyEnvironmentPostCommitRollback) {
        Invoke-EnvironmentPostCommitRollbackTest -ScriptPath $scriptPath -TestRoot $testRoot -HostPreflightManifest $hostPreflightManifest
        Write-Host 'PASS: Codex host hook environment post-commit rollback'
        return
    }

    if ($OnlyHeaderLikeArrayToml) {
        Invoke-HeaderLikeArrayTomlRejectionTest -ScriptPath $scriptPath -TestRoot $testRoot
        Write-Host 'PASS: Codex host hook header-like-array TOML rejection'
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($OnlyFeatureDisableVariant)) {
        $selectedFeatureDisableCase = @($featureDisableCases | Where-Object { $_.Variant -ceq $OnlyFeatureDisableVariant })
        Assert-True -Condition ($selectedFeatureDisableCase.Count -eq 1) -Message "未知 feature-disable fixture：$OnlyFeatureDisableVariant"
        $hooksDisabledHome = Join-Path $testRoot "$($selectedFeatureDisableCase[0].Directory)\.codex"
        New-FixtureCodexHome -Root $hooksDisabledHome -Variant $selectedFeatureDisableCase[0].Variant
        Assert-CheckWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $hooksDisabledHome -CaseName $selectedFeatureDisableCase[0].Name
        Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $hooksDisabledHome -CaseName $selectedFeatureDisableCase[0].Name
        Write-Host "PASS: Codex host hook feature-disable rejection $OnlyFeatureDisableVariant"
        return
    }

    if ($OnlyFeatureDisableVariants) {
        foreach ($disabledFeatureCase in $featureDisableCases) {
            $hooksDisabledHome = Join-Path $testRoot "$($disabledFeatureCase.Directory)\.codex"
            New-FixtureCodexHome -Root $hooksDisabledHome -Variant $disabledFeatureCase.Variant
            Assert-CheckWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $hooksDisabledHome -CaseName $disabledFeatureCase.Name
            Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $hooksDisabledHome -CaseName $disabledFeatureCase.Name
        }

        Write-Host "PASS: Codex host hook feature-disable rejection"
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
    foreach ($sentinel in @('fixture-model-must-survive', 'fixture_unicode = "中文必须通过"', 'FIXTURE_ENV_SENTINEL = "must-survive"', 'fixture_feature_sentinel = true', 'fixture_user_project_sentinel = "must-survive"', 'array-table-must-survive', 'multiline-array-must-survive', 'fixture_network_sentinel = "must-survive"')) {
        Assert-True -Condition $config.Contains($sentinel) -Message "无关 TOML 内容被误删或改写：$sentinel"
    }
    Assert-True -Condition (-not ($config -match '(?m)^approval_policy\s*=')) -Message "Repair 不得为缺失 approval_policy 推测权限"
    Assert-True -Condition (-not ($config -match '(?m)^sandbox_mode\s*=')) -Message "Repair 不得为缺失 sandbox_mode 推测权限"
    Assert-True -Condition (-not ($config -match '(?m)^hooks\s*=')) -Message "Repair 不得把默认启用的 features.hooks 写成显式配置"
    Assert-True -Condition (-not ($config -match '(?m)^unified_exec\s*=')) -Message "Repair 不得改写 Windows unified_exec 默认值"
    foreach ($trustedProject in @(
        'D:\agents\projects\时钟倒计时',
        'D:\agents\projects\统一环境',
        'D:\agents\projects\杨杨子',
        'D:\Codex\projects\codex-account-switch',
        'D:\Codex\projects\CodexProviderSync',
        'D:\agents\projects\minmin-calendar'
    )) {
        $header = [regex]::Escape("[projects.'$($trustedProject.ToLowerInvariant())']")
        Assert-True -Condition ([regex]::IsMatch($config, "(?m)^$header\s*\r?\ntrust_level\s*=\s*`"trusted`"\s*$")) -Message "项目 trust 未收敛：$trustedProject"
    }
    $userProjectHeader = "[projects.'D:\Codex\projects\user-owned-project']"
    Assert-True -Condition ($config.Contains($userProjectHeader) -and $config.Contains('fixture_user_project_sentinel = "must-survive"')) -Message '不在 allow/denylist 的用户 project trust 被错误删除'
    Assert-True -Condition (-not $config.Contains("[projects.'d:\codex\projects']")) -Message '不得把 projects 集合根设为 trusted'
    Assert-True -Condition (-not ($config -match '(?m)^\[hooks(?:\.|\])')) -Message "旧 hook trust section 未删除"
    Assert-True -Condition (-not $config.Contains('fixture-trust-hash')) -Message "带点号空白的合法 hook trust section 未删除"

    foreach ($name in $legacyNames) {
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $healthyHome "hooks\$name"))) -Message "legacy 文件仍在 live 目录：$name"
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $repair.evidencePath 'legacy-hooks'))) -Message '退役 Hook 不得保留可恢复 evidence 备份'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $healthyHome "hooks\__pycache__"))) -Message "空 legacy __pycache__ 目录未退役"
    foreach ($relative in @("config.toml", "hooks.json", "manifest.json")) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $repair.evidencePath $relative) -PathType Leaf) -Message "evidence 缺少：$relative"
    }
    Assert-True -Condition ((Get-Sha256 -Path (Join-Path $repair.evidencePath "config.toml")) -eq $originalConfigHash) -Message "config evidence 不是修复前快照"
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
    $healthyCheck = Invoke-ReconcilerJson -ScriptPath $scriptPath -Mode Check -CodexHome $healthyHome
    Assert-True -Condition ([bool]$healthyCheck.ok -and [int]$healthyCheck.driftCount -eq 0) -Message "Repair 后的直接 Check 不健康"
    foreach ($name in @("serenaContext", "config", "registrations", "legacyImplementations", "acl")) {
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
        foreach ($name in @('serenaContext','config','registrations','managedFiles','environment','legacyImplementations','acl')) {
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

    $vendorAclSddl = (Get-Acl -LiteralPath $configPath).Sddl
    $vendorDriftedConfig = [System.IO.File]::ReadAllText($configPath).Replace('command = "D:\\Codex\\.codex\\scripts\\start-serena-mcp.cmd"', 'command = "D:\\fixture\\serena-wrapper.cmd"')
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
    foreach ($name in $legacyNames) {
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $protectedRestoreHome "hooks\$name"))) -Message "Restore 不得重建已退役 legacy 文件：$name"
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $protectedRestoreHome 'hooks\__pycache__'))) -Message 'Restore 不得重建已退役 legacy 目录'
    Set-TestInheritedFileAcl -Path $protectedRestoreConfig
    Assert-True -Condition ((Get-Acl -LiteralPath $protectedRestoreConfig).Sddl -cne $protectedRestoreSddl) -Message 'content same-bytes different-ACL fixture 未形成真实漂移'
    $protectedRestoreAclDriftThrew = $false
    try { Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $protectedRestoreHome -EvidencePath ([string]$protectedRestoreRepair.evidencePath) | Out-Null } catch { $protectedRestoreAclDriftThrew = $true }
    Assert-True -Condition $protectedRestoreAclDriftThrew -Message 'content same-bytes different-ACL 不得通过 restored shortcut/final postcheck'

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

    # A later resource failure must not let the config rollback resurrect a
    # retired project trust that the Repair had already removed.
    $retiredTrustRollbackHome = Join-Path $testRoot 'retired-project-trust-rollback\.codex'
    New-FixtureCodexHome -Root $retiredTrustRollbackHome
    $retiredTrustRollbackConfigPath = Join-Path $retiredTrustRollbackHome 'config.toml'
    $retiredTrustRollbackUserHeader = "[projects.'D:\Codex\projects\user-owned-project']"
    $retiredTrustRollbackHeader = "[projects.'D:\Codex\projects\codex-gsd-codex-c-skill']"
    $retiredTrustRollbackOriginalConfig = [IO.File]::ReadAllText($retiredTrustRollbackConfigPath)
    $retiredTrustRollbackBlock = $retiredTrustRollbackHeader + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine + 'retired_rollback_fixture_sentinel = "must-not-return"' + [Environment]::NewLine + [Environment]::NewLine
    $retiredTrustRollbackDriftedConfig = $retiredTrustRollbackOriginalConfig.Replace($retiredTrustRollbackUserHeader, $retiredTrustRollbackBlock + $retiredTrustRollbackUserHeader)
    Assert-True -Condition (-not $retiredTrustRollbackDriftedConfig.Equals($retiredTrustRollbackOriginalConfig, [StringComparison]::Ordinal)) -Message 'retired trust rollback fixture 未注入已退役 trust'
    [IO.File]::WriteAllText($retiredTrustRollbackConfigPath, $retiredTrustRollbackDriftedConfig, [Text.UTF8Encoding]::new($false))
    $retiredTrustRollbackLock = [System.IO.File]::Open((Join-Path $retiredTrustRollbackHome 'hooks.json'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $retiredTrustRollbackThrew = $false
    try {
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $retiredTrustRollbackHome | Out-Null
    } catch {
        $retiredTrustRollbackThrew = $true
    } finally {
        $retiredTrustRollbackLock.Dispose()
    }
    Assert-True -Condition $retiredTrustRollbackThrew -Message '后续 hooks 资源故障未触发 retired trust rollback fixture'
    $retiredTrustRollbackConfig = [IO.File]::ReadAllText($retiredTrustRollbackConfigPath)
    Assert-True -Condition ($retiredTrustRollbackConfig -ceq $retiredTrustRollbackOriginalConfig) -Message '常规 rollback 未仅清除已退役 project trust 后恢复 config'
    Assert-True -Condition (-not $retiredTrustRollbackConfig.Contains('retired_rollback_fixture_sentinel = "must-not-return"')) -Message '常规 rollback 回写了已退役 project trust'
    $retiredTrustRollbackEvidence = @(Get-ChildItem -LiteralPath (Join-Path $retiredTrustRollbackHome 'run-evidence\host-hook-remediation') -Directory -Force)
    $retiredTrustRollbackManifest = Get-Content -LiteralPath (Join-Path $retiredTrustRollbackEvidence[0].FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True -Condition ($retiredTrustRollbackManifest.status -eq 'rolled-back' -and @($retiredTrustRollbackManifest.attemptedResources) -contains 'config.toml' -and @($retiredTrustRollbackManifest.attemptedResources) -contains 'hooks.json') -Message '常规 retired trust rollback 未记录后续资源故障和完整回滚'

    $retiredTrustPostCommitRollbackHome = Join-Path $testRoot 'retired-project-trust-post-commit-rollback\.codex'
    New-FixtureCodexHome -Root $retiredTrustPostCommitRollbackHome
    $retiredTrustPostCommitRollbackConfigPath = Join-Path $retiredTrustPostCommitRollbackHome 'config.toml'
    $retiredTrustPostCommitOriginalConfig = [IO.File]::ReadAllText($retiredTrustPostCommitRollbackConfigPath)
    $retiredTrustPostCommitDriftedConfig = $retiredTrustPostCommitOriginalConfig.Replace($retiredTrustRollbackUserHeader, $retiredTrustRollbackBlock + $retiredTrustRollbackUserHeader)
    Assert-True -Condition (-not $retiredTrustPostCommitDriftedConfig.Equals($retiredTrustPostCommitOriginalConfig, [StringComparison]::Ordinal)) -Message 'post-commit retired trust rollback fixture 未注入已退役 trust'
    [IO.File]::WriteAllText($retiredTrustPostCommitRollbackConfigPath, $retiredTrustPostCommitDriftedConfig, [Text.UTF8Encoding]::new($false))
    $retiredTrustPostCommitRollbackThrew = $false
    try {
        $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = 'acl'
        Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $retiredTrustPostCommitRollbackHome | Out-Null
    } catch {
        $retiredTrustPostCommitRollbackThrew = $true
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
    }
    Assert-True -Condition $retiredTrustPostCommitRollbackThrew -Message 'post-commit ACL 故障未触发 retired trust rollback fixture'
    $retiredTrustPostCommitRollbackConfig = [IO.File]::ReadAllText($retiredTrustPostCommitRollbackConfigPath)
    Assert-True -Condition ($retiredTrustPostCommitRollbackConfig -ceq $retiredTrustPostCommitOriginalConfig) -Message 'post-commit rollback 未仅清除已退役 project trust 后恢复 config'
    Assert-True -Condition (-not $retiredTrustPostCommitRollbackConfig.Contains('retired_rollback_fixture_sentinel = "must-not-return"')) -Message 'post-commit rollback 回写了已退役 project trust'
    $retiredTrustPostCommitRollbackEvidence = @(Get-ChildItem -LiteralPath (Join-Path $retiredTrustPostCommitRollbackHome 'run-evidence\host-hook-remediation') -Directory -Force)
    $retiredTrustPostCommitRollbackManifest = Get-Content -LiteralPath (Join-Path $retiredTrustPostCommitRollbackEvidence[0].FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True -Condition ($retiredTrustPostCommitRollbackManifest.status -eq 'rolled-back' -and @($retiredTrustPostCommitRollbackManifest.committedResources) -contains 'config.toml') -Message 'post-commit retired trust rollback 未记录 config 提交和完整回滚'

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
        foreach ($resource in @("config.toml", "hooks.json")) {
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
        @{ Name = "hermes-command-drift-repair"; Variant = "HermesCommandDrift" }
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

    $singleQuotedArgsHome = Join-Path $testRoot 'single-quoted-serena-args-command-drift\.codex'
    New-FixtureCodexHome -Root $singleQuotedArgsHome -Variant 'SingleQuotedSerenaArgs'
    $singleQuotedArgsContextPath = Join-Path ([System.IO.Directory]::GetParent($singleQuotedArgsHome).FullName) '.serena\contexts\codex-file-tools.yml'
    $singleQuotedArgsExpectedLine = "args = ['start-mcp-server', '--context=$singleQuotedArgsContextPath', '--enable-web-dashboard=true', '--open-web-dashboard=false']"
    $singleQuotedArgsRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $singleQuotedArgsHome
    Assert-True -Condition ([bool]$singleQuotedArgsRepair.ok -and [bool]$singleQuotedArgsRepair.changed) -Message 'single-quoted Serena args fixture 未修复真实 command drift'
    $singleQuotedArgsText = Get-Content -Raw -LiteralPath (Join-Path $singleQuotedArgsHome 'config.toml')
    Assert-True -Condition ($singleQuotedArgsText -match '(?m)^command\s*=\s*"D:\\\\Codex\\\\\.codex\\\\scripts\\\\start-serena-mcp\.cmd"\s*$') -Message 'single-quoted Serena args fixture 未修复 command'
    Assert-True -Condition $singleQuotedArgsText.Contains($singleQuotedArgsExpectedLine) -Message '真实 command drift Repair 不得改写已正确的 single-quoted Serena args'
    $singleQuotedArgsSecond = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $singleQuotedArgsHome
    Assert-True -Condition ([bool]$singleQuotedArgsSecond.ok -and -not [bool]$singleQuotedArgsSecond.changed) -Message 'single-quoted Serena args command Repair 后第二次不是 no-op'

    $singleQuotedCanonicalHome = Join-Path $testRoot 'single-quoted-canonical-serena-values\.codex'
    New-FixtureCodexHome -Root $singleQuotedCanonicalHome
    $singleQuotedCanonicalConfigPath = Join-Path $singleQuotedCanonicalHome 'config.toml'
    $singleQuotedCanonicalBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $singleQuotedCanonicalHome
    Assert-True -Condition ([bool]$singleQuotedCanonicalBaselineRepair.ok -and [bool]$singleQuotedCanonicalBaselineRepair.changed) -Message 'single-quoted canonical Serena values fixture 未先收敛到健康基线'
    $singleQuotedCanonicalContextPath = Join-Path ([System.IO.Directory]::GetParent($singleQuotedCanonicalHome).FullName) '.serena\contexts\codex-file-tools.yml'
    $singleQuotedCanonicalCommandLine = "command = 'D:\Codex\.codex\scripts\start-serena-mcp.cmd'"
    $singleQuotedCanonicalArgsLine = "args = ['start-mcp-server', '--context=$singleQuotedCanonicalContextPath', '--enable-web-dashboard=true', '--open-web-dashboard=false']"
    $singleQuotedCanonicalText = Get-Content -Raw -LiteralPath $singleQuotedCanonicalConfigPath
    Assert-True -Condition ([regex]::Matches($singleQuotedCanonicalText, '(?m)^command\s*=').Count -eq 1 -and [regex]::Matches($singleQuotedCanonicalText, '(?m)^args\s*=').Count -eq 1) -Message 'single-quoted canonical Serena values fixture 未形成唯一 Serena command/args 基线'
    $singleQuotedCanonicalText = [regex]::Replace($singleQuotedCanonicalText, '(?m)^command\s*=[^\r\n]*', $singleQuotedCanonicalCommandLine)
    $singleQuotedCanonicalText = [regex]::Replace($singleQuotedCanonicalText, '(?m)^args\s*=[^\r\n]*', $singleQuotedCanonicalArgsLine)
    [System.IO.File]::WriteAllText($singleQuotedCanonicalConfigPath, $singleQuotedCanonicalText, [System.Text.UTF8Encoding]::new($false))
    $singleQuotedCanonicalBefore = Get-TreeFingerprint -CodexHome $singleQuotedCanonicalHome
    $singleQuotedCanonicalCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $singleQuotedCanonicalHome
    Assert-True -Condition ([bool]$singleQuotedCanonicalCheck.ok -and [int]$singleQuotedCanonicalCheck.driftCount -eq 0 -and [bool](Get-CheckResult -Result $singleQuotedCanonicalCheck -Name 'config').ok) -Message 'single-quoted canonical Serena values 的 Check 不应报告 config drift'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $singleQuotedCanonicalHome) -eq $singleQuotedCanonicalBefore) -Message 'single-quoted canonical Serena values 的 Check 修改了 fixture'
    $singleQuotedCanonicalRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $singleQuotedCanonicalHome
    Assert-True -Condition ([bool]$singleQuotedCanonicalRepair.ok -and -not [bool]$singleQuotedCanonicalRepair.changed -and $null -eq $singleQuotedCanonicalRepair.evidencePath) -Message 'single-quoted canonical Serena values 的 Repair 必须是 no-op'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $singleQuotedCanonicalHome) -eq $singleQuotedCanonicalBefore) -Message 'single-quoted canonical Serena values 的 no-op Repair 修改了 fixture'
    $singleQuotedCanonicalAfter = Get-Content -Raw -LiteralPath $singleQuotedCanonicalConfigPath
    Assert-True -Condition $singleQuotedCanonicalAfter.Contains($singleQuotedCanonicalCommandLine) -Message 'no-op Repair 改写了 canonical single-quoted Serena command'
    Assert-True -Condition $singleQuotedCanonicalAfter.Contains($singleQuotedCanonicalArgsLine) -Message 'no-op Repair 改写了 canonical single-quoted Serena args'

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

    $userPolicyHome = Join-Path $testRoot 'user-policy-choices\.codex'
    New-FixtureCodexHome -Root $userPolicyHome -Variant 'UserPolicyChoices'
    $userPolicyRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $userPolicyHome
    $userPolicyConfig = Get-Content -Raw -LiteralPath (Join-Path $userPolicyHome 'config.toml')
    foreach ($literal in @('approval_policy = "on-request"', 'sandbox_mode = "workspace-write"', 'unified_exec = false')) {
        Assert-True -Condition $userPolicyConfig.Contains($literal) -Message "Repair 改写了用户显式权限或 unified_exec 选择：$literal"
    }
    $userPolicyCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $userPolicyHome
    Assert-True -Condition ([bool]$userPolicyCheck.ok) -Message '保留用户权限选择后 Check 不应继续报告 config drift'

    $inlineUserHooksHome = Join-Path $testRoot 'inline-user-hooks\.codex'
    New-FixtureCodexHome -Root $inlineUserHooksHome -Variant 'InlineUserHooks'
    $inlineUserHooksRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $inlineUserHooksHome
    $inlineUserHooksConfig = Get-Content -Raw -LiteralPath (Join-Path $inlineUserHooksHome 'config.toml')
    Assert-True -Condition ([bool]$inlineUserHooksRepair.ok -and $inlineUserHooksConfig.Contains('[[hooks.PreToolUse]]') -and $inlineUserHooksConfig.Contains('D:\\fixture\\user-hook.cmd')) -Message 'Repair 不得删除用户合法 inline [hooks]'
    Assert-True -Condition (-not ($inlineUserHooksConfig -match '(?m)^\[hooks\.state\]')) -Message 'Repair 必须仅移除已退役 hooks.state trust 结构'
    $inlineUserHooksCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $inlineUserHooksHome
    Assert-True -Condition ([bool]$inlineUserHooksCheck.ok) -Message '保留用户 inline hooks 后 Check 不应继续报告 config drift'

    foreach ($disabledFeatureCase in $featureDisableCases) {
        $hooksDisabledHome = Join-Path $testRoot "$($disabledFeatureCase.Directory)\.codex"
        New-FixtureCodexHome -Root $hooksDisabledHome -Variant $disabledFeatureCase.Variant
        Assert-CheckWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $hooksDisabledHome -CaseName $disabledFeatureCase.Name
        Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $hooksDisabledHome -CaseName $disabledFeatureCase.Name
    }

    $missingSerenaHome = Join-Path $testRoot "missing-serena-section\.codex"
    New-FixtureCodexHome -Root $missingSerenaHome -Variant "MissingSerenaSection"
    $missingSerenaContextPath = Join-Path ([System.IO.Directory]::GetParent($missingSerenaHome).FullName) ".serena\contexts\codex-file-tools.yml"
    $missingSerenaConfigPath = Join-Path $missingSerenaHome "config.toml"
    $missingSerenaInitialConfig = Get-Content -Raw -LiteralPath $missingSerenaConfigPath
    Assert-True -Condition (-not [regex]::IsMatch($missingSerenaInitialConfig, '(?m)^\[mcp_servers\.serena\]\s*$')) -Message "缺段 fixture 意外保留了 Serena section"
    $missingSerenaBeforeCheck = Get-TreeFingerprint -CodexHome $missingSerenaHome
    $missingSerenaCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $missingSerenaHome
    Assert-True -Condition (-not [bool]$missingSerenaCheck.ok -and -not [bool](Get-CheckResult -Result $missingSerenaCheck -Name "config").ok) -Message "缺失 Serena section 的 Check 未报告 config drift"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $missingSerenaHome) -eq $missingSerenaBeforeCheck) -Message "缺失 Serena section 的 Check 修改了 fixture"

    $missingSerenaRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $missingSerenaHome
    Assert-True -Condition ([bool]$missingSerenaRepair.ok -and [bool]$missingSerenaRepair.changed) -Message "缺失 Serena section 的 Repair 未收敛"
    $missingSerenaConfig = Get-Content -Raw -LiteralPath $missingSerenaConfigPath
    $missingSerenaSection = [regex]::Match($missingSerenaConfig, '(?ms)^\[mcp_servers\.serena\]\r?\n(?<body>.*?)(?=^\s*\[|\z)')
    Assert-True -Condition ($missingSerenaSection.Success -and [regex]::Matches($missingSerenaConfig, '(?m)^\[mcp_servers\.serena\]\s*$').Count -eq 1) -Message "缺失 Serena section Repair 后未精确插入唯一 canonical section"
    $missingSerenaBody = $missingSerenaSection.Groups['body'].Value
    Assert-True -Condition ([regex]::Matches($missingSerenaBody, '(?m)^command\s*=\s*"D:\\\\Codex\\\\\.codex\\\\scripts\\\\start-serena-mcp\.cmd"\s*$').Count -eq 1) -Message "缺失 Serena section Repair 后 command 不精确"
    $missingSerenaArgsMatch = [regex]::Match($missingSerenaBody, '(?m)^args\s*=\s*(?<rhs>\[.*\])\s*$')
    Assert-True -Condition $missingSerenaArgsMatch.Success -Message "缺失 Serena section Repair 后缺少 canonical args"
    $missingSerenaArgs = @((ConvertFrom-Json -InputObject $missingSerenaArgsMatch.Groups['rhs'].Value -NoEnumerate))
    $expectedMissingSerenaArgs = @("start-mcp-server", "--context=$missingSerenaContextPath", "--enable-web-dashboard=true", "--open-web-dashboard=false")
    Assert-True -Condition (($missingSerenaArgs -join "`n") -ceq ($expectedMissingSerenaArgs -join "`n")) -Message "缺失 Serena section Repair 后 args 不精确"
    foreach ($sentinel in @('fixture-model-must-survive', 'fixture_unicode = "中文必须通过"', 'fixture_feature_sentinel = true', 'array-table-must-survive', 'fixture_network_sentinel = "must-survive"')) {
        Assert-True -Condition $missingSerenaConfig.Contains($sentinel) -Message "缺失 Serena section Repair 改写了无关 TOML 内容：$sentinel"
    }

    $missingSerenaHealthyCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $missingSerenaHome
    Assert-True -Condition ([bool]$missingSerenaHealthyCheck.ok -and [int]$missingSerenaHealthyCheck.driftCount -eq 0) -Message "缺失 Serena section Repair 后的 Check 不健康"
    $missingSerenaFingerprint = Get-TreeFingerprint -CodexHome $missingSerenaHome
    $missingSerenaEvidenceRoot = Join-Path $missingSerenaHome "run-evidence\host-hook-remediation"
    $missingSerenaEvidenceCount = @(Get-ChildItem -LiteralPath $missingSerenaEvidenceRoot -Directory -Force).Count
    $missingSerenaNoOp = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $missingSerenaHome
    Assert-True -Condition ([bool]$missingSerenaNoOp.ok -and -not [bool]$missingSerenaNoOp.changed -and $null -eq $missingSerenaNoOp.evidencePath) -Message "缺失 Serena section 收敛后的 Repair 不是 no-op"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $missingSerenaHome) -eq $missingSerenaFingerprint) -Message "缺失 Serena section 收敛后的 no-op Repair 修改了 fixture"
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $missingSerenaEvidenceRoot -Directory -Force).Count -eq $missingSerenaEvidenceCount) -Message "缺失 Serena section 收敛后的 no-op Repair 创建了 evidence"

    foreach ($retiredProjectTrustCase in @(
        [pscustomobject]@{ name = 'retired-project-trust-crlf'; newLine = ([string][char]13 + [char]10) },
        [pscustomobject]@{ name = 'retired-project-trust-lf'; newLine = ([string][char]10) }
    )) {
        $retiredProjectTrustHome = Join-Path $testRoot "$($retiredProjectTrustCase.name)\.codex"
        New-FixtureCodexHome -Root $retiredProjectTrustHome
        $retiredProjectTrustConfigPath = Join-Path $retiredProjectTrustHome 'config.toml'
        $retiredProjectTrustBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $retiredProjectTrustHome
        Assert-True -Condition ([bool]$retiredProjectTrustBaselineRepair.ok) -Message "$($retiredProjectTrustCase.name) 基准 Repair 未形成健康状态"

        $retiredProjectTrustUserHeader = "[projects.'D:\Codex\projects\user-owned-project']"
        $retiredProjectTrustNeighborHeader = '[fixture.project-trust-neighbor]'
        $retiredProjectTrustHeader = "[projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL']"
        $retiredProjectTrustBaselineConfig = [IO.File]::ReadAllText($retiredProjectTrustConfigPath)
        Assert-True -Condition ($retiredProjectTrustBaselineConfig.Contains($retiredProjectTrustUserHeader)) -Message "$($retiredProjectTrustCase.name) 缺少用户 project trust 基准 table"
        $retiredProjectTrustNewLine = [string]$retiredProjectTrustCase.newLine
        $retiredProjectTrustNormalizedBaseline = [regex]::Replace($retiredProjectTrustBaselineConfig, "\r?\n", $retiredProjectTrustNewLine)
        $retiredProjectTrustBlock = $retiredProjectTrustHeader + $retiredProjectTrustNewLine + 'trust_level = "trusted"' + $retiredProjectTrustNewLine + 'retired_project_fixture_sentinel = "must-be-removed"' + $retiredProjectTrustNewLine + $retiredProjectTrustNewLine
        $retiredProjectTrustDriftedConfig = $retiredProjectTrustNormalizedBaseline.Replace($retiredProjectTrustUserHeader, $retiredProjectTrustBlock + $retiredProjectTrustUserHeader)
        Assert-True -Condition (-not $retiredProjectTrustDriftedConfig.Equals($retiredProjectTrustBaselineConfig, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustCase.name) 未注入旧 GSD project trust drift"
        [IO.File]::WriteAllText($retiredProjectTrustConfigPath, $retiredProjectTrustDriftedConfig, [Text.UTF8Encoding]::new($false))

        $retiredProjectTrustBeforeCheck = Get-TreeFingerprint -CodexHome $retiredProjectTrustHome
        $retiredProjectTrustCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $retiredProjectTrustHome
        Assert-True -Condition (-not [bool]$retiredProjectTrustCheck.ok -and [int]$retiredProjectTrustCheck.driftCount -eq 1 -and -not [bool](Get-CheckResult -Result $retiredProjectTrustCheck -Name 'config').ok) -Message "$($retiredProjectTrustCase.name) 的 Check 未只报告 config drift"
        foreach ($checkName in @('serenaContext', 'registrations', 'managedFiles', 'environment', 'legacyImplementations', 'acl')) {
            Assert-True -Condition ([bool](Get-CheckResult -Result $retiredProjectTrustCheck -Name $checkName).ok) -Message "$($retiredProjectTrustCase.name) 的 config drift 误伤 $checkName"
        }
        Assert-True -Condition ((Get-TreeFingerprint -CodexHome $retiredProjectTrustHome) -eq $retiredProjectTrustBeforeCheck) -Message "$($retiredProjectTrustCase.name) 的 Check 修改了 fixture"

        $retiredProjectTrustRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $retiredProjectTrustHome
        Assert-True -Condition ([bool]$retiredProjectTrustRepair.ok -and [bool]$retiredProjectTrustRepair.changed) -Message "$($retiredProjectTrustCase.name) 的 Repair 未收敛"
        $retiredProjectTrustConfig = [IO.File]::ReadAllText($retiredProjectTrustConfigPath)
        Assert-True -Condition ($retiredProjectTrustConfig.IndexOf($retiredProjectTrustHeader, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and -not $retiredProjectTrustConfig.Contains('retired_project_fixture_sentinel = "must-be-removed"')) -Message "$($retiredProjectTrustCase.name) 未删除旧 GSD 精确 project trust table"
        Assert-True -Condition ($retiredProjectTrustConfig.Contains($retiredProjectTrustUserHeader) -and $retiredProjectTrustConfig.Contains('fixture_user_project_sentinel = "must-survive"')) -Message "$($retiredProjectTrustCase.name) 错误删除了不在 denylist 的用户 project trust"
        Assert-True -Condition ($retiredProjectTrustConfig.IndexOf($retiredProjectTrustUserHeader, [StringComparison]::Ordinal) -lt $retiredProjectTrustConfig.IndexOf($retiredProjectTrustNeighborHeader, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustCase.name) 改写了无关 project trust 的相对位置"
        if ($retiredProjectTrustCase.name -ceq 'retired-project-trust-crlf') {
            Assert-True -Condition (-not [regex]::IsMatch($retiredProjectTrustConfig, '(?<!\r)\n')) -Message 'CRLF retired project trust Repair 未保持 CRLF'
        } else {
            Assert-True -Condition (-not $retiredProjectTrustConfig.Contains([string][char]13)) -Message 'LF retired project trust Repair 未保持 LF'
        }

        $retiredProjectTrustHealthyCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $retiredProjectTrustHome
        Assert-True -Condition ([bool]$retiredProjectTrustHealthyCheck.ok -and [int]$retiredProjectTrustHealthyCheck.driftCount -eq 0) -Message "$($retiredProjectTrustCase.name) Repair 后的 Check 不健康"
        $retiredProjectTrustFingerprint = Get-TreeFingerprint -CodexHome $retiredProjectTrustHome
        $retiredProjectTrustEvidenceRoot = Join-Path $retiredProjectTrustHome 'run-evidence\host-hook-remediation'
        $retiredProjectTrustEvidenceCount = @(Get-ChildItem -LiteralPath $retiredProjectTrustEvidenceRoot -Directory -Force).Count
        $retiredProjectTrustNoOp = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $retiredProjectTrustHome
        Assert-True -Condition ([bool]$retiredProjectTrustNoOp.ok -and -not [bool]$retiredProjectTrustNoOp.changed -and $null -eq $retiredProjectTrustNoOp.evidencePath) -Message "$($retiredProjectTrustCase.name) 收敛后的 Repair 不是 no-op"
        Assert-True -Condition ((Get-TreeFingerprint -CodexHome $retiredProjectTrustHome) -eq $retiredProjectTrustFingerprint) -Message "$($retiredProjectTrustCase.name) 的 no-op Repair 修改了 fixture"
        Assert-True -Condition (@(Get-ChildItem -LiteralPath $retiredProjectTrustEvidenceRoot -Directory -Force).Count -eq $retiredProjectTrustEvidenceCount) -Message "$($retiredProjectTrustCase.name) 的 no-op Repair 创建了 evidence"
    }

    foreach ($retiredProjectTrustShape in @(
        [pscustomobject]@{
            name = 'retired-project-trust-descendant-table-and-array'
            buildBlock = {
                param([string]$newLine)
                @(
                    "[projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL']",
                    'trust_level = "trusted"',
                    'retired_root_sentinel = "must-be-removed"',
                    "[projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL'.metadata]",
                    'retired_descendant_table_sentinel = "must-be-removed"',
                    "[[projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL'.history]]",
                    'retired_descendant_array_sentinel = "must-be-removed"',
                    ''
                ) -join $newLine
            }
            markers = @('retired_root_sentinel', 'retired_descendant_table_sentinel', 'retired_descendant_array_sentinel')
        },
        [pscustomobject]@{
            name = 'retired-project-trust-array-root-and-descendant'
            buildBlock = {
                param([string]$newLine)
                @(
                    "[[projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL']]",
                    'trust_level = "trusted"',
                    'retired_array_root_sentinel = "must-be-removed"',
                    "[[projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL'.history]]",
                    'retired_array_descendant_sentinel = "must-be-removed"',
                    ''
                ) -join $newLine
            }
            markers = @('retired_array_root_sentinel', 'retired_array_descendant_sentinel')
        }
    )) {
        foreach ($newLineCase in @(
            [pscustomobject]@{ name = 'crlf'; value = ([string][char]13 + [char]10) },
            [pscustomobject]@{ name = 'lf'; value = ([string][char]10) }
        )) {
            $shapeHome = Join-Path $testRoot "$($retiredProjectTrustShape.name)-$($newLineCase.name)\.codex"
            New-FixtureCodexHome -Root $shapeHome
            $shapeConfigPath = Join-Path $shapeHome 'config.toml'
            $shapeBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $shapeHome
            Assert-True -Condition ([bool]$shapeBaselineRepair.ok) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) 基准 Repair 未形成健康状态"

            $shapeUserHeader = "[projects.'D:\Codex\projects\user-owned-project']"
            $shapeNeighborHeader = '[fixture.project-trust-neighbor]'
            $shapeBaseline = [IO.File]::ReadAllText($shapeConfigPath)
            $shapeBlock = & $retiredProjectTrustShape.buildBlock ([string]$newLineCase.value)
            $shapeNormalizedBaseline = [regex]::Replace($shapeBaseline, "\r?\n", [string]$newLineCase.value)
            $shapeDrifted = $shapeNormalizedBaseline.Replace($shapeUserHeader, $shapeBlock + $shapeUserHeader)
            Assert-True -Condition (-not $shapeDrifted.Equals($shapeBaseline, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) 未注入退休 trust shape"
            [IO.File]::WriteAllText($shapeConfigPath, $shapeDrifted, [Text.UTF8Encoding]::new($false))
            $shapeLiveHashBeforeRepair = Get-Sha256 -Path $shapeConfigPath

            $shapeRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $shapeHome
            Assert-True -Condition ([bool]$shapeRepair.ok -and [bool]$shapeRepair.changed) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) 的 Repair 未收敛"
            $shapeConfig = [IO.File]::ReadAllText($shapeConfigPath)
            foreach ($marker in @($retiredProjectTrustShape.markers)) {
                Assert-True -Condition (-not $shapeConfig.Contains($marker, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) 未删除 $marker"
            }
            Assert-True -Condition ($shapeConfig.Contains($shapeUserHeader) -and $shapeConfig.Contains('fixture_user_project_sentinel = "must-survive"')) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) 错误删除了无关用户 trust"
            Assert-True -Condition ($shapeConfig.IndexOf($shapeUserHeader, [StringComparison]::Ordinal) -lt $shapeConfig.IndexOf($shapeNeighborHeader, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) 改写了无关 trust 的相对位置"

            $shapeExpectedEvidence = $shapeDrifted.Replace($shapeBlock, '')
            $shapeEvidenceConfigPath = Join-Path $shapeRepair.evidencePath 'config.toml'
            $shapeEvidenceConfig = [IO.File]::ReadAllText($shapeEvidenceConfigPath)
            Assert-True -Condition ($shapeEvidenceConfig -ceq $shapeExpectedEvidence) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) evidence 清洗了退役 blocks 之外的 TOML 内容"
            foreach ($marker in @($retiredProjectTrustShape.markers)) {
                Assert-True -Condition (-not $shapeEvidenceConfig.Contains($marker, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) evidence 仍包含 $marker"
            }
            $shapeManifest = Get-Content -Raw -LiteralPath (Join-Path $shapeRepair.evidencePath 'manifest.json') | ConvertFrom-Json
            Assert-True -Condition ((Get-Sha256 -Path $shapeEvidenceConfigPath) -ceq [string]$shapeManifest.originalHashes.'config.toml') -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) manifest 未绑定清洗后的 config evidence"
            Assert-True -Condition ($shapeLiveHashBeforeRepair -cne (Get-Sha256 -Path $shapeEvidenceConfigPath)) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) fixture 未形成 live/evidence 哈希分离"

            $shapeRestore = Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $shapeHome -EvidencePath ([string]$shapeRepair.evidencePath)
            Assert-True -Condition ([bool]$shapeRestore.ok) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) 的清洗 evidence 不应阻塞 Restore"
            $shapeAfterRestore = [IO.File]::ReadAllText($shapeConfigPath)
            foreach ($marker in @($retiredProjectTrustShape.markers)) {
                Assert-True -Condition (-not $shapeAfterRestore.Contains($marker, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustShape.name)/$($newLineCase.name) Restore 回流了 $marker"
            }
        }
    }

    $malformedRetiredTrustHome = Join-Path $testRoot 'retired-project-trust-malformed-header\.codex'
    New-FixtureCodexHome -Root $malformedRetiredTrustHome
    $malformedRetiredTrustConfigPath = Join-Path $malformedRetiredTrustHome 'config.toml'
    [IO.File]::AppendAllText(
        $malformedRetiredTrustConfigPath,
        ([Environment]::NewLine + "[[projects.'D:\Codex\projects\codex-gsd-codex-c-skill']" + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    $malformedRetiredTrustBefore = Get-TreeFingerprint -CodexHome $malformedRetiredTrustHome
    $malformedRetiredTrustThrew = $false
    try { Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $malformedRetiredTrustHome | Out-Null } catch { $malformedRetiredTrustThrew = $true }
    Assert-True -Condition $malformedRetiredTrustThrew -Message 'malformed retired project trust header 未让 Repair fail closed'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $malformedRetiredTrustHome) -ceq $malformedRetiredTrustBefore) -Message 'malformed retired project trust header 被拒绝后仍修改了 fixture'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $malformedRetiredTrustHome 'run-evidence'))) -Message 'malformed retired project trust header 在拒绝前产生 evidence'

    $historicalRetiredEvidenceHome = Join-Path $testRoot 'historical-retired-project-trust-evidence\.codex'
    New-FixtureCodexHome -Root $historicalRetiredEvidenceHome
    $historicalRetiredEvidenceRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $historicalRetiredEvidenceHome
    $historicalRetiredEvidenceConfigPath = Join-Path $historicalRetiredEvidenceRepair.evidencePath 'config.toml'
    [IO.File]::AppendAllText(
        $historicalRetiredEvidenceConfigPath,
        ([Environment]::NewLine + "[projects.'D:\Codex\projects\codex-gsd-codex-c-skill']" + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine + 'historical_retired_evidence_sentinel = "must-not-restore"' + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    $historicalRetiredLiveBefore = Get-TreeFingerprint -CodexHome $historicalRetiredEvidenceHome
    $historicalRetiredRestoreError = $null
    try {
        & $scriptPath -Mode Restore -CodexHome $historicalRetiredEvidenceHome -EvidencePath ([string]$historicalRetiredEvidenceRepair.evidencePath) | Out-Null
    } catch {
        $historicalRetiredRestoreError = $_.Exception.Message
    }
    Assert-True -Condition ($historicalRetiredRestoreError -match '退役 project trust') -Message '历史 evidence 的 retired trust 未触发明确 Restore 拒绝'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $historicalRetiredEvidenceHome) -ceq $historicalRetiredLiveBefore) -Message '历史 evidence 的 retired trust 拒绝后仍修改了 live fixture'

    $caseSensitiveRetiredTrustHome = Join-Path $testRoot 'retired-project-trust-case-sensitive-projects-key\.codex'
    New-FixtureCodexHome -Root $caseSensitiveRetiredTrustHome
    $caseSensitiveRetiredTrustConfigPath = Join-Path $caseSensitiveRetiredTrustHome 'config.toml'
    $caseSensitiveRetiredTrustBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $caseSensitiveRetiredTrustHome
    Assert-True -Condition ([bool]$caseSensitiveRetiredTrustBaselineRepair.ok) -Message 'case-sensitive Projects fixture 基准 Repair 未形成健康状态'
    $caseSensitiveRetiredTrustUserHeader = "[projects.'D:\Codex\projects\user-owned-project']"
    $caseSensitiveRetiredTrustHeader = "[Projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL']"
    $caseSensitiveRetiredTrustBlock = $caseSensitiveRetiredTrustHeader + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine + 'case_sensitive_projects_sentinel = "must-survive"' + [Environment]::NewLine + [Environment]::NewLine
    $caseSensitiveRetiredTrustBaseline = [IO.File]::ReadAllText($caseSensitiveRetiredTrustConfigPath)
    $caseSensitiveRetiredTrustConfig = $caseSensitiveRetiredTrustBaseline.Replace($caseSensitiveRetiredTrustUserHeader, $caseSensitiveRetiredTrustBlock + $caseSensitiveRetiredTrustUserHeader)
    Assert-True -Condition (-not $caseSensitiveRetiredTrustConfig.Equals($caseSensitiveRetiredTrustBaseline, [StringComparison]::Ordinal)) -Message 'case-sensitive Projects fixture 未注入大小写反例'
    [IO.File]::WriteAllText($caseSensitiveRetiredTrustConfigPath, $caseSensitiveRetiredTrustConfig, [Text.UTF8Encoding]::new($false))
    $caseSensitiveRetiredTrustBefore = Get-TreeFingerprint -CodexHome $caseSensitiveRetiredTrustHome
    $caseSensitiveRetiredTrustCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $caseSensitiveRetiredTrustHome
    Assert-True -Condition ([bool]$caseSensitiveRetiredTrustCheck.ok -and [int]$caseSensitiveRetiredTrustCheck.driftCount -eq 0) -Message 'TOML 顶层 Projects 大小写反例被错误识别为 retired trust'
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $caseSensitiveRetiredTrustHome) -ceq $caseSensitiveRetiredTrustBefore) -Message 'case-sensitive Projects Check 修改 fixture'
    $caseSensitiveRetiredTrustRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $caseSensitiveRetiredTrustHome
    Assert-True -Condition ([bool]$caseSensitiveRetiredTrustRepair.ok -and -not [bool]$caseSensitiveRetiredTrustRepair.changed) -Message 'TOML 顶层 Projects 大小写反例不应触发 Repair'
    $caseSensitiveRetiredTrustAfter = [IO.File]::ReadAllText($caseSensitiveRetiredTrustConfigPath)
    Assert-True -Condition ($caseSensitiveRetiredTrustAfter.Contains($caseSensitiveRetiredTrustHeader) -and $caseSensitiveRetiredTrustAfter.Contains('case_sensitive_projects_sentinel = "must-survive"')) -Message 'TOML 顶层 Projects 大小写反例被错误删除'

    $quotedBracketHeaderHome = Join-Path $testRoot 'retired-project-trust-quoted-bracket-neighbor\.codex'
    New-FixtureCodexHome -Root $quotedBracketHeaderHome
    $quotedBracketHeaderConfigPath = Join-Path $quotedBracketHeaderHome 'config.toml'
    $quotedBracketHeaderBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $quotedBracketHeaderHome
    Assert-True -Condition ([bool]$quotedBracketHeaderBaselineRepair.ok) -Message 'quoted bracket header fixture 基准 Repair 未形成健康状态'
    $quotedBracketHeaderUserHeader = "[projects.'D:\Codex\projects\user-owned-project']"
    $quotedBracketRetiredHeader = "[projects.'D:\Codex\projects\codex-gsd-codex-c-skill']"
    $quotedBracketNeighborHeader = '["unrelated]header"]'
    $quotedBracketHeaderBlock = $quotedBracketRetiredHeader + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine + 'quoted_bracket_retired_sentinel = "must-be-removed"' + [Environment]::NewLine + $quotedBracketNeighborHeader + [Environment]::NewLine + 'quoted_bracket_neighbor_sentinel = "must-survive"' + [Environment]::NewLine + [Environment]::NewLine
    $quotedBracketHeaderBaseline = [IO.File]::ReadAllText($quotedBracketHeaderConfigPath)
    $quotedBracketHeaderConfig = $quotedBracketHeaderBaseline.Replace($quotedBracketHeaderUserHeader, $quotedBracketHeaderBlock + $quotedBracketHeaderUserHeader)
    Assert-True -Condition (-not $quotedBracketHeaderConfig.Equals($quotedBracketHeaderBaseline, [StringComparison]::Ordinal)) -Message 'quoted bracket header fixture 未注入退役/邻居块'
    [IO.File]::WriteAllText($quotedBracketHeaderConfigPath, $quotedBracketHeaderConfig, [Text.UTF8Encoding]::new($false))
    $quotedBracketHeaderCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $quotedBracketHeaderHome
    Assert-True -Condition (-not [bool]$quotedBracketHeaderCheck.ok -and [int]$quotedBracketHeaderCheck.driftCount -eq 1 -and -not [bool](Get-CheckResult -Result $quotedBracketHeaderCheck -Name 'config').ok) -Message 'quoted bracket header 退役 trust 未只报告 config drift'
    $quotedBracketHeaderRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $quotedBracketHeaderHome
    Assert-True -Condition ([bool]$quotedBracketHeaderRepair.ok -and [bool]$quotedBracketHeaderRepair.changed) -Message 'quoted bracket header Repair 未收敛'
    $quotedBracketHeaderAfter = [IO.File]::ReadAllText($quotedBracketHeaderConfigPath)
    $quotedBracketEvidenceAfter = [IO.File]::ReadAllText((Join-Path $quotedBracketHeaderRepair.evidencePath 'config.toml'))
    foreach ($contentCase in @(
        [pscustomobject]@{ name = 'live'; value = $quotedBracketHeaderAfter },
        [pscustomobject]@{ name = 'evidence'; value = $quotedBracketEvidenceAfter }
    )) {
        Assert-True -Condition (-not $contentCase.value.Contains('quoted_bracket_retired_sentinel', [StringComparison]::Ordinal)) -Message "quoted bracket header $($contentCase.name) 未删除退役块"
        Assert-True -Condition ($contentCase.value.Contains($quotedBracketNeighborHeader) -and $contentCase.value.Contains('quoted_bracket_neighbor_sentinel = "must-survive"')) -Message "quoted bracket header $($contentCase.name) 错误删除相邻 quoted key header"
    }
    $quotedBracketHeaderRestore = Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $quotedBracketHeaderHome -EvidencePath ([string]$quotedBracketHeaderRepair.evidencePath)
    Assert-True -Condition ([bool]$quotedBracketHeaderRestore.ok) -Message 'quoted bracket header 清洗 evidence 不应阻塞 Restore'
    $quotedBracketHeaderAfterRestore = [IO.File]::ReadAllText($quotedBracketHeaderConfigPath)
    Assert-True -Condition ($quotedBracketHeaderAfterRestore.Contains($quotedBracketNeighborHeader) -and $quotedBracketHeaderAfterRestore.Contains('quoted_bracket_neighbor_sentinel = "must-survive"')) -Message 'quoted bracket header Restore 丢失相邻用户 header'

    foreach ($retiredProjectTrustAssignmentShape in @(
        [pscustomobject]@{
            name = 'retired-project-trust-projects-table-dotted-assignment'
            buildBlock = {
                param([string]$newLine)
                @(
                    '[projects]',
                    "'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL'.trust_level = `"trusted`"",
                    "'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL'.retired_assignment_table_sentinel = `"must-be-removed`"",
                    ''
                ) -join $newLine
            }
            markers = @('retired_assignment_table_sentinel')
        },
        [pscustomobject]@{
            name = 'retired-project-trust-root-dotted-assignment'
            buildBlock = {
                param([string]$newLine)
                @(
                    "projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL'.trust_level = `"trusted`"",
                    "projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL'.retired_assignment_root_sentinel = `"must-be-removed`"",
                    ''
                ) -join $newLine
            }
            markers = @('retired_assignment_root_sentinel')
        },
        [pscustomobject]@{
            name = 'retired-project-trust-direct-inline-assignment'
            buildBlock = {
                param([string]$newLine)
                "projects.'D:\CODEX\Projects\CODEX-GSD-CODEX-C-SKILL' = { trust_level = `"trusted`", retired_assignment_inline_sentinel = `"must-be-removed`" }$newLine"
            }
            markers = @('retired_assignment_inline_sentinel')
        }
    )) {
        $assignmentHome = Join-Path $testRoot "$($retiredProjectTrustAssignmentShape.name)\.codex"
        New-FixtureCodexHome -Root $assignmentHome
        $assignmentConfigPath = Join-Path $assignmentHome 'config.toml'
        $assignmentBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $assignmentHome
        Assert-True -Condition ([bool]$assignmentBaselineRepair.ok) -Message "$($retiredProjectTrustAssignmentShape.name) 基准 Repair 未形成健康状态"

        $assignmentBaseline = [IO.File]::ReadAllText($assignmentConfigPath)
        $assignmentNewLine = if ($assignmentBaseline.Contains("`r`n")) { "`r`n" } else { "`n" }
        $assignmentAnchor = '[mcp_servers.serena]'
        Assert-True -Condition ($assignmentBaseline.Contains($assignmentAnchor)) -Message "$($retiredProjectTrustAssignmentShape.name) 缺少插入 anchor"
        $assignmentBlock = & $retiredProjectTrustAssignmentShape.buildBlock $assignmentNewLine
        $assignmentDrifted = $assignmentBaseline.Replace($assignmentAnchor, $assignmentBlock + $assignmentAnchor)
        Assert-True -Condition (-not $assignmentDrifted.Equals($assignmentBaseline, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustAssignmentShape.name) 未注入 dotted trust drift"
        [IO.File]::WriteAllText($assignmentConfigPath, $assignmentDrifted, [Text.UTF8Encoding]::new($false))

        $assignmentBeforeCheck = Get-TreeFingerprint -CodexHome $assignmentHome
        $assignmentCheck = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $assignmentHome
        Assert-True -Condition (-not [bool]$assignmentCheck.ok -and [int]$assignmentCheck.driftCount -eq 1 -and -not [bool](Get-CheckResult -Result $assignmentCheck -Name 'config').ok) -Message "$($retiredProjectTrustAssignmentShape.name) 的 Check 未只报告 config drift"
        foreach ($checkName in @('serenaContext', 'registrations', 'managedFiles', 'environment', 'legacyImplementations', 'acl')) {
            Assert-True -Condition ([bool](Get-CheckResult -Result $assignmentCheck -Name $checkName).ok) -Message "$($retiredProjectTrustAssignmentShape.name) 的 config drift 误伤 $checkName"
        }
        Assert-True -Condition ((Get-TreeFingerprint -CodexHome $assignmentHome) -ceq $assignmentBeforeCheck) -Message "$($retiredProjectTrustAssignmentShape.name) 的 Check 修改了 fixture"

        $assignmentRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $assignmentHome
        Assert-True -Condition ([bool]$assignmentRepair.ok -and [bool]$assignmentRepair.changed) -Message "$($retiredProjectTrustAssignmentShape.name) 的 Repair 未收敛"
        $assignmentConfig = [IO.File]::ReadAllText($assignmentConfigPath)
        $assignmentEvidenceConfig = [IO.File]::ReadAllText((Join-Path $assignmentRepair.evidencePath 'config.toml'))
        foreach ($marker in @($retiredProjectTrustAssignmentShape.markers)) {
            Assert-True -Condition (-not $assignmentConfig.Contains($marker, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustAssignmentShape.name) Repair 后仍含 $marker"
            Assert-True -Condition (-not $assignmentEvidenceConfig.Contains($marker, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustAssignmentShape.name) evidence 仍含 $marker"
        }
        Assert-True -Condition ($assignmentConfig.Contains('fixture_user_project_sentinel = "must-survive"')) -Message "$($retiredProjectTrustAssignmentShape.name) Repair 误伤无关 project trust"

        $assignmentRestore = Invoke-Reconciler -ScriptPath $scriptPath -Mode Restore -CodexHome $assignmentHome -EvidencePath ([string]$assignmentRepair.evidencePath)
        Assert-True -Condition ([bool]$assignmentRestore.ok) -Message "$($retiredProjectTrustAssignmentShape.name) 的清洗 evidence 不应阻塞 Restore"
        $assignmentAfterRestore = [IO.File]::ReadAllText($assignmentConfigPath)
        foreach ($marker in @($retiredProjectTrustAssignmentShape.markers)) {
            Assert-True -Condition (-not $assignmentAfterRestore.Contains($marker, [StringComparison]::Ordinal)) -Message "$($retiredProjectTrustAssignmentShape.name) Restore 回流了 $marker"
        }
    }

    $inlineRetiredTrustHome = Join-Path $testRoot 'retired-project-trust-mixed-inline-map\.codex'
    New-FixtureCodexHome -Root $inlineRetiredTrustHome
    $inlineRetiredTrustConfigPath = Join-Path $inlineRetiredTrustHome 'config.toml'
    $inlineRetiredTrustOriginal = [IO.File]::ReadAllText($inlineRetiredTrustConfigPath)
    $inlineRetiredTrustNewLine = if ($inlineRetiredTrustOriginal.Contains("`r`n")) { "`r`n" } else { "`n" }
    $inlineRetiredTrustUserBlockPattern = '(?ms)^\[projects\.' + [regex]::Escape("'D:\Codex\projects\user-owned-project'") + '\]\r?\n.*?(?=^\s*\[|\z)'
    $inlineRetiredTrustUserBlockMatch = [regex]::Match($inlineRetiredTrustOriginal, $inlineRetiredTrustUserBlockPattern)
    Assert-True -Condition $inlineRetiredTrustUserBlockMatch.Success -Message 'mixed inline map fixture 未定位冲突的普通 projects table'
    $inlineRetiredTrustWithoutUserBlock = $inlineRetiredTrustOriginal.Remove($inlineRetiredTrustUserBlockMatch.Index, $inlineRetiredTrustUserBlockMatch.Length)
    Assert-True -Condition (-not $inlineRetiredTrustWithoutUserBlock.Equals($inlineRetiredTrustOriginal, [StringComparison]::Ordinal)) -Message 'mixed inline map fixture 未删除冲突的普通 projects table'
    $inlineRetiredTrustAnchor = '[mcp_servers.serena]'
    $inlineRetiredTrustLine = "projects = { 'D:\Codex\projects\codex-gsd-codex-c-skill' = { trust_level = `"trusted`" }, 'D:\Codex\projects\user-owned-inline-project' = { trust_level = `"trusted`" } }"
    $inlineRetiredTrustConfig = $inlineRetiredTrustWithoutUserBlock.Replace($inlineRetiredTrustAnchor, $inlineRetiredTrustLine + $inlineRetiredTrustNewLine + $inlineRetiredTrustAnchor)
    Assert-True -Condition (-not $inlineRetiredTrustConfig.Equals($inlineRetiredTrustWithoutUserBlock, [StringComparison]::Ordinal)) -Message 'mixed inline map fixture 未注入 root projects inline table'
    [IO.File]::WriteAllText($inlineRetiredTrustConfigPath, $inlineRetiredTrustConfig, [Text.UTF8Encoding]::new($false))
    Assert-TomlParsesWithPython -Path $inlineRetiredTrustConfigPath -Message 'mixed inline map fixture 输入本身不是合法 TOML'

    $inlineRetiredTrustBefore = Get-TreeFingerprint -CodexHome $inlineRetiredTrustHome
    $inlineRetiredTrustCheckError = $null
    try {
        & $scriptPath -Mode Check -CodexHome $inlineRetiredTrustHome | Out-Null
    } catch {
        $inlineRetiredTrustCheckError = $_.Exception.Message
    }
    Assert-True -Condition ($inlineRetiredTrustCheckError -ceq 'unsupported-inline-retired-project-trust') -Message "mixed inline map Check 未以稳定错误拒绝：$inlineRetiredTrustCheckError"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $inlineRetiredTrustHome) -ceq $inlineRetiredTrustBefore) -Message 'mixed inline map Check 拒绝后仍修改 fixture'

    $inlineRetiredTrustRepairError = $null
    try {
        & $scriptPath -Mode Repair -CodexHome $inlineRetiredTrustHome | Out-Null
    } catch {
        $inlineRetiredTrustRepairError = $_.Exception.Message
    }
    Assert-True -Condition ($inlineRetiredTrustRepairError -ceq 'unsupported-inline-retired-project-trust') -Message "mixed inline map Repair 未以稳定错误拒绝：$inlineRetiredTrustRepairError"
    Assert-True -Condition ((Get-TreeFingerprint -CodexHome $inlineRetiredTrustHome) -ceq $inlineRetiredTrustBefore) -Message 'mixed inline map Repair 拒绝后仍修改 fixture'

    $extendedProjectTrustPathCases = @(
        [pscustomobject]@{ name = 'extended-backslash'; path = '\\?\D:\Codex\projects\codex-gsd-codex-c-skill' },
        [pscustomobject]@{ name = 'extended-slash'; path = '//?/D:/Codex/projects/codex-gsd-codex-c-skill' },
        [pscustomobject]@{ name = 'extended-mixed'; path = '\\?/D:/Codex/projects/codex-gsd-codex-c-skill' },
        [pscustomobject]@{ name = 'device-backslash'; path = '\\.\D:\Codex\projects\codex-gsd-codex-c-skill' },
        [pscustomobject]@{ name = 'device-mixed'; path = '\\./D:/Codex/projects/codex-gsd-codex-c-skill' },
        [pscustomobject]@{ name = 'device-slash'; path = '//./D:/Codex/projects/codex-gsd-codex-c-skill' }
    )
    foreach ($extendedProjectTrustPrefixCase in $extendedProjectTrustPathCases) {
        $extendedProjectTrustHome = Join-Path $testRoot "retired-project-trust-$($extendedProjectTrustPrefixCase.name)\.codex"
        New-FixtureCodexHome -Root $extendedProjectTrustHome
        $extendedProjectTrustConfigPath = Join-Path $extendedProjectTrustHome 'config.toml'
        $extendedProjectTrustBaselineRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $extendedProjectTrustHome
        Assert-True -Condition ([bool]$extendedProjectTrustBaselineRepair.ok) -Message "$($extendedProjectTrustPrefixCase.name) fixture 基准 Repair 未形成健康状态"
        $extendedProjectTrustPath = [string]$extendedProjectTrustPrefixCase.path
        $extendedProjectTrustHeader = "[projects.'$extendedProjectTrustPath']"
        $extendedProjectTrustUserHeader = "[projects.'D:\Codex\projects\user-owned-project']"
        $extendedProjectTrustBaseline = [IO.File]::ReadAllText($extendedProjectTrustConfigPath)
        $extendedProjectTrustBlock = $extendedProjectTrustHeader + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine + 'extended_project_trust_sentinel = "must-not-pass"' + [Environment]::NewLine + [Environment]::NewLine
        $extendedProjectTrustConfig = $extendedProjectTrustBaseline.Replace($extendedProjectTrustUserHeader, $extendedProjectTrustBlock + $extendedProjectTrustUserHeader)
        Assert-True -Condition (-not $extendedProjectTrustConfig.Equals($extendedProjectTrustBaseline, [StringComparison]::Ordinal)) -Message "$($extendedProjectTrustPrefixCase.name) fixture 未注入 extended/device project key"
        [IO.File]::WriteAllText($extendedProjectTrustConfigPath, $extendedProjectTrustConfig, [Text.UTF8Encoding]::new($false))

        $extendedProjectTrustBefore = Get-TreeFingerprint -CodexHome $extendedProjectTrustHome
        $extendedProjectTrustCheckError = $null
        try {
            & $scriptPath -Mode Check -CodexHome $extendedProjectTrustHome | Out-Null
        } catch {
            $extendedProjectTrustCheckError = $_.Exception.Message
        }
        Assert-True -Condition ($extendedProjectTrustCheckError -ceq 'unsupported-extended-project-trust-path') -Message "$($extendedProjectTrustPrefixCase.name) Check 未以稳定错误拒绝：$extendedProjectTrustCheckError"
        Assert-True -Condition ((Get-TreeFingerprint -CodexHome $extendedProjectTrustHome) -ceq $extendedProjectTrustBefore) -Message "$($extendedProjectTrustPrefixCase.name) Check 拒绝后仍修改 fixture"

        $extendedProjectTrustRepairError = $null
        try {
            & $scriptPath -Mode Repair -CodexHome $extendedProjectTrustHome | Out-Null
        } catch {
            $extendedProjectTrustRepairError = $_.Exception.Message
        }
        Assert-True -Condition ($extendedProjectTrustRepairError -ceq 'unsupported-extended-project-trust-path') -Message "$($extendedProjectTrustPrefixCase.name) Repair 未以稳定错误拒绝：$extendedProjectTrustRepairError"
        Assert-True -Condition ((Get-TreeFingerprint -CodexHome $extendedProjectTrustHome) -ceq $extendedProjectTrustBefore) -Message "$($extendedProjectTrustPrefixCase.name) Repair 拒绝后仍修改 fixture"
    }

    $extendedProjectTrustEvidenceHome = Join-Path $testRoot 'retired-project-trust-extended-evidence\.codex'
    New-FixtureCodexHome -Root $extendedProjectTrustEvidenceHome
    $extendedProjectTrustEvidenceRepair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $extendedProjectTrustEvidenceHome
    Assert-True -Condition ([bool]$extendedProjectTrustEvidenceRepair.ok) -Message 'extended project trust evidence fixture 基准 Repair 未形成健康状态'
    $extendedProjectTrustEvidenceConfigPath = Join-Path $extendedProjectTrustEvidenceRepair.evidencePath 'config.toml'
    $extendedProjectTrustEvidenceBaseConfig = [IO.File]::ReadAllText($extendedProjectTrustEvidenceConfigPath)
    foreach ($extendedProjectTrustEvidenceCase in $extendedProjectTrustPathCases) {
        [IO.File]::WriteAllText(
            $extendedProjectTrustEvidenceConfigPath,
            ($extendedProjectTrustEvidenceBaseConfig + [Environment]::NewLine + "[projects.'$([string]$extendedProjectTrustEvidenceCase.path)']" + [Environment]::NewLine + 'trust_level = "trusted"' + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
        $extendedProjectTrustEvidenceLiveBefore = Get-TreeFingerprint -CodexHome $extendedProjectTrustEvidenceHome
        $extendedProjectTrustEvidenceRestoreError = $null
        try {
            & $scriptPath -Mode Restore -CodexHome $extendedProjectTrustEvidenceHome -EvidencePath ([string]$extendedProjectTrustEvidenceRepair.evidencePath) | Out-Null
        } catch {
            $extendedProjectTrustEvidenceRestoreError = $_.Exception.Message
        }
        Assert-True -Condition ($extendedProjectTrustEvidenceRestoreError -match 'unsupported-extended-project-trust-path') -Message "$($extendedProjectTrustEvidenceCase.name) project trust evidence Restore 未 fail closed：$extendedProjectTrustEvidenceRestoreError"
        Assert-True -Condition ((Get-TreeFingerprint -CodexHome $extendedProjectTrustEvidenceHome) -ceq $extendedProjectTrustEvidenceLiveBefore) -Message "$($extendedProjectTrustEvidenceCase.name) project trust evidence Restore 拒绝后仍修改 live fixture"
    }

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
        @{ Name = "multiline-toml"; Variant = "MultilineToml" },
        @{ Name = "invalid-unmanaged-toml"; Variant = "InvalidUnmanagedToml" },
        @{ Name = "invalid-utf8-toml"; Variant = "InvalidUtf8Toml" },
        @{ Name = "bom-toml"; Variant = "BomToml" }
    )) {
        $caseHome = Join-Path $testRoot "$($case.Name)\.codex"
        New-FixtureCodexHome -Root $caseHome -Variant $case.Variant
        Assert-RepairWasRejectedWithoutMutation -ScriptPath $scriptPath -CodexHome $caseHome -CaseName $case.Name
    }

    Invoke-HeaderLikeArrayTomlRejectionTest -ScriptPath $scriptPath -TestRoot $testRoot

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
