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

function Get-CodexHookSafeFileProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$AllowedExactPaths = @(),
        [string[]]$AllowedRoots = @()
    )

    $fullPath = Assert-CodexHookDPath -Value $Path -Name $Name
    $isAllowlisted = $false
    foreach ($allowedPath in $AllowedExactPaths) {
        $normalizedAllowedPath = Assert-CodexHookDPath -Value $allowedPath -Name "$Name allowlisted path"
        if ($fullPath.Equals($normalizedAllowedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $isAllowlisted = $true
            break
        }
    }
    if (-not $isAllowlisted) {
        foreach ($allowedRoot in $AllowedRoots) {
            $normalizedAllowedRoot = Assert-CodexHookDPath -Value $allowedRoot -Name "$Name allowlisted root"
            if (Test-CodexHookPathWithin -Path $fullPath -ParentPath $normalizedAllowedRoot) {
                $isAllowlisted = $true
                break
            }
        }
    }
    if (-not $isAllowlisted) {
        throw "$Name 不在固定 probe allowlist：$fullPath"
    }

    $root = [IO.Path]::GetPathRoot($fullPath)
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject][ordered]@{
            path = $fullPath
            exists = $null
            safeToRead = $false
            state = 'reparse-blocked'
            byteLength = $null
            blockedAtSha256 = Get-CodexHookTextSha256 -Text $root
        }
    }
    $segments = @($fullPath.Substring($root.Length) -split '[\\/]' | Where-Object { $_ -ne '' })
    $currentPath = $root
    $lastItem = $null
    for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
        $currentPath = Join-Path $currentPath $segments[$segmentIndex]
        try {
            $lastItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        } catch [System.Management.Automation.ItemNotFoundException] {
            return [pscustomobject][ordered]@{
                path = $fullPath
                exists = $false
                safeToRead = $false
                state = 'missing'
                byteLength = $null
                blockedAtSha256 = $null
            }
        }

        if (($lastItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject][ordered]@{
                path = $fullPath
                exists = $null
                safeToRead = $false
                state = 'reparse-blocked'
                byteLength = $null
                blockedAtSha256 = Get-CodexHookTextSha256 -Text $currentPath
            }
        }

        $isFinalSegment = $segmentIndex -eq ($segments.Count - 1)
        if (-not $isFinalSegment -and -not $lastItem.PSIsContainer) {
            return [pscustomobject][ordered]@{
                path = $fullPath
                exists = $false
                safeToRead = $false
                state = 'non-directory-ancestor'
                byteLength = $null
                blockedAtSha256 = Get-CodexHookTextSha256 -Text $currentPath
            }
        }
    }

    if ($null -eq $lastItem -or $lastItem.PSIsContainer -or $lastItem -isnot [IO.FileInfo]) {
        return [pscustomobject][ordered]@{
            path = $fullPath
            exists = $null -ne $lastItem
            safeToRead = $false
            state = 'not-regular-file'
            byteLength = $null
            blockedAtSha256 = $null
        }
    }

    return [pscustomobject][ordered]@{
        path = $fullPath
        exists = $true
        safeToRead = $true
        state = 'regular-file'
        byteLength = [int64]$lastItem.Length
        blockedAtSha256 = $null
    }
}

function Read-CodexHookSafeTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$AllowedExactPaths = @(),
        [string[]]$AllowedRoots = @()
    )

    $probe = Get-CodexHookSafeFileProbe -Path $Path -Name $Name -AllowedExactPaths $AllowedExactPaths -AllowedRoots $AllowedRoots
    if (-not $probe.safeToRead) {
        throw "$Name 无法安全读取：state=$($probe.state)"
    }

    return [IO.File]::ReadAllText($probe.path)
}

function Get-CodexHookSafeFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$AllowedExactPaths = @(),
        [string[]]$AllowedRoots = @()
    )

    $probe = Get-CodexHookSafeFileProbe -Path $Path -Name $Name -AllowedExactPaths $AllowedExactPaths -AllowedRoots $AllowedRoots
    if (-not $probe.safeToRead) {
        return [pscustomobject][ordered]@{
            probe = $probe
            sha256 = $null
        }
    }

    return [pscustomobject][ordered]@{
        probe = $probe
        sha256 = (Get-FileHash -LiteralPath $probe.path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
}

function Read-CodexHookSafeUtf8FileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$AllowedExactPaths = @(),
        [string[]]$AllowedRoots = @()
    )

    $probe = Get-CodexHookSafeFileProbe -Path $Path -Name $Name -AllowedExactPaths $AllowedExactPaths -AllowedRoots $AllowedRoots
    if (-not $probe.safeToRead) {
        throw "$Name 无法安全读取 snapshot：state=$($probe.state)"
    }

    $bytes = [IO.File]::ReadAllBytes($probe.path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $sha256 = [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf
    try {
        $text = if ($hasBom) { $utf8.GetString($bytes, 3, $bytes.Length - 3) } else { $utf8.GetString($bytes) }
    } catch {
        throw "$Name 不是严格 UTF-8：$($_.Exception.Message)"
    }

    return [pscustomobject][ordered]@{
        probe = $probe
        byteLength = [int64]$bytes.Length
        sha256 = $sha256
        text = $text
    }
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

function Get-CodexHookNormalizedRelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-CodexHookRelativePath -Value $Path -Name $Name
    return (($Path -split '[\\/]') -join '\')
}

function Get-CodexHookCommandIdentity {
    param([Parameter(Mandatory)][object]$Hook)

    $path = [IO.Path]::GetFullPath([string]$Hook.commandPath).ToLowerInvariant()
    $arguments = @($Hook.arguments | ForEach-Object { [string]$_ })
    $matcher = if ($null -eq $Hook.matcher) { '<null>' } else { [string]$Hook.matcher }
    return "$($Hook.event)`0$matcher`0$path`0$($arguments -join "`0")"
}

function Test-CodexHookExactStringSequence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected
    )

    if ($Actual.Count -ne $Expected.Count) { return $false }
    for ($itemIndex = 0; $itemIndex -lt $Actual.Count; $itemIndex++) {
        if (-not [string]::Equals([string]$Actual[$itemIndex], [string]$Expected[$itemIndex], [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Assert-CodexHookSafeArguments {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Arguments,
        [Parameter(Mandatory)][string]$Name
    )

    for ($argumentIndex = 0; $argumentIndex -lt $Arguments.Count; $argumentIndex++) {
        $argument = $Arguments[$argumentIndex]
        Assert-CodexHookString -Value $argument -Name "$Name[]" -AllowEmpty
        if (
            $argument -match '[\x00-\x1f\x7f]' -or
            $argument -match '(?i)\b(?:token|password|passwd|secret|credential|api[_-]?key)\s*=' -or
            $argument -match '(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@'
        ) {
            throw "$Name 包含控制字符或敏感值模式。"
        }

        if ($argument -cmatch '^(?i:--?(?:token|password|passwd|secret|credential|api[-_]?key))$') {
            $valueState = if ($argumentIndex + 1 -lt $Arguments.Count) { '及其分离值' } else { '但缺少值' }
            throw "$Name 包含 credential flag$valueState。"
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
        } elseif ($resource.kind -ceq 'abstract' -and $abstractValues -ccontains $resource.value) {
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
        [void](Assert-CodexHookExactPath -Value $Manifest.runtimes.$name -Expected $expectedRuntimes[$name] -Name "runtimes.$name")
    }

    Assert-CodexHookArray -Value ([object]$Manifest.hooks) -Name 'hooks'
    Assert-CodexHookArray -Value ([object]$Manifest.files) -Name 'files'
    Assert-CodexHookArray -Value ([object]$Manifest.environment) -Name 'environment'

    $hookNames = @(
        'id', 'event', 'order', 'matcher', 'timeoutSeconds', 'commandPath', 'arguments',
        'wrapperPath', 'implementationPath', 'runtimeId', 'sourceState', 'readResources', 'writeResources',
        'criticality', 'lifecycle', 'lifecycleReason', 'quickHealthCheck', 'fullAcceptanceCommand'
    )
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $commandIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $eventOrders = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hooksById = @{}
    foreach ($hook in @($Manifest.hooks)) {
        Assert-CodexHookExactProperties -Value $hook -Names $hookNames -Scope 'hooks[]'
        Assert-CodexHookString -Value $hook.id -Name 'hooks[].id'
        if ($hook.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or -not $ids.Add($hook.id)) {
            throw "hook id 非法或重复：$($hook.id)"
        }
        $hooksById[$hook.id] = $hook

        Assert-CodexHookString -Value $hook.event -Name "hooks[$($hook.id)].event"
        if ($hook.event -cnotin @('SessionStart', 'Stop', 'PreToolUse')) {
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
        Assert-CodexHookString -Value $hook.sourceState -Name "hooks[$($hook.id)].sourceState"
        if ($hook.sourceState -cnotin @('managed', 'planned', 'vendor')) {
            throw "hooks[$($hook.id)].sourceState 非法：$($hook.sourceState)"
        }

        $runtimePath = [IO.Path]::GetFullPath([string]$Manifest.runtimes.PSObject.Properties[$hook.runtimeId].Value)
        if ($null -eq $wrapperPath) {
            if ($hook.sourceState -cne 'vendor') {
                throw "hooks[$($hook.id)] direct vendor entry 必须声明 sourceState=vendor。"
            }
            if (
                -not $commandPath.Equals($implementationPath, [StringComparison]::OrdinalIgnoreCase) -or
                -not $commandPath.Equals($runtimePath, [StringComparison]::OrdinalIgnoreCase)
            ) {
                throw "hooks[$($hook.id)] direct vendor entry 必须令 commandPath=implementationPath=runtime。"
            }
        } else {
            if ($hook.sourceState -ceq 'vendor') {
                throw "hooks[$($hook.id)] custom entry 不得声明 sourceState=vendor。"
            }
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
        if ($hook.criticality -cnotin @('critical', 'degraded', 'optional')) {
            throw "hook criticality 非法：$($hook.criticality)"
        }

        Assert-CodexHookString -Value $hook.lifecycle -Name "hooks[$($hook.id)].lifecycle"
        if ($hook.lifecycle -cnotin @('active', 'compatibility', 'retired')) {
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
        $inventoryAcceptanceArguments = @(
            '-NoProfile', '-File', 'D:\Codex\projects\统一环境\scripts\Get-CodexHookInventory.ps1',
            '-ManifestPath', 'D:\Codex\projects\统一环境\managed\codex-hooks\manifest.json',
            '-CodexHome', 'D:\Codex\.codex',
            '-OutputDir', 'D:\Codex\projects\统一环境\reports\codex-hook-inventory'
        )
        foreach ($declaredCommand in @($hook.quickHealthCheck, $hook.fullAcceptanceCommand)) {
            $declaredPath = [IO.Path]::GetFullPath([string]$declaredCommand.commandPath)
            if (-not @($allowedAcceptanceCommands | Where-Object { $declaredPath.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                throw "hooks[$($hook.id)] health/acceptance commandPath 不在受管 wrapper/runtime allowlist。"
            }

            $declaredArguments = [object[]]@($declaredCommand.arguments)
            $pwshPath = [IO.Path]::GetFullPath([string]$expectedRuntimes.pwsh)
            if ($declaredPath.Equals($pwshPath, [StringComparison]::OrdinalIgnoreCase)) {
                if (Test-CodexHookExactStringSequence -Actual $declaredArguments -Expected $inventoryAcceptanceArguments) {
                    continue
                }
                if ($declaredArguments.Count -ne 3 -or $declaredArguments[0] -cne '-NoProfile' -or $declaredArguments[1] -cne '-Command') {
                    throw "hooks[$($hook.id)] pwsh health/acceptance arguments 不在受控 allowlist。"
                }

                $scriptText = [string]$declaredArguments[2]
                $testPathMatch = [regex]::Match($scriptText, "^Test-Path -LiteralPath '(?<path>[^']+)'$")
                if ($testPathMatch.Success) {
                    $testedPath = Assert-CodexHookDPath -Value $testPathMatch.Groups['path'].Value -Name "hooks[$($hook.id)] health Test-Path"
                    $allowedTestPaths = @($wrapperPath, $implementationPath, $runtimePath) | Where-Object { $null -ne $_ }
                    if (-not @($allowedTestPaths | Where-Object { $testedPath.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                        throw "hooks[$($hook.id)] health Test-Path target 不在 dependency allowlist。"
                    }
                    continue
                }

                $invokeMatch = [regex]::Match($scriptText, "^'\{\}' \| & '(?<path>[^']+)'$")
                if ($invokeMatch.Success) {
                    $invokedPath = Assert-CodexHookDPath -Value $invokeMatch.Groups['path'].Value -Name "hooks[$($hook.id)] acceptance invoke"
                    if ($invokedPath.Equals($commandPath, [StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                }
                throw "hooks[$($hook.id)] pwsh health/acceptance script 不在受控 allowlist。"
            }

            if ($declaredPath.Equals($commandPath, [StringComparison]::OrdinalIgnoreCase)) {
                if ($null -eq $wrapperPath -and -not (Test-CodexHookExactStringSequence -Actual $declaredArguments -Expected @($hook.arguments))) {
                    throw "hooks[$($hook.id)] direct vendor acceptance arguments 必须等于注册 arguments。"
                }
                continue
            }

            throw "hooks[$($hook.id)] health/acceptance runtime 用法不在受控 allowlist。"
        }
        $identity = Get-CodexHookCommandIdentity -Hook $hook
        if (-not $commandIdentities.Add($identity)) {
            throw "hook identity 重复（包括 retired）：$($hook.id)"
        }

        $orderIdentity = "$($hook.event)`0$($hook.order)"
        if (-not $eventOrders.Add($orderIdentity)) {
            throw "hook event/order 重复（包括 retired）：$($hook.event)[$($hook.order)]"
        }
    }

    $environmentNames = @('name', 'scope', 'desired', 'restartRequired')
    $environmentNamesSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Manifest.environment)) {
        Assert-CodexHookExactProperties -Value $item -Names $environmentNames -Scope 'environment[]'
        Assert-CodexHookString -Value $item.name -Name 'environment[].name'
        Assert-CodexHookString -Value $item.scope -Name 'environment[].scope'
        Assert-CodexHookString -Value $item.desired -Name 'environment[].desired' -AllowEmpty
        if ($item.restartRequired -isnot [bool]) {
            throw 'environment[].restartRequired 必须是 JSON boolean。'
        }
        if (
            $item.name -cne 'SERENA_HOME' -or
            $item.scope -cne 'User' -or
            $item.desired -cne 'D:\Codex\.serena' -or
            -not $item.restartRequired
        ) {
            throw 'environment[] 只允许 SERENA_HOME/User/D:\Codex\.serena/restartRequired=true。'
        }
        if (-not $environmentNamesSeen.Add("$($item.name)`0$($item.scope)")) {
            throw "environment name/scope 重复：$($item.name)/$($item.scope)"
        }
    }

    $fileNames = @('relativePath', 'liveRelativePath', 'sha256', 'lifecycle', 'ownerHookIds')
    $relativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $liveRelativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $filesByLivePath = @{}
    foreach ($file in @($Manifest.files)) {
        Assert-CodexHookExactProperties -Value $file -Names $fileNames -Scope 'files[]'
        $normalizedRelativePath = Get-CodexHookNormalizedRelativePath -Path $file.relativePath -Name 'files[].relativePath'
        $normalizedLiveRelativePath = Get-CodexHookNormalizedRelativePath -Path $file.liveRelativePath -Name 'files[].liveRelativePath'
        if ($normalizedRelativePath -cnotmatch '^(?:hooks|retired)\\') {
            throw "files[].relativePath 不在可发布 source 布局：$($file.relativePath)"
        }
        if (-not $relativePaths.Add($normalizedRelativePath) -or -not $liveRelativePaths.Add($normalizedLiveRelativePath)) {
            throw "manifest file 路径重复：$($file.relativePath)"
        }

        Assert-CodexHookString -Value $file.sha256 -Name "files[$($file.relativePath)].sha256"
        if ($file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "files[$($file.relativePath)].sha256 必须是 lowercase SHA-256。"
        }

        Assert-CodexHookString -Value $file.lifecycle -Name "files[$($file.relativePath)].lifecycle"
        if ($file.lifecycle -cnotin @('active', 'compatibility', 'retired')) {
            throw "file lifecycle 非法：$($file.lifecycle)"
        }

        Assert-CodexHookArray -Value ([object]$file.ownerHookIds) -Name "files[$($file.relativePath)].ownerHookIds"
        if (@($file.ownerHookIds).Count -eq 0) {
            throw "files[$($file.relativePath)].ownerHookIds 不得为空。"
        }
        $owners = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($ownerId in @($file.ownerHookIds)) {
            Assert-CodexHookString -Value $ownerId -Name "files[$($file.relativePath)].ownerHookIds[]"
            if (-not $ids.Contains($ownerId) -or -not $owners.Add($ownerId)) {
                throw "file ownerHookId 未声明或重复：$ownerId"
            }
            if ($null -eq $hooksById[$ownerId].wrapperPath) {
                throw "direct vendor hook 不得声称受管 file 所有权：$ownerId"
            }
        }

        $livePath = [IO.Path]::GetFullPath((Join-Path (Join-Path $codexHome 'hooks') $normalizedLiveRelativePath))
        $filesByLivePath[$livePath] = $file
    }

    foreach ($hook in @($Manifest.hooks | Where-Object { $null -ne $_.wrapperPath })) {
        $implementationRolePath = [IO.Path]::GetFullPath([string]$hook.implementationPath)
        if ($hook.sourceState -ceq 'planned' -and $filesByLivePath.ContainsKey($implementationRolePath)) {
            throw "hooks[$($hook.id)] sourceState=planned 时不得为未实现 implementation 伪造 files[] SHA-256。"
        }
        $requiredRoles = if ($hook.sourceState -ceq 'planned') { @('wrapperPath') } else { @('wrapperPath', 'implementationPath') }
        foreach ($role in $requiredRoles) {
            $rolePath = [IO.Path]::GetFullPath([string]$hook.$role)
            if (-not $filesByLivePath.ContainsKey($rolePath)) {
                throw "hooks[$($hook.id)].$role 缺少对应 files[].liveRelativePath。"
            }

            $roleFile = $filesByLivePath[$rolePath]
            $roleOwners = @($roleFile.ownerHookIds)
            if ($roleOwners.Count -ne 1 -or $roleOwners[0] -cne $hook.id) {
                throw "files[$($roleFile.relativePath)] 对 $rolePath 声称了无关 owner。"
            }
            if ($hook.lifecycle -cne 'retired' -and $roleFile.lifecycle -ceq 'retired') {
                throw "hooks[$($hook.id)].$role 不能只由 retired file 提供。"
            }
        }
    }

    return $true
}

function Read-CodexHookManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-CodexHookDPath -Value $Path -Name 'Path'
    $jsonText = Read-CodexHookSafeTextFile `
        -Path $fullPath `
        -Name 'manifest' `
        -AllowedRoots @(
            'D:\Codex\projects\统一环境\managed\codex-hooks',
            'D:\Codex\projects\统一环境\reports'
        )
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

function Get-CodexHookObservedIdentitySha256 {
    param(
        [Parameter(Mandatory)][string]$Event,
        [AllowNull()][object]$Matcher,
        [AllowNull()][object]$Command,
        [Parameter(Mandatory)][string]$EntryType,
        [AllowNull()][object]$ParsedCommand,
        [Parameter(Mandatory)][int]$GroupIndex,
        [Parameter(Mandatory)][int]$EntryIndex
    )

    $matcherComponent = if ($null -eq $Matcher) {
        '<null>'
    } elseif ($Matcher -is [string]) {
        [string]$Matcher
    } else {
        $Matcher | ConvertTo-Json -Depth 32 -Compress
    }

    if ($Command -is [string] -and $null -ne $ParsedCommand -and $ParsedCommand.parsed) {
        $tokens = [string[]]$ParsedCommand.tokens
        $normalizedTarget = $tokens[0].Replace('/', '\')
        try {
            if ([IO.Path]::IsPathFullyQualified($normalizedTarget)) {
                $normalizedTarget = [IO.Path]::GetFullPath($normalizedTarget)
            }
        } catch {
            # Identity generation is read-free. Keep an unresolvable path as text instead of probing it.
        }
        $normalizedTarget = $normalizedTarget.ToLowerInvariant()
        $arguments = if ($tokens.Count -gt 1) { [string[]]@($tokens | Select-Object -Skip 1) } else { [string[]]@() }
        return Get-CodexHookTextSha256 -Text "$Event`0$matcherComponent`0$EntryType`0$normalizedTarget`0$($arguments -join "`0")"
    }

    if ($Command -is [string]) {
        return Get-CodexHookTextSha256 -Text "$Event`0$matcherComponent`0$EntryType`0raw`0$Command"
    }

    return Get-CodexHookTextSha256 -Text "$Event`0$matcherComponent`0$EntryType`0missing-or-non-string`0$GroupIndex`0$EntryIndex"
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

function Get-CodexHookWrapperReferenceFacts {
    param(
        [Parameter(Mandatory)][string]$WrapperText,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$ImplementationPath,
        [Parameter(Mandatory)][string]$RuntimeId
    )

    $effectiveLines = [Collections.Generic.List[string]]::new()
    foreach ($rawLine in @($WrapperText -split '\r?\n')) {
        $line = $rawLine.Trim()
        if ($line.StartsWith('@', [StringComparison]::Ordinal)) {
            $line = $line.Substring(1).TrimStart()
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('::', [StringComparison]::Ordinal)) { continue }
        if ($line -match '^(?i:rem)(?:\s|$)') { continue }
        if ($line -match '^(?i:echo)(?:\s|$)' -or $line -match '^(?i:setlocal|endlocal)(?:\s|$)' -or $line -match '^(?i:exit)(?:\s|$)') { continue }
        $effectiveLines.Add($line)
    }

    if ($effectiveLines.Count -eq 0) {
        return [pscustomobject][ordered]@{
            parseState = 'no-effective-command'
            referencesRuntime = $null
            referencesImplementation = $null
        }
    }
    if ($effectiveLines.Count -ne 1) {
        return [pscustomobject][ordered]@{
            parseState = 'ambiguous-effective-command'
            referencesRuntime = $null
            referencesImplementation = $null
        }
    }

    $parsed = Split-CodexHookCommandLine -Command $effectiveLines[0]
    if (-not $parsed.parsed) {
        return [pscustomobject][ordered]@{
            parseState = 'unparseable'
            referencesRuntime = $null
            referencesImplementation = $null
        }
    }

    $tokens = [string[]]$parsed.tokens
    try {
        $observedRuntime = [IO.Path]::GetFullPath($tokens[0].Replace('/', '\'))
    } catch {
        return [pscustomobject][ordered]@{
            parseState = 'unparseable-runtime-path'
            referencesRuntime = $null
            referencesImplementation = $null
        }
    }
    $runtimeMatches = $observedRuntime.Equals([IO.Path]::GetFullPath($RuntimePath), [StringComparison]::OrdinalIgnoreCase)
    if (-not $runtimeMatches) {
        return [pscustomobject][ordered]@{
            parseState = 'runtime-mismatch'
            referencesRuntime = $false
            referencesImplementation = $false
        }
    }

    $implementationToken = $null
    if ($RuntimeId -ceq 'pwsh') {
        $fileIndexes = @(
            for ($tokenIndex = 1; $tokenIndex -lt $tokens.Count; $tokenIndex++) {
                if ($tokens[$tokenIndex] -ieq '-File') { $tokenIndex }
            }
        )
        if ($fileIndexes.Count -ne 1 -or $fileIndexes[0] + 1 -ge $tokens.Count) {
            return [pscustomobject][ordered]@{
                parseState = 'implementation-token-unreliable'
                referencesRuntime = $true
                referencesImplementation = $null
            }
        }
        $implementationToken = $tokens[$fileIndexes[0] + 1]
    } elseif (@('python', 'serenaPython') -ccontains $RuntimeId) {
        if ($tokens.Count -lt 2) {
            return [pscustomobject][ordered]@{
                parseState = 'implementation-token-unreliable'
                referencesRuntime = $true
                referencesImplementation = $null
            }
        }
        $implementationToken = $tokens[1]
    } else {
        return [pscustomobject][ordered]@{
            parseState = 'unsupported-wrapper-runtime'
            referencesRuntime = $true
            referencesImplementation = $null
        }
    }

    try {
        $observedImplementation = [IO.Path]::GetFullPath($implementationToken.Replace('/', '\'))
    } catch {
        return [pscustomobject][ordered]@{
            parseState = 'unparseable-implementation-path'
            referencesRuntime = $true
            referencesImplementation = $null
        }
    }
    $implementationMatches = $observedImplementation.Equals([IO.Path]::GetFullPath($ImplementationPath), [StringComparison]::OrdinalIgnoreCase)
    return [pscustomobject][ordered]@{
        parseState = if ($implementationMatches) { 'matched' } else { 'implementation-mismatch' }
        referencesRuntime = $true
        referencesImplementation = $implementationMatches
    }
}

function Get-CodexHookRegistryFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][object]$Manifest
    )

    [void](Assert-CodexHookManifest -Manifest $Manifest)

    $fullPath = Assert-CodexHookDPath -Value $RegistryPath -Name 'RegistryPath'
    $registrySnapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $fullPath `
        -Name 'hook registry' `
        -AllowedExactPaths @((Join-Path ([string]$Manifest.codexHome) 'hooks.json')) `
        -AllowedRoots @('D:\Codex\projects\统一环境\reports')
    $jsonText = $registrySnapshot.text
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
            $entries = @($group.hooks)
            for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
                $entry = $entries[$entryIndex]
                $propertyNames = if ($null -ne $entry) { @($entry.PSObject.Properties.Name) } else { @() }
                $commandPresent = $propertyNames -contains 'command'
                $command = if ($commandPresent) { $entry.command } else { $null }
                $commandIsString = $command -is [string]
                $timeout = if ($propertyNames -contains 'timeout') { $entry.timeout } else { $null }
                $rawEntryType = if ($propertyNames -contains 'type' -and $entry.type -is [string]) { [string]$entry.type } else { $null }
                $entryType = if ($rawEntryType -ceq 'command') { 'command' } elseif ([string]::IsNullOrWhiteSpace($rawEntryType)) { 'missing' } else { 'other' }
                $parsed = if ($commandIsString) { Split-CodexHookCommandLine -Command ([string]$command) } else { [pscustomobject]@{ parsed = $false; tokens = @() } }
                $timeoutIsInteger = $timeout -is [sbyte] -or $timeout -is [byte] -or $timeout -is [int16] -or $timeout -is [uint16] -or $timeout -is [int32] -or $timeout -is [uint32] -or $timeout -is [int64] -or $timeout -is [uint64]

                [object[]]$manifestMatches = @()
                if ($parsed.parsed -and $entryType -ceq 'command') {
                    $manifestMatches = [object[]]@(Get-CodexHookManifestMatches -Manifest $Manifest -Event $eventName -Matcher $matcher -Tokens $parsed.tokens -IsCommandEntry $true | Where-Object { $null -ne $_ })
                }
                $matchedHook = if ($manifestMatches.Count -eq 1) { $manifestMatches[0] } else { $null }
                $targetExists = $null
                $commandSha256 = $null
                $targetPath = $null
                $targetProbeState = 'not-probed'
                if ($null -ne $matchedHook) {
                    $targetPath = [IO.Path]::GetFullPath([string]$matchedHook.commandPath)
                    $targetObservation = Get-CodexHookSafeFileHash `
                        -Path $targetPath `
                        -Name "manifest command $($matchedHook.id)" `
                        -AllowedExactPaths @([string]$matchedHook.commandPath)
                    $targetExists = $targetObservation.probe.exists
                    $targetProbeState = $targetObservation.probe.state
                    $commandSha256 = $targetObservation.sha256
                }

                $pathPolicy = if (-not $commandPresent) {
                    'missing-command'
                } elseif (-not $commandIsString) {
                    'non-string-command'
                } elseif ($entryType -cne 'command') {
                    'non-command-entry'
                } elseif ($null -ne $matchedHook) {
                    'manifest-allowlisted'
                } elseif (-not $parsed.parsed) {
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
                    event = if ($eventName -cnotin @('SessionStart', 'Stop', 'PreToolUse')) { 'Unknown' } else { $eventName }
                    groupIndex = $groupIndex
                    entryIndex = $entryIndex
                    matcher = if ($null -ne $matchedHook) { $matchedHook.matcher } else { $null }
                    matcherPresent = $null -ne $matcher
                    timeout = if ($timeoutIsInteger) { $timeout } else { $null }
                    timeoutPresent = $null -ne $timeout
                    entryType = $entryType
                    commandPresent = $commandPresent
                    commandIsString = $commandIsString
                    pathPolicy = $pathPolicy
                    targetPath = $targetPath
                    targetExists = $targetExists
                    targetProbeState = $targetProbeState
                    commandSha256 = $commandSha256
                    commandIdentitySha256 = Get-CodexHookObservedIdentitySha256 -Event $eventName -Matcher $matcher -Command $command -EntryType $entryType -ParsedCommand $parsed -GroupIndex $groupIndex -EntryIndex $entryIndex
                    argumentCount = if ($parsed.parsed) { [Math]::Max(0, $parsed.tokens.Count - 1) } else { $null }
                    idMatch = if ($null -ne $matchedHook) { $matchedHook.id } else { $null }
                    idMatchStatus = if (-not $commandPresent) { 'missing-command' } elseif (-not $commandIsString) { 'non-string-command' } elseif ($entryType -cne 'command') { 'not-command' } elseif (-not $parsed.parsed) { 'unparsed' } elseif ($manifestMatches.Count -gt 1) { 'ambiguous' } elseif ($manifestMatches.Count -eq 1) { 'matched' } else { 'unmatched' }
                    lifecycleMatch = if ($null -ne $matchedHook) { $matchedHook.lifecycle } else { $null }
                    registrationState = if ($null -ne $matchedHook -and $matchedHook.lifecycle -ceq 'retired') { 'retired-but-registered' } elseif ($null -ne $matchedHook) { 'declared' } else { 'unknown' }
                })
            }
        }

        $bucket = if ($eventName -cnotin @('SessionStart', 'Stop', 'PreToolUse')) { 'Unknown' } else { $eventName }
        $events[$bucket] = [object[]]@($events[$bucket]) + [object[]]$eventFacts.ToArray()
    }

    return [pscustomobject][ordered]@{
        registryFileSha256 = $registrySnapshot.sha256
        registryByteLength = $registrySnapshot.byteLength
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
        $wrapperObservation = if ($null -ne $wrapperPath) {
            $wrapperProbe = Get-CodexHookSafeFileProbe -Path $wrapperPath -Name "hooks[$($hook.id)].wrapper" -AllowedExactPaths @($wrapperPath)
            if ($wrapperProbe.safeToRead) {
                Read-CodexHookSafeUtf8FileSnapshot -Path $wrapperPath -Name "hooks[$($hook.id)].wrapper" -AllowedExactPaths @($wrapperPath)
            } else {
                [pscustomobject][ordered]@{ probe = $wrapperProbe; sha256 = $null; text = $null }
            }
        } else { $null }
        $implementationObservation = Get-CodexHookSafeFileHash -Path $implementationPath -Name "hooks[$($hook.id)].implementation" -AllowedExactPaths @($implementationPath)
        $runtimeObservation = Get-CodexHookSafeFileHash -Path $runtimePath -Name "hooks[$($hook.id)].runtime" -AllowedExactPaths @($runtimePath)
        $wrapperReferences = if ($null -eq $wrapperObservation -or -not $wrapperObservation.probe.safeToRead) {
            $null
        } else {
            Get-CodexHookWrapperReferenceFacts -WrapperText $wrapperObservation.text -RuntimePath $runtimePath -ImplementationPath $implementationPath -RuntimeId $hook.runtimeId
        }

        [pscustomobject][ordered]@{
            id = $hook.id
            sourceState = $hook.sourceState
            entrypointKind = if ($null -eq $wrapperPath) { 'direct-vendor' } else { 'wrapper' }
            wrapperPath = $wrapperPath
            wrapperExists = if ($null -eq $wrapperObservation) { $null } else { $wrapperObservation.probe.exists }
            wrapperProbeState = if ($null -eq $wrapperObservation) { 'not-applicable' } else { $wrapperObservation.probe.state }
            wrapperSha256 = if ($null -eq $wrapperObservation) { $null } else { $wrapperObservation.sha256 }
            implementationPath = $implementationPath
            implementationExists = $implementationObservation.probe.exists
            implementationProbeState = $implementationObservation.probe.state
            implementationSha256 = $implementationObservation.sha256
            runtimeId = $hook.runtimeId
            runtimePath = $runtimePath
            runtimeExists = $runtimeObservation.probe.exists
            runtimeProbeState = $runtimeObservation.probe.state
            runtimeSha256 = $runtimeObservation.sha256
            wrapperParseState = if ($null -eq $wrapperReferences) { if ($null -eq $wrapperPath) { 'not-applicable' } else { 'not-read' } } else { $wrapperReferences.parseState }
            wrapperReferencesImplementation = if ($null -eq $wrapperReferences) { $null } else { $wrapperReferences.referencesImplementation }
            wrapperReferencesRuntime = if ($null -eq $wrapperReferences) { $null } else { $wrapperReferences.referencesRuntime }
            readResourceCount = @($hook.readResources).Count
            writeResourceCount = @($hook.writeResources).Count
            dependencyState = if ($null -eq $wrapperPath) {
                if ($implementationObservation.probe.safeToRead -and $runtimeObservation.probe.safeToRead) { 'ready' } else { 'pending' }
            } elseif ($wrapperObservation.probe.safeToRead -and $implementationObservation.probe.safeToRead -and $runtimeObservation.probe.safeToRead -and
                $null -ne $wrapperReferences -and $wrapperReferences.parseState -ceq 'matched') {
                'ready'
            } else {
                'pending-or-mismatched'
            }
        }
    }
}

function Get-CodexHookRuntimeFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest)

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    foreach ($property in $Manifest.runtimes.PSObject.Properties) {
        $runtimePath = [IO.Path]::GetFullPath([string]$property.Value)
        $observation = Get-CodexHookSafeFileHash `
            -Path $runtimePath `
            -Name "runtime $($property.Name)" `
            -AllowedExactPaths @($runtimePath)
        [pscustomobject][ordered]@{
            name = $property.Name
            path = $runtimePath
            exists = $observation.probe.exists
            probeState = $observation.probe.state
            sha256 = $observation.sha256
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
        $managedObservation = Get-CodexHookSafeFileHash `
            -Path $managedPath `
            -Name "managed file $($file.relativePath)" `
            -AllowedRoots @($managedRootPath)
        $liveObservation = Get-CodexHookSafeFileHash `
            -Path $livePath `
            -Name "live file $($file.liveRelativePath)" `
            -AllowedRoots @($liveHooksRootPath)
        $managedExists = $managedObservation.probe.exists
        $liveExists = $liveObservation.probe.exists
        $managedSha256 = $managedObservation.sha256
        $liveSha256 = $liveObservation.sha256

        [pscustomobject][ordered]@{
            relativePath = $file.relativePath
            liveRelativePath = $file.liveRelativePath
            lifecycle = $file.lifecycle
            declaredSha256 = $file.sha256
            managedExists = $managedExists
            managedProbeState = $managedObservation.probe.state
            managedSha256 = $managedSha256
            managedMatchesManifest = $managedObservation.probe.safeToRead -and $managedSha256 -ceq $file.sha256
            liveExists = $liveExists
            liveProbeState = $liveObservation.probe.state
            liveSha256 = $liveSha256
            liveMatchesManifest = $liveObservation.probe.safeToRead -and $liveSha256 -ceq $file.sha256
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

    $duplicateIdentityCount = @($commandCounts.GetEnumerator() | Where-Object Value -gt 1).Count
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
            duplicateIdentityCount = $duplicateIdentityCount
            duplicateCommandCount = $duplicateIdentityCount
            managedMissingCount = @($FileFacts | Where-Object { $_.managedExists -eq $false }).Count
            liveMissingCount = @($FileFacts | Where-Object { $_.liveExists -eq $false }).Count
            unsafeFileProbeCount = @($FileFacts | Where-Object { $_.managedProbeState -ceq 'reparse-blocked' -or $_.liveProbeState -ceq 'reparse-blocked' }).Count
            dependencyGapCount = @($DependencyFacts | Where-Object { $_.dependencyState -cne 'ready' }).Count
            retiredButRegisteredCount = @($entries | Where-Object registrationState -ceq 'retired-but-registered').Count
            trustObservationCount = $sanitizedTrust.Count
        }
    }
}
