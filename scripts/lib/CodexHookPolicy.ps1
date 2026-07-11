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
    if ($Value.Length -gt 2 -and ($Value.Substring(2) -match '[:*?<>"|]' -or $Value.Substring(2) -match '[\x00-\x1f]')) {
        throw "$Name 包含 ADS、通配符或非法字符：$Value"
    }

    $fullPath = [IO.Path]::GetFullPath($Value)
    if ([IO.Path]::GetPathRoot($fullPath) -ine 'D:\') {
        throw "$Name 必须位于 D:\：$fullPath"
    }

    foreach ($segment in @($fullPath.Substring(3) -split '[\\/]' | Where-Object { $_ -ne '' })) {
        if (
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal) -or
            [IO.Path]::GetFileNameWithoutExtension($segment) -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
        ) {
            throw "$Name 包含 Windows 保留路径片段：$segment"
        }
    }

    return $fullPath
}

function Assert-CodexHookExactPath {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Assert-CodexHookDPath -Value $Value -Name $Name
    $expectedPath = [IO.Path]::GetFullPath($Expected)
    if (-not $fullPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name 必须严格等于 $expectedPath：$fullPath"
    }

    return $fullPath
}

function Test-CodexHookPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ParentPath
    )

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parent = [IO.Path]::GetFullPath($ParentPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return (
        $candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Assert-CodexHookRelativePath {
    param(
        [object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-CodexHookString -Value $Value -Name $Name
    if ([IO.Path]::IsPathRooted($Value) -or $Value -match '[:*?<>"|]' -or $Value -match '[\x00-\x1f]') {
        throw "$Name 必须是相对路径：$Value"
    }

    $segments = @($Value -split '[\\/]')
    if ($segments.Count -eq 0 -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
        throw "$Name 必须是规范的相对路径：$Value"
    }

    foreach ($segment in $segments) {
        if (
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal) -or
            [IO.Path]::GetFileNameWithoutExtension($segment) -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
        ) {
            throw "$Name 包含 Windows 保留路径片段：$segment"
        }
    }
}

function Get-CodexHookCommandIdentity {
    param([Parameter(Mandatory)][object]$Hook)

    $path = [IO.Path]::GetFullPath([string]$Hook.commandPath).ToLowerInvariant()
    $arguments = @($Hook.arguments | ForEach-Object { [string]$_ })
    $matcher = if ($null -eq $Hook.matcher) { '<null>' } else { [string]$Hook.matcher }
    return "$($Hook.event)`0$matcher`0$path`0$($arguments -join "`0")"
}

function Assert-CodexHookSafeArguments {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Arguments,
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($argument in $Arguments) {
        Assert-CodexHookString -Value $argument -Name "$Name[]" -AllowEmpty
        if (
            $argument -match '[\x00-\x1f\x7f]' -or
            $argument -match '(?i)\b(?:token|password|passwd|secret|credential|api[_-]?key)\s*=' -or
            $argument -match '(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@'
        ) {
            throw "$Name 包含控制字符或敏感值模式。"
        }
    }
}

function Assert-CodexHookResourceList {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Resources,
        [Parameter(Mandatory)][string]$Name
    )

    $abstractValues = @(
        'hook-stdin', 'hook-stdout', 'process-environment', 'windows-user-environment',
        'network', 'github-credential-store', 'codex-thread-state', 'serena-hook-state'
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($resource in $Resources) {
        Assert-CodexHookExactProperties -Value $resource -Names @('kind', 'value') -Scope "$Name[]"
        Assert-CodexHookString -Value $resource.kind -Name "$Name[].kind"
        Assert-CodexHookString -Value $resource.value -Name "$Name[].value"
        if ($resource.kind -ceq 'path') {
            $normalized = Assert-CodexHookDPath -Value $resource.value -Name "$Name[].value"
        } elseif ($resource.kind -ceq 'abstract' -and $resource.value -cin $abstractValues) {
            $normalized = [string]$resource.value
        } else {
            throw "$Name 资源 grammar 非法：$($resource.kind):$($resource.value)"
        }

        if (-not $seen.Add("$($resource.kind)`0$normalized")) {
            throw "$Name 包含重复资源：$($resource.value)"
        }
    }
}

function Assert-CodexHookDeclaredCommand {
    param(
        [Parameter(Mandatory)][object]$Command,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-CodexHookExactProperties -Value $Command -Names @('commandPath', 'arguments') -Scope $Name
    [void](Assert-CodexHookDPath -Value $Command.commandPath -Name "$Name.commandPath")
    Assert-CodexHookArray -Value ([object]$Command.arguments) -Name "$Name.arguments"
    Assert-CodexHookSafeArguments -Arguments @($Command.arguments) -Name "$Name.arguments"
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

    $codexHome = Assert-CodexHookExactPath -Value $Manifest.codexHome -Expected 'D:\Codex\.codex' -Name 'codexHome'
    [void](Assert-CodexHookExactPath -Value $Manifest.managedRoot -Expected 'D:\Codex\projects\统一环境\managed\codex-hooks' -Name 'managedRoot')

    $runtimeNames = @('pwsh', 'python', 'serenaPython', 'serenaHooks')
    $expectedRuntimes = [ordered]@{
        pwsh = 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe'
        python = 'D:\Codex\tools\python314-official\python.exe'
        serenaPython = 'D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe'
        serenaHooks = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
    }
    Assert-CodexHookExactProperties -Value $Manifest.runtimes -Names $runtimeNames -Scope 'runtimes'
    foreach ($name in $runtimeNames) {
        $runtimePath = Assert-CodexHookExactPath -Value $Manifest.runtimes.$name -Expected $expectedRuntimes[$name] -Name "runtimes.$name"
        if (-not [IO.File]::Exists($runtimePath)) {
            throw "runtimes.$name 不存在：$runtimePath"
        }
    }

    Assert-CodexHookArray -Value ([object]$Manifest.hooks) -Name 'hooks'
    Assert-CodexHookArray -Value ([object]$Manifest.files) -Name 'files'
    Assert-CodexHookArray -Value ([object]$Manifest.environment) -Name 'environment'

    $hookNames = @(
        'id', 'event', 'order', 'matcher', 'timeoutSeconds', 'commandPath', 'arguments',
        'wrapperPath', 'implementationPath', 'runtimeId', 'readResources', 'writeResources',
        'criticality', 'lifecycle', 'lifecycleReason', 'quickHealthCheck', 'fullAcceptanceCommand'
    )
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

        $commandPath = Assert-CodexHookDPath -Value $hook.commandPath -Name "hooks[$($hook.id)].commandPath"
        Assert-CodexHookArray -Value ([object]$hook.arguments) -Name "hooks[$($hook.id)].arguments"
        Assert-CodexHookSafeArguments -Arguments @($hook.arguments) -Name "hooks[$($hook.id)].arguments"

        if ($null -ne $hook.wrapperPath) {
            $wrapperPath = Assert-CodexHookDPath -Value $hook.wrapperPath -Name "hooks[$($hook.id)].wrapperPath"
            if (-not $wrapperPath.Equals($commandPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "hooks[$($hook.id)] custom wrapperPath 必须等于 commandPath。"
            }
        } else {
            $wrapperPath = $null
        }

        $implementationPath = Assert-CodexHookDPath -Value $hook.implementationPath -Name "hooks[$($hook.id)].implementationPath"
        Assert-CodexHookString -Value $hook.runtimeId -Name "hooks[$($hook.id)].runtimeId"
        if ($hook.runtimeId -cnotin $runtimeNames) {
            throw "hooks[$($hook.id)].runtimeId 非法：$($hook.runtimeId)"
        }

        $runtimePath = [IO.Path]::GetFullPath([string]$Manifest.runtimes.PSObject.Properties[$hook.runtimeId].Value)
        if ($null -eq $wrapperPath) {
            if (
                -not $commandPath.Equals($implementationPath, [StringComparison]::OrdinalIgnoreCase) -or
                -not $commandPath.Equals($runtimePath, [StringComparison]::OrdinalIgnoreCase)
            ) {
                throw "hooks[$($hook.id)] direct vendor entry 必须令 commandPath=implementationPath=runtime。"
            }
        } else {
            $expectedExtension = switch ($hook.runtimeId) {
                'pwsh' { '.ps1' }
                'python' { '.py' }
                'serenaPython' { '.py' }
                default { $null }
            }
            if ($null -eq $expectedExtension -or [IO.Path]::GetExtension($implementationPath) -ine $expectedExtension) {
                throw "hooks[$($hook.id)] implementation 与 runtimeId 类型不匹配。"
            }
            if (-not (Test-CodexHookPathWithin -Path $wrapperPath -ParentPath (Join-Path $codexHome 'hooks'))) {
                throw "hooks[$($hook.id)].wrapperPath 必须位于固定 live hooks 根。"
            }
            if ([IO.Path]::GetExtension($wrapperPath) -ine '.cmd') {
                throw "hooks[$($hook.id)].wrapperPath 必须是 .cmd wrapper。"
            }
            if (-not (Test-CodexHookPathWithin -Path $implementationPath -ParentPath (Join-Path $codexHome 'hooks'))) {
                throw "hooks[$($hook.id)].implementationPath 必须位于固定 live hooks 根。"
            }
        }

        Assert-CodexHookArray -Value ([object]$hook.readResources) -Name "hooks[$($hook.id)].readResources"
        Assert-CodexHookArray -Value ([object]$hook.writeResources) -Name "hooks[$($hook.id)].writeResources"
        Assert-CodexHookResourceList -Resources @($hook.readResources) -Name "hooks[$($hook.id)].readResources"
        Assert-CodexHookResourceList -Resources @($hook.writeResources) -Name "hooks[$($hook.id)].writeResources"

        Assert-CodexHookString -Value $hook.criticality -Name "hooks[$($hook.id)].criticality"
        if ($hook.criticality -notin @('critical', 'degraded', 'optional')) {
            throw "hook criticality 非法：$($hook.criticality)"
        }

        Assert-CodexHookString -Value $hook.lifecycle -Name "hooks[$($hook.id)].lifecycle"
        if ($hook.lifecycle -notin @('active', 'compatibility', 'retired')) {
            throw "hook lifecycle 非法：$($hook.lifecycle)"
        }
        if ($hook.lifecycle -ceq 'retired') {
            Assert-CodexHookString -Value $hook.lifecycleReason -Name "hooks[$($hook.id)].lifecycleReason"
        } elseif ($null -ne $hook.lifecycleReason) {
            throw "hooks[$($hook.id)].lifecycleReason 仅允许 retired hook 使用。"
        }

        Assert-CodexHookDeclaredCommand -Command $hook.quickHealthCheck -Name "hooks[$($hook.id)].quickHealthCheck"
        Assert-CodexHookDeclaredCommand -Command $hook.fullAcceptanceCommand -Name "hooks[$($hook.id)].fullAcceptanceCommand"
        $allowedAcceptanceCommands = @($commandPath) + @($expectedRuntimes.Values | ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
        foreach ($declaredCommand in @($hook.quickHealthCheck, $hook.fullAcceptanceCommand)) {
            $declaredPath = [IO.Path]::GetFullPath([string]$declaredCommand.commandPath)
            if (-not @($allowedAcceptanceCommands | Where-Object { $declaredPath.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                throw "hooks[$($hook.id)] health/acceptance commandPath 不在受管 wrapper/runtime allowlist。"
            }
        }
        if ($hook.lifecycle -cin @('active', 'compatibility')) {
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

    $environmentNames = @('name', 'scope', 'desired', 'restartRequired')
    $environmentNamesSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Manifest.environment)) {
        Assert-CodexHookExactProperties -Value $item -Names $environmentNames -Scope 'environment[]'
        Assert-CodexHookString -Value $item.name -Name 'environment[].name'
        Assert-CodexHookString -Value $item.scope -Name 'environment[].scope'
        if ($item.scope -cnotin @('User', 'Process')) {
            throw "environment[].scope 非法：$($item.scope)"
        }
        Assert-CodexHookString -Value $item.desired -Name 'environment[].desired' -AllowEmpty
        if ($item.restartRequired -isnot [bool]) {
            throw 'environment[].restartRequired 必须是 JSON boolean。'
        }
        if (-not $environmentNamesSeen.Add("$($item.name)`0$($item.scope)")) {
            throw "environment name/scope 重复：$($item.name)/$($item.scope)"
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

function Get-CodexHookTextSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Split-CodexHookCommandLine {
    param([Parameter(Mandatory)][string]$Command)

    $tokens = [Collections.Generic.List[string]]::new()
    $index = 0
    while ($index -lt $Command.Length) {
        while ($index -lt $Command.Length -and [char]::IsWhiteSpace($Command[$index])) { $index++ }
        if ($index -ge $Command.Length) { break }

        $value = [Text.StringBuilder]::new()
        $inQuotes = $false
        while ($index -lt $Command.Length) {
            $character = $Command[$index]
            if ($character -eq '"') {
                $inQuotes = -not $inQuotes
                $index++
                continue
            }
            if (-not $inQuotes -and [char]::IsWhiteSpace($character)) { break }
            [void]$value.Append($character)
            $index++
        }
        if ($inQuotes) {
            return [pscustomobject]@{ parsed = $false; tokens = @() }
        }
        $tokens.Add($value.ToString())
    }

    return [pscustomobject]@{ parsed = ($tokens.Count -gt 0); tokens = [string[]]$tokens.ToArray() }
}

function Get-CodexHookManifestMatches {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$Event,
        [AllowNull()][object]$Matcher,
        [Parameter(Mandatory)][string[]]$Tokens,
        [Parameter(Mandatory)][bool]$IsCommandEntry
    )

    if (-not $IsCommandEntry -or $Tokens.Count -eq 0 -or $Tokens[0] -notmatch '^[dD]:[\\/]') {
        return
    }
    try {
        $targetPath = [IO.Path]::GetFullPath($Tokens[0].Replace('/', '\'))
    } catch {
        return
    }
    [string[]]$arguments = @()
    if ($Tokens.Count -gt 1) {
        $arguments = [string[]]@($Tokens | Select-Object -Skip 1)
    }

    return @(
        foreach ($hook in @($Manifest.hooks)) {
            $matcherMatches = (
                ($null -eq $Matcher -and $null -eq $hook.matcher) -or
                ($null -ne $Matcher -and $null -ne $hook.matcher -and [string]::Equals([string]$Matcher, [string]$hook.matcher, [StringComparison]::Ordinal))
            )
            if (-not $matcherMatches -or -not [string]::Equals($Event, [string]$hook.event, [StringComparison]::Ordinal)) { continue }
            if (-not $targetPath.Equals([IO.Path]::GetFullPath([string]$hook.commandPath), [StringComparison]::OrdinalIgnoreCase)) { continue }
            $expectedArguments = [string[]]@($hook.arguments)
            if ($arguments.Count -ne $expectedArguments.Count) { continue }
            $argumentsMatch = $true
            for ($i = 0; $i -lt $arguments.Count; $i++) {
                if (-not [string]::Equals($arguments[$i], $expectedArguments[$i], [StringComparison]::Ordinal)) {
                    $argumentsMatch = $false
                    break
                }
            }
            if ($argumentsMatch) { $hook }
        }
    )
}

function Get-CodexHookRegistryFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][object]$Manifest
    )

    [void](Assert-CodexHookManifest -Manifest $Manifest)

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

    $events = [ordered]@{ SessionStart = @(); Stop = @(); PreToolUse = @(); Unknown = @() }
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
            $entryIndex = 0
            foreach ($entry in @($group.hooks)) {
                if ($null -eq $entry -or $entry.PSObject.Properties.Name -notcontains 'command') {
                    $entryIndex++
                    continue
                }

                $command = [string]$entry.command
                $timeout = if ($entry.PSObject.Properties.Name -contains 'timeout') { $entry.timeout } else { $null }
                $parsed = Split-CodexHookCommandLine -Command $command
                $entryType = if ($entry.PSObject.Properties.Name -contains 'type') { [string]$entry.type } else { $null }
                $timeoutIsInteger = $timeout -is [sbyte] -or $timeout -is [byte] -or $timeout -is [int16] -or $timeout -is [uint16] -or $timeout -is [int32] -or $timeout -is [uint32] -or $timeout -is [int64] -or $timeout -is [uint64]
                [object[]]$manifestMatches = @()
                if ($parsed.parsed) {
                    $manifestMatches = [object[]]@(Get-CodexHookManifestMatches -Manifest $Manifest -Event $eventName -Matcher $matcher -Tokens $parsed.tokens -IsCommandEntry ($entryType -ceq 'command') | Where-Object { $null -ne $_ })
                }
                $matchedHook = if ($manifestMatches.Count -eq 1) { $manifestMatches[0] } else { $null }
                $targetExists = $null
                $commandSha256 = $null
                $targetPath = $null
                if ($null -ne $matchedHook) {
                    $targetPath = [IO.Path]::GetFullPath([string]$matchedHook.commandPath)
                    $targetExists = [IO.File]::Exists($targetPath)
                    if ($targetExists) {
                        $commandSha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    }
                }

                $pathPolicy = if ($null -ne $matchedHook) { 'manifest-allowlisted' } elseif (-not $parsed.parsed) {
                    'unparsed'
                } elseif ($parsed.tokens[0] -match '^(?:\\\\|\\\?|\\\.)') {
                    'forbidden-unc-or-device'
                } elseif ($parsed.tokens[0] -match '^[dD]:[\\/]') {
                    'unmatched-d-path'
                } elseif ([IO.Path]::IsPathRooted($parsed.tokens[0])) {
                    'outside-d-path'
                } else {
                    'relative-path'
                }

                $eventFacts.Add([pscustomobject][ordered]@{
                    event = if ($eventName -cin @('SessionStart', 'Stop', 'PreToolUse')) { $eventName } else { 'Unknown' }
                    groupIndex = $groupIndex
                    entryIndex = $entryIndex
                    matcher = if ($null -ne $matchedHook) { $matchedHook.matcher } else { $null }
                    matcherPresent = $null -ne $matcher
                    timeout = if ($timeoutIsInteger) { $timeout } else { $null }
                    timeoutPresent = $null -ne $timeout
                    entryType = if ($entryType -ceq 'command') { 'command' } elseif ([string]::IsNullOrWhiteSpace($entryType)) { 'missing' } else { 'other' }
                    pathPolicy = $pathPolicy
                    targetPath = $targetPath
                    targetExists = $targetExists
                    commandSha256 = $commandSha256
                    commandIdentitySha256 = Get-CodexHookTextSha256 -Text $command
                    argumentCount = if ($parsed.parsed) { [Math]::Max(0, $parsed.tokens.Count - 1) } else { $null }
                    idMatch = if ($null -ne $matchedHook) { $matchedHook.id } else { $null }
                    idMatchStatus = if (-not $parsed.parsed) { 'unparsed' } elseif ($manifestMatches.Count -gt 1) { 'ambiguous' } elseif ($manifestMatches.Count -eq 1) { 'matched' } else { 'unmatched' }
                    lifecycleMatch = if ($null -ne $matchedHook) { $matchedHook.lifecycle } else { $null }
                    registrationState = if ($null -ne $matchedHook -and $matchedHook.lifecycle -ceq 'retired') { 'retired-but-registered' } elseif ($null -ne $matchedHook) { 'declared' } else { 'unknown' }
                })
                $entryIndex++
            }
        }

        $bucket = if ($eventName -cin @('SessionStart', 'Stop', 'PreToolUse')) { $eventName } else { 'Unknown' }
        $events[$bucket] = [object[]]@($events[$bucket]) + [object[]]$eventFacts.ToArray()
    }

    return [pscustomobject][ordered]@{
        events = [pscustomobject]$events
    }
}

function Get-CodexHookDependencyFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest)

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    foreach ($hook in @($Manifest.hooks)) {
        $wrapperPath = if ($null -ne $hook.wrapperPath) { [IO.Path]::GetFullPath([string]$hook.wrapperPath) } else { $null }
        $implementationPath = [IO.Path]::GetFullPath([string]$hook.implementationPath)
        $runtimePath = [IO.Path]::GetFullPath([string]$Manifest.runtimes.PSObject.Properties[$hook.runtimeId].Value)
        $wrapperExists = if ($null -ne $wrapperPath) { [IO.File]::Exists($wrapperPath) } else { $null }
        $implementationExists = [IO.File]::Exists($implementationPath)
        $runtimeExists = [IO.File]::Exists($runtimePath)
        $wrapperText = if ($wrapperExists) { [IO.File]::ReadAllText($wrapperPath) } else { $null }
        $normalizedWrapperText = if ($null -ne $wrapperText) { $wrapperText.Replace('/', '\') } else { $null }

        [pscustomobject][ordered]@{
            id = $hook.id
            entrypointKind = if ($null -eq $wrapperPath) { 'direct-vendor' } else { 'wrapper' }
            wrapperPath = $wrapperPath
            wrapperExists = $wrapperExists
            wrapperSha256 = if ($wrapperExists) { (Get-FileHash -LiteralPath $wrapperPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
            implementationPath = $implementationPath
            implementationExists = $implementationExists
            implementationSha256 = if ($implementationExists) { (Get-FileHash -LiteralPath $implementationPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
            runtimeId = $hook.runtimeId
            runtimePath = $runtimePath
            runtimeExists = $runtimeExists
            runtimeSha256 = if ($runtimeExists) { (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
            wrapperReferencesImplementation = if ($null -eq $wrapperPath) { $null } elseif ($wrapperExists) { $normalizedWrapperText.IndexOf($implementationPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 } else { $false }
            wrapperReferencesRuntime = if ($null -eq $wrapperPath) { $null } elseif ($wrapperExists) { $normalizedWrapperText.IndexOf($runtimePath, [StringComparison]::OrdinalIgnoreCase) -ge 0 } else { $false }
            readResourceCount = @($hook.readResources).Count
            writeResourceCount = @($hook.writeResources).Count
            dependencyState = if ($null -eq $wrapperPath) {
                if ($implementationExists -and $runtimeExists) { 'ready' } else { 'pending' }
            } elseif ($wrapperExists -and $implementationExists -and $runtimeExists -and
                $normalizedWrapperText.IndexOf($implementationPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $normalizedWrapperText.IndexOf($runtimePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                'ready'
            } else {
                'pending-or-mismatched'
            }
        }
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
        if (-not (Test-CodexHookPathWithin -Path $managedPath -ParentPath $managedRootPath)) {
            throw "managed file 逃逸固定根：$($file.relativePath)"
        }
        if (-not (Test-CodexHookPathWithin -Path $livePath -ParentPath $liveHooksRootPath)) {
            throw "live file 逃逸固定根：$($file.liveRelativePath)"
        }
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
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DependencyFacts,
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
        if ([string]::IsNullOrWhiteSpace([string]$entry.commandIdentitySha256)) {
            continue
        }

        $key = [string]$entry.commandIdentitySha256
        if (-not $commandCounts.ContainsKey($key)) {
            $commandCounts[$key] = 0
        }
        $commandCounts[$key]++
    }

    $sanitizedTrust = @(
        foreach ($observation in @($TrustObservation)) {
            [pscustomobject][ordered]@{
                section = if ($observation.PSObject.Properties.Name -contains 'section') { [string]$observation.section } else { $null }
                keyKind = if ($observation.PSObject.Properties.Name -contains 'keyKind') { [string]$observation.keyKind } else { 'unknown' }
                keyNameSha256 = if ($observation.PSObject.Properties.Name -contains 'keyNameSha256') { [string]$observation.keyNameSha256 } else { $null }
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
        dependencyFacts = [object[]]@($DependencyFacts)
        trustObservation = [object[]]$sanitizedTrust
        summary = [pscustomobject][ordered]@{
            eventCount = @($Registry.events.PSObject.Properties).Count
            registryEntryCount = $entries.Count
            missingTargetCount = @($entries | Where-Object { $null -ne $_.targetExists -and -not $_.targetExists }).Count
            unprobedTargetCount = @($entries | Where-Object { $null -eq $_.targetExists }).Count
            duplicateCommandCount = $duplicateCommandCount
            managedMissingCount = @($FileFacts | Where-Object { -not $_.managedExists }).Count
            liveMissingCount = @($FileFacts | Where-Object { -not $_.liveExists }).Count
            dependencyGapCount = @($DependencyFacts | Where-Object { $_.dependencyState -cne 'ready' }).Count
            retiredButRegisteredCount = @($entries | Where-Object registrationState -ceq 'retired-but-registered').Count
            trustObservationCount = $sanitizedTrust.Count
        }
    }
}
