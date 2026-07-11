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
$missingActivate.implementationPath = 'D:\Codex\.codex\hooks\missing-serena-activate.ps1'
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
        )
        Stop = @(
            [pscustomobject][ordered]@{
                hooks = @(
                    [pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $cleanup.commandPath $cleanup.arguments; timeout = 10 }
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
Assert-True ($facts.events.SessionStart.Count -eq 7) '必须看到全部 SessionStart entries'
Assert-True ($facts.events.SessionStart[1].idMatch -eq 'github-cli') '必须观察 GitHub 插入索引 1'
Assert-True ($facts.events.SessionStart[3].targetExists -eq $false) 'manifest allowlist 内缺失 target 必须被观察'
Assert-True ($facts.events.SessionStart[5].idMatch -eq $null -and $null -eq $facts.events.SessionStart[5].targetExists) '同文件名错误父目录不得识别或探测'
Assert-True ($facts.events.SessionStart[6].idMatchStatus -ceq 'unmatched') 'entry.type 非 command 不得识别'
Assert-True (@($facts.events.Unknown).Count -eq 3) '未知 event 必须聚合为脱敏计数事实'
Assert-True (@($facts.events.Unknown | Where-Object { $null -ne $_.targetExists }).Count -eq 0) 'UNC/C/device unknown target 不得探测'
Assert-True (@($facts.events.Stop | Where-Object idMatch -ceq 'serena-cleanup').Count -eq 2) '精确 vendor args 必须识别'
Assert-True (@($facts.events.Stop | Where-Object idMatchStatus -ceq 'unmatched').Count -eq 2) 'verb 前后缀不得误识别'
Assert-True ($facts.events.PreToolUse[0].idMatch -eq $null) '额外敏感参数不得匹配'
Assert-True ($facts.events.PreToolUse[1].registrationState -ceq 'retired-but-registered') 'retired identity 仍注册必须显式观察'
foreach ($secret in @('SECRET_MATCHER_DO_NOT_LEAK', 'SECRET_TOKEN_DO_NOT_LEAK', 'user:pass', '019f0000-0000-7000-8000-000000000001', 'SECRET_EXTRA_DO_NOT_LEAK', 'UNC_SECRET_DO_NOT_LEAK', 'C_SECRET_DO_NOT_LEAK', 'DEVICE_SECRET_DO_NOT_LEAK', 'future-secret')) {
    Assert-True (-not $factsJson.Contains($secret)) "registry facts 泄露敏感未知值：$secret"
}
Assert-True ($factsJson -notmatch '"command"\s*:') 'registry facts 不得包含 raw command 字段'
Assert-True (-not $factsJson.Contains('trusted_hash')) 'registry facts 不得泄露 trust hash'
Assert-True (-not (Test-Path -LiteralPath $probeMarker)) 'registry inventory 不得执行 hook'

$ambiguousManifest = Copy-TestDocument $missingTargetManifest
$duplicateCleanup = Copy-TestDocument $cleanup
$duplicateCleanup.id = 'serena-cleanup-retired-copy'
$duplicateCleanup.lifecycle = 'retired'
$duplicateCleanup.lifecycleReason = 'ambiguity fixture'
$duplicateCleanup.order = 99
$ambiguousManifest.hooks = @($ambiguousManifest.hooks) + @($duplicateCleanup)
[void](Assert-CodexHookManifest -Manifest $ambiguousManifest)
$ambiguousFacts = Get-CodexHookRegistryFacts -RegistryPath $RegistryPath -Manifest $ambiguousManifest
Assert-True ($ambiguousFacts.events.Stop[0].idMatchStatus -ceq 'ambiguous' -and $null -eq $ambiguousFacts.events.Stop[0].targetExists) '多候选不得猜测或探测'

$fixtureManifest = Copy-TestDocument $manifest
$fixtureManifest.files = @(
    [pscustomobject][ordered]@{
        relativePath = 'hooks/present.cmd'
        liveRelativePath = 'present.cmd'
        sha256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        lifecycle = 'active'
        ownerHookIds = @('provider-stability')
    }
    [pscustomobject][ordered]@{
        relativePath = 'hooks/missing.cmd'
        liveRelativePath = 'missing.cmd'
        sha256 = ('0' * 64)
        lifecycle = 'active'
        ownerHookIds = @('provider-stability')
    }
)
[void](Assert-CodexHookManifest -Manifest $fixtureManifest)

Write-TestText -Path (Join-Path $ManagedRoot 'hooks\present.cmd') -Value 'abc'
Write-TestText -Path (Join-Path $FixtureLiveHooksRoot 'present.cmd') -Value 'abc'
$fileFacts = @(Get-CodexHookFileFacts -Manifest $fixtureManifest -ManagedRoot $ManagedRoot -LiveHooksRoot $FixtureLiveHooksRoot)
Assert-True ($fileFacts.Count -eq 2) '必须逐项输出 manifest file facts'
Assert-True ($fileFacts[0].managedExists -and $fileFacts[0].liveExists) '存在文件必须被观察'
Assert-True ($fileFacts[0].managedMatchesManifest -and $fileFacts[0].liveMatchesManifest) '匹配 SHA-256 必须被观察'
Assert-True (-not $fileFacts[1].managedExists) 'managed 缺文件必须作为事实缺口输出'
Assert-True (-not $fileFacts[1].liveExists) 'live 缺文件必须作为事实缺口输出'

$dependencyFacts = @(Get-CodexHookDependencyFacts -Manifest $manifest)
$directFact = @($dependencyFacts | Where-Object id -ceq 'serena-cleanup')[0]
$stateFact = @($dependencyFacts | Where-Object id -ceq 'codex-state-policy')[0]
Assert-True ($directFact.entrypointKind -ceq 'direct-vendor' -and $null -eq $directFact.wrapperPath) 'direct vendor 必须显式无 wrapper'
Assert-True ($stateFact.dependencyState -ceq 'pending-or-mismatched') 'desired Python state policy 与 observed legacy Node/JS 必须报告缺口'

$trustSecret = 'DO_NOT_LEAK_FULL_TRUST_HASH_0123456789'
$document = New-CodexHookInventoryDocument -Manifest $fixtureManifest -Registry $facts -FileFacts $fileFacts -DependencyFacts $dependencyFacts -TrustObservation @([pscustomobject]@{ section = 'hooks.state'; keyName = 'trusted_hash_0'; present = $true; value = $trustSecret })
Assert-True ($document.artifactType -ceq 'env-governance.codex-hook-inventory') 'inventory artifactType 必须固定'
Assert-True ($document.schemaVersion -eq 1) 'inventory schemaVersion 必须固定'
Assert-True ($document.readOnly -and -not $document.executionAllowed) 'inventory 必须明确只读且禁止执行'
Assert-True (-not (($document | ConvertTo-Json -Depth 100).Contains($trustSecret))) 'inventory document 不得泄露 trust value'
Assert-True ($document.summary.unprobedTargetCount -gt 0) 'unknown target 必须单列 unprobed'

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
