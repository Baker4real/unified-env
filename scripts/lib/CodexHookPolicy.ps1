Set-StrictMode -Version Latest

function Assert-CodexHookJsonElementUniqueProperties {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [string]$Path = '$'
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) {
                throw "重复 JSON 属性：$Path.$($property.Name)"
            }

            Assert-CodexHookJsonElementUniqueProperties -Element $property.Value -Path "$Path.$($property.Name)"
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-CodexHookJsonElementUniqueProperties -Element $item -Path "$Path[$index]"
            $index++
        }
    }
}

function Assert-CodexHookStrictJsonText {
    param([Parameter(Mandatory)][string]$JsonText)

    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 128
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($JsonText, $options)
    } catch {
        throw "严格 JSON 词法校验失败：$($_.Exception.Message)"
    }

    try {
        Assert-CodexHookJsonElementUniqueProperties -Element $document.RootElement
    } finally {
        $document.Dispose()
    }
}

function Assert-CodexHookExactProperties {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [array] -or $Value.GetType().IsPrimitive) {
        throw "$Scope 必须是 JSON object。"
    }

    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) {
        throw "$Scope 属性集合不精确：expected=$($Names -join ','), actual=$($actual -join ',')"
    }

    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Names) {
        [void]$expected.Add($name)
    }

    foreach ($name in $actual) {
        if (-not $expected.Remove($name)) {
            throw "$Scope 包含未知或重复属性：$name"
        }
    }

    if ($expected.Count -ne 0) {
        throw "$Scope 缺少属性：$(@($expected) -join ',')"
    }
}

function Assert-CodexHookString {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowEmpty
    )

    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "$Name 必须是 JSON string。"
    }
}

function Assert-CodexHookInteger {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if (
        $Value -isnot [sbyte] -and $Value -isnot [byte] -and
        $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64]
    ) {
        throw "$Name 必须是 JSON integer。"
    }
}

function Assert-CodexHookArray {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -isnot [array]) {
        throw "$Name 必须是 JSON array。"
    }
}

function Assert-CodexHookDPath {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-CodexHookString -Value $Value -Name $Name
    if (-not [IO.Path]::IsPathFullyQualified($Value)) {
        throw "$Name 必须是 D 盘绝对路径：$Value"
    }

    $fullPath = [IO.Path]::GetFullPath($Value)
    if ([IO.Path]::GetPathRoot($fullPath) -ine 'D:\') {
        throw "$Name 必须位于 D:\：$fullPath"
    }

    return $fullPath
}

function Assert-CodexHookRelativePath {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-CodexHookString -Value $Value -Name $Name
    if ([IO.Path]::IsPathFullyQualified($Value)) {
        throw "$Name 必须是相对路径：$Value"
    }

    $segments = @($Value -split '[\\/]')
    if ($segments.Count -eq 0 -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
        throw "$Name 必须是规范的相对路径：$Value"
    }
}

function Get-CodexHookCommandIdentity {
    param([Parameter(Mandatory)][object]$Hook)

    $path = [IO.Path]::GetFullPath([string]$Hook.commandPath).ToLowerInvariant()
    $arguments = @($Hook.arguments | ForEach-Object { [string]$_ })
    return "$path`0$($arguments -join "`0")"
}

function Assert-CodexHookManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest)

    $topNames = @('artifactType', 'schemaVersion', 'codexHome', 'managedRoot', 'runtimes', 'hooks', 'files', 'environment')
    Assert-CodexHookExactProperties -Value $Manifest -Names $topNames -Scope 'manifest'

    Assert-CodexHookString -Value $Manifest.artifactType -Name 'artifactType'
    if ($Manifest.artifactType -cne 'env-governance.codex-hook-manifest') {
        throw 'artifactType 必须严格等于 env-governance.codex-hook-manifest。'
    }

    Assert-CodexHookInteger -Value $Manifest.schemaVersion -Name 'schemaVersion'
    if ([int64]$Manifest.schemaVersion -ne 1) {
        throw 'schemaVersion 必须严格等于 1。'
    }

    [void](Assert-CodexHookDPath -Value $Manifest.codexHome -Name 'codexHome')
    [void](Assert-CodexHookDPath -Value $Manifest.managedRoot -Name 'managedRoot')

    $runtimeNames = @('pwsh', 'python', 'serenaPython', 'serenaHooks')
    Assert-CodexHookExactProperties -Value $Manifest.runtimes -Names $runtimeNames -Scope 'runtimes'
    foreach ($name in $runtimeNames) {
        $runtimePath = Assert-CodexHookDPath -Value $Manifest.runtimes.$name -Name "runtimes.$name"
        if (-not [IO.File]::Exists($runtimePath)) {
            throw "runtimes.$name 不存在：$runtimePath"
        }
    }

    Assert-CodexHookArray -Value ([object]$Manifest.hooks) -Name 'hooks'
    Assert-CodexHookArray -Value ([object]$Manifest.files) -Name 'files'
    Assert-CodexHookArray -Value ([object]$Manifest.environment) -Name 'environment'

    $hookNames = @('id', 'event', 'order', 'matcher', 'timeoutSeconds', 'commandPath', 'arguments', 'criticality', 'lifecycle', 'healthCheck')
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $activeCommands = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $activeOrders = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($hook in @($Manifest.hooks)) {
        Assert-CodexHookExactProperties -Value $hook -Names $hookNames -Scope 'hooks[]'
        Assert-CodexHookString -Value $hook.id -Name 'hooks[].id'
        if ($hook.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or -not $ids.Add($hook.id)) {
            throw "hook id 非法或重复：$($hook.id)"
        }

        Assert-CodexHookString -Value $hook.event -Name "hooks[$($hook.id)].event"
        if ($hook.event -notin @('SessionStart', 'Stop', 'PreToolUse')) {
            throw "hook event 非法：$($hook.event)"
        }

        Assert-CodexHookInteger -Value $hook.order -Name "hooks[$($hook.id)].order"
        if ([int64]$hook.order -lt 0) {
            throw "hook order 不得小于 0：$($hook.id)"
        }

        if ($null -ne $hook.matcher -and $hook.matcher -isnot [string]) {
            throw "hooks[$($hook.id)].matcher 必须是 JSON string 或 null。"
        }

        Assert-CodexHookInteger -Value $hook.timeoutSeconds -Name "hooks[$($hook.id)].timeoutSeconds"
        if ([int64]$hook.timeoutSeconds -le 0 -or [int64]$hook.timeoutSeconds -ge 30) {
            throw "hook timeoutSeconds 必须大于 0 且小于 30：$($hook.id)"
        }

        [void](Assert-CodexHookDPath -Value $hook.commandPath -Name "hooks[$($hook.id)].commandPath")
        Assert-CodexHookArray -Value ([object]$hook.arguments) -Name "hooks[$($hook.id)].arguments"
        foreach ($argument in @($hook.arguments)) {
            Assert-CodexHookString -Value $argument -Name "hooks[$($hook.id)].arguments[]" -AllowEmpty
        }

        Assert-CodexHookString -Value $hook.criticality -Name "hooks[$($hook.id)].criticality"
        if ($hook.criticality -notin @('critical', 'degraded', 'optional')) {
            throw "hook criticality 非法：$($hook.criticality)"
        }

        Assert-CodexHookString -Value $hook.lifecycle -Name "hooks[$($hook.id)].lifecycle"
        if ($hook.lifecycle -notin @('active', 'compatibility', 'retired')) {
            throw "hook lifecycle 非法：$($hook.lifecycle)"
        }

        Assert-CodexHookString -Value $hook.healthCheck -Name "hooks[$($hook.id)].healthCheck"
        if ($hook.lifecycle -ceq 'active') {
            $identity = Get-CodexHookCommandIdentity -Hook $hook
            if (-not $activeCommands.Add($identity)) {
                throw "active hook command 重复：$($hook.id)"
            }

            $orderIdentity = "$($hook.event)`0$($hook.order)"
            if (-not $activeOrders.Add($orderIdentity)) {
                throw "active hook event/order 重复：$($hook.event)[$($hook.order)]"
            }
        }
    }

    $fileNames = @('relativePath', 'liveRelativePath', 'sha256', 'lifecycle', 'ownerHookIds')
    $relativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $liveRelativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Manifest.files)) {
        Assert-CodexHookExactProperties -Value $file -Names $fileNames -Scope 'files[]'
        Assert-CodexHookRelativePath -Value $file.relativePath -Name 'files[].relativePath'
        Assert-CodexHookRelativePath -Value $file.liveRelativePath -Name 'files[].liveRelativePath'
        if (-not $relativePaths.Add($file.relativePath) -or -not $liveRelativePaths.Add($file.liveRelativePath)) {
            throw "manifest file 路径重复：$($file.relativePath)"
        }

        Assert-CodexHookString -Value $file.sha256 -Name "files[$($file.relativePath)].sha256"
        if ($file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "files[$($file.relativePath)].sha256 必须是 lowercase SHA-256。"
        }

        Assert-CodexHookString -Value $file.lifecycle -Name "files[$($file.relativePath)].lifecycle"
        if ($file.lifecycle -notin @('active', 'compatibility', 'retired')) {
            throw "file lifecycle 非法：$($file.lifecycle)"
        }

        Assert-CodexHookArray -Value ([object]$file.ownerHookIds) -Name "files[$($file.relativePath)].ownerHookIds"
        $owners = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($ownerId in @($file.ownerHookIds)) {
            Assert-CodexHookString -Value $ownerId -Name "files[$($file.relativePath)].ownerHookIds[]"
            if (-not $ids.Contains($ownerId) -or -not $owners.Add($ownerId)) {
                throw "file ownerHookId 未声明或重复：$ownerId"
            }
        }
    }

    return $true
}

function Read-CodexHookManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-CodexHookDPath -Value $Path -Name 'Path'
    if (-not [IO.File]::Exists($fullPath)) {
        throw "manifest 不存在：$fullPath"
    }

    $jsonText = [IO.File]::ReadAllText($fullPath)
    Assert-CodexHookStrictJsonText -JsonText $jsonText
    $manifest = $jsonText | ConvertFrom-Json -Depth 128 -ErrorAction Stop
    [void](Assert-CodexHookManifest -Manifest $manifest)
    return $manifest
}

function Resolve-CodexHookCommandTarget {
    param([Parameter(Mandatory)][string]$Command)

    $match = [regex]::Match($Command, '^\s*"(?<target>[^"]+)"(?<arguments>.*)$')
    if (-not $match.Success) {
        $match = [regex]::Match($Command, '^\s*(?<target>\S+)(?<arguments>.*)$')
    }

    if (-not $match.Success) {
        return [pscustomobject]@{
            path = $null
            argumentsText = ''
        }
    }

    $target = $match.Groups['target'].Value.Replace('/', '\')
    return [pscustomobject]@{
        path = $target
        argumentsText = $match.Groups['arguments'].Value.Trim()
    }
}

function Get-CodexHookIdMatch {
    param(
        [string]$TargetPath,
        [Parameter(Mandatory)][string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return $null
    }

    switch ([IO.Path]::GetFileName($TargetPath).ToLowerInvariant()) {
        'codex-provider-stability-guard.cmd' { return 'provider-stability' }
        'codex-github-cli-guard.cmd' { return 'github-cli' }
        'codex-projectless-root-d.cmd' { return 'codex-state-policy' }
        'serena-activate-guarded.cmd' { return 'serena-activate' }
        'serena-dashboard-guard.cmd' { return 'serena-dashboard' }
        'serena-hooks.exe' {
            if ($Command -match '(?i)(?:^|\s)cleanup(?:\s|$)') { return 'serena-cleanup' }
            if ($Command -match '(?i)(?:^|\s)remind(?:\s|$)') { return 'serena-reminder' }
            if ($Command -match '(?i)(?:^|\s)auto-approve(?:\s|$)') { return 'serena-auto-approve' }
        }
    }

    return $null
}

function Get-CodexHookRegistryFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)

    $fullPath = Assert-CodexHookDPath -Value $RegistryPath -Name 'RegistryPath'
    if (-not [IO.File]::Exists($fullPath)) {
        throw "hook registry 不存在：$fullPath"
    }

    $jsonText = [IO.File]::ReadAllText($fullPath)
    Assert-CodexHookStrictJsonText -JsonText $jsonText
    $registry = $jsonText | ConvertFrom-Json -Depth 128 -ErrorAction Stop
    if ($registry.PSObject.Properties.Name -notcontains 'hooks' -or $null -eq $registry.hooks) {
        throw 'hook registry 缺少 hooks object。'
    }

    $events = [ordered]@{}
    foreach ($eventProperty in $registry.hooks.PSObject.Properties) {
        $eventName = [string]$eventProperty.Name
        $eventFacts = [Collections.Generic.List[object]]::new()
        $groups = @($eventProperty.Value)
        for ($groupIndex = 0; $groupIndex -lt $groups.Count; $groupIndex++) {
            $group = $groups[$groupIndex]
            if ($null -eq $group -or $group.PSObject.Properties.Name -notcontains 'hooks') {
                continue
            }

            $matcher = if ($group.PSObject.Properties.Name -contains 'matcher') { $group.matcher } else { $null }
            foreach ($entry in @($group.hooks)) {
                if ($null -eq $entry -or $entry.PSObject.Properties.Name -notcontains 'command') {
                    continue
                }

                $command = [string]$entry.command
                $timeout = if ($entry.PSObject.Properties.Name -contains 'timeout') { $entry.timeout } else { $null }
                $target = Resolve-CodexHookCommandTarget -Command $command
                $targetExists = $false
                $commandSha256 = $null
                if (-not [string]::IsNullOrWhiteSpace($target.path) -and [IO.Path]::IsPathFullyQualified($target.path)) {
                    $targetExists = [IO.File]::Exists($target.path)
                    if ($targetExists) {
                        $commandSha256 = (Get-FileHash -LiteralPath $target.path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    }
                }

                $eventFacts.Add([pscustomobject][ordered]@{
                    event = $eventName
                    index = $groupIndex
                    matcher = $matcher
                    command = $command
                    timeout = $timeout
                    targetExists = $targetExists
                    commandSha256 = $commandSha256
                    idMatch = Get-CodexHookIdMatch -TargetPath $target.path -Command $command
                })
            }
        }

        $events[$eventName] = [object[]]$eventFacts.ToArray()
    }

    return [pscustomobject][ordered]@{
        events = [pscustomobject]$events
    }
}

function Get-CodexHookFileFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManagedRoot,
        [Parameter(Mandatory)][string]$LiveHooksRoot
    )

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    $managedRootPath = Assert-CodexHookDPath -Value $ManagedRoot -Name 'ManagedRoot'
    $liveHooksRootPath = Assert-CodexHookDPath -Value $LiveHooksRoot -Name 'LiveHooksRoot'

    foreach ($file in @($Manifest.files)) {
        $managedPath = [IO.Path]::GetFullPath((Join-Path $managedRootPath $file.relativePath))
        $livePath = [IO.Path]::GetFullPath((Join-Path $liveHooksRootPath $file.liveRelativePath))
        $managedExists = [IO.File]::Exists($managedPath)
        $liveExists = [IO.File]::Exists($livePath)
        $managedSha256 = if ($managedExists) {
            (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        } else {
            $null
        }
        $liveSha256 = if ($liveExists) {
            (Get-FileHash -LiteralPath $livePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        } else {
            $null
        }

        [pscustomobject][ordered]@{
            relativePath = $file.relativePath
            liveRelativePath = $file.liveRelativePath
            lifecycle = $file.lifecycle
            declaredSha256 = $file.sha256
            managedExists = $managedExists
            managedSha256 = $managedSha256
            managedMatchesManifest = $managedExists -and $managedSha256 -ceq $file.sha256
            liveExists = $liveExists
            liveSha256 = $liveSha256
            liveMatchesManifest = $liveExists -and $liveSha256 -ceq $file.sha256
        }
    }
}

function New-CodexHookInventoryDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Registry,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FileFacts,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$TrustObservation
    )

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    if ($Registry.PSObject.Properties.Name -notcontains 'events') {
        throw 'Registry facts 缺少 events。'
    }

    $entries = @(
        foreach ($eventProperty in $Registry.events.PSObject.Properties) {
            @($eventProperty.Value)
        }
    )
    $commandCounts = @{}
    foreach ($entry in $entries) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.command)) {
            continue
        }

        $key = ([string]$entry.command).ToLowerInvariant()
        if (-not $commandCounts.ContainsKey($key)) {
            $commandCounts[$key] = 0
        }
        $commandCounts[$key]++
    }

    $sanitizedTrust = @(
        foreach ($observation in @($TrustObservation)) {
            [pscustomobject][ordered]@{
                section = if ($observation.PSObject.Properties.Name -contains 'section') { [string]$observation.section } else { $null }
                keyName = if ($observation.PSObject.Properties.Name -contains 'keyName') { [string]$observation.keyName } else { $null }
                present = if ($observation.PSObject.Properties.Name -contains 'present') { [bool]$observation.present } else { $true }
            }
        }
    )

    $duplicateCommandCount = @($commandCounts.GetEnumerator() | Where-Object Value -gt 1).Count
    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-inventory'
        schemaVersion = 1
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        readOnly = $true
        executionAllowed = $false
        manifest = [pscustomobject][ordered]@{
            artifactType = $Manifest.artifactType
            schemaVersion = $Manifest.schemaVersion
            codexHome = $Manifest.codexHome
            managedRoot = $Manifest.managedRoot
            hookCount = @($Manifest.hooks).Count
            fileCount = @($Manifest.files).Count
        }
        registry = $Registry
        fileFacts = [object[]]@($FileFacts)
        trustObservation = [object[]]$sanitizedTrust
        summary = [pscustomobject][ordered]@{
            eventCount = @($Registry.events.PSObject.Properties).Count
            registryEntryCount = $entries.Count
            missingTargetCount = @($entries | Where-Object { -not $_.targetExists }).Count
            duplicateCommandCount = $duplicateCommandCount
            managedMissingCount = @($FileFacts | Where-Object { -not $_.managedExists }).Count
            liveMissingCount = @($FileFacts | Where-Object { -not $_.liveExists }).Count
            trustObservationCount = $sanitizedTrust.Count
        }
    }
}
