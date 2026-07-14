Set-StrictMode -Version Latest

$codexHookHandleBoundSource = Join-Path $PSScriptRoot 'CodexHookHandleBoundIO.cs'
if (-not ('CodexHookGovernance.HandleBoundFileReader' -as [type])) {
    Add-Type -Path $codexHookHandleBoundSource -ErrorAction Stop
}

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

function Resolve-CodexHookAllowedReadPath {
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
        throw "$Name 不在固定读取 allowlist：$fullPath"
    }

    return $fullPath
}

function Get-CodexHookSafeFileProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$AllowedExactPaths = @(),
        [string[]]$AllowedRoots = @()
    )

    # 该函数只提供路径树观察事实，不能作为 plan/apply 的最终门槛。
    # 最终读取与 hash 必须使用 Get-CodexHookHandleBoundFileSnapshot。
    $fullPath = Resolve-CodexHookAllowedReadPath `
        -Path $Path `
        -Name $Name `
        -AllowedExactPaths $AllowedExactPaths `
        -AllowedRoots $AllowedRoots

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

function Get-CodexHookInnermostException {
    param([Parameter(Mandatory)][Exception]$Exception)

    $current = $Exception
    while ($null -ne $current.InnerException) {
        $current = $current.InnerException
    }
    return $current
}

function Get-CodexHookHandleBoundFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$AllowedExactPaths = @(),
        [string[]]$AllowedRoots = @()
    )

    $fullPath = Resolve-CodexHookAllowedReadPath `
        -Path $Path `
        -Name $Name `
        -AllowedExactPaths $AllowedExactPaths `
        -AllowedRoots $AllowedRoots

    # 稳定可见的 reparse/missing 先在逐段观察阶段失败，避免主动打开外部 target。
    # 该观察不是最终门槛；probe 与 open 之间的替换仍由下面的 handle final-path 比较封住。
    $preOpenProbe = Get-CodexHookSafeFileProbe `
        -Path $fullPath `
        -Name $Name `
        -AllowedExactPaths @($fullPath)
    if (-not $preOpenProbe.safeToRead) {
        return [pscustomobject][ordered]@{
            probe = [pscustomobject][ordered]@{
                path = $preOpenProbe.path
                exists = $preOpenProbe.exists
                safeToRead = $false
                state = $preOpenProbe.state
                byteLength = $preOpenProbe.byteLength
                blockedAtSha256 = $preOpenProbe.blockedAtSha256
                finalPathVerified = $false
            }
            bytes = $null
        }
    }

    try {
        $nativeSnapshot = [CodexHookGovernance.HandleBoundFileReader]::ReadAllBytes($fullPath)
    } catch {
        $leaf = Get-CodexHookInnermostException -Exception $_.Exception
        if ($leaf -is [IO.FileNotFoundException] -or $leaf -is [IO.DirectoryNotFoundException]) {
            return [pscustomobject][ordered]@{
                probe = [pscustomobject][ordered]@{
                    path = $fullPath
                    exists = $false
                    safeToRead = $false
                    state = 'missing'
                    byteLength = $null
                    blockedAtSha256 = $null
                    finalPathVerified = $false
                }
                bytes = $null
            }
        }
        if ($leaf -is [CodexHookGovernance.HandlePathMismatchException]) {
            return [pscustomobject][ordered]@{
                probe = [pscustomobject][ordered]@{
                    path = $fullPath
                    exists = $true
                    safeToRead = $false
                    state = 'final-path-mismatch'
                    byteLength = $null
                    blockedAtSha256 = Get-CodexHookTextSha256 -Text $leaf.FinalPath
                    finalPathVerified = $false
                }
                bytes = $null
            }
        }
        throw
    }

    [byte[]]$bytes = $nativeSnapshot.Bytes
    return [pscustomobject][ordered]@{
        probe = [pscustomobject][ordered]@{
            path = $fullPath
            exists = $true
            safeToRead = $true
            state = 'regular-file'
            byteLength = [int64]$bytes.Length
            blockedAtSha256 = $null
            finalPathVerified = $true
        }
        bytes = $bytes
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

    return (Read-CodexHookSafeUtf8FileSnapshot `
        -Path $Path `
        -Name $Name `
        -AllowedExactPaths $AllowedExactPaths `
        -AllowedRoots $AllowedRoots).text
}

function Get-CodexHookSafeFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$AllowedExactPaths = @(),
        [string[]]$AllowedRoots = @()
    )

    $snapshot = Get-CodexHookHandleBoundFileSnapshot -Path $Path -Name $Name -AllowedExactPaths $AllowedExactPaths -AllowedRoots $AllowedRoots
    if (-not $snapshot.probe.safeToRead) {
        return [pscustomobject][ordered]@{
            probe = $snapshot.probe
            sha256 = $null
        }
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $sha256 = [Convert]::ToHexString($sha.ComputeHash([byte[]]$snapshot.bytes)).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }

    return [pscustomobject][ordered]@{
        probe = $snapshot.probe
        sha256 = $sha256
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

    $snapshot = Get-CodexHookHandleBoundFileSnapshot -Path $Path -Name $Name -AllowedExactPaths $AllowedExactPaths -AllowedRoots $AllowedRoots
    if (-not $snapshot.probe.safeToRead) {
        throw "$Name 无法安全读取 snapshot：state=$($snapshot.probe.state)"
    }

    [byte[]]$bytes = $snapshot.bytes
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
        probe = $snapshot.probe
        byteLength = [int64]$bytes.Length
        sha256 = $sha256
        text = $text
        bytes = $bytes
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
        $legacyInventoryAcceptanceArguments = @(
            '-NoProfile', '-File', 'D:\Codex\projects\统一环境\scripts\Get-CodexHookInventory.ps1',
            '-LegacyFixtureManifest',
            '-ManifestPath', 'D:\Codex\projects\统一环境\managed\codex-hooks\legacy-fixture-manifest.json',
            '-CodexHome', 'D:\Codex\.codex',
            '-OutputDir', 'D:\Codex\projects\统一环境\reports\codex-hook-inventory',
            '-RequireNoRetiredRegistrations'
        )
        $compatibilityInventoryAcceptanceArguments = @(
            '-NoProfile', '-File', 'D:\Codex\projects\统一环境\scripts\Get-CodexHookInventory.ps1',
            '-ManifestPath', 'D:\Codex\projects\统一环境\managed\codex-hooks\manifest.json',
            '-CodexHome', 'D:\Codex\.codex',
            '-OutputDir', 'D:\Codex\projects\统一环境\reports\codex-hook-inventory',
            '-RequireNoRetiredRegistrations'
        )
        foreach ($declaredCommand in @($hook.quickHealthCheck, $hook.fullAcceptanceCommand)) {
            $declaredPath = [IO.Path]::GetFullPath([string]$declaredCommand.commandPath)
            if (-not @($allowedAcceptanceCommands | Where-Object { $declaredPath.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                throw "hooks[$($hook.id)] health/acceptance commandPath 不在受管 wrapper/runtime allowlist。"
            }

            $declaredArguments = [object[]]@($declaredCommand.arguments)
            $pwshPath = [IO.Path]::GetFullPath([string]$expectedRuntimes.pwsh)
            if ($declaredPath.Equals($pwshPath, [StringComparison]::OrdinalIgnoreCase)) {
                if (
                    (Test-CodexHookExactStringSequence -Actual $declaredArguments -Expected $legacyInventoryAcceptanceArguments) -or
                    (Test-CodexHookExactStringSequence -Actual $declaredArguments -Expected $compatibilityInventoryAcceptanceArguments)
                ) {
                    continue
                }
                $behaviorAcceptanceArguments = @{
                    'serena-activate' = @('-NoProfile', '-File', 'D:\Codex\.codex\hooks\serena-behavior-guard.ps1', '-Mode', 'ActivationAcceptance')
                    'serena-cleanup' = @('-NoProfile', '-File', 'D:\Codex\.codex\hooks\serena-behavior-guard.ps1', '-Mode', 'CleanupAcceptance')
                    'serena-reminder' = @('-NoProfile', '-File', 'D:\Codex\.codex\hooks\serena-behavior-guard.ps1', '-Mode', 'ReminderAcceptance')
                }
                if ($behaviorAcceptanceArguments.ContainsKey([string]$hook.id) -and (Test-CodexHookExactStringSequence -Actual $declaredArguments -Expected $behaviorAcceptanceArguments[[string]$hook.id])) {
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

                $invokePattern = '^''\{"session_(?:id|Id)":"[0-9a-f-]{36}"\}'' \| & ''(?<path>[^'']+)'' -CheckOnly -Json$'
                $invokeMatch = [regex]::Match($scriptText, $invokePattern)
                if ($invokeMatch.Success) {
                    $invokedPath = Assert-CodexHookDPath -Value $invokeMatch.Groups['path'].Value -Name "hooks[$($hook.id)] acceptance invoke"
                    if ($invokedPath.Equals($commandPath, [StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                }
                $vendorInvokePattern = '^''\{"session_(?:id|Id)":"[0-9a-f-]{36}"\}'' \| & ''(?<path>[^'']+)''$'
                $vendorInvokeMatch = [regex]::Match($scriptText, $vendorInvokePattern)
                if ($hook.id -ceq 'serena-activate' -and $vendorInvokeMatch.Success -and (Test-CodexHookExactStringSequence -Actual $declaredArguments -Expected @($hook.fullAcceptanceCommand.arguments))) {
                    $invokedPath = Assert-CodexHookDPath -Value $vendorInvokeMatch.Groups['path'].Value -Name "hooks[$($hook.id)] full vendor acceptance invoke"
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

        if ($hook.lifecycle -cne 'retired') {
            $orderIdentity = "$($hook.event)`0$($hook.order)"
            if (-not $eventOrders.Add($orderIdentity)) {
                throw "active/compatibility hook event/order 重复：$($hook.event)[$($hook.order)]"
            }
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
        $expectedFileNames = if ($file.lifecycle -ceq 'retired') { @($fileNames + 'deleteLive') } else { $fileNames }
        Assert-CodexHookExactProperties -Value $file -Names $expectedFileNames -Scope 'files[]'
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
        if ($file.lifecycle -ceq 'retired' -and ($file.deleteLive -isnot [bool] -or $file.deleteLive)) {
            throw "retired file 必须显式声明 deleteLive=false：$($file.relativePath)"
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
            if ($role -ceq 'wrapperPath') {
                if ($roleOwners.Count -ne 1 -or $roleOwners[0] -cne $hook.id) {
                    throw "files[$($roleFile.relativePath)] 对 $rolePath 声称了无关 owner。"
                }
            }
            else {
                if ($roleOwners -cnotcontains $hook.id) {
                    throw "files[$($roleFile.relativePath)] 未声明 implementation owner：$($hook.id)"
                }
                foreach ($implementationOwner in $roleOwners) {
                    $ownerHook = $hooksById[$implementationOwner]
                    if (
                        $null -eq $ownerHook -or
                        $null -eq $ownerHook.wrapperPath -or
                        $ownerHook.sourceState -cne 'managed' -or
                        -not ([IO.Path]::GetFullPath([string]$ownerHook.implementationPath)).Equals($rolePath, [StringComparison]::OrdinalIgnoreCase)
                    ) {
                        throw "files[$($roleFile.relativePath)] 声明了无关 shared implementation owner：$implementationOwner"
                    }
                }
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

function Get-CodexHookHostPreflightManifestPath {
    return 'D:\Codex\projects\统一环境\managed\codex-hooks\host-preflight-manifest.json'
}

function Get-CodexHookLegacyFixtureManifestPath {
    return 'D:\Codex\projects\统一环境\managed\codex-hooks\legacy-fixture-manifest.json'
}

function Assert-CodexHookHostPreflightManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest)

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    $expectedIds = @('codex-state-preflight', 'serena-activate', 'serena-cleanup', 'serena-reminder')
    $actualIds = @($Manifest.hooks | ForEach-Object { [string]$_.id } | Sort-Object)
    if (($actualIds -join "`0") -cne (@($expectedIds | Sort-Object) -join "`0")) {
        throw "host-preflight manifest hook 集合不精确：$($actualIds -join ',')"
    }
    if (@($Manifest.hooks | Where-Object lifecycle -cne 'active').Count -ne 0) {
        throw 'host-preflight manifest 只能包含 active hook。'
    }

    $expectedHookIdentityHashes = @{
        'codex-state-preflight' = '15dbc61e3ba5514b09e713a7814b69c6a5b05244f9208ffe67b3a27ffee7ec2c'
        'serena-activate' = '70b0e6406be68f2f4b47b7666baf130e4d11b2364ae39925180fe50edb351344'
        'serena-cleanup' = '4e13fc275f0eab40c8e95a02a86ec82f65699fefd79100b4e071bce8676849de'
        'serena-reminder' = 'a34adceb6423c2bc872e5a42891769df16a03cd966f31883e2745af1db41b812'
    }
    foreach ($hook in @($Manifest.hooks)) {
        $identity = [ordered]@{
            id = $hook.id
            event = $hook.event
            order = $hook.order
            matcher = $hook.matcher
            timeoutSeconds = $hook.timeoutSeconds
            commandPath = $hook.commandPath
            arguments = @($hook.arguments)
            wrapperPath = $hook.wrapperPath
            implementationPath = $hook.implementationPath
            runtimeId = $hook.runtimeId
            sourceState = $hook.sourceState
            readResources = @($hook.readResources)
            writeResources = @($hook.writeResources)
            criticality = $hook.criticality
            lifecycle = $hook.lifecycle
            lifecycleReason = $hook.lifecycleReason
            quickHealthCheck = $hook.quickHealthCheck
            fullAcceptanceCommand = $hook.fullAcceptanceCommand
        }
        $identityHash = Get-CodexHookTextSha256 -Text ($identity | ConvertTo-Json -Depth 100 -Compress)
        if (-not $expectedHookIdentityHashes.ContainsKey([string]$hook.id) -or $identityHash -cne $expectedHookIdentityHashes[[string]$hook.id]) {
            throw "host-preflight manifest identity 漂移：$($hook.id)"
        }
    }

    $expectedFiles = @{
        'codex-state-policy-guard.py' = @('hooks/codex-state-policy-guard.py', '1c1985c66c0c3ef49e24ba919333d6f1aeb7c06f75c5861404c3b916496298f8', 'codex-state-preflight')
        'codex-state-preflight.py' = @('hooks/codex-state-preflight.py', '3fcd5a800cafa4b8b1caad4117b49b8c2dfd18df4ed769d652d5d95dcc53b38c', 'codex-state-preflight')
        'codex-state-preflight.cmd' = @('hooks/codex-state-preflight.cmd', '5392cd7d18253b4b372c9e6811b1a6380ffd554ad7b2d88008f8d1819d9b252e', 'codex-state-preflight')
        'serena-reminder-guarded.cmd' = @('hooks/serena-reminder-guarded.cmd', 'd6120f87231a058aa1a4b4a3610965c69401285637b5f7b5a2fe19dc9021925b', 'serena-reminder')
        'serena-cleanup-guarded.cmd' = @('hooks/serena-cleanup-guarded.cmd', '0944b2e57c5920f7be9c87dc32e13f8ab29adbd7e2837dcd9d64cf2b90142440', 'serena-cleanup')
        'serena-behavior-guard.ps1' = @('hooks/serena-behavior-guard.ps1', 'c19ff4b9bfa6912d67ae99ece33ca732e3f600e6bba7e213fd9cc7a4a7585be1', 'serena-reminder', 'serena-cleanup', 'serena-activate')
        'serena-activation-reminder.cmd' = @('hooks/serena-activation-reminder.cmd', '1ddf42321e82d6410266da79e591dc53a37490f5da862fce3b8f64cdebcc0e17', 'serena-activate')
        'lib/CodexHookRuntime.ps1' = @('hooks/lib/CodexHookRuntime.ps1', '8e79250ba9f8114a38b3411dda1fe62616701ba1b43c0cdbafedd14680172004', 'serena-activate', 'serena-cleanup', 'serena-reminder')
    }
    if (@($Manifest.files).Count -ne $expectedFiles.Count) {
        throw "host-preflight manifest file 闭包不精确：$(@($Manifest.files).Count)"
    }
    foreach ($file in @($Manifest.files)) {
        $liveRelativePath = [string]$file.liveRelativePath
        if (-not $expectedFiles.ContainsKey($liveRelativePath)) {
            throw "host-preflight manifest file identity 漂移：$liveRelativePath"
        }
        $expectedFile = [object[]]$expectedFiles[$liveRelativePath]
        if (
            [string]$file.relativePath -cne [string]$expectedFile[0] -or
            [string]$file.sha256 -cne [string]$expectedFile[1] -or
            [string]$file.lifecycle -cne 'active' -or
            -not (Test-CodexHookExactStringSequence -Actual @($file.ownerHookIds) -Expected @($expectedFile | Select-Object -Skip 2))
        ) {
            throw "host-preflight manifest file identity 漂移：$liveRelativePath"
        }
    }

    $stateHook = @($Manifest.hooks | Where-Object id -ceq 'codex-state-preflight')
    if (
        $stateHook.Count -ne 1 -or
        $stateHook[0].commandPath -cne 'D:\Codex\.codex\hooks\codex-state-preflight.cmd' -or
        $stateHook[0].wrapperPath -cne 'D:\Codex\.codex\hooks\codex-state-preflight.cmd' -or
        $stateHook[0].implementationPath -cne 'D:\Codex\.codex\hooks\codex-state-preflight.py'
    ) {
        throw 'host-preflight manifest state identity 必须固定为 local-only preflight。'
    }

    $forbiddenLivePaths = @(
        'codex-projectless-root-d.cmd',
        'codex-projectless-root-d.js',
        'codex-mobile-permission-guard.cmd',
        'codex-mobile-permission-guard.py',
        'codex-provider-stability-guard.cmd',
        'codex-provider-stability-guard.ps1',
        'serena-dashboard-guard.cmd',
        'serena-dashboard-guard.ps1',
        'serena-activate-guarded.cmd',
        'serena-activate-guarded.ps1'
    )
    foreach ($file in @($Manifest.files)) {
        if ([string]$file.liveRelativePath -cin $forbiddenLivePaths -or $file.lifecycle -cne 'active') {
            throw "host-preflight manifest 包含退役或冷路径外实现：$($file.liveRelativePath)"
        }
    }

    $environment = @($Manifest.environment)
    if (
        $environment.Count -ne 1 -or
        $environment[0].name -cne 'SERENA_HOME' -or
        $environment[0].scope -cne 'User' -or
        $environment[0].desired -cne 'D:\Codex\.serena' -or
        -not [bool]$environment[0].restartRequired
    ) {
        throw 'host-preflight manifest 静态 cold ownership 必须精确声明 User SERENA_HOME。'
    }
    return $true
}

function Read-CodexHookHostPreflightManifest {
    [CmdletBinding()]
    param([string]$Path = (Get-CodexHookHostPreflightManifestPath))

    $expected = [IO.Path]::GetFullPath((Get-CodexHookHostPreflightManifestPath))
    $actual = [IO.Path]::GetFullPath((Assert-CodexHookDPath -Value $Path -Name 'host-preflight manifest path'))
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "production 只接受固定 host-preflight manifest：$actual"
    }
    $manifest = Read-CodexHookManifest -Path $actual
    [void](Assert-CodexHookHostPreflightManifest -Manifest $manifest)
    return $manifest
}

function Read-CodexHookLegacyFixtureManifest {
    [CmdletBinding()]
    param([string]$Path = (Get-CodexHookLegacyFixtureManifestPath))

    $expected = [IO.Path]::GetFullPath((Get-CodexHookLegacyFixtureManifestPath))
    $actual = [IO.Path]::GetFullPath((Assert-CodexHookDPath -Value $Path -Name 'legacy fixture manifest path'))
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "历史 fixture 只接受固定 legacy manifest：$actual"
    }
    return Read-CodexHookManifest -Path $actual
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

function Get-CodexHookOpaqueCommandTargetPath {
    param(
        [Parameter(Mandatory)][string]$Command
    )

    $index = 0
    while ($index -lt $Command.Length -and [char]::IsWhiteSpace($Command[$index])) { $index++ }
    if ($index -ge $Command.Length) { return $null }

    # Managed hook targets do not contain whitespace. Stop at the first whitespace even
    # when a leading quote is unclosed, and never scan later arguments for managed paths.
    $target = [Text.StringBuilder]::new()
    while ($index -lt $Command.Length -and -not [char]::IsWhiteSpace($Command[$index])) {
        if ($Command[$index] -ne '"') { [void]$target.Append($Command[$index]) }
        $index++
    }
    if ($target.Length -eq 0) { return $null }

    $candidate = $target.ToString().Replace('/', '\')
    if ($candidate -notmatch '^[dD]:\\') { return $null }
    try {
        return [IO.Path]::GetFullPath($candidate)
    } catch {
        return $null
    }
}

function Test-CodexHookOpaqueCommandTargetsManagedPath {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$Command
    )

    $targetPath = Get-CodexHookOpaqueCommandTargetPath -Command $Command
    if ($null -eq $targetPath) { return $false }

    $managedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($hook in @($Manifest.hooks)) {
        foreach ($propertyName in @('wrapperPath', 'commandPath')) {
            $managedPath = $hook.$propertyName
            if ($null -eq $managedPath -or $managedPath -isnot [string]) { continue }
            try {
                [void]$managedPaths.Add([IO.Path]::GetFullPath(([string]$managedPath).Replace('/', '\')))
            } catch {
                continue
            }
        }
    }
    return $managedPaths.Contains([string]$targetPath)
}

function Copy-CodexHookJsonValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $jsonText = $Value | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
    Assert-CodexHookStrictJsonText -JsonText $jsonText
    return ($jsonText | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
}

function Get-CodexHookRegistryEntryAnalysis {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$Event,
        [AllowNull()][object]$Matcher,
        [AllowNull()][object]$Entry
    )

    $propertyNames = if ($null -eq $Entry) { @() } else { @($Entry.PSObject.Properties.Name) }
    $entryType = if ($propertyNames -contains 'type' -and $Entry.type -is [string]) { [string]$Entry.type } else { $null }
    $command = if ($propertyNames -contains 'command') { $Entry.command } else { $null }
    $parsed = if ($command -is [string]) {
        Split-CodexHookCommandLine -Command ([string]$command)
    } else {
        [pscustomobject]@{ parsed = $false; tokens = @() }
    }

    [object[]]$exactMatches = @()
    if ($entryType -ceq 'command' -and $parsed.parsed) {
        $exactMatches = [object[]]@(
            Get-CodexHookManifestMatches `
                -Manifest $Manifest `
                -Event $Event `
                -Matcher $Matcher `
                -Tokens ([string[]]$parsed.tokens) `
                -IsCommandEntry $true |
                Where-Object { $null -ne $_ }
        )
    }
    if ($exactMatches.Count -gt 1) {
        throw "registry identity 命中多个 manifest hook：event=$Event"
    }

    $customPathMatches = @()
    if ($parsed.parsed -and $parsed.tokens.Count -gt 0 -and [string]$parsed.tokens[0] -match '^[dD]:[\\/]') {
        try {
            $targetPath = [IO.Path]::GetFullPath(([string]$parsed.tokens[0]).Replace('/', '\'))
            $customPathMatches = @(
                $Manifest.hooks | Where-Object {
                    $null -ne $_.wrapperPath -and
                    $targetPath.Equals([IO.Path]::GetFullPath([string]$_.commandPath), [StringComparison]::OrdinalIgnoreCase)
                }
            )
        } catch {
            $customPathMatches = @()
        }
    }
    if ($customPathMatches.Count -gt 0 -and $exactMatches.Count -eq 0) {
        throw "受管 custom wrapper identity 漂移：event=$Event"
    }
    if (
        -not $parsed.parsed -and
        $command -is [string] -and
        (Test-CodexHookOpaqueCommandTargetsManagedPath -Manifest $Manifest -Command ([string]$command))
    ) {
        throw "受管 custom wrapper command 无法安全解析：event=$Event"
    }

    return [pscustomobject][ordered]@{
        matchedHook = if ($exactMatches.Count -eq 1) { $exactMatches[0] } else { $null }
        exactMatchCount = $exactMatches.Count
    }
}

function Get-CodexHookRegistryOwnershipMap {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Registry
    )

    if ($null -eq $Registry -or $Registry.PSObject.Properties.Name -notcontains 'hooks' -or $null -eq $Registry.hooks) {
        throw 'hook registry 缺少 hooks object。'
    }

    $seenHookIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $groupsByEvent = [ordered]@{}
    foreach ($eventProperty in $Registry.hooks.PSObject.Properties) {
        $eventName = [string]$eventProperty.Name
        $groupAnalyses = [Collections.Generic.List[object]]::new()
        $groups = @($eventProperty.Value)
        for ($groupIndex = 0; $groupIndex -lt $groups.Count; $groupIndex++) {
            $group = $groups[$groupIndex]
            $groupProperties = if ($null -eq $group) { @() } else { @($group.PSObject.Properties.Name) }
            if ($groupProperties -notcontains 'hooks') {
                $groupAnalyses.Add([pscustomobject][ordered]@{
                    index = $groupIndex
                    matchedHook = $null
                    isManaged = $false
                })
                continue
            }

            $matcher = if ($groupProperties -contains 'matcher') { $group.matcher } else { $null }
            $entries = @($group.hooks)
            $entryMatches = [Collections.Generic.List[object]]::new()
            foreach ($entry in $entries) {
                $entryMatches.Add((Get-CodexHookRegistryEntryAnalysis -Manifest $Manifest -Event $eventName -Matcher $matcher -Entry $entry))
            }
            $matchedEntries = @($entryMatches | Where-Object { $null -ne $_.matchedHook })
            if ($entries.Count -ne 1 -and $matchedEntries.Count -gt 0) {
                throw "包含受管 identity 的 multi-entry group 拒绝自动合并：event=$eventName,index=$groupIndex"
            }

            $matchedHook = if ($entries.Count -eq 1 -and $matchedEntries.Count -eq 1) { $matchedEntries[0].matchedHook } else { $null }
            if ($null -ne $matchedHook -and -not $seenHookIds.Add([string]$matchedHook.id)) {
                throw "registry 受管 identity 重复：id=$($matchedHook.id)"
            }
            $groupAnalyses.Add([pscustomobject][ordered]@{
                index = $groupIndex
                matchedHook = $matchedHook
                isManaged = $null -ne $matchedHook
            })
        }
        $groupsByEvent[$eventName] = [object[]]$groupAnalyses.ToArray()
    }

    return [pscustomobject][ordered]@{
        groupsByEvent = [pscustomobject]$groupsByEvent
    }
}

function ConvertTo-CodexHookCommandToken {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.Contains('"')) {
        throw 'manifest 注册 token 不得包含双引号。'
    }
    if ($Value -match '\s') {
        return '"' + $Value + '"'
    }
    return $Value
}

function New-CodexHookCanonicalRegistryGroup {
    param([Parameter(Mandatory)][object]$Hook)

    $tokens = @(
        ConvertTo-CodexHookCommandToken -Value ([string]$Hook.commandPath)
        foreach ($argument in @($Hook.arguments)) {
            ConvertTo-CodexHookCommandToken -Value ([string]$argument)
        }
    )
    $group = [pscustomobject][ordered]@{}
    if ($null -ne $Hook.matcher) {
        $group | Add-Member -NotePropertyName matcher -NotePropertyValue ([string]$Hook.matcher)
    }
    $group | Add-Member -NotePropertyName hooks -NotePropertyValue @(
        [pscustomobject][ordered]@{
            type = 'command'
            command = $tokens -join ' '
            timeout = [int]$Hook.timeoutSeconds
        }
    )
    return $group
}

function Merge-CodexHookRegistryEventGroups {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$Event,
        [AllowEmptyCollection()][object[]]$Groups = @(),
        [AllowEmptyCollection()][object[]]$Analyses = @(),
        [Parameter(Mandatory)][bool]$RemoveRetired
    )

    $desiredHooks = @(
        $Manifest.hooks |
        Where-Object { $_.event -ceq $Event -and $_.lifecycle -cne 'retired' } |
        Sort-Object { [int]$_.order }
    )
    $desiredIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($hook in $desiredHooks) { [void]$desiredIds.Add([string]$hook.id) }

    $baseGroups = [Collections.Generic.List[object]]::new()
    $managedSlotIndexes = [Collections.Generic.List[int]]::new()
    $existingById = @{}
    for ($groupIndex = 0; $groupIndex -lt $Groups.Count; $groupIndex++) {
        $analysis = if ($groupIndex -lt $Analyses.Count) { $Analyses[$groupIndex] } else { $null }
        $matchedHook = if ($null -eq $analysis) { $null } else { $analysis.matchedHook }
        if ($RemoveRetired -and $null -ne $matchedHook -and $matchedHook.lifecycle -ceq 'retired') {
            continue
        }

        $newIndex = $baseGroups.Count
        $baseGroups.Add($Groups[$groupIndex])
        if ($null -ne $matchedHook -and $desiredIds.Contains([string]$matchedHook.id)) {
            $existingById[[string]$matchedHook.id] = $Groups[$groupIndex]
            $managedSlotIndexes.Add($newIndex)
        }
    }

    $orderedExisting = [Collections.Generic.List[object]]::new()
    $missing = [Collections.Generic.List[object]]::new()
    $missingSeen = $false
    foreach ($hook in $desiredHooks) {
        if ($existingById.ContainsKey([string]$hook.id)) {
            if ($missingSeen) {
                throw "受管 event 缺失非尾部 identity，拒绝在已存在 identity 后补插：event=$Event"
            }
            $existingGroup = $existingById[[string]$hook.id]
            $existingEntry = @($existingGroup.hooks)[0]
            if ($existingEntry.PSObject.Properties.Name -contains 'timeout') {
                $existingEntry.timeout = [int]$hook.timeoutSeconds
            } else {
                $existingEntry | Add-Member -NotePropertyName timeout -NotePropertyValue ([int]$hook.timeoutSeconds)
            }
            $orderedExisting.Add($existingGroup)
        } else {
            $missingSeen = $true
            $missing.Add((New-CodexHookCanonicalRegistryGroup -Hook $hook))
        }
    }
    if ($orderedExisting.Count -ne $managedSlotIndexes.Count) {
        throw "registry event 合并内部计数不一致：event=$Event"
    }
    for ($slot = 0; $slot -lt $managedSlotIndexes.Count; $slot++) {
        $baseGroups[$managedSlotIndexes[$slot]] = $orderedExisting[$slot]
    }
    foreach ($missingGroup in $missing) { $baseGroups.Add($missingGroup) }
    return [object[]]$baseGroups.ToArray()
}

function Merge-CodexHookRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$LiveRegistry,
        [Parameter(Mandatory)][ValidateSet('registration-repair', 'full')][string]$Mode
    )

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    $registry = Copy-CodexHookJsonValue -Value $LiveRegistry
    $ownership = Get-CodexHookRegistryOwnershipMap -Manifest $Manifest -Registry $registry

    $eventsToMerge = if ($Mode -ceq 'registration-repair') {
        @('SessionStart')
    } else {
        @($Manifest.hooks | ForEach-Object { [string]$_.event } | Select-Object -Unique)
    }
    foreach ($eventName in $eventsToMerge) {
        $eventProperty = $registry.hooks.PSObject.Properties[$eventName]
        [object[]]$groups = @()
        if ($null -ne $eventProperty) { $groups = [object[]]@($eventProperty.Value) }
        $analysisProperty = $ownership.groupsByEvent.PSObject.Properties[$eventName]
        [object[]]$analyses = @()
        if ($null -ne $analysisProperty) { $analyses = [object[]]@($analysisProperty.Value) }
        $mergedGroups = Merge-CodexHookRegistryEventGroups `
            -Manifest $Manifest `
            -Event $eventName `
            -Groups $groups `
            -Analyses $analyses `
            -RemoveRetired ($Mode -ceq 'full')
        if ($null -eq $eventProperty) {
            $registry.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue $mergedGroups
        } else {
            $registry.hooks.$eventName = $mergedGroups
        }
    }

    return $registry
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
        if ($line -match '[&|<>^]') {
            return [pscustomobject][ordered]@{
                parseState = 'unsafe-cmd-metacharacter'
                referencesRuntime = $null
                referencesImplementation = $null
            }
        }
        if (
            $line -match '^(?i:echo\s+off)$' -or
            $line -match '^(?i:setlocal|endlocal)$' -or
            $line -match '^(?i:exit\s+/b\s+%ERRORLEVEL%)$'
        ) { continue }
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
        $seenFlags = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $tokenIndex = 1
        while ($tokenIndex -lt $tokens.Count -and $tokens[$tokenIndex] -ine '-File') {
            $token = $tokens[$tokenIndex]
            if ($token -ieq '-NoLogo' -or $token -ieq '-NoProfile') {
                if (-not $seenFlags.Add($token)) {
                    return [pscustomobject][ordered]@{
                        parseState = 'duplicate-startup-flag'
                        referencesRuntime = $true
                        referencesImplementation = $null
                    }
                }
                $tokenIndex++
                continue
            }
            if ($token -ieq '-ExecutionPolicy') {
                if (-not $seenFlags.Add('-ExecutionPolicy') -or $tokenIndex + 1 -ge $tokens.Count -or $tokens[$tokenIndex + 1] -ine 'Bypass') {
                    return [pscustomobject][ordered]@{
                        parseState = 'invalid-execution-policy'
                        referencesRuntime = $true
                        referencesImplementation = $null
                    }
                }
                $tokenIndex += 2
                continue
            }
            return [pscustomobject][ordered]@{
                parseState = if ($token -ieq '-Command' -or $token -ieq '-EncodedCommand') { 'forbidden-pwsh-command-mode' } else { 'invalid-startup-token' }
                referencesRuntime = $true
                referencesImplementation = $null
            }
        }

        if ($tokenIndex -ge $tokens.Count -or $tokens[$tokenIndex] -ine '-File' -or $tokenIndex + 1 -ge $tokens.Count) {
            return [pscustomobject][ordered]@{
                parseState = 'implementation-token-unreliable'
                referencesRuntime = $true
                referencesImplementation = $null
            }
        }
        $implementationToken = $tokens[$tokenIndex + 1]
        $remainingTokens = [string[]]@($tokens | Select-Object -Skip ($tokenIndex + 2))
        if ($remainingTokens.Count -gt 1 -or ($remainingTokens.Count -eq 1 -and $remainingTokens[0] -cne '%*')) {
            return [pscustomobject][ordered]@{
                parseState = 'unexpected-trailing-token'
                referencesRuntime = $true
                referencesImplementation = $null
            }
        }
    } elseif (@('python', 'serenaPython') -ccontains $RuntimeId) {
        if ($tokens.Count -lt 2 -or $tokens.Count -gt 3 -or ($tokens.Count -eq 3 -and $tokens[2] -cne '%*')) {
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

function Get-CodexHookKnownRetiredRegistrationManifest {
    return [pscustomobject]@{
        hooks = @(
            [pscustomobject]@{ id = 'provider-stability'; event = 'SessionStart'; matcher = $null; commandPath = 'D:\Codex\.codex\hooks\codex-provider-stability-guard.cmd'; arguments = @(); lifecycle = 'retired' }
            [pscustomobject]@{ id = 'codex-state-policy'; event = 'SessionStart'; matcher = $null; commandPath = 'D:\Codex\.codex\hooks\codex-projectless-root-d.cmd'; arguments = @(); lifecycle = 'retired' }
            [pscustomobject]@{ id = 'serena-activate-legacy'; event = 'SessionStart'; matcher = 'startup|resume'; commandPath = 'D:\Codex\.codex\hooks\serena-activate-guarded.cmd'; arguments = @(); lifecycle = 'retired' }
            [pscustomobject]@{ id = 'serena-dashboard'; event = 'SessionStart'; matcher = $null; commandPath = 'D:\Codex\.codex\hooks\serena-dashboard-guard.cmd'; arguments = @(); lifecycle = 'retired' }
            [pscustomobject]@{ id = 'github-cli'; event = 'SessionStart'; matcher = $null; commandPath = 'D:\Codex\.codex\hooks\codex-github-cli-guard.cmd'; arguments = @(); lifecycle = 'retired' }
            [pscustomobject]@{ id = 'serena-auto-approve'; event = 'PreToolUse'; matcher = 'mcp__serena__.*|mcp__serena\..*'; commandPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe'; arguments = @('auto-approve', '--client=codex'); lifecycle = 'retired' }
        )
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
                if ($null -eq $matchedHook -and $parsed.parsed -and $entryType -ceq 'command') {
                    $retiredMatches = [object[]]@(
                        Get-CodexHookManifestMatches `
                            -Manifest (Get-CodexHookKnownRetiredRegistrationManifest) `
                            -Event $eventName `
                            -Matcher $matcher `
                            -Tokens $parsed.tokens `
                            -IsCommandEntry $true |
                            Where-Object { $null -ne $_ }
                    )
                    if ($retiredMatches.Count -eq 1) {
                        $matchedHook = $retiredMatches[0]
                    }
                }
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
                    idMatchStatus = if (-not $commandPresent) { 'missing-command' } elseif (-not $commandIsString) { 'non-string-command' } elseif ($entryType -cne 'command') { 'not-command' } elseif (-not $parsed.parsed) { 'unparsed' } elseif ($manifestMatches.Count -gt 1) { 'ambiguous' } elseif ($null -ne $matchedHook) { 'matched' } else { 'unmatched' }
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

function Get-CodexHookBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertTo-CodexHookRegistryBytes {
    param([Parameter(Mandatory)][object]$Registry)

    $text = $Registry | ConvertTo-Json -Depth 100 -ErrorAction Stop
    return [Text.UTF8Encoding]::new($false).GetBytes($text)
}

function Get-CodexHookFixtureMappingIdentity {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CodexHome
    )

    $source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\').ToLowerInvariant()
    $normalizedHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\').ToLowerInvariant()
    $managed = [IO.Path]::GetFullPath([string]$Manifest.managedRoot).TrimEnd('\').ToLowerInvariant()
    $productionHome = [IO.Path]::GetFullPath([string]$Manifest.codexHome).TrimEnd('\').ToLowerInvariant()
    return Get-CodexHookTextSha256 -Text "codex-hook-fixture-v1`0$source`0$normalizedHome`0$managed`0$productionHome"
}

function Assert-CodexHookFixturePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Assert-CodexHookDPath -Value $Path -Name $Name
    $fixtureRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test'
    if (-not (Test-CodexHookPathWithin -Path $fullPath -ParentPath $fixtureRoot)) {
        throw "$Name 必须位于固定 deployment fixture 根：$fullPath"
    }
    if ($fullPath.Substring(2).Contains(':')) {
        throw "$Name 不得包含 NTFS alternate data stream。"
    }
    Assert-CodexHookNoReparseAncestor -Path $fullPath -Name $Name
    return $fullPath
}

function Assert-CodexHookNoReparseAncestor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Assert-CodexHookDPath -Value $Path -Name $Name
    $root = [IO.Path]::GetPathRoot($fullPath)
    $currentPath = $root
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name 祖先包含 reparse point。"
    }
    foreach ($segment in @($fullPath.Substring($root.Length) -split '[\\/]' | Where-Object { $_ -ne '' })) {
        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath -ErrorAction Stop)) { break }
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name 祖先或 final path 包含 reparse point。"
        }
    }
}

function Enter-CodexHookFixtureDirectoryChainGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DirectoryPath,
        [switch]$CreateMissing
    )

    $fullPath = Assert-CodexHookFixturePath -Path $DirectoryPath -Name 'fixture directory chain guard'
    $fixtureRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test'
    return [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $fixtureRoot,
        $fullPath,
        $CreateMissing.IsPresent)
}

function New-CodexHookFixtureDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Name = 'fixture directory',
        [switch]$RequireMissing
    )

    $fullPath = Assert-CodexHookFixturePath -Path $Path -Name $Name
    $fixtureRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test'
    $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $fixtureRoot,
        $fullPath,
        $true,
        $RequireMissing.IsPresent)
    try {
        return $fullPath
    } finally {
        $guard.Dispose()
    }
}

function Assert-CodexHookMappingIdentity {
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$Name = 'mappingIdentity'
    )

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name 非法。"
    }
    return $Value
}

function Assert-CodexHookGenerationId {
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$Name = 'generationId'
    )

    $generationGuid = [guid]::Empty
    if (
        -not [guid]::TryParse($Value, [ref]$generationGuid) -or
        $generationGuid -eq [guid]::Empty -or
        $Value -cne $generationGuid.ToString()
    ) {
        throw "$Name 非法。"
    }
    return $Value
}

function Get-CodexHookFixtureDeploymentMutexName {
    param([Parameter(Mandatory)][string]$MappingIdentity)

    $identity = Assert-CodexHookMappingIdentity -Value $MappingIdentity
    return "Local\CodexHookDeploymentFixture-$identity"
}

function Get-CodexHookFixtureLifecyclePaths {
    param(
        [Parameter(Mandatory)][string]$MappingIdentity,
        [Parameter(Mandatory)][string]$GenerationId
    )

    $identity = Assert-CodexHookMappingIdentity -Value $MappingIdentity
    $generation = Assert-CodexHookGenerationId -Value $GenerationId
    $fixtureRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test'
    $lifecycleRoot = Join-Path $fixtureRoot '.deployment-state'
    $mappingRoot = Join-Path (Join-Path $lifecycleRoot 'mappings') $identity
    $claimsRoot = Join-Path $mappingRoot 'claims'
    $claimPath = Join-Path $claimsRoot "$generation.json"
    foreach ($pathFact in @(
        @{ Path = $lifecycleRoot; Name = 'fixed lifecycle root' },
        @{ Path = $mappingRoot; Name = 'mapping lifecycle root' },
        @{ Path = $claimsRoot; Name = 'mapping claims root' },
        @{ Path = $claimPath; Name = 'mapping generation claim' }
    )) {
        [void](Assert-CodexHookFixturePath -Path ([string]$pathFact.Path) -Name ([string]$pathFact.Name))
    }
    return [pscustomobject][ordered]@{
        lifecycleRoot = [IO.Path]::GetFullPath($lifecycleRoot)
        mappingRoot = [IO.Path]::GetFullPath($mappingRoot)
        claimsRoot = [IO.Path]::GetFullPath($claimsRoot)
        claimPath = [IO.Path]::GetFullPath($claimPath)
    }
}

function New-CodexHookDeploymentPlanDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Inventory,
        [Parameter(Mandatory)][object]$DesiredRegistry,
        [Parameter(Mandatory)][ValidateSet('registration-repair', 'full')][string]$Mode
    )

    [void](Assert-CodexHookManifest -Manifest $Manifest)
    $requiredInventoryProperties = @(
        'targetProfile', 'mappingIdentity', 'manifestPath', 'manifestSha256',
        'sourceRoot', 'codexHome', 'hooksRoot', 'registryPath', 'registryBeforeSha256',
        'sourceFiles', 'liveFiles', 'environmentFacts', 'blockers'
    )
    Assert-CodexHookExactProperties -Value $Inventory -Names $requiredInventoryProperties -Scope 'deployment inventory'
    if ($Inventory.targetProfile -cne 'codex-hook-fixture-v1') {
        throw 'deployment inventory targetProfile 非法。'
    }

    $mappingIdentity = Get-CodexHookFixtureMappingIdentity `
        -Manifest $Manifest `
        -SourceRoot ([string]$Inventory.sourceRoot) `
        -CodexHome ([string]$Inventory.codexHome)
    if ($mappingIdentity -cne [string]$Inventory.mappingIdentity) {
        throw 'deployment inventory mapping identity 不一致。'
    }

    $sourceByRelative = @{}
    foreach ($fact in @($Inventory.sourceFiles)) { $sourceByRelative[[string]$fact.relativePath] = $fact }
    $liveByRelative = @{}
    foreach ($fact in @($Inventory.liveFiles)) { $liveByRelative[[string]$fact.liveRelativePath] = $fact }
    $blockerCodes = [Collections.Generic.List[string]]::new()
    foreach ($blocker in @($Inventory.blockers)) {
        $code = if ($blocker -is [string]) { [string]$blocker } elseif ($blocker.PSObject.Properties.Name -contains 'code') { [string]$blocker.code } else { 'invalid-blocker' }
        if (-not [string]::IsNullOrWhiteSpace($code)) { $blockerCodes.Add($code) }
    }

    $actions = [Collections.Generic.List[object]]::new()
    $postChecks = [Collections.Generic.List[object]]::new()
    $restoreOrder = 0
    if ($Mode -ceq 'full') {
        $publishFiles = @($Manifest.files | Where-Object { $_.lifecycle -cne 'retired' })
        foreach ($phase in @('implementation', 'wrapper')) {
            foreach ($file in $publishFiles) {
                $isWrapper = [IO.Path]::GetExtension([string]$file.liveRelativePath) -ieq '.cmd'
                if (($phase -ceq 'wrapper') -ne $isWrapper) { continue }
                $sourceFact = $sourceByRelative[[string]$file.relativePath]
                $liveFact = $liveByRelative[[string]$file.liveRelativePath]
                if ($null -eq $sourceFact -or -not $sourceFact.exists -or $sourceFact.probeState -cne 'regular-file' -or $sourceFact.sha256 -cne $file.sha256) {
                    $blockerCodes.Add('source-fact-mismatch')
                    continue
                }
                if ($null -eq $liveFact -or $liveFact.probeState -cnotin @('regular-file', 'missing')) {
                    $blockerCodes.Add('live-target-unsafe')
                    continue
                }
                $restoreOrder++
                $actionId = "file:$($file.relativePath.Replace('\','/'))"
                $action = [pscustomobject][ordered]@{
                    actionId = $actionId
                    phase = $phase
                    kind = 'file'
                    sourceRef = [string]$file.relativePath
                    sourceSha256 = [string]$sourceFact.sha256
                    logicalTarget = [string]$file.liveRelativePath
                    targetPath = [string]$liveFact.path
                    beforeExists = [bool]$liveFact.exists
                    beforeSha256 = if ($liveFact.exists) { [string]$liveFact.sha256 } else { $null }
                    afterSha256 = [string]$file.sha256
                    restoreOrder = $restoreOrder
                }
                $actions.Add($action)
                $postChecks.Add([pscustomobject][ordered]@{ actionId = $actionId; kind = 'sha256'; expectedSha256 = [string]$file.sha256 })
            }
        }
    }

    $environmentActions = [Collections.Generic.List[object]]::new()
    if ($Mode -ceq 'full') {
        foreach ($environment in @($Manifest.environment)) {
            $fact = @($Inventory.environmentFacts | Where-Object { $_.name -ceq $environment.name -and $_.scope -ceq $environment.scope })
            if ($fact.Count -ne 1) {
                $blockerCodes.Add('environment-fact-missing')
                continue
            }
            $restoreOrder++
            $afterHash = Get-CodexHookTextSha256 -Text "present`0$($environment.desired)"
            $environmentActions.Add([pscustomobject][ordered]@{
                actionId = "environment:$($environment.scope):$($environment.name)"
                phase = 'environment'
                kind = 'environment'
                name = [string]$environment.name
                scope = [string]$environment.scope
                after = [string]$environment.desired
                beforePresent = [bool]$fact[0].present
                beforeMatchesTarget = [bool]$fact[0].matchesTarget
                beforeValueSha256 = [string]$fact[0].valueSha256
                afterValueSha256 = $afterHash
                restoreOrder = $restoreOrder
            })
        }
    }

    $desiredRegistryBytes = ConvertTo-CodexHookRegistryBytes -Registry $DesiredRegistry
    $registryAfterSha256 = Get-CodexHookBytesSha256 -Bytes $desiredRegistryBytes
    $restoreOrder++
    $registryAction = [pscustomobject][ordered]@{
        actionId = 'registry:hooks.json'
        phase = 'registry'
        kind = 'registry'
        sourceRef = $null
        sourceSha256 = $null
        logicalTarget = 'hooks.json'
        targetPath = [string]$Inventory.registryPath
        beforeExists = $true
        beforeSha256 = [string]$Inventory.registryBeforeSha256
        afterSha256 = $registryAfterSha256
        restoreOrder = $restoreOrder
    }
    $actions.Add($registryAction)
    $postChecks.Add([pscustomobject][ordered]@{ actionId = $registryAction.actionId; kind = 'sha256'; expectedSha256 = $registryAfterSha256 })

    $distinctBlockers = @($blockerCodes | Select-Object -Unique)
    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-deployment-plan'
        schemaVersion = 1
        generationId = [guid]::NewGuid().ToString()
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        manifestSha256 = [string]$Inventory.manifestSha256
        mode = $Mode
        applyEligible = $distinctBlockers.Count -eq 0
        sourceFacts = [pscustomobject][ordered]@{
            targetProfile = 'codex-hook-fixture-v1'
            mappingIdentity = $mappingIdentity
            manifestPath = [string]$Inventory.manifestPath
            manifestSha256 = [string]$Inventory.manifestSha256
            sourceRoot = [string]$Inventory.sourceRoot
            files = [object[]]@($Inventory.sourceFiles)
            blockerReasonCodes = [string[]]$distinctBlockers
        }
        liveFacts = [pscustomobject][ordered]@{
            targetProfile = 'codex-hook-fixture-v1'
            mappingIdentity = $mappingIdentity
            codexHome = [string]$Inventory.codexHome
            hooksRoot = [string]$Inventory.hooksRoot
            registryPath = [string]$Inventory.registryPath
            files = [object[]]@($Inventory.liveFiles)
            blockerReasonCodes = [string[]]$distinctBlockers
        }
        registryBeforeSha256 = [string]$Inventory.registryBeforeSha256
        registryAfterSha256 = $registryAfterSha256
        actions = [object[]]$actions.ToArray()
        environmentActions = [object[]]$environmentActions.ToArray()
        postChecks = [object[]]$postChecks.ToArray()
        rollbackRequired = ($actions.Count + $environmentActions.Count) -gt 0
    }
}

function Assert-CodexHookDeploymentPlanFresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    $topNames = @(
        'artifactType', 'schemaVersion', 'generationId', 'generatedAtUtc', 'manifestSha256',
        'mode', 'applyEligible', 'sourceFacts', 'liveFacts', 'registryBeforeSha256',
        'registryAfterSha256', 'actions', 'environmentActions', 'postChecks', 'rollbackRequired'
    )
    Assert-CodexHookExactProperties -Value $Plan -Names $topNames -Scope 'deployment plan'
    Assert-CodexHookString -Value $Plan.artifactType -Name 'deployment plan artifactType'
    Assert-CodexHookInteger -Value $Plan.schemaVersion -Name 'deployment plan schemaVersion'
    Assert-CodexHookString -Value $Plan.generationId -Name 'deployment plan generationId'
    Assert-CodexHookString -Value $Plan.generatedAtUtc -Name 'deployment plan generatedAtUtc'
    Assert-CodexHookString -Value $Plan.manifestSha256 -Name 'deployment plan manifestSha256'
    Assert-CodexHookString -Value $Plan.mode -Name 'deployment plan mode'
    if ($Plan.artifactType -cne 'env-governance.codex-hook-deployment-plan' -or [int]$Plan.schemaVersion -ne 1) {
        throw 'deployment plan artifact/schema 非法。'
    }
    [void](Assert-CodexHookGenerationId -Value ([string]$Plan.generationId) -Name 'deployment plan generationId')
    $generated = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Plan.generatedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$generated)) {
        throw 'deployment plan generatedAtUtc 非法。'
    }
    if ($generated -gt $Now.AddMinutes(5) -or $generated -lt $Now.AddHours(-1)) {
        throw 'deployment plan 已过期或来自未来。'
    }
    if ($Plan.mode -cnotin @('registration-repair', 'full')) { throw 'deployment plan mode 非法。' }
    if ($Plan.applyEligible -isnot [bool] -or -not $Plan.applyEligible) { throw 'deployment plan 不可 apply。' }
    if ($Plan.rollbackRequired -isnot [bool] -or -not $Plan.rollbackRequired) { throw 'deployment plan 必须声明 rollbackRequired。' }
    foreach ($hashName in @('manifestSha256', 'registryBeforeSha256', 'registryAfterSha256')) {
        if ([string]$Plan.$hashName -cnotmatch '^[0-9a-f]{64}$') { throw "deployment plan $hashName 非法。" }
    }
    if ($Plan.sourceFacts.targetProfile -cne 'codex-hook-fixture-v1' -or $Plan.liveFacts.targetProfile -cne 'codex-hook-fixture-v1') {
        throw 'deployment plan targetProfile 非法。'
    }
    Assert-CodexHookExactProperties -Value $Plan.sourceFacts -Names @(
        'targetProfile', 'mappingIdentity', 'manifestPath', 'manifestSha256', 'sourceRoot', 'files', 'blockerReasonCodes'
    ) -Scope 'deployment plan sourceFacts'
    Assert-CodexHookExactProperties -Value $Plan.liveFacts -Names @(
        'targetProfile', 'mappingIdentity', 'codexHome', 'hooksRoot', 'registryPath', 'files', 'blockerReasonCodes'
    ) -Scope 'deployment plan liveFacts'
    foreach ($stringProperty in @('targetProfile', 'mappingIdentity', 'manifestPath', 'manifestSha256', 'sourceRoot')) {
        Assert-CodexHookString -Value $Plan.sourceFacts.$stringProperty -Name "plan sourceFacts.$stringProperty"
    }
    foreach ($stringProperty in @('targetProfile', 'mappingIdentity', 'codexHome', 'hooksRoot', 'registryPath')) {
        Assert-CodexHookString -Value $Plan.liveFacts.$stringProperty -Name "plan liveFacts.$stringProperty"
    }
    if ($Plan.sourceFacts.mappingIdentity -cne $Plan.liveFacts.mappingIdentity) { throw 'deployment plan mapping identity 不一致。' }
    [void](Assert-CodexHookMappingIdentity -Value ([string]$Plan.sourceFacts.mappingIdentity) -Name 'deployment plan mappingIdentity')
    if ($Plan.sourceFacts.manifestSha256 -cne $Plan.manifestSha256) { throw 'deployment plan manifest hash 不一致。' }
    [void](Assert-CodexHookDPath -Value ([string]$Plan.sourceFacts.manifestPath) -Name 'plan manifestPath')
    [void](Assert-CodexHookFixturePath -Path ([string]$Plan.sourceFacts.sourceRoot) -Name 'plan sourceRoot')
    [void](Assert-CodexHookFixturePath -Path ([string]$Plan.liveFacts.codexHome) -Name 'plan codexHome')
    [void](Assert-CodexHookFixturePath -Path ([string]$Plan.liveFacts.hooksRoot) -Name 'plan hooksRoot')
    [void](Assert-CodexHookFixturePath -Path ([string]$Plan.liveFacts.registryPath) -Name 'plan registryPath')
    if ([IO.Path]::GetFullPath([string]$Plan.liveFacts.registryPath) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Plan.liveFacts.codexHome) 'hooks.json'))) {
        throw 'deployment plan registryPath 与 codexHome 映射不一致。'
    }
    if ([IO.Path]::GetFullPath([string]$Plan.liveFacts.hooksRoot) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Plan.liveFacts.codexHome) 'hooks'))) {
        throw 'deployment plan hooksRoot 与 codexHome 映射不一致。'
    }

    Assert-CodexHookArray -Value ([object]$Plan.sourceFacts.files) -Name 'plan sourceFacts.files'
    Assert-CodexHookArray -Value ([object]$Plan.liveFacts.files) -Name 'plan liveFacts.files'
    Assert-CodexHookArray -Value ([object]$Plan.sourceFacts.blockerReasonCodes) -Name 'plan sourceFacts.blockerReasonCodes'
    Assert-CodexHookArray -Value ([object]$Plan.liveFacts.blockerReasonCodes) -Name 'plan liveFacts.blockerReasonCodes'
    $allowedBlockers = @('registry-ownership-ambiguous', 'source-fact-mismatch', 'live-target-unsafe', 'environment-fact-missing', 'retired-live-not-retained')
    $sourceBlockers = @($Plan.sourceFacts.blockerReasonCodes)
    $liveBlockers = @($Plan.liveFacts.blockerReasonCodes)
    if (-not (Test-CodexHookExactStringSequence -Actual $sourceBlockers -Expected $liveBlockers)) { throw 'plan blocker reason codes 不一致。' }
    foreach ($code in $sourceBlockers) {
        if ($code -isnot [string] -or $allowedBlockers -cnotcontains [string]$code) { throw 'plan blocker reason code 非法。' }
    }
    if ($sourceBlockers.Count -ne 0) { throw 'applyEligible plan 不得包含 blocker。' }

    $sourcePathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fact in @($Plan.sourceFacts.files)) {
        Assert-CodexHookExactProperties -Value $fact -Names @('relativePath', 'path', 'exists', 'probeState', 'sha256') -Scope 'plan source file fact'
        Assert-CodexHookRelativePath -Value $fact.relativePath -Name 'plan source file relativePath'
        $factPath = Assert-CodexHookFixturePath -Path ([string]$fact.path) -Name 'plan source file path'
        if (-not (Test-CodexHookPathWithin -Path $factPath -ParentPath ([string]$Plan.sourceFacts.sourceRoot)) -or -not $sourcePathSet.Add([string]$fact.relativePath)) {
            throw 'plan source file mapping 重复或越界。'
        }
        if ($fact.exists -isnot [bool] -or $fact.probeState -cnotin @('regular-file', 'missing')) { throw 'plan source file state 非法。' }
        if ($fact.exists -and [string]$fact.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'plan source file hash 非法。' }
        if (-not $fact.exists -and $null -ne $fact.sha256) { throw 'missing source file 不得有 hash。' }
    }
    $livePathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fact in @($Plan.liveFacts.files)) {
        Assert-CodexHookExactProperties -Value $fact -Names @('liveRelativePath', 'path', 'exists', 'probeState', 'sha256') -Scope 'plan live file fact'
        Assert-CodexHookRelativePath -Value $fact.liveRelativePath -Name 'plan live file relativePath'
        $factPath = Assert-CodexHookFixturePath -Path ([string]$fact.path) -Name 'plan live file path'
        if (-not (Test-CodexHookPathWithin -Path $factPath -ParentPath ([string]$Plan.liveFacts.hooksRoot)) -or -not $livePathSet.Add([string]$fact.liveRelativePath)) {
            throw 'plan live file mapping 重复或越界。'
        }
        if ($fact.exists -isnot [bool] -or $fact.probeState -cnotin @('regular-file', 'missing')) { throw 'plan live file state 非法。' }
        if ($fact.exists -and [string]$fact.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'plan live file hash 非法。' }
        if (-not $fact.exists -and $null -ne $fact.sha256) { throw 'missing live file 不得有 hash。' }
    }

    Assert-CodexHookArray -Value ([object]$Plan.actions) -Name 'plan actions'
    Assert-CodexHookArray -Value ([object]$Plan.environmentActions) -Name 'plan environmentActions'
    Assert-CodexHookArray -Value ([object]$Plan.postChecks) -Name 'plan postChecks'
    $actionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $restoreOrders = [Collections.Generic.HashSet[int]]::new()
    foreach ($action in @($Plan.actions)) {
        Assert-CodexHookExactProperties -Value $action -Names @(
            'actionId', 'phase', 'kind', 'sourceRef', 'sourceSha256', 'logicalTarget', 'targetPath',
            'beforeExists', 'beforeSha256', 'afterSha256', 'restoreOrder'
        ) -Scope 'plan action'
        Assert-CodexHookString -Value $action.actionId -Name 'plan actionId'
        Assert-CodexHookString -Value $action.phase -Name 'plan action phase'
        Assert-CodexHookString -Value $action.kind -Name 'plan action kind'
        Assert-CodexHookString -Value $action.logicalTarget -Name 'plan action logicalTarget'
        Assert-CodexHookString -Value $action.targetPath -Name 'plan action targetPath'
        if (-not $actionIds.Add([string]$action.actionId)) { throw 'plan actionId 重复。' }
        if ($action.kind -cnotin @('file', 'registry') -or $action.phase -cnotin @('implementation', 'wrapper', 'registry')) { throw 'plan action kind/phase 非法。' }
        if (($action.kind -ceq 'registry') -ne ($action.phase -ceq 'registry')) { throw 'plan registry action kind/phase 不一致。' }
        if ($action.beforeExists -isnot [bool]) { throw 'plan action beforeExists 必须是 boolean。' }
        Assert-CodexHookInteger -Value $action.restoreOrder -Name 'plan action restoreOrder'
        if ([int]$action.restoreOrder -le 0 -or -not $restoreOrders.Add([int]$action.restoreOrder)) { throw 'plan restoreOrder 非法或重复。' }
        if ([string]$action.afterSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'plan action after hash 非法。' }
        if ($action.beforeExists -and [string]$action.beforeSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'plan action before hash 非法。' }
        if (-not $action.beforeExists -and $null -ne $action.beforeSha256) { throw 'missing action target 不得有 before hash。' }
        $targetPath = Assert-CodexHookFixturePath -Path ([string]$action.targetPath) -Name 'plan action targetPath'
        if ($action.kind -ceq 'file') {
            Assert-CodexHookRelativePath -Value $action.sourceRef -Name 'plan action sourceRef'
            Assert-CodexHookRelativePath -Value $action.logicalTarget -Name 'plan action logicalTarget'
            if ([string]$action.sourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-CodexHookPathWithin -Path $targetPath -ParentPath ([string]$Plan.liveFacts.hooksRoot))) {
                throw 'plan file action source/hash/target 非法。'
            }
        } else {
            if ($null -ne $action.sourceRef -or $null -ne $action.sourceSha256 -or $action.logicalTarget -cne 'hooks.json' -or $targetPath -ine [string]$Plan.liveFacts.registryPath) {
                throw 'plan registry action contract 非法。'
            }
        }
    }
    foreach ($action in @($Plan.environmentActions)) {
        Assert-CodexHookExactProperties -Value $action -Names @(
            'actionId', 'phase', 'kind', 'name', 'scope', 'after', 'beforePresent', 'beforeMatchesTarget',
            'beforeValueSha256', 'afterValueSha256', 'restoreOrder'
        ) -Scope 'plan environment action'
        foreach ($stringProperty in @('actionId', 'phase', 'kind', 'name', 'scope', 'after', 'beforeValueSha256', 'afterValueSha256')) {
            Assert-CodexHookString -Value $action.$stringProperty -Name "plan environment action $stringProperty"
        }
        if (
            $action.phase -cne 'environment' -or $action.kind -cne 'environment' -or
            $action.name -cne 'SERENA_HOME' -or $action.scope -cne 'User' -or $action.after -cne 'D:\Codex\.serena'
        ) { throw 'plan environment action 未授权。' }
        if (-not $actionIds.Add([string]$action.actionId)) { throw 'plan environment actionId 重复。' }
        Assert-CodexHookInteger -Value $action.restoreOrder -Name 'plan environment restoreOrder'
        if ([int]$action.restoreOrder -le 0 -or -not $restoreOrders.Add([int]$action.restoreOrder)) { throw 'plan environment restoreOrder 重复。' }
        if ($action.beforePresent -isnot [bool] -or $action.beforeMatchesTarget -isnot [bool]) { throw 'plan environment before flags 非法。' }
        if ([string]$action.beforeValueSha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$action.afterValueSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'plan environment freshness hash 非法。' }
    }
    $postCheckIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($postCheck in @($Plan.postChecks)) {
        Assert-CodexHookExactProperties -Value $postCheck -Names @('actionId', 'kind', 'expectedSha256') -Scope 'plan postCheck'
        Assert-CodexHookString -Value $postCheck.actionId -Name 'plan postCheck actionId'
        Assert-CodexHookString -Value $postCheck.kind -Name 'plan postCheck kind'
        Assert-CodexHookString -Value $postCheck.expectedSha256 -Name 'plan postCheck expectedSha256'
        if ($postCheck.kind -cne 'sha256' -or -not $actionIds.Contains([string]$postCheck.actionId) -or -not $postCheckIds.Add([string]$postCheck.actionId)) { throw 'plan postCheck 非 allowlisted action。' }
        if ([string]$postCheck.expectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'plan postCheck hash 非法。' }
    }
    return $true
}

function Get-CodexHookEnvironmentValueFact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][scriptblock]$ReadValue,
        [Parameter(Mandatory)][string]$Desired
    )

    $readResult = & $ReadValue $Name $Scope
    if ($null -ne $readResult -and $readResult.PSObject.Properties.Name -contains 'present' -and $readResult.PSObject.Properties.Name -contains 'value') {
        $present = [bool]$readResult.present
        $value = if ($present) { [string]$readResult.value } else { $null }
    } else {
        $present = $null -ne $readResult
        $value = if ($present) { [string]$readResult } else { $null }
    }
    return [pscustomobject][ordered]@{
        name = $Name
        scope = $Scope
        present = $present
        matchesTarget = $present -and [string]::Equals($value, $Desired, [StringComparison]::Ordinal)
        valueSha256 = Get-CodexHookTextSha256 -Text ($(if ($present) { "present`0$value" } else { 'absent' }))
        value = $value
    }
}

function Invoke-CodexHookEnvironmentAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][scriptblock]$ReadValue,
        [Parameter(Mandatory)][scriptblock]$WriteValue,
        [switch]$Restore,
        [AllowNull()][object]$RestoreValue
    )

    if ($Action.name -cne 'SERENA_HOME' -or $Action.scope -cne 'User' -or $Action.after -cne 'D:\Codex\.serena') {
        throw '拒绝未授权的环境动作。'
    }
    if ($Restore) {
        if ($null -eq $RestoreValue -or $RestoreValue.PSObject.Properties.Name -notcontains 'present' -or $RestoreValue.PSObject.Properties.Name -notcontains 'value') {
            throw '环境 restore value 形状非法。'
        }
        & $WriteValue $Action.name $Action.scope $(if ($RestoreValue.present) { [string]$RestoreValue.value } else { $null })
    } else {
        & $WriteValue $Action.name $Action.scope $Action.after
    }
}

function Get-CodexHookFixtureFileSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Assert-CodexHookFixturePath -Path $Path -Name $Name
    $snapshot = Get-CodexHookHandleBoundFileSnapshot -Path $fullPath -Name $Name -AllowedExactPaths @($fullPath)
    return [pscustomobject][ordered]@{
        path = $fullPath
        exists = $snapshot.probe.exists -eq $true
        state = [string]$snapshot.probe.state
        sha256 = if ($snapshot.probe.safeToRead) { Get-CodexHookBytesSha256 -Bytes ([byte[]]$snapshot.bytes) } else { $null }
        bytes = if ($snapshot.probe.safeToRead) { [byte[]]$snapshot.bytes } else { $null }
    }
}

function Assert-CodexHookCapabilityPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Assert-CodexHookDPath -Value $Path -Name $Name
    $fullRoot = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Name capability root"
    if (-not (Test-CodexHookPathWithin -Path $fullPath -ParentPath $fullRoot)) {
        throw "$Name 超出 capability root。"
    }
    if ($fullPath.Substring(2).Contains(':')) {
        throw "$Name 不得包含 NTFS alternate data stream。"
    }
    if ($AllowedExactPaths.Count -gt 0) {
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($candidate in $AllowedExactPaths) {
            [void]$allowed.Add((Assert-CodexHookDPath -Value $candidate -Name "$Name allowed exact path"))
        }
        if (-not $allowed.Contains($fullPath)) {
            throw "$Name 不在 exact-path capability allowlist。"
        }
    }
    Assert-CodexHookNoReparseAncestor -Path $fullPath -Name $Name
    return $fullPath
}

function Get-CodexHookCapabilityFileSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Name
    $snapshot = Get-CodexHookHandleBoundFileSnapshot -Path $fullPath -Name $Name -AllowedExactPaths @($fullPath)
    return [pscustomobject][ordered]@{
        path = $fullPath
        exists = $snapshot.probe.exists -eq $true
        state = [string]$snapshot.probe.state
        sha256 = if ($snapshot.probe.safeToRead) { Get-CodexHookBytesSha256 -Bytes ([byte[]]$snapshot.bytes) } else { $null }
        bytes = if ($snapshot.probe.safeToRead) { [byte[]]$snapshot.bytes } else { $null }
    }
}

function New-CodexHookCapabilityDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [string]$Name = 'capability directory',
        [switch]$RequireMissing
    )

    $fullPath = Assert-CodexHookCapabilityPath -Path $Path -CapabilityRoot $CapabilityRoot -Name $Name
    $fullRoot = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Name capability root"
    $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $fullRoot,
        $fullPath,
        $true,
        $RequireMissing.IsPresent)
    try {
        return $fullPath
    } finally {
        $guard.Dispose()
    }
}

function Assert-CodexHookSnapshotExpectedState {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][bool]$ExpectedExists,
        [AllowNull()][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($ExpectedExists) {
        if (-not $Snapshot.exists -or $Snapshot.state -cne 'regular-file' -or $Snapshot.sha256 -cne $ExpectedSha256) {
            throw "$Scope 临写前状态漂移。"
        }
    } elseif ($Snapshot.exists -or $Snapshot.state -cne 'missing') {
        throw "$Scope 临写前 missing 状态漂移。"
    }
}

function Set-CodexHookAtomicFileBytesWithCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][bool]$ExpectedExists,
        [AllowNull()][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$AfterSha256,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [string]$Scope = 'atomic publish',
        [scriptblock]$BeforeMove,
        [scriptblock]$TestAfterPremoveSnapshot
    )

    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Scope
    if ((Get-CodexHookBytesSha256 -Bytes $Bytes) -cne $AfterSha256) {
        throw "$Scope 待发布 bytes 与 after SHA-256 不一致。"
    }

    $parent = Split-Path -Parent $fullPath
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Scope capability root"
    $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $capabilityRootPath,
        $parent,
        $false)
    try {
        $before = Get-CodexHookCapabilityFileSnapshot `
            -Path $fullPath `
            -CapabilityRoot $capabilityRootPath `
            -AllowedExactPaths $AllowedExactPaths `
            -Name "$Scope prewrite"
        Assert-CodexHookSnapshotExpectedState -Snapshot $before -ExpectedExists $ExpectedExists -ExpectedSha256 $ExpectedSha256 -Scope $Scope
        $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if (-not $parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Scope target parent 非安全普通目录。"
        }
        $tempPath = Join-Path $parent ".codex-hook-$([guid]::NewGuid().ToString('N')).tmp"
        $tempFile = $null
        $targetLease = $null
        try {
            $tempFile = $directoryGuard.CreateTempFile($tempPath)
            $tempFile.WriteAndFlush($Bytes)
            if ($null -ne $BeforeMove) { & $BeforeMove $fullPath }
            if ($ExpectedExists) {
                $targetLease = $directoryGuard.AcquireTargetFileLease($fullPath)
                [byte[]]$leasedBytes = $targetLease.SnapshotBytes
                $preMove = [pscustomobject][ordered]@{
                    path = $fullPath
                    exists = $true
                    state = 'regular-file'
                    sha256 = Get-CodexHookBytesSha256 -Bytes $leasedBytes
                    bytes = $leasedBytes
                }
            } else {
                $preMove = Get-CodexHookCapabilityFileSnapshot `
                    -Path $fullPath `
                    -CapabilityRoot $capabilityRootPath `
                    -AllowedExactPaths $AllowedExactPaths `
                    -Name "$Scope premove"
            }
            Assert-CodexHookSnapshotExpectedState -Snapshot $preMove -ExpectedExists $ExpectedExists -ExpectedSha256 $ExpectedSha256 -Scope "$Scope premove"
            if ($null -ne $TestAfterPremoveSnapshot) { & $TestAfterPremoveSnapshot $fullPath }
            [void](Assert-CodexHookCapabilityPath -Path $parent -CapabilityRoot $capabilityRootPath -Name "$Scope parent premove")
            $tempFile.RenameTo($fullPath, $ExpectedExists)
        } finally {
            try {
                try {
                    if ($null -ne $tempFile) { $tempFile.Dispose() }
                } finally {
                    if ($null -ne $targetLease) { $targetLease.Dispose() }
                }
            } finally {
                if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
            }
        }

        $after = Get-CodexHookCapabilityFileSnapshot `
            -Path $fullPath `
            -CapabilityRoot $capabilityRootPath `
            -AllowedExactPaths $AllowedExactPaths `
            -Name "$Scope postwrite"
        Assert-CodexHookSnapshotExpectedState -Snapshot $after -ExpectedExists $true -ExpectedSha256 $AfterSha256 -Scope "$Scope postcheck"
    } finally {
        $directoryGuard.Dispose()
    }
}

function Remove-CodexHookCapabilityFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [string]$Scope = 'capability conditional delete',
        [scriptblock]$TestAfterSnapshot
    )

    $fullPath = Assert-CodexHookCapabilityPath -Path $Path -CapabilityRoot $CapabilityRoot -AllowedExactPaths $AllowedExactPaths -Name $Scope
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Scope capability root"
    $parent = Split-Path -Parent $fullPath
    $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($capabilityRootPath, $parent, $false)
    $targetLease = $null
    try {
        $targetLease = $directoryGuard.AcquireTargetFileLease($fullPath)
        [byte[]]$leasedBytes = $targetLease.ReadAllBytesFromHandle()
        $leasedSha256 = Get-CodexHookBytesSha256 -Bytes $leasedBytes
        if ($leasedSha256 -cne $ExpectedSha256) { throw "$Scope 临删前状态漂移。" }
        if ($null -ne $TestAfterSnapshot) { & $TestAfterSnapshot $fullPath }
        [byte[]]$confirmedBytes = $targetLease.ReadAllBytesFromHandle()
        if ((Get-CodexHookBytesSha256 -Bytes $confirmedBytes) -cne $ExpectedSha256) { throw "$Scope handle identity 内容漂移。" }
        $targetLease.DeleteWithPosixSemantics()
    } finally {
        if ($null -ne $targetLease) { $targetLease.Dispose() }
        $directoryGuard.Dispose()
    }
    $after = Get-CodexHookCapabilityFileSnapshot -Path $fullPath -CapabilityRoot $capabilityRootPath -AllowedExactPaths $AllowedExactPaths -Name "$Scope postdelete"
    Assert-CodexHookSnapshotExpectedState -Snapshot $after -ExpectedExists $false -ExpectedSha256 $null -Scope "$Scope postcheck"
}

function Set-CodexHookAtomicFileBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][bool]$ExpectedExists,
        [AllowNull()][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$AfterSha256,
        [string]$Scope = 'atomic publish',
        [scriptblock]$BeforeMove,
        [scriptblock]$TestAfterPremoveSnapshot
    )

    $fullPath = Assert-CodexHookFixturePath -Path $Path -Name $Scope
    Set-CodexHookAtomicFileBytesWithCapability `
        -Path $fullPath `
        -Bytes $Bytes `
        -ExpectedExists $ExpectedExists `
        -ExpectedSha256 $ExpectedSha256 `
        -AfterSha256 $AfterSha256 `
        -CapabilityRoot 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test' `
        -AllowedExactPaths @($fullPath) `
        -Scope $Scope `
        -BeforeMove $BeforeMove `
        -TestAfterPremoveSnapshot $TestAfterPremoveSnapshot
}

function Set-CodexHookCapabilityJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [string]$Scope = 'capability json'
    )

    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Document | ConvertTo-Json -Depth 100))
    $existing = Get-CodexHookCapabilityFileSnapshot `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name "$Scope before"
    Set-CodexHookAtomicFileBytesWithCapability `
        -Path $Path `
        -Bytes $bytes `
        -ExpectedExists $existing.exists `
        -ExpectedSha256 $existing.sha256 `
        -AfterSha256 (Get-CodexHookBytesSha256 -Bytes $bytes) `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Scope $Scope
}

function Remove-CodexHookFixtureFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [string]$Scope = 'fixture delete'
    )

    $fullPath = Assert-CodexHookFixturePath -Path $Path -Name $Scope
    $directoryGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath (Split-Path -Parent $fullPath)
    try {
        $current = Get-CodexHookFixtureFileSnapshot -Path $fullPath -Name "$Scope predelete"
        Assert-CodexHookSnapshotExpectedState -Snapshot $current -ExpectedExists $true -ExpectedSha256 $ExpectedSha256 -Scope $Scope
        [IO.File]::Delete($fullPath)
        $after = Get-CodexHookFixtureFileSnapshot -Path $fullPath -Name "$Scope postdelete"
        Assert-CodexHookSnapshotExpectedState -Snapshot $after -ExpectedExists $false -ExpectedSha256 $null -Scope "$Scope postcheck"
    } finally {
        $directoryGuard.Dispose()
    }
}

function Set-CodexHookEvidenceJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Document | ConvertTo-Json -Depth 100))
    $existing = Get-CodexHookFixtureFileSnapshot -Path $Path -Name 'evidence json'
    Set-CodexHookAtomicFileBytes `
        -Path $Path `
        -Bytes $bytes `
        -ExpectedExists $existing.exists `
        -ExpectedSha256 $existing.sha256 `
        -AfterSha256 (Get-CodexHookBytesSha256 -Bytes $bytes) `
        -Scope 'evidence json'
}

function Restore-CodexHookDeploymentCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][scriptblock]$EnvironmentReadValue,
        [Parameter(Mandatory)][scriptblock]$EnvironmentWriteValue,
        [ValidateSet('restored', 'rolled-back')][string]$FinalStatus = 'restored'
    )

    $evidencePath = Assert-CodexHookFixturePath -Path $EvidenceDirectory -Name 'EvidenceDirectory'
    $restoreManifestPath = Join-Path $evidencePath 'restore-manifest.json'

    # Read only enough identity to select the mapping-scoped mutex. The authoritative
    # manifest is re-read and fully validated after the mutex is held.
    $identitySnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $restoreManifestPath -Name 'restore manifest identity' -AllowedExactPaths @($restoreManifestPath)
    Assert-CodexHookStrictJsonText -JsonText $identitySnapshot.text
    $identityRestore = $identitySnapshot.text | ConvertFrom-Json -Depth 128 -ErrorAction Stop
    Assert-CodexHookExactProperties -Value $identityRestore -Names @(
        'artifactType', 'schemaVersion', 'generationId', 'planSha256', 'mappingIdentity', 'actions'
    ) -Scope 'restore manifest identity'
    if ($identityRestore.artifactType -cne 'env-governance.codex-hook-restore-manifest' -or [int]$identityRestore.schemaVersion -ne 1) {
        throw 'restore manifest artifact/schema 非法。'
    }
    [void](Assert-CodexHookGenerationId -Value ([string]$identityRestore.generationId) -Name 'restore generationId')
    [void](Assert-CodexHookMappingIdentity -Value ([string]$identityRestore.mappingIdentity) -Name 'restore mappingIdentity')

    $mutexName = Get-CodexHookFixtureDeploymentMutexName -MappingIdentity ([string]$identityRestore.mappingIdentity)
    $deploymentMutex = [Threading.Mutex]::new($false, $mutexName)
    $mutexHeld = $false
    try {
        $mutexHeld = $deploymentMutex.WaitOne(0)
        if (-not $mutexHeld) { throw 'deployment mutex busy；restore 已拒绝。' }

        $restoreSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $restoreManifestPath -Name 'restore manifest' -AllowedExactPaths @($restoreManifestPath)
        Assert-CodexHookStrictJsonText -JsonText $restoreSnapshot.text
        $restore = $restoreSnapshot.text | ConvertFrom-Json -Depth 128 -ErrorAction Stop
        Assert-CodexHookExactProperties -Value $restore -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'planSha256', 'mappingIdentity', 'actions'
        ) -Scope 'restore manifest'
        if (
            $restore.artifactType -cne 'env-governance.codex-hook-restore-manifest' -or
            [int]$restore.schemaVersion -ne 1 -or
            $restore.generationId -cne $identityRestore.generationId -or
            $restore.mappingIdentity -cne $identityRestore.mappingIdentity
        ) {
            throw 'restore manifest identity 在 mutex 获取前后不一致。'
        }
        [void](Assert-CodexHookGenerationId -Value ([string]$restore.generationId) -Name 'restore generationId')
        [void](Assert-CodexHookMappingIdentity -Value ([string]$restore.mappingIdentity) -Name 'restore mappingIdentity')
        if ([string]$restore.planSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'restore planSha256 非法。' }

        $lifecyclePaths = Get-CodexHookFixtureLifecyclePaths `
            -MappingIdentity ([string]$restore.mappingIdentity) `
            -GenerationId ([string]$restore.generationId)
        $claimPath = [string]$lifecyclePaths.claimPath
    $claimSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $claimPath -Name 'deployment claim' -AllowedExactPaths @($claimPath)
    Assert-CodexHookStrictJsonText -JsonText $claimSnapshot.text
    $claim = $claimSnapshot.text | ConvertFrom-Json -Depth 32 -ErrorAction Stop
    Assert-CodexHookExactProperties -Value $claim -Names @(
        'artifactType', 'schemaVersion', 'state', 'generationId', 'mappingIdentity', 'planSha256', 'evidenceDirectory', 'restoreManifestSha256'
    ) -Scope 'deployment claim'
    if (
        $claim.artifactType -cne 'env-governance.codex-hook-deployment-claim' -or
        [int]$claim.schemaVersion -ne 1 -or
        $claim.state -cne 'prepared' -or
        $claim.generationId -cne $restore.generationId -or
        $claim.mappingIdentity -cne $restore.mappingIdentity -or
        $claim.planSha256 -cne $restore.planSha256 -or
        [IO.Path]::GetFullPath([string]$claim.evidenceDirectory) -ine $evidencePath -or
        $claim.restoreManifestSha256 -cne $restoreSnapshot.sha256
    ) {
        throw 'deployment claim 与 restore manifest 不一致。'
    }

        $statusPath = Join-Path $evidencePath 'status.json'
        $statusSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $statusPath -Name 'deployment status' -AllowedExactPaths @($statusPath)
        Assert-CodexHookStrictJsonText -JsonText $statusSnapshot.text
        $oldStatus = $statusSnapshot.text | ConvertFrom-Json -Depth 32 -ErrorAction Stop
        Assert-CodexHookExactProperties -Value $oldStatus -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'status', 'completedActionIds'
        ) -Scope 'deployment status'
        if (
            $oldStatus.artifactType -cne 'env-governance.codex-hook-deployment-status' -or
            [int]$oldStatus.schemaVersion -ne 1 -or
            $oldStatus.generationId -cne $restore.generationId -or
            $oldStatus.status -cnotin @('applying', 'rollback-pending', 'applied', 'rolled-back', 'restored')
        ) {
            throw 'deployment status schema/generation/状态非法。'
        }
        Assert-CodexHookArray -Value ([object]$oldStatus.completedActionIds) -Name 'deployment status completedActionIds'
        foreach ($completedActionId in @($oldStatus.completedActionIds)) {
            if ($completedActionId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$completedActionId)) {
                throw 'deployment status completedActionIds 非法。'
            }
        }
        if ($FinalStatus -ceq 'rolled-back' -and $oldStatus.status -cnotin @('rollback-pending', 'rolled-back')) {
            throw 'deployment status 不允许转为 rolled-back。'
        }
        if ($FinalStatus -ceq 'restored' -and $oldStatus.status -ceq 'rolled-back') {
            throw '已 rolled-back deployment 不得改写为 restored。'
        }

    $preflight = [Collections.Generic.List[object]]::new()
    foreach ($action in @($restore.actions)) {
        Assert-CodexHookExactProperties -Value $action -Names @(
            'actionId', 'kind', 'path', 'beforeExists', 'beforeSha256', 'backupRelativePath',
            'backupSha256', 'deployedExists', 'deployedSha256', 'restoreOrder',
            'environmentName', 'environmentScope', 'environmentAfter', 'environmentBeforeBackupRelativePath',
            'environmentBeforeBackupSha256'
        ) -Scope 'restore action'
        if ($action.kind -ceq 'environment') {
            if ($action.environmentName -cne 'SERENA_HOME' -or $action.environmentScope -cne 'User' -or $action.environmentAfter -cne 'D:\Codex\.serena') {
                throw 'restore environment action 未授权。'
            }
            $backupPath = Join-Path $evidencePath ([string]$action.environmentBeforeBackupRelativePath)
            if (-not (Test-CodexHookPathWithin -Path $backupPath -ParentPath (Join-Path $evidencePath 'backups'))) { throw 'environment backup 路径越界。' }
            $backupSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $backupPath -Name 'environment backup' -AllowedExactPaths @($backupPath)
            if ($backupSnapshot.sha256 -cne $action.environmentBeforeBackupSha256) { throw 'environment backup SHA-256 不一致。' }
            Assert-CodexHookStrictJsonText -JsonText $backupSnapshot.text
            $beforeValue = $backupSnapshot.text | ConvertFrom-Json -Depth 10 -ErrorAction Stop
            Assert-CodexHookExactProperties -Value $beforeValue -Names @('present', 'value') -Scope 'environment backup value'
            $current = Get-CodexHookEnvironmentValueFact -Name 'SERENA_HOME' -Scope 'User' -ReadValue $EnvironmentReadValue -Desired 'D:\Codex\.serena'
            $beforeHash = Get-CodexHookTextSha256 -Text ($(if ($beforeValue.present) { "present`0$($beforeValue.value)" } else { 'absent' }))
            $state = if ($current.valueSha256 -ceq $beforeHash) { 'already-before' } elseif ($current.valueSha256 -ceq $action.deployedSha256) { 'deployed' } else { 'drifted' }
            if ($state -ceq 'drifted') { throw 'environment restore preflight 检测到漂移。' }
            $preflight.Add([pscustomobject]@{
                action = $action
                state = $state
                backup = $beforeValue
                expectedBeforeValueSha256 = $beforeHash
            })
            continue
        }

        $targetPath = Assert-CodexHookFixturePath -Path ([string]$action.path) -Name 'restore target'
        $backupBytes = $null
        if ($action.beforeExists) {
            $backupPath = Join-Path $evidencePath ([string]$action.backupRelativePath)
            if (-not (Test-CodexHookPathWithin -Path $backupPath -ParentPath (Join-Path $evidencePath 'backups'))) { throw 'backup 路径越界。' }
            $backup = Get-CodexHookFixtureFileSnapshot -Path $backupPath -Name 'restore backup'
            if (-not $backup.exists -or $backup.sha256 -cne $action.backupSha256 -or $backup.sha256 -cne $action.beforeSha256) {
                throw 'restore backup SHA-256 不一致。'
            }
            $backupBytes = [byte[]]$backup.bytes
        } elseif ($null -ne $action.backupRelativePath -or $null -ne $action.backupSha256) {
            throw 'missing-before action 不得声明 backup。'
        }

        $current = Get-CodexHookFixtureFileSnapshot -Path $targetPath -Name 'restore current target'
        $isBefore = if ($action.beforeExists) { $current.exists -and $current.sha256 -ceq $action.beforeSha256 } else { -not $current.exists -and $current.state -ceq 'missing' }
        $isDeployed = if ($action.deployedExists) { $current.exists -and $current.sha256 -ceq $action.deployedSha256 } else { -not $current.exists -and $current.state -ceq 'missing' }
        $state = if ($isBefore) { 'already-before' } elseif ($isDeployed) { 'deployed' } else { 'drifted' }
        if ($state -ceq 'drifted') { throw 'restore preflight 检测到 target 漂移。' }
        $preflight.Add([pscustomobject]@{ action = $action; state = $state; backup = $backupBytes })
    }

    if ($oldStatus.status -cin @('rolled-back', 'restored') -and @($preflight | Where-Object state -cne 'already-before').Count -ne 0) {
        throw 'deployment terminal status 与 restore target 状态不一致。'
    }

    $knownActionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($preflight)) { [void]$knownActionIds.Add([string]$item.action.actionId) }
    $seenCompletedActionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($completedActionId in @($oldStatus.completedActionIds)) {
        if (-not $knownActionIds.Contains([string]$completedActionId) -or -not $seenCompletedActionIds.Add([string]$completedActionId)) {
            throw 'deployment status completedActionIds 与 restore manifest 不一致。'
        }
    }

    $changed = $false
    foreach ($item in @($preflight | Sort-Object { -[int]$_.action.restoreOrder })) {
        if ($item.state -ceq 'already-before') { continue }
        $action = $item.action
        if ($action.kind -ceq 'environment') {
            Invoke-CodexHookEnvironmentAction `
                -Action ([pscustomobject]@{ name = $action.environmentName; scope = $action.environmentScope; after = $action.environmentAfter }) `
                -ReadValue $EnvironmentReadValue `
                -WriteValue $EnvironmentWriteValue `
                -Restore `
                -RestoreValue $item.backup
            $restoredEnvironment = Get-CodexHookEnvironmentValueFact `
                -Name ([string]$action.environmentName) `
                -Scope ([string]$action.environmentScope) `
                -ReadValue $EnvironmentReadValue `
                -Desired ([string]$action.environmentAfter)
            if ($restoredEnvironment.valueSha256 -cne [string]$item.expectedBeforeValueSha256) {
                throw 'environment restore postcheck 失败。'
            }
        } elseif ($action.beforeExists) {
            Set-CodexHookAtomicFileBytes `
                -Path ([string]$action.path) `
                -Bytes ([byte[]]$item.backup) `
                -ExpectedExists ([bool]$action.deployedExists) `
                -ExpectedSha256 ([string]$action.deployedSha256) `
                -AfterSha256 ([string]$action.beforeSha256) `
                -Scope 'restore publish'
        } else {
            Remove-CodexHookFixtureFile -Path ([string]$action.path) -ExpectedSha256 ([string]$action.deployedSha256) -Scope 'restore remove'
        }
        $changed = $true
    }

    Set-CodexHookEvidenceJson -Path $statusPath -Document ([pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-deployment-status'
        schemaVersion = 1
        generationId = [string]$restore.generationId
        status = $FinalStatus
        completedActionIds = [string[]]@($oldStatus.completedActionIds)
    })

        return [pscustomobject][ordered]@{
        restored = $true
        idempotent = -not $changed
        evidenceDirectory = $evidencePath
        status = $FinalStatus
    }
    } finally {
        if ($mutexHeld) { [void]$deploymentMutex.ReleaseMutex() }
        $deploymentMutex.Dispose()
    }
}
