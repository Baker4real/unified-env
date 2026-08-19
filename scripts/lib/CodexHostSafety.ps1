Set-StrictMode -Version Latest

$codexHookHandleBoundSource = Join-Path $PSScriptRoot 'CodexHookHandleBoundIO.cs'
$codexSafeTreeDeleteFileIdentitySource = Join-Path $PSScriptRoot 'CodexSafeTreeDeleteFileIdentity.cs'
$codexSafeTreeDeleteHashCacheSource = Join-Path $PSScriptRoot 'CodexSafeTreeDeleteHashCache.cs'
$codexSafeTreeDeleteApplySnapshotSource = Join-Path $PSScriptRoot 'CodexSafeTreeDeleteApplySnapshot.cs'
$codexSafeTreeDeleteThreadJournalSource = Join-Path $PSScriptRoot 'CodexSafeTreeDeleteThreadJournal.cs'
$codexSafeTreeDeleteParallelPurgeSource = Join-Path $PSScriptRoot 'CodexSafeTreeDeleteParallelPurge.cs'
if (-not ('CodexHookGovernance.HandleBoundFileReader' -as [type])) {
    $hookAssemblyDirectory = [IO.Path]::Combine('D:\', 'Codex', 'temp', 'unified-env-addtype')
    [void][IO.Directory]::CreateDirectory($hookAssemblyDirectory)
    $hookAssemblyPath = Join-Path $hookAssemblyDirectory 'CodexHostSafetyNative.dll'
    $nativeSources = @(
        $codexHookHandleBoundSource,
        $codexSafeTreeDeleteFileIdentitySource,
        $codexSafeTreeDeleteHashCacheSource,
        $codexSafeTreeDeleteApplySnapshotSource,
        $codexSafeTreeDeleteThreadJournalSource,
        $codexSafeTreeDeleteParallelPurgeSource
    )
    $assemblyStale = -not [IO.File]::Exists($hookAssemblyPath)
    if (-not $assemblyStale) {
        $assemblyWriteTime = [IO.File]::GetLastWriteTimeUtc($hookAssemblyPath)
        foreach ($nativeSource in $nativeSources) {
            if ([IO.File]::GetLastWriteTimeUtc($nativeSource) -gt $assemblyWriteTime) {
                $assemblyStale = $true
                break
            }
        }
    }
    if ($assemblyStale) {
        Add-Type `
            -Path $nativeSources `
            -OutputAssembly $hookAssemblyPath `
            -OutputType Library `
            -ErrorAction Stop
    }
    Add-Type -Path $hookAssemblyPath -ErrorAction Stop
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
                identity = $null
            }
            bytes = $null
            sddl = $null
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
                    identity = $null
                }
                bytes = $null
                sddl = $null
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
                    identity = $null
                }
                bytes = $null
                sddl = $null
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
            identity = @(
                [string]$nativeSnapshot.VolumeSerialNumber,
                [string]$nativeSnapshot.FileIndex
            )
        }
        bytes = $bytes
        sddl = [string]$nativeSnapshot.SecurityDescriptorSddl
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

function Get-CodexHookTextSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-CodexHookBytesSha256 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
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

function Assert-CodexHookCapabilityLeafPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
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
    $parent = Split-Path -Parent $fullPath
    if ([string]::IsNullOrWhiteSpace($parent) -or
        [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($fullPath))) {
        throw "$Name 必须是普通父目录下的叶节点。"
    }
    [void](Assert-CodexHookCapabilityPath `
        -Path $parent `
        -CapabilityRoot $fullRoot `
        -Name "$Name parent")
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
        identity = if ($snapshot.probe.safeToRead) { @($snapshot.probe.identity) } else { @() }
        sddl = if ($snapshot.probe.safeToRead) { [string]$snapshot.sddl } else { $null }
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
        [Parameter(Mandatory)][string]$Scope,
        [AllowNull()][string[]]$ExpectedIdentity
    )

    if ($ExpectedExists) {
        if (-not $Snapshot.exists -or $Snapshot.state -cne 'regular-file' -or $Snapshot.sha256 -cne $ExpectedSha256) {
            throw "$Scope 临写前状态漂移。"
        }
        if ($null -ne $ExpectedIdentity -and @(Compare-Object @($ExpectedIdentity) @($Snapshot.identity)).Count -ne 0) {
            throw "$Scope 临写前文件身份漂移。"
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
        [scriptblock]$TestAfterPremoveSnapshot,
        [AllowNull()][string[]]$ExpectedIdentity,
        [scriptblock]$BeforeRename,
        [scriptblock]$AfterRename,
        [switch]$PreservePreparedTempOnRenameFailure,
        [scriptblock]$RenameAction
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
        Assert-CodexHookSnapshotExpectedState -Snapshot $before -ExpectedExists $ExpectedExists -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity -Scope $Scope
        $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if (-not $parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Scope target parent 非安全普通目录。"
        }
        $tempPath = Join-Path $parent ".codex-hook-$([guid]::NewGuid().ToString('N')).tmp"
        $tempFile = $null
        $targetLease = $null
        $beforeRenameCompleted = $false
        $renameSucceeded = $false
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
                    identity = @($targetLease.VolumeSerialNumber, $targetLease.FileIndex)
                }
            } else {
                $preMove = Get-CodexHookCapabilityFileSnapshot `
                    -Path $fullPath `
                    -CapabilityRoot $capabilityRootPath `
                    -AllowedExactPaths $AllowedExactPaths `
                    -Name "$Scope premove"
            }
            Assert-CodexHookSnapshotExpectedState -Snapshot $preMove -ExpectedExists $ExpectedExists -ExpectedSha256 $ExpectedSha256 -ExpectedIdentity $ExpectedIdentity -Scope "$Scope premove"
            if ($null -ne $TestAfterPremoveSnapshot) { & $TestAfterPremoveSnapshot $fullPath }
            [void](Assert-CodexHookCapabilityPath -Path $parent -CapabilityRoot $capabilityRootPath -Name "$Scope parent premove")
            if ($null -ne $BeforeRename) {
                [void](& $BeforeRename ([pscustomobject][ordered]@{
                    path = $tempFile.CurrentPath
                    sha256 = $AfterSha256
                    identity = @($tempFile.VolumeSerialNumber, $tempFile.FileIndex)
                }))
                $beforeRenameCompleted = $true
            }
            if ($null -ne $RenameAction) {
                [void](& $RenameAction $tempFile $fullPath $ExpectedExists)
            } else {
                $tempFile.RenameTo($fullPath, $ExpectedExists)
            }
            $renameSucceeded = $true
            if ($null -ne $AfterRename) {
                $publishedLease = $null
                try {
                    $publishedLease = $directoryGuard.AcquireAclTargetLease($fullPath)
                    [void](& $AfterRename $publishedLease $fullPath)
                } finally {
                    if ($null -ne $publishedLease) { $publishedLease.Dispose() }
                }
            }
        } finally {
            try {
                try {
                    if ($null -ne $tempFile) { $tempFile.Dispose() }
                } finally {
                    if ($null -ne $targetLease) { $targetLease.Dispose() }
                }
            } finally {
                $preservePrepared = $PreservePreparedTempOnRenameFailure -and $beforeRenameCompleted -and -not $renameSucceeded
                if (-not $preservePrepared -and [IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
            }
        }

        $after = Get-CodexHookCapabilityFileSnapshot `
            -Path $fullPath `
            -CapabilityRoot $capabilityRootPath `
            -AllowedExactPaths $AllowedExactPaths `
            -Name "$Scope postwrite"
        Assert-CodexHookSnapshotExpectedState -Snapshot $after -ExpectedExists $true -ExpectedSha256 $AfterSha256 -ExpectedIdentity $null -Scope "$Scope postcheck"
    } finally {
        $directoryGuard.Dispose()
    }
}

function Test-CodexHookDirectoryTreeIdentityEqual {
    param(
        [AllowNull()][object[]]$Expected,
        [AllowNull()][object[]]$Actual
    )

    return @($Expected).Count -eq 2 -and @($Actual).Count -eq 2 -and
        ([string]$Expected[0]) -ceq ([string]$Actual[0]) -and
        ([string]$Expected[1]) -ceq ([string]$Actual[1])
}

function Assert-CodexHookDirectoryTreeIdentity {
    param(
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][object[]]$Actual,
        [Parameter(Mandatory)][string]$Scope
    )

    if (@($Expected).Count -ne 2 -or
        ([string]$Expected[0]) -notmatch '^[0-9a-f]{8}$' -or
        ([string]$Expected[1]) -notmatch '^[0-9a-f]{16}$') {
        throw "$Scope expected identity 非法。"
    }
    if (@($Actual).Count -ne 2 -or
        ([string]$Actual[0]) -notmatch '^[0-9a-f]{8}$' -or
        ([string]$Actual[1]) -notmatch '^[0-9a-f]{16}$') {
        throw "$Scope observed identity 非法。"
    }
    if (-not (Test-CodexHookDirectoryTreeIdentityEqual -Expected $Expected -Actual $Actual)) {
        throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope 身份漂移。"
    }
}

function Get-CodexHookDirectoryTreeRelativeParent {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ($RelativePath -ceq '.') { return $null }
    $lastSlash = $RelativePath.LastIndexOf('/')
    if ($lastSlash -lt 0) { return '.' }
    return $RelativePath.Substring(0, $lastSlash)
}

function Get-CodexHookDirectoryTreeRelativeLeaf {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ($RelativePath -ceq '.') { return $null }
    $lastSlash = $RelativePath.LastIndexOf('/')
    if ($lastSlash -lt 0) { return $RelativePath }
    return $RelativePath.Substring($lastSlash + 1)
}

function Assert-CodexHookDirectoryTreeRelativePath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($RelativePath -ceq '.') { return }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.StartsWith('/') -or $RelativePath.EndsWith('/') -or
        $RelativePath.Contains('\') -or $RelativePath.Contains(':')) {
        throw "$Scope relativePath 非法。"
    }
    foreach ($segment in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
            $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $segment.EndsWith(' ') -or $segment.EndsWith('.')) {
            throw "$Scope relativePath 含不安全路径段。"
        }
    }
}

function Assert-CodexHookDirectoryTreeExactProperties {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($null -eq $Value -or $null -eq $Value.PSObject) {
        throw "$Scope 不是对象。"
    }
    $actual = @($Value.PSObject.Properties.Name)
    if (@($actual | Where-Object { $_ -notin $Names }).Count -ne 0 -or
        @($Names | Where-Object { $_ -notin $actual }).Count -ne 0) {
        throw "$Scope 属性集合非法。"
    }
}

function Get-CodexHookCapabilityDirectoryTreeSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [switch]$AllowHardLinks,
        [switch]$AllowInternalDirectoryJunctions,
        [string]$InternalDirectoryJunctionTargetRoot,
        [scriptblock]$MetricsObserver,
        [scriptblock]$FileContentHashProvider,
        [string]$Name = 'capability directory-tree snapshot'
    )

    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Name
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Name capability root"
    $junctionTargetRoot = $null
    if ($AllowInternalDirectoryJunctions) {
        if ([string]::IsNullOrWhiteSpace($InternalDirectoryJunctionTargetRoot)) {
            throw "$Name 允许内部 junction 时必须提供 target root。"
        }
        $junctionTargetRoot = Assert-CodexHookDPath `
            -Value $InternalDirectoryJunctionTargetRoot `
            -Name "$Name internal junction target root"
        if (-not (Test-CodexHookPathWithin -Path $junctionTargetRoot -ParentPath $capabilityRootPath)) {
            throw "$Name internal junction target root 超出 capability root。"
        }
    }
    $entries = [Collections.Generic.List[object]]::new()
    $rootGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $capabilityRootPath,
        $fullPath,
        $false)
    try {
        function Add-CodexHookCapabilityDirectoryTreeSnapshotNode {
            param(
                [Parameter(Mandatory)][string]$DirectoryPath,
                [Parameter(Mandatory)][string]$RelativePath,
                [Parameter(Mandatory)][object]$DirectoryGuard
            )

            $item = Get-Item -LiteralPath $DirectoryPath -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name snapshot 遇到非安全普通目录：$DirectoryPath"
            }
            $entries.Add([pscustomobject][ordered]@{
                relativePath = $RelativePath
                kind = 'directory'
                sha256 = $null
                identity = @([string]$DirectoryGuard.VolumeSerialNumber, [string]$DirectoryGuard.FileIndex)
            })
            if ($null -ne $MetricsObserver) { & $MetricsObserver 'directory' 0L 0L }
            $children = @(Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction Stop | Sort-Object -Property Name)
            foreach ($child in $children) {
                $childPath = Join-Path $DirectoryPath $child.Name
                $childRelative = if ($RelativePath -ceq '.') { $child.Name } else { "$RelativePath/$($child.Name)" }
                $childItem = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
                if (($childItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    if (-not $AllowInternalDirectoryJunctions -or -not $childItem.PSIsContainer) {
                        throw "$Name snapshot 包含未授权 reparse point：$childPath"
                    }
                    [void](Assert-CodexHookCapabilityLeafPath `
                        -Path $childPath `
                        -CapabilityRoot $capabilityRootPath `
                        -Name "$Name snapshot junction leaf")
                    $junctionLease = $null
                    try {
                        $junctionLease = $DirectoryGuard.AcquireSafeTreeDeleteReparseLeafLease($childPath)
                        $junctionTarget = Assert-CodexHookDPath `
                            -Value ([string]$junctionLease.TargetPath) `
                            -Name "$Name snapshot junction target"
                        if (-not (Test-CodexHookPathWithin -Path $junctionTarget -ParentPath $junctionTargetRoot)) {
                            throw "$Name snapshot junction target 越界：$childPath"
                        }
                        [byte[]]$junctionSha256 = $junctionLease.ReparseDataSha256
                        $entries.Add([pscustomobject][ordered]@{
                            relativePath = $childRelative
                            kind = 'directory-junction'
                            sha256 = [Convert]::ToHexString($junctionSha256).ToLowerInvariant()
                            identity = @(
                                [string]$junctionLease.VolumeSerialNumber,
                                [string]$junctionLease.FileIndex)
                        })
                        if ($null -ne $MetricsObserver) {
                            & $MetricsObserver 'directory-junction' 0L ([long]$junctionLease.ReparseDataLength)
                        }
                    } finally {
                        if ($null -ne $junctionLease) { $junctionLease.Dispose() }
                    }
                    continue
                }
                [void](Assert-CodexHookCapabilityPath `
                    -Path $childPath `
                    -CapabilityRoot $capabilityRootPath `
                    -Name "$Name snapshot child")
                if ($childItem.PSIsContainer) {
                    $childGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
                        $capabilityRootPath,
                        $childPath,
                        $false)
                    try {
                        Add-CodexHookCapabilityDirectoryTreeSnapshotNode `
                            -DirectoryPath $childPath `
                            -RelativePath $childRelative `
                            -DirectoryGuard $childGuard
                    } finally {
                        $childGuard.Dispose()
                    }
                    continue
                }

                $parentGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
                    $capabilityRootPath,
                    $DirectoryPath,
                    $false)
                $lease = $null
                try {
                    $lease = $parentGuard.AcquireSafeTreeDeleteFileLease(
                        $childPath,
                        $AllowHardLinks.IsPresent)
                    $length = [long]$lease.Length
                    $fileIdentity = @([string]$lease.VolumeSerialNumber, [string]$lease.FileIndex)
                    [byte[]]$sha256 = $null
                    if ($null -ne $FileContentHashProvider) {
                        $provided = & $FileContentHashProvider $childPath $childRelative $length $lease
                        if ($provided -is [byte[]]) {
                            $sha256 = $provided
                        } elseif ($null -ne $provided) {
                            $sha256 = [byte[]]@($provided)
                        }
                        if ($null -eq $sha256 -or $sha256.Length -ne 32) {
                            throw "$Name FileContentHashProvider 必须返回 32 字节 SHA-256。"
                        }
                    } else {
                        $sha256 = $lease.ComputeSha256FromHandle()
                    }
                    $entries.Add([pscustomobject][ordered]@{
                        relativePath = $childRelative
                        kind = 'file'
                        sha256 = [Convert]::ToHexString($sha256).ToLowerInvariant()
                        identity = $fileIdentity
                    })
                    if ($null -ne $MetricsObserver) { & $MetricsObserver 'file' $length $length }
                } finally {
                    if ($null -ne $lease) { $lease.Dispose() }
                    $parentGuard.Dispose()
                }
            }
        }

        Add-CodexHookCapabilityDirectoryTreeSnapshotNode `
            -DirectoryPath $fullPath `
            -RelativePath '.' `
            -DirectoryGuard $rootGuard
        return [pscustomobject][ordered]@{
            schemaVersion = 2
            rootIdentity = @([string]$rootGuard.VolumeSerialNumber, [string]$rootGuard.FileIndex)
            entries = @($entries)
        }
    } finally {
        $rootGuard.Dispose()
    }
}

function ConvertTo-CodexHookExpectedDirectoryTreeManifest {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$Scope
    )

    Assert-CodexHookDirectoryTreeExactProperties `
        -Value $Manifest `
        -Names @('schemaVersion', 'rootIdentity', 'entries') `
        -Scope "$Scope manifest"
    $manifestSchemaVersion = [int]$Manifest.schemaVersion
    if ($manifestSchemaVersion -notin @(1, 2)) {
        throw "$Scope manifest schemaVersion 非法。"
    }
    $rootIdentity = @($Manifest.rootIdentity)
    Assert-CodexHookDirectoryTreeIdentity -Expected $rootIdentity -Actual $rootIdentity -Scope "$Scope manifest root"
    $entriesByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $childrenByParent = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Manifest.entries)) {
        Assert-CodexHookDirectoryTreeExactProperties `
            -Value $entry `
            -Names @('relativePath', 'kind', 'sha256', 'identity') `
            -Scope "$Scope manifest entry"
        $relativePath = [string]$entry.relativePath
        Assert-CodexHookDirectoryTreeRelativePath -RelativePath $relativePath -Scope "$Scope manifest entry"
        $kind = [string]$entry.kind
        if ($kind -cne 'directory' -and
            $kind -cne 'file' -and
            ($manifestSchemaVersion -ne 2 -or $kind -cne 'directory-junction')) {
            throw "$Scope manifest entry kind 非法。"
        }
        $sha256 = $entry.sha256
        if ($kind -ceq 'directory') {
            if ($null -ne $sha256) { throw "$Scope manifest directory 不得声明 SHA-256。" }
        } elseif ($sha256 -isnot [string] -or $sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "$Scope manifest leaf SHA-256 非法。"
        }
        $identity = @($entry.identity)
        Assert-CodexHookDirectoryTreeIdentity -Expected $identity -Actual $identity -Scope "$Scope manifest entry"
        if (-not $entriesByPath.TryAdd($relativePath, $null)) {
            throw "$Scope manifest relativePath 重复。"
        }
        $canonical = [pscustomobject][ordered]@{
            relativePath = $relativePath
            kind = $kind
            sha256 = if ($kind -ceq 'directory') { $null } else { [string]$sha256 }
            identity = @([string]$identity[0], [string]$identity[1])
        }
        $entriesByPath[$relativePath] = $canonical
        $entries.Add($canonical)
    }
    if (-not $entriesByPath.ContainsKey('.')) {
        throw "$Scope manifest 缺少根目录条目。"
    }
    $rootEntry = $entriesByPath['.']
    if ($rootEntry.kind -cne 'directory') {
        throw "$Scope manifest 根目录 kind 非法。"
    }
    Assert-CodexHookDirectoryTreeIdentity -Expected $rootIdentity -Actual @($rootEntry.identity) -Scope "$Scope manifest root"
    foreach ($entry in $entries) {
        if ($entry.relativePath -ceq '.') { continue }
        $parent = Get-CodexHookDirectoryTreeRelativeParent -RelativePath $entry.relativePath
        if (-not $entriesByPath.ContainsKey($parent) -or $entriesByPath[$parent].kind -cne 'directory') {
            throw "$Scope manifest entry 缺少安全目录父级。"
        }
        if (-not $childrenByParent.ContainsKey($parent)) {
            $childrenByParent.Add($parent, [Collections.Generic.List[object]]::new())
        }
        $childrenByParent[$parent].Add($entry)
    }
    return [pscustomobject][ordered]@{
        rootIdentity = @([string]$rootIdentity[0], [string]$rootIdentity[1])
        entriesByPath = $entriesByPath
        childrenByParent = $childrenByParent
    }
}

function Assert-CodexHookCapabilityLeafRetryPolicy {
    param([Parameter(Mandatory)][object]$RetryPolicy)

    $expectedNames = @(
        'schemaVersion', 'maxAttempts', 'wallTimeBudgetMs',
        'delayMilliseconds', 'allowedWindowsErrors')
    if ((@($RetryPolicy.PSObject.Properties.Name) -join '|') -cne ($expectedNames -join '|')) {
        throw 'safe-delete leaf retry policy 属性结构非法。'
    }
    $maxAttempts = [long]$RetryPolicy.maxAttempts
    $wallTimeBudgetMs = [long]$RetryPolicy.wallTimeBudgetMs
    $delays = @($RetryPolicy.delayMilliseconds)
    $allowedErrors = @($RetryPolicy.allowedWindowsErrors)
    if ([long]$RetryPolicy.schemaVersion -ne 1L -or
        $maxAttempts -lt 1L -or $maxAttempts -gt 16L -or
        $wallTimeBudgetMs -lt 0L -or $wallTimeBudgetMs -gt 60000L -or
        $delays.Count -ne ($maxAttempts - 1L) -or
        (@($allowedErrors | ForEach-Object { [long]$_ }) -join ',') -cne '32,33,170') {
        throw 'safe-delete leaf retry policy schema、attempts、budget 或 allowlist 非法。'
    }
    foreach ($delay in $delays) {
        if ([long]$delay -lt 0L -or [long]$delay -gt $wallTimeBudgetMs) {
            throw 'safe-delete leaf retry policy delay 非法。'
        }
    }
}

function New-CodexHookCapabilityLeafRetryRuntime {
    param(
        [Parameter(Mandatory)][object]$RetryPolicy,
        [scriptblock]$ElapsedMillisecondsForTest,
        [scriptblock]$DelayForTest
    )

    Assert-CodexHookCapabilityLeafRetryPolicy -RetryPolicy $RetryPolicy
    return [pscustomobject][ordered]@{
        stopwatch = [Diagnostics.Stopwatch]::StartNew()
        elapsedMillisecondsForTest = $ElapsedMillisecondsForTest
        delayForTest = $DelayForTest
        lastElapsedMilliseconds = -1L
    }
}

function Get-CodexHookCapabilityLeafRetryElapsedMilliseconds {
    param([Parameter(Mandatory)][object]$RetryRuntime)

    $elapsed = if ($null -ne $RetryRuntime.elapsedMillisecondsForTest) {
        [long](& $RetryRuntime.elapsedMillisecondsForTest)
    } else {
        [long]$RetryRuntime.stopwatch.ElapsedMilliseconds
    }
    if ($elapsed -lt 0L -or $elapsed -lt [long]$RetryRuntime.lastElapsedMilliseconds) {
        throw 'safe-delete leaf retry elapsed source 必须单调且非负。'
    }
    $RetryRuntime.lastElapsedMilliseconds = $elapsed
    return $elapsed
}

function Invoke-CodexHookCapabilityLeafRetryDelay {
    param(
        [Parameter(Mandatory)][object]$RetryRuntime,
        [Parameter(Mandatory)][long]$DelayMilliseconds
    )

    if ($null -ne $RetryRuntime.delayForTest) {
        & $RetryRuntime.delayForTest $DelayMilliseconds
        return
    }
    Start-Sleep -Milliseconds $DelayMilliseconds
}

function Remove-CodexHookCapabilityTreeFileWithDirectoryGuard {
    param(
        [Parameter(Mandatory)][object]$DirectoryGuard,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][object[]]$ExpectedIdentity,
        [switch]$AllowHardLinks,
        [object]$RetryPolicy,
        [object]$RetryRuntime,
        [scriptblock]$RetryFaultForTest,
        [scriptblock]$RetryObserver,
        [scriptblock]$MetricsObserver,
        [scriptblock]$DeleteCheckpointForTest,
        [scriptblock]$DeleteCommitCallback,
        [scriptblock]$FileContentHashProvider,
        [string]$RelativePath,
        [Parameter(Mandatory)][string]$Scope
    )

    $maxAttempts = if ($null -eq $RetryPolicy) { 1 } else { [int]$RetryPolicy.maxAttempts }
    $wallTimeBudgetMs = if ($null -eq $RetryPolicy) { 0L } else { [long]$RetryPolicy.wallTimeBudgetMs }
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $targetLease = $null
        $revalidationPassed = $false
        try {
            if ($null -ne $RetryFaultForTest) {
                $injectedError = & $RetryFaultForTest $Path $attempt
                if ($null -ne $injectedError -and [int]$injectedError -ne 0) {
                    throw [ComponentModel.Win32Exception]::new(
                        [int]$injectedError,
                        'Injected safe-delete leaf failure.')
                }
            }
            $targetLease = $DirectoryGuard.AcquireSafeTreeDeleteFileLease(
                $Path,
                $AllowHardLinks.IsPresent)
            $length = [long]$targetLease.Length
            [byte[]]$leasedSha256 = $null
            if ($null -ne $FileContentHashProvider) {
                if ([string]::IsNullOrWhiteSpace($RelativePath)) {
                    throw "$Scope FileContentHashProvider 删除哈希必须提供 relativePath。"
                }
                $provided = & $FileContentHashProvider $Path $RelativePath $length $targetLease
                if ($provided -is [byte[]]) {
                    $leasedSha256 = $provided
                } elseif ($null -ne $provided) {
                    $leasedSha256 = [byte[]]@($provided)
                }
                if ($null -eq $leasedSha256 -or $leasedSha256.Length -ne 32) {
                    throw "$Scope FileContentHashProvider 必须返回 32 字节 SHA-256。"
                }
            } else {
                $leasedSha256 = $targetLease.ComputeSha256FromHandle()
            }
            if ($null -ne $MetricsObserver) { & $MetricsObserver 'hash-read' 0L $length }
            if ([Convert]::ToHexString($leasedSha256).ToLowerInvariant() -cne $ExpectedSha256) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope 临删前内容漂移。"
            }
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected $ExpectedIdentity `
                -Actual @($targetLease.VolumeSerialNumber, $targetLease.FileIndex) `
                -Scope "$Scope handle identity"
            [byte[]]$confirmedSha256 = $null
            if ($null -ne $FileContentHashProvider) {
                $confirmed = & $FileContentHashProvider $Path $RelativePath $length $targetLease
                if ($confirmed -is [byte[]]) {
                    $confirmedSha256 = $confirmed
                } elseif ($null -ne $confirmed) {
                    $confirmedSha256 = [byte[]]@($confirmed)
                }
                if ($null -eq $confirmedSha256 -or $confirmedSha256.Length -ne 32) {
                    throw "$Scope FileContentHashProvider 必须返回 32 字节 SHA-256。"
                }
            } else {
                $confirmedSha256 = $targetLease.ComputeSha256FromHandle()
            }
            if ($null -ne $MetricsObserver) { & $MetricsObserver 'hash-read' 0L $length }
            if ([Convert]::ToHexString($confirmedSha256).ToLowerInvariant() -cne $ExpectedSha256) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope handle identity 内容漂移。"
            }
            $revalidationPassed = $true
            $targetLease.DeleteWithPosixSemantics()
            if ($null -ne $DeleteCheckpointForTest) { & $DeleteCheckpointForTest $Path 'file' }
            if ($null -ne $DeleteCommitCallback) { & $DeleteCommitCallback $Path 'file' }
            if ($attempt -gt 1 -and $null -ne $RetryObserver) {
                & $RetryObserver ([pscustomobject][ordered]@{
                    revalidation = 'passed'
                    result = 'succeeded'
                })
            }
            return
        } catch {
            $failure = $_
            $nativeError = $null
            $current = $failure.Exception
            while ($null -ne $current) {
                if ($current -is [ComponentModel.Win32Exception]) {
                    $nativeError = [int]$current.NativeErrorCode
                    break
                }
                $current = $current.InnerException
            }
            $retryAllowed = $null -ne $RetryPolicy -and
                $nativeError -in @($RetryPolicy.allowedWindowsErrors)
            $retryDelays = if ($null -eq $RetryPolicy) { @() } else { @($RetryPolicy.delayMilliseconds) }
            $delayIndex = [Math]::Min($attempt - 1, $retryDelays.Count - 1)
            $delayMs = if ($retryAllowed -and $delayIndex -ge 0) {
                [long]$retryDelays[$delayIndex]
            } else { 0L }
            $elapsedMs = if ($null -ne $RetryRuntime) {
                Get-CodexHookCapabilityLeafRetryElapsedMilliseconds -RetryRuntime $RetryRuntime
            } else { 0L }
            if ($attempt -gt 1 -and $null -ne $RetryObserver) {
                & $RetryObserver ([pscustomobject][ordered]@{
                    revalidation = if ($revalidationPassed) { 'passed' } else { 'failed' }
                    result = 'failed'
                })
            }
            if (-not $retryAllowed -or $attempt -ge $maxAttempts -or
                $elapsedMs + $delayMs -gt $wallTimeBudgetMs) {
                throw $failure
            }
            if ($null -ne $RetryObserver) {
                & $RetryObserver ([pscustomobject][ordered]@{
                    attempt = $attempt
                    errorCategory = if ($nativeError -eq 32) { 'sharing-violation' } elseif ($nativeError -eq 33) { 'lock-violation' } else { 'busy' }
                    delayMs = $delayMs
                    elapsedMs = $elapsedMs
                    budgetRemainingMs = $wallTimeBudgetMs - $elapsedMs
                    revalidation = 'pending'
                    result = 'retrying'
                })
            }
            Invoke-CodexHookCapabilityLeafRetryDelay `
                -RetryRuntime $RetryRuntime `
                -DelayMilliseconds $delayMs
            if ((Get-CodexHookCapabilityLeafRetryElapsedMilliseconds -RetryRuntime $RetryRuntime) -gt
                $wallTimeBudgetMs) {
                if ($null -ne $RetryObserver) {
                    & $RetryObserver ([pscustomobject][ordered]@{
                        revalidation = 'not-attempted'
                        result = 'failed'
                    })
                }
                throw $failure
            }
        } finally {
            if ($null -ne $targetLease) { $targetLease.Dispose() }
        }
    }
}

function Remove-CodexHookCapabilityTreeJunctionWithDirectoryGuard {
    param(
        [Parameter(Mandatory)][object]$DirectoryGuard,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][object[]]$ExpectedIdentity,
        [Parameter(Mandatory)][string]$InternalDirectoryJunctionTargetRoot,
        [object]$RetryPolicy,
        [object]$RetryRuntime,
        [scriptblock]$RetryFaultForTest,
        [scriptblock]$RetryObserver,
        [scriptblock]$MetricsObserver,
        [scriptblock]$DeleteCheckpointForTest,
        [scriptblock]$DeleteCommitCallback,
        [Parameter(Mandatory)][string]$Scope
    )

    $maxAttempts = if ($null -eq $RetryPolicy) { 1 } else { [int]$RetryPolicy.maxAttempts }
    $wallTimeBudgetMs = if ($null -eq $RetryPolicy) { 0L } else { [long]$RetryPolicy.wallTimeBudgetMs }
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $targetLease = $null
        $revalidationPassed = $false
        try {
            if ($null -ne $RetryFaultForTest) {
                $injectedError = & $RetryFaultForTest $Path $attempt
                if ($null -ne $injectedError -and [int]$injectedError -ne 0) {
                    throw [ComponentModel.Win32Exception]::new(
                        [int]$injectedError,
                        'Injected safe-delete junction failure.')
                }
            }
            $targetLease = $DirectoryGuard.AcquireSafeTreeDeleteReparseLeafLease($Path)
            $reparseLength = [long]$targetLease.ReparseDataLength
            [byte[]]$leasedSha256 = $targetLease.ComputeReparseDataSha256FromHandle()
            if ($null -ne $MetricsObserver) { & $MetricsObserver 'hash-read' 0L $reparseLength }
            if ([Convert]::ToHexString($leasedSha256).ToLowerInvariant() -cne $ExpectedSha256) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope 临删前 reparse data 漂移。"
            }
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected $ExpectedIdentity `
                -Actual @($targetLease.VolumeSerialNumber, $targetLease.FileIndex) `
                -Scope "$Scope handle identity"
            $junctionTarget = Assert-CodexHookDPath `
                -Value ([string]$targetLease.ReadTargetPathFromHandle()) `
                -Name "$Scope junction target"
            if (-not (Test-CodexHookPathWithin `
                    -Path $junctionTarget `
                    -ParentPath $InternalDirectoryJunctionTargetRoot)) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope junction target 越界。"
            }
            [byte[]]$confirmedSha256 = $targetLease.ComputeReparseDataSha256FromHandle()
            if ($null -ne $MetricsObserver) { & $MetricsObserver 'hash-read' 0L $reparseLength }
            if ([Convert]::ToHexString($confirmedSha256).ToLowerInvariant() -cne $ExpectedSha256) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope handle reparse data 漂移。"
            }
            $revalidationPassed = $true
            $targetLease.DeleteWithPosixSemantics()
            if ($null -ne $DeleteCheckpointForTest) {
                & $DeleteCheckpointForTest $Path 'directory-junction'
            }
            if ($null -ne $DeleteCommitCallback) { & $DeleteCommitCallback $Path 'directory-junction' }
            if ($attempt -gt 1 -and $null -ne $RetryObserver) {
                & $RetryObserver ([pscustomobject][ordered]@{
                    revalidation = 'passed'
                    result = 'succeeded'
                })
            }
            return
        } catch {
            $failure = $_
            $nativeError = $null
            $current = $failure.Exception
            while ($null -ne $current) {
                if ($current -is [ComponentModel.Win32Exception]) {
                    $nativeError = [int]$current.NativeErrorCode
                    break
                }
                $current = $current.InnerException
            }
            $retryAllowed = $null -ne $RetryPolicy -and
                $nativeError -in @($RetryPolicy.allowedWindowsErrors)
            $retryDelays = if ($null -eq $RetryPolicy) { @() } else { @($RetryPolicy.delayMilliseconds) }
            $delayIndex = [Math]::Min($attempt - 1, $retryDelays.Count - 1)
            $delayMs = if ($retryAllowed -and $delayIndex -ge 0) {
                [long]$retryDelays[$delayIndex]
            } else { 0L }
            $elapsedMs = if ($null -ne $RetryRuntime) {
                Get-CodexHookCapabilityLeafRetryElapsedMilliseconds -RetryRuntime $RetryRuntime
            } else { 0L }
            if ($attempt -gt 1 -and $null -ne $RetryObserver) {
                & $RetryObserver ([pscustomobject][ordered]@{
                    revalidation = if ($revalidationPassed) { 'passed' } else { 'failed' }
                    result = 'failed'
                })
            }
            if (-not $retryAllowed -or $attempt -ge $maxAttempts -or
                $elapsedMs + $delayMs -gt $wallTimeBudgetMs) {
                throw $failure
            }
            if ($null -ne $RetryObserver) {
                & $RetryObserver ([pscustomobject][ordered]@{
                    attempt = $attempt
                    errorCategory = if ($nativeError -eq 32) { 'sharing-violation' } elseif ($nativeError -eq 33) { 'lock-violation' } else { 'busy' }
                    delayMs = $delayMs
                    elapsedMs = $elapsedMs
                    budgetRemainingMs = $wallTimeBudgetMs - $elapsedMs
                    revalidation = 'pending'
                    result = 'retrying'
                })
            }
            Invoke-CodexHookCapabilityLeafRetryDelay `
                -RetryRuntime $RetryRuntime `
                -DelayMilliseconds $delayMs
            if ((Get-CodexHookCapabilityLeafRetryElapsedMilliseconds -RetryRuntime $RetryRuntime) -gt
                $wallTimeBudgetMs) {
                if ($null -ne $RetryObserver) {
                    & $RetryObserver ([pscustomobject][ordered]@{
                        revalidation = 'not-attempted'
                        result = 'failed'
                    })
                }
                throw $failure
            }
        } finally {
            if ($null -ne $targetLease) { $targetLease.Dispose() }
        }
    }
}

function Remove-CodexHookCapabilityDirectoryTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [string]$Scope = 'capability directory-tree delete',
        [Parameter(Mandatory)][string[]]$ExpectedRootIdentity,
        [Parameter(Mandatory)][object]$ExpectedTreeManifest,
        [switch]$AllowHardLinks,
        [switch]$AllowInternalDirectoryJunctions,
        [string]$InternalDirectoryJunctionTargetRoot,
        [switch]$RejectNamedStreams,
        [string]$NamedStreamDeleteIntentRoot,
        [string]$NamedStreamDeleteGenerationId,
        [AllowEmptyCollection()][object[]]$NamedStreamDeleteJournalAnchors = @(),
        [scriptblock]$NamedStreamDeleteCommitAnchor,
        [scriptblock]$NamedStreamDeleteCheckpointForTest,
        [object]$LeafRetryPolicy,
        [scriptblock]$LeafRetryFaultForTest,
        [scriptblock]$LeafRetryObserver,
        [scriptblock]$LeafRetryElapsedMillisecondsForTest,
        [scriptblock]$LeafRetryDelayForTest,
        [scriptblock]$LeafDeleteCheckpointForTest,
        [scriptblock]$MetricsObserver,
        [scriptblock]$DeleteCommitCallback,
        [scriptblock]$FileContentHashProvider
    )

    $leafRetryRuntime = if ($null -ne $LeafRetryPolicy) {
        New-CodexHookCapabilityLeafRetryRuntime `
            -RetryPolicy $LeafRetryPolicy `
            -ElapsedMillisecondsForTest $LeafRetryElapsedMillisecondsForTest `
            -DelayForTest $LeafRetryDelayForTest
    } else { $null }
    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Scope
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Scope capability root"
    $junctionTargetRoot = $null
    if ($AllowInternalDirectoryJunctions) {
        if ([string]::IsNullOrWhiteSpace($InternalDirectoryJunctionTargetRoot)) {
            throw "$Scope 允许内部 junction 时必须提供 target root。"
        }
        $junctionTargetRoot = Assert-CodexHookDPath `
            -Value $InternalDirectoryJunctionTargetRoot `
            -Name "$Scope internal junction target root"
        if (-not (Test-CodexHookPathWithin -Path $junctionTargetRoot -ParentPath $capabilityRootPath)) {
            throw "$Scope internal junction target root 超出 capability root。"
        }
    }
    $manifest = ConvertTo-CodexHookExpectedDirectoryTreeManifest -Manifest $ExpectedTreeManifest -Scope $Scope
    $intentRoot = $null
    $intentGenerationId = $null
    $journalAnchorsByIdentity = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    if ($RejectNamedStreams) {
        if ([string]::IsNullOrWhiteSpace($NamedStreamDeleteIntentRoot)) {
            throw "$Scope named-stream 删除必须提供 intent root。"
        }
        $intentRoot = Assert-CodexHookDPath -Value $NamedStreamDeleteIntentRoot -Name "$Scope intent root"
        $intentRootItem = Get-Item -LiteralPath $intentRoot -Force -ErrorAction Stop
        if (-not $intentRootItem.PSIsContainer -or
            ($intentRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Scope intent root 必须是安全普通目录。"
        }
        if (Test-CodexHookPathWithin -Path $intentRoot -ParentPath $fullPath) {
            throw "$Scope intent root 不得位于待删除树内。"
        }
        $parsedGenerationId = [guid]::Empty
        if (-not [guid]::TryParseExact(
            $NamedStreamDeleteGenerationId,
            'D',
            [ref]$parsedGenerationId)) {
            throw "$Scope named-stream 删除必须提供规范 generation id。"
        }
        $intentGenerationId = $parsedGenerationId.ToString('D')
        if ($null -eq $NamedStreamDeleteCommitAnchor) {
            throw "$Scope named-stream 删除必须提供 transaction commit anchor。"
        }
        foreach ($anchor in @($NamedStreamDeleteJournalAnchors)) {
            Assert-CodexHookDirectoryTreeExactProperties `
                -Value $anchor `
                -Names @(
                    'generationId', 'operationId', 'directoryPath', 'relativePath',
                    'volumeSerialNumber', 'fileIndex',
                    'freezeIntentPath', 'freezeIntentSha256', 'freezeIntentIdentity',
                    'commitIntentPath', 'commitIntentSha256', 'commitIntentIdentity'
                ) `
                -Scope "$Scope directory journal anchor"
            $anchorIdentity = @(
                [string]$anchor.volumeSerialNumber,
                [string]$anchor.fileIndex)
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected $anchorIdentity `
                -Actual $anchorIdentity `
                -Scope "$Scope directory journal anchor identity"
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($anchor.freezeIntentIdentity) `
                -Actual @($anchor.freezeIntentIdentity) `
                -Scope "$Scope directory freeze journal identity"
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($anchor.commitIntentIdentity) `
                -Actual @($anchor.commitIntentIdentity) `
                -Scope "$Scope directory commit journal identity"
            if ([string]$anchor.generationId -cne $intentGenerationId -or
                [string]$anchor.operationId -notmatch '^[0-9a-f]{32}$' -or
                [string]$anchor.freezeIntentSha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]$anchor.commitIntentSha256 -notmatch '^[0-9a-f]{64}$') {
                throw "$Scope directory journal anchor 状态非法。"
            }
            $identityKey = '{0}|{1}' -f $anchorIdentity[0], $anchorIdentity[1]
            if ($journalAnchorsByIdentity.ContainsKey($identityKey)) {
                throw "$Scope directory journal anchor identity 重复。"
            }
            $journalAnchorsByIdentity.Add($identityKey, $anchor)
        }
    }
    Assert-CodexHookDirectoryTreeIdentity -Expected @($ExpectedRootIdentity) -Actual @($ExpectedRootIdentity) -Scope "$Scope expected root"
    Assert-CodexHookDirectoryTreeIdentity -Expected @($ExpectedRootIdentity) -Actual @($manifest.rootIdentity) -Scope "$Scope root manifest"

    function Read-CodexHookDirectoryDeleteJournal {
        param(
            [Parameter(Mandatory)][string]$JournalPath,
            [Parameter(Mandatory)][ValidateSet('freeze', 'commit', 'abort')][string]$Kind,
            [Parameter(Mandatory)][string]$JournalScope
        )

        $fullJournalPath = Assert-CodexHookDPath -Value $JournalPath -Name "$JournalScope path"
        if (-not (Test-CodexHookPathWithin -Path $fullJournalPath -ParentPath $intentRoot) -or
            $fullJournalPath -ieq $intentRoot -or
            [IO.Path]::GetFileName($fullJournalPath) -notmatch "^directory-delete-.+-$Kind\.json$") {
            throw "$JournalScope path 越界或命名非法。"
        }
        $safeSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $fullJournalPath `
            -Name $JournalScope `
            -AllowedExactPaths @($fullJournalPath)
        $snapshot = [pscustomobject][ordered]@{
            sha256 = [string]$safeSnapshot.sha256
            text = [string]$safeSnapshot.text
            bytes = [byte[]]$safeSnapshot.bytes
            identity = @($safeSnapshot.probe.identity)
        }
        Assert-CodexHookStrictJsonText -JsonText $snapshot.text
        $document = $snapshot.text |
            ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        $commonNames = @(
            'artifactType', 'schemaVersion', 'generationId', 'operationId',
            'directoryPath', 'relativePath', 'volumeSerialNumber', 'fileIndex',
            'state')
        $expectedNames = switch ($Kind) {
            'freeze' {
                @($commonNames) + @(
                    'originalSecurityDescriptorSddl',
                    'requestedFrozenSecurityDescriptorSddl', 'createdAtUtc')
            }
            'commit' {
                @($commonNames) + @(
                    'originalSecurityDescriptorSddl',
                    'requestedFrozenSecurityDescriptorSddl',
                    'appliedFrozenSecurityDescriptorSddl',
                    'freezeIntentPath', 'freezeIntentSha256',
                    'freezeIntentIdentity', 'createdAtUtc')
            }
            'abort' {
                @($commonNames) + @(
                    'restoredSecurityDescriptorSddl',
                    'freezeIntentPath', 'freezeIntentSha256',
                    'freezeIntentIdentity', 'createdAtUtc')
            }
        }
        Assert-CodexHookDirectoryTreeExactProperties `
            -Value $document `
            -Names $expectedNames `
            -Scope $JournalScope
        $expectedArtifactType = "env-governance.codex-safe-tree-delete-directory-$Kind-intent"
        $expectedState = switch ($Kind) {
            'freeze' { 'freeze-prepared' }
            'commit' { 'commit-authorized' }
            'abort' { 'aborted' }
        }
        if ([string]$document.artifactType -cne $expectedArtifactType -or
            [long]$document.schemaVersion -ne 2 -or
            [string]$document.generationId -cne $intentGenerationId -or
            [string]$document.operationId -notmatch '^[0-9a-f]{32}$' -or
            [string]$document.state -cne $expectedState) {
            throw "$JournalScope artifact、schema 或状态非法。"
        }
        $documentIdentity = @(
            [string]$document.volumeSerialNumber,
            [string]$document.fileIndex)
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected $documentIdentity `
            -Actual $documentIdentity `
            -Scope "$JournalScope directory identity"
        if ($Kind -cne 'freeze') {
            if ([string]$document.freezeIntentSha256 -notmatch '^[0-9a-f]{64}$') {
                throw "$JournalScope freeze SHA-256 非法。"
            }
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($document.freezeIntentIdentity) `
                -Actual @($document.freezeIntentIdentity) `
                -Scope "$JournalScope freeze identity"
        }
        return [pscustomobject][ordered]@{
            path = $fullJournalPath
            snapshot = $snapshot
            document = $document
        }
    }

    function Assert-CodexHookDirectoryDeleteJournalBinding {
        param(
            [Parameter(Mandatory)][object]$FreezeJournal,
            [Parameter(Mandatory)][object]$TerminalJournal,
            [Parameter(Mandatory)][string]$BindingScope
        )

        $freeze = $FreezeJournal.document
        $terminal = $TerminalJournal.document
        if ([string]$terminal.generationId -cne [string]$freeze.generationId -or
            [string]$terminal.operationId -cne [string]$freeze.operationId -or
            [string]$terminal.directoryPath -cne [string]$freeze.directoryPath -or
            [string]$terminal.relativePath -cne [string]$freeze.relativePath -or
            [string]$terminal.volumeSerialNumber -cne [string]$freeze.volumeSerialNumber -or
            [string]$terminal.fileIndex -cne [string]$freeze.fileIndex -or
            [string]$terminal.freezeIntentPath -cne [string]$FreezeJournal.path -or
            [string]$terminal.freezeIntentSha256 -cne [string]$FreezeJournal.snapshot.sha256 -or
            -not (Test-CodexHookDirectoryTreeIdentityEqual `
                -Expected @($terminal.freezeIntentIdentity) `
                -Actual @($FreezeJournal.snapshot.identity))) {
            throw "$BindingScope journal 绑定不一致。"
        }
        if ([string]$terminal.state -ceq 'commit-authorized') {
            if ([string]$terminal.originalSecurityDescriptorSddl -cne
                    [string]$freeze.originalSecurityDescriptorSddl -or
                [string]$terminal.requestedFrozenSecurityDescriptorSddl -cne
                    [string]$freeze.requestedFrozenSecurityDescriptorSddl -or
                -not [CodexHookGovernance.VerifiedDirectoryChainGuard]::IsValidAlternateDataStreamWriteFreeze(
                    [string]$terminal.originalSecurityDescriptorSddl,
                    [string]$terminal.requestedFrozenSecurityDescriptorSddl,
                    [string]$terminal.appliedFrozenSecurityDescriptorSddl)) {
                throw "$BindingScope commit SDDL 冻结语义非法。"
            }
        } elseif (-not [CodexHookGovernance.VerifiedDirectoryChainGuard]::SecurityDescriptorsHaveEquivalentDacl(
                [string]$freeze.originalSecurityDescriptorSddl,
                [string]$terminal.restoredSecurityDescriptorSddl)) {
            throw "$BindingScope abort 未恢复首份 freeze 的原始 DACL。"
        }
    }

    function Remove-CodexHookCapabilityDirectoryNode {
        param(
            [Parameter(Mandatory)][string]$DirectoryPath,
            [Parameter(Mandatory)][string]$RelativePath,
            [Parameter(Mandatory)][object]$DirectoryGuard,
            [Parameter(Mandatory)][string]$RootPath,
            [Parameter(Mandatory)][string]$NodeScope
        )

        $expectedDirectory = $manifest.entriesByPath[$RelativePath]
        if ($null -eq $expectedDirectory -or $expectedDirectory.kind -cne 'directory') {
            throw "$NodeScope manifest 缺少当前目录条目。"
        }
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @($expectedDirectory.identity) `
            -Actual @($DirectoryGuard.VolumeSerialNumber, $DirectoryGuard.FileIndex) `
            -Scope "$NodeScope 目录"
        [void](Assert-CodexHookCapabilityPath `
            -Path $DirectoryPath `
            -CapabilityRoot $RootPath `
            -Name "$NodeScope directory")
        $item = Get-Item -LiteralPath $DirectoryPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 不是安全普通目录。"
        }
        $children = @(Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction Stop | Sort-Object -Property Name)
        $expectedChildren = if ($manifest.childrenByParent.ContainsKey($RelativePath)) {
            @($manifest.childrenByParent[$RelativePath] | Sort-Object -Property relativePath)
        } else {
            @()
        }
        if (@($children).Count -ne @($expectedChildren).Count) {
            throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 目录内容与已审计树清单不一致。"
        }
        $actualNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($child in $children) { [void]$actualNames.Add([string]$child.Name) }
        foreach ($expectedChild in @($expectedChildren)) {
            $leaf = Get-CodexHookDirectoryTreeRelativeLeaf -RelativePath $expectedChild.relativePath
            if (-not $actualNames.Contains($leaf)) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 目录内容与已审计树清单不一致。"
            }
        }
        foreach ($expectedChild in @($expectedChildren)) {
            $leaf = Get-CodexHookDirectoryTreeRelativeLeaf -RelativePath $expectedChild.relativePath
            $childPath = Join-Path $DirectoryPath $leaf
            $child = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (-not $AllowInternalDirectoryJunctions -or
                    $expectedChild.kind -cne 'directory-junction' -or
                    -not $child.PSIsContainer) {
                    throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 包含未授权 reparse point：$childPath"
                }
                [void](Assert-CodexHookCapabilityLeafPath `
                    -Path $childPath `
                    -CapabilityRoot $RootPath `
                    -Name "$NodeScope junction leaf")
                Remove-CodexHookCapabilityTreeJunctionWithDirectoryGuard `
                    -DirectoryGuard $DirectoryGuard `
                    -Path $childPath `
                    -ExpectedSha256 $expectedChild.sha256 `
                    -ExpectedIdentity @($expectedChild.identity) `
                    -InternalDirectoryJunctionTargetRoot $junctionTargetRoot `
                    -RetryPolicy $LeafRetryPolicy `
                    -RetryRuntime $leafRetryRuntime `
                    -RetryFaultForTest $LeafRetryFaultForTest `
                    -RetryObserver $LeafRetryObserver `
                    -MetricsObserver $MetricsObserver `
                    -DeleteCheckpointForTest $LeafDeleteCheckpointForTest `
                    -DeleteCommitCallback $DeleteCommitCallback `
                    -Scope "$NodeScope child"
                continue
            }
            [void](Assert-CodexHookCapabilityPath `
                -Path $childPath `
                -CapabilityRoot $RootPath `
                -Name "$NodeScope child")
            if ($expectedChild.kind -ceq 'directory-junction') {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 已审计 junction 被替换：$childPath"
            }
            if ($expectedChild.kind -ceq 'directory') {
                if (-not $child.PSIsContainer) {
                    throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 已审计目录被替换为文件：$childPath"
                }
                $childGuard = $DirectoryGuard.AcquireChildDirectoryForEmptyDelete($childPath)
                try {
                    Remove-CodexHookCapabilityDirectoryNode `
                        -DirectoryPath $childPath `
                        -RelativePath $expectedChild.relativePath `
                        -DirectoryGuard $childGuard `
                        -RootPath $RootPath `
                        -NodeScope $NodeScope
                } finally {
                    $childGuard.Dispose()
                }
                continue
            }
            if ($child.PSIsContainer) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 已审计文件被替换为目录：$childPath"
            }
            Remove-CodexHookCapabilityTreeFileWithDirectoryGuard `
                -DirectoryGuard $DirectoryGuard `
                -Path $childPath `
                -ExpectedSha256 $expectedChild.sha256 `
                -ExpectedIdentity @($expectedChild.identity) `
                -AllowHardLinks:$AllowHardLinks `
                -RetryPolicy $LeafRetryPolicy `
                -RetryRuntime $leafRetryRuntime `
                -RetryFaultForTest $LeafRetryFaultForTest `
                -RetryObserver $LeafRetryObserver `
                -MetricsObserver $MetricsObserver `
                -DeleteCheckpointForTest $LeafDeleteCheckpointForTest `
                -DeleteCommitCallback $DeleteCommitCallback `
                -FileContentHashProvider $FileContentHashProvider `
                -RelativePath ([string]$expectedChild.relativePath) `
                -Scope "$NodeScope child"
        }
        if ($RejectNamedStreams) {
            $directoryIdentity = @(
                [string]$expectedDirectory.identity[0],
                [string]$expectedDirectory.identity[1])
            $identityKey = '{0}|{1}' -f $directoryIdentity[0], $directoryIdentity[1]
            $activeJournals = [Collections.Generic.List[object]]::new()
            foreach ($freezePathCandidate in @([IO.Directory]::EnumerateFiles(
                    $intentRoot,
                    'directory-delete-*-freeze.json',
                    [IO.SearchOption]::TopDirectoryOnly))) {
                $freezeJournal = Read-CodexHookDirectoryDeleteJournal `
                    -JournalPath $freezePathCandidate `
                    -Kind freeze `
                    -JournalScope "$NodeScope directory freeze journal"
                $freeze = $freezeJournal.document
                if ([string]$freeze.directoryPath -cne $DirectoryPath -or
                    [string]$freeze.relativePath -cne $RelativePath -or
                    [string]$freeze.volumeSerialNumber -cne $directoryIdentity[0] -or
                    [string]$freeze.fileIndex -cne $directoryIdentity[1]) {
                    continue
                }
                $commitPathCandidate = $freezeJournal.path -replace '-freeze\.json$', '-commit.json'
                $abortPathCandidate = $freezeJournal.path -replace '-freeze\.json$', '-abort.json'
                $hasCommit = [IO.File]::Exists($commitPathCandidate)
                $hasAbort = [IO.File]::Exists($abortPathCandidate)
                if ($hasCommit -and $hasAbort) {
                    throw "$NodeScope 同一 directory operation 同时存在 commit 与 abort。"
                }
                if ($hasAbort) {
                    $abortJournal = Read-CodexHookDirectoryDeleteJournal `
                        -JournalPath $abortPathCandidate `
                        -Kind abort `
                        -JournalScope "$NodeScope directory abort journal"
                    Assert-CodexHookDirectoryDeleteJournalBinding `
                        -FreezeJournal $freezeJournal `
                        -TerminalJournal $abortJournal `
                        -BindingScope "$NodeScope directory abort"
                    continue
                }
                $commitJournal = $null
                if ($hasCommit) {
                    $commitJournal = Read-CodexHookDirectoryDeleteJournal `
                        -JournalPath $commitPathCandidate `
                        -Kind commit `
                        -JournalScope "$NodeScope directory commit journal"
                    Assert-CodexHookDirectoryDeleteJournalBinding `
                        -FreezeJournal $freezeJournal `
                        -TerminalJournal $commitJournal `
                        -BindingScope "$NodeScope directory commit"
                }
                $activeJournals.Add([pscustomobject][ordered]@{
                    freeze = $freezeJournal
                    commit = $commitJournal
                    commitPath = $commitPathCandidate
                    abortPath = $abortPathCandidate
                })
            }
            if ($activeJournals.Count -gt 1) {
                throw "$NodeScope 存在多个未终结 directory journal operation。"
            }

            $anchoredJournal = $null
            if ($journalAnchorsByIdentity.ContainsKey($identityKey)) {
                $anchor = $journalAnchorsByIdentity[$identityKey]
                if ([string]$anchor.directoryPath -cne $DirectoryPath -or
                    [string]$anchor.relativePath -cne $RelativePath) {
                    throw "$NodeScope directory journal anchor 路径绑定不一致。"
                }
                $freezeJournal = Read-CodexHookDirectoryDeleteJournal `
                    -JournalPath ([string]$anchor.freezeIntentPath) `
                    -Kind freeze `
                    -JournalScope "$NodeScope anchored freeze journal"
                $commitJournal = Read-CodexHookDirectoryDeleteJournal `
                    -JournalPath ([string]$anchor.commitIntentPath) `
                    -Kind commit `
                    -JournalScope "$NodeScope anchored commit journal"
                Assert-CodexHookDirectoryDeleteJournalBinding `
                    -FreezeJournal $freezeJournal `
                    -TerminalJournal $commitJournal `
                    -BindingScope "$NodeScope anchored commit"
                if ([string]$anchor.operationId -cne [string]$commitJournal.document.operationId -or
                    [string]$anchor.freezeIntentSha256 -cne [string]$freezeJournal.snapshot.sha256 -or
                    [string]$anchor.commitIntentSha256 -cne [string]$commitJournal.snapshot.sha256 -or
                    -not (Test-CodexHookDirectoryTreeIdentityEqual `
                        -Expected @($anchor.freezeIntentIdentity) `
                        -Actual @($freezeJournal.snapshot.identity)) -or
                    -not (Test-CodexHookDirectoryTreeIdentityEqual `
                        -Expected @($anchor.commitIntentIdentity) `
                        -Actual @($commitJournal.snapshot.identity)) -or
                    [IO.File]::Exists(
                        ([string]$anchor.commitIntentPath -replace '-commit\.json$', '-abort.json'))) {
                    throw "$NodeScope directory journal anchor hash、identity 或终态冲突。"
                }
                if ($activeJournals.Count -ne 1 -or
                    [string]$activeJournals[0].commit.path -cne [string]$commitJournal.path) {
                    throw "$NodeScope anchored commit 不是唯一活跃 operation。"
                }
                $anchoredJournal = $commitJournal
            }

            $freezeIntentPath = $null
            $commitIntentPath = $null
            $abortIntentPath = $null
            $checkpointForTest = $null
            if ($null -ne $NamedStreamDeleteCheckpointForTest) {
                [Action[string]]$checkpointForTest = {
                    param([string]$Phase)
                    & $NamedStreamDeleteCheckpointForTest `
                        $DirectoryPath `
                        $RelativePath `
                        $Phase `
                        $freezeIntentPath `
                        $commitIntentPath `
                        $abortIntentPath
                }
            }

            if ($null -ne $anchoredJournal) {
                $freezeIntentPath = [string]$anchoredJournal.document.freezeIntentPath
                $commitIntentPath = [string]$anchoredJournal.path
                $abortIntentPath = $commitIntentPath -replace '-commit\.json$', '-abort.json'
                $DirectoryGuard.DeleteEmptyDirectoryWithAuthorizedAlternateDataStreamCommit(
                    [string]$anchoredJournal.document.originalSecurityDescriptorSddl,
                    [string]$anchoredJournal.document.requestedFrozenSecurityDescriptorSddl,
                    [string]$anchoredJournal.document.appliedFrozenSecurityDescriptorSddl,
                    $checkpointForTest)
                return
            }

            $resumePreparedFreeze = $activeJournals.Count -eq 1
            if ($resumePreparedFreeze) {
                $active = $activeJournals[0]
                $freezeIntentPath = [string]$active.freeze.path
                $commitIntentPath = [string]$active.commitPath
                $abortIntentPath = [string]$active.abortPath
                if ($null -ne $active.commit) {
                    $commitDocument = $active.commit.document
                    $commitAnchor = [pscustomobject][ordered]@{
                        generationId = [string]$commitDocument.generationId
                        operationId = [string]$commitDocument.operationId
                        directoryPath = [string]$commitDocument.directoryPath
                        relativePath = [string]$commitDocument.relativePath
                        volumeSerialNumber = [string]$commitDocument.volumeSerialNumber
                        fileIndex = [string]$commitDocument.fileIndex
                        freezeIntentPath = [string]$active.freeze.path
                        freezeIntentSha256 = [string]$active.freeze.snapshot.sha256
                        freezeIntentIdentity = @($active.freeze.snapshot.identity)
                        commitIntentPath = [string]$active.commit.path
                        commitIntentSha256 = [string]$active.commit.snapshot.sha256
                        commitIntentIdentity = @($active.commit.snapshot.identity)
                    }
                    & $NamedStreamDeleteCommitAnchor $commitAnchor
                    $DirectoryGuard.DeleteEmptyDirectoryWithAuthorizedAlternateDataStreamCommit(
                        [string]$commitDocument.originalSecurityDescriptorSddl,
                        [string]$commitDocument.requestedFrozenSecurityDescriptorSddl,
                        [string]$commitDocument.appliedFrozenSecurityDescriptorSddl,
                        $checkpointForTest)
                    return
                }
                $intentId = [string]$active.freeze.document.operationId
            } else {
                $intentId = [guid]::NewGuid().ToString('N')
                $intentLeafBase = 'directory-delete-{0}-{1}-{2}' -f
                        $directoryIdentity[0].ToLowerInvariant(),
                        $directoryIdentity[1].ToLowerInvariant(),
                        $intentId
                $freezeIntentPath = Join-Path $intentRoot "$intentLeafBase-freeze.json"
                $commitIntentPath = Join-Path $intentRoot "$intentLeafBase-commit.json"
                $abortIntentPath = Join-Path $intentRoot "$intentLeafBase-abort.json"
            }
            $journalState = [pscustomobject][ordered]@{
                freezeDocument = if ($resumePreparedFreeze) {
                    $activeJournals[0].freeze.document
                } else { $null }
                freezeSnapshot = if ($resumePreparedFreeze) {
                    $activeJournals[0].freeze.snapshot
                } else { $null }
                commitAnchor = $null
            }
            [Action[string, string]]$publishFreezeIntent = {
                param([string]$OriginalSddl, [string]$FrozenSddl)
                $journalState.freezeDocument = [ordered]@{
                    artifactType = 'env-governance.codex-safe-tree-delete-directory-freeze-intent'
                    schemaVersion = 2
                    generationId = $intentGenerationId
                    operationId = $intentId
                    directoryPath = $DirectoryPath
                    relativePath = $RelativePath
                    volumeSerialNumber = [string]$expectedDirectory.identity[0]
                    fileIndex = [string]$expectedDirectory.identity[1]
                    state = 'freeze-prepared'
                    originalSecurityDescriptorSddl = $OriginalSddl
                    requestedFrozenSecurityDescriptorSddl = $FrozenSddl
                    createdAtUtc = [datetimeoffset]::UtcNow.ToString(
                        'o',
                        [Globalization.CultureInfo]::InvariantCulture)
                }
                $journalState.freezeSnapshot = New-CodexHookCapabilityJson `
                    -Path $freezeIntentPath `
                    -Document $journalState.freezeDocument `
                    -CapabilityRoot $intentRoot `
                    -AllowedExactPaths @($freezeIntentPath) `
                    -Scope "$NodeScope directory freeze intent"
            }
            [Action[string]]$publishCommitIntent = {
                param([string]$AppliedFrozenSddl)
                $commitDocument = [ordered]@{
                    artifactType = 'env-governance.codex-safe-tree-delete-directory-commit-intent'
                    schemaVersion = 2
                    generationId = $intentGenerationId
                    operationId = $intentId
                    directoryPath = $DirectoryPath
                    relativePath = $RelativePath
                    volumeSerialNumber = [string]$expectedDirectory.identity[0]
                    fileIndex = [string]$expectedDirectory.identity[1]
                    state = 'commit-authorized'
                    originalSecurityDescriptorSddl = [string]$journalState.freezeDocument.originalSecurityDescriptorSddl
                    requestedFrozenSecurityDescriptorSddl = [string]$journalState.freezeDocument.requestedFrozenSecurityDescriptorSddl
                    appliedFrozenSecurityDescriptorSddl = $AppliedFrozenSddl
                    freezeIntentPath = $freezeIntentPath
                    freezeIntentSha256 = [string]$journalState.freezeSnapshot.sha256
                    freezeIntentIdentity = @($journalState.freezeSnapshot.identity)
                    createdAtUtc = [datetimeoffset]::UtcNow.ToString(
                        'o',
                        [Globalization.CultureInfo]::InvariantCulture)
                }
                $commitSnapshot = New-CodexHookCapabilityJson `
                    -Path $commitIntentPath `
                    -Document $commitDocument `
                    -CapabilityRoot $intentRoot `
                    -AllowedExactPaths @($commitIntentPath) `
                    -Scope "$NodeScope directory commit intent"
                $journalState.commitAnchor = [pscustomobject][ordered]@{
                    generationId = $intentGenerationId
                    operationId = $intentId
                    directoryPath = $DirectoryPath
                    relativePath = $RelativePath
                    volumeSerialNumber = $directoryIdentity[0]
                    fileIndex = $directoryIdentity[1]
                    freezeIntentPath = $freezeIntentPath
                    freezeIntentSha256 = [string]$journalState.freezeSnapshot.sha256
                    freezeIntentIdentity = @($journalState.freezeSnapshot.identity)
                    commitIntentPath = $commitIntentPath
                    commitIntentSha256 = [string]$commitSnapshot.sha256
                    commitIntentIdentity = @($commitSnapshot.identity)
                }
                if ($null -ne $NamedStreamDeleteCheckpointForTest) {
                    & $NamedStreamDeleteCheckpointForTest `
                        $DirectoryPath `
                        $RelativePath `
                        'after-commit-publish-before-return' `
                        $freezeIntentPath `
                        $commitIntentPath `
                        $abortIntentPath
                }
            }
            [Action]$anchorCommitIntent = {
                if ($null -eq $journalState.commitAnchor) {
                    throw "$NodeScope directory commit anchor 尚未准备。"
                }
                & $NamedStreamDeleteCommitAnchor $journalState.commitAnchor
            }
            [Action[string]]$publishAbortIntent = {
                param([string]$RestoredSddl)
                $abortDocument = [ordered]@{
                    artifactType = 'env-governance.codex-safe-tree-delete-directory-abort-intent'
                    schemaVersion = 2
                    generationId = $intentGenerationId
                    operationId = $intentId
                    directoryPath = $DirectoryPath
                    relativePath = $RelativePath
                    volumeSerialNumber = [string]$expectedDirectory.identity[0]
                    fileIndex = [string]$expectedDirectory.identity[1]
                    state = 'aborted'
                    restoredSecurityDescriptorSddl = $RestoredSddl
                    freezeIntentPath = $freezeIntentPath
                    freezeIntentSha256 = [string]$journalState.freezeSnapshot.sha256
                    freezeIntentIdentity = @($journalState.freezeSnapshot.identity)
                    createdAtUtc = [datetimeoffset]::UtcNow.ToString(
                        'o',
                        [Globalization.CultureInfo]::InvariantCulture)
                }
                [void](New-CodexHookCapabilityJson `
                    -Path $abortIntentPath `
                    -Document $abortDocument `
                    -CapabilityRoot $intentRoot `
                    -AllowedExactPaths @($abortIntentPath) `
                    -Scope "$NodeScope directory abort intent")
            }
            if ($resumePreparedFreeze) {
                $DirectoryGuard.ResumeEmptyDirectoryRejectingAlternateDataStreams(
                    [string]$journalState.freezeDocument.originalSecurityDescriptorSddl,
                    [string]$journalState.freezeDocument.requestedFrozenSecurityDescriptorSddl,
                    $publishCommitIntent,
                    $anchorCommitIntent,
                    $publishAbortIntent,
                    $checkpointForTest)
            } else {
                $DirectoryGuard.DeleteEmptyDirectoryRejectingAlternateDataStreams(
                    $publishFreezeIntent,
                    $publishCommitIntent,
                    $anchorCommitIntent,
                    $publishAbortIntent,
                    $checkpointForTest)
            }
            return
        }
        $DirectoryGuard.DeleteEmptyDirectory()
    }

    $rootGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete(
        $capabilityRootPath,
        $fullPath)
    try {
        Remove-CodexHookCapabilityDirectoryNode `
            -DirectoryPath $fullPath `
            -RelativePath '.' `
            -DirectoryGuard $rootGuard `
            -RootPath $capabilityRootPath `
            -NodeScope $Scope
    } finally {
        $rootGuard.Dispose()
    }
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

function New-CodexHookCapabilityJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [string]$Scope = 'create-only capability json'
    )

    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        ($Document | ConvertTo-Json -Depth 100))
    $afterSha256 = Get-CodexHookBytesSha256 -Bytes $bytes
    $publication = [pscustomobject][ordered]@{
        renamePrepared = $false
        identity = $null
    }
    try {
        Set-CodexHookAtomicFileBytesWithCapability `
            -Path $Path `
            -Bytes $bytes `
            -ExpectedExists $false `
            -ExpectedSha256 $null `
            -AfterSha256 $afterSha256 `
            -CapabilityRoot $CapabilityRoot `
            -AllowedExactPaths $AllowedExactPaths `
            -Scope $Scope `
            -BeforeRename {
                param($PreparedSnapshot)
                $publication.renamePrepared = $true
                $publication.identity = @($PreparedSnapshot.identity)
            }
    } catch {
        $failure = $_
        if ($publication.renamePrepared) {
            try {
                $published = Get-CodexHookCapabilityFileSnapshot `
                    -Path $Path `
                    -CapabilityRoot $CapabilityRoot `
                    -AllowedExactPaths $AllowedExactPaths `
                    -Name "$Scope indeterminate publish"
                if ($published.exists -and
                    [string]$published.sha256 -ceq $afterSha256 -and
                    (Test-CodexHookDirectoryTreeIdentityEqual `
                        -Expected @($publication.identity) `
                        -Actual @($published.identity))) {
                    return $published
                }
            } catch {
                throw $failure
            }
        }
        throw $failure
    }

    return Get-CodexHookCapabilityFileSnapshot `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name "$Scope published"
}
