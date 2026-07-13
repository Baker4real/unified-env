[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1')
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookProductionFull.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionFixtureTestSupport.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionFullEvidenceTestSupport.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Bytes {
    param([Parameter(Mandatory)][byte[]]$Actual, [Parameter(Mandatory)][byte[]]$Expected, [Parameter(Mandatory)][string]$Message)
    Assert-True (([Convert]::ToHexString($Actual)) -ceq ([Convert]::ToHexString($Expected))) $Message
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action } catch { return $_.Exception.Message }
    throw $Message
}

$productionProfile=Get-CodexHookProductionFullProfile
$productionEnvironmentRead={param($Name,$Scope)[Environment]::GetEnvironmentVariable($Name,[EnvironmentVariableTarget]::User)}
$productionState=New-CodexHookProductionFullState -Profile $productionProfile -EnvironmentReadValue $productionEnvironmentRead
Assert-True (Assert-CodexHookProductionFullPlan -Plan $productionState.plan -Profile $productionProfile) 'current production full snapshot plan 必须通过只读 validator'

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-TestCodexHookProductionFullPlanPair {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][object]$Plan,
        [string]$MarkdownGenerationId = ([string]$Plan.generationId),
        [string]$MarkdownSourceJsonSha256
    )
    [byte[]]$jsonBytes = [Text.UTF8Encoding]::new($false).GetBytes(($Plan | ConvertTo-Json -Depth 100))
    $jsonSha256 = Get-CodexHookBytesSha256 -Bytes $jsonBytes
    if([string]::IsNullOrWhiteSpace($MarkdownSourceJsonSha256)){$MarkdownSourceJsonSha256=$jsonSha256}
    [IO.File]::WriteAllBytes([string]$Profile.planPath, $jsonBytes)
    $markdownPath = Join-Path ([string]$Profile.planOutputDir) 'PLAN.md'
    Write-Utf8NoBom -Path $markdownPath -Text "---`ngenerationId: $MarkdownGenerationId`nsourceJsonSha256: $MarkdownSourceJsonSha256`n---`nfixture plan pair"
    return [pscustomobject][ordered]@{ generationId=[string]$Plan.generationId; sha256=$jsonSha256; markdownPath=$markdownPath }
}

function Invoke-CompetingFileWrite {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes)
    $literal="'"+$Path.Replace("'","''")+"'";$payload=[Convert]::ToBase64String($Bytes)
    $command="try { [IO.File]::WriteAllBytes($literal,[Convert]::FromBase64String('$payload')); exit 0 } catch [IO.IOException] { exit (`$_.Exception.HResult -band 0xffff) } catch { exit 254 }"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=Start-Process -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -WindowStyle Hidden -Wait -PassThru
    return [int]$process.ExitCode
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
    Assert-True (Assert-CodexHookProductionFullPlan -Plan $state.plan -Profile $fixture.profile) 'fixture full plan 必须满足 fixed production action contract'
    Assert-True ($state.plan.sourceFacts.targetProfile -ceq 'codex-hook-production-full-v1') 'production full profile identity 非法'
    Assert-True (@($state.plan.actions | Where-Object kind -ceq 'file').Count -eq @($fixture.manifest.files | Where-Object lifecycle -cne 'retired').Count) '只能发布 non-retired 文件'
    Assert-True (@($state.plan.environmentActions).Count -eq 1) '必须只有唯一 User SERENA_HOME 环境动作'
    Assert-True (@($state.plan.actions)[-1].kind -ceq 'registry') 'registry 必须最后发布'
    Assert-True ((@($state.plan.actions).Count + @($state.plan.environmentActions).Count) -eq 15) 'Task 7 production rollback 只能覆盖 15 个 deployment actions'
    $planJson = $state.plan | ConvertTo-Json -Depth 100
    Assert-True ($planJson -notmatch 'registry-secret|keep-secret|serena-secret|D:\\Private') 'plan 不得泄露 registry command 或环境原值'

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $extraRelativePath = 'hooks\fixture-extra-production-full-support.ps1'
    $extraLiveRelativePath = 'lib\fixture-extra-production-full-support.ps1'
    $extraSourcePath = Join-Path ([string]$fixture.profile.sourceRoot) $extraRelativePath
    $extraLivePath = Join-Path ([string]$fixture.profile.hooksRoot) $extraLiveRelativePath
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $extraSourcePath))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $extraLivePath))
    [byte[]]$extraSourceBytes = [Text.UTF8Encoding]::new($false).GetBytes('fixture 16-action source')
    [IO.File]::WriteAllBytes($extraSourcePath, $extraSourceBytes)
    [IO.File]::WriteAllText($extraLivePath, 'fixture 16-action live', [Text.UTF8Encoding]::new($false))
    $extraFile = [pscustomobject][ordered]@{
        relativePath = $extraRelativePath
        liveRelativePath = $extraLiveRelativePath
        sha256 = Get-CodexHookBytesSha256 -Bytes $extraSourceBytes
        lifecycle = 'active'
        ownerHookIds = @('provider-stability')
    }
    $fixture.manifest.files = @($fixture.manifest.files) + @($extraFile)
    Write-Utf8NoBom -Path ([string]$fixture.profile.manifestPath) -Text ($fixture.manifest | ConvertTo-Json -Depth 100)
    $sixteenActionPlanError = Assert-Throws {
        New-CodexHookProductionFullValidatedState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment | Out-Null
    } '16-action production plan generator 必须在发布前拒绝'
    Assert-True ($sixteenActionPlanError -match '15-action|allowlist') '16-action generator 必须命中 fixed production validator'

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $approvalState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    $approvedPair = Write-TestCodexHookProductionFullPlanPair -Profile $fixture.profile -Plan $approvalState.plan
    $approvedBinding = Assert-CodexHookProductionFullApprovedPlanPair -Profile $fixture.profile -ApprovedGenerationId $approvedPair.generationId -ApprovedPlanSha256 $approvedPair.sha256
    Assert-True ($approvedBinding.planSnapshot.sha256 -ceq $approvedPair.sha256) 'approved plan pair 必须返回同一 JSON snapshot'
    $pairMismatch = Assert-Throws {
        Write-TestCodexHookProductionFullPlanPair -Profile $fixture.profile -Plan $approvalState.plan -MarkdownGenerationId ([guid]::NewGuid().ToString()) | Out-Null
        Assert-CodexHookProductionFullApprovedPlanPair -Profile $fixture.profile -ApprovedGenerationId $approvedPair.generationId -ApprovedPlanSha256 $approvedPair.sha256 | Out-Null
    } 'JSON/Markdown generation mismatch 必须 fail closed'
    Assert-True ($pairMismatch -match 'pair|generation') 'pair mismatch 拒绝原因必须可审计'
    Remove-Item -LiteralPath $approvedPair.markdownPath -Force
    $partialPair = Assert-Throws {
        Assert-CodexHookProductionFullApprovedPlanPair -Profile $fixture.profile -ApprovedGenerationId $approvedPair.generationId -ApprovedPlanSha256 $approvedPair.sha256 | Out-Null
    } 'partial plan pair 必须 fail closed'
    Assert-True ($partialPair -match 'pair|PLAN|Markdown|文件') 'partial pair 拒绝原因必须可审计'
    Write-TestCodexHookProductionFullPlanPair -Profile $fixture.profile -Plan $approvalState.plan | Out-Null
    $replacementPlan = (($approvalState.plan | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100 -DateKind String)
    $replacementPlan.generationId = [guid]::NewGuid().ToString()
    $replacementPlan.generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-TestCodexHookProductionFullPlanPair -Profile $fixture.profile -Plan $replacementPlan | Out-Null
    $replacementError = Assert-Throws {
        Assert-CodexHookProductionFullApprovedPlanPair -Profile $fixture.profile -ApprovedGenerationId $approvedPair.generationId -ApprovedPlanSha256 $approvedPair.sha256 | Out-Null
    } 'same-scope replacement plan 必须拒绝旧 approval'
    Assert-True ($replacementError -match 'approved|generation|SHA') 'replacement 拒绝必须绑定 approved generation/hash'
    $replacementPair = Write-TestCodexHookProductionFullPlanPair -Profile $fixture.profile -Plan $replacementPlan
    $wrongGeneration = Assert-Throws {
        Assert-CodexHookProductionFullApprovedPlanPair -Profile $fixture.profile -ApprovedGenerationId ([guid]::NewGuid().ToString()) -ApprovedPlanSha256 $replacementPair.sha256 | Out-Null
    } '错误 approved generation 必须拒绝'
    Assert-True ($wrongGeneration -match 'approved|generation') '错误 generation 必须指向 approval binding'
    $wrongHash = Assert-Throws {
        Assert-CodexHookProductionFullApprovedPlanPair -Profile $fixture.profile -ApprovedGenerationId $replacementPair.generationId -ApprovedPlanSha256 ('0' * 64) | Out-Null
    } '错误 approved SHA-256 必须拒绝'
    Assert-True ($wrongHash -match 'approved|SHA') '错误 SHA 必须指向 approval binding'

    $retiredFile=@($fixture.manifest.files|Where-Object lifecycle -ceq 'retired')[0]
    $retiredLivePath=Join-Path ([string]$fixture.profile.hooksRoot) ([string]$retiredFile.liveRelativePath)
    [IO.File]::Delete($retiredLivePath)
    $retiredMissingState=New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Assert-True (-not $retiredMissingState.plan.applyEligible -and @($retiredMissingState.plan.liveFacts.blockerReasonCodes) -ccontains 'retired-live-not-retained') 'retired live 文件缺失必须成为 production full blocker，且不得发布/删除它'
    [IO.File]::WriteAllBytes($retiredLivePath,[byte[]]$fixture.before[[string]$retiredFile.liveRelativePath])
    [IO.File]::Delete($retiredLivePath)
    [void][IO.Directory]::CreateDirectory($retiredLivePath)
    $retiredUnsafeState=New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Assert-True (-not $retiredUnsafeState.plan.applyEligible -and @($retiredUnsafeState.plan.liveFacts.blockerReasonCodes) -ccontains 'retired-live-not-retained') 'retired live 非 regular 文件必须成为 production full blocker'
    Remove-Item -LiteralPath $retiredLivePath -Force
    [IO.File]::WriteAllBytes($retiredLivePath,[byte[]]$fixture.before[[string]$retiredFile.liveRelativePath])

    $missingFixedAction=Copy-CodexHookJsonValue -Value $state.plan
    $removedAction=@($missingFixedAction.actions|Where-Object kind -ceq 'file')[0]
    $missingFixedAction.actions=@($missingFixedAction.actions|Where-Object actionId -cne $removedAction.actionId)
    $missingFixedAction.postChecks=@($missingFixedAction.postChecks|Where-Object actionId -cne $removedAction.actionId)
    $missingFixedAction.projectionSummary.fileActions=[int]$missingFixedAction.projectionSummary.fileActions-1
    $missingFixedActionError=Assert-Throws {Assert-CodexHookProductionFullPlan -Plan $missingFixedAction -Profile $fixture.profile|Out-Null} '减少一项且同步 summary/postcheck 的 plan 必须被 fixed 15-action gate 拒绝'

    $registryNotFinal=Copy-CodexHookJsonValue -Value $state.plan
    $registryAction=@($registryNotFinal.actions|Where-Object kind -ceq 'registry')[0]
    $registryAction.restoreOrder=1
    $nextRestoreOrder=2
    foreach($action in @($registryNotFinal.actions|Where-Object kind -ceq 'file'|Sort-Object restoreOrder)){$action.restoreOrder=$nextRestoreOrder;$nextRestoreOrder++}
    $registryNotFinal.environmentActions[0].restoreOrder=15
    $registryNotFinalError=Assert-Throws {Assert-CodexHookProductionFullPlan -Plan $registryNotFinal -Profile $fixture.profile|Out-Null} 'registry 非最终且 restoreOrder 仍连续的 plan 必须被 runtime gate 拒绝'
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
    $claimPath = Join-Path ([string]$fixture.profile.evidenceRoot) ".claims\$($state.plan.generationId).json"
    [byte[]]$validClaimBytes = [IO.File]::ReadAllBytes($claimPath)
    $coordinatedRestore = Get-Content -LiteralPath $restoreManifestPath -Raw | ConvertFrom-Json -Depth 100
    $coordinatedRestore.planSha256 = ('a' * 64)
    Write-Utf8NoBom -Path $restoreManifestPath -Text ($coordinatedRestore | ConvertTo-Json -Depth 100)
    $coordinatedClaim = Get-Content -LiteralPath $claimPath -Raw | ConvertFrom-Json -Depth 100
    $coordinatedClaim.planSha256 = ('a' * 64)
    $coordinatedClaim.restoreManifestSha256 = (Get-FileHash -LiteralPath $restoreManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBom -Path $claimPath -Text ($coordinatedClaim | ConvertTo-Json -Depth 100)
    $coordinatedError = Assert-Throws {
        Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$result.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment | Out-Null
    } '协调伪造 claim/restore/hash 必须被 DPAPI attestation 拒绝'
    Assert-True ($coordinatedError -match 'attestation|认证|authentication') '协调伪造必须命中 DPAPI evidence authentication gate'
    [IO.File]::WriteAllBytes($restoreManifestPath,$validRestoreManifestBytes)
    [IO.File]::WriteAllBytes($claimPath,$validClaimBytes)
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

    $restoreProgress=[ordered]@{count=0}
    $crashAfterFirstRestoreAction={param($ActionId)$restoreProgress.count++;if($restoreProgress.count -eq 1){throw 'test-crash-after-first-restore-action'}}.GetNewClosure()
    $restoreCrash=Assert-Throws {
        Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$result.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestAfterRestoreAction $crashAfterFirstRestoreAction | Out-Null
    } 'restore 第一项后 crash seam 必须触发'
    Assert-True ($restoreCrash -match 'test-crash-after-first-restore-action') 'restore crash seam 原因非法'
    $progressStatus=Get-Content -LiteralPath (Join-Path ([string]$result.evidenceDirectory) 'status.json') -Raw | ConvertFrom-Json -Depth 32
    Assert-True ($progressStatus.status -ceq 'restoring' -and @($progressStatus.restoredActionIds).Count -eq 1) 'restore 每项后必须 crash-safe 持久化 progress'
    $environmentRace={param($ActionId)$environment.value='D:\Concurrent\third-value'}.GetNewClosure()
    $environmentRaceError=Assert-Throws {
        Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$result.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestBeforeEnvironmentRestoreWrite $environmentRace | Out-Null
    } 'environment restore 临写前 race 必须被 CAS 拒绝'
    Assert-True ($environmentRaceError -match 'environment restore CAS') 'environment race 必须命中临写前 CAS gate'
    $environment.value='D:\Codex\.serena'
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

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $statusFaultState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($statusFaultState.plan | ConvertTo-Json -Depth 100)
    $statusFault = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestFaultInjection before-registry -TestBeforeRollbackPendingStatus { throw 'status-evidence-fault' } | Out-Null
    } 'rollback-pending status 写失败仍必须 restore'
    Assert-True ($statusFault -match 'rollback-confirmed') 'status evidence 写失败且 restore 成功必须报告 rollback-confirmed'
    $statusFaultPath=[string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$statusFaultState.plan.generationId)).statusPath
    $statusFaultEvidence=Get-Content -Raw -LiteralPath $statusFaultPath|ConvertFrom-Json
    Assert-True ($statusFaultEvidence.status -ceq 'rolled-back') 'status evidence 写失败后 restore 终态必须 rolled-back'

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $rollbackBlockedState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($rollbackBlockedState.plan | ConvertTo-Json -Depth 100)
    $rollbackBlockedFile = @($fixture.manifest.files | Where-Object lifecycle -cne 'retired')[0]
    $rollbackBlockedPath = Join-Path ([string]$fixture.profile.hooksRoot) ([string]$rollbackBlockedFile.liveRelativePath)
    [byte[]]$thirdPartyBytes = [Text.UTF8Encoding]::new($false).GetBytes('third-party-concurrent-change')
    $rollbackBlocked = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestFaultInjection before-registry -TestBeforeAutomaticRollback { [IO.File]::WriteAllBytes($rollbackBlockedPath, $thirdPartyBytes) } | Out-Null
    } '自动 restore 失败必须进入 blocked recovery 状态'
    Assert-True ($rollbackBlocked -match 'rollback-blocked|recovery-required') '自动 restore 失败不得声称 rollback-confirmed'
    $rollbackBlockedStatusPath=[string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$rollbackBlockedState.plan.generationId)).statusPath
    $rollbackBlockedStatus=Get-Content -Raw -LiteralPath $rollbackBlockedStatusPath|ConvertFrom-Json
    Assert-True ($rollbackBlockedStatus.status -ceq 'rollback-blocked') '自动 restore 失败必须保留 rollback-blocked 状态证据'
    Assert-Bytes ([IO.File]::ReadAllBytes($rollbackBlockedPath)) $thirdPartyBytes '自动 restore 失败不得覆盖第三方并发 bytes'
    $rollbackBlockedRecovery=($rollbackBlocked.Substring($rollbackBlocked.IndexOf('{'))|ConvertFrom-Json)
    Assert-True (
        $rollbackBlockedRecovery.generationId -ceq [string]$rollbackBlockedState.plan.generationId -and
        $rollbackBlockedRecovery.evidenceDirectory -ceq [string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$rollbackBlockedState.plan.generationId)).evidenceDirectory -and
        $rollbackBlockedRecovery.statusPath -ceq $rollbackBlockedStatusPath -and
        $rollbackBlockedRecovery.reason -ceq 'automatic-rollback-failed'
    ) 'rollback-blocked recovery error 必须交付 generationId/evidenceDirectory/statusPath/脱敏 reason'

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $partialRollbackState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($partialRollbackState.plan | ConvertTo-Json -Depth 100)
    $partialRollbackFile=@($fixture.manifest.files|Where-Object lifecycle -cne 'retired')[0]
    $partialRollbackPath=Join-Path ([string]$fixture.profile.hooksRoot) ([string]$partialRollbackFile.liveRelativePath)
    $partialRollbackMutation=[ordered]@{done=$false}
    $partialRollbackError=Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestFaultInjection before-registry -TestAfterAutomaticRollbackAction {
            param($ActionId)
            if(-not $partialRollbackMutation.done){
                [IO.File]::WriteAllBytes($partialRollbackPath,[Text.UTF8Encoding]::new($false).GetBytes('partial-rollback-third-party'))
                $partialRollbackMutation.done=$true
            }
        } | Out-Null
    } 'partial automatic rollback fault 必须进入 rollback-blocked'
    Assert-True $partialRollbackMutation.done 'partial automatic rollback fixture 必须在首个已持久 action 后引入 drift'
    $partialRollbackStatusPath=[string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$partialRollbackState.plan.generationId)).statusPath
    $partialRollbackStatus=Get-Content -Raw -LiteralPath $partialRollbackStatusPath|ConvertFrom-Json
    Assert-True ($partialRollbackStatus.status -ceq 'rollback-blocked' -and @($partialRollbackStatus.restoredActionIds).Count -ge 1) 'partial automatic rollback blocked status 必须保留已持久 restoredActionIds'

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $registryFinalState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($registryFinalState.plan | ConvertTo-Json -Depth 100)
    $registryFinalMutation = [ordered]@{ done = $false }
    [byte[]]$registryFinalThirdPartyBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"external":"registry-drift-after-restore"}')
    $registryFinalError = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore `
            -Profile $fixture.profile `
            -EnvironmentReadValue $readEnvironment `
            -EnvironmentWriteValue $writeEnvironment `
            -TestFaultInjection before-registry `
            -TestAfterAutomaticRollbackAction {
                param($ActionId)
                if ($ActionId -ceq 'registry:hooks.json') {
                    [IO.File]::WriteAllBytes([string]$fixture.profile.registryPath, $registryFinalThirdPartyBytes)
                    $registryFinalMutation.done = $true
                }
            } | Out-Null
    } 'registry restore 后第三方 drift 必须阻止 automatic rollback-confirmed'
    Assert-True $registryFinalMutation.done 'fixture 必须在 registry restore 后、下一 action 前注入第三方 bytes'
    Assert-True ($registryFinalError -match 'rollback-blocked|recovery-required') 'registry final drift 不得报告 rollback-confirmed'
    $registryFinalStatusPath = [string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$registryFinalState.plan.generationId)).statusPath
    $registryFinalStatus = Get-Content -Raw -LiteralPath $registryFinalStatusPath | ConvertFrom-Json
    Assert-True ($registryFinalStatus.status -ceq 'rollback-blocked') 'registry final drift 必须持久化 rollback-blocked'
    Assert-Bytes ([IO.File]::ReadAllBytes([string]$fixture.profile.registryPath)) $registryFinalThirdPartyBytes 'final restore verification 不得覆盖 registry 第三方 bytes'

    foreach($transactionDriftKind in @('published-file','unknown-live')){
        $fixture = Initialize-ProductionFullFixture
        $environment.present = $true
        $environment.value = 'D:\Private\serena-secret'
        $transactionState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
        Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($transactionState.plan | ConvertTo-Json -Depth 100)
        [byte[]]$registryBeforeTransactionDrift = [IO.File]::ReadAllBytes([string]$fixture.profile.registryPath)
        $publishedFile = @($fixture.manifest.files | Where-Object lifecycle -cne 'retired')[0]
        $publishedPath = Join-Path ([string]$fixture.profile.hooksRoot) ([string]$publishedFile.liveRelativePath)
        $transactionDriftInjected = [ordered]@{ done = $false }
        $transactionDriftError = Assert-Throws {
            Invoke-CodexHookProductionFullApplyCore `
                -Profile $fixture.profile `
                -EnvironmentReadValue $readEnvironment `
                -EnvironmentWriteValue $writeEnvironment `
                -TestBeforeRegistryPublish {
                    if($transactionDriftKind -ceq 'published-file'){
                        [IO.File]::WriteAllText($publishedPath, 'third-party-published-file-drift', [Text.UTF8Encoding]::new($false))
                    }else{
                        [IO.File]::WriteAllText((Join-Path ([string]$fixture.profile.hooksRoot) 'third-party-unknown-live.txt'), 'unknown-live-drift', [Text.UTF8Encoding]::new($false))
                    }
                    $transactionDriftInjected.done = $true
                } | Out-Null
        } "$transactionDriftKind drift 必须在 registry 最终发布前停止 transaction"
        Assert-True $transactionDriftInjected.done "$transactionDriftKind fixture 必须在 registry publish 前注入 drift"
        Assert-True ($transactionDriftError -match 'rollback|recovery|required|final') "$transactionDriftKind drift 必须走 rollback/recovery 而非 applied"
        Assert-Bytes ([IO.File]::ReadAllBytes([string]$fixture.profile.registryPath)) $registryBeforeTransactionDrift "$transactionDriftKind drift 不得激活 registry"
        $transactionStatusPath = [string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$transactionState.plan.generationId)).statusPath
        $transactionStatus = Get-Content -Raw -LiteralPath $transactionStatusPath | ConvertFrom-Json
        Assert-True ($transactionStatus.status -cne 'applied') "$transactionDriftKind drift 不得发布 applied terminal status"
    }

    $fixture = Initialize-ProductionFullFixture
    $environment.present = $true
    $environment.value = 'D:\Private\serena-secret'
    $terminalActiveState = New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($terminalActiveState.plan | ConvertTo-Json -Depth 100)
    $terminalActivePath = [string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$terminalActiveState.plan.generationId)).activePath
    [byte[]]$terminalActiveThirdPartyBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"external":"active-terminal-drift"}')
    $terminalActiveMutation = [ordered]@{ done = $false }
    $terminalActiveError = Assert-Throws {
        Invoke-CodexHookProductionFullApplyCore `
            -Profile $fixture.profile `
            -EnvironmentReadValue $readEnvironment `
            -EnvironmentWriteValue $writeEnvironment `
            -TestBeforeAppliedActivePublish {
                [IO.File]::WriteAllBytes($terminalActivePath, $terminalActiveThirdPartyBytes)
                $terminalActiveMutation.done = $true
            } | Out-Null
    } 'applying 到 applied 的 terminal active drift 必须被 known-SHA CAS 拒绝'
    Assert-True $terminalActiveMutation.done 'terminal active fixture 必须在 applying snapshot 后注入 drift'
    Assert-True ($terminalActiveError -match 'rollback-blocked|recovery-required|漂移|CAS') 'terminal active drift 不得报告 applied'
    $terminalActiveStatusPath = [string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$terminalActiveState.plan.generationId)).statusPath
    $terminalActiveStatus = Get-Content -Raw -LiteralPath $terminalActiveStatusPath | ConvertFrom-Json
    Assert-True ($terminalActiveStatus.status -cne 'applied') 'terminal active drift 不得持久化 applied'
    Assert-Bytes ([IO.File]::ReadAllBytes($terminalActivePath)) $terminalActiveThirdPartyBytes 'terminal active CAS 不得覆盖第三方 evidence bytes'

    $conditionalDeletePath=Join-Path ([string]$fixture.profile.hooksRoot) 'conditional-delete.tmp'
    [byte[]]$conditionalDeleteBytes=[Text.UTF8Encoding]::new($false).GetBytes('deployed-delete-target')
    [IO.File]::WriteAllBytes($conditionalDeletePath,$conditionalDeleteBytes)
    $deleteRace=[ordered]@{exit=$null}
    $deleteAttack={param($Target)$deleteRace.exit=Invoke-CompetingFileWrite -Path $Target -Bytes ([Text.UTF8Encoding]::new($false).GetBytes('attacker-replacement'))}.GetNewClosure()
    Remove-CodexHookCapabilityFile -Path $conditionalDeletePath -ExpectedSha256 (Get-CodexHookBytesSha256 $conditionalDeleteBytes) -CapabilityRoot ([string]$fixture.profile.hooksRoot) -AllowedExactPaths @($conditionalDeletePath) -TestAfterSnapshot $deleteAttack
    Assert-True (-not [IO.File]::Exists($conditionalDeletePath)) 'handle-bound conditional delete 必须删除已验证 identity'
    Assert-True ($deleteRace.exit -eq 32) "target lease 必须阻止并发 writer；actual=$($deleteRace.exit)"

    $activeLineage=$null
    foreach($generation in 1..40){
        $lineageGenerationId=[guid]::NewGuid().ToString()
        $lineageEvidenceDirectory=Join-Path ([string]$fixture.profile.evidenceRoot) "deployment-$lineageGenerationId"
        $activeLineage=New-CodexHookProductionFullActiveDocument -Profile $fixture.profile -GenerationId $lineageGenerationId -EvidenceDirectory $lineageEvidenceDirectory -State applied -PreviousActive $activeLineage
        Assert-True (@($activeLineage.PSObject.Properties.Name).Count -eq 8) 'active pointer 必须保持固定 schema 深度'
    }
    Assert-True (($activeLineage|ConvertTo-Json -Depth 10) -notmatch 'previousActive\s*":\s*\{') 'active lineage 不得递归嵌入 previousActive object'
    $cycleGeneration=[string]$activeLineage.previousGenerationId
    $cycleEvidence=(Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId $cycleGeneration).evidenceDirectory
    $cycleError=Assert-Throws {
        New-CodexHookProductionFullActiveDocument -Profile $fixture.profile -GenerationId $cycleGeneration -EvidenceDirectory $cycleEvidence -State applied -PreviousActive $activeLineage | Out-Null
    } 'active pointer 二环必须拒绝'
    Assert-True ($cycleError -match 'cycle') 'active pointer 二环必须命中 cycle gate'

    $fixture = Initialize-ProductionFullFixture
    $environment.present=$true;$environment.value='D:\Private\serena-secret'
    $generationOne=New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom ([string]$fixture.profile.planPath) ($generationOne.plan|ConvertTo-Json -Depth 100)
    $applyOne=Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    $firstManaged=@($fixture.manifest.files|Where-Object lifecycle -cne 'retired')[0]
    $sourcePath=Join-Path ([string]$fixture.profile.sourceRoot) ([string]$firstManaged.relativePath)
    [byte[]]$generationTwoBytes=[Text.UTF8Encoding]::new($false).GetBytes('generation-two-source')
    [IO.File]::WriteAllBytes($sourcePath,$generationTwoBytes);$firstManaged.sha256=Get-CodexHookBytesSha256 $generationTwoBytes
    Write-Utf8NoBom ([string]$fixture.profile.manifestPath) ($fixture.manifest|ConvertTo-Json -Depth 100)
    $generationTwo=New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom ([string]$fixture.profile.planPath) ($generationTwo.plan|ConvertTo-Json -Depth 100)
    $applyTwo=Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    $restoreTwo=Get-Content (Join-Path ([string]$applyTwo.evidenceDirectory) 'restore-manifest.json') -Raw|ConvertFrom-Json -Depth 100
    $previousBackup=Join-Path ([string]$applyTwo.evidenceDirectory) ([string]$restoreTwo.previousActiveBackupRelativePath)
    Assert-True (((Get-FileHash $previousBackup -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $restoreTwo.previousActiveBackupSha256) '第二代 attested predecessor backup/hash 必须一致'
    $activeCrash={throw 'test-crash-after-active-converged' }
    $activeCrashError=Assert-Throws {Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$applyTwo.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestAfterActiveConverged $activeCrash|Out-Null} 'active 收敛后 terminal 前 crash 必须触发'
    Assert-True ($activeCrashError -match 'active-converged') 'active/terminal crash seam 原因非法'
    $activeAfterCrash=(Get-FileHash ([string](Get-CodexHookProductionFullLifecyclePaths $fixture.profile $generationTwo.plan.generationId).activePath) -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($activeAfterCrash -ceq $restoreTwo.previousActiveBackupSha256) 'crash 时 active 必须已先收敛 predecessor'
    $retryTwo=Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$applyTwo.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    $retryTwoAgain=Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$applyTwo.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    Assert-True ($retryTwo.terminalStatus -ceq 'restored' -and $retryTwoAgain.noOp) '第二代 restore retry/幂等必须收敛'
    [byte[]]$generationThreeBytes=[Text.UTF8Encoding]::new($false).GetBytes('generation-three-source')
    [IO.File]::WriteAllBytes($sourcePath,$generationThreeBytes);$firstManaged.sha256=Get-CodexHookBytesSha256 $generationThreeBytes
    Write-Utf8NoBom ([string]$fixture.profile.manifestPath) ($fixture.manifest|ConvertTo-Json -Depth 100)
    $generationThree=New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom ([string]$fixture.profile.planPath) ($generationThree.plan|ConvertTo-Json -Depth 100)
    $activePath=[string](Get-CodexHookProductionFullLifecyclePaths $fixture.profile $generationThree.plan.generationId).activePath
    $driftActive={param($Snapshot)[IO.File]::WriteAllText($activePath,'{"external":"active-drift"}',[Text.UTF8Encoding]::new($false))}.GetNewClosure()
    $activeCasError=Assert-Throws {Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestAfterPredecessorSnapshot $driftActive|Out-Null} 'snapshot 后 active 漂移必须被条件 CAS 拒绝'
    Assert-True ($activeCasError -match '漂移|CAS|临写前') 'active snapshot CAS 必须拒绝第二次路径状态'

    $fixture = Initialize-ProductionFullFixture
    $environment.present=$true;$environment.value='D:\Private\serena-secret'
    $restoreCasState=New-CodexHookProductionFullState -Profile $fixture.profile -EnvironmentReadValue $readEnvironment
    Write-Utf8NoBom ([string]$fixture.profile.planPath) ($restoreCasState.plan|ConvertTo-Json -Depth 100)
    $restoreCasApply=Invoke-CodexHookProductionFullApplyCore -Profile $fixture.profile -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment
    $restoreCasActivePath=[string](Get-CodexHookProductionFullLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$restoreCasState.plan.generationId)).activePath
    [byte[]]$restoreCasThirdParty=[Text.UTF8Encoding]::new($false).GetBytes('{"external":"restore-active-drift"}')
    $restoreCasInjected=[ordered]@{value=$false}
    $restoreCasError=Assert-Throws {
        Restore-CodexHookProductionFullCore -Profile $fixture.profile -EvidenceDirectory ([string]$restoreCasApply.evidenceDirectory) -EnvironmentReadValue $readEnvironment -EnvironmentWriteValue $writeEnvironment -TestBeforeActiveRestorePublish {
            [IO.File]::WriteAllBytes($restoreCasActivePath,$restoreCasThirdParty)
            $restoreCasInjected.value=$true
        } | Out-Null
    } 'restore active pointer preflight snapshot CAS 必须拒绝并发 evidence'
    Assert-True $restoreCasInjected.value 'restore active pointer CAS fixture 必须在 preflight 后、最终发布前注入 drift'
    Assert-True ($restoreCasError -match '漂移|CAS|临写前') 'restore active pointer CAS 必须返回 fail-closed evidence drift'
    Assert-Bytes ([IO.File]::ReadAllBytes($restoreCasActivePath)) $restoreCasThirdParty 'restore active pointer CAS 不得覆盖并发 evidence'

    $cycleStart=New-TestCodexHookProductionFullAttestedLineage -Profile $fixture.profile -PredecessorIndexes @(1,2,0)
    Assert-True ((Assert-Throws {Assert-CodexHookProductionFullAttestedLineage -Profile $fixture.profile -Active $cycleStart|Out-Null} '真实 attested 三环必须拒绝') -match 'cycle') '真实 attested 三环必须命中 visited gate'
    [object[]]$longIndexes=New-Object object[] 129
    foreach($index in 0..127){$longIndexes[$index]=$index+1}
    $longIndexes[128]=$null
    $longStart=New-TestCodexHookProductionFullAttestedLineage -Profile $fixture.profile -PredecessorIndexes $longIndexes
    Assert-True ((Assert-Throws {Assert-CodexHookProductionFullAttestedLineage -Profile $fixture.profile -Active $longStart|Out-Null} '129 节点 lineage 必须拒绝') -match '最大|maximum') '真实 attested lineage 上限必须 fail closed'

    $productionProfile=Get-CodexHookProductionFullProfile
    foreach($seam in @('after-action','before-environment','before-active-publish','after-active')){
        $seamError=Assert-Throws {Assert-CodexHookProductionFullRestoreSeamGuard -Profile $productionProfile -TestAfterRestoreAction $(if($seam-ceq'after-action'){{}}else{$null}) -TestBeforeEnvironmentRestoreWrite $(if($seam-ceq'before-environment'){{}}else{$null}) -TestBeforeActiveRestorePublish $(if($seam-ceq'before-active-publish'){{}}else{$null}) -TestAfterActiveConverged $(if($seam-ceq'after-active'){{}}else{$null})} 'production profile seam 必须入口拒绝'
        Assert-True ($seamError -match 'fixture|seam') "production seam guard 必须在读取前拒绝：$seam"
    }
    foreach($applySeam in @('fault','after-predecessor','rollback-status','before-automatic-rollback','after-automatic-rollback-action')){
        $applySeamError=Assert-Throws {Assert-CodexHookProductionFullApplySeamGuard -Profile $productionProfile -TestFaultInjection $(if($applySeam-ceq'fault'){'before-registry'}else{'none'}) -TestAfterPredecessorSnapshot $(if($applySeam-ceq'after-predecessor'){{}}else{$null}) -TestBeforeRollbackPendingStatus $(if($applySeam-ceq'rollback-status'){{}}else{$null}) -TestBeforeAutomaticRollback $(if($applySeam-ceq'before-automatic-rollback'){{}}else{$null}) -TestAfterAutomaticRollbackAction $(if($applySeam-ceq'after-automatic-rollback-action'){{}}else{$null})} 'production apply seam 必须入口拒绝'
        Assert-True ($applySeamError -match 'fixture|seam') "production apply seam guard 必须在读取前拒绝：$applySeam"
    }

    [pscustomobject][ordered]@{ ok=$true; test='CodexHookProductionFull'; fileActions=@($state.plan.actions | Where-Object kind -ceq 'file').Count }
} finally {
    try {
        if ($null -ne $fixture -and [IO.Directory]::Exists([string]$fixture.root)) { Remove-Item -LiteralPath ([string]$fixture.root) -Recurse -Force }
    } finally {
        Exit-CodexHookProductionFixtureLifecycle -Lease $lease
    }
}
