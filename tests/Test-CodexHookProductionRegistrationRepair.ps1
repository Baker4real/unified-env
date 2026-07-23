[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1')
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookProductionRegistrationRepair.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionFixtureTestSupport.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )
    try {
        & $Action
    } catch {
        return $_.Exception.Message
    }
    throw $Message
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$profile = Get-CodexHookProductionRegistrationRepairProfile
Assert-True ($profile.profileId -ceq 'codex-hook-production-registration-repair-v1') 'production profile id 必须固定'
Assert-True ($profile.mode -ceq 'registration-repair') 'production profile 只能 registration-repair'
Assert-True ($profile.manifestPath -ceq 'D:\Codex\projects\统一环境\managed\codex-hooks\host-preflight-manifest.json') '非 fixture production profile 只能绑定 host-preflight manifest，legacy 仅供 fixture adapter'
Assert-True ($profile.sourceRoot -ceq 'D:\Codex\projects\统一环境\managed\codex-hooks') 'source root 必须固定'
Assert-True ($profile.codexHome -ceq 'D:\Codex\.codex') 'codex home 必须固定'
Assert-True ($profile.registryPath -ceq 'D:\Codex\.codex\hooks.json') 'registry path 必须固定'
Assert-True ($profile.planPath -ceq 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan\plan.json') 'plan path 必须固定'
Assert-True ($profile.evidenceRoot -ceq 'D:\Codex\.codex\run-evidence\env-governance') 'evidence root 必须固定'
Assert-True ($profile.mutexName -ceq 'Local\CodexHookProductionRegistrationRepairV1') 'production mutex 必须固定'
$lifecycleGeneration = '11111111-1111-4111-8111-111111111111'
$productionLifecycle = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $profile -GenerationId $lifecycleGeneration
Assert-True ($productionLifecycle.claimPath -ceq "D:\Codex\.codex\run-evidence\env-governance\.claims\$lifecycleGeneration.json") 'production claim path 必须固定'
Assert-True ($productionLifecycle.evidenceDirectory -ceq "D:\Codex\.codex\run-evidence\env-governance\deployment-$lifecycleGeneration") 'production evidence directory 必须是直接子目录'

$newPlanCommand = Get-Command -Name (Join-Path $ProjectRoot 'scripts\New-CodexHookDeploymentPlan.ps1')
$newPlanScriptText = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'scripts\New-CodexHookDeploymentPlan.ps1'))
$productionParameter = $newPlanCommand.Parameters['ProductionRegistrationRepair']
Assert-True ($null -ne $productionParameter) 'plan CLI 必须暴露独立 -ProductionRegistrationRepair 参数集'
Assert-True (@($productionParameter.ParameterSets.Keys) -contains 'ProductionRegistrationRepair') 'production switch 必须属于独立参数集'
foreach ($fixtureOnlyName in @('ManifestPath', 'FixtureSourceRoot', 'FixtureCodexHome', 'Mode', 'OutputDir', 'EnvironmentReadValue')) {
    Assert-True (-not $newPlanCommand.Parameters[$fixtureOnlyName].ParameterSets.ContainsKey('ProductionRegistrationRepair')) "production plan 参数集不得接受 $fixtureOnlyName"
}
Assert-True ($newPlanScriptText.Contains('superseded-by-host-hook-reconciler')) 'production registration-repair plan façade 必须稳定退役'
$invokeCommand = Get-Command -Name (Join-Path $ProjectRoot 'scripts\Invoke-CodexHookDeployment.ps1')
foreach ($testOnlyName in @('TestAfterRegistryPublish', 'TestBeforeRollbackMove', 'TestAfterRollbackSnapshot', 'TestAfterPremoveSnapshot', 'TestFaultInjection')) {
    Assert-True (-not $invokeCommand.Parameters.ContainsKey($testOnlyName)) "production CLI 不得暴露 test-only apply seam：$testOnlyName"
}
foreach ($fixtureOnlyName in @('PlanPath', 'EvidenceRoot', 'EnvironmentReadValue', 'EnvironmentWriteValue', 'FaultInjection')) {
    Assert-True (-not $invokeCommand.Parameters[$fixtureOnlyName].ParameterSets.ContainsKey('ProductionRegistrationRepair')) "production apply 参数集不得接受 $fixtureOnlyName"
}
$restoreCommand = Get-Command -Name (Join-Path $ProjectRoot 'scripts\Restore-CodexHookDeployment.ps1')
Assert-True (-not $restoreCommand.Parameters.ContainsKey('TestFaultInjection')) 'production CLI 不得暴露 test-only restore seam'
foreach ($fixtureOnlyName in @('EnvironmentReadValue', 'EnvironmentWriteValue')) {
    Assert-True (-not $restoreCommand.Parameters[$fixtureOnlyName].ParameterSets.ContainsKey('ProductionRegistrationRepair')) "production restore 参数集不得接受 $fixtureOnlyName"
}
$profileTamper = Copy-CodexHookJsonValue -Value $profile
$profileTamper.registryPath = 'D:\Codex\.codex\other.json'
[void](Assert-Throws { Assert-CodexHookProductionRegistrationRepairProfile -Profile $profileTamper | Out-Null } 'production fixed path 覆盖必须失败')

$fixtureProfile = Get-CodexHookProductionRegistrationRepairFixtureProfile
[void](Assert-CodexHookProductionRegistrationRepairProfile -Profile $fixtureProfile -AllowFixtureAdapter)
$fixtureRoot = Split-Path -Parent ([string]$fixtureProfile.sourceRoot)
$fixtureLifecycleLease = Enter-CodexHookProductionFixtureLifecycle
try {
if ([IO.Directory]::Exists($fixtureRoot)) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
[void][IO.Directory]::CreateDirectory([string]$fixtureProfile.sourceRoot)
[void][IO.Directory]::CreateDirectory([string]$fixtureProfile.hooksRoot)
[void][IO.Directory]::CreateDirectory([string]$fixtureProfile.planOutputDir)
[void][IO.Directory]::CreateDirectory([string]$fixtureProfile.evidenceRoot)

$templateText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'managed\codex-hooks\legacy-fixture-manifest.json') -Raw
$fixtureManifest = $templateText | ConvertFrom-Json -Depth 128
foreach ($file in @($fixtureManifest.files)) {
    $sourcePath = Join-Path ([string]$fixtureProfile.sourceRoot) ([string]$file.relativePath)
    $livePath = Join-Path ([string]$fixtureProfile.hooksRoot) ([string]$file.liveRelativePath)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $sourcePath))
    [byte[]]$sourceBytes = [Text.UTF8Encoding]::new($false).GetBytes("production-fixture-source:$($file.relativePath)`n")
    [byte[]]$liveBytes = [Text.UTF8Encoding]::new($false).GetBytes("production-fixture-live:$($file.liveRelativePath)`n")
    [IO.Directory]::CreateDirectory((Split-Path -Parent $livePath)) | Out-Null
    [IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
    [IO.File]::WriteAllBytes($livePath, $liveBytes)
    $file.sha256 = Get-CodexHookBytesSha256 -Bytes $sourceBytes
}
[void](Assert-CodexHookManifest -Manifest $fixtureManifest)
Write-Utf8NoBom -Path ([string]$fixtureProfile.manifestPath) -Text ($fixtureManifest | ConvertTo-Json -Depth 100)

$byId = @{}
foreach ($hook in @($fixtureManifest.hooks)) { $byId[[string]$hook.id] = $hook }
function New-FixtureManagedGroup {
    param([Parameter(Mandatory)][string]$Id)
    $group = New-CodexHookCanonicalRegistryGroup -Hook $byId[$Id]
    $group | Add-Member -NotePropertyName customManagedField -NotePropertyValue "preserve-$Id"
    return $group
}
$unknownSessionGroup = [pscustomobject][ordered]@{
    matcher = 'FixtureUnknown'
    customUnknownField = 'preserve'
    hooks = @([pscustomobject][ordered]@{
        type = 'command'
        command = 'D:\Fixture\unknown-session.cmd --token fixture-secret'
        timeout = 7
        opaque = 'preserve'
    })
}
$fixtureRegistry = [pscustomobject][ordered]@{
    registryCustomField = 'preserve'
    hooks = [pscustomobject][ordered]@{
        SessionStart = @(
            (New-FixtureManagedGroup -Id 'provider-stability')
            $unknownSessionGroup
            (New-FixtureManagedGroup -Id 'github-cli')
            (New-FixtureManagedGroup -Id 'codex-state-policy')
            (New-FixtureManagedGroup -Id 'serena-activate')
            (New-FixtureManagedGroup -Id 'serena-dashboard')
        )
        Stop = @(
            (New-CodexHookCanonicalRegistryGroup -Hook $byId['serena-cleanup'])
            [pscustomobject][ordered]@{
                customStop = 'preserve'
                hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'D:\Fixture\unknown-stop.cmd' })
            }
        )
        PreToolUse = @(
            (New-CodexHookCanonicalRegistryGroup -Hook $byId['serena-reminder'])
            [pscustomobject][ordered]@{
                matcher = 'Fixture'
                customPreToolUse = 'preserve'
                hooks = @([pscustomobject][ordered]@{ type = 'prompt'; prompt = 'opaque' })
            }
        )
        UnknownEvent = @([pscustomobject][ordered]@{
            customUnknownEvent = 'preserve'
            hooks = @([pscustomobject][ordered]@{ type = 'prompt'; prompt = 'opaque-event' })
        })
    }
}
Write-Utf8NoBom -Path ([string]$fixtureProfile.registryPath) -Text ($fixtureRegistry | ConvertTo-Json -Depth 100)
[byte[]]$registryBeforeBytes = [IO.File]::ReadAllBytes([string]$fixtureProfile.registryPath)
$registryBeforeSha256 = Get-CodexHookBytesSha256 -Bytes $registryBeforeBytes

$state = New-CodexHookProductionRegistrationRepairState -Profile $fixtureProfile
[void](Assert-CodexHookProductionRegistrationRepairPlan -Plan $state.plan -Profile $fixtureProfile)
Assert-True (-not $state.isNoOp) '初始 production fixture 必须需要 registry reorder'
Assert-True (@($state.plan.actions).Count -eq 1 -and $state.plan.actions[0].kind -ceq 'registry') 'production plan 必须恰好一个 registry action'
Assert-True (@($state.plan.environmentActions).Count -eq 0) 'production plan 必须零 environment action'
Assert-True (@($state.plan.actions | Where-Object kind -ceq 'file').Count -eq 0) 'production plan 必须零 file action'
Assert-True (@(Get-CodexHookProductionManagedOrder -Manifest $state.manifest -Registry $state.desiredRegistry) -join ',' -ceq 'provider-stability,codex-state-policy,serena-activate,serena-dashboard,github-cli') 'production plan desired managed order 必须固定'
$planJson = $state.plan | ConvertTo-Json -Depth 100
Assert-True ($planJson -notmatch 'fixture-secret|unknown-session\.cmd|unknown-stop\.cmd') 'production plan 不得嵌入 raw registry command/secret'

$timeoutTamper = Copy-CodexHookJsonValue -Value $state.desiredRegistry
$timeoutTamper.hooks.SessionStart[0].hooks[0].timeout = 9
[void](Assert-Throws {
    Assert-CodexHookProductionRegistrationRepairRegistryDelta -Manifest $state.manifest -Before $state.registry -After $timeoutTamper | Out-Null
} 'managed timeout 非顺序变化必须被语义防火墙拒绝')
$stopTamper = Copy-CodexHookJsonValue -Value $state.desiredRegistry
$stopTamper.hooks.Stop[0].hooks[0].timeout = 9
[void](Assert-Throws {
    Assert-CodexHookProductionRegistrationRepairRegistryDelta -Manifest $state.manifest -Before $state.registry -After $stopTamper | Out-Null
} 'Stop 变化必须被语义防火墙拒绝')
$unknownTamper = Copy-CodexHookJsonValue -Value $state.desiredRegistry
$unknownTamper.hooks.SessionStart[1].customUnknownField = 'changed'
[void](Assert-Throws {
    Assert-CodexHookProductionRegistrationRepairRegistryDelta -Manifest $state.manifest -Before $state.registry -After $unknownTamper | Out-Null
} 'unknown SessionStart group 变化必须被语义防火墙拒绝')

$actionTamper = Copy-CodexHookJsonValue -Value $state.plan
$actionTamper.actions[0].kind = 'file'
[void](Assert-Throws {
    Assert-CodexHookProductionRegistrationRepairPlan -Plan $actionTamper -Profile $fixtureProfile | Out-Null
} 'production plan file capability 必须拒绝')
$environmentTamper = Copy-CodexHookJsonValue -Value $state.plan
$environmentTamper.environmentActions = @([pscustomobject][ordered]@{ kind = 'environment' })
[void](Assert-Throws {
    Assert-CodexHookProductionRegistrationRepairPlan -Plan $environmentTamper -Profile $fixtureProfile | Out-Null
} 'production plan environment capability 必须拒绝')

[IO.File]::WriteAllBytes([string]$fixtureProfile.registryPath, [byte[]]$state.desiredRegistryBytes)
$noOpState = New-CodexHookProductionRegistrationRepairState -Profile $fixtureProfile
Assert-True ($noOpState.isNoOp -and @($noOpState.plan.actions).Count -eq 0 -and -not $noOpState.plan.rollbackRequired) '已收敛 production plan 必须是零动作 no-op'
Write-Utf8NoBom -Path ([string]$fixtureProfile.planPath) -Text ($noOpState.plan | ConvertTo-Json -Depth 100)
$noOpResult = Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixtureProfile
Assert-True (-not $noOpResult.applied -and $noOpResult.noOp -and $noOpResult.refusalReason -ceq 'already-converged') 'production no-op apply 必须结构化返回'
Assert-True (-not [IO.Directory]::Exists((Join-Path ([string]$fixtureProfile.evidenceRoot) '.claims'))) 'production no-op 不得创建 claim'
Assert-True (@(Get-ChildItem -LiteralPath ([string]$fixtureProfile.evidenceRoot) -Filter 'deployment-*' -Directory).Count -eq 0) 'production no-op 不得创建 evidence'

[IO.File]::WriteAllBytes([string]$fixtureProfile.registryPath, $registryBeforeBytes)
$state = New-CodexHookProductionRegistrationRepairState -Profile $fixtureProfile
Write-Utf8NoBom -Path ([string]$fixtureProfile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
$mutexReadyPath = Join-Path $fixtureRoot 'production-mutex-ready.txt'
$mutexHolderCode = @'
$mutex = [Threading.Mutex]::new($false, $env:CODEX_TEST_MUTEX_NAME)
try {
    if (-not $mutex.WaitOne(0)) { throw 'fixture mutex setup busy' }
    [IO.File]::WriteAllText($env:CODEX_TEST_MUTEX_READY, 'ready', [Text.UTF8Encoding]::new($false))
    Start-Sleep -Seconds 30
} finally {
    try { [void]$mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
'@
$mutexHolderEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($mutexHolderCode))
$mutexHolderStart = [Diagnostics.ProcessStartInfo]::new()
$mutexHolderStart.FileName = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$mutexHolderStart.UseShellExecute = $false
$mutexHolderStart.CreateNoWindow = $true
$mutexHolderStart.RedirectStandardOutput = $true
$mutexHolderStart.RedirectStandardError = $true
$mutexHolderStart.Environment['CODEX_TEST_MUTEX_NAME'] = [string]$fixtureProfile.mutexName
$mutexHolderStart.Environment['CODEX_TEST_MUTEX_READY'] = $mutexReadyPath
foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $mutexHolderEncoded)) {
    [void]$mutexHolderStart.ArgumentList.Add($argument)
}
$mutexHolder = [Diagnostics.Process]::new()
$mutexHolder.StartInfo = $mutexHolderStart
$mutexStdoutTask = $null
$mutexStderrTask = $null
try {
    Assert-True $mutexHolder.Start() 'production fixture mutex holder 无法启动'
    $mutexStdoutTask = $mutexHolder.StandardOutput.ReadToEndAsync()
    $mutexStderrTask = $mutexHolder.StandardError.ReadToEndAsync()
    for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path -LiteralPath $mutexReadyPath -PathType Leaf); $attempt++) {
        if ($mutexHolder.HasExited) { break }
        Start-Sleep -Milliseconds 50
    }
    Assert-True ((Test-Path -LiteralPath $mutexReadyPath -PathType Leaf) -and -not $mutexHolder.HasExited) 'production fixture mutex 预占失败'
    $mutexError = Assert-Throws {
        Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixtureProfile | Out-Null
    } 'production apply 必须受 fixed mutex 保护'
    Assert-True ($mutexError -match 'mutex busy') 'production mutex 冲突必须给出脱敏原因'
} finally {
    if (-not $mutexHolder.HasExited) {
        $mutexHolder.Kill($true)
        [void]$mutexHolder.WaitForExit(5000)
    }
    if ($null -ne $mutexStdoutTask) { [void]$mutexStdoutTask.GetAwaiter().GetResult() }
    if ($null -ne $mutexStderrTask) { [void]$mutexStderrTask.GetAwaiter().GetResult() }
    $mutexHolder.Dispose()
}
Assert-True (-not [IO.Directory]::Exists((Join-Path ([string]$fixtureProfile.evidenceRoot) '.claims'))) 'mutex gate 失败不得创建 claim'

$applyResult = Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixtureProfile
Assert-True ($applyResult.applied -and -not $applyResult.noOp) 'production fixture apply core 必须应用唯一 registry action'
$registryAfterSha256 = (Get-FileHash -LiteralPath ([string]$fixtureProfile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($registryAfterSha256 -ceq $state.plan.registryAfterSha256) 'production apply registry postcheck hash 必须匹配'
$claimPath = Join-Path ([string]$fixtureProfile.evidenceRoot) ".claims\$($state.plan.generationId).json"
Assert-True ([IO.File]::Exists($claimPath)) 'production generation claim 必须固定且永久保留'
$restoreManifestPath = Join-Path ([string]$applyResult.evidenceDirectory) 'restore-manifest.json'
$restoreManifest = Get-Content -LiteralPath $restoreManifestPath -Raw | ConvertFrom-Json -Depth 128
Assert-True (@($restoreManifest.actions).Count -eq 1 -and $restoreManifest.actions[0].kind -ceq 'registry') 'production restore manifest 只能包含一个 registry action'

$restoreResult = Restore-CodexHookProductionRegistrationRepairCore -Profile $fixtureProfile -EvidenceDirectory ([string]$applyResult.evidenceDirectory)
Assert-True ($restoreResult.restored -and -not $restoreResult.noOp) 'production fixture restore core 必须恢复 registry'
Assert-True (((Get-FileHash -LiteralPath ([string]$fixtureProfile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $registryBeforeSha256) 'production restore 必须恢复原 registry bytes'
Assert-True ([IO.File]::Exists($claimPath)) 'production restore 后 claim 必须永久保留'
$restoreNoOp = Restore-CodexHookProductionRegistrationRepairCore -Profile $fixtureProfile -EvidenceDirectory ([string]$applyResult.evidenceDirectory)
Assert-True (-not $restoreNoOp.restored -and $restoreNoOp.noOp) 'production restore 必须幂等 no-op'
$replayError = Assert-Throws {
    Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixtureProfile | Out-Null
} '同 generationId production replay 必须被 claim 拒绝'
Assert-True ($replayError -match 'claim|重放') 'production replay 必须给出 claim/replay 原因'

[pscustomobject][ordered]@{
    ok = $true
    test = 'CodexHookProductionRegistrationRepair'
}
} finally {
    try {
        if ([IO.Directory]::Exists($fixtureRoot)) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    } finally {
        Exit-CodexHookProductionFixtureLifecycle -Lease $fixtureLifecycleLease
    }
}
