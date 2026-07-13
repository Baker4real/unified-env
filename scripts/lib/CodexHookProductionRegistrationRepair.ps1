Set-StrictMode -Version Latest

function Get-CodexHookProductionRegistrationRepairFrozenFileMappings {
    [CmdletBinding()]
    param()

    return [object[]]@(
        [pscustomobject]@{ liveRelativePath='codex-github-cli-guard.cmd'; sourceRelativePath='hooks/codex-github-cli-guard.cmd' },
        [pscustomobject]@{ liveRelativePath='codex-github-cli-guard.ps1'; sourceRelativePath='hooks/codex-github-cli-guard.ps1' },
        [pscustomobject]@{ liveRelativePath='codex-mobile-permission-guard.cmd'; sourceRelativePath='retired/codex-mobile-permission-guard.cmd' },
        [pscustomobject]@{ liveRelativePath='codex-mobile-permission-guard.py'; sourceRelativePath='retired/codex-mobile-permission-guard.py' },
        [pscustomobject]@{ liveRelativePath='codex-projectless-root-d.cmd'; sourceRelativePath='hooks/codex-projectless-root-d.cmd' },
        [pscustomobject]@{ liveRelativePath='codex-projectless-root-d.js'; sourceRelativePath='retired/codex-projectless-root-d.js' },
        [pscustomobject]@{ liveRelativePath='codex-provider-stability-guard.cmd'; sourceRelativePath='hooks/codex-provider-stability-guard.cmd' },
        [pscustomobject]@{ liveRelativePath='codex-provider-stability-guard.ps1'; sourceRelativePath='hooks/codex-provider-stability-guard.ps1' },
        [pscustomobject]@{ liveRelativePath='serena-activate-guarded.cmd'; sourceRelativePath='hooks/serena-activate-guarded.cmd' },
        [pscustomobject]@{ liveRelativePath='serena-activate-guarded.ps1'; sourceRelativePath='hooks/serena-activate-guarded.ps1' },
        [pscustomobject]@{ liveRelativePath='serena-dashboard-guard.cmd'; sourceRelativePath='hooks/serena-dashboard-guard.cmd' },
        [pscustomobject]@{ liveRelativePath='serena-dashboard-guard.ps1'; sourceRelativePath='hooks/serena-dashboard-guard.ps1' }
    )
}

function Get-CodexHookProductionRegistrationRepairFrozenRelativePaths {
    [CmdletBinding()]
    param()
    return [string[]]@(Get-CodexHookProductionRegistrationRepairFrozenFileMappings | ForEach-Object { [string]$_.sourceRelativePath })
}

function Get-CodexHookProductionRegistrationRepairFrozenLiveRelativePaths {
    [CmdletBinding()]
    param()

    return [string[]]@(Get-CodexHookProductionRegistrationRepairFrozenFileMappings | ForEach-Object { [string]$_.liveRelativePath })
}

function Select-CodexHookProductionRegistrationRepairFiles {
    param([Parameter(Mandatory)][object]$Manifest)

    $byLiveRelativePath = @{}
    foreach ($file in @($Manifest.files)) {
        $key = ([string]$file.liveRelativePath).Replace('\', '/').ToLowerInvariant()
        if ($byLiveRelativePath.ContainsKey($key)) { throw 'production manifest 存在重复 liveRelativePath。' }
        $byLiveRelativePath[$key] = $file
    }
    $selected = [Collections.Generic.List[object]]::new()
    foreach ($mapping in Get-CodexHookProductionRegistrationRepairFrozenFileMappings) {
        $key = ([string]$mapping.liveRelativePath).ToLowerInvariant()
        if (-not $byLiveRelativePath.ContainsKey($key)) { throw "production registration-repair 缺少冻结 live 文件：$($mapping.liveRelativePath)" }
        $file = $byLiveRelativePath[$key]
        if ([string]$file.relativePath -cne [string]$mapping.sourceRelativePath) {
            throw "production registration-repair 冻结 source/live 映射非法：$($mapping.liveRelativePath)"
        }
        if ($file.lifecycle -cnotin @('active', 'compatibility', 'retired')) { throw "production registration-repair 冻结文件生命周期非法：$($mapping.liveRelativePath)" }
        $selected.Add($file)
    }
    return [object[]]$selected.ToArray()
}

function Get-CodexHookProductionRegistrationRepairProfile {
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        profileId = 'codex-hook-production-registration-repair-v1'
        mode = 'registration-repair'
        manifestPath = 'D:\Codex\projects\统一环境\managed\codex-hooks\manifest.json'
        sourceRoot = 'D:\Codex\projects\统一环境\managed\codex-hooks'
        codexHome = 'D:\Codex\.codex'
        hooksRoot = 'D:\Codex\.codex\hooks'
        registryPath = 'D:\Codex\.codex\hooks.json'
        planOutputDir = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan'
        planPath = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan\plan.json'
        evidenceRoot = 'D:\Codex\.codex\run-evidence\env-governance'
        mutexName = 'Local\CodexHookProductionRegistrationRepairV1'
        isFixtureAdapter = $false
    }
}

function Get-CodexHookProductionRegistrationRepairFixtureProfile {
    [CmdletBinding()]
    param()

    $root = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test\production-registration-repair'
    return [pscustomobject][ordered]@{
        profileId = 'codex-hook-production-registration-repair-v1'
        mode = 'registration-repair'
        manifestPath = Join-Path $root 'managed\manifest.json'
        sourceRoot = Join-Path $root 'managed'
        codexHome = Join-Path $root 'live'
        hooksRoot = Join-Path $root 'live\hooks'
        registryPath = Join-Path $root 'live\hooks.json'
        planOutputDir = Join-Path $root 'plan'
        planPath = Join-Path $root 'plan\plan.json'
        evidenceRoot = Join-Path $root 'evidence'
        mutexName = 'Local\CodexHookProductionRegistrationRepairFixtureV1'
        isFixtureAdapter = $true
    }
}

function Assert-CodexHookProductionRegistrationRepairProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Profile,
        [switch]$AllowFixtureAdapter
    )

    Assert-CodexHookExactProperties -Value $Profile -Names @(
        'profileId', 'mode', 'manifestPath', 'sourceRoot', 'codexHome', 'hooksRoot',
        'registryPath', 'planOutputDir', 'planPath', 'evidenceRoot', 'mutexName',
        'isFixtureAdapter'
    ) -Scope 'production registration-repair profile'
    if (
        $Profile.profileId -cne 'codex-hook-production-registration-repair-v1' -or
        $Profile.mode -cne 'registration-repair'
    ) {
        throw 'production registration-repair profile identity 非法。'
    }
    if ($Profile.isFixtureAdapter -isnot [bool]) {
        throw 'production registration-repair profile adapter flag 非法。'
    }
    foreach ($name in @(
        'manifestPath', 'sourceRoot', 'codexHome', 'hooksRoot', 'registryPath',
        'planOutputDir', 'planPath', 'evidenceRoot'
    )) {
        [void](Assert-CodexHookDPath -Value ([string]$Profile.$name) -Name "production profile $name")
    }
    if ([IO.Path]::GetFullPath([string]$Profile.hooksRoot) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Profile.codexHome) 'hooks'))) {
        throw 'production profile hooksRoot 映射非法。'
    }
    if ([IO.Path]::GetFullPath([string]$Profile.registryPath) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Profile.codexHome) 'hooks.json'))) {
        throw 'production profile registryPath 映射非法。'
    }
    if ([IO.Path]::GetFullPath([string]$Profile.manifestPath) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Profile.sourceRoot) 'manifest.json'))) {
        throw 'production profile manifestPath 映射非法。'
    }
    if ([IO.Path]::GetFullPath([string]$Profile.planPath) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Profile.planOutputDir) 'plan.json'))) {
        throw 'production profile planPath 映射非法。'
    }

    if ($Profile.isFixtureAdapter) {
        if (-not $AllowFixtureAdapter) {
            throw 'production entrypoint 不接受 fixture adapter。'
        }
        $fixtureRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test'
        foreach ($name in @(
            'manifestPath', 'sourceRoot', 'codexHome', 'hooksRoot', 'registryPath',
            'planOutputDir', 'planPath', 'evidenceRoot'
        )) {
            [void](Assert-CodexHookFixturePath -Path ([string]$Profile.$name) -Name "production fixture profile $name")
        }
        if ($Profile.mutexName -cne 'Local\CodexHookProductionRegistrationRepairFixtureV1') {
            throw 'production fixture mutex 非法。'
        }
    } else {
        $fixed = Get-CodexHookProductionRegistrationRepairProfile
        foreach ($name in @(
            'profileId', 'mode', 'manifestPath', 'sourceRoot', 'codexHome', 'hooksRoot',
            'registryPath', 'planOutputDir', 'planPath', 'evidenceRoot', 'mutexName'
        )) {
            if ([string]$Profile.$name -cne [string]$fixed.$name) {
                throw "production profile 固定字段被覆盖：$name"
            }
        }
    }
    return $Profile
}

function Get-CodexHookProductionRegistrationRepairMappingIdentity {
    param([Parameter(Mandatory)][object]$Profile)

    [void](Assert-CodexHookProductionRegistrationRepairProfile -Profile $Profile -AllowFixtureAdapter)
    $fields = @(
        [string]$Profile.profileId,
        [IO.Path]::GetFullPath([string]$Profile.manifestPath).ToLowerInvariant(),
        [IO.Path]::GetFullPath([string]$Profile.sourceRoot).ToLowerInvariant(),
        [IO.Path]::GetFullPath([string]$Profile.codexHome).ToLowerInvariant(),
        [IO.Path]::GetFullPath([string]$Profile.registryPath).ToLowerInvariant(),
        [IO.Path]::GetFullPath([string]$Profile.evidenceRoot).ToLowerInvariant()
    )
    return Get-CodexHookTextSha256 -Text ($fields -join "`0")
}

function ConvertFrom-CodexHookProductionJsonSnapshot {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Snapshot.exists -or $Snapshot.state -cne 'regular-file') {
        throw "$Name 必须是普通文件。"
    }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$Snapshot.bytes)
    } catch {
        throw "$Name 不是严格 UTF-8。"
    }
    Assert-CodexHookStrictJsonText -JsonText $text
    return ($text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop)
}

function Assert-CodexHookProductionManifestBinding {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Profile
    )

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    $bindingProfile = if ($Profile.isFixtureAdapter) {
        Get-CodexHookProductionRegistrationRepairProfile
    } else {
        $Profile
    }
    if (
        [IO.Path]::GetFullPath([string]$Manifest.managedRoot) -ine [IO.Path]::GetFullPath([string]$bindingProfile.sourceRoot) -or
        [IO.Path]::GetFullPath([string]$Manifest.codexHome) -ine [IO.Path]::GetFullPath([string]$bindingProfile.codexHome)
    ) {
        throw 'production manifest managedRoot/codexHome 未绑定固定 profile。'
    }
    $frozenFiles = @(Select-CodexHookProductionRegistrationRepairFiles -Manifest $Manifest)
    if ($frozenFiles.Count -ne 12) { throw 'production registration-repair 冻结闭包必须恰好 12 个文件。' }
}

function Get-CodexHookProductionManagedOrder {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Registry
    )

    $ownership = Get-CodexHookRegistryOwnershipMap -Manifest $Manifest -Registry $Registry
    $property = $ownership.groupsByEvent.PSObject.Properties['SessionStart']
    if ($null -eq $property) { return @() }
    return [string[]]@(
        foreach ($analysis in @($property.Value)) {
            if ($analysis.isManaged -and $analysis.matchedHook.lifecycle -cne 'retired') {
                [string]$analysis.matchedHook.id
            }
        }
    )
}

function Test-CodexHookJsonSemanticEquivalent {
    param(
        [AllowNull()][object]$Left,
        [AllowNull()][object]$Right
    )

    return (
        ($Left | ConvertTo-Json -Depth 100 -Compress) -ceq
        ($Right | ConvertTo-Json -Depth 100 -Compress)
    )
}

function Get-CodexHookProductionProjectionSummary {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )

    $beforeOwnership = Get-CodexHookRegistryOwnershipMap -Manifest $Manifest -Registry $Before
    $sessionGroups = @($Before.hooks.SessionStart)
    $sessionAnalyses = @($beforeOwnership.groupsByEvent.SessionStart)
    $unknownSessionGroups = @(
        for ($index = 0; $index -lt $sessionGroups.Count; $index++) {
            if (-not $sessionAnalyses[$index].isManaged) {
                $sessionGroups[$index]
            }
        }
    )
    $knownEvents = @('SessionStart', 'Stop', 'PreToolUse')
    $unknownEvents = [ordered]@{}
    foreach ($property in $Before.hooks.PSObject.Properties) {
        if ($knownEvents -cnotcontains [string]$property.Name) {
            $unknownEvents[[string]$property.Name] = $property.Value
        }
    }
    $unknownTopLevel = [ordered]@{}
    foreach ($property in $Before.PSObject.Properties) {
        if ($property.Name -cne 'hooks') {
            $unknownTopLevel[[string]$property.Name] = $property.Value
        }
    }
    $stopProjection = @($Before.hooks.Stop)
    $preToolUseProjection = @($Before.hooks.PreToolUse)
    $unknownProjection = [pscustomobject][ordered]@{
        sessionStartGroups = $unknownSessionGroups
        events = [pscustomobject]$unknownEvents
        topLevel = [pscustomobject]$unknownTopLevel
    }
    return [pscustomobject][ordered]@{
        managedBeforeOrder = [string[]]@(Get-CodexHookProductionManagedOrder -Manifest $Manifest -Registry $Before)
        managedAfterOrder = [string[]]@(Get-CodexHookProductionManagedOrder -Manifest $Manifest -Registry $After)
        stopProjectionCount = $stopProjection.Count
        stopProjectionSha256 = Get-CodexHookTextSha256 -Text ($stopProjection | ConvertTo-Json -Depth 100 -Compress)
        preToolUseProjectionCount = $preToolUseProjection.Count
        preToolUseProjectionSha256 = Get-CodexHookTextSha256 -Text ($preToolUseProjection | ConvertTo-Json -Depth 100 -Compress)
        unknownProjectionCount = $unknownSessionGroups.Count + $unknownEvents.Count + $unknownTopLevel.Count
        unknownProjectionSha256 = Get-CodexHookTextSha256 -Text ($unknownProjection | ConvertTo-Json -Depth 100 -Compress)
        restartRequired = $true
        fileActions = 0
        environmentActions = 0
    }
}

function Assert-CodexHookProductionRegistrationRepairRegistryDelta {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )

    $expectedBefore = @('provider-stability', 'github-cli', 'codex-state-policy', 'serena-activate', 'serena-dashboard')
    $expectedAfter = @('provider-stability', 'codex-state-policy', 'serena-activate', 'serena-dashboard', 'github-cli')
    $beforeOrder = @(Get-CodexHookProductionManagedOrder -Manifest $Manifest -Registry $Before)
    $afterOrder = @(Get-CodexHookProductionManagedOrder -Manifest $Manifest -Registry $After)
    $beforeJson = $Before | ConvertTo-Json -Depth 100 -Compress
    $afterJson = $After | ConvertTo-Json -Depth 100 -Compress
    if ($beforeJson -ceq $afterJson) {
        if (-not (Test-CodexHookExactStringSequence -Actual $beforeOrder -Expected $expectedAfter)) {
            throw 'production registry no-op 仅允许已收敛的受管顺序。'
        }
        return $true
    }
    if (
        -not (Test-CodexHookExactStringSequence -Actual $beforeOrder -Expected $expectedBefore) -or
        -not (Test-CodexHookExactStringSequence -Actual $afterOrder -Expected $expectedAfter)
    ) {
        throw 'production registry 唯一批准顺序差异不匹配。'
    }

    $beforeOther = Copy-CodexHookJsonValue -Value $Before
    $afterOther = Copy-CodexHookJsonValue -Value $After
    $beforeOther.hooks.SessionStart = @()
    $afterOther.hooks.SessionStart = @()
    if (
        ($beforeOther | ConvertTo-Json -Depth 100 -Compress) -cne
        ($afterOther | ConvertTo-Json -Depth 100 -Compress)
    ) {
        throw 'production registry Stop/PreToolUse/未知 event 或字段发生变化。'
    }

    $beforeOwnership = Get-CodexHookRegistryOwnershipMap -Manifest $Manifest -Registry $Before
    $afterOwnership = Get-CodexHookRegistryOwnershipMap -Manifest $Manifest -Registry $After
    $beforeGroups = @($Before.hooks.SessionStart)
    $afterGroups = @($After.hooks.SessionStart)
    $beforeAnalyses = @($beforeOwnership.groupsByEvent.SessionStart)
    $afterAnalyses = @($afterOwnership.groupsByEvent.SessionStart)
    $beforeManagedSlots = @(
        for ($index = 0; $index -lt $beforeAnalyses.Count; $index++) {
            if ($beforeAnalyses[$index].isManaged) { [string]$index }
        }
    )
    $afterManagedSlots = @(
        for ($index = 0; $index -lt $afterAnalyses.Count; $index++) {
            if ($afterAnalyses[$index].isManaged) { [string]$index }
        }
    )
    if (-not (Test-CodexHookExactStringSequence -Actual $beforeManagedSlots -Expected $afterManagedSlots)) {
        throw 'production registry 必须只在原 managed slots 内重排。'
    }
    $beforeUnknown = @(
        for ($index = 0; $index -lt $beforeGroups.Count; $index++) {
            if (-not $beforeAnalyses[$index].isManaged) {
                $beforeGroups[$index] | ConvertTo-Json -Depth 100 -Compress
            }
        }
    )
    $afterUnknown = @(
        for ($index = 0; $index -lt $afterGroups.Count; $index++) {
            if (-not $afterAnalyses[$index].isManaged) {
                $afterGroups[$index] | ConvertTo-Json -Depth 100 -Compress
            }
        }
    )
    if (-not (Test-CodexHookExactStringSequence -Actual $beforeUnknown -Expected $afterUnknown)) {
        throw 'production registry 未知 SessionStart group 投影发生变化。'
    }
    $beforeManaged = @{}
    for ($index = 0; $index -lt $beforeGroups.Count; $index++) {
        if ($beforeAnalyses[$index].isManaged) {
            $beforeManaged[[string]$beforeAnalyses[$index].matchedHook.id] = $beforeGroups[$index] | ConvertTo-Json -Depth 100 -Compress
        }
    }
    for ($index = 0; $index -lt $afterGroups.Count; $index++) {
        if ($afterAnalyses[$index].isManaged) {
            $id = [string]$afterAnalyses[$index].matchedHook.id
            if (-not $beforeManaged.ContainsKey($id) -or $beforeManaged[$id] -cne ($afterGroups[$index] | ConvertTo-Json -Depth 100 -Compress)) {
                throw 'production registry 受管 group 内容发生非顺序变化。'
            }
        }
    }
    return $true
}

function New-CodexHookProductionRegistrationRepairState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Profile)

    [void](Assert-CodexHookProductionRegistrationRepairProfile -Profile $Profile -AllowFixtureAdapter)
    $manifestSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$Profile.manifestPath) `
        -CapabilityRoot ([string]$Profile.sourceRoot) `
        -AllowedExactPaths @([string]$Profile.manifestPath) `
        -Name 'production manifest'
    $manifest = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $manifestSnapshot -Name 'production manifest'
    Assert-CodexHookProductionManifestBinding -Manifest $manifest -Profile $Profile

    $sourceFacts = [Collections.Generic.List[object]]::new()
    $liveFacts = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Select-CodexHookProductionRegistrationRepairFiles -Manifest $manifest)) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path ([string]$Profile.sourceRoot) ([string]$file.relativePath)))
        $livePath = [IO.Path]::GetFullPath((Join-Path ([string]$Profile.hooksRoot) ([string]$file.liveRelativePath)))
        $source = Get-CodexHookCapabilityFileSnapshot `
            -Path $sourcePath `
            -CapabilityRoot ([string]$Profile.sourceRoot) `
            -AllowedExactPaths @($sourcePath) `
            -Name 'production source file'
        $live = Get-CodexHookCapabilityFileSnapshot `
            -Path $livePath `
            -CapabilityRoot ([string]$Profile.hooksRoot) `
            -AllowedExactPaths @($livePath) `
            -Name 'production live file'
        if (-not $source.exists -or $source.state -cne 'regular-file' -or $source.sha256 -cne [string]$file.sha256) {
            throw 'production source closure/hash gate 失败。'
        }
        if (-not $live.exists -or $live.state -cne 'regular-file') {
            throw 'production live file 必须是安全可读普通文件。'
        }
        $sourceFacts.Add([pscustomobject][ordered]@{
            relativePath = [string]$file.relativePath
            path = $sourcePath
            exists = $true
            probeState = 'regular-file'
            sha256 = [string]$source.sha256
        })
        $liveFacts.Add([pscustomobject][ordered]@{
            liveRelativePath = [string]$file.liveRelativePath
            path = $livePath
            exists = $true
            probeState = 'regular-file'
            sha256 = [string]$live.sha256
        })
    }

    $registrySnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$Profile.registryPath) `
        -CapabilityRoot ([string]$Profile.codexHome) `
        -AllowedExactPaths @([string]$Profile.registryPath) `
        -Name 'production hook registry'
    $registry = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $registrySnapshot -Name 'production hook registry'
    $desiredRegistry = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $registry -Mode 'registration-repair'
    [void](Assert-CodexHookProductionRegistrationRepairRegistryDelta -Manifest $manifest -Before $registry -After $desiredRegistry)
    $isNoOp = Test-CodexHookJsonSemanticEquivalent -Left $registry -Right $desiredRegistry
    [byte[]]$desiredBytes = if ($isNoOp) {
        [byte[]]$registrySnapshot.bytes
    } else {
        ConvertTo-CodexHookRegistryBytes -Registry $desiredRegistry
    }
    $registryAfterSha256 = Get-CodexHookBytesSha256 -Bytes $desiredBytes
    $mappingIdentity = Get-CodexHookProductionRegistrationRepairMappingIdentity -Profile $Profile
    $projectionSummary = Get-CodexHookProductionProjectionSummary -Manifest $manifest -Before $registry -After $desiredRegistry
    [object[]]$actions = @()
    [object[]]$postChecks = @()
    if (-not $isNoOp) {
        $actions = @([pscustomobject][ordered]@{
            actionId = 'registry:hooks.json'
            phase = 'registry'
            kind = 'registry'
            sourceRef = $null
            sourceSha256 = $null
            logicalTarget = 'hooks.json'
            targetPath = [string]$Profile.registryPath
            beforeExists = $true
            beforeSha256 = [string]$registrySnapshot.sha256
            afterSha256 = $registryAfterSha256
            restoreOrder = 1
        })
        $postChecks = @([pscustomobject][ordered]@{
            actionId = 'registry:hooks.json'
            kind = 'sha256'
            expectedSha256 = $registryAfterSha256
        })
    }
    $plan = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-deployment-plan'
        schemaVersion = 1
        generationId = [guid]::NewGuid().ToString()
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        manifestSha256 = [string]$manifestSnapshot.sha256
        mode = 'registration-repair'
        applyEligible = $true
        sourceFacts = [pscustomobject][ordered]@{
            targetProfile = [string]$Profile.profileId
            mappingIdentity = $mappingIdentity
            manifestPath = [string]$Profile.manifestPath
            manifestSha256 = [string]$manifestSnapshot.sha256
            sourceRoot = [string]$Profile.sourceRoot
            files = [object[]]$sourceFacts.ToArray()
            blockerReasonCodes = @()
        }
        liveFacts = [pscustomobject][ordered]@{
            targetProfile = [string]$Profile.profileId
            mappingIdentity = $mappingIdentity
            codexHome = [string]$Profile.codexHome
            hooksRoot = [string]$Profile.hooksRoot
            registryPath = [string]$Profile.registryPath
            files = [object[]]$liveFacts.ToArray()
            blockerReasonCodes = @()
        }
        registryBeforeSha256 = [string]$registrySnapshot.sha256
        registryAfterSha256 = $registryAfterSha256
        projectionSummary = $projectionSummary
        actions = $actions
        environmentActions = @()
        postChecks = $postChecks
        rollbackRequired = -not $isNoOp
    }
    return [pscustomobject][ordered]@{
        manifestSnapshot = $manifestSnapshot
        manifest = $manifest
        registrySnapshot = $registrySnapshot
        registry = $registry
        desiredRegistry = $desiredRegistry
        desiredRegistryBytes = $desiredBytes
        sourceFacts = [object[]]$sourceFacts.ToArray()
        liveFacts = [object[]]$liveFacts.ToArray()
        plan = $plan
        isNoOp = $isNoOp
    }
}

function Assert-CodexHookProductionRegistrationRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Profile,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    [void](Assert-CodexHookProductionRegistrationRepairProfile -Profile $Profile -AllowFixtureAdapter)
    Assert-CodexHookExactProperties -Value $Plan -Names @(
        'artifactType', 'schemaVersion', 'generationId', 'generatedAtUtc', 'manifestSha256',
        'mode', 'applyEligible', 'sourceFacts', 'liveFacts', 'registryBeforeSha256',
        'registryAfterSha256', 'projectionSummary', 'actions', 'environmentActions',
        'postChecks', 'rollbackRequired'
    ) -Scope 'production deployment plan'
    if (
        $Plan.artifactType -cne 'env-governance.codex-hook-deployment-plan' -or
        [int]$Plan.schemaVersion -ne 1 -or
        $Plan.mode -cne 'registration-repair' -or
        $Plan.applyEligible -isnot [bool] -or
        -not $Plan.applyEligible
    ) {
        throw 'production deployment plan 顶层 contract 非法。'
    }
    [void](Assert-CodexHookGenerationId -Value ([string]$Plan.generationId))
    $generated = [datetimeoffset]::MinValue
    if (
        -not [datetimeoffset]::TryParse([string]$Plan.generatedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$generated) -or
        $generated -gt $Now.AddMinutes(5) -or
        $generated -lt $Now.AddHours(-1)
    ) {
        throw 'production deployment plan 已过期或时间非法。'
    }
    foreach ($hashName in @('manifestSha256', 'registryBeforeSha256', 'registryAfterSha256')) {
        if ([string]$Plan.$hashName -cnotmatch '^[0-9a-f]{64}$') {
            throw "production deployment plan $hashName 非法。"
        }
    }
    Assert-CodexHookExactProperties -Value $Plan.sourceFacts -Names @(
        'targetProfile', 'mappingIdentity', 'manifestPath', 'manifestSha256',
        'sourceRoot', 'files', 'blockerReasonCodes'
    ) -Scope 'production plan sourceFacts'
    Assert-CodexHookExactProperties -Value $Plan.liveFacts -Names @(
        'targetProfile', 'mappingIdentity', 'codexHome', 'hooksRoot',
        'registryPath', 'files', 'blockerReasonCodes'
    ) -Scope 'production plan liveFacts'
    $identity = Get-CodexHookProductionRegistrationRepairMappingIdentity -Profile $Profile
    if (
        $Plan.sourceFacts.targetProfile -cne [string]$Profile.profileId -or
        $Plan.liveFacts.targetProfile -cne [string]$Profile.profileId -or
        $Plan.sourceFacts.mappingIdentity -cne $identity -or
        $Plan.liveFacts.mappingIdentity -cne $identity -or
        $Plan.sourceFacts.manifestPath -cne [string]$Profile.manifestPath -or
        $Plan.sourceFacts.sourceRoot -cne [string]$Profile.sourceRoot -or
        $Plan.liveFacts.codexHome -cne [string]$Profile.codexHome -or
        $Plan.liveFacts.hooksRoot -cne [string]$Profile.hooksRoot -or
        $Plan.liveFacts.registryPath -cne [string]$Profile.registryPath -or
        $Plan.manifestSha256 -cne $Plan.sourceFacts.manifestSha256
    ) {
        throw 'production plan fixed profile/mapping binding 失败。'
    }
    if (@($Plan.sourceFacts.blockerReasonCodes).Count -ne 0 -or @($Plan.liveFacts.blockerReasonCodes).Count -ne 0) {
        throw 'production applyEligible plan 不得包含 blocker。'
    }
    if (@($Plan.sourceFacts.files).Count -ne 12 -or @($Plan.liveFacts.files).Count -ne 12) {
        throw 'production plan source/live closure 必须恰好 12 个文件。'
    }
    $expectedFrozenRelative = [string[]](Get-CodexHookProductionRegistrationRepairFrozenRelativePaths)
    $sourceRelative = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fact in @($Plan.sourceFacts.files)) {
        Assert-CodexHookExactProperties -Value $fact -Names @('relativePath', 'path', 'exists', 'probeState', 'sha256') -Scope 'production source fact'
        $expectedPath = [IO.Path]::GetFullPath((Join-Path ([string]$Profile.sourceRoot) ([string]$fact.relativePath)))
        if (
            -not $sourceRelative.Add([string]$fact.relativePath) -or
            [IO.Path]::GetFullPath([string]$fact.path) -ine $expectedPath -or
            $fact.exists -isnot [bool] -or -not $fact.exists -or
            $fact.probeState -cne 'regular-file' -or
            [string]$fact.sha256 -cnotmatch '^[0-9a-f]{64}$'
        ) {
            throw 'production source fact mapping/state 非法。'
        }
        [void](Assert-CodexHookCapabilityPath -Path $expectedPath -CapabilityRoot ([string]$Profile.sourceRoot) -AllowedExactPaths @($expectedPath) -Name 'production plan source fact')
    }
    if (-not (Test-CodexHookExactStringSequence -Actual ([string[]]@($Plan.sourceFacts.files | ForEach-Object { [string]$_.relativePath })) -Expected $expectedFrozenRelative)) {
        throw 'production source facts 未严格绑定冻结 12 文件 allowlist。'
    }
    $liveRelative = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fact in @($Plan.liveFacts.files)) {
        Assert-CodexHookExactProperties -Value $fact -Names @('liveRelativePath', 'path', 'exists', 'probeState', 'sha256') -Scope 'production live fact'
        $expectedPath = [IO.Path]::GetFullPath((Join-Path ([string]$Profile.hooksRoot) ([string]$fact.liveRelativePath)))
        if (
            -not $liveRelative.Add([string]$fact.liveRelativePath) -or
            [IO.Path]::GetFullPath([string]$fact.path) -ine $expectedPath -or
            $fact.exists -isnot [bool] -or -not $fact.exists -or
            $fact.probeState -cne 'regular-file' -or
            [string]$fact.sha256 -cnotmatch '^[0-9a-f]{64}$'
        ) {
            throw 'production live fact mapping/state 非法。'
        }
        [void](Assert-CodexHookCapabilityPath -Path $expectedPath -CapabilityRoot ([string]$Profile.hooksRoot) -AllowedExactPaths @($expectedPath) -Name 'production plan live fact')
    }
    $expectedFrozenLive = [string[]](Get-CodexHookProductionRegistrationRepairFrozenLiveRelativePaths)
    if (-not (Test-CodexHookExactStringSequence -Actual ([string[]]@($Plan.liveFacts.files | ForEach-Object { [string]$_.liveRelativePath })) -Expected $expectedFrozenLive)) {
        throw 'production live facts 未严格绑定冻结 12 文件 allowlist。'
    }
    if (@($Plan.environmentActions).Count -ne 0) {
        throw 'production registration-repair 禁止 environment action。'
    }
    Assert-CodexHookExactProperties -Value $Plan.projectionSummary -Names @(
        'managedBeforeOrder', 'managedAfterOrder', 'stopProjectionCount',
        'stopProjectionSha256', 'preToolUseProjectionCount',
        'preToolUseProjectionSha256', 'unknownProjectionCount',
        'unknownProjectionSha256', 'restartRequired', 'fileActions',
        'environmentActions'
    ) -Scope 'production plan projectionSummary'
    $expectedBeforeOrder = if ($Plan.registryBeforeSha256 -ceq $Plan.registryAfterSha256) {
        @('provider-stability','codex-state-policy','serena-activate','serena-dashboard','github-cli')
    } else {
        @('provider-stability','github-cli','codex-state-policy','serena-activate','serena-dashboard')
    }
    $expectedAfterOrder = @('provider-stability','codex-state-policy','serena-activate','serena-dashboard','github-cli')
    if (
        -not (Test-CodexHookExactStringSequence -Actual @($Plan.projectionSummary.managedBeforeOrder) -Expected $expectedBeforeOrder) -or
        -not (Test-CodexHookExactStringSequence -Actual @($Plan.projectionSummary.managedAfterOrder) -Expected $expectedAfterOrder)
    ) {
        throw 'production plan managed projection order 非法。'
    }
    foreach ($countName in @('stopProjectionCount','preToolUseProjectionCount','unknownProjectionCount','fileActions','environmentActions')) {
        Assert-CodexHookInteger -Value $Plan.projectionSummary.$countName -Name "production projection $countName"
        if ([int]$Plan.projectionSummary.$countName -lt 0) { throw "production projection $countName 非法。" }
    }
    foreach ($hashName in @('stopProjectionSha256','preToolUseProjectionSha256','unknownProjectionSha256')) {
        if ([string]$Plan.projectionSummary.$hashName -cnotmatch '^[0-9a-f]{64}$') {
            throw "production projection $hashName 非法。"
        }
    }
    if (
        $Plan.projectionSummary.restartRequired -ne $true -or
        [int]$Plan.projectionSummary.fileActions -ne 0 -or
        [int]$Plan.projectionSummary.environmentActions -ne 0
    ) {
        throw 'production projection restart/action contract 非法。'
    }
    $actions = @($Plan.actions)
    $postChecks = @($Plan.postChecks)
    if ($Plan.registryBeforeSha256 -ceq $Plan.registryAfterSha256) {
        if ($actions.Count -ne 0 -or $postChecks.Count -ne 0 -or $Plan.rollbackRequired -ne $false) {
            throw 'production converged plan 必须是零动作 no-op。'
        }
    } else {
        if ($actions.Count -ne 1 -or $postChecks.Count -ne 1 -or $Plan.rollbackRequired -ne $true) {
            throw 'production registration-repair 必须恰好一个 registry action/postcheck。'
        }
        $action = $actions[0]
        Assert-CodexHookExactProperties -Value $action -Names @(
            'actionId', 'phase', 'kind', 'sourceRef', 'sourceSha256', 'logicalTarget',
            'targetPath', 'beforeExists', 'beforeSha256', 'afterSha256', 'restoreOrder'
        ) -Scope 'production registry action'
        if (
            $action.actionId -cne 'registry:hooks.json' -or
            $action.phase -cne 'registry' -or
            $action.kind -cne 'registry' -or
            $null -ne $action.sourceRef -or
            $null -ne $action.sourceSha256 -or
            $action.logicalTarget -cne 'hooks.json' -or
            $action.targetPath -cne [string]$Profile.registryPath -or
            $action.beforeExists -ne $true -or
            $action.beforeSha256 -cne $Plan.registryBeforeSha256 -or
            $action.afterSha256 -cne $Plan.registryAfterSha256 -or
            [int]$action.restoreOrder -ne 1
        ) {
            throw 'production registry action capability contract 非法。'
        }
        Assert-CodexHookExactProperties -Value $postChecks[0] -Names @('actionId', 'kind', 'expectedSha256') -Scope 'production registry postcheck'
        if (
            $postChecks[0].actionId -cne 'registry:hooks.json' -or
            $postChecks[0].kind -cne 'sha256' -or
            $postChecks[0].expectedSha256 -cne $Plan.registryAfterSha256
        ) {
            throw 'production registry postcheck contract 非法。'
        }
    }
    return $true
}

function Test-CodexHookProductionPlanProjectionEqual {
    param(
        [Parameter(Mandatory)][object]$Planned,
        [Parameter(Mandatory)][object]$Derived
    )

    foreach ($property in @(
        'manifestSha256', 'mode', 'sourceFacts', 'liveFacts', 'registryBeforeSha256',
        'registryAfterSha256', 'projectionSummary', 'actions', 'environmentActions',
        'postChecks', 'rollbackRequired'
    )) {
        if (
            ($Planned.$property | ConvertTo-Json -Depth 100 -Compress) -cne
            ($Derived.$property | ConvertTo-Json -Depth 100 -Compress)
        ) {
            return $false
        }
    }
    return $true
}

function Test-CodexHookProductionStaticFactsEqual {
    param(
        [Parameter(Mandatory)][object]$Planned,
        [Parameter(Mandatory)][object]$Derived
    )

    foreach ($property in @('manifestSha256', 'sourceFacts', 'liveFacts')) {
        if (
            ($Planned.$property | ConvertTo-Json -Depth 100 -Compress) -cne
            ($Derived.$property | ConvertTo-Json -Depth 100 -Compress)
        ) {
            return $false
        }
    }
    return $true
}

function Get-CodexHookProductionRegistrationRepairLifecyclePaths {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$GenerationId
    )

    [void](Assert-CodexHookGenerationId -Value $GenerationId)
    $claimsRoot = Join-Path ([string]$Profile.evidenceRoot) '.claims'
    $claimPath = Join-Path $claimsRoot "$GenerationId.json"
    $evidenceDirectory = Join-Path ([string]$Profile.evidenceRoot) "deployment-$GenerationId"
    return [pscustomobject][ordered]@{
        claimsRoot = $claimsRoot
        claimPath = $claimPath
        evidenceDirectory = $evidenceDirectory
        backupsRoot = Join-Path $evidenceDirectory 'backups'
        backupPath = Join-Path $evidenceDirectory 'backups\registry.bin'
        restoreManifestPath = Join-Path $evidenceDirectory 'restore-manifest.json'
        statusPath = Join-Path $evidenceDirectory 'status.json'
    }
}

function Set-CodexHookProductionApplyTerminalStatus {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$StatusPath,
        [Parameter(Mandatory)][object]$StatusDocument,
        [Parameter(Mandatory)]
        [ValidateSet('rolled-back', 'rollback-blocked')]
        [string]$TerminalStatus
    )

    $StatusDocument.status = $TerminalStatus
    $StatusDocument.completedActionIds = @()
    Set-CodexHookCapabilityJson `
        -Path $StatusPath `
        -Document $StatusDocument `
        -CapabilityRoot ([string]$Profile.evidenceRoot) `
        -AllowedExactPaths @($StatusPath) `
        -Scope 'production apply terminal status'
    $snapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $StatusPath `
        -CapabilityRoot ([string]$Profile.evidenceRoot) `
        -AllowedExactPaths @($StatusPath) `
        -Name 'production apply terminal status confirm'
    $confirmed = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $snapshot -Name 'production apply terminal status confirm'
    if (
        $confirmed.status -cne $TerminalStatus -or
        @($confirmed.completedActionIds).Count -ne 0 -or
        $confirmed.generationId -cne $StatusDocument.generationId -or
        $confirmed.profileId -cne $StatusDocument.profileId
    ) {
        throw 'production apply terminal status 回读确认失败。'
    }
    return $confirmed
}

function Invoke-CodexHookProductionRegistrationRepairApplyCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Profile,
        [scriptblock]$TestAfterRegistryPublish,
        [scriptblock]$TestBeforeRollbackMove,
        [scriptblock]$TestAfterRollbackSnapshot,
        [ValidateSet('none', 'crash-after-registry-publish')]
        [string]$TestFaultInjection = 'none'
    )

    [void](Assert-CodexHookProductionRegistrationRepairProfile -Profile $Profile -AllowFixtureAdapter)
    if (
        ($null -ne $TestAfterRegistryPublish -or $null -ne $TestBeforeRollbackMove -or $null -ne $TestAfterRollbackSnapshot -or $TestFaultInjection -cne 'none') -and
        -not $Profile.isFixtureAdapter
    ) {
        throw 'test-only production apply fault injection 仅允许 fixed fixture adapter。'
    }
    $planSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$Profile.planPath) `
        -CapabilityRoot ([string]$Profile.planOutputDir) `
        -AllowedExactPaths @([string]$Profile.planPath) `
        -Name 'production deployment plan'
    $plan = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $planSnapshot -Name 'production deployment plan'
    [void](Assert-CodexHookProductionRegistrationRepairPlan -Plan $plan -Profile $Profile)
    $state = New-CodexHookProductionRegistrationRepairState -Profile $Profile
    if (
        $state.isNoOp -and
        $state.registrySnapshot.sha256 -ceq $plan.registryAfterSha256 -and
        (Test-CodexHookProductionStaticFactsEqual -Planned $plan -Derived $state.plan)
    ) {
        $noOpPaths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $Profile -GenerationId ([string]$plan.generationId)
        [void](Assert-CodexHookCapabilityPath -Path ([string]$noOpPaths.claimPath) -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$noOpPaths.claimPath) -Name 'production no-op claim check')
        if (Test-Path -LiteralPath ([string]$noOpPaths.claimPath)) {
            throw 'production generationId 已被永久 claim；拒绝重放。'
        }
        return [pscustomobject][ordered]@{
            applied = $false
            noOp = $true
            refusalReason = 'already-converged'
            generationId = [string]$plan.generationId
        }
    }
    if (-not (Test-CodexHookProductionPlanProjectionEqual -Planned $plan -Derived $state.plan)) {
        throw 'production plan final re-derivation contract 失败。'
    }

    $mutex = [Threading.Mutex]::new($false, [string]$Profile.mutexName)
    $mutexHeld = $false
    try {
        $mutexHeld = $mutex.WaitOne(0)
        if (-not $mutexHeld) { throw 'production registration-repair mutex busy。' }
        $state = New-CodexHookProductionRegistrationRepairState -Profile $Profile
        if (-not (Test-CodexHookProductionPlanProjectionEqual -Planned $plan -Derived $state.plan)) {
            throw 'production critical recheck 检测到漂移。'
        }
        $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $Profile -GenerationId ([string]$plan.generationId)
        [void](Assert-CodexHookCapabilityPath -Path ([string]$paths.claimPath) -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.claimPath) -Name 'production generation claim')
        [void](Assert-CodexHookCapabilityPath -Path ([string]$paths.evidenceDirectory) -CapabilityRoot ([string]$Profile.evidenceRoot) -Name 'production evidence directory')
        if (Test-Path -LiteralPath ([string]$paths.claimPath)) {
            throw 'production generationId 已被永久 claim；拒绝重放。'
        }
        if (Test-Path -LiteralPath ([string]$paths.evidenceDirectory)) {
            throw 'production evidence directory 已存在；拒绝重放。'
        }
        [void](New-CodexHookCapabilityDirectory -Path ([string]$paths.claimsRoot) -CapabilityRoot ([string]$Profile.evidenceRoot) -Name 'production claims root')
        $claim = [pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-hook-deployment-claim'
            schemaVersion = 1
            profileId = [string]$Profile.profileId
            state = 'reserved'
            generationId = [string]$plan.generationId
            mappingIdentity = [string]$plan.sourceFacts.mappingIdentity
            planSha256 = [string]$planSnapshot.sha256
            evidenceDirectory = [string]$paths.evidenceDirectory
            restoreManifestSha256 = $null
        }
        Set-CodexHookCapabilityJson `
            -Path ([string]$paths.claimPath) `
            -Document $claim `
            -CapabilityRoot ([string]$Profile.evidenceRoot) `
            -AllowedExactPaths @([string]$paths.claimPath) `
            -Scope 'production claim reserve'

        [void](New-CodexHookCapabilityDirectory -Path ([string]$paths.evidenceDirectory) -CapabilityRoot ([string]$Profile.evidenceRoot) -Name 'production evidence directory' -RequireMissing)
        [void](New-CodexHookCapabilityDirectory -Path ([string]$paths.backupsRoot) -CapabilityRoot ([string]$Profile.evidenceRoot) -Name 'production backups root' -RequireMissing)
        Set-CodexHookAtomicFileBytesWithCapability `
            -Path ([string]$paths.backupPath) `
            -Bytes ([byte[]]$state.registrySnapshot.bytes) `
            -ExpectedExists $false `
            -ExpectedSha256 $null `
            -AfterSha256 ([string]$state.registrySnapshot.sha256) `
            -CapabilityRoot ([string]$Profile.evidenceRoot) `
            -AllowedExactPaths @([string]$paths.backupPath) `
            -Scope 'production registry backup'
        $restore = [pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-hook-production-registration-repair-restore'
            schemaVersion = 1
            profileId = [string]$Profile.profileId
            generationId = [string]$plan.generationId
            planSha256 = [string]$planSnapshot.sha256
            mappingIdentity = [string]$plan.sourceFacts.mappingIdentity
            actions = @([pscustomobject][ordered]@{
                actionId = 'registry:hooks.json'
                kind = 'registry'
                path = [string]$Profile.registryPath
                beforeExists = $true
                beforeSha256 = [string]$state.registrySnapshot.sha256
                backupRelativePath = 'backups/registry.bin'
                backupSha256 = [string]$state.registrySnapshot.sha256
                deployedExists = $true
                deployedSha256 = [string]$plan.registryAfterSha256
                restoreOrder = 1
            })
        }
        Set-CodexHookCapabilityJson -Path ([string]$paths.restoreManifestPath) -Document $restore -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.restoreManifestPath) -Scope 'production restore manifest'
        $restoreSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$paths.restoreManifestPath) -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.restoreManifestPath) -Name 'production restore manifest'
        $claim.state = 'prepared'
        $claim.restoreManifestSha256 = [string]$restoreSnapshot.sha256
        Set-CodexHookCapabilityJson -Path ([string]$paths.claimPath) -Document $claim -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.claimPath) -Scope 'production claim prepared'
        $status = [pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-hook-production-registration-repair-status'
            schemaVersion = 1
            profileId = [string]$Profile.profileId
            generationId = [string]$plan.generationId
            status = 'applying'
            completedActionIds = @()
        }
        Set-CodexHookCapabilityJson -Path ([string]$paths.statusPath) -Document $status -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.statusPath) -Scope 'production status'
        try {
            Set-CodexHookAtomicFileBytesWithCapability `
                -Path ([string]$Profile.registryPath) `
                -Bytes ([byte[]]$state.desiredRegistryBytes) `
                -ExpectedExists $true `
                -ExpectedSha256 ([string]$state.registrySnapshot.sha256) `
                -AfterSha256 ([string]$plan.registryAfterSha256) `
                -CapabilityRoot ([string]$Profile.codexHome) `
                -AllowedExactPaths @([string]$Profile.registryPath) `
                -Scope 'production registry publish'
            if ($null -ne $TestAfterRegistryPublish) {
                & $TestAfterRegistryPublish
            }
            if ($TestFaultInjection -ceq 'crash-after-registry-publish') {
                throw 'test-fault:crash-after-registry-publish'
            }
            try {
                $postPublishState = New-CodexHookProductionRegistrationRepairState -Profile $Profile
                if (
                    -not $postPublishState.isNoOp -or
                    $postPublishState.registrySnapshot.sha256 -cne [string]$plan.registryAfterSha256 -or
                    -not (Test-CodexHookProductionStaticFactsEqual -Planned $plan -Derived $postPublishState.plan)
                ) {
                    throw 'static fact projection mismatch'
                }
            } catch {
                throw 'production post-publish static facts final gate 失败。'
            }
            $status.status = 'applied'
            $status.completedActionIds = @('registry:hooks.json')
            Set-CodexHookCapabilityJson -Path ([string]$paths.statusPath) -Document $status -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.statusPath) -Scope 'production status'
        } catch {
            $failureMessage = $_.Exception.Message
            if ($failureMessage -ceq 'test-fault:crash-after-registry-publish') {
                throw
            }
            $rollbackConfirmed = $false
            $blockedStatusConfirmed = $false
            $rollbackAttempted = $false
            $blockedReason = 'external-registry-drift / rollback-not-attempted'
            $current = Get-CodexHookCapabilityFileSnapshot -Path ([string]$Profile.registryPath) -CapabilityRoot ([string]$Profile.codexHome) -AllowedExactPaths @([string]$Profile.registryPath) -Name 'production rollback current registry'
            if ($current.sha256 -ceq [string]$plan.registryAfterSha256) {
                $rollbackAttempted = $true
                try {
                    Set-CodexHookAtomicFileBytesWithCapability `
                        -Path ([string]$Profile.registryPath) `
                        -Bytes ([byte[]]$state.registrySnapshot.bytes) `
                        -ExpectedExists $true `
                        -ExpectedSha256 ([string]$plan.registryAfterSha256) `
                        -AfterSha256 ([string]$state.registrySnapshot.sha256) `
                        -CapabilityRoot ([string]$Profile.codexHome) `
                        -AllowedExactPaths @([string]$Profile.registryPath) `
                        -Scope 'production automatic registry rollback' `
                        -BeforeMove $TestBeforeRollbackMove `
                        -TestAfterPremoveSnapshot $TestAfterRollbackSnapshot
                } catch {
                    # An uncoordinated external delete/replace can still alter the pathname
                    # around the final syscall. Re-read below; never retry over an
                    # unrecognized state or describe this as an absolute CAS.
                }
            }
            $afterRollbackAttempt = Get-CodexHookCapabilityFileSnapshot -Path ([string]$Profile.registryPath) -CapabilityRoot ([string]$Profile.codexHome) -AllowedExactPaths @([string]$Profile.registryPath) -Name 'production rollback outcome registry'
            if (
                $rollbackAttempted -and
                $afterRollbackAttempt.sha256 -cne [string]$state.registrySnapshot.sha256
            ) {
                $blockedReason = if ($afterRollbackAttempt.sha256 -cne [string]$plan.registryAfterSha256) {
                    'external-registry-drift / rollback-cas-lost'
                } else {
                    'rollback-attempt-failed'
                }
            }
            if ($afterRollbackAttempt.sha256 -ceq [string]$state.registrySnapshot.sha256) {
                try {
                    [void](Set-CodexHookProductionApplyTerminalStatus `
                        -Profile $Profile `
                        -StatusPath ([string]$paths.statusPath) `
                        -StatusDocument $status `
                        -TerminalStatus 'rolled-back')
                    $finalRegistry = Get-CodexHookCapabilityFileSnapshot -Path ([string]$Profile.registryPath) -CapabilityRoot ([string]$Profile.codexHome) -AllowedExactPaths @([string]$Profile.registryPath) -Name 'production rollback final registry confirm'
                    $rollbackConfirmed = $finalRegistry.sha256 -ceq [string]$state.registrySnapshot.sha256
                    if (-not $rollbackConfirmed) {
                        $blockedReason = 'external-registry-drift / rollback-confirmation-lost'
                    }
                } catch {
                    $rollbackConfirmed = $false
                    $blockedReason = 'rollback-state-confirmation-failed'
                }
            }
            if (-not $rollbackConfirmed) {
                try {
                    [void](Set-CodexHookProductionApplyTerminalStatus `
                        -Profile $Profile `
                        -StatusPath ([string]$paths.statusPath) `
                        -StatusDocument $status `
                        -TerminalStatus 'rollback-blocked')
                    $blockedStatusConfirmed = $true
                } catch {
                    $blockedReason = "$blockedReason / status-confirmation-failed"
                }
            }
            $blockedStatusLabel = if ($blockedStatusConfirmed) { 'rollback-blocked' } else { 'unconfirmed' }
            if ($failureMessage -like 'production post-publish static facts*') {
                if ($rollbackConfirmed) {
                    throw 'production post-publish static facts 失败；rollback-confirmed；status=rolled-back。'
                }
                throw "production post-publish static facts 失败；$blockedReason；status=$blockedStatusLabel。"
            }
            if ($rollbackConfirmed) {
                throw 'production registry apply 失败；rollback-confirmed；status=rolled-back。'
            }
            throw "production registry apply 失败；$blockedReason；status=$blockedStatusLabel。"
        }
        return [pscustomobject][ordered]@{
            applied = $true
            noOp = $false
            generationId = [string]$plan.generationId
            evidenceDirectory = [string]$paths.evidenceDirectory
        }
    } finally {
        if ($mutexHeld) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Restore-CodexHookProductionRegistrationRepairCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [ValidateSet('none', 'crash-after-registry-restore')]
        [string]$TestFaultInjection = 'none'
    )

    [void](Assert-CodexHookProductionRegistrationRepairProfile -Profile $Profile -AllowFixtureAdapter)
    if ($TestFaultInjection -cne 'none' -and -not $Profile.isFixtureAdapter) {
        throw 'test-only production restore fault injection 仅允许 fixed fixture adapter。'
    }
    $evidencePath = Assert-CodexHookCapabilityPath -Path $EvidenceDirectory -CapabilityRoot ([string]$Profile.evidenceRoot) -Name 'production restore evidence directory'
    if (
        [IO.Path]::GetDirectoryName($evidencePath) -ine [IO.Path]::GetFullPath([string]$Profile.evidenceRoot) -or
        [IO.Path]::GetFileName($evidencePath) -cnotmatch '^deployment-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
    ) {
        throw 'production restore evidence 必须是固定 root 的 deployment-guid 直接子目录。'
    }
    $generationId = [regex]::Match([IO.Path]::GetFileName($evidencePath), '^deployment-(.+)$').Groups[1].Value
    [void](Assert-CodexHookGenerationId -Value $generationId)
    $paths = Get-CodexHookProductionRegistrationRepairLifecyclePaths -Profile $Profile -GenerationId $generationId
    if ([IO.Path]::GetFullPath([string]$paths.evidenceDirectory) -ine $evidencePath) {
        throw 'production restore generation/evidence mapping 不一致。'
    }
    $mutex = [Threading.Mutex]::new($false, [string]$Profile.mutexName)
    $held = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'production registration-repair mutex busy。' }
        $claimSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$paths.claimPath) -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.claimPath) -Name 'production restore claim'
        $restoreSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$paths.restoreManifestPath) -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.restoreManifestPath) -Name 'production restore manifest'
        $statusSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$paths.statusPath) -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.statusPath) -Name 'production restore status'
        $backupSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$paths.backupPath) -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.backupPath) -Name 'production restore backup'
        $claim = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $claimSnapshot -Name 'production restore claim'
        $restore = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $restoreSnapshot -Name 'production restore manifest'
        $status = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $statusSnapshot -Name 'production restore status'
        Assert-CodexHookExactProperties -Value $claim -Names @('artifactType','schemaVersion','profileId','state','generationId','mappingIdentity','planSha256','evidenceDirectory','restoreManifestSha256') -Scope 'production restore claim'
        Assert-CodexHookExactProperties -Value $restore -Names @('artifactType','schemaVersion','profileId','generationId','planSha256','mappingIdentity','actions') -Scope 'production restore manifest'
        Assert-CodexHookExactProperties -Value $status -Names @('artifactType','schemaVersion','profileId','generationId','status','completedActionIds') -Scope 'production restore status'
        Assert-CodexHookArray -Value ([object]$restore.actions) -Name 'production restore actions'
        Assert-CodexHookArray -Value ([object]$status.completedActionIds) -Name 'production restore completedActionIds'
        $actions = @($restore.actions)
        if (
            $claim.artifactType -cne 'env-governance.codex-hook-deployment-claim' -or
            [int]$claim.schemaVersion -ne 1 -or
            $claim.profileId -cne [string]$Profile.profileId -or
            $claim.state -cne 'prepared' -or
            $claim.generationId -cne $generationId -or
            $claim.evidenceDirectory -cne $evidencePath -or
            $claim.restoreManifestSha256 -cne $restoreSnapshot.sha256 -or
            $claim.mappingIdentity -cne (Get-CodexHookProductionRegistrationRepairMappingIdentity -Profile $Profile) -or
            [string]$claim.planSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $restore.artifactType -cne 'env-governance.codex-hook-production-registration-repair-restore' -or
            [int]$restore.schemaVersion -ne 1 -or
            $restore.profileId -cne [string]$Profile.profileId -or
            $restore.generationId -cne $generationId -or
            $restore.mappingIdentity -cne (Get-CodexHookProductionRegistrationRepairMappingIdentity -Profile $Profile) -or
            $restore.planSha256 -cne $claim.planSha256 -or
            $status.artifactType -cne 'env-governance.codex-hook-production-registration-repair-status' -or
            [int]$status.schemaVersion -ne 1 -or
            $status.profileId -cne [string]$Profile.profileId -or
            $status.generationId -cne $generationId -or
            $status.status -cnotin @('applying', 'applied', 'restored', 'rolled-back') -or
            $actions.Count -ne 1
        ) {
            throw 'production restore claim/manifest binding 非法。'
        }
        $action = $actions[0]
        Assert-CodexHookExactProperties -Value $action -Names @('actionId','kind','path','beforeExists','beforeSha256','backupRelativePath','backupSha256','deployedExists','deployedSha256','restoreOrder') -Scope 'production restore action'
        if (
            $action.actionId -cne 'registry:hooks.json' -or
            $action.kind -cne 'registry' -or
            $action.path -cne [string]$Profile.registryPath -or
            $action.beforeExists -isnot [bool] -or
            $action.beforeExists -ne $true -or
            $action.deployedExists -isnot [bool] -or
            $action.deployedExists -ne $true -or
            $action.backupRelativePath -cne 'backups/registry.bin' -or
            [string]$action.beforeSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$action.deployedSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $action.backupSha256 -cne $action.beforeSha256 -or
            $backupSnapshot.sha256 -cne $action.backupSha256 -or
            $action.beforeSha256 -ceq $action.deployedSha256
        ) {
            throw 'production restore 只允许 fixed registry action。'
        }
        Assert-CodexHookInteger -Value $action.restoreOrder -Name 'production restore order'
        if ([int]$action.restoreOrder -ne 1) {
            throw 'production restore order 非法。'
        }
        $completedActionIdsValid = if ($status.status -ceq 'applied') {
            @($status.completedActionIds).Count -eq 1 -and
            [string]@($status.completedActionIds)[0] -ceq 'registry:hooks.json'
        } else {
            @($status.completedActionIds).Count -eq 0
        }
        if (-not $completedActionIdsValid) {
            throw 'production restore status/completedActionIds binding 非法。'
        }

        $manifestSnapshot = Get-CodexHookCapabilityFileSnapshot `
            -Path ([string]$Profile.manifestPath) `
            -CapabilityRoot ([string]$Profile.sourceRoot) `
            -AllowedExactPaths @([string]$Profile.manifestPath) `
            -Name 'production restore profile manifest'
        $manifest = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $manifestSnapshot -Name 'production restore profile manifest'
        Assert-CodexHookProductionManifestBinding -Manifest $manifest -Profile $Profile
        $backupRegistry = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $backupSnapshot -Name 'production restore backup registry'
        $current = Get-CodexHookCapabilityFileSnapshot -Path ([string]$Profile.registryPath) -CapabilityRoot ([string]$Profile.codexHome) -AllowedExactPaths @([string]$Profile.registryPath) -Name 'production restore current registry'
        $currentRegistry = ConvertFrom-CodexHookProductionJsonSnapshot -Snapshot $current -Name 'production restore current registry'
        try {
            $expectedDeployedRegistry = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $backupRegistry -Mode 'registration-repair'
            [void](Assert-CodexHookProductionRegistrationRepairRegistryDelta -Manifest $manifest -Before $backupRegistry -After $expectedDeployedRegistry)
            [byte[]]$expectedDeployedBytes = ConvertTo-CodexHookRegistryBytes -Registry $expectedDeployedRegistry
            $expectedDeployedSha256 = Get-CodexHookBytesSha256 -Bytes $expectedDeployedBytes
            if ($expectedDeployedSha256 -cne [string]$action.deployedSha256) {
                throw 'deployed fingerprint mismatch'
            }
            if ($current.sha256 -ceq [string]$action.deployedSha256) {
                [void](Assert-CodexHookProductionRegistrationRepairRegistryDelta -Manifest $manifest -Before $backupRegistry -After $currentRegistry)
            } elseif ($current.sha256 -ceq [string]$action.beforeSha256) {
                if (-not (Test-CodexHookJsonSemanticEquivalent -Left $backupRegistry -Right $currentRegistry)) {
                    throw 'before fingerprint semantic mismatch'
                }
            } else {
                throw 'current registry third hash'
            }
        } catch {
            throw 'production restore forged/semantic registry evidence 拒绝。'
        }

        $currentIsBefore = $current.sha256 -ceq [string]$action.beforeSha256
        $currentIsDeployed = $current.sha256 -ceq [string]$action.deployedSha256
        if ($status.status -cin @('restored', 'rolled-back')) {
            if (-not $currentIsBefore) {
                throw 'production restore terminal status 与 current registry 不相容。'
            }
            return [pscustomobject][ordered]@{
                restored = $false
                noOp = $true
                generationId = $generationId
                terminalStatus = [string]$status.status
            }
        }
        if ($currentIsBefore) {
            $status.status = if ($status.status -ceq 'applying') { 'rolled-back' } else { 'restored' }
            $status.completedActionIds = @()
            Set-CodexHookCapabilityJson -Path ([string]$paths.statusPath) -Document $status -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.statusPath) -Scope 'production restore terminal status'
            return [pscustomobject][ordered]@{
                restored = $false
                noOp = $true
                generationId = $generationId
                terminalStatus = [string]$status.status
            }
        }
        if (-not $currentIsDeployed -or $status.status -cnotin @('applying', 'applied')) {
            throw 'production restore status/hash matrix 不相容。'
        }
        Set-CodexHookAtomicFileBytesWithCapability `
            -Path ([string]$Profile.registryPath) `
            -Bytes ([byte[]]$backupSnapshot.bytes) `
            -ExpectedExists $true `
            -ExpectedSha256 ([string]$action.deployedSha256) `
            -AfterSha256 ([string]$action.beforeSha256) `
            -CapabilityRoot ([string]$Profile.codexHome) `
            -AllowedExactPaths @([string]$Profile.registryPath) `
            -Scope 'production external registry restore'
        if ($TestFaultInjection -ceq 'crash-after-registry-restore') {
            throw 'test-fault:crash-after-registry-restore'
        }
        $status.status = 'restored'
        $status.completedActionIds = @()
        Set-CodexHookCapabilityJson -Path ([string]$paths.statusPath) -Document $status -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @([string]$paths.statusPath) -Scope 'production restore status'
        return [pscustomobject][ordered]@{
            restored = $true
            noOp = $false
            generationId = $generationId
            terminalStatus = 'restored'
        }
    } finally {
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
