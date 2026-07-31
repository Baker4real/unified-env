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
        [string]$Name = 'capability directory-tree snapshot'
    )

    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Name
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Name capability root"
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
            $children = @(Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction Stop | Sort-Object -Property Name)
            foreach ($child in $children) {
                $childPath = Join-Path $DirectoryPath $child.Name
                [void](Assert-CodexHookCapabilityPath `
                    -Path $childPath `
                    -CapabilityRoot $capabilityRootPath `
                    -Name "$Name snapshot child")
                $childItem = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
                if (($childItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "$Name snapshot 包含 reparse point：$childPath"
                }
                $childRelative = if ($RelativePath -ceq '.') { $child.Name } else { "$RelativePath/$($child.Name)" }
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
                    $lease = $parentGuard.AcquireReadOnlyFileLease($childPath)
                    [byte[]]$sha256 = $lease.ComputeSha256FromHandle()
                    $entries.Add([pscustomobject][ordered]@{
                        relativePath = $childRelative
                        kind = 'file'
                        sha256 = [Convert]::ToHexString($sha256).ToLowerInvariant()
                        identity = @([string]$lease.VolumeSerialNumber, [string]$lease.FileIndex)
                    })
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
            schemaVersion = 1
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
    if ([int]$Manifest.schemaVersion -ne 1) {
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
        if ($kind -cne 'directory' -and $kind -cne 'file') {
            throw "$Scope manifest entry kind 非法。"
        }
        $sha256 = $entry.sha256
        if ($kind -ceq 'directory') {
            if ($null -ne $sha256) { throw "$Scope manifest directory 不得声明 SHA-256。" }
        } elseif ($sha256 -isnot [string] -or $sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "$Scope manifest file SHA-256 非法。"
        }
        $identity = @($entry.identity)
        Assert-CodexHookDirectoryTreeIdentity -Expected $identity -Actual $identity -Scope "$Scope manifest entry"
        if (-not $entriesByPath.TryAdd($relativePath, $null)) {
            throw "$Scope manifest relativePath 重复。"
        }
        $canonical = [pscustomobject][ordered]@{
            relativePath = $relativePath
            kind = $kind
            sha256 = if ($kind -ceq 'file') { [string]$sha256 } else { $null }
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

function Remove-CodexHookCapabilityTreeFileWithDirectoryGuard {
    param(
        [Parameter(Mandatory)][object]$DirectoryGuard,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][object[]]$ExpectedIdentity,
        [Parameter(Mandatory)][string]$Scope
    )

    $targetLease = $null
    try {
        $targetLease = $DirectoryGuard.AcquireTargetFileLease($Path)
        [byte[]]$leasedSha256 = $targetLease.ComputeSha256FromHandle()
        if ([Convert]::ToHexString($leasedSha256).ToLowerInvariant() -cne $ExpectedSha256) {
            throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope 临删前内容漂移。"
        }
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected $ExpectedIdentity `
            -Actual @($targetLease.VolumeSerialNumber, $targetLease.FileIndex) `
            -Scope "$Scope handle identity"
        [byte[]]$confirmedSha256 = $targetLease.ComputeSha256FromHandle()
        if ([Convert]::ToHexString($confirmedSha256).ToLowerInvariant() -cne $ExpectedSha256) {
            throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $Scope handle identity 内容漂移。"
        }
        $targetLease.DeleteWithPosixSemantics()
    } finally {
        if ($null -ne $targetLease) { $targetLease.Dispose() }
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
        [Parameter(Mandatory)][object]$ExpectedTreeManifest
    )

    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Scope
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Scope capability root"
    $manifest = ConvertTo-CodexHookExpectedDirectoryTreeManifest -Manifest $ExpectedTreeManifest -Scope $Scope
    Assert-CodexHookDirectoryTreeIdentity -Expected @($ExpectedRootIdentity) -Actual @($ExpectedRootIdentity) -Scope "$Scope expected root"
    Assert-CodexHookDirectoryTreeIdentity -Expected @($ExpectedRootIdentity) -Actual @($manifest.rootIdentity) -Scope "$Scope root manifest"

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
            [void](Assert-CodexHookCapabilityPath `
                -Path $childPath `
                -CapabilityRoot $RootPath `
                -Name "$NodeScope child")
            $child = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT: $NodeScope 包含 reparse point，拒绝递归删除：$childPath"
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
                -Scope "$NodeScope child"
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
