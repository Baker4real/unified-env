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

if (Test-Path -LiteralPath $FixtureRoot) {
    $resolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
    $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'reports')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理 fixture 根以外路径：$resolvedFixture"
    }

    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}

$CodexHome = Join-Path $FixtureRoot 'codex-home'
$LiveHooksRoot = Join-Path $CodexHome 'hooks'
$ManagedRoot = Join-Path $FixtureRoot 'managed-codex-hooks'
$OutputDir = Join-Path $FixtureRoot 'output'
New-Item -ItemType Directory -Path $LiveHooksRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ManagedRoot 'hooks') -Force | Out-Null

$probeMarker = Join-Path $FixtureRoot 'HOOK-EXECUTED.txt'
$providerPath = Join-Path $LiveHooksRoot 'codex-provider-stability-guard.cmd'
$githubPath = Join-Path $LiveHooksRoot 'codex-github-cli-guard.cmd'
$statePath = Join-Path $LiveHooksRoot 'codex-projectless-root-d.cmd'
$activatePath = Join-Path $LiveHooksRoot 'serena-activate-guarded.cmd'
$dashboardPath = Join-Path $LiveHooksRoot 'serena-dashboard-guard.cmd'
$serenaHooksPath = Join-Path $LiveHooksRoot 'serena-hooks.exe'
$unknownPath = Join-Path $LiveHooksRoot 'unknown-hook.cmd'

$probeBody = "@echo off`r`necho executed>`"$probeMarker`"`r`n"
foreach ($path in @($providerPath, $githubPath, $statePath, $dashboardPath, $serenaHooksPath, $unknownPath)) {
    Write-TestText -Path $path -Value $probeBody
}

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
            [pscustomobject][ordered]@{ hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $providerPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $githubPath; timeout = 10 }) }
            [pscustomobject][ordered]@{ hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $statePath; timeout = 10 }) }
            [pscustomobject][ordered]@{ matcher = 'startup|resume'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $activatePath; timeout = 10 }) }
            [pscustomobject][ordered]@{ customGroupField = 'preserve-me'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $dashboardPath; timeout = 10 }) }
        )
        Stop = @(
            [pscustomobject][ordered]@{
                hooks = @(
                    [pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $serenaHooksPath @('cleanup', '--client=codex'); timeout = 10 }
                    [pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $serenaHooksPath @('cleanup', '--client=codex'); timeout = 10 }
                )
            }
        )
        FutureEvent = @(
            [pscustomobject][ordered]@{ matcher = 'future'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = ConvertTo-TestCommand $unknownPath; timeout = 7 }) }
        )
    }
    unknownTopLevel = 'preserve-me'
}
$RegistryPath = Join-Path $CodexHome 'hooks.json'
Write-TestText -Path $RegistryPath -Value ($registry | ConvertTo-Json -Depth 100)

$facts = Get-CodexHookRegistryFacts -RegistryPath $RegistryPath
Assert-True ($facts.events.SessionStart.Count -eq 5) '必须看到全部 SessionStart'
Assert-True ($facts.events.SessionStart[1].idMatch -eq 'github-cli') '必须观察 GitHub 插入索引 1'
Assert-True (-not $facts.events.SessionStart[3].targetExists) '必须观察缺失 target'
Assert-True ($facts.events.PSObject.Properties.Name -contains 'FutureEvent') '必须保留未知 event 事实'
Assert-True ($facts.events.FutureEvent[0].idMatch -eq $null) '未知 command 不得伪造受管 id'
Assert-True (@($facts.events.Stop).Count -eq 2) '必须保留重复 command 的两个事实'
Assert-True ($facts.events.Stop[0].command -ceq $facts.events.Stop[1].command) '重复受管 command 必须可观察'
Assert-True (-not ($facts | ConvertTo-Json -Depth 20).Contains('trusted_hash')) 'registry facts 不得泄露 trust hash'
Assert-True (-not (Test-Path -LiteralPath $probeMarker)) 'registry inventory 不得执行 hook'

$fixtureManifest = Read-CodexHookManifest -Path (Join-Path $ProjectRoot 'managed\codex-hooks\manifest.json')
$fixtureManifest.codexHome = $CodexHome
$fixtureManifest.managedRoot = $ManagedRoot
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
Write-TestText -Path (Join-Path $LiveHooksRoot 'present.cmd') -Value 'abc'
$fileFacts = @(Get-CodexHookFileFacts -Manifest $fixtureManifest -ManagedRoot $ManagedRoot -LiveHooksRoot $LiveHooksRoot)
Assert-True ($fileFacts.Count -eq 2) '必须逐项输出 manifest file facts'
Assert-True ($fileFacts[0].managedExists -and $fileFacts[0].liveExists) '存在文件必须被观察'
Assert-True ($fileFacts[0].managedMatchesManifest -and $fileFacts[0].liveMatchesManifest) '匹配 SHA-256 必须被观察'
Assert-True (-not $fileFacts[1].managedExists) 'managed 缺文件必须作为事实缺口输出'
Assert-True (-not $fileFacts[1].liveExists) 'live 缺文件必须作为事实缺口输出'

$document = New-CodexHookInventoryDocument -Manifest $fixtureManifest -Registry $facts -FileFacts $fileFacts -TrustObservation @()
Assert-True ($document.artifactType -ceq 'env-governance.codex-hook-inventory') 'inventory artifactType 必须固定'
Assert-True ($document.schemaVersion -eq 1) 'inventory schemaVersion 必须固定'
Assert-True ($document.readOnly -and -not $document.executionAllowed) 'inventory 必须明确只读且禁止执行'
Assert-True (@($document.trustObservation).Count -eq 0) '缺 trust observation 必须作为空事实保留'
Assert-True (-not (($document | ConvertTo-Json -Depth 100).Contains('trusted_hash'))) 'inventory document 不得伪造或泄露 trust hash'

$FixtureManifestPath = Join-Path $FixtureRoot 'manifest.json'
Write-TestText -Path $FixtureManifestPath -Value ($fixtureManifest | ConvertTo-Json -Depth 100)
$trustSecret = 'DO_NOT_LEAK_FULL_TRUST_HASH_0123456789'
Write-TestText -Path (Join-Path $CodexHome 'config.toml') -Value "[hooks.state]`ntrusted_hash_0 = `"$trustSecret`"`nunknown_key = `"preserve`"`n"

Assert-Throws {
    & $InventoryScript `
        -ManifestPath $FixtureManifestPath `
        -CodexHome $CodexHome `
        -OutputDir (Join-Path $CodexHome 'forbidden-inventory-output') |
        Out-Null
} 'inventory OutputDir 不得位于 CodexHome live 树内'

$published = & $InventoryScript -ManifestPath $FixtureManifestPath -CodexHome $CodexHome -OutputDir $OutputDir
$publishedJson = [IO.File]::ReadAllText((Join-Path $OutputDir 'inventory.json'))
$publishedDocument = $publishedJson | ConvertFrom-Json -Depth 100
Assert-True ($publishedDocument.artifactType -ceq 'env-governance.codex-hook-inventory') '入口必须发布 inventory JSON'
Assert-True ($publishedDocument.readOnly -and -not $publishedDocument.executionAllowed) '入口不得宣称可执行'
Assert-True ($publishedJson -notlike "*$trustSecret*") '入口不得输出完整 trust value'
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
