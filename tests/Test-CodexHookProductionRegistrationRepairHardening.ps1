[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'semantic-noop',
        'crash-applying-deployed',
        'crash-applied-before',
        'crash-applying-before',
        'terminal-incompatible',
        'third-hash-rejected',
        'postpublish-source-drift',
        'postpublish-live-drift',
        'postpublish-static-and-registry-third',
        'rollback-cas-race',
        'rollback-write-excluding-lease',
        'forged-evidence',
        'projection-summary'
    )]
    [string]$Case
)

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
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
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

function Invoke-HiddenPowerShellFileWrite {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][byte[]]$Bytes
    )

    $pwshPath = 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe'
    $targetLiteral = "'" + $TargetPath.Replace("'", "''") + "'"
    $payload = [Convert]::ToBase64String($Bytes)
    $command = "try { [IO.File]::WriteAllBytes($targetLiteral, [Convert]::FromBase64String('$payload')); exit 0 } catch [IO.IOException] { exit (`$_.Exception.HResult -band 0xffff) } catch { exit 254 }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process `
        -FilePath $pwshPath `
        -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    return [int]$process.ExitCode
}

function Initialize-HardeningFixture {
    param([ValidateSet('before', 'after')][string]$ManagedOrder = 'before')

    $profile = Get-CodexHookProductionRegistrationRepairFixtureProfile
    $fixtureRoot = Split-Path -Parent ([string]$profile.sourceRoot)
    if ([IO.Directory]::Exists($fixtureRoot)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    foreach ($directory in @($profile.sourceRoot, $profile.hooksRoot, $profile.planOutputDir, $profile.evidenceRoot)) {
        [void][IO.Directory]::CreateDirectory([string]$directory)
    }

    $manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'managed\codex-hooks\manifest.json') -Raw |
        ConvertFrom-Json -Depth 128
    foreach ($file in @($manifest.files)) {
        $sourcePath = Join-Path ([string]$profile.sourceRoot) ([string]$file.relativePath)
        $livePath = Join-Path ([string]$profile.hooksRoot) ([string]$file.liveRelativePath)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $sourcePath))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $livePath))
        [byte[]]$sourceBytes = [Text.UTF8Encoding]::new($false).GetBytes("hardening-source:$($file.relativePath)`n")
        [byte[]]$liveBytes = [Text.UTF8Encoding]::new($false).GetBytes("hardening-live:$($file.liveRelativePath)`n")
        [IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
        [IO.File]::WriteAllBytes($livePath, $liveBytes)
        $file.sha256 = Get-CodexHookBytesSha256 -Bytes $sourceBytes
    }
    Write-Utf8NoBom -Path ([string]$profile.manifestPath) -Text ($manifest | ConvertTo-Json -Depth 100)

    $byId = @{}
    foreach ($hook in @($manifest.hooks)) { $byId[[string]$hook.id] = $hook }
    $groups = @{}
    foreach ($id in @('provider-stability','github-cli','codex-state-policy','serena-activate','serena-dashboard')) {
        $group = New-CodexHookCanonicalRegistryGroup -Hook $byId[$id]
        $group | Add-Member -NotePropertyName customManagedField -NotePropertyValue "preserve-$id"
        $groups[$id] = $group
    }
    $unknown = [pscustomobject][ordered]@{
        matcher = 'HardeningUnknown'
        customUnknownField = 'preserve'
        hooks = @([pscustomobject][ordered]@{
            type = 'command'
            command = 'D:\Fixture\unknown-session.cmd --token hardening-secret'
            timeout = 7
            opaque = 'preserve'
        })
    }
    $managedIds = if ($ManagedOrder -ceq 'before') {
        @('provider-stability','github-cli','codex-state-policy','serena-activate','serena-dashboard')
    } else {
        @('provider-stability','codex-state-policy','serena-activate','serena-dashboard','github-cli')
    }
    $sessionStart = @($groups[$managedIds[0]], $unknown)
    foreach ($id in $managedIds[1..4]) { $sessionStart += $groups[$id] }
    $registry = [pscustomobject][ordered]@{
        registryCustomField = 'preserve'
        hooks = [pscustomobject][ordered]@{
            SessionStart = $sessionStart
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
    $registryText = $registry | ConvertTo-Json -Depth 100
    Write-Utf8NoBom -Path ([string]$profile.registryPath) -Text $registryText
    return [pscustomobject][ordered]@{
        profile = $profile
        manifest = $manifest
        registry = $registry
        registryText = $registryText
        registryBytes = [IO.File]::ReadAllBytes([string]$profile.registryPath)
        registrySha256 = (Get-FileHash -LiteralPath ([string]$profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-ActionableFixtureApply {
    $fixture = Initialize-HardeningFixture -ManagedOrder before
    $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
    Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
    $result = Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixture.profile
    return [pscustomobject][ordered]@{ fixture = $fixture; state = $state; result = $result }
}

$hardeningFixtureRoot = Split-Path -Parent ([string](Get-CodexHookProductionRegistrationRepairFixtureProfile).sourceRoot)
$fixtureLifecycleLease = Enter-CodexHookProductionFixtureLifecycle
try {
switch ($Case) {
    'semantic-noop' {
        $fixture = Initialize-HardeningFixture -ManagedOrder after
        $pretty = $fixture.registry | ConvertTo-Json -Depth 100
        $indent4 = @(
            foreach ($line in $pretty -split "`n") {
                if ($line -match '^(?<indent> +)(?<rest>.*)$') {
                    (' ' * ($Matches.indent.Length * 2)) + $Matches.rest
                } else {
                    $line
                }
            }
        ) -join "`n"
        $variants = [ordered]@{
            minified = $fixture.registry | ConvertTo-Json -Depth 100 -Compress
            indent4 = $indent4
            crlf = $pretty.Replace("`n", "`r`n")
            trailingNewline = "$pretty`n"
        }
        foreach ($name in $variants.Keys) {
            [byte[]]$beforeBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$variants[$name])
            [IO.File]::WriteAllBytes([string]$fixture.profile.registryPath, $beforeBytes)
            $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
            Assert-True (
                $state.isNoOp -and
                @($state.plan.actions).Count -eq 0 -and
                @($state.plan.postChecks).Count -eq 0 -and
                -not $state.plan.rollbackRequired
            ) "semantic-noop variant=$name 应为零动作；actual isNoOp=$($state.isNoOp),actions=$(@($state.plan.actions).Count)"
            Assert-True (
                (Get-CodexHookBytesSha256 -Bytes ([byte[]]$state.desiredRegistryBytes)) -ceq
                (Get-CodexHookBytesSha256 -Bytes $beforeBytes)
            ) "semantic-noop variant=$name 必须保留当前 registry bytes"
            Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
            $result = Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixture.profile
            Assert-True ($result.noOp -and -not $result.applied) "semantic-noop variant=$name apply 必须结构化 no-op"
            $currentSha = Get-CodexHookBytesSha256 -Bytes ([IO.File]::ReadAllBytes([string]$fixture.profile.registryPath))
            $beforeSha = Get-CodexHookBytesSha256 -Bytes $beforeBytes
            Assert-True ($currentSha -ceq $beforeSha) "semantic-noop variant=$name 不得重写 registry"
            Assert-True (-not [IO.Directory]::Exists((Join-Path ([string]$fixture.profile.evidenceRoot) '.claims'))) "semantic-noop variant=$name 不得创建 claim"
            Assert-True (@(Get-ChildItem -LiteralPath ([string]$fixture.profile.evidenceRoot) -Filter 'deployment-*' -Directory).Count -eq 0) "semantic-noop variant=$name 不得创建 evidence"
        }
    }
    'crash-applying-deployed' {
        $fixture = Initialize-HardeningFixture -ManagedOrder before
        $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
        Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
        $crashMessage = Assert-Throws {
            Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixture.profile -TestFaultInjection crash-after-registry-publish | Out-Null
        } 'apply rename 后/status 前 crash seam 必须触发'
        Assert-True ($crashMessage -match 'crash-after-registry-publish') "apply crash seam 原因非法：$crashMessage"
        $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$state.plan.generationId)
        $status = Get-Content -LiteralPath ([string]$paths.statusPath) -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($status.status -ceq 'applying') 'apply crash 后 status 必须保持 applying'
        Assert-True (((Get-FileHash -LiteralPath ([string]$fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $state.plan.registryAfterSha256) 'apply crash 后 registry 必须处于 deployed hash'
        $restored = Restore-CodexHookProductionRegistrationRepairCore -Profile $fixture.profile -EvidenceDirectory ([string]$paths.evidenceDirectory)
        Assert-True ($restored.restored) 'applying+deployed 必须恢复 registry'
        Assert-True (((Get-FileHash -LiteralPath ([string]$fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $fixture.registrySha256) 'applying+deployed 必须恢复 before hash'
    }
    'crash-applied-before' {
        $applied = New-ActionableFixtureApply
        $crashMessage = Assert-Throws {
            Restore-CodexHookProductionRegistrationRepairCore -Profile $applied.fixture.profile -EvidenceDirectory ([string]$applied.result.evidenceDirectory) -TestFaultInjection crash-after-registry-restore | Out-Null
        } 'restore rename 后/status 前 crash seam 必须触发'
        Assert-True ($crashMessage -match 'crash-after-registry-restore') "restore crash seam 原因非法：$crashMessage"
        $restored = Restore-CodexHookProductionRegistrationRepairCore -Profile $applied.fixture.profile -EvidenceDirectory ([string]$applied.result.evidenceDirectory)
        Assert-True (-not $restored.restored -and $restored.noOp) 'applied+before 必须只完成 terminal status'
        $status = Get-Content -LiteralPath (Join-Path ([string]$applied.result.evidenceDirectory) 'status.json') -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($status.status -ceq 'restored') 'applied+before terminal status 必须是 restored'
    }
    'crash-applying-before' {
        $applied = New-ActionableFixtureApply
        [IO.File]::WriteAllBytes([string]$applied.fixture.profile.registryPath, [byte[]]$applied.fixture.registryBytes)
        $statusPath = Join-Path ([string]$applied.result.evidenceDirectory) 'status.json'
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -Depth 100
        $status.status = 'applying'
        $status.completedActionIds = @()
        Write-Utf8NoBom -Path $statusPath -Text ($status | ConvertTo-Json -Depth 100)
        $terminal = Restore-CodexHookProductionRegistrationRepairCore -Profile $applied.fixture.profile -EvidenceDirectory ([string]$applied.result.evidenceDirectory)
        Assert-True (-not $terminal.restored -and $terminal.noOp -and $terminal.terminalStatus -ceq 'rolled-back') 'applying+before 必须完成 rolled-back terminal status'
        $again = Restore-CodexHookProductionRegistrationRepairCore -Profile $applied.fixture.profile -EvidenceDirectory ([string]$applied.result.evidenceDirectory)
        Assert-True (-not $again.restored -and $again.noOp -and $again.terminalStatus -ceq 'rolled-back') 'rolled-back+before 必须幂等 no-op'
    }
    'terminal-incompatible' {
        $applied = New-ActionableFixtureApply
        [byte[]]$deployedBytes = [IO.File]::ReadAllBytes([string]$applied.fixture.profile.registryPath)
        [IO.File]::WriteAllBytes([string]$applied.fixture.profile.registryPath, [byte[]]$applied.fixture.registryBytes)
        $statusPath = Join-Path ([string]$applied.result.evidenceDirectory) 'status.json'
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -Depth 100
        $status.status = 'rolled-back'
        $status.completedActionIds = @()
        Write-Utf8NoBom -Path $statusPath -Text ($status | ConvertTo-Json -Depth 100)
        [IO.File]::WriteAllBytes([string]$applied.fixture.profile.registryPath, $deployedBytes)
        $deployedHash = Get-CodexHookBytesSha256 -Bytes $deployedBytes
        $failureMessage = Assert-Throws {
            Restore-CodexHookProductionRegistrationRepairCore -Profile $applied.fixture.profile -EvidenceDirectory ([string]$applied.result.evidenceDirectory) | Out-Null
        } 'rolled-back+deployed 必须拒绝'
        Assert-True ($failureMessage -match 'terminal status') "terminal incompatible 原因非法：$failureMessage"
        Assert-True (((Get-FileHash -LiteralPath ([string]$applied.fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $deployedHash) 'terminal incompatible 拒绝必须 registry 零写'
    }
    'third-hash-rejected' {
        $applied = New-ActionableFixtureApply
        $third = Get-Content -LiteralPath ([string]$applied.fixture.profile.registryPath) -Raw | ConvertFrom-Json -Depth 100
        $third | Add-Member -NotePropertyName thirdHashSentinel -NotePropertyValue 'preserve'
        Write-Utf8NoBom -Path ([string]$applied.fixture.profile.registryPath) -Text ($third | ConvertTo-Json -Depth 100)
        $thirdHash = (Get-FileHash -LiteralPath ([string]$applied.fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()
        $failureMessage = Assert-Throws {
            Restore-CodexHookProductionRegistrationRepairCore -Profile $applied.fixture.profile -EvidenceDirectory ([string]$applied.result.evidenceDirectory) | Out-Null
        } 'third registry hash 必须拒绝'
        Assert-True ($failureMessage -match 'forged/semantic|third hash') "third hash 原因非法：$failureMessage"
        Assert-True (((Get-FileHash -LiteralPath ([string]$applied.fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $thirdHash) 'third hash 拒绝必须 registry 零写'
    }
    'postpublish-source-drift' {
        $fixture = Initialize-HardeningFixture -ManagedOrder before
        $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
        Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
        $sourcePath = [string]$state.sourceFacts[0].path
        $inject = { [IO.File]::WriteAllText($sourcePath, 'source-drift', [Text.UTF8Encoding]::new($false)) }.GetNewClosure()
        $failureMessage = Assert-Throws {
            Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixture.profile -TestAfterRegistryPublish $inject | Out-Null
        } 'post-publish source drift 必须失败'
        Assert-True ($failureMessage -match 'post-publish static facts') "post-publish source drift 应命中 static gate；actual=$failureMessage"
        Assert-True (((Get-FileHash -LiteralPath ([string]$fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $fixture.registrySha256) 'source drift 必须 rollback registry'
        $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$state.plan.generationId)
        $status = Get-Content -LiteralPath ([string]$paths.statusPath) -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($status.status -ceq 'rolled-back' -and @($status.completedActionIds).Count -eq 0) 'source drift rollback 必须留下 non-applied terminal status'
    }
    'postpublish-live-drift' {
        $fixture = Initialize-HardeningFixture -ManagedOrder before
        $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
        Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
        $livePath = [string]$state.liveFacts[0].path
        $inject = { [IO.File]::WriteAllText($livePath, 'live-drift', [Text.UTF8Encoding]::new($false)) }.GetNewClosure()
        $failureMessage = Assert-Throws {
            Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixture.profile -TestAfterRegistryPublish $inject | Out-Null
        } 'post-publish live drift 必须失败'
        Assert-True ($failureMessage -match 'post-publish static facts') "post-publish live drift 应命中 static gate；actual=$failureMessage"
        Assert-True (((Get-FileHash -LiteralPath ([string]$fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $fixture.registrySha256) 'live drift 必须 rollback registry'
        $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$state.plan.generationId)
        $status = Get-Content -LiteralPath ([string]$paths.statusPath) -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($status.status -ceq 'rolled-back' -and @($status.completedActionIds).Count -eq 0) 'live drift rollback 必须留下 non-applied terminal status'
    }
    'postpublish-static-and-registry-third' {
        $fixture = Initialize-HardeningFixture -ManagedOrder before
        $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
        Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
        $sourcePath = [string]$state.sourceFacts[0].path
        $registryPath = [string]$fixture.profile.registryPath
        $thirdRegistry = Copy-CodexHookJsonValue -Value $state.desiredRegistry
        $thirdRegistry | Add-Member -NotePropertyName externalRegistryDrift -NotePropertyValue 'preserve-third'
        [byte[]]$thirdBytes = [Text.UTF8Encoding]::new($false).GetBytes(($thirdRegistry | ConvertTo-Json -Depth 100))
        $thirdSha256 = Get-CodexHookBytesSha256 -Bytes $thirdBytes
        $inject = {
            [IO.File]::WriteAllText($sourcePath, 'source-drift', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllBytes($registryPath, $thirdBytes)
        }.GetNewClosure()
        $failureMessage = Assert-Throws {
            Invoke-CodexHookProductionRegistrationRepairApplyCore -Profile $fixture.profile -TestAfterRegistryPublish $inject | Out-Null
        } 'static+registry third drift 必须失败'
        Assert-True ($failureMessage -match 'external-registry-drift / rollback-not-attempted') "third drift 错误不得声称 rolled-back；actual=$failureMessage"
        Assert-True (((Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $thirdSha256) 'third drift 必须零覆盖'
        $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$state.plan.generationId)
        $status = Get-Content -LiteralPath ([string]$paths.statusPath) -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($status.status -ceq 'rollback-blocked' -and @($status.completedActionIds).Count -eq 0) "third drift status 必须 rollback-blocked；actual=$($status.status)"
        $beforeRestoreSha256 = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $restoreFailure = Assert-Throws {
            Restore-CodexHookProductionRegistrationRepairCore -Profile $fixture.profile -EvidenceDirectory ([string]$paths.evidenceDirectory) | Out-Null
        } 'rollback-blocked restore 必须不相容拒绝'
        Assert-True ($restoreFailure -match 'binding|rollback-blocked|不相容') "rollback-blocked restore 原因非法：$restoreFailure"
        Assert-True (((Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $beforeRestoreSha256) 'rollback-blocked restore 必须 registry 零写'
    }
    'rollback-cas-race' {
        $fixture = Initialize-HardeningFixture -ManagedOrder before
        $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
        Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
        $sourcePath = [string]$state.sourceFacts[0].path
        $registryPath = [string]$fixture.profile.registryPath
        $thirdRegistry = Copy-CodexHookJsonValue -Value $state.desiredRegistry
        $thirdRegistry | Add-Member -NotePropertyName rollbackRaceWinner -NotePropertyValue 'preserve-third'
        [byte[]]$thirdBytes = [Text.UTF8Encoding]::new($false).GetBytes(($thirdRegistry | ConvertTo-Json -Depth 100))
        $thirdSha256 = Get-CodexHookBytesSha256 -Bytes $thirdBytes
        $injectStaticDrift = {
            [IO.File]::WriteAllText($sourcePath, 'source-drift', [Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        $winRollbackRace = {
            param($Target)
            Assert-True ($Target -ceq $registryPath) 'rollback race seam target 必须是 fixture registry'
            [IO.File]::WriteAllBytes($Target, $thirdBytes)
        }.GetNewClosure()
        $failureMessage = Assert-Throws {
            Invoke-CodexHookProductionRegistrationRepairApplyCore `
                -Profile $fixture.profile `
                -TestAfterRegistryPublish $injectStaticDrift `
                -TestBeforeRollbackMove $winRollbackRace |
                Out-Null
        } 'rollback CAS race 必须失败'
        Assert-True ($failureMessage -match 'external-registry-drift / rollback-cas-lost') "rollback CAS race 必须报告 CAS lost；actual=$failureMessage"
        Assert-True ($failureMessage -notmatch 'rollback-confirmed|status=rolled-back') "rollback CAS race 不得声称 rolled-back；actual=$failureMessage"
        Assert-True (((Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $thirdSha256) 'rollback CAS race winner 必须零覆盖保留'
        $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$state.plan.generationId)
        $status = Get-Content -LiteralPath ([string]$paths.statusPath) -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($status.status -ceq 'rollback-blocked' -and @($status.completedActionIds).Count -eq 0) "rollback CAS race status 必须 rollback-blocked；actual=$($status.status)"
        $beforeRestoreSha256 = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $restoreFailure = Assert-Throws {
            Restore-CodexHookProductionRegistrationRepairCore -Profile $fixture.profile -EvidenceDirectory ([string]$paths.evidenceDirectory) | Out-Null
        } 'rollback CAS race restore 必须不相容拒绝'
        Assert-True ($restoreFailure -match 'binding|rollback-blocked|不相容') "rollback CAS race restore 原因非法：$restoreFailure"
        Assert-True (((Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $beforeRestoreSha256) 'rollback CAS race restore 必须 registry 零写'
    }
    'rollback-write-excluding-lease' {
        $fixture = Initialize-HardeningFixture -ManagedOrder before
        $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
        Write-Utf8NoBom -Path ([string]$fixture.profile.planPath) -Text ($state.plan | ConvertTo-Json -Depth 100)
        $sourcePath = [string]$state.sourceFacts[0].path
        $registryPath = [string]$fixture.profile.registryPath
        [byte[]]$thirdBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"external":"third"}')
        $injectStaticDrift = {
            [IO.File]::WriteAllText($sourcePath, 'source-drift', [Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        $rollbackLeaseAttempts = [ordered]@{ writeExit = $null }
        $attackAfterSnapshot = {
            param($Target)
            Assert-True ($Target -ceq $registryPath) 'rollback target lease seam 必须命中 fixture registry'
            $rollbackLeaseAttempts.writeExit = Invoke-HiddenPowerShellFileWrite `
                -TargetPath $Target `
                -Bytes $thirdBytes
        }.GetNewClosure()
        $failureMessage = Assert-Throws {
            Invoke-CodexHookProductionRegistrationRepairApplyCore `
                -Profile $fixture.profile `
                -TestAfterRegistryPublish $injectStaticDrift `
                -TestAfterRollbackSnapshot $attackAfterSnapshot |
                Out-Null
        } 'post-publish static drift 必须触发自动 rollback'
        Assert-True ($failureMessage -match 'rollback-confirmed') "target lease rollback 必须完成受保护回滚；actual=$failureMessage"
        Assert-True ($rollbackLeaseAttempts.writeExit -eq 32) "rollback write-excluding lease 必须跨进程阻止内容写入；actual=$($rollbackLeaseAttempts.writeExit)"
        Assert-True (((Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $fixture.registrySha256) 'target lease 保护下 rollback 必须恢复 before hash'
        $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $fixture.profile -GenerationId ([string]$state.plan.generationId)
        $status = Get-Content -LiteralPath ([string]$paths.statusPath) -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($status.status -ceq 'rolled-back') 'target lease 保护下 rollback status 必须 rolled-back'
    }
    'forged-evidence' {
        $applied = New-ActionableFixtureApply
        $evidence = [string]$applied.result.evidenceDirectory
        $backupPath = Join-Path $evidence 'backups\registry.bin'
        $restorePath = Join-Path $evidence 'restore-manifest.json'
        $claimPath = Join-Path ([string]$applied.fixture.profile.evidenceRoot) ".claims\$($applied.state.plan.generationId).json"
        $forged = Copy-CodexHookJsonValue -Value $applied.fixture.registry
        $forged.hooks.SessionStart += [pscustomobject][ordered]@{
            matcher = 'Injected'
            hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'D:\Injected\evil.cmd'; timeout = 10 })
        }
        [byte[]]$forgedBytes = [Text.UTF8Encoding]::new($false).GetBytes(($forged | ConvertTo-Json -Depth 100))
        [IO.File]::WriteAllBytes($backupPath, $forgedBytes)
        $forgedHash = Get-CodexHookBytesSha256 -Bytes $forgedBytes
        $restore = Get-Content -LiteralPath $restorePath -Raw | ConvertFrom-Json -Depth 100
        $restore.actions[0].beforeSha256 = $forgedHash
        $restore.actions[0].backupSha256 = $forgedHash
        Write-Utf8NoBom -Path $restorePath -Text ($restore | ConvertTo-Json -Depth 100)
        $restoreHash = (Get-FileHash -LiteralPath $restorePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $claim = Get-Content -LiteralPath $claimPath -Raw | ConvertFrom-Json -Depth 100
        $claim.restoreManifestSha256 = $restoreHash
        Write-Utf8NoBom -Path $claimPath -Text ($claim | ConvertTo-Json -Depth 100)
        $statusPath = Join-Path $evidence 'status.json'
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -Depth 100
        Write-Utf8NoBom -Path $statusPath -Text ($status | ConvertTo-Json -Depth 100)
        $deployedHash = (Get-FileHash -LiteralPath ([string]$applied.fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()
        $failureMessage = Assert-Throws {
            Restore-CodexHookProductionRegistrationRepairCore -Profile $applied.fixture.profile -EvidenceDirectory $evidence | Out-Null
        } 'forged evidence 必须被拒绝'
        Assert-True ($failureMessage -match 'semantic|fingerprint|forged|语义') "forged evidence 应由非 evidence 语义门禁拒绝；actual=$failureMessage"
        Assert-True (((Get-FileHash -LiteralPath ([string]$applied.fixture.profile.registryPath) -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq $deployedHash) 'forged evidence 拒绝时 registry 必须零写'
    }
    'projection-summary' {
        $fixture = Initialize-HardeningFixture -ManagedOrder before
        $state = New-CodexHookProductionRegistrationRepairState -Profile $fixture.profile
        Assert-True ($state.plan.PSObject.Properties.Name -contains 'projectionSummary') 'production plan 缺少 projectionSummary'
        $summary = $state.plan.projectionSummary
        Assert-True (($summary.managedBeforeOrder -join ',') -ceq 'provider-stability,github-cli,codex-state-policy,serena-activate,serena-dashboard') 'projection managed before order 非法'
        Assert-True (($summary.managedAfterOrder -join ',') -ceq 'provider-stability,codex-state-policy,serena-activate,serena-dashboard,github-cli') 'projection managed after order 非法'
        Assert-True ($summary.restartRequired -eq $true -and $summary.fileActions -eq 0 -and $summary.environmentActions -eq 0) 'projection restart/action summary 非法'
    }
}

[pscustomobject][ordered]@{ ok = $true; case = $Case }
} finally {
    try {
        if ([IO.Directory]::Exists($hardeningFixtureRoot)) {
            Remove-Item -LiteralPath $hardeningFixtureRoot -Recurse -Force
        }
    } finally {
        Exit-CodexHookProductionFixtureLifecycle -Lease $fixtureLifecycleLease
    }
}
