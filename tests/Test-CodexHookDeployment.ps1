[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PolicyPath = Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1'
$ManifestPath = Join-Path $ProjectRoot 'managed\codex-hooks\manifest.json'

. $PolicyPath

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw "断言失败：$Message"
    }
}

function Assert-Sequence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True ($Actual.Count -eq $Expected.Count) "$Message；数量不一致"
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-True ([string]::Equals([string]$Actual[$index], [string]$Expected[$index], [StringComparison]::Ordinal)) "$Message；index=$index"
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
        return $_.Exception.Message
    }
    throw "未拒绝：$Message"
}

function Get-ByteSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
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

function New-RegistryGroup {
    param(
        [Parameter(Mandatory)][object]$Hook,
        [string]$Marker
    )

    $group = [pscustomobject][ordered]@{
        hooks = @(
            [pscustomobject][ordered]@{
                type = 'command'
                command = ((@([string]$Hook.commandPath) + @($Hook.arguments)) -join ' ')
                timeout = [int]$Hook.timeoutSeconds
            }
        )
    }
    if ($null -ne $Hook.matcher) {
        $group | Add-Member -NotePropertyName matcher -NotePropertyValue ([string]$Hook.matcher)
    }
    if (-not [string]::IsNullOrWhiteSpace($Marker)) {
        $group | Add-Member -NotePropertyName managedMarker -NotePropertyValue $Marker
    }
    return $group
}

function Get-ManagedCommandNames {
    param([Parameter(Mandatory)][object[]]$Groups)

    return @(
        foreach ($group in $Groups) {
            if ($null -eq $group -or $group.PSObject.Properties.Name -notcontains 'hooks') { continue }
            $entries = @($group.hooks)
            if ($entries.Count -ne 1 -or $entries[0].PSObject.Properties.Name -notcontains 'command' -or $entries[0].command -isnot [string]) { continue }
            $parsed = Split-CodexHookCommandLine -Command ([string]$entries[0].command)
            if (-not $parsed.parsed -or $parsed.tokens.Count -eq 0) { continue }
            $leaf = [IO.Path]::GetFileName([string]$parsed.tokens[0])
            if ($leaf -in @(
                'codex-provider-stability-guard.cmd',
                'codex-projectless-root-d.cmd',
                'serena-activate-guarded.cmd',
                'serena-dashboard-guard.cmd',
                'codex-github-cli-guard.cmd'
            )) {
                $leaf
            }
        }
    )
}

$manifest = Read-CodexHookManifest -Path $ManifestPath
$realSerenaHomeBefore = [Environment]::GetEnvironmentVariable('SERENA_HOME', 'User')
$sessionHooks = @($manifest.hooks | Where-Object { $_.event -ceq 'SessionStart' })
$byId = @{}
foreach ($hook in $sessionHooks) { $byId[[string]$hook.id] = $hook }

$unknownBefore = [pscustomobject][ordered]@{
    matcher = 'fixture-before'
    customOwner = 'fixture-before'
    customObject = [pscustomobject][ordered]@{ keep = $true; level = 2 }
    hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'D:\Fixture\unknown-before.cmd --opaque'; timeout = 9; customEntry = 'keep' })
}
$unknownAfter = [pscustomobject][ordered]@{
    customOwner = 'fixture'
    hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'D:\Fixture\unknown-after.cmd'; timeout = 7 })
}
$stopGroups = @([pscustomobject][ordered]@{ customStop = 'unchanged'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'D:\Fixture\stop.cmd' }) })
$preToolGroups = @([pscustomobject][ordered]@{ matcher = 'Fixture'; hooks = @([pscustomobject][ordered]@{ type = 'prompt'; prompt = 'unchanged' }) })
$live = [pscustomobject][ordered]@{
    schema = 99
    customTop = [pscustomobject][ordered]@{ keep = 'yes' }
    hooks = [pscustomobject][ordered]@{
        SessionStart = @(
            $unknownBefore
            (New-RegistryGroup -Hook $byId['github-cli'] -Marker 'github-preserved')
            (New-RegistryGroup -Hook $byId['codex-state-policy'])
            (New-RegistryGroup -Hook $byId['provider-stability'])
            (New-RegistryGroup -Hook $byId['serena-activate'])
            (New-RegistryGroup -Hook $byId['serena-dashboard'])
            $unknownAfter
        )
        Stop = $stopGroups
        PreToolUse = $preToolGroups
    }
}

$beforeUnknownJson = @($unknownBefore, $unknownAfter) | ConvertTo-Json -Depth 30 -Compress
$beforeStopJson = $live.hooks.Stop | ConvertTo-Json -Depth 30 -Compress
$beforePreToolJson = $live.hooks.PreToolUse | ConvertTo-Json -Depth 30 -Compress
$merged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $live -Mode registration-repair

Assert-Sequence -Actual @(Get-ManagedCommandNames -Groups @($merged.hooks.SessionStart)) -Expected @(
    'codex-provider-stability-guard.cmd',
    'codex-projectless-root-d.cmd',
    'serena-activate-guarded.cmd',
    'serena-dashboard-guard.cmd',
    'codex-github-cli-guard.cmd'
) -Message 'SessionStart 受管 identity 必须恢复固定顺序'
Assert-True ($merged.hooks.SessionStart[0].customOwner -ceq 'fixture-before') '前置未知 group 必须保持原位置与字段'
Assert-True ($merged.hooks.SessionStart[-1].customOwner -ceq 'fixture') '后置未知 group 必须保持原位置与字段'
Assert-True ((@($merged.hooks.SessionStart[0], $merged.hooks.SessionStart[-1]) | ConvertTo-Json -Depth 30 -Compress) -ceq $beforeUnknownJson) '未知 group 必须深拷贝原样保留'
Assert-True (($merged.hooks.Stop | ConvertTo-Json -Depth 30 -Compress) -ceq $beforeStopJson) 'registration-repair 不得修改 Stop'
Assert-True (($merged.hooks.PreToolUse | ConvertTo-Json -Depth 30 -Compress) -ceq $beforePreToolJson) 'registration-repair 不得修改 PreToolUse'
$githubGroup = @($merged.hooks.SessionStart | Where-Object { $_.PSObject.Properties.Name -contains 'managedMarker' })
Assert-True ($githubGroup.Count -eq 1 -and $githubGroup[0].managedMarker -ceq 'github-preserved') '已有单 entry 受管 group 必须复用原对象字段'
Assert-True (-not [object]::ReferenceEquals($merged, $live)) '合并结果必须是深拷贝，不能复用 live registry 根对象'

$timeoutDriftRegistry = Copy-CodexHookJsonValue -Value $live
$timeoutProviderGroup = @($timeoutDriftRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -like '*codex-provider-stability-guard.cmd*' })[0]
$timeoutProviderGroup.hooks[0].timeout = 3
$timeoutProviderGroup | Add-Member -NotePropertyName customTimeoutOwner -NotePropertyValue 'preserve'
$timeoutMerged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $timeoutDriftRegistry -Mode registration-repair
$timeoutMergedProvider = @($timeoutMerged.hooks.SessionStart | Where-Object { $_.PSObject.Properties.Name -contains 'customTimeoutOwner' })[0]
Assert-True ($timeoutMergedProvider.hooks[0].timeout -eq 10 -and $timeoutMergedProvider.customTimeoutOwner -ceq 'preserve') 'timeout-only drift 必须修正且保留未知字段'
$timeoutMergedAgain = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $timeoutMerged -Mode registration-repair
Assert-True (($timeoutMergedAgain | ConvertTo-Json -Depth 100 -Compress) -ceq ($timeoutMerged | ConvertTo-Json -Depth 100 -Compress)) 'registry merge 必须二次同 bytes'

$missingTailRegistry = Copy-CodexHookJsonValue -Value $live
$missingTailRegistry.hooks.SessionStart = @($missingTailRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -notlike '*codex-github-cli-guard.cmd*' })
$missingTailMerged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $missingTailRegistry -Mode registration-repair
Assert-True ([IO.Path]::GetFileName((Split-CodexHookCommandLine -Command ([string]$missingTailMerged.hooks.SessionStart[-1].hooks[0].command)).tokens[0]) -ceq 'codex-github-cli-guard.cmd') '缺失尾部 GitHub identity 必须只在尾部 append'

$missingNonTailRegistry = Copy-CodexHookJsonValue -Value $live
$missingNonTailRegistry.hooks.SessionStart = @($missingNonTailRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -notlike '*codex-provider-stability-guard.cmd*' })
[void](Assert-Throws { Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $missingNonTailRegistry -Mode registration-repair | Out-Null } '缺失非尾部 managed identity 必须 fail closed')

$mixedRegistry = Copy-CodexHookJsonValue -Value $live
$mixedProvider = @($mixedRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -like '*codex-provider-stability-guard.cmd*' })[0]
$mixedProvider.hooks = @($mixedProvider.hooks[0], [pscustomobject][ordered]@{ type = 'command'; command = 'D:\Fixture\mixed-unknown.cmd' })
[void](Assert-Throws { Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $mixedRegistry -Mode registration-repair | Out-Null } 'mixed managed/unknown multi-entry group 必须 fail closed')

$identityDriftRegistry = Copy-CodexHookJsonValue -Value $live
$identityDriftProvider = @($identityDriftRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -like '*codex-provider-stability-guard.cmd*' })[0]
$identityDriftProvider.hooks[0].command += ' --identity-drift'
[void](Assert-Throws { Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $identityDriftRegistry -Mode registration-repair | Out-Null } '同 custom wrapper path 的 identity drift 必须 fail closed')

$unclosedManagedRegistry = Copy-CodexHookJsonValue -Value $live
$unclosedManagedGithub = @($unclosedManagedRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -like '*codex-github-cli-guard.cmd*' })[0]
$unclosedManagedGithub.hooks[0].command = '"D:\Codex\.codex\hooks\codex-github-cli-guard.cmd --token fixture-secret'
$unclosedManagedError = Assert-Throws -Message '未闭合引号中的完整受管 wrapper path 必须 fail closed' -Action {
    Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $unclosedManagedRegistry -Mode registration-repair | Out-Null
}
Assert-True ($unclosedManagedError -match '无法安全解析|identity') '不可解析受管 wrapper 必须输出脱敏 ownership reason'
Assert-True ($unclosedManagedError -notmatch 'fixture-secret') '不可解析受管 wrapper 错误不得回显 raw command/secret'

$dotSegmentManagedRegistry = Copy-CodexHookJsonValue -Value $live
$dotSegmentManagedGithub = @($dotSegmentManagedRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -like '*codex-github-cli-guard.cmd*' })[0]
$dotSegmentManagedGithub.hooks[0].command = '"D:\Codex\.codex\hooks\.\codex-github-cli-guard.cmd --token fixture-secret'
$dotSegmentManagedError = Assert-Throws -Message '不可解析 command target 的 dot segment 规范化后命中 managed wrapper 必须 fail closed' -Action {
    Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $dotSegmentManagedRegistry -Mode registration-repair | Out-Null
}
Assert-True ($dotSegmentManagedError -notmatch 'fixture-secret') 'dot segment ownership 错误不得回显 raw command/secret'

$parentSegmentManagedRegistry = Copy-CodexHookJsonValue -Value $live
$parentSegmentManagedGithub = @($parentSegmentManagedRegistry.hooks.SessionStart | Where-Object { @($_.hooks)[0].command -like '*codex-github-cli-guard.cmd*' })[0]
$parentSegmentManagedGithub.hooks[0].command = '  "D:/Codex/.codex/hooks/sub/../codex-github-cli-guard.cmd --token fixture-secret'
$parentSegmentManagedError = Assert-Throws -Message '不可解析 command target 的 parent segment 规范化后命中 managed wrapper 必须 fail closed' -Action {
    Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $parentSegmentManagedRegistry -Mode registration-repair | Out-Null
}
Assert-True ($parentSegmentManagedError -notmatch 'fixture-secret') 'parent segment ownership 错误不得回显 raw command/secret'

$backupSuffixRegistry = Copy-CodexHookJsonValue -Value $missingTailRegistry
$backupSuffixRegistry.hooks.SessionStart += [pscustomobject][ordered]@{
    customBackupSuffixUnknown = 'preserve'
    hooks = @([pscustomobject][ordered]@{
        type = 'command'
        command = '"D:\Codex\.codex\hooks\codex-github-cli-guard.cmd.backup --opaque'
    })
}
$backupSuffixMerged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $backupSuffixRegistry -Mode registration-repair
Assert-True (@($backupSuffixMerged.hooks.SessionStart | Where-Object {
    $_.PSObject.Properties.Name -contains 'customBackupSuffixUnknown' -and $_.customBackupSuffixUnknown -ceq 'preserve'
}).Count -eq 1) 'managed wrapper 文件名加 .backup 后缀必须保持 unknown'

$managedLaterArgumentRegistry = Copy-CodexHookJsonValue -Value $missingTailRegistry
$managedLaterArgumentRegistry.hooks.SessionStart += [pscustomobject][ordered]@{
    customManagedLaterArgument = 'preserve'
    hooks = @([pscustomobject][ordered]@{
        type = 'command'
        command = 'D:\Fixture\unknown-target.cmd --opaque "D:\Codex\.codex\hooks\codex-github-cli-guard.cmd'
    })
}
$managedLaterArgumentMerged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $managedLaterArgumentRegistry -Mode registration-repair
Assert-True (@($managedLaterArgumentMerged.hooks.SessionStart | Where-Object {
    $_.PSObject.Properties.Name -contains 'customManagedLaterArgument' -and $_.customManagedLaterArgument -ceq 'preserve'
}).Count -eq 1) '受管 path 只出现在后续参数时必须保持 unknown，不得 substring 误报'

$wrongParentRegistry = Copy-CodexHookJsonValue -Value $missingTailRegistry
$wrongParentRegistry.hooks.SessionStart += [pscustomobject][ordered]@{
    customMalformedUnknown = 'preserve'
    hooks = @([pscustomobject][ordered]@{
        type = 'command'
        command = '"D:\Fixture\elsewhere\codex-github-cli-guard.cmd --opaque'
    })
}
$wrongParentMerged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $wrongParentRegistry -Mode registration-repair
Assert-True (@($wrongParentMerged.hooks.SessionStart | Where-Object {
    $_.PSObject.Properties.Name -contains 'customMalformedUnknown' -and $_.customMalformedUnknown -ceq 'preserve'
}).Count -eq 1) '同文件名错误父目录的不可解析 command 必须保持 unknown'
Assert-True (@(Get-ManagedCommandNames -Groups @($wrongParentMerged.hooks.SessionStart))[-1] -ceq 'codex-github-cli-guard.cmd') '错误父目录 unknown 不得阻止缺失尾部 identity append'

$fullRegistry = Copy-CodexHookJsonValue -Value $live
$fullRegistry.hooks.Stop = @()
$fullRegistry.hooks.PreToolUse = @(
    (New-RegistryGroup -Hook ($manifest.hooks | Where-Object id -ceq 'serena-auto-approve'))
    [pscustomobject][ordered]@{
        matcher = 'Bash'
        customVendorSibling = 'preserve'
        hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'D:\Codex\tools\uv\bin\serena-hooks.exe other --client=codex'; timeout = 8 })
    }
)
$fullMerged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $fullRegistry -Mode full
$fullFacts = @(
    foreach ($eventName in @('Stop', 'PreToolUse')) {
        foreach ($group in @($fullMerged.hooks.$eventName)) {
            foreach ($entry in @($group.hooks)) { if ($entry.command -is [string]) { [string]$entry.command } }
        }
    }
)
Assert-True (@($fullFacts | Where-Object { $_ -like '* cleanup --client=codex' }).Count -eq 1) 'full 必须补齐缺失 active Stop identity'
Assert-True (@($fullFacts | Where-Object { $_ -like '* remind --client=codex' }).Count -eq 1) 'full 必须补齐缺失 active PreToolUse identity'
Assert-True (@($fullFacts | Where-Object { $_ -like '* auto-approve --client=codex' }).Count -eq 0) 'full 必须精确移除 retired identity'
Assert-True (@($fullMerged.hooks.PreToolUse | Where-Object { $_.PSObject.Properties.Name -contains 'customVendorSibling' -and $_.customVendorSibling -ceq 'preserve' }).Count -eq 1) 'vendor shared executable 只有完整 identity 才归属，未知 sibling 必须保留'

$fixtureRoot = Join-Path $ProjectRoot 'reports\codex-hook-deployment-test'
Assert-True (Test-CodexHookPathWithin -Path $fixtureRoot -ParentPath (Join-Path $ProjectRoot 'reports')) 'fixture root 必须位于项目 reports'
if ([IO.Directory]::Exists($fixtureRoot)) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$fixtureSourceRoot = Join-Path $fixtureRoot 'fixture-source'
$fixtureCodexHome = Join-Path $fixtureRoot 'fixture-home'
$fixtureHooksRoot = Join-Path $fixtureCodexHome 'hooks'
$planOutput = Join-Path $fixtureRoot 'plan'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
[void][IO.Directory]::CreateDirectory($fixtureSourceRoot)
[void][IO.Directory]::CreateDirectory($fixtureHooksRoot)

$handleLockPath = Join-Path $fixtureRoot 'handle-lock.bin'
[IO.File]::WriteAllBytes($handleLockPath, [byte[]](1, 2, 3, 4))
$verifiedHandle = [CodexHookGovernance.HandleBoundFileReader]::OpenVerifiedReadHandle($handleLockPath)
try {
    [void](Assert-Throws { [IO.File]::Move($handleLockPath, "$handleLockPath.moved") } 'verified read handle 持有期间 rename 必须被拒绝')
    [void](Assert-Throws { [IO.File]::Delete($handleLockPath) } 'verified read handle 持有期间 delete 必须被拒绝')
} finally {
    $verifiedHandle.Dispose()
}
[IO.File]::Delete($handleLockPath)

$existingRacePath = Join-Path $fixtureRoot 'existing-race.bin'
[byte[]]$existingRaceBefore = [Text.UTF8Encoding]::new($false).GetBytes('approved-before')
[byte[]]$existingRaceAfter = [Text.UTF8Encoding]::new($false).GetBytes('approved-after')
[byte[]]$existingRaceThird = [Text.UTF8Encoding]::new($false).GetBytes('external-third')
[IO.File]::WriteAllBytes($existingRacePath, $existingRaceBefore)
$script:existingRaceWriteExit = $null
Set-CodexHookAtomicFileBytes `
    -Path $existingRacePath `
    -Bytes $existingRaceAfter `
    -ExpectedExists $true `
    -ExpectedSha256 (Get-ByteSha256 -Bytes $existingRaceBefore) `
    -AfterSha256 (Get-ByteSha256 -Bytes $existingRaceAfter) `
    -Scope 'existing target lease race fixture' `
    -TestAfterPremoveSnapshot {
        param($Target)
        $script:existingRaceWriteExit = Invoke-HiddenPowerShellFileWrite `
            -TargetPath $Target `
            -Bytes $existingRaceThird
    }
Assert-True ($script:existingRaceWriteExit -eq 32) "write-excluding target lease 必须跨进程阻止最终 snapshot 后的内容写入；actual=$script:existingRaceWriteExit"
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($existingRacePath))) -ceq (Get-ByteSha256 -Bytes $existingRaceAfter)) 'approved initial publish 必须原子成功'
[IO.File]::Delete($existingRacePath)

$missingRacePath = Join-Path $fixtureRoot 'missing-race.bin'
[byte[]]$managedRaceBytes = [Text.UTF8Encoding]::new($false).GetBytes('managed')
$missingRaceError = Assert-Throws -Message 'missing target 在 temp 后竞争创建时不得覆盖' -Action {
    Set-CodexHookAtomicFileBytes `
        -Path $missingRacePath `
        -Bytes $managedRaceBytes `
        -ExpectedExists $false `
        -ExpectedSha256 $null `
        -AfterSha256 (Get-ByteSha256 -Bytes $managedRaceBytes) `
        -Scope 'missing race fixture' `
        -BeforeMove { param($Target) [IO.File]::WriteAllText($Target, 'competitor', [Text.UTF8Encoding]::new($false)) }
}
Assert-True ($missingRaceError -match 'premove|状态漂移|missing') 'missing target race 必须由 move 前 CAS 拒绝'
Assert-True ([IO.File]::ReadAllText($missingRacePath) -ceq 'competitor') 'missing target race 不得覆盖竞争者 bytes'
[IO.File]::Delete($missingRacePath)

$missingLateRacePath = Join-Path $fixtureRoot 'missing-late-race.bin'
$script:missingLateRaceWriteExit = $null
$missingLateRaceError = Assert-Throws -Message 'missing target 在最终 missing snapshot 后竞争创建时必须 collision-safe' -Action {
    Set-CodexHookAtomicFileBytes `
        -Path $missingLateRacePath `
        -Bytes $managedRaceBytes `
        -ExpectedExists $false `
        -ExpectedSha256 $null `
        -AfterSha256 (Get-ByteSha256 -Bytes $managedRaceBytes) `
        -Scope 'missing late race fixture' `
        -TestAfterPremoveSnapshot {
            param($Target)
            $script:missingLateRaceWriteExit = Invoke-HiddenPowerShellFileWrite `
                -TargetPath $Target `
                -Bytes ([Text.UTF8Encoding]::new($false).GetBytes('late-competitor'))
        }
}
Assert-True ($script:missingLateRaceWriteExit -eq 0) 'missing target 的竞争创建必须真实发生在最终 snapshot 后'
Assert-True ($missingLateRaceError -match 'rename|already exists|已存在|存在') "missing target late race 必须由 flags=0 rename collision 拒绝；actual=$missingLateRaceError"
Assert-True ([IO.File]::ReadAllText($missingLateRacePath) -ceq 'late-competitor') 'missing target late race 不得覆盖竞争者 bytes'
[IO.File]::Delete($missingLateRacePath)

$fixtureManifest = Copy-CodexHookJsonValue -Value $manifest
$fixtureManifest.environment = @(
    [pscustomobject][ordered]@{
        name = 'SERENA_HOME'
        scope = 'User'
        desired = 'D:\Codex\.serena'
        restartRequired = $true
    }
)
$expectedOldFileBytes = @{}
$expectedNewFileBytes = @{}
foreach ($file in @($fixtureManifest.files)) {
    $sourcePath = Join-Path $fixtureSourceRoot ([string]$file.relativePath)
    $targetPath = Join-Path $fixtureHooksRoot ([string]$file.liveRelativePath)
    [byte[]]$sourceBytes = [Text.UTF8Encoding]::new($false).GetBytes("fixture-source:$($file.relativePath)`n")
    [byte[]]$targetBytes = [Text.UTF8Encoding]::new($false).GetBytes("fixture-live-before:$($file.liveRelativePath)`n")
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $sourcePath))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
    [IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
    [IO.File]::WriteAllBytes($targetPath, $targetBytes)
    $file.sha256 = Get-ByteSha256 -Bytes $sourceBytes
    $expectedOldFileBytes[[IO.Path]::GetFullPath($targetPath)] = $targetBytes
    $expectedNewFileBytes[[IO.Path]::GetFullPath($targetPath)] = $sourceBytes
}
[void](Assert-CodexHookManifest -Manifest $fixtureManifest)
$fixtureManifestPath = Join-Path $fixtureRoot 'fixture-manifest.json'
Write-Utf8NoBom -Path $fixtureManifestPath -Text ($fixtureManifest | ConvertTo-Json -Depth 100)

$fixtureById = @{}
foreach ($hook in @($fixtureManifest.hooks)) { $fixtureById[[string]$hook.id] = $hook }
$fixtureRegistry = Copy-CodexHookJsonValue -Value $live
$fixtureRegistry.hooks.Stop = @(
    [pscustomobject][ordered]@{ customStop = 'preserve'; hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'D:\Fixture\unknown-stop.cmd --token fixture-secret' }) }
    (New-RegistryGroup -Hook $fixtureById['serena-cleanup'])
)
$fixtureRegistry.hooks.PreToolUse = @(
    (New-RegistryGroup -Hook $fixtureById['serena-auto-approve'])
    [pscustomobject][ordered]@{ matcher = 'Fixture'; customPreTool = 'preserve'; hooks = @([pscustomobject][ordered]@{ type = 'prompt'; prompt = 'opaque' }) }
    (New-RegistryGroup -Hook $fixtureById['serena-reminder'])
)
$fixtureRegistryPath = Join-Path $fixtureCodexHome 'hooks.json'
Write-Utf8NoBom -Path $fixtureRegistryPath -Text ($fixtureRegistry | ConvertTo-Json -Depth 100)
[byte[]]$registryBeforeBytes = [IO.File]::ReadAllBytes($fixtureRegistryPath)

$newPlanScript = Join-Path $ProjectRoot 'scripts\New-CodexHookDeploymentPlan.ps1'
$invokeScript = Join-Path $ProjectRoot 'scripts\Invoke-CodexHookDeployment.ps1'
$restoreScript = Join-Path $ProjectRoot 'scripts\Restore-CodexHookDeployment.ps1'
$environmentStore = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$environmentStore['User|SERENA_HOME'] = 'D:\Fixture\serena-before'
$readEnvironment = { param($Name, $Scope) return $environmentStore["$Scope|$Name"] }.GetNewClosure()
$writeEnvironment = { param($Name, $Scope, $Value) $environmentStore["$Scope|$Name"] = $Value }.GetNewClosure()
$publishedPlan = & $newPlanScript `
    -ManifestPath $fixtureManifestPath `
    -FixtureSourceRoot $fixtureSourceRoot `
    -FixtureCodexHome $fixtureCodexHome `
    -Mode full `
    -OutputDir $planOutput `
    -EnvironmentReadValue $readEnvironment
$planJson = [IO.File]::ReadAllText($publishedPlan.jsonPath)
$plan = $planJson | ConvertFrom-Json -Depth 100
Assert-True ($plan.artifactType -ceq 'env-governance.codex-hook-deployment-plan' -and $plan.schemaVersion -eq 1) 'plan schema 必须固定'
Assert-True ($plan.applyEligible) '无漂移 fixture plan 必须可 apply'
Assert-True ($planJson -notmatch 'fixture-secret|unknown-stop\.cmd|"DesiredRegistry"|"desiredRegistry"') 'plan 不得嵌入 raw registry 或 unknown command'

$driftSourcePath = Join-Path $fixtureSourceRoot ([string]$fixtureManifest.files[0].relativePath)
[IO.File]::WriteAllText($driftSourcePath, 'source-drift', [Text.UTF8Encoding]::new($false))
$sourceGateError = Assert-Throws -Message 'source hash 漂移必须在任何 target 写入前拒绝' -Action {
    & $invokeScript `
        -PlanPath $publishedPlan.jsonPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $evidenceRoot `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($sourceGateError -match 'source|源|hash|SHA') "source drift 错误必须是脱敏 gate 原因；actual=$sourceGateError"
foreach ($targetPath in $expectedOldFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedOldFileBytes[$targetPath])) 'source final gate 失败后 live file 字节必须不变'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq (Get-ByteSha256 -Bytes $registryBeforeBytes)) 'source final gate 失败后 registry 字节必须不变'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Fixture\serena-before') 'source final gate 失败不得写环境 adapter'

$firstTargetPath = [IO.Path]::GetFullPath((Join-Path $fixtureHooksRoot ([string]$fixtureManifest.files[0].liveRelativePath)))
[byte[]]$firstSourceBytes = $expectedNewFileBytes[$firstTargetPath]
[IO.File]::WriteAllBytes($driftSourcePath, $firstSourceBytes)

$refusalEvidenceRoot = Join-Path $fixtureRoot 'refusal-evidence'
$noApplyResult = & $invokeScript `
    -PlanPath $publishedPlan.jsonPath `
    -ApprovedScope 'codex-hook-governance-2026-07-11' `
    -EvidenceRoot $refusalEvidenceRoot
Assert-True (-not $noApplyResult.applied -and $noApplyResult.refusalReason -ceq 'apply-switch-required') '缺少 -Apply 必须只返回结构化拒绝原因'
Assert-True (-not [IO.Directory]::Exists($refusalEvidenceRoot)) '缺少 -Apply 不得创建 evidence/temp/backup'
$wrongScopeResult = & $invokeScript `
    -PlanPath $publishedPlan.jsonPath `
    -Apply `
    -ApprovedScope 'wrong-scope' `
    -EvidenceRoot $refusalEvidenceRoot
Assert-True (-not $wrongScopeResult.applied -and $wrongScopeResult.refusalReason -ceq 'approved-scope-mismatch') 'scope 不精确必须只返回结构化拒绝原因'
Assert-True (-not [IO.Directory]::Exists($refusalEvidenceRoot)) 'scope 不精确不得创建 evidence/temp/backup'

[byte[]]$firstTargetBeforeBytes = [IO.File]::ReadAllBytes($firstTargetPath)
[IO.File]::WriteAllText($firstTargetPath, 'live-target-drift', [Text.UTF8Encoding]::new($false))
$liveDriftError = Assert-Throws -Message 'live target hash 漂移必须在任何 evidence/live 写入前拒绝' -Action {
    & $invokeScript `
        -PlanPath $publishedPlan.jsonPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $evidenceRoot `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($liveDriftError -match 'action contract|target|live|before') 'live drift 必须输出脱敏 final-gate 原因'
Assert-True ([IO.File]::ReadAllText($firstTargetPath) -ceq 'live-target-drift') 'live drift gate 不得覆盖漂移 target'
Assert-True (-not [IO.Directory]::Exists($evidenceRoot)) 'live drift final gate 失败不得创建 evidence'
[IO.File]::WriteAllBytes($firstTargetPath, $firstTargetBeforeBytes)

$realHooksRoot = Join-Path $fixtureRoot 'fixture-hooks-real'
[IO.Directory]::Move($fixtureHooksRoot, $realHooksRoot)
New-Item -ItemType Junction -Path $fixtureHooksRoot -Target $realHooksRoot | Out-Null
try {
    $targetJunctionError = Assert-Throws -Message 'target parent junction 必须在 gate 阶段拒绝' -Action {
        & $invokeScript `
            -PlanPath $publishedPlan.jsonPath `
            -Apply `
            -ApprovedScope 'codex-hook-governance-2026-07-11' `
            -EvidenceRoot $evidenceRoot `
            -EnvironmentReadValue $readEnvironment `
            -EnvironmentWriteValue $writeEnvironment |
            Out-Null
    }
    Assert-True ($targetJunctionError -match 'reparse') 'target junction 必须输出脱敏 reparse reason'
    Assert-True (-not [IO.Directory]::Exists($evidenceRoot)) 'target junction gate 失败不得创建 evidence'
} finally {
    Remove-Item -LiteralPath $fixtureHooksRoot -Force
    [IO.Directory]::Move($realHooksRoot, $fixtureHooksRoot)
}

$tamperedPlanPath = Join-Path $fixtureRoot 'tampered-plan.json'
$tamperedPlan = Copy-CodexHookJsonValue -Value $plan
$tamperedPlan.sourceFacts | Add-Member -NotePropertyName secret -NotePropertyValue 'fixture-secret'
Write-Utf8NoBom -Path $tamperedPlanPath -Text ($tamperedPlan | ConvertTo-Json -Depth 100)
$tamperedPlanError = Assert-Throws -Message 'plan nested unknown field 必须严格拒绝' -Action {
    & $invokeScript `
        -PlanPath $tamperedPlanPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $evidenceRoot `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($tamperedPlanError -notmatch 'fixture-secret') 'nested plan 拒绝错误不得回显 secret sentinel'

$junctionEvidenceTarget = Join-Path $fixtureRoot 'junction-evidence-target'
$junctionEvidenceRoot = Join-Path $fixtureRoot 'junction-evidence-root'
[void][IO.Directory]::CreateDirectory($junctionEvidenceTarget)
New-Item -ItemType Junction -Path $junctionEvidenceRoot -Target $junctionEvidenceTarget | Out-Null
try {
    $junctionEvidenceError = Assert-Throws -Message 'EvidenceRoot junction 必须在任何 evidence/live 写入前拒绝' -Action {
        & $invokeScript `
            -PlanPath $publishedPlan.jsonPath `
            -Apply `
            -ApprovedScope 'codex-hook-governance-2026-07-11' `
            -EvidenceRoot $junctionEvidenceRoot `
            -EnvironmentReadValue $readEnvironment `
            -EnvironmentWriteValue $writeEnvironment |
            Out-Null
    }
    Assert-True ($junctionEvidenceError -match 'reparse') 'EvidenceRoot junction 必须输出脱敏 reparse reason'
    Assert-True (@(Get-ChildItem -LiteralPath $junctionEvidenceTarget -Force).Count -eq 0) 'EvidenceRoot junction 拒绝后 target directory 必须零写入'
} finally {
    Remove-Item -LiteralPath $junctionEvidenceRoot -Force
}
$rollbackFailure = Assert-Throws -Message 'implementation 后 wrapper 故障必须触发自动回滚' -Action {
    & $invokeScript `
        -PlanPath $publishedPlan.jsonPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $evidenceRoot `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment `
        -FaultInjection 'before-wrapper' |
        Out-Null
}
Assert-True ($rollbackFailure -match 'fault|故障|injection') '故障注入必须返回脱敏失败原因'
$evidenceDirectories = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory -ErrorAction SilentlyContinue | Where-Object Name -like 'deployment-*')
Assert-True ($evidenceDirectories.Count -eq 1) '中途故障必须留下单个 evidence directory'
$failureStatus = Get-Content -LiteralPath (Join-Path $evidenceDirectories[0].FullName 'status.json') -Raw | ConvertFrom-Json -Depth 30
Assert-True ($failureStatus.status -ceq 'rolled-back') '中途故障 evidence 必须标记 rolled-back'
Assert-True (@($failureStatus.completedActionIds | Where-Object { $_ -like 'file:*' }).Count -gt 0) '故障注入前必须确有 implementation action 发布'
Assert-True ([IO.File]::Exists((Join-Path $evidenceDirectories[0].FullName 'restore-manifest.json'))) '中途故障必须留下 restore manifest'
foreach ($targetPath in $expectedOldFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedOldFileBytes[$targetPath])) '中途故障后全部 live file 必须反序恢复'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq (Get-ByteSha256 -Bytes $registryBeforeBytes)) '中途故障后 registry 必须恢复'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Fixture\serena-before') '中途故障后 environment 必须恢复'

$publishedPlan2 = & $newPlanScript `
    -ManifestPath $fixtureManifestPath `
    -FixtureSourceRoot $fixtureSourceRoot `
    -FixtureCodexHome $fixtureCodexHome `
    -Mode full `
    -OutputDir $planOutput `
    -EnvironmentReadValue $readEnvironment
$registryFault = Assert-Throws -Message 'registry postcheck 故障必须回滚 wrapper、environment 与 registry' -Action {
    & $invokeScript `
        -PlanPath $publishedPlan2.jsonPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $evidenceRoot `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment `
        -FaultInjection 'registry-postcheck' |
        Out-Null
}
Assert-True ($registryFault -match 'fault|故障|injection') 'registry postcheck fault 必须返回脱敏错误'
$registryFaultEvidence = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory | Where-Object Name -like 'deployment-*' | Sort-Object LastWriteTimeUtc)[-1]
$registryFaultStatus = Get-Content -LiteralPath (Join-Path $registryFaultEvidence.FullName 'status.json') -Raw | ConvertFrom-Json -Depth 30
Assert-True ($registryFaultStatus.status -ceq 'rolled-back') 'registry postcheck fault 必须标记 rolled-back'
Assert-True (@($registryFaultStatus.completedActionIds | Where-Object { $_ -like 'file:*.cmd' }).Count -gt 0) 'registry postcheck fault 前 wrapper 必须确已发布'
foreach ($targetPath in $expectedOldFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedOldFileBytes[$targetPath])) 'registry postcheck 故障后全部 file 必须恢复'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq (Get-ByteSha256 -Bytes $registryBeforeBytes)) 'registry postcheck 故障后 registry 必须恢复原 bytes'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Fixture\serena-before') 'registry postcheck 故障后 environment 必须恢复'

$publishedPlan3 = & $newPlanScript `
    -ManifestPath $fixtureManifestPath `
    -FixtureSourceRoot $fixtureSourceRoot `
    -FixtureCodexHome $fixtureCodexHome `
    -Mode full `
    -OutputDir $planOutput `
    -EnvironmentReadValue $readEnvironment
$plan3 = Get-Content -LiteralPath $publishedPlan3.jsonPath -Raw | ConvertFrom-Json -Depth 100
$applyResult = & $invokeScript `
    -PlanPath $publishedPlan3.jsonPath `
    -Apply `
    -ApprovedScope 'codex-hook-governance-2026-07-11' `
    -EvidenceRoot $evidenceRoot `
    -EnvironmentReadValue $readEnvironment `
    -EnvironmentWriteValue $writeEnvironment
Assert-True ($applyResult.applied) '无漂移 full fixture 必须 apply 成功'
$plan3LifecyclePaths = Get-CodexHookFixtureLifecyclePaths `
    -MappingIdentity ([string]$plan3.sourceFacts.mappingIdentity) `
    -GenerationId ([string]$plan3.generationId)
Assert-True ([IO.File]::Exists([string]$plan3LifecyclePaths.claimPath)) 'generation claim 必须写入固定 mapping-scoped lifecycle 根'
Assert-True (-not [IO.Directory]::Exists((Join-Path $evidenceRoot '.claims'))) '调用者 EvidenceRoot 内不得保存 replay claim'
$plan3Claim = Get-Content -LiteralPath ([string]$plan3LifecyclePaths.claimPath) -Raw | ConvertFrom-Json -Depth 20
Assert-True ($plan3Claim.state -ceq 'prepared' -and $plan3Claim.mappingIdentity -ceq $plan3.sourceFacts.mappingIdentity) 'claim lifecycle 必须从 reserved 进入 prepared 并绑定 mapping identity'
foreach ($targetPath in $expectedNewFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedNewFileBytes[$targetPath])) 'apply 后 file 必须等于 gated source bytes'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq $plan3.registryAfterSha256) 'apply 后 registry 必须等于 deterministic after hash'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Codex\.serena') 'full apply 必须只通过内存 adapter 设置 SERENA_HOME'

$mappingMutexName = Get-CodexHookFixtureDeploymentMutexName -MappingIdentity ([string]$plan3.sourceFacts.mappingIdentity)
$heldMappingMutex = [Threading.Mutex]::new($false, $mappingMutexName)
$heldMappingMutexAcquired = $false
try {
    $heldMappingMutexAcquired = $heldMappingMutex.WaitOne(0)
    Assert-True $heldMappingMutexAcquired '测试进程必须先占有 mapping lifecycle mutex'
    $restoreWhileApplyStdout = Join-Path $fixtureRoot 'restore-while-apply.stdout.txt'
    $restoreWhileApplyStderr = Join-Path $fixtureRoot 'restore-while-apply.stderr.txt'
    $restoreWhileApplyProcess = Start-Process `
        -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
        -ArgumentList @('-NoProfile', '-File', $restoreScript, '-EvidenceDirectory', $applyResult.evidenceDirectory, '-Apply') `
        -RedirectStandardOutput $restoreWhileApplyStdout `
        -RedirectStandardError $restoreWhileApplyStderr `
        -WindowStyle Hidden `
        -PassThru
    Assert-True ($restoreWhileApplyProcess.WaitForExit(120000)) '锁占用期间 restore 子进程必须在 120 秒内退出'
    Assert-True ($restoreWhileApplyProcess.ExitCode -ne 0) 'restore 不得与持有同 mapping mutex 的 apply 生命周期并发'
    $restoreWhileApplyError = [IO.File]::ReadAllText($restoreWhileApplyStderr)
    Assert-True ($restoreWhileApplyError -match 'mutex busy') '并发 restore 必须由同一 mapping mutex 明确拒绝'
    foreach ($targetPath in $expectedNewFileBytes.Keys) {
        Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedNewFileBytes[$targetPath])) 'mutex 拒绝后 deployed file 不得出现混合状态'
    }
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq $plan3.registryAfterSha256) 'mutex 拒绝后 registry 必须仍为 deployed 状态'
    Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Codex\.serena') 'mutex 拒绝后 environment 必须仍为 deployed 状态'
} finally {
    if ($heldMappingMutexAcquired) { [void]$heldMappingMutex.ReleaseMutex() }
    $heldMappingMutex.Dispose()
}

$restoreResult = & $restoreScript `
    -EvidenceDirectory $applyResult.evidenceDirectory `
    -Apply `
    -EnvironmentReadValue $readEnvironment `
    -EnvironmentWriteValue $writeEnvironment
Assert-True ($restoreResult.restored -and -not $restoreResult.idempotent) '首次 restore 必须执行反序恢复'
foreach ($targetPath in $expectedOldFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedOldFileBytes[$targetPath])) 'restore 后 file 必须恢复原 bytes'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq (Get-ByteSha256 -Bytes $registryBeforeBytes)) 'restore 后 registry 必须字节级恢复'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Fixture\serena-before') 'restore 后 environment 必须恢复 before 值'
$restoreAgain = & $restoreScript `
    -EvidenceDirectory $applyResult.evidenceDirectory `
    -Apply `
    -EnvironmentReadValue $readEnvironment `
    -EnvironmentWriteValue $writeEnvironment
Assert-True ($restoreAgain.restored -and $restoreAgain.idempotent) 'restore 重复执行必须幂等'

$replayError = Assert-Throws -Message '已 claim generationId 的旧 plan 在 rollback 后不得重放' -Action {
    & $invokeScript `
        -PlanPath $publishedPlan3.jsonPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $evidenceRoot `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($replayError -match 'claim|重放|generationId') '旧 plan 重放必须由 generation claim 拒绝'

$alternateEvidenceRoot = Join-Path $fixtureRoot 'alternate-evidence'
$crossEvidenceReplayError = Assert-Throws -Message '换用另一个合法 EvidenceRoot 也不得重放同 generationId' -Action {
    & $invokeScript `
        -PlanPath $publishedPlan3.jsonPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $alternateEvidenceRoot `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($crossEvidenceReplayError -match 'mapping-scoped claim|重放|generationId') '跨 EvidenceRoot 重放必须由固定 mapping claim 拒绝'
Assert-True (-not [IO.Directory]::Exists($alternateEvidenceRoot)) '跨 EvidenceRoot 重放拒绝前不得创建调用者 evidence 根'

$publishedPlan4 = & $newPlanScript `
    -ManifestPath $fixtureManifestPath `
    -FixtureSourceRoot $fixtureSourceRoot `
    -FixtureCodexHome $fixtureCodexHome `
    -Mode full `
    -OutputDir $planOutput `
    -EnvironmentReadValue $readEnvironment
$plan4 = Get-Content -LiteralPath $publishedPlan4.jsonPath -Raw | ConvertFrom-Json -Depth 100
$apply4 = & $invokeScript `
    -PlanPath $publishedPlan4.jsonPath `
    -Apply `
    -ApprovedScope 'codex-hook-governance-2026-07-11' `
    -EvidenceRoot $evidenceRoot `
    -EnvironmentReadValue $readEnvironment `
    -EnvironmentWriteValue $writeEnvironment
$restoreManifestPath = Join-Path $apply4.evidenceDirectory 'restore-manifest.json'
[byte[]]$restoreManifestBytes = [IO.File]::ReadAllBytes($restoreManifestPath)
$pathTraversalRestore = [Text.UTF8Encoding]::new($false).GetString($restoreManifestBytes) | ConvertFrom-Json -Depth 100
$pathTraversalRestore.generationId = '..\..\claim-path-traversal-sentinel'
$pathTraversalEscapePath = Join-Path $fixtureRoot 'claim-path-traversal-sentinel.json'
Assert-True (-not [IO.File]::Exists($pathTraversalEscapePath)) 'path traversal sentinel 必须预先不存在'
Write-Utf8NoBom -Path $restoreManifestPath -Text ($pathTraversalRestore | ConvertTo-Json -Depth 100)
$pathTraversalRestoreError = Assert-Throws -Message 'restore generationId path traversal 必须在 claim path 构造前拒绝' -Action {
    & $restoreScript `
        -EvidenceDirectory $apply4.evidenceDirectory `
        -Apply `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($pathTraversalRestoreError -match 'generationId|非法') '恶意 restore generationId 必须输出脱敏字段验证原因'
Assert-True (-not [IO.File]::Exists($pathTraversalEscapePath)) '恶意 generationId 不得在固定 claim root 外创建文件'
foreach ($targetPath in $expectedNewFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedNewFileBytes[$targetPath])) '恶意 generationId 拒绝后 deployed file 必须不变'
}
[IO.File]::WriteAllBytes($restoreManifestPath, $restoreManifestBytes)

$tamperedRestore = [Text.UTF8Encoding]::new($false).GetString($restoreManifestBytes) | ConvertFrom-Json -Depth 100
$tamperedRestore | Add-Member -NotePropertyName secret -NotePropertyValue 'fixture-secret'
Write-Utf8NoBom -Path $restoreManifestPath -Text ($tamperedRestore | ConvertTo-Json -Depth 100)
$restoreManifestTamperError = Assert-Throws -Message 'restore manifest 篡改必须全量预检零写拒绝' -Action {
    & $restoreScript `
        -EvidenceDirectory $apply4.evidenceDirectory `
        -Apply `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($restoreManifestTamperError -notmatch 'fixture-secret') 'restore manifest 篡改错误不得回显 secret sentinel'
foreach ($targetPath in $expectedNewFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedNewFileBytes[$targetPath])) 'restore manifest 篡改预检失败后 deployed file 必须不变'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq $plan4.registryAfterSha256) 'restore manifest 篡改预检失败后 registry 必须不变'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Codex\.serena') 'restore manifest 篡改预检失败后 environment 必须不变'
[IO.File]::WriteAllBytes($restoreManifestPath, $restoreManifestBytes)

$backupPath = @(Get-ChildItem -LiteralPath (Join-Path $apply4.evidenceDirectory 'backups') -File -Filter '*.bin' | Sort-Object Name)[0].FullName
[byte[]]$backupBytes = [IO.File]::ReadAllBytes($backupPath)
[byte[]]$tamperedBackupBytes = [byte[]]$backupBytes.Clone()
$tamperedBackupBytes[0] = $tamperedBackupBytes[0] -bxor 0xff
[IO.File]::WriteAllBytes($backupPath, $tamperedBackupBytes)
$backupTamperError = Assert-Throws -Message 'backup 篡改必须在任何 restore 写入前拒绝' -Action {
    & $restoreScript `
        -EvidenceDirectory $apply4.evidenceDirectory `
        -Apply `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($backupTamperError -match 'backup|SHA') 'backup 篡改必须输出脱敏 hash 原因'
foreach ($targetPath in $expectedNewFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedNewFileBytes[$targetPath])) 'backup 篡改预检失败后 deployed file 必须不变'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq $plan4.registryAfterSha256) 'backup 篡改预检失败后 registry 必须不变'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Codex\.serena') 'backup 篡改预检失败后 environment 必须不变'
[IO.File]::WriteAllBytes($backupPath, $backupBytes)

$strictStatusPath = Join-Path $apply4.evidenceDirectory 'status.json'
[byte[]]$strictStatusBytes = [IO.File]::ReadAllBytes($strictStatusPath)
$tamperedStatus = [Text.UTF8Encoding]::new($false).GetString($strictStatusBytes) | ConvertFrom-Json -Depth 30
$tamperedStatus | Add-Member -NotePropertyName secret -NotePropertyValue 'fixture-secret'
Write-Utf8NoBom -Path $strictStatusPath -Text ($tamperedStatus | ConvertTo-Json -Depth 30)
$statusTamperError = Assert-Throws -Message 'status.json 篡改必须在任何 restore 写入前拒绝' -Action {
    & $restoreScript `
        -EvidenceDirectory $apply4.evidenceDirectory `
        -Apply `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $writeEnvironment |
        Out-Null
}
Assert-True ($statusTamperError -notmatch 'fixture-secret') 'status 篡改错误不得回显 secret sentinel'
foreach ($targetPath in $expectedNewFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedNewFileBytes[$targetPath])) 'status 篡改预检失败后 deployed file 必须不变'
}
Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($fixtureRegistryPath))) -ceq $plan4.registryAfterSha256) 'status 篡改预检失败后 registry 必须不变'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Codex\.serena') 'status 篡改预检失败后 environment 必须不变'
[IO.File]::WriteAllBytes($strictStatusPath, $strictStatusBytes)

$restore4 = & $restoreScript `
    -EvidenceDirectory $apply4.evidenceDirectory `
    -Apply `
    -EnvironmentReadValue $readEnvironment `
    -EnvironmentWriteValue $writeEnvironment
Assert-True ($restore4.restored) '恢复未篡改 evidence 后 restore 必须成功'

$environmentPostcheckPlan = & $newPlanScript `
    -ManifestPath $fixtureManifestPath `
    -FixtureSourceRoot $fixtureSourceRoot `
    -FixtureCodexHome $fixtureCodexHome `
    -Mode full `
    -OutputDir $planOutput `
    -EnvironmentReadValue $readEnvironment
$environmentPostcheckApply = & $invokeScript `
    -PlanPath $environmentPostcheckPlan.jsonPath `
    -Apply `
    -ApprovedScope 'codex-hook-governance-2026-07-11' `
    -EvidenceRoot $evidenceRoot `
    -EnvironmentReadValue $readEnvironment `
    -EnvironmentWriteValue $writeEnvironment
$wrongEnvironmentWriter = {
    param($Name, $Scope, $Value)
    $environmentStore["$Scope|$Name"] = 'D:\Fixture\wrong-restore-value'
}.GetNewClosure()
$wrongEnvironmentRestoreError = Assert-Throws -Message '写入错误 environment before 值的 adapter 必须由 postcheck 拒绝' -Action {
    & $restoreScript `
        -EvidenceDirectory $environmentPostcheckApply.evidenceDirectory `
        -Apply `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $wrongEnvironmentWriter |
        Out-Null
}
Assert-True ($wrongEnvironmentRestoreError -match 'environment restore postcheck') '错误 environment restore 值必须明确 postcheck 失败'
$environmentFailureStatusPath = Join-Path $environmentPostcheckApply.evidenceDirectory 'status.json'
$environmentFailureStatus = Get-Content -LiteralPath $environmentFailureStatusPath -Raw | ConvertFrom-Json -Depth 30
Assert-True ($environmentFailureStatus.status -ceq 'applied') 'environment postcheck 失败后不得宣称 restored'

$environmentStore['User|SERENA_HOME'] = 'D:\Codex\.serena'
$noopEnvironmentWriter = { param($Name, $Scope, $Value) }.GetNewClosure()
$noopEnvironmentRestoreError = Assert-Throws -Message 'silent no-op environment adapter 必须由 postcheck 拒绝' -Action {
    & $restoreScript `
        -EvidenceDirectory $environmentPostcheckApply.evidenceDirectory `
        -Apply `
        -EnvironmentReadValue $readEnvironment `
        -EnvironmentWriteValue $noopEnvironmentWriter |
        Out-Null
}
Assert-True ($noopEnvironmentRestoreError -match 'environment restore postcheck') 'silent no-op environment restore 必须明确 postcheck 失败'
$noopFailureStatus = Get-Content -LiteralPath $environmentFailureStatusPath -Raw | ConvertFrom-Json -Depth 30
Assert-True ($noopFailureStatus.status -ceq 'applied') 'silent no-op postcheck 失败后不得宣称 restored'

$environmentPostcheckRestore = & $restoreScript `
    -EvidenceDirectory $environmentPostcheckApply.evidenceDirectory `
    -Apply `
    -EnvironmentReadValue $readEnvironment `
    -EnvironmentWriteValue $writeEnvironment
Assert-True ($environmentPostcheckRestore.restored) 'postcheck 失败后使用正确 adapter 必须可继续恢复'
Assert-True ($environmentStore['User|SERENA_HOME'] -ceq 'D:\Fixture\serena-before') '正确 adapter 必须恢复 environment before 值'
foreach ($targetPath in $expectedOldFileBytes.Keys) {
    Assert-True ((Get-ByteSha256 -Bytes ([IO.File]::ReadAllBytes($targetPath))) -ceq (Get-ByteSha256 -Bytes $expectedOldFileBytes[$targetPath])) 'environment postcheck 恢复重试后 file 必须回到 before 状态'
}

$absentFact = Get-CodexHookEnvironmentValueFact `
    -Name 'SERENA_HOME' `
    -Scope 'User' `
    -ReadValue { param($Name, $Scope) [pscustomobject]@{ present = $false; value = $null } } `
    -Desired 'D:\Codex\.serena'
$emptyFact = Get-CodexHookEnvironmentValueFact `
    -Name 'SERENA_HOME' `
    -Scope 'User' `
    -ReadValue { param($Name, $Scope) [pscustomobject]@{ present = $true; value = '' } } `
    -Desired 'D:\Codex\.serena'
Assert-True ($absentFact.valueSha256 -cne $emptyFact.valueSha256) 'environment freshness 必须精确区分 absent 与 empty'

$registrationPlanOutput = Join-Path $fixtureRoot 'registration-plan'
$registrationPlanPublished = & $newPlanScript `
    -ManifestPath $fixtureManifestPath `
    -FixtureSourceRoot $fixtureSourceRoot `
    -FixtureCodexHome $fixtureCodexHome `
    -Mode registration-repair `
    -OutputDir $registrationPlanOutput
$registrationPlan = Get-Content -LiteralPath $registrationPlanPublished.jsonPath -Raw | ConvertFrom-Json -Depth 100
Assert-True ($registrationPlan.applyEligible) 'registration-repair fixture plan 必须可 apply'
Assert-True (@($registrationPlan.actions).Count -eq 1 -and $registrationPlan.actions[0].kind -ceq 'registry') 'registration-repair 只能声明 registry action'
Assert-True (@($registrationPlan.environmentActions).Count -eq 0) 'registration-repair 不得声明 environment action'

$stalePlan = Copy-CodexHookJsonValue -Value $registrationPlan
$stalePlan.generatedAtUtc = [datetimeoffset]::UtcNow.AddHours(-2).ToString('o')
$stalePlanPath = Join-Path $fixtureRoot 'stale-plan.json'
Write-Utf8NoBom -Path $stalePlanPath -Text ($stalePlan | ConvertTo-Json -Depth 100)
$staleEvidence = Join-Path $fixtureRoot 'stale-evidence'
$staleError = Assert-Throws -Message '超过一小时的 plan 必须在 evidence 创建前拒绝' -Action {
    & $invokeScript `
        -PlanPath $stalePlanPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $staleEvidence |
        Out-Null
}
Assert-True ($staleError -match '过期|未来') 'stale plan 必须给出 freshness reason'
Assert-True (-not [IO.Directory]::Exists($staleEvidence)) 'stale plan 不得创建 evidence'

[byte[]]$fixtureManifestOriginalBytes = [IO.File]::ReadAllBytes($fixtureManifestPath)
[IO.File]::WriteAllBytes($fixtureManifestPath, [byte[]](@(32) + $fixtureManifestOriginalBytes))
$manifestDriftEvidence = Join-Path $fixtureRoot 'manifest-drift-evidence'
$manifestDriftError = Assert-Throws -Message 'manifest hash 漂移必须在 evidence 创建前拒绝' -Action {
    & $invokeScript `
        -PlanPath $registrationPlanPublished.jsonPath `
        -Apply `
        -ApprovedScope 'codex-hook-governance-2026-07-11' `
        -EvidenceRoot $manifestDriftEvidence |
        Out-Null
}
Assert-True ($manifestDriftError -match 'manifest|SHA') 'manifest drift 必须输出脱敏 hash reason'
Assert-True (-not [IO.Directory]::Exists($manifestDriftEvidence)) 'manifest drift 不得创建 evidence'
[IO.File]::WriteAllBytes($fixtureManifestPath, $fixtureManifestOriginalBytes)

$concurrentEvidence = Join-Path $fixtureRoot 'concurrent-evidence'
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
for ($processIndex = 0; $processIndex -lt 2; $processIndex++) {
    $stdoutPath = Join-Path $fixtureRoot "concurrent-$processIndex.stdout.txt"
    $stderrPath = Join-Path $fixtureRoot "concurrent-$processIndex.stderr.txt"
    $processes.Add((Start-Process `
        -FilePath 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' `
        -ArgumentList @(
            '-NoProfile', '-File', $invokeScript,
            '-PlanPath', $registrationPlanPublished.jsonPath,
            '-Apply',
            '-ApprovedScope', 'codex-hook-governance-2026-07-11',
            '-EvidenceRoot', $concurrentEvidence
        ) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru))
}
foreach ($process in $processes) {
    Assert-True ($process.WaitForExit(120000)) '并发 apply 子进程必须在 120 秒内退出'
}
$successfulProcesses = @($processes | Where-Object ExitCode -eq 0)
Assert-True ($successfulProcesses.Count -eq 1) '同 generationId 双进程 apply 必须恰有一个成功'
$concurrentEvidenceDirectory = @(Get-ChildItem -LiteralPath $concurrentEvidence -Directory | Where-Object Name -like 'deployment-*')
Assert-True ($concurrentEvidenceDirectory.Count -eq 1) '双进程 apply 只能生成一个 deployment evidence'
$concurrentRestore = & $restoreScript -EvidenceDirectory $concurrentEvidenceDirectory[0].FullName -Apply
Assert-True ($concurrentRestore.restored) '双进程胜者的 registration repair 必须可恢复'

Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('SERENA_HOME', 'User'), $realSerenaHomeBefore, [StringComparison]::Ordinal)) 'fixture suite 绝不得写真实 User SERENA_HOME'

[pscustomobject]@{
    ok = $true
    suite = 'CodexHookDeployment'
}
