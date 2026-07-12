[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1')
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookProductionFull.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionFixtureTestSupport.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action } catch { return $_.Exception.Message }
    throw $Message
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Initialize-ProductionFullFixture {
    $profile = Get-CodexHookProductionFullFixtureProfile
    $root = Split-Path -Parent ([string]$profile.sourceRoot)
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
    foreach ($directory in @($profile.sourceRoot, $profile.hooksRoot, $profile.planOutputDir, $profile.evidenceRoot)) {
        [void][IO.Directory]::CreateDirectory([string]$directory)
    }

    $manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'managed\codex-hooks\manifest.json') -Raw |
        ConvertFrom-Json -Depth 128
    $before = @{}
    foreach ($file in @($manifest.files)) {
        $sourcePath = Join-Path ([string]$profile.sourceRoot) ([string]$file.relativePath)
        $livePath = Join-Path ([string]$profile.hooksRoot) ([string]$file.liveRelativePath)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $sourcePath))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $livePath))
        [byte[]]$sourceBytes = [Text.UTF8Encoding]::new($false).GetBytes("full-source:$($file.relativePath)`n")
        [byte[]]$liveBytes = [Text.UTF8Encoding]::new($false).GetBytes("full-before:$($file.liveRelativePath)`n")
        [IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
        [IO.File]::WriteAllBytes($livePath, $liveBytes)
        $file.sha256 = Get-CodexHookBytesSha256 -Bytes $sourceBytes
        $before[[string]$file.liveRelativePath] = [byte[]]$liveBytes
    }
    Write-Utf8NoBom -Path ([string]$profile.manifestPath) -Text ($manifest | ConvertTo-Json -Depth 100)

    $byId = @{}
    foreach ($hook in @($manifest.hooks)) { $byId[[string]$hook.id] = $hook }
    $registry = [pscustomobject][ordered]@{
        marker = 'registry-secret-must-not-enter-plan'
        hooks = [pscustomobject][ordered]@{
            SessionStart = @(
                (New-CodexHookCanonicalRegistryGroup -Hook $byId['provider-stability'])
                [pscustomobject][ordered]@{ matcher = 'UnknownSession'; hooks = @([pscustomobject][ordered]@{ type='command'; command='D:\Unknown\keep.cmd --token registry-secret' }) }
                (New-CodexHookCanonicalRegistryGroup -Hook $byId['github-cli'])
                (New-CodexHookCanonicalRegistryGroup -Hook $byId['codex-state-policy'])
                (New-CodexHookCanonicalRegistryGroup -Hook $byId['serena-activate'])
                (New-CodexHookCanonicalRegistryGroup -Hook $byId['serena-dashboard'])
            )
            Stop = @((New-CodexHookCanonicalRegistryGroup -Hook $byId['serena-cleanup']))
            PreToolUse = @(
                (New-CodexHookCanonicalRegistryGroup -Hook $byId['serena-reminder'])
                (New-CodexHookCanonicalRegistryGroup -Hook $byId['serena-auto-approve'])
                [pscustomobject][ordered]@{ matcher='UnknownTool'; hooks=@([pscustomobject][ordered]@{ type='prompt'; prompt='keep-secret' }) }
            )
            UnknownEvent = @([pscustomobject][ordered]@{ hooks=@([pscustomobject][ordered]@{ type='prompt'; prompt='opaque' }) })
        }
    }
    Write-Utf8NoBom -Path ([string]$profile.registryPath) -Text ($registry | ConvertTo-Json -Depth 100)

    return [pscustomobject][ordered]@{ profile=$profile; manifest=$manifest; before=$before; registry=$registry; root=$root }
}

$lease = Enter-CodexHookProductionFixtureLifecycle
$fixture = $null
try {
    $fixture = Initialize-ProductionFullFixture
    $identityAtProject = Get-CodexHookProductionFullMappingIdentity -Profile $fixture.profile
    Push-Location 'D:\Codex'
    try { $identityAtD = Get-CodexHookProductionFullMappingIdentity -Profile $fixture.profile } finally { Pop-Location }
    Assert-True ($identityAtProject -ceq $identityAtD) 'production full mapping identity 不得依赖当前工作目录'
    $environment = [ordered]@{ present=$true; value='D:\Private\serena-secret' }
    $readEnvironment = { param($Name,$Scope) [pscustomobject]@{ present=$environment.present; value=$environment.value } }.GetNewClosure()
    $writeEnvironment = { param($Name,$Scope,$Value) $environment.present = $null -ne $Value; $environment.value = $Value }.GetNewClosure()

    $state = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Assert-True ($state.plan.mode -ceq 'full' -and $state.plan.applyEligible) 'production full plan 必须可执行'
    Assert-True ($state.plan.sourceFacts.targetProfile -ceq 'codex-hook-production-full-v1') 'production full profile identity 非法'
    Assert-True (@($state.plan.actions | Where-Object kind -ceq 'file').Count -eq @($fixture.manifest.files | Where-Object lifecycle -cne 'retired').Count) '只能发布 non-retired 文件'
    Assert-True (@($state.plan.environmentActions).Count -eq 1) '必须只有唯一 User SERENA_HOME 环境动作'
    Assert-True (@($state.plan.actions)[-1].kind -ceq 'registry') 'registry 必须最后发布'
    $planJson = $state.plan | ConvertTo-Json -Depth 100
    Assert-True ($planJson -notmatch 'registry-secret|keep-secret|serena-secret|D:\\Private') 'plan 不得泄露 registry command 或环境原值'
    $blockedPlan = Copy-CodexHookJsonValue -Value $state.plan
    $blockedPlan.applyEligible = 'false'
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($blockedPlan | ConvertTo-Json -Depth 100)
    $blockedError = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment | Out-Null
    } '字符串型 applyEligible 必须在任何 fixture 写入前拒绝'
    Assert-True ($blockedError -match 'plan|applyEligible|布尔') '畸形 applyEligible 必须命中 plan schema gate'
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text $planJson
    $unknownLivePath = Join-Path ([string]$fixture.profile.hooksRoot) 'unknown-after-plan.ps1'
    Write-Utf8NoBom -Path $unknownLivePath -Text 'unknown-live-drift'
    $unknownError = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment | Out-Null
    } 'plan 后新增 unknown live file 必须在任何写入前阻断'
    Assert-True ($unknownError -match 'rederive|unknown|projection') 'unknown live drift 必须命中 critical projection gate'
    Remove-Item -LiteralPath $unknownLivePath -Force

    $result = Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    Assert-True ($result.applied -and -not $result.noOp) 'production full fixture apply 必须成功'
    Assert-True ($environment.value -ceq 'D:\Codex\.serena') 'apply 必须写唯一 User SERENA_HOME'
    $evidenceText = (Get-ChildItem -LiteralPath ([string]$result.evidenceDirectory) -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }) -join "`n"
    Assert-True ($evidenceText -notmatch 'D:\\Private\\serena-secret') 'evidence 不得明文保存 User SERENA_HOME 原值'
    foreach ($file in @($fixture.manifest.files)) {
        $livePath = Join-Path ([string]$fixture.profile.hooksRoot) ([string]$file.liveRelativePath)
        $actual = [IO.File]::ReadAllBytes($livePath)
        if ($file.lifecycle -ceq 'retired') {
            Assert-True ((Get-CodexHookBytesSha256 -Bytes $actual) -ceq (Get-CodexHookBytesSha256 -Bytes ([byte[]]$fixture.before[[string]$file.liveRelativePath]))) 'retired live 文件必须保持不删不改'
        } else {
            Assert-True ((Get-CodexHookBytesSha256 -Bytes $actual) -ceq [string]$file.sha256) 'active live 文件必须发布 source bytes'
        }
    }
    $afterRegistry = Get-Content -LiteralPath ([string]$fixture.profile.registryPath) -Raw | ConvertFrom-Json -Depth 100
    Assert-True (@($afterRegistry.hooks.PreToolUse).Count -eq 2) '只应移除 exact retired auto-approve'
    Assert-True (@($afterRegistry.hooks.PreToolUse | Where-Object matcher -ceq 'UnknownTool').Count -eq 1) 'unknown PreToolUse 必须保留'
    Assert-True (@($afterRegistry.hooks.Stop).Count -eq 1 -and @($afterRegistry.hooks.UnknownEvent).Count -eq 1) 'Stop/unknown event 必须保留'

    $restoreManifestPath = Join-Path ([string]$result.evidenceDirectory) 'restore-manifest.json'
    [byte[]]$validRestoreManifestBytes = [IO.File]::ReadAllBytes($restoreManifestPath)
    $forgedRestore = Get-Content -LiteralPath $restoreManifestPath -Raw | ConvertFrom-Json -Depth 100
    $forgedRestore | Add-Member -NotePropertyName forged -NotePropertyValue $true
    Write-Utf8NoBom -Path $restoreManifestPath -Text ($forgedRestore | ConvertTo-Json -Depth 100)
    $forgedError = Assert-Throws {
        Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$result.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment | Out-Null
    } 'tampered restore manifest 必须在任何 target 写入前拒绝'
    Assert-True ($forgedError -match 'claim|schema|binding|hash') 'tampered restore 必须命中 evidence binding/schema gate'
    [IO.File]::WriteAllBytes($restoreManifestPath,$validRestoreManifestBytes)

    $noOpState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($noOpState.plan | ConvertTo-Json -Depth 100)
    $noOpResult = Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    Assert-True (-not $noOpResult.applied -and $noOpResult.noOp) '已收敛 production full apply 必须结构化 no-op'
    $noOpClaim = Join-Path ([string]$fixture.profile.evidenceRoot) ".claims\$($noOpState.plan.generationId).json"
    Assert-True (-not [IO.File]::Exists($noOpClaim)) 'no-op 不得创建永久 claim 或 evidence'

    $restore = Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$result.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    Assert-True ($restore.restored -and -not $restore.noOp) 'external restore 必须恢复完整状态'
    Assert-True ($environment.value -ceq 'D:\Private\serena-secret') 'restore 必须恢复 User SERENA_HOME 原值'
    $restoreAgain = Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$result.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    Assert-True ($restoreAgain.noOp -and -not $restoreAgain.restored) 'restore 必须幂等 no-op'
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text $planJson
    $replay = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment | Out-Null
    } '同 generation replay 必须拒绝'
    Assert-True ($replay -match 'claim|重放') 'replay 拒绝原因必须指向永久 claim'

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $faultState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($faultState.plan | ConvertTo-Json -Depth 100)
    $fault = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestFaultInjection before-registry | Out-Null
    } 'registry 发布前故障必须触发自动 rollback'
    Assert-True ($fault -match '自动 rollback 完成') '故障必须报告 rollback 已完成'
    Assert-True ($environment.value -ceq 'D:\Private\serena-secret') '自动 rollback 必须恢复 User SERENA_HOME'
    foreach($file in @($fixture.manifest.files)){
        $livePath = Join-Path ([string]$fixture.profile.hooksRoot) ([string]$file.liveRelativePath)
        Assert-True ((Get-CodexHookBytesSha256 -Bytes ([IO.File]::ReadAllBytes($livePath))) -ceq (Get-CodexHookBytesSha256 -Bytes ([byte[]]$fixture.before[[string]$file.liveRelativePath]))) '自动 rollback 必须恢复所有 live file bytes'
    }

    [pscustomobject][ordered]@{ ok=$true; test='CodexHookProductionFull'; fileActions=@($state.plan.actions | Where-Object kind -ceq 'file').Count }
} finally {
    try {
        if ($null -ne $fixture -and [IO.Directory]::Exists([string]$fixture.root)) { Remove-Item -LiteralPath ([string]$fixture.root) -Recurse -Force }
    } finally {
        Exit-CodexHookProductionFixtureLifecycle -Lease $lease
    }
}
