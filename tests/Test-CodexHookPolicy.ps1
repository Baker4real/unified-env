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

function Invoke-HiddenNativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "native command 无法启动：$FilePath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-True ($process.WaitForExit(30000)) "native command 超时：$FilePath"
        [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch {}
        }
        $process.Dispose()
    }
}

Assert-True (
    (Get-CodexHookBytesSha256 -Bytes ([byte[]]@())) -ceq
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
) '空文件字节数组必须产生稳定 SHA-256，而不是被误判为缺少参数'

function Copy-TestDocument {
    param([Parameter(Mandatory)][object]$Document)

    return ($Document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
}

function New-ValidManifest {
    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-manifest'
        schemaVersion = 1
        codexHome = 'D:\Codex\.codex'
        managedRoot = 'D:\agents\projects\统一环境\managed\codex-hooks'
        runtimes = [pscustomobject][ordered]@{
            pwsh = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
            python = 'D:\Codex\tools\python314-official\python.exe'
            pythonw = 'D:\Codex\tools\python314-official\pythonw.exe'
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
                launcherRuntimeId = $null
                launcherImplementationPath = $null
                sourceState = 'managed'
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
        files = @(
            [pscustomobject][ordered]@{
                relativePath = 'hooks/codex-provider-stability-guard.cmd'
                liveRelativePath = 'codex-provider-stability-guard.cmd'
                sha256 = ('0' * 64)
                lifecycle = 'active'
                ownerHookIds = @('provider-stability')
            }
            [pscustomobject][ordered]@{
                relativePath = 'hooks/codex-provider-stability-guard.ps1'
                liveRelativePath = 'codex-provider-stability-guard.ps1'
                sha256 = ('0' * 64)
                lifecycle = 'active'
                ownerHookIds = @('provider-stability')
            }
        )
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
$case.hooks[0].launcherRuntimeId = 'pythonw'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'launcher runtime/path 必须成对声明'

$case = Copy-TestDocument $valid
$case.hooks[0].launcherImplementationPath = 'D:\Codex\.codex\hooks\lib\hidden-console-launcher.py'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'launcher path/runtime 必须成对声明'

$case = Copy-TestDocument $valid
$case.hooks[0].launcherRuntimeId = 'python'
$case.hooks[0].launcherImplementationPath = 'D:\Codex\.codex\hooks\lib\hidden-console-launcher.py'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'launcher runtime 必须固定为 pythonw'

$case = Copy-TestDocument $valid
$case.hooks[0].launcherRuntimeId = 'pythonw'
$case.hooks[0].launcherImplementationPath = 'D:\Codex\.codex\outside\hidden-console-launcher.py'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'launcher implementation 必须位于 live hooks 根'

$case = Copy-TestDocument $valid
$case.hooks[0].readResources[0].value = 'D:\Codex\.codex\config.toml:secret'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } '绝对资源路径不得使用 ADS'

$case = Copy-TestDocument $valid
$case.hooks[0].quickHealthCheck.arguments = @('--token=DO_NOT_DECLARE_SECRET')
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'health command 不得声明敏感参数'

foreach ($credentialFlag in @('--token', '--password', '--api-key')) {
    $case = Copy-TestDocument $valid
    $case.hooks[0].quickHealthCheck.arguments = @($credentialFlag, 'DO_NOT_DECLARE_SECRET')
    Assert-Throws { Assert-CodexHookManifest -Manifest $case } "health command 不得声明分离式 credential：$credentialFlag"
}

$case = Copy-TestDocument $valid
$case.hooks[0].quickHealthCheck.arguments = @('--check-only', '--json', 'ordinary-value')
Assert-True (Assert-CodexHookManifest -Manifest $case) '非敏感分离参数必须保留合法'

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

foreach ($enumCase in @(
    @{ Property = 'event'; Value = 'sessionstart'; Label = 'event case' }
    @{ Property = 'criticality'; Value = 'Critical'; Label = 'criticality case' }
    @{ Property = 'lifecycle'; Value = 'Active'; Label = 'hook lifecycle case' }
    @{ Property = 'sourceState'; Value = 'Managed'; Label = 'sourceState case' }
)) {
    $case = Copy-TestDocument $valid
    $case.hooks[0].($enumCase.Property) = $enumCase.Value
    Assert-Throws { Assert-CodexHookManifest -Manifest $case } "enum 必须大小写敏感：$($enumCase.Label)"
}

$case = Copy-TestDocument $valid
$case.hooks[0].readResources[0].kind = 'Path'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'resource kind 必须大小写敏感'

$case = Copy-TestDocument $valid
$case.hooks[0].writeResources[0].value = 'Hook-Stdout'
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'abstract resource 必须大小写敏感'

$case = Copy-TestDocument $valid
$case.hooks[0].quickHealthCheck.commandPath = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$case.hooks[0].quickHealthCheck.arguments = @('-NoProfile', '-Command', 'Write-Output ok')
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'pwsh health script 必须在受控 allowlist'

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
$case.files = @([pscustomobject][ordered]@{
    relativePath = 'hooks/provider.cmd'
    liveRelativePath = 'provider.cmd'
    sha256 = ('0' * 64)
    lifecycle = 'Active'
    ownerHookIds = @('provider-stability')
})
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'file lifecycle 必须大小写敏感'

$case = Copy-TestDocument $valid
$retiredFile = Copy-TestDocument $case.files[0]
$retiredFile.relativePath = 'retired/provider-legacy.cmd'
$retiredFile.liveRelativePath = 'provider-legacy.cmd'
$retiredFile.lifecycle = 'retired'
$retiredFile | Add-Member -NotePropertyName deleteLive -NotePropertyValue $false
$case.files = @($case.files) + $retiredFile
[void](Assert-CodexHookManifest -Manifest $case)
$case.files[-1].deleteLive = $true
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'retired file 不得默认删除 live 文件'

$case = Copy-TestDocument $valid
$case.environment = @([pscustomobject][ordered]@{ name = 'SERENA_HOME'; scope = 'Machine'; desired = 'D:\Codex\.serena'; restartRequired = $true })
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'environment scope 必须精确'

$case = Copy-TestDocument $valid
$case.environment = @([pscustomobject][ordered]@{ name = 'serena_home'; scope = 'User'; desired = 'D:\Codex\.serena'; restartRequired = $true })
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'environment name 必须大小写敏感且固定'

$case = Copy-TestDocument $valid
$case.environment = @([pscustomobject][ordered]@{ name = 'SERENA_HOME'; scope = 'User'; desired = 'D:\other\.serena'; restartRequired = $true })
Assert-Throws { Assert-CodexHookManifest -Manifest $case } 'environment desired 必须固定'

$case = Copy-TestDocument $valid
$case.environment = @([pscustomobject][ordered]@{ name = 'SERENA_HOME'; scope = 'User'; desired = 'D:\Codex\.serena'; restartRequired = $true })
Assert-True (Assert-CodexHookManifest -Manifest $case) '唯一批准的 environment policy 必须合法'

foreach ($invalidTimeout in @(0, 30)) {
    $case = Copy-TestDocument $valid
    $case.hooks[0].timeoutSeconds = $invalidTimeout
    Assert-Throws { Assert-CodexHookManifest -Manifest $case } "非法 timeout：$invalidTimeout"
}

$managedManifestPath = Join-Path $ProjectRoot 'managed\codex-hooks\manifest.json'
$managedManifest = Read-CodexHookManifest -Path $managedManifestPath

$legacyFixtureManifestPath = Join-Path $ProjectRoot 'managed\codex-hooks\legacy-fixture-manifest.json'
$hostPreflightManifestPath = Join-Path $ProjectRoot 'managed\codex-hooks\host-preflight-manifest.json'
$hiddenLauncherRelativePath = 'managed/codex-hooks/hooks/lib/hidden-console-launcher.py'
$hiddenLauncherSourcePath = Join-Path $ProjectRoot ($hiddenLauncherRelativePath.Replace('/', '\'))
Assert-True (Test-Path -LiteralPath $legacyFixtureManifestPath -PathType Leaf) '必须提供仅供历史 fixture 使用的 legacy manifest'
Assert-True (Test-Path -LiteralPath $hostPreflightManifestPath -PathType Leaf) '必须提供唯一生产 host-preflight manifest'
Assert-True (Test-Path -LiteralPath $hiddenLauncherSourcePath -PathType Leaf) '必须提供受管 hidden console launcher 源文件'
$gitCommands = @(Get-Command git.exe -CommandType Application -ErrorAction Stop)
Assert-True ($gitCommands.Count -gt 0) '必须能够解析真实 git.exe 以验证 Git 属性'
$gitPath = [string]$gitCommands[0].Source
$gitAttributeResult = Invoke-HiddenNativeCommand -FilePath $gitPath -ArgumentList @('-C', $ProjectRoot, 'check-attr', 'text', 'eol', '--', $hiddenLauncherRelativePath)
Assert-True ($gitAttributeResult.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($gitAttributeResult.stderr)) 'git check-attr 必须能够读取 hidden console launcher 属性'
$hiddenLauncherAttributes = @([regex]::Split($gitAttributeResult.stdout.Trim(), '\r?\n'))
Assert-True (
    $hiddenLauncherAttributes.Count -eq 2 -and
    [string]$hiddenLauncherAttributes[0] -ceq ('{0}: text: set' -f $hiddenLauncherRelativePath) -and
    [string]$hiddenLauncherAttributes[1] -ceq ('{0}: eol: lf' -f $hiddenLauncherRelativePath)
) 'hidden console launcher 必须由 Git 属性固定为 text eol=lf'
$legacyFixtureManifest = Read-CodexHookManifest -Path $legacyFixtureManifestPath
$hostPreflightManifest = Read-CodexHookManifest -Path $hostPreflightManifestPath
Assert-True ($hostPreflightManifest.runtimes.python -ceq 'D:\Codex\tools\python315-official\python.exe') '现役 preflight 必须固定 Python 3.15。'
$oldHostRuntime = Copy-TestDocument $hostPreflightManifest
$oldHostRuntime.runtimes.python = 'D:\Codex\tools\python314-official\python.exe'
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $oldHostRuntime | Out-Null } '现役 preflight 不得退回 Python 3.14。'
$hostHiddenLauncherFile = @($hostPreflightManifest.files | Where-Object relativePath -ceq 'hooks/lib/hidden-console-launcher.py')
Assert-True ($hostHiddenLauncherFile.Count -eq 1) 'host-preflight manifest 必须唯一声明 hidden console launcher'
[byte[]]$hiddenLauncherRawBytes = [IO.File]::ReadAllBytes($hiddenLauncherSourcePath)
$hiddenLauncherRawSha256 = Get-CodexHookBytesSha256 -Bytes $hiddenLauncherRawBytes
Assert-True (
    [string]$hostHiddenLauncherFile[0].sha256 -ceq $hiddenLauncherRawSha256
) 'host-preflight manifest 的 hidden console launcher SHA-256 必须匹配工作树原始字节，不得只匹配 canonical text hash'
[void](Read-CodexHookHostPreflightManifest)
[void](Read-CodexHookLegacyFixtureManifest)
$expectedTrustedProjects = @(
    'D:\agents\projects\时钟倒计时',
    'D:\agents\projects\统一环境',
    'D:\agents\projects\杨杨子',
    'D:\Codex\projects\codex-account-switch',
    'D:\Codex\projects\CodexProviderSync',
    'D:\agents\projects\minmin-calendar'
)
Assert-True ((@($hostPreflightManifest.trustedProjects) -join "`0") -ceq ($expectedTrustedProjects -join "`0")) 'host-preflight manifest 必须只声明当前六个精确项目根的 trust 投影'
Assert-True (-not (@($hostPreflightManifest.trustedProjects) -ccontains 'D:\Codex\projects')) 'host-preflight manifest 不得信任 projects 集合根'
$expectedRetiredProjectTrusts = @(
    'D:\Codex\projects\codex-gsd-codex-c-skill'
)
Assert-True ((@($hostPreflightManifest.retiredProjectTrusts) -join "`0") -ceq ($expectedRetiredProjectTrusts -join "`0")) 'host-preflight manifest 必须只声明旧 GSD 精确 project trust denylist'
Assert-Throws { Read-CodexHookHostPreflightManifest -Path $legacyFixtureManifestPath | Out-Null } 'legacy manifest 不得提供 production identity'
Assert-Throws { Read-CodexHookLegacyFixtureManifest -Path $hostPreflightManifestPath | Out-Null } 'host manifest 不得伪装历史 fixture identity'
$missingHostRetiredTrusts = Copy-TestDocument $hostPreflightManifest
[void]$missingHostRetiredTrusts.PSObject.Properties.Remove('retiredProjectTrusts')
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $missingHostRetiredTrusts | Out-Null } 'host manifest 缺少 retired project trust denylist 必须被拒绝'
$duplicateHostRetiredTrusts = Copy-TestDocument $hostPreflightManifest
$duplicateHostRetiredTrusts.retiredProjectTrusts = @(
    'D:\Codex\projects\codex-gsd-codex-c-skill',
    'D:\CODEX\PROJECTS\CODEX-GSD-CODEX-C-SKILL'
)
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $duplicateHostRetiredTrusts | Out-Null } 'host manifest retired project trust 的大小写重复必须被拒绝'
$overlappingHostRetiredTrusts = Copy-TestDocument $hostPreflightManifest
$overlappingHostRetiredTrusts.retiredProjectTrusts = @('D:\CODEX\PROJECTS\MINMIN-CALENDAR')
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $overlappingHostRetiredTrusts | Out-Null } 'host manifest retired project trust 不得与 trusted project 重叠'
$collectionRootRetiredTrusts = Copy-TestDocument $hostPreflightManifest
$collectionRootRetiredTrusts.retiredProjectTrusts = @('D:\Codex\projects')
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $collectionRootRetiredTrusts | Out-Null } 'host manifest retired project trust 不得使用 projects 集合根'
$outOfRootRetiredTrusts = Copy-TestDocument $hostPreflightManifest
$outOfRootRetiredTrusts.retiredProjectTrusts = @('D:\Codex\retired-project')
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $outOfRootRetiredTrusts | Out-Null } 'host manifest retired project trust 必须位于 projects 根下'
$duplicateHostTrustedProjects = Copy-TestDocument $hostPreflightManifest
$duplicateHostTrustedProjects.trustedProjects += 'D:\CODEX\PROJECTS\MINMIN-CALENDAR'
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $duplicateHostTrustedProjects | Out-Null } 'host manifest trusted project 的大小写重复必须被拒绝'
$mutatedHostHookIdentity = Copy-TestDocument $hostPreflightManifest
@($mutatedHostHookIdentity.hooks | Where-Object id -ceq 'serena-reminder')[0].order = 9
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $mutatedHostHookIdentity | Out-Null } 'host manifest 必须冻结 Serena reminder 的完整 identity'
$mutatedHostFileClosure = Copy-TestDocument $hostPreflightManifest
@($mutatedHostFileClosure.files | Where-Object liveRelativePath -ceq 'serena-reminder-guarded.cmd')[0].sha256 = ('0' * 64)
Assert-Throws { Assert-CodexHookHostPreflightManifest -Manifest $mutatedHostFileClosure | Out-Null } 'host manifest 必须冻结 8-file closure 的精确 hash map'
$expectedProductionHookIds = @('codex-state-preflight', 'serena-activate', 'github-cli', 'serena-cleanup', 'serena-reminder')
Assert-True (
    (@($hostPreflightManifest.hooks | ForEach-Object id | Sort-Object) -join ',') -ceq
    (@($expectedProductionHookIds | Sort-Object) -join ',')
) 'production manifest 必须声明 state preflight、github-cli 与三项 Serena 行为 hook'
foreach ($forbiddenHookId in @('provider-stability', 'serena-dashboard', 'serena-auto-approve')) {
    Assert-True (@($hostPreflightManifest.hooks | Where-Object id -ceq $forbiddenHookId).Count -eq 0) "production manifest 不得包含旧/显式维护 identity：$forbiddenHookId"
}
$productionStateHook = @($hostPreflightManifest.hooks | Where-Object id -ceq 'codex-state-preflight')[0]
Assert-True (
    $productionStateHook.commandPath -ceq 'D:\Codex\.codex\hooks\codex-state-preflight.cmd' -and
    $productionStateHook.wrapperPath -ceq 'D:\Codex\.codex\hooks\codex-state-preflight.cmd' -and
    $productionStateHook.implementationPath -ceq 'D:\Codex\.codex\hooks\codex-state-preflight.py'
) 'production state identity 必须指向 local-only state preflight，不得恢复旧 projectless wrapper'
foreach ($forbiddenLivePath in @(
    'codex-projectless-root-d.cmd',
    'codex-projectless-root-d.js',
    'codex-mobile-permission-guard.cmd',
    'codex-mobile-permission-guard.py',
    'serena-auto-approve.cmd'
)) {
    Assert-True (@($hostPreflightManifest.files | Where-Object liveRelativePath -ceq $forbiddenLivePath).Count -eq 0) "production manifest 不得包含退役双写/auto-approve 文件：$forbiddenLivePath"
}
Assert-True (@($legacyFixtureManifest.hooks).Count -gt @($hostPreflightManifest.hooks).Count) 'legacy fixture manifest 必须保留历史测试闭包，而非伪装 production manifest'
$stateGuardSource = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'managed\codex-hooks\hooks\codex-state-policy-guard.py')
Assert-True ($stateGuardSource.Contains('def resolve_permission_policy(')) 'state guard 必须从受控来源解析权限策略'
Assert-True ($stateGuardSource.Contains('path_mode: str = "inventory"')) 'state guard 必须公开 inventory path mode'
Assert-True ($stateGuardSource.Contains('approved_map: object = None')) 'state guard 必须要求显式 approved map 才能修复路径'
Assert-True ($stateGuardSource.Contains('permission policy sources conflict')) '策略来源冲突必须 fail closed'
Assert-True (@($managedManifest.hooks).Count -eq 8) '兼容 manifest 必须继续覆盖 Task 1-5 的当前 hook 模型'
Assert-True (@($managedManifest.files).Count -eq 24) '兼容 manifest 必须纳入 state preflight、hidden launcher、Serena behavior wrapper 与 provider core 的完整文件闭包'
Assert-True (@($legacyFixtureManifest.files).Count -eq 16) 'legacy fixture manifest 必须冻结 13 active + 3 retired 历史事务闭包'
Assert-True (
    @($hostPreflightManifest.files | Where-Object liveRelativePath -ceq 'codex-state-preflight.py').Count -eq 1 -and
    @($hostPreflightManifest.files | Where-Object liveRelativePath -ceq 'codex-state-preflight.cmd').Count -eq 1
) 'host-preflight manifest 必须唯一声明 state preflight 实现与固定 wrapper'
Assert-True (
    @($managedManifest.environment).Count -eq 1 -and
    $managedManifest.environment[0].name -ceq 'SERENA_HOME' -and
    $managedManifest.environment[0].scope -ceq 'User' -and
    $managedManifest.environment[0].desired -ceq 'D:\Codex\.serena' -and
    $managedManifest.environment[0].restartRequired -eq $true
) 'manifest 必须只声明受管 User SERENA_HOME 环境动作'

$normalizedDuplicate = Copy-TestDocument $managedManifest
$duplicateFile = Copy-TestDocument $normalizedDuplicate.files[0]
$duplicateFile.relativePath = $duplicateFile.relativePath.Replace('/', '\')
$duplicateFile.liveRelativePath = 'duplicate-auxiliary.cmd'
$normalizedDuplicate.files = @($normalizedDuplicate.files) + @($duplicateFile)
Assert-Throws { Assert-CodexHookManifest -Manifest $normalizedDuplicate } 'files relativePath 必须在斜杠规范化后唯一'

$emptyOwner = Copy-TestDocument $managedManifest
$emptyOwner.files[0].ownerHookIds = @()
Assert-Throws { Assert-CodexHookManifest -Manifest $emptyOwner } 'file ownerHookIds 不得为空'

$unrelatedOwner = Copy-TestDocument $managedManifest
$unrelatedOwner.files[0].ownerHookIds = @('provider-stability')
Assert-Throws { Assert-CodexHookManifest -Manifest $unrelatedOwner } 'wrapper role file 不得声称无关 owner'

$missingImplementationClosure = Copy-TestDocument $managedManifest
$missingImplementationClosure.files = @($missingImplementationClosure.files | Where-Object liveRelativePath -cne 'codex-provider-stability-guard.ps1')
Assert-Throws { Assert-CodexHookManifest -Manifest $missingImplementationClosure } 'managed custom implementation 必须具备 file 闭包'

$retiredWrapperClosure = Copy-TestDocument $managedManifest
@($retiredWrapperClosure.files | Where-Object liveRelativePath -ceq 'codex-provider-stability-guard.cmd')[0].lifecycle = 'retired'
Assert-Throws { Assert-CodexHookManifest -Manifest $retiredWrapperClosure } 'active custom wrapper 不得只由 retired file 提供'

$plannedWithFakeHash = Copy-TestDocument $managedManifest
$plannedWithFakeHash.files = @($plannedWithFakeHash.files) + @([pscustomobject][ordered]@{
    relativePath = 'hooks/codex-state-policy-guard.py'
    liveRelativePath = 'codex-state-policy-guard.py'
    sha256 = ('0' * 64)
    lifecycle = 'active'
    ownerHookIds = @('codex-state-policy')
})
Assert-Throws { Assert-CodexHookManifest -Manifest $plannedWithFakeHash } 'planned implementation 不得伪造 files SHA-256'

$outsidePublishLayout = Copy-TestDocument $managedManifest
$outsidePublishLayout.files = @($outsidePublishLayout.files) + @([pscustomobject][ordered]@{
    relativePath = 'misc/unpublishable.cmd'
    liveRelativePath = 'unpublishable.cmd'
    sha256 = ('0' * 64)
    lifecycle = 'compatibility'
    ownerHookIds = @('provider-stability')
})
Assert-Throws { Assert-CodexHookManifest -Manifest $outsidePublishLayout } 'source relativePath 必须位于可发布布局'

$duplicateRetiredIdentity = Copy-TestDocument $managedManifest
$duplicateHook = Copy-TestDocument @($duplicateRetiredIdentity.hooks | Where-Object id -ceq 'serena-cleanup')[0]
$duplicateHook.id = 'serena-cleanup-retired-copy'
$duplicateHook.lifecycle = 'retired'
$duplicateHook.lifecycleReason = 'identity uniqueness fixture'
$duplicateHook.order = 99
$duplicateRetiredIdentity.hooks = @($duplicateRetiredIdentity.hooks) + @($duplicateHook)
Assert-Throws { Assert-CodexHookManifest -Manifest $duplicateRetiredIdentity } 'retired 在内的全部 manifest identity 必须唯一'

$retiredReplacementOrder = Copy-TestDocument $managedManifest
$retiredReplacement = Copy-TestDocument @($retiredReplacementOrder.hooks | Where-Object id -ceq 'serena-cleanup')[0]
$retiredReplacement.id = 'serena-cleanup-retired-replacement'
$retiredReplacement.lifecycle = 'retired'
$retiredReplacement.lifecycleReason = 'retired replacement may retain the active order'
$retiredReplacement.commandPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
$retiredReplacement.wrapperPath = $null
$retiredReplacement.implementationPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
$retiredReplacement.runtimeId = 'serenaHooks'
$retiredReplacement.sourceState = 'vendor'
$retiredReplacement.arguments = @('cleanup-retired', '--client=codex')
$retiredReplacement.quickHealthCheck.arguments = @('-NoProfile', '-Command', "Test-Path -LiteralPath 'D:\Codex\tools\uv\bin\serena-hooks.exe'")
$retiredReplacement.fullAcceptanceCommand.commandPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
$retiredReplacement.fullAcceptanceCommand.arguments = @('cleanup-retired', '--client=codex')
$retiredReplacementOrder.hooks = @($retiredReplacementOrder.hooks) + @($retiredReplacement)
Assert-True (Assert-CodexHookManifest -Manifest $retiredReplacementOrder) 'event/order 唯一性只约束 active+compatibility；retired replacement 可保留同 order'

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
    $autoApprove.Count -eq 1 -and
    $autoApprove[0].lifecycle -ceq 'retired' -and
    $autoApprove[0].lifecycleReason -ceq 'Codex payload does not expose acceptEdits/auto permission modes'
) 'Serena auto-approve 必须以精确原因声明为 retired'
Assert-True (
    $autoApprove[0].fullAcceptanceCommand.commandPath -ceq 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -and
    @($autoApprove[0].fullAcceptanceCommand.arguments) -ccontains 'D:\agents\projects\统一环境\scripts\Get-CodexHookInventory.ps1' -and
    $autoApprove[0].fullAcceptanceCommand.arguments[-1] -ceq '-RequireNoRetiredRegistrations' -and
    -not (($autoApprove[0].fullAcceptanceCommand.arguments -join ' ').Contains('Get-Content'))
) 'auto-approve full acceptance 必须走带 retirement 断言的结构化 inventory 入口而非 grep registry 原文'

$sourceStates = @($managedManifest.hooks | Group-Object sourceState -AsHashTable -AsString)
Assert-True (
    @($managedManifest.hooks | Where-Object sourceState -ceq 'planned').Count -eq 0 -and
    @($managedManifest.hooks | Where-Object sourceState -ceq 'vendor').Count -eq 1 -and
    @($managedManifest.hooks | Where-Object sourceState -ceq 'managed').Count -eq 7
) 'sourceState 必须诚实区分 managed/planned/vendor'

Assert-True (
    $managedManifest.runtimes.pwsh -ceq 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -and
    $managedManifest.runtimes.python -ceq 'D:\Codex\tools\python314-official\python.exe' -and
    $managedManifest.runtimes.pythonw -ceq 'D:\Codex\tools\python314-official\pythonw.exe' -and
    $managedManifest.runtimes.serenaPython -ceq 'D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe' -and
    $managedManifest.runtimes.serenaHooks -ceq 'D:\Codex\tools\uv\bin\serena-hooks.exe'
) 'runtime manifest 必须使用 brief 固定路径'

$runtimeFile=@($managedManifest.files|Where-Object relativePath -ceq 'hooks/lib/CodexHookRuntime.ps1')
Assert-True ($runtimeFile.Count -eq 1 -and (@($runtimeFile[0].ownerHookIds) -join ',') -ceq 'provider-stability,serena-activate,serena-dashboard,github-cli,serena-cleanup,serena-reminder') 'shared runtime owners 必须覆盖所有 PowerShell active hooks'
$hiddenLauncherFile=@($managedManifest.files|Where-Object relativePath -ceq 'hooks/lib/hidden-console-launcher.py')
Assert-True ($hiddenLauncherFile.Count -eq 1 -and (@($hiddenLauncherFile[0].ownerHookIds) -join ',') -ceq 'serena-activate,serena-cleanup,serena-reminder') '兼容 manifest 的 hidden launcher owners 必须只覆盖真实使用两层链的 hook'
$provider=@($managedManifest.hooks|Where-Object id -ceq 'provider-stability')[0]
$dashboard=@($managedManifest.hooks|Where-Object id -ceq 'serena-dashboard')[0]
$serenaActivate=@($managedManifest.hooks|Where-Object id -ceq 'serena-activate')[0]
$github=@($managedManifest.hooks|Where-Object id -ceq 'github-cli')[0]
function Assert-WriteResource([object]$Hook,[string]$Path,[string]$Message){Assert-True (@($Hook.writeResources|Where-Object{$_.kind -ceq 'path' -and $_.value -ceq $Path}).Count -eq 1) $Message}
function Assert-ReadResource([object]$Hook,[string]$Path,[string]$Message){Assert-True (@($Hook.readResources|Where-Object{$_.kind -ceq 'path' -and $_.value -ceq $Path}).Count -eq 1) $Message}
Assert-ReadResource $github 'D:\Codex\tools\gh\bin\gh.exe' 'GitHub manifest 必须声明实际官方 gh.exe 信任/签名输入'
Assert-True (@($serenaActivate.readResources | Where-Object { $_.kind -ceq 'path' -and $_.value -ceq 'D:\Codex\tools\uv\bin\serena-hooks.exe' }).Count -eq 0) '静态 activation reminder 不得读取 vendor runtime'
Assert-WriteResource $provider 'D:\Codex\.codex\backups_state\provider-stability-guard' 'provider manifest 必须声明 config rollback backup 写资源'
Assert-WriteResource $dashboard 'D:\Codex\.codex\backups_state\serena-dashboard-guard\toml' 'dashboard manifest 必须声明 TOML rollback backup 写资源'
Assert-WriteResource $dashboard 'D:\Codex\.codex\backups_state\serena-dashboard-guard\yaml' 'dashboard manifest 必须声明 YAML rollback backup 写资源'
foreach($hook in @($provider,$serenaActivate,$dashboard,$github)){Assert-WriteResource $hook 'D:\agents\run-evidence\codex-hook-health\.backups' "$($hook.id) manifest 必须声明 latest-health backup 写资源"}
Assert-WriteResource $serenaActivate 'D:\agents\run-evidence\codex-hook-health\serena-activate.json' 'Serena activate manifest 必须声明独立 health 写资源'
Assert-True (($provider.fullAcceptanceCommand.arguments -join ',') -ceq '-Json,-CheckNetwork') 'provider full acceptance 必须保留 Task 8 实际 network 验收；Task 7 另走 CheckOnly'
$expectedSerenaActivateAcceptance = @('-NoProfile','-File','D:\Codex\.codex\hooks\serena-behavior-guard.ps1','-Mode','ActivationAcceptance')
Assert-True ((@($serenaActivate.fullAcceptanceCommand.arguments) -join "`0") -ceq ($expectedSerenaActivateAcceptance -join "`0")) 'Serena activation reminder acceptance 必须调用固定无残留验收模式'
$invalidSerenaActivateAcceptance = Copy-TestDocument $managedManifest
$invalidSerenaActivateHook = @($invalidSerenaActivateAcceptance.hooks | Where-Object id -ceq 'serena-activate')[0]
$invalidSerenaActivateHook.fullAcceptanceCommand.arguments[-1] = 'ReminderAcceptance'
Assert-Throws { Assert-CodexHookManifest -Manifest $invalidSerenaActivateAcceptance } 'Serena activate invalid SessionStart input 不得绕过 full vendor protocol allowlist'
$serenaCleanup=@($managedManifest.hooks|Where-Object id -ceq 'serena-cleanup')[0]
$serenaReminder=@($managedManifest.hooks|Where-Object id -ceq 'serena-reminder')[0]
$expectedCleanupAcceptance = @('-NoProfile','-File','D:\Codex\.codex\hooks\serena-behavior-guard.ps1','-Mode','CleanupAcceptance')
$expectedReminderAcceptance = @('-NoProfile','-File','D:\Codex\.codex\hooks\serena-behavior-guard.ps1','-Mode','ReminderAcceptance')
Assert-True ($serenaCleanup.fullAcceptanceCommand.commandPath -ceq 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -and (@($serenaCleanup.fullAcceptanceCommand.arguments) -join "`0") -ceq ($expectedCleanupAcceptance -join "`0")) 'Serena cleanup full acceptance 必须使用唯一 session 并验证删除'
Assert-True ($serenaReminder.fullAcceptanceCommand.commandPath -ceq 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -and (@($serenaReminder.fullAcceptanceCommand.arguments) -join "`0") -ceq ($expectedReminderAcceptance -join "`0")) 'Serena reminder full acceptance 必须验证阈值并清理唯一 session'
$invalidBehaviorAcceptance = Copy-TestDocument $managedManifest
@($invalidBehaviorAcceptance.hooks|Where-Object id -ceq 'serena-reminder')[0].fullAcceptanceCommand.arguments[-1] = 'CleanupAcceptance'
Assert-Throws { Assert-CodexHookManifest -Manifest $invalidBehaviorAcceptance } 'Serena reminder 空对象不得绕过受控 full acceptance allowlist'
Assert-True (($github.quickHealthCheck.arguments -join ',') -ceq '-CheckOnly,-Json') 'GitHub quick health 接口必须固定且不请求 auth'
Assert-True (($github.fullAcceptanceCommand.arguments -join ',') -ceq '-Json,-CheckAuth,-Strict') 'GitHub full health 接口必须固定为 auth strict'

$implementationPlan=Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'docs\plans\2026-07-11-codex-hook-governance-implementation.md')
Assert-True ($implementationPlan.Contains('历史实施计划：已被主机钩子协调器取代')) '旧 Task 7 实施计划必须明确标记为历史不可执行'
Assert-True ($implementationPlan.Contains('Invoke-CodexHostHookReconciliation.ps1') -and $implementationPlan.Contains('唯一生产权威')) '旧 Task 7 实施计划必须指向唯一生产协调器'
Assert-True ($implementationPlan -notmatch '(?m)^\s*&.*(?:Invoke|Restore)-CodexHookDeployment\.ps1') '旧 Task 7 实施计划不得保留可复制的 live apply/restore 命令'

[pscustomobject]@{
    ok = $true
    suite = 'CodexHookPolicy'
}
