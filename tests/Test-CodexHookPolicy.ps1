Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PolicyPath = Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1'
if (Test-Path -LiteralPath $PolicyPath) {
    . $PolicyPath
}

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

function Copy-TestDocument {
    param([Parameter(Mandatory)][object]$Document)

    return ($Document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
}

function New-ValidManifest {
    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-manifest'
        schemaVersion = 1
        codexHome = 'D:\Codex\.codex'
        managedRoot = 'D:\Codex\projects\统一环境\managed\codex-hooks'
        runtimes = [pscustomobject][ordered]@{
            pwsh = 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe'
            python = 'D:\Codex\tools\python314-official\python.exe'
            serenaPython = 'D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe'
            serenaHooks = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
        }
        hooks = @(
            [pscustomobject][ordered]@{
                id = 'provider-stability'
                event = 'SessionStart'
                order = 0
                matcher = $null
                timeoutSeconds = 10
                commandPath = 'D:\Codex\.codex\hooks\codex-provider-stability-guard.cmd'
                arguments = @()
                wrapperPath = 'D:\Codex\.codex\hooks\codex-provider-stability-guard.cmd'
                implementationPath = 'D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1'
                runtimeId = 'pwsh'
                readResources = @([pscustomobject][ordered]@{ kind = 'path'; value = 'D:\Codex\.codex\config.toml' })
                writeResources = @([pscustomobject][ordered]@{ kind = 'abstract'; value = 'hook-stdout' })
                criticality = 'critical'
                lifecycle = 'active'
                lifecycleReason = $null
                quickHealthCheck = [pscustomobject][ordered]@{
                    commandPath = 'D:\Codex\.codex\hooks\codex-provider-stability-guard.cmd'
                    arguments = @('-Json')
                }
                fullAcceptanceCommand = [pscustomobject][ordered]@{
                    commandPath = 'D:\Codex\.codex\hooks\codex-provider-stability-guard.cmd'
                    arguments = @('-Json', '-CheckNetwork')
                }
            }
        )
        files = @()
        environment = @()
    }
}

$validJson = '{"artifactType":"env-governance.codex-hook-manifest","schemaVersion":1}'
Assert-CodexHookStrictJsonText -JsonText $validJson

$duplicateJson = '{"artifactType":"env-governance.codex-hook-manifest","artifactType":"x","schemaVersion":1}'
Assert-Throws { Assert-CodexHookStrictJsonText -JsonText $duplicateJson } '重复 JSON 属性'
Assert-Throws { Assert-CodexHookStrictJsonText -JsonText '{"schemaVersion":1,}' } '尾随逗号'
Assert-Throws { Assert-CodexHookStrictJsonText -JsonText '{/*comment*/"schemaVersion":1}' } 'JSON comment'

$valid = New-ValidManifest
Assert-True (Assert-CodexHookManifest -Manifest $valid) '合法 manifest 必须通过'

$case = Copy-TestDocument $valid
$case | Add-Member -NotePropertyName smuggled -NotePropertyValue $true
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '未知顶层属性'

$case = Copy-TestDocument $valid
$case.artifactType = 'x'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '错误 artifactType'

$case = Copy-TestDocument $valid
$case.schemaVersion = 1.0
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '非整数 schema'

$case = Copy-TestDocument $valid
$case.codexHome = 'C:\Users\fixture\.codex'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'codexHome 必须位于 D:\'

$case = Copy-TestDocument $valid
$case.codexHome = 'D:\arbitrary\.codex'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'codexHome 必须严格固定'

$case = Copy-TestDocument $valid
$case.managedRoot = 'D:\arbitrary\managed'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'managedRoot 必须严格固定'

$case = Copy-TestDocument $valid
$case.runtimes.PSObject.Properties.Remove('python')
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '缺 runtime'

$case = Copy-TestDocument $valid
$case.runtimes.pwsh = 'D:\Codex\tools\python314-official\python.exe'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'runtime 路径/类型错配'

$case = Copy-TestDocument $valid
$case.hooks[0].runtimeId = 'python'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'hook implementation/runtime 类型错配'

$case = Copy-TestDocument $valid
$case.hooks[0].readResources[0].value = 'D:\Codex\.codex\config.toml:secret'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '绝对资源路径不得使用 ADS'

$case = Copy-TestDocument $valid
$case.hooks[0].quickHealthCheck.arguments = @('--token=DO_NOT_DECLARE_SECRET')
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'health command 不得声明敏感参数'

$case = Copy-TestDocument $valid
$duplicateHook = Copy-TestDocument $case.hooks[0]
$duplicateHook.commandPath = 'D:\Codex\.codex\hooks\another.cmd'
$case.hooks = @($case.hooks) + @($duplicateHook)
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '重复 id'

$case = Copy-TestDocument $valid
$duplicateHook = Copy-TestDocument $case.hooks[0]
$duplicateHook.id = 'another-hook'
$duplicateHook.order = 1
$case.hooks = @($case.hooks) + @($duplicateHook)
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '重复 active command'

$case = Copy-TestDocument $valid
$case.hooks[0].criticality = 'best-effort'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '非法 criticality'

foreach ($invalidRelativePath in @('\evil.cmd', '/evil.cmd', 'D:relative.cmd', 'hooks/file.cmd:secret', 'hooks/*.cmd', 'hooks/CON.cmd', 'hooks/bad|name.cmd')) {
    $case = Copy-TestDocument $valid
    $case.files = @([pscustomobject][ordered]@{
        relativePath = $invalidRelativePath
        liveRelativePath = 'safe.cmd'
        sha256 = ('0' * 64)
        lifecycle = 'active'
        ownerHookIds = @('provider-stability')
    })
    Assert-Throws { Assert-CodexHookManifest -Manifest $case } "非法相对路径：$invalidRelativePath"
}

$case = Copy-TestDocument $valid
$case.environment = @([pscustomobject][ordered]@{ name = 'SERENA_HOME'; scope = 'Machine'; desired = 'D:\Codex\.serena'; restartRequired = $true })
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'environment scope 必须精确'

foreach ($invalidTimeout in @(0, 30)) {
    $case = Copy-TestDocument $valid
    $case.hooks[0].timeoutSeconds = $invalidTimeout
    Assert-Throws { Assert-CodexHookManifest -Manifest $case } "非法 timeout：$invalidTimeout"
}

$managedManifestPath = Join-Path $ProjectRoot 'managed\codex-hooks\manifest.json'
$managedManifest = Read-CodexHookManifest -Path $managedManifestPath
Assert-True (@($managedManifest.hooks).Count -eq 8) '受管 manifest 必须声明 8 个当前 hook'
Assert-True (@($managedManifest.files).Count -eq 12) '受管 manifest 必须声明 12 个审计快照文件'
Assert-True (@($managedManifest.environment).Count -eq 0) 'Task 1 不得提前声明环境写入'

$sessionStartIds = @(
    $managedManifest.hooks |
        Where-Object event -ceq 'SessionStart' |
        Sort-Object order |
        ForEach-Object id
)
Assert-True (
    ($sessionStartIds -join ',') -ceq 'provider-stability,codex-state-policy,serena-activate,serena-dashboard,github-cli'
) 'SessionStart 受管顺序必须固定为 provider/state/activate/dashboard/GitHub'

$autoApprove = @($managedManifest.hooks | Where-Object id -ceq 'serena-auto-approve')
Assert-True (
    $autoApprove.Count -eq 1 -and $autoApprove[0].lifecycle -ceq 'retired'
) 'Serena auto-approve 在 Task 1 必须声明为 retired'

Assert-True (
    $managedManifest.runtimes.pwsh -ceq 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -and
    $managedManifest.runtimes.python -ceq 'D:\Codex\tools\python314-official\python.exe' -and
    $managedManifest.runtimes.serenaPython -ceq 'D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe' -and
    $managedManifest.runtimes.serenaHooks -ceq 'D:\Codex\tools\uv\bin\serena-hooks.exe'
) 'runtime manifest 必须使用 brief 固定路径'

[pscustomobject]@{
    ok = $true
    suite = 'CodexHookPolicy'
}
