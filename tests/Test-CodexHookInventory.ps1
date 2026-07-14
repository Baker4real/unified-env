Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PolicyPath = Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1'
$InventoryScript = Join-Path $ProjectRoot 'scripts\Get-CodexHookInventory.ps1'
$FixtureRoot = Join-Path $ProjectRoot 'reports\codex-hook-inventory-test'

. $PolicyPath

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    } catch {
        return
    }

    throw "未拒绝：$Message"
}

function Write-TestText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Copy-TestDocument {
    param([Parameter(Mandatory)][object]$Document)
    return ($Document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
}

if (Test-Path -LiteralPath $FixtureRoot) {
    $resolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
    $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'reports')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理 fixture 根以外路径：$resolvedFixture"
    }

    foreach ($reparseChild in @(Get-ChildItem -LiteralPath $resolvedFixture -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })) {
        if (-not (Test-CodexHookPathWithin -Path $reparseChild.FullName -ParentPath $resolvedFixture)) {
            throw "拒绝清理 fixture 根以外 reparse path：$($reparseChild.FullName)"
        }
        Remove-Item -LiteralPath $reparseChild.FullName -Force
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}

$CodexHome = 'D:\Codex\.codex'
$FixtureLiveHooksRoot = Join-Path $FixtureRoot 'live-hooks'
$ManagedRoot = Join-Path $FixtureRoot 'managed-codex-hooks'
$OutputDir = Join-Path $FixtureRoot 'output'
New-Item -ItemType Directory -Path $FixtureLiveHooksRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ManagedRoot 'hooks') -Force | Out-Null

$probeMarker = Join-Path $FixtureRoot 'HOOK-EXECUTED.txt'
$manifestPath = Join-Path $ProjectRoot 'managed\codex-hooks\manifest.json'
$manifest = Read-CodexHookManifest -Path $manifestPath
$missingTargetManifest = Copy-TestDocument $manifest
$missingActivate = @($missingTargetManifest.hooks | Where-Object id -ceq 'serena-activate')[0]
$missingActivate.commandPath = 'D:\Codex\.codex\hooks\missing-serena-activate.cmd'
$missingActivate.wrapperPath = 'D:\Codex\.codex\hooks\missing-serena-activate.cmd'
$missingActivate.quickHealthCheck.arguments[2] = "Test-Path -LiteralPath 'D:\Codex\.codex\hooks\missing-serena-activate.cmd'"
@($missingTargetManifest.files | Where-Object liveRelativePath -ceq 'serena-activation-reminder.cmd')[0].liveRelativePath = 'missing-serena-activate.cmd'
[void](Assert-CodexHookManifest -Manifest $missingTargetManifest)

function Get-HookById {
    param([Parameter(Mandatory)][string]$Id)
    return @($missingTargetManifest.hooks | Where-Object id -ceq $Id)[0]
}

$provider = Get-HookById 'provider-stability'
$github = Get-HookById 'github-cli'
$state = Get-HookById 'codex-state-policy'
$activate = Get-HookById 'serena-activate'
$dashboard = Get-HookById 'serena-dashboard'
$cleanup = Get-HookById 'serena-cleanup'
$reminder = Get-HookById 'serena-reminder'
$autoApprove = Get-HookById 'serena-auto-approve'
$unknownPath = Join-Path $FixtureLiveHooksRoot 'codex-provider-stability-guard.cmd'

$probeBody = "@echo off`r`necho executed>`"$probeMarker`"`r`n"
Write-TestText -Path $unknownPath -Value $probeBody

function ConvertTo-TestCommand {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @()
    )

    $command = '"' + $Path.Replace('\', '/') + '"'
    if ($Arguments.Count -gt 0) {
        $command += ' ' + ($Arguments -join ' ')
    }

    return $command
}

$registry = [pscustomobject][ordered]@{
    hooks = [pscustomobject][ordered]@{
        SessionStart = @(
            [pscustomobject][ordered]@{ hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $provider.commandPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $github.commandPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $state.commandPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ matcher = 'startup|resume'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $activate.commandPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ customGroupField = 'preserve-me'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $dashboard.commandPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ matcher = 'SECRET_MATCHER_DO_NOT_LEAK'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = (ConvertTo-TestCommand $unknownPath @('--token=SECRET_TOKEN_DO_NOT_LEAK', 'https://user:pass@example.invalid/', '019f0000-0000-7000-8000-000000000001')); timeout = 10 }) }
            [pscustomobject][ordered]@{ hooks = @([pscustomobject][ordered]@{ type = 'http'; command = ConvertTo-TestCommand $provider.commandPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ hooks = @(
                [pscustomobject][ordered]@{ type = 'command'; timeout = 10; secretField = 'MISSING_COMMAND_SECRET_DO_NOT_LEAK' }
                [pscustomobject][ordered]@{ type = 'command'; command = [pscustomobject]@{ secret = 'NON_STRING_COMMAND_SECRET_DO_NOT_LEAK' }; timeout = 10 }
                [pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $cleanup.commandPath $cleanup.arguments; timeout = 10 }
            ) }
        )
        Stop = @(
            [pscustomobject][ordered]@{
                hooks = @(
                    [pscustomobject][ordered]@{ type = 'command'; command = '"d:\codex\.CODEX\hooks\serena-cleanup-guarded.cmd"'; timeout = 10 }
                    [pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $cleanup.commandPath $cleanup.arguments; timeout = 10 }
                    [pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $cleanup.commandPath @('cleanup-now', '--client=codex'); timeout = 10 }
                    [pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $cleanup.commandPath @('precleanup', '--client=codex'); timeout = 10 }
                )
            }
        )
        PreToolUse = @(
            [pscustomobject][ordered]@{ matcher = 'Bash'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $reminder.commandPath @('remind', '--client=codex', '--token=SECRET_EXTRA_DO_NOT_LEAK'); timeout = 10 }) }
            [pscustomobject][ordered]@{ matcher = 'mcp__serena__.*|mcp__serena\..*'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $autoApprove.commandPath $autoApprove.arguments; timeout = 10 }) }
        )
        FutureEvent = @(
            [pscustomobject][ordered]@{ matcher = 'future-secret'; hooks = @(
                [pscustomobject][ordered]@{ type = 'command'; command = '"\\server.invalid\share\hook.cmd" --secret=UNC_SECRET_DO_NOT_LEAK'; timeout = 7 }
                [pscustomobject][ordered]@{ type = 'command'; command = '"C:\Users\sensitive\hook.cmd" --secret=C_SECRET_DO_NOT_LEAK'; timeout = 7 }
                [pscustomobject][ordered]@{ type = 'command'; command = '"\\?\C:\device\hook.cmd" --secret=DEVICE_SECRET_DO_NOT_LEAK'; timeout = 7 }
            ) }
        )
    }
    unknownTopLevel = 'preserve-me'
}
$RegistryPath = Join-Path $FixtureRoot 'hooks.json'
Write-TestText -Path $RegistryPath -Value ($registry | ConvertTo-Json -Depth 100)

$facts = Get-CodexHookRegistryFacts -RegistryPath $RegistryPath -Manifest $missingTargetManifest
$factsJson = $facts | ConvertTo-Json -Depth 100
Assert-True ($facts.events.SessionStart.Count -eq 10) '必须看到全部 SessionStart entries，包括缺 command/non-string entry'
Assert-True ($facts.events.SessionStart[1].idMatch -eq 'github-cli') '必须观察 GitHub 插入索引 1'
Assert-True ($facts.events.SessionStart[3].targetExists -eq $false) 'manifest allowlist 内缺失 target 必须被观察'
Assert-True ($facts.events.SessionStart[5].idMatch -eq $null -and $null -eq $facts.events.SessionStart[5].targetExists) '同文件名错误父目录不得识别或探测'
Assert-True ($facts.events.SessionStart[6].idMatchStatus -ceq 'not-command') 'entry.type 非 command 不得识别'
Assert-True ($facts.events.SessionStart[7].groupIndex -eq 7 -and $facts.events.SessionStart[7].entryIndex -eq 0 -and $facts.events.SessionStart[7].idMatchStatus -ceq 'missing-command') '缺 command entry 必须保留安全位置事实'
Assert-True ($facts.events.SessionStart[8].groupIndex -eq 7 -and $facts.events.SessionStart[8].entryIndex -eq 1 -and $facts.events.SessionStart[8].idMatchStatus -ceq 'non-string-command') '非 string command entry 必须保留安全位置事实'
Assert-True (@($facts.events.Unknown).Count -eq 3) '未知 event 必须聚合为脱敏计数事实'
Assert-True (@($facts.events.Unknown | Where-Object { $null -ne $_.targetExists }).Count -eq 0) 'UNC/C/device unknown target 不得探测'
Assert-True (@($facts.events.Stop | Where-Object idMatch -ceq 'serena-cleanup').Count -eq 2) '精确受管 wrapper identity 必须识别'
Assert-True ($facts.events.Stop[0].commandIdentitySha256 -ceq $facts.events.Stop[1].commandIdentitySha256) 'slash/case/quote command 变体必须归一为同一 identity digest'
Assert-True ($facts.events.SessionStart[9].commandIdentitySha256 -cne $facts.events.Stop[0].commandIdentitySha256) '相同 path/args 在不同 event 中不得误算重复 identity'
Assert-True (@($facts.events.Stop | Where-Object idMatchStatus -ceq 'unmatched').Count -eq 2) 'verb 前后缀不得误识别'
Assert-True ($facts.events.PreToolUse[0].idMatch -eq $null) '额外敏感参数不得匹配'
Assert-True ($facts.events.PreToolUse[1].registrationState -ceq 'retired-but-registered') 'retired identity 仍注册必须显式观察'
foreach ($secret in @('SECRET_MATCHER_DO_NOT_LEAK', 'SECRET_TOKEN_DO_NOT_LEAK', 'user:pass', '019f0000-0000-7000-8000-000000000001', 'SECRET_EXTRA_DO_NOT_LEAK', 'UNC_SECRET_DO_NOT_LEAK', 'C_SECRET_DO_NOT_LEAK', 'DEVICE_SECRET_DO_NOT_LEAK', 'future-secret', 'MISSING_COMMAND_SECRET_DO_NOT_LEAK', 'NON_STRING_COMMAND_SECRET_DO_NOT_LEAK')) {
    Assert-True (-not $factsJson.Contains($secret)) "registry facts 泄露敏感未知值：$secret"
}
Assert-True ($factsJson -notmatch '"command"\s*:') 'registry facts 不得包含 raw command 字段'
Assert-True (-not $factsJson.Contains('trusted_hash')) 'registry facts 不得泄露 trust hash'
Assert-True ($facts.registryFileSha256 -ceq (Get-FileHash -LiteralPath $RegistryPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'registry facts 必须提供原始整文件 SHA-256'
Assert-True ($facts.registryByteLength -eq (Get-Item -LiteralPath $RegistryPath).Length) 'registry facts 必须提供原始整文件字节长度'
Assert-True (-not (Test-Path -LiteralPath $probeMarker)) 'registry inventory 不得执行 hook'

$ambiguousManifest = Copy-TestDocument $missingTargetManifest
$duplicateCleanup = Copy-TestDocument $cleanup
$duplicateCleanup.id = 'serena-cleanup-retired-copy'
$duplicateCleanup.lifecycle = 'retired'
$duplicateCleanup.lifecycleReason = 'ambiguity fixture'
$duplicateCleanup.order = 99
$ambiguousManifest.hooks = @($ambiguousManifest.hooks) + @($duplicateCleanup)
Assert-Throws { Assert-CodexHookManifest -Manifest $ambiguousManifest } 'retired 在内的所有 manifest identity 必须唯一'

$fixtureManifest = Copy-TestDocument $manifest
$fixtureManifest.files = @($fixtureManifest.files) + @(
    [pscustomobject][ordered]@{
        relativePath = 'hooks/test-present.cmd'
        liveRelativePath = 'test-present.cmd'
        sha256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        lifecycle = 'active'
        ownerHookIds = @('provider-stability')
    }
    [pscustomobject][ordered]@{
        relativePath = 'hooks/test-missing.cmd'
        liveRelativePath = 'test-missing.cmd'
        sha256 = ('0' * 64)
        lifecycle = 'active'
        ownerHookIds = @('provider-stability')
    }
)
[void](Assert-CodexHookManifest -Manifest $fixtureManifest)

Write-TestText -Path (Join-Path $ManagedRoot 'hooks\test-present.cmd') -Value 'abc'
Write-TestText -Path (Join-Path $FixtureLiveHooksRoot 'test-present.cmd') -Value 'abc'
$fileFacts = @(Get-CodexHookFileFacts -Manifest $fixtureManifest -ManagedRoot $ManagedRoot -LiveHooksRoot $FixtureLiveHooksRoot)
Assert-True ($fileFacts.Count -eq @($fixtureManifest.files).Count) '必须逐项输出 manifest file facts'
$presentFileFact = @($fileFacts | Where-Object relativePath -ceq 'hooks/test-present.cmd')[0]
$missingFileFact = @($fileFacts | Where-Object relativePath -ceq 'hooks/test-missing.cmd')[0]
Assert-True ($presentFileFact.managedExists -and $presentFileFact.liveExists) '存在文件必须被观察'
Assert-True ($presentFileFact.managedMatchesManifest -and $presentFileFact.liveMatchesManifest) '匹配 SHA-256 必须被观察'
Assert-True (-not $missingFileFact.managedExists) 'managed 缺文件必须作为事实缺口输出'
Assert-True (-not $missingFileFact.liveExists) 'live 缺文件必须作为事实缺口输出'

$probeTarget = Join-Path $FixtureRoot 'safe-probe-target'
$probeLink = Join-Path $FixtureRoot 'safe-probe-link'
New-Item -ItemType Directory -Path $probeTarget -Force | Out-Null
Write-TestText -Path (Join-Path $probeTarget 'secret.txt') -Value 'REPARSE_TARGET_SECRET_DO_NOT_READ'
New-Item -ItemType Junction -Path $probeLink -Target $probeTarget | Out-Null
try {
    $blockedObservation = Get-CodexHookSafeFileHash -Path (Join-Path $probeLink 'secret.txt') -Name 'reparse fixture' -AllowedRoots @($FixtureRoot)
    Assert-True ($blockedObservation.probe.state -ceq 'reparse-blocked' -and -not $blockedObservation.probe.finalPathVerified -and $null -eq $blockedObservation.sha256) '稳定 junction 必须在 open 前停止且不得 hash target'
    Assert-Throws {
        Read-CodexHookSafeUtf8FileSnapshot -Path (Join-Path $probeLink 'secret.txt') -Name 'reparse fixture text' -AllowedRoots @($FixtureRoot)
    } 'UTF-8 读取必须拒绝 junction 最终路径'
    $directFinalPathRejected = $false
    try {
        [void][CodexHookGovernance.HandleBoundFileReader]::ReadAllBytes((Join-Path $probeLink 'secret.txt'))
    } catch {
        $directFinalPathRejected = (Get-CodexHookInnermostException -Exception $_.Exception) -is [CodexHookGovernance.HandlePathMismatchException]
    }
    Assert-True $directFinalPathRejected 'handle helper 自身必须用 final path 拒绝经 junction 打开的 target'
    Assert-Throws { Get-CodexHookRegistryFacts -RegistryPath (Join-Path $probeLink 'secret.txt') -Manifest $manifest } 'registry 读取不得穿过 reparse ancestor'
} finally {
    Remove-Item -LiteralPath $probeLink -Force
}

$replaceablePath = Join-Path $FixtureRoot 'replaceable-snapshot.txt'
$replacementPath = Join-Path $FixtureRoot 'replacement-snapshot.txt'
Write-TestText -Path $replaceablePath -Value 'snapshot-before-replacement'
$beforeReplacement = Read-CodexHookSafeUtf8FileSnapshot -Path $replaceablePath -Name 'replaceable fixture' -AllowedRoots @($FixtureRoot)
Write-TestText -Path $replacementPath -Value 'snapshot-after-replacement'
[IO.File]::Move($replacementPath, $replaceablePath, $true)
$afterReplacement = Read-CodexHookSafeUtf8FileSnapshot -Path $replaceablePath -Name 'replaced fixture' -AllowedRoots @($FixtureRoot)
Assert-True (
    $beforeReplacement.probe.finalPathVerified -and
    $beforeReplacement.text -ceq 'snapshot-before-replacement' -and
    $beforeReplacement.sha256 -ceq (Get-CodexHookTextSha256 -Text $beforeReplacement.text)
) '替换前 text/hash 必须来自同一 handle-bound bytes snapshot'
Assert-True (
    $afterReplacement.probe.finalPathVerified -and
    $afterReplacement.text -ceq 'snapshot-after-replacement' -and
    $afterReplacement.sha256 -ceq (Get-CodexHookTextSha256 -Text $afterReplacement.text) -and
    $afterReplacement.sha256 -cne $beforeReplacement.sha256
) '路径目标替换后必须建立独立 snapshot，不能混用旧 hash/text'

$missingRuntimeProbe = Get-CodexHookSafeFileProbe -Path (Join-Path $FixtureRoot 'missing-runtime.exe') -Name 'missing runtime fixture' -AllowedRoots @($FixtureRoot)
Assert-True ($missingRuntimeProbe.state -ceq 'missing' -and -not $missingRuntimeProbe.exists) '缺 runtime 应作为 inventory gap，而不是 manifest schema 错误'

$providerWrapperReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText "@echo off`r`nREM D:\Codex\tools\PowerShell\7.6.3\pwsh.exe D:\Codex\.codex\hooks\wrong.ps1`r`n`"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`" -NoProfile -File `"D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1`" %*`r`nexit /b %ERRORLEVEL%" `
    -RuntimePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1' `
    -RuntimeId 'pwsh'
Assert-True ($providerWrapperReference.parseState -ceq 'matched') '有效 .cmd command line 必须精确识别 runtime/implementation'

$commentOnlyReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText "@echo off`r`nREM D:\Codex\tools\PowerShell\7.6.3\pwsh.exe D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1`r`n:: same fake reference" `
    -RuntimePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1' `
    -RuntimeId 'pwsh'
Assert-True ($commentOnlyReference.parseState -ceq 'no-effective-command' -and $null -eq $commentOnlyReference.referencesImplementation) 'REM/:: comment substring 不得构成 dependency 引用'

$wrongCommandReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText "REM D:\Codex\tools\PowerShell\7.6.3\pwsh.exe D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1`r`n`"D:\Codex\tools\python314-official\python.exe`" `"D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1`"" `
    -RuntimePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1' `
    -RuntimeId 'pwsh'
Assert-True ($wrongCommandReference.parseState -ceq 'runtime-mismatch' -and -not $wrongCommandReference.referencesRuntime) 'comment 中的正确 path 不得掩盖实际错误 command line'

$injectedPwshReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText '"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -Command injected -File "D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1" & whoami' `
    -RuntimePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1' `
    -RuntimeId 'pwsh'
Assert-True ($injectedPwshReference.parseState -ceq 'unsafe-cmd-metacharacter' -and $injectedPwshReference.referencesImplementation -ne $true) 'reviewer 注入反例不得 matched/ready'

$commandModeReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText '"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -Command injected -File "D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1"' `
    -RuntimePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1' `
    -RuntimeId 'pwsh'
Assert-True ($commandModeReference.parseState -ceq 'forbidden-pwsh-command-mode' -and $commandModeReference.referencesImplementation -ne $true) '-Command/-EncodedCommand 不得伪装为 -File wrapper'

$extraEffectiveCommandReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText "`"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`" -NoProfile -File `"D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1`"`r`nwhoami" `
    -RuntimePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1' `
    -RuntimeId 'pwsh'
Assert-True ($extraEffectiveCommandReference.parseState -ceq 'ambiguous-effective-command' -and $extraEffectiveCommandReference.referencesImplementation -ne $true) '额外有效命令必须保持 pending'

$validPythonReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText '"D:\Codex\tools\python314-official\python.exe" "D:\Codex\.codex\hooks\codex-state-policy-guard.py" %*' `
    -RuntimePath 'D:\Codex\tools\python314-official\python.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-state-policy-guard.py' `
    -RuntimeId 'python'
Assert-True ($validPythonReference.parseState -ceq 'matched') 'Python wrapper 只允许 runtime + implementation + 可选末尾 %*'

$invalidPythonReference = Get-CodexHookWrapperReferenceFacts `
    -WrapperText '"D:\Codex\tools\python314-official\python.exe" -I "D:\Codex\.codex\hooks\codex-state-policy-guard.py" %*' `
    -RuntimePath 'D:\Codex\tools\python314-official\python.exe' `
    -ImplementationPath 'D:\Codex\.codex\hooks\codex-state-policy-guard.py' `
    -RuntimeId 'python'
Assert-True ($invalidPythonReference.parseState -cne 'matched' -and $invalidPythonReference.referencesImplementation -ne $true) 'Python wrapper 不得接受额外 token/flag'

$dependencyFacts = @(Get-CodexHookDependencyFacts -Manifest $manifest)
$directFact = @($dependencyFacts | Where-Object id -ceq 'serena-cleanup')[0]
$stateFact = @($dependencyFacts | Where-Object id -ceq 'codex-state-policy')[0]
$providerFact = @($dependencyFacts | Where-Object id -ceq 'provider-stability')[0]
Assert-True (
    $directFact.entrypointKind -ceq 'wrapper' -and
    $directFact.wrapperPath -ceq 'D:\Codex\.codex\hooks\serena-cleanup-guarded.cmd'
) 'Serena cleanup 必须声明受控 wrapper，不得回退 direct vendor'
Assert-True (
    $stateFact.dependencyState -ceq 'pending-or-mismatched' -and
    $stateFact.wrapperExists -eq $false -and
    $stateFact.wrapperParseState -ceq 'not-read'
) '已退役 state policy wrapper 必须作为缺失依赖观察，不得假定仍在线'
Assert-True (
    $providerFact.dependencyState -ceq 'pending-or-mismatched' -and
    $providerFact.wrapperExists -eq $false -and
    $providerFact.wrapperParseState -ceq 'not-read'
) '已退役 provider wrapper 必须作为缺失依赖观察，不得假定仍在线'

$runtimeFacts = @(Get-CodexHookRuntimeFacts -Manifest $manifest)
Assert-True ($runtimeFacts.Count -eq 4 -and @($runtimeFacts | Where-Object probeState -ceq 'regular-file').Count -eq 4) 'runtime existence/hash 必须由安全 inventory probe 观察'

$trustSecret = 'DO_NOT_LEAK_FULL_TRUST_HASH_0123456789'
$document = New-CodexHookInventoryDocument -Manifest $fixtureManifest -Registry $facts -FileFacts $fileFacts -DependencyFacts $dependencyFacts -TrustObservation @([pscustomobject]@{ section = 'hooks.state'; keyName = 'trusted_hash_0'; present = $true; value = $trustSecret })
Assert-True ($document.artifactType -ceq 'env-governance.codex-hook-inventory') 'inventory artifactType 必须固定'
Assert-True ($document.schemaVersion -eq 1) 'inventory schemaVersion 必须固定'
Assert-True ($document.readOnly -and -not $document.executionAllowed) 'inventory 必须明确只读且禁止执行'
Assert-True (-not (($document | ConvertTo-Json -Depth 100).Contains($trustSecret))) 'inventory document 不得泄露 trust value'
Assert-True ($document.summary.unprobedTargetCount -gt 0) 'unknown target 必须单列 unprobed'
Assert-True ($document.summary.duplicateIdentityCount -eq 1) '重复计数必须基于规范 event/matcher/path/args identity'
Assert-True ($document.summary.duplicateCommandCount -eq $document.summary.duplicateIdentityCount) '旧 duplicateCommandCount 必须保持兼容别名'
Assert-True ($document.registry.registryFileSha256 -ceq $facts.registryFileSha256 -and $document.registry.registryByteLength -eq $facts.registryByteLength) 'inventory document 必须保留 registry final-gate hash/length'

Assert-Throws {
    & $InventoryScript `
        -ManifestPath $manifestPath `
        -CodexHome $CodexHome `
        -OutputDir (Join-Path $CodexHome 'forbidden-inventory-output') |
        Out-Null
} 'inventory OutputDir 不得位于 CodexHome live 树内'

Assert-Throws { & $InventoryScript -ManifestPath $manifestPath -CodexHome $CodexHome -OutputDir (Join-Path $ProjectRoot 'reports\other-output') | Out-Null } 'inventory OutputDir 必须受控'
Assert-Throws { & $InventoryScript -ManifestPath $manifestPath -CodexHome $CodexHome -OutputDir ($OutputDir + ':secret') | Out-Null } 'inventory OutputDir 不得使用 ADS'

$reparseTarget = Join-Path $FixtureRoot 'reparse-target'
$reparseLink = Join-Path $FixtureRoot 'reparse-link'
New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget | Out-Null
try {
    Assert-Throws { & $InventoryScript -ManifestPath $manifestPath -CodexHome $CodexHome -OutputDir (Join-Path $reparseLink 'output') | Out-Null } 'inventory OutputDir 不得穿过 reparse ancestor'
} finally {
    Remove-Item -LiteralPath $reparseLink -Force
}

$published = & $InventoryScript -ManifestPath $manifestPath -CodexHome $CodexHome -OutputDir $OutputDir
$publishedJson = [IO.File]::ReadAllText((Join-Path $OutputDir 'inventory.json'))
$publishedDocument = $publishedJson | ConvertFrom-Json -Depth 100
Assert-True ($publishedDocument.artifactType -ceq 'env-governance.codex-hook-inventory') '入口必须发布 inventory JSON'
Assert-True ($publishedDocument.readOnly -and -not $publishedDocument.executionAllowed) '入口不得宣称可执行'
Assert-True ($publishedJson -notmatch '"command"\s*:') '入口不得输出 raw command'
Assert-True (-not (Test-Path -LiteralPath $probeMarker)) 'inventory 入口不得执行 hook'
Assert-True ([IO.File]::Exists((Join-Path $OutputDir 'REPORT.md'))) '入口必须发布 Markdown 配对报告'
Assert-True ($published.jsonPath -ceq (Join-Path $OutputDir 'inventory.json')) '入口返回值必须指向已发布 JSON'
$accepted = & $InventoryScript `
    -ManifestPath $manifestPath `
    -CodexHome $CodexHome `
    -OutputDir $OutputDir `
    -RequireNoRetiredRegistrations
$acceptedDocument = [IO.File]::ReadAllText([string]$accepted.jsonPath) | ConvertFrom-Json -Depth 100
Assert-True ($acceptedDocument.summary.retiredButRegisteredCount -eq 0) '当前终态必须通过 retired registration 硬门槛'
Assert-True ([IO.File]::Exists((Join-Path $OutputDir 'inventory.json'))) 'full acceptance 通过后必须保留已发布 inventory artifact'

$gitIgnoreLines = @([IO.File]::ReadAllLines((Join-Path $ProjectRoot '.gitignore')))
foreach ($requiredIgnore in @(
    'reports/codex-hook-policy-test/',
    'reports/codex-hook-inventory-test/',
    'reports/codex-hook-deployment-test/',
    'reports/codex-hook-runtime-test/',
    'reports/codex-hook-config-test/',
    'reports/codex-state-policy-test/'
)) {
    Assert-True ($gitIgnoreLines -ccontains $requiredIgnore) ".gitignore 缺少精确条目：$requiredIgnore"
}

[pscustomobject]@{
    ok = $true
    suite = 'CodexHookInventory'
}
