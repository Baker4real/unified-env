Set-StrictMode -Version Latest

$codexSafeTreeDeleteFileIdentitySource = Join-Path $PSScriptRoot 'CodexSafeTreeDeleteFileIdentity.cs'
$codexSafeTreeDeleteHashCacheSource = Join-Path $PSScriptRoot 'CodexSafeTreeDeleteHashCache.cs'
if (-not ('CodexSafeTreeDelete.FileIdentityReader' -as [type])) {
    Add-Type -Path $codexSafeTreeDeleteFileIdentitySource, $codexSafeTreeDeleteHashCacheSource -ErrorAction Stop
}

function Get-CodexSafeTreeDeleteFileIdentityV2 {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        throw 'LiteralPath 不得为空。'
    }

    return [CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($LiteralPath)
}

function Get-CodexSafeTreeDeleteHashSafely {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [Parameter(Mandatory)]
        [CodexSafeTreeDelete.FileIdentityV2]$ExpectedIdentity,
        [Parameter(Mandatory)]
        [CodexSafeTreeDelete.SessionHashCache]$SessionCache
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        throw 'LiteralPath 不得为空。'
    }

    return [CodexSafeTreeDelete.FileHashComputer]::GetHashSafely(
        $LiteralPath,
        $ExpectedIdentity,
        $SessionCache
    )
}

function ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if ($RelativePath -ceq '.') {
        throw 'fileIdentitiesV2 不得使用根目录 relativePath。'
    }
    Assert-CodexHookDirectoryTreeRelativePath `
        -RelativePath $RelativePath `
        -Scope 'safe-delete plan fileIdentitiesV2'
    $absolutePath = $TargetPath
    foreach ($segment in $RelativePath.Split('/')) {
        $absolutePath = Join-Path $absolutePath $segment
    }
    return $absolutePath
}

function ConvertTo-CodexSafeTreeDeleteUtcText {
    param([Parameter(Mandatory)][datetime]$Value)

    if ($Value.Kind -ne [DateTimeKind]::Utc) {
        throw 'FileIdentityV2 时间必须是 UTC。'
    }
    return [datetimeoffset]::new($Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-CodexSafeTreeDeleteUInt64JsonInteger {
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($null -eq $Value) {
        throw "$Scope 必须是 JSON integer。"
    }
    if ($Value -is [UInt64]) {
        return [UInt64]$Value
    }
    if ($Value -is [long]) {
        if ([long]$Value -lt 0L) {
            throw "$Scope 必须是非负 JSON integer。"
        }
        return [UInt64][long]$Value
    }
    if ($Value -is [int]) {
        if ([int]$Value -lt 0) {
            throw "$Scope 必须是非负 JSON integer。"
        }
        return [UInt64][int]$Value
    }
    if ($Value -is [decimal]) {
        if ([decimal]$Value -lt 0 -or
            [decimal]$Value -ne [Math]::Truncate([decimal]$Value) -or
            [decimal]$Value -gt [decimal][UInt64]::MaxValue) {
            throw "$Scope 必须是 uint64 JSON integer。"
        }
        return [UInt64][decimal]$Value
    }
    if ($Value -is [Numerics.BigInteger]) {
        if ($Value -lt [Numerics.BigInteger]::Zero -or
            $Value -gt [Numerics.BigInteger][UInt64]::MaxValue) {
            throw "$Scope 必须是 uint64 JSON integer。"
        }
        return [UInt64]$Value
    }
    throw "$Scope 必须是 JSON integer。"
}

function ConvertTo-CodexSafeTreeDeleteFileIdentityV2Record {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]$Identity
    )

    if ($Identity -isnot [CodexSafeTreeDelete.FileIdentityV2]) {
        throw 'safe-delete plan fileIdentitiesV2 必须来自 FileIdentityV2。'
    }
    if ($null -eq $Identity.FileId128 -or $Identity.FileId128.Length -ne 16) {
        throw 'safe-delete plan fileIdentitiesV2 FileId128 必须是 16 字节。'
    }

    return [pscustomobject][ordered]@{
        relativePath = $RelativePath
        volumeSerialNumber = [UInt64]$Identity.VolumeSerialNumber
        fileId128 = [Convert]::ToBase64String([byte[]]$Identity.FileId128)
        fileSize = [long]$Identity.FileSize
        lastWriteTimeUtc = ConvertTo-CodexSafeTreeDeleteUtcText -Value $Identity.LastWriteTimeUtc
        capturedAtUtc = ConvertTo-CodexSafeTreeDeleteUtcText -Value $Identity.CapturedAtUtc
    }
}

function New-CodexSafeTreeDeletePlanFileIdentitiesV2 {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][object]$TreeManifest
    )

    $records = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($TreeManifest.entries)) {
        if ([string]$entry.kind -cne 'file') { continue }
        $relativePath = [string]$entry.relativePath
        if (-not $seen.Add($relativePath)) {
            throw "safe-delete plan fileIdentitiesV2 relativePath 重复：$relativePath"
        }
        $absolutePath = ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
            -TargetPath $TargetPath `
            -RelativePath $relativePath
        $identity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $absolutePath
        $records.Add((
            ConvertTo-CodexSafeTreeDeleteFileIdentityV2Record `
                -RelativePath $relativePath `
                -Identity $identity
        ))
    }
    return $records
}

function New-CodexSafeTreeDeleteMetricsState {
    param([Parameter(Mandatory)][string]$Phase)

    return [pscustomobject][ordered]@{
        phase = $Phase
        stopwatch = [Diagnostics.Stopwatch]::StartNew()
        entriesScanned = 0L
        logicalBytes = 0L
        bytesHashed = 0L
        retryAttempts = 0L
        retryResult = 'not-applicable'
        retryContract = $null
        retryEvents = [Collections.Generic.List[object]]::new()
    }
}

function New-CodexSafeTreeDeleteMetricsObserver {
    param(
        [Parameter(Mandatory)][object]$State,
        [bool]$IncludeLogicalBytes = $true
    )

    $observer = {
        param([string]$Kind, [long]$LogicalBytes, [long]$BytesHashed)
        if ($Kind -cne 'hash-read') {
            $State.entriesScanned = [long]$State.entriesScanned + 1L
        }
        if ($IncludeLogicalBytes) {
            $State.logicalBytes = [long]$State.logicalBytes + $LogicalBytes
        }
        $State.bytesHashed = [long]$State.bytesHashed + $BytesHashed
    }
    return $observer.GetNewClosure()
}

function Complete-CodexSafeTreeDeleteMetrics {
    param([Parameter(Mandatory)][object]$State)

    $State.stopwatch.Stop()
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        phase = [string]$State.phase
        elapsedMs = [long]$State.stopwatch.ElapsedMilliseconds
        entriesScanned = [long]$State.entriesScanned
        logicalBytes = [long]$State.logicalBytes
        bytesHashed = [long]$State.bytesHashed
        retry = [pscustomobject][ordered]@{
            contract = $State.retryContract
            attempts = [long]$State.retryAttempts
            result = [string]$State.retryResult
            events = @($State.retryEvents)
        }
    }
}

function New-CodexSafeTreeDeleteOutcome {
    param(
        [AllowNull()][object]$NamespaceAbsent,
        [Parameter(Mandatory)][bool]$LogicalCompletion,
        [ValidateSet('unknown', 'verified', 'not-applicable')][string]$PhysicalReclaimStatus = 'unknown',
        [string]$PhysicalReclaimReason = 'independent-filesystem-allocation-evidence-unavailable'
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        namespaceAbsent = $NamespaceAbsent
        logicalCompletion = $LogicalCompletion
        physicalReclaimStatus = $PhysicalReclaimStatus
        physicalReclaimReason = $PhysicalReclaimReason
    }
}

function Assert-CodexSafeTreeDeleteExactProperties {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($null -eq $Value -or $null -eq $Value.PSObject) { throw "$Scope 不是对象。" }
    $actual = @($Value.PSObject.Properties.Name)
    if (@($actual | Where-Object { $_ -notin $Names }).Count -ne 0 -or
        @($Names | Where-Object { $_ -notin $actual }).Count -ne 0) {
        throw "$Scope 属性集合非法。"
    }
}

function Assert-CodexSafeTreeDeletePlanDocumentProperties {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$Scope
    )

    $required = @(
        'artifactType', 'schemaVersion', 'generationId', 'createdAtUtc', 'expiresAtUtc',
        'policyPath', 'policySha256', 'policyEntryId', 'targetPath', 'capabilityRoot',
        'treeManifest', 'summary'
    )
    $allowed = $required + @('fileIdentitiesV2')
    $actual = @($Plan.PSObject.Properties.Name)
    if (@($actual | Where-Object { $_ -notin $allowed }).Count -ne 0 -or
        @($required | Where-Object { $_ -notin $actual }).Count -ne 0) {
        throw "$Scope 属性集合非法。"
    }
}

function Test-CodexSafeTreeDeletePathEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    return [StringComparer]::OrdinalIgnoreCase.Equals($Left, $Right)
}

function Read-CodexSafeTreeDeletePolicy {
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [scriptblock]$MetricsObserver
    )

    $fullPolicyPath = Assert-CodexHookDPath -Value $PolicyPath -Name 'safe-delete policy path'
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $fullPolicyPath `
        -Name 'safe-delete policy' `
        -AllowedExactPaths @($fullPolicyPath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$snapshot.bytes.Length)
    }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $policy = $snapshot.text | ConvertFrom-Json -Depth 32 -ErrorAction Stop
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $policy `
        -Names @('artifactType', 'schemaVersion', 'entries') `
        -Scope 'safe-delete policy'
    if ($policy.artifactType -cne 'env-governance.codex-safe-tree-delete-policy') {
        throw 'safe-delete policy artifact 非法。'
    }
    if ($policy.schemaVersion -isnot [long] -or
        [long]$policy.schemaVersion -notin @(3L, 4L, 5L)) {
        throw 'safe-delete policy schemaVersion 必须是 JSON integer 3、4 或 5。'
    }
    $schemaVersion = [long]$policy.schemaVersion
    if ($policy.entries -isnot [Array]) {
        throw 'safe-delete policy entries 必须是 JSON array。'
    }
    if (@($policy.entries).Count -eq 0) { throw 'safe-delete policy 不得为空。' }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $canonicalEntries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($policy.entries)) {
        $baseEntryProperties = @(
            'id',
            'capabilityRoot',
            'minimumDescendantDepth',
            'rootDeletionPurpose',
            'deniedExactPaths'
        )
        if ($schemaVersion -eq 3) {
            Assert-CodexSafeTreeDeleteExactProperties `
                -Value $entry `
                -Names $baseEntryProperties `
                -Scope 'safe-delete policy entry'
        } else {
            $allowedEntryProperties = @($baseEntryProperties) + @(
                'allowHardLinks',
                'allowInternalDirectoryJunctions'
            )
            $requiredEntryProperties = @($baseEntryProperties)
            if ($schemaVersion -eq 5) {
                $allowedEntryProperties += @('minimumQuarantineAgeMinutes', 'producerFenceMode')
                $requiredEntryProperties += @(
                    'allowHardLinks',
                    'allowInternalDirectoryJunctions',
                    'minimumQuarantineAgeMinutes',
                    'producerFenceMode'
                )
            }
            $actualEntryProperties = @($entry.PSObject.Properties.Name)
            if (@($actualEntryProperties | Where-Object { $_ -notin $allowedEntryProperties }).Count -ne 0 -or
                @($requiredEntryProperties | Where-Object { $_ -notin $actualEntryProperties }).Count -ne 0) {
                throw 'safe-delete policy entry 属性集合非法。'
            }
        }
        if ($entry.id -isnot [string] -or
            $entry.capabilityRoot -isnot [string] -or
            $entry.rootDeletionPurpose -isnot [string]) {
            throw 'safe-delete policy entry id、capabilityRoot 与 rootDeletionPurpose 必须是 JSON string。'
        }
        $id = [string]$entry.id
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or -not $ids.Add($id)) {
            throw 'safe-delete policy entry id 非法或重复。'
        }
        $root = Assert-CodexHookDPath -Value ([string]$entry.capabilityRoot) -Name "safe-delete policy $id root"
        if ($root -in @('D:\', 'D:\Codex', 'D:\Codex\.codex', 'D:\Codex\projects')) {
            throw "safe-delete policy $id root 过宽。"
        }
        if (-not $roots.Add($root)) { throw 'safe-delete policy capabilityRoot 重复。' }
        if ($entry.minimumDescendantDepth -isnot [long]) {
            throw "safe-delete policy $id minimumDescendantDepth 必须是 JSON integer。"
        }
        $minimumDepth = [long]$entry.minimumDescendantDepth
        if ($minimumDepth -lt 0 -or $minimumDepth -gt 16) {
            throw "safe-delete policy $id minimumDescendantDepth 非法。"
        }
        $rootDeletionPurpose = [string]$entry.rootDeletionPurpose
        if ($rootDeletionPurpose -notin @('none', 'rebuildable-build-output', 'empty-project-state', 'retired-project-root')) {
            throw "safe-delete policy $id rootDeletionPurpose 非法。"
        }
        if ($minimumDepth -eq 0 -and
            $rootDeletionPurpose -cnotin @('rebuildable-build-output', 'empty-project-state', 'retired-project-root')) {
            throw "safe-delete policy $id 深度 0 必须显式限定 root 删除用途。"
        }
        if ($minimumDepth -gt 0 -and $rootDeletionPurpose -cne 'none') {
            throw "safe-delete policy $id 非 root 删除条目的 purpose 必须为 none。"
        }
        if ($rootDeletionPurpose -ceq 'rebuildable-build-output' -and
            $root -notmatch '^D:\\Codex\\projects\\[^\\]+\\.+$') {
            throw "safe-delete policy $id 可重建构建产物必须位于项目根之下。"
        }
        if ($rootDeletionPurpose -ceq 'rebuildable-build-output' -and
            $root -match '^D:\\Codex\\projects\\[^\\]+\\\.codex$') {
            throw "safe-delete policy $id 项目 .codex 不得声明为可重建构建产物。"
        }
        if ($rootDeletionPurpose -ceq 'empty-project-state' -and
            $root -notmatch '^D:\\Codex\\projects\\[^\\]+\\\.codex$') {
            throw "safe-delete policy $id 空项目状态必须精确指向项目 .codex 根。"
        }
        if ($rootDeletionPurpose -ceq 'retired-project-root' -and
            $root -notmatch '^D:\\Codex\\projects\\[^\\]+$') {
            throw "safe-delete policy $id 退役项目必须精确指向项目根。"
        }
        $allowHardLinks = $false
        $allowInternalDirectoryJunctions = $false
        if ($schemaVersion -in @(4, 5)) {
            if ($entry.PSObject.Properties.Name -contains 'allowHardLinks') {
                if ($entry.allowHardLinks -isnot [bool]) {
                    throw "safe-delete policy $id allowHardLinks 必须是 JSON boolean。"
                }
                $allowHardLinks = [bool]$entry.allowHardLinks
            }
            if ($entry.PSObject.Properties.Name -contains 'allowInternalDirectoryJunctions') {
                if ($entry.allowInternalDirectoryJunctions -isnot [bool]) {
                    throw "safe-delete policy $id allowInternalDirectoryJunctions 必须是 JSON boolean。"
                }
                $allowInternalDirectoryJunctions = [bool]$entry.allowInternalDirectoryJunctions
            }
        }
        if (($allowHardLinks -or $allowInternalDirectoryJunctions) -and
            ($minimumDepth -ne 0 -or $rootDeletionPurpose -cne 'rebuildable-build-output')) {
            throw "safe-delete policy $id link-aware 能力只允许深度 0 的可重建构建产物根。"
        }
        if ($entry.deniedExactPaths -isnot [Array]) {
            throw "safe-delete policy $id deniedExactPaths 必须是 JSON array。"
        }
        $minimumQuarantineAgeMinutes = 0L
        $producerFenceMode = 'manual-only'
        if ($schemaVersion -eq 5) {
            if ($entry.minimumQuarantineAgeMinutes -isnot [long] -or
                [long]$entry.minimumQuarantineAgeMinutes -lt 0L) {
                throw "safe-delete policy $id minimumQuarantineAgeMinutes 必须是非负 JSON integer。"
            }
            $minimumQuarantineAgeMinutes = [long]$entry.minimumQuarantineAgeMinutes
            if ($entry.producerFenceMode -isnot [string]) {
                throw "safe-delete policy $id producerFenceMode 必须是 JSON string。"
            }
            $producerFenceMode = [string]$entry.producerFenceMode
            if ($producerFenceMode -cnotin @('manual-only', 'os-handle-required')) {
                throw "safe-delete policy $id producerFenceMode 非法。"
            }
        }
        $denied = [Collections.Generic.List[string]]::new()
        foreach ($candidate in @($entry.deniedExactPaths)) {
            if ($candidate -isnot [string]) {
                throw "safe-delete policy $id deniedExactPaths 元素必须是 JSON string。"
            }
            $deniedPath = Assert-CodexHookDPath -Value ([string]$candidate) -Name "safe-delete policy $id denied path"
            if (-not (Test-CodexHookPathWithin -Path $deniedPath -ParentPath $root)) {
                throw "safe-delete policy $id denied path 越界。"
            }
            $denied.Add($deniedPath)
        }
        $canonicalEntries.Add([pscustomobject][ordered]@{
            id = $id
            capabilityRoot = $root
            minimumDescendantDepth = $minimumDepth
            rootDeletionPurpose = $rootDeletionPurpose
            allowHardLinks = $allowHardLinks
            allowInternalDirectoryJunctions = $allowInternalDirectoryJunctions
            minimumQuarantineAgeMinutes = $minimumQuarantineAgeMinutes
            producerFenceMode = $producerFenceMode
            deniedExactPaths = @($denied)
        })
    }

    return [pscustomobject][ordered]@{
        path = $fullPolicyPath
        sha256 = [string]$snapshot.sha256
        schemaVersion = $schemaVersion
        entries = @($canonicalEntries)
    }
}

function Resolve-CodexSafeTreeDeleteTarget {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][object]$Policy,
        [bool]$RequireExisting = $true
    )

    $fullTarget = Assert-CodexHookDPath -Value $TargetPath -Name 'safe-delete target'
    $fullRoot = Assert-CodexHookDPath -Value $CapabilityRoot -Name 'safe-delete capability root'
    $entry = @($Policy.entries | Where-Object {
        Test-CodexSafeTreeDeletePathEqual -Left ([string]$_.capabilityRoot) -Right $fullRoot
    })
    if ($entry.Count -ne 1) { throw 'safe-delete capability root 不在受管 allowlist。' }
    if (-not (Test-CodexHookPathWithin -Path $fullTarget -ParentPath $fullRoot)) {
        throw 'safe-delete target 必须位于 capability root 内。'
    }
    if ([string]$entry[0].rootDeletionPurpose -cin @('empty-project-state', 'retired-project-root') -and
        -not (Test-CodexSafeTreeDeletePathEqual -Left $fullTarget -Right $fullRoot)) {
        throw 'safe-delete root 删除用途只允许精确 capability root。'
    }
    if (([bool]$entry[0].allowHardLinks -or [bool]$entry[0].allowInternalDirectoryJunctions) -and
        -not (Test-CodexSafeTreeDeletePathEqual -Left $fullTarget -Right $fullRoot)) {
        throw 'safe-delete link-aware 能力只允许精确 capability root。'
    }
    $relative = $fullTarget.Substring($fullRoot.Length).TrimStart('\', '/')
    $depth = @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 }).Count
    if ($depth -lt [int]$entry[0].minimumDescendantDepth) {
        throw 'safe-delete target 未达到策略要求的最小后代深度。'
    }
    foreach ($deniedPath in @($entry[0].deniedExactPaths)) {
        if ((Test-CodexSafeTreeDeletePathEqual -Left $fullTarget -Right $deniedPath) -or
            (Test-CodexHookPathWithin -Path $fullTarget -ParentPath $deniedPath)) {
            throw 'safe-delete target 命中 denylist。'
        }
    }
    [void](Assert-CodexHookCapabilityPath `
        -Path $fullTarget `
        -CapabilityRoot $fullRoot `
        -AllowedExactPaths @($fullTarget) `
        -Name 'safe-delete target')
    if ($RequireExisting -and -not [IO.Directory]::Exists($fullTarget)) {
        throw 'safe-delete target 必须是现存普通目录。'
    }

    return [pscustomobject][ordered]@{
        targetPath = $fullTarget
        capabilityRoot = $fullRoot
        policyEntryId = [string]$entry[0].id
        rootDeletionPurpose = [string]$entry[0].rootDeletionPurpose
        allowHardLinks = [bool]$entry[0].allowHardLinks
        allowInternalDirectoryJunctions = [bool]$entry[0].allowInternalDirectoryJunctions
        minimumQuarantineAgeMinutes = [long]$entry[0].minimumQuarantineAgeMinutes
        producerFenceMode = [string]$entry[0].producerFenceMode
        policySchemaVersion = [long]$Policy.schemaVersion
    }
}

function Assert-CodexSafeTreeDeleteTargetTreePolicy {
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$TreeManifest,
        [string]$TreePath
    )

    if (-not [bool]$Target.allowInternalDirectoryJunctions -and
        @($TreeManifest.entries | Where-Object kind -ceq 'directory-junction').Count -ne 0) {
        throw 'safe-delete tree manifest 包含未授权的 directory junction。'
    }
    if ([string]$Target.rootDeletionPurpose -cne 'empty-project-state') { return }
    if (@($TreeManifest.entries | Where-Object kind -ceq 'file').Count -ne 0) {
        throw 'safe-delete 空项目状态树不得包含文件。'
    }
    if ([string]::IsNullOrWhiteSpace($TreePath)) { return }

    $fullTreePath = Assert-CodexHookDPath -Value $TreePath -Name 'safe-delete 空项目状态树'
    foreach ($entry in @($TreeManifest.entries | Where-Object kind -ceq 'directory')) {
        $nodePath = if ([string]$entry.relativePath -ceq '.') {
            $fullTreePath
        } else {
            Join-Path $fullTreePath ([string]$entry.relativePath).Replace('/', '\')
        }
        $streams = @(Get-Item -LiteralPath $nodePath -Stream * -Force -ErrorAction Stop)
        foreach ($stream in $streams) {
            if ($null -eq $stream -or
                $stream.PSObject.Properties.Name -notcontains 'Stream' -or
                $stream.Stream -isnot [string]) {
                throw 'safe-delete 空项目状态 alternate data stream 枚举结果非法。'
            }
            if ([string]$stream.Stream -cne ':$DATA') {
                throw 'safe-delete 空项目状态树不得包含 NTFS alternate data stream。'
            }
        }
    }
}

function Get-CodexSafeTreeDeleteQuarantineCapabilityRoot {
    param([Parameter(Mandatory)][object]$Target)

    if (Test-CodexSafeTreeDeletePathEqual `
            -Left ([string]$Target.targetPath) `
            -Right ([string]$Target.capabilityRoot)) {
        return Split-Path -Parent ([string]$Target.targetPath)
    }
    return [string]$Target.capabilityRoot
}

function Initialize-CodexSafeTreeDeleteEvidenceRoot {
    param([Parameter(Mandatory)][string]$EvidenceRoot)

    $fullRoot = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'safe-delete evidence root'
    $parent = Split-Path -Parent $fullRoot
    if (-not [IO.Directory]::Exists($parent)) { throw 'safe-delete evidence parent 不存在。' }
    if (-not [IO.Directory]::Exists($fullRoot)) {
        [void](New-CodexHookCapabilityDirectory `
            -Path $fullRoot `
            -CapabilityRoot $parent `
            -Name 'safe-delete evidence root' `
            -RequireMissing)
    } else {
        [void](Assert-CodexHookCapabilityPath -Path $fullRoot -CapabilityRoot $parent -Name 'safe-delete evidence root')
    }
    return $fullRoot
}

function Get-CodexSafeTreeDeleteTrustedElapsedTimeSample {
    param(
        [datetimeoffset]$WallClockUtc = [datetimeoffset]::UtcNow,
        [Nullable[long]]$ElapsedMilliseconds,
        [string]$BootSessionId,
        [scriptblock]$BootSessionSourceForTest,
        [switch]$RestartAmbiguous
    )

    if ($RestartAmbiguous) {
        throw 'safe-delete grace manual-review: restart ambiguity.'
    }
    $wallClockUtc = $WallClockUtc.ToUniversalTime()
    $elapsedMilliseconds = if ($null -eq $ElapsedMilliseconds) {
        [Environment]::TickCount64
    } else {
        [long]$ElapsedMilliseconds
    }
    if ($elapsedMilliseconds -lt 0L) {
        throw 'safe-delete grace manual-review: system uptime source returned a negative value.'
    }

    if ([string]::IsNullOrWhiteSpace($BootSessionId)) {
        try {
            $operatingSystems = @(if ($null -eq $BootSessionSourceForTest) {
                Get-CimInstance `
                    -ClassName Win32_OperatingSystem `
                    -Property LastBootUpTime `
                    -ErrorAction Stop
            } else {
                & $BootSessionSourceForTest
            })
        } catch {
            throw "safe-delete grace manual-review: boot session source unavailable: $($_.Exception.Message)"
        }
        if ($operatingSystems.Count -ne 1 -or $null -eq $operatingSystems[0].LastBootUpTime) {
            throw 'safe-delete grace manual-review: boot session source was ambiguous.'
        }
        try {
            $lastBootUtc = ([datetimeoffset]$operatingSystems[0].LastBootUpTime).ToUniversalTime()
        } catch {
            throw 'safe-delete grace manual-review: boot session source was invalid.'
        }
        if ($lastBootUtc -gt $wallClockUtc) {
            throw 'safe-delete grace manual-review: boot session source was in the future.'
        }
        $BootSessionId = Get-CodexHookTextSha256 -Text (
            '{0}|{1}' -f `
                [Environment]::MachineName.ToUpperInvariant(),
                $lastBootUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture))
    } elseif ($BootSessionId -notmatch '^[0-9a-f]{64}$') {
        throw 'safe-delete grace manual-review: boot session id was invalid.'
    }
    return [pscustomobject][ordered]@{
        wallClockUtc = $wallClockUtc
        elapsedTimeSource = 'system-uptime-milliseconds'
        elapsedMilliseconds = [long]$elapsedMilliseconds
        bootSessionId = [string]$BootSessionId
    }
}

function Assert-CodexSafeTreeDeleteQuarantineGrace {
    param(
        [Parameter(Mandatory)][object]$Anchor,
        [Parameter(Mandatory)][long]$MinimumAgeMinutes,
        [Parameter(Mandatory)][object]$TrustedTime
    )

    if ([string]$TrustedTime.elapsedTimeSource -cne [string]$Anchor.elapsedTimeSource -or
        [string]$TrustedTime.bootSessionId -cne [string]$Anchor.bootSessionId) {
        throw 'safe-delete grace manual-review: restart ambiguity.'
    }
    $wallElapsed = $TrustedTime.wallClockUtc - $Anchor.createdAtUtc
    if ($wallElapsed.Ticks -lt 0L) {
        throw 'safe-delete grace manual-review: trusted wall clock is at anchor 之前.'
    }
    $elapsedMilliseconds = [long]$TrustedTime.elapsedMilliseconds -
        [long]$Anchor.elapsedTimeStartMilliseconds
    if ($elapsedMilliseconds -lt 0L) {
        throw 'safe-delete grace manual-review: monotonic elapsed time rolled back.'
    }
    $wallElapsedMilliseconds = [long][Math]::Round($wallElapsed.TotalMilliseconds)
    $continuityDriftMilliseconds = [Math]::Abs(
        [decimal]$wallElapsedMilliseconds - [decimal]$elapsedMilliseconds)
    if ($continuityDriftMilliseconds -gt 5000L) {
        throw 'safe-delete grace manual-review: wall/monotonic continuity drift or abnormal forward jump.'
    }
    $minimumAgeMilliseconds = [decimal]$MinimumAgeMinutes * 60000L
    if ([decimal]$elapsedMilliseconds -lt $minimumAgeMilliseconds) {
        throw 'safe-delete grace not satisfied for minimumQuarantineAgeMinutes.'
    }
}

function Read-CodexSafeTreeDeleteQuarantineTimeAnchor {
    param(
        [Parameter(Mandatory)][object]$Anchor,
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$RunDirectory,
        [scriptblock]$MetricsObserver
    )

    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $Anchor `
        -Names @('path', 'sha256', 'identity', 'createdAtUtc') `
        -Scope 'safe-delete quarantine-time anchor binding'
    $anchorPath = Assert-CodexHookDPath -Value ([string]$Anchor.path) -Name 'safe-delete quarantine-time anchor path'
    if ([IO.Path]::GetFileName($anchorPath) -cne 'quarantine-time.json' -or
        -not (Test-CodexHookPathWithin -Path $anchorPath -ParentPath $RunDirectory)) {
        throw 'safe-delete quarantine-time anchor path 非法。'
    }
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $anchorPath `
        -Name 'safe-delete quarantine-time anchor' `
        -AllowedExactPaths @($anchorPath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$snapshot.bytes.Length)
    }
    if ([string]$snapshot.sha256 -cne [string]$Anchor.sha256) {
        throw 'safe-delete quarantine-time anchor SHA-256 漂移。'
    }
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($Anchor.identity) `
        -Actual @($snapshot.probe.identity) `
        -Scope 'safe-delete quarantine-time anchor'
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $document = $snapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $document `
        -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'transactionPath',
            'targetPath', 'quarantinePath', 'createdAtUtc', 'elapsedTimeSource',
            'elapsedTimeStartMilliseconds', 'bootSessionId') `
        -Scope 'safe-delete quarantine-time journal'
    if ($document.artifactType -cne 'env-governance.codex-safe-tree-delete-quarantine-time' -or
        $document.schemaVersion -isnot [long] -or [long]$document.schemaVersion -ne 2L -or
        [string]$document.generationId -cne [string]$Plan.generationId -or
        [string]$document.transactionPath -cne (Join-Path $RunDirectory 'transaction.json') -or
        [string]$document.targetPath -cne [string]$Transaction.targetPath -or
        [string]$document.quarantinePath -cne [string]$Transaction.quarantinePath -or
        [string]$document.createdAtUtc -cne [string]$Anchor.createdAtUtc -or
        $document.elapsedTimeSource -isnot [string] -or
        [string]$document.elapsedTimeSource -cne 'system-uptime-milliseconds' -or
        $document.elapsedTimeStartMilliseconds -isnot [long] -or
        [long]$document.elapsedTimeStartMilliseconds -lt 0L -or
        $document.bootSessionId -isnot [string] -or
        [string]$document.bootSessionId -notmatch '^[0-9a-f]{64}$') {
        throw 'safe-delete quarantine-time journal 绑定非法。'
    }
    $createdAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParseExact(
            [string]$document.createdAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$createdAt)) {
        throw 'safe-delete quarantine-time journal 时间非法。'
    }
    return [pscustomobject][ordered]@{
        path = $anchorPath
        sha256 = [string]$snapshot.sha256
        identity = @($snapshot.probe.identity)
        createdAtUtc = $createdAt
        elapsedTimeSource = [string]$document.elapsedTimeSource
        elapsedTimeStartMilliseconds = [long]$document.elapsedTimeStartMilliseconds
        bootSessionId = [string]$document.bootSessionId
    }
}

function New-CodexSafeTreeDeleteQuarantineTimeAnchor {
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$RunDirectory,
        [object]$TrustedTime
    )

    $anchorPath = Join-Path $RunDirectory 'quarantine-time.json'
    if ([IO.File]::Exists($anchorPath)) {
        throw 'safe-delete quarantine-time anchor 已存在但 transaction 未绑定。'
    }
    if ($null -eq $TrustedTime) {
        $TrustedTime = Get-CodexSafeTreeDeleteTrustedElapsedTimeSample
    }
    $createdAtText = $TrustedTime.wallClockUtc.ToUniversalTime().ToString(
        'o',
        [Globalization.CultureInfo]::InvariantCulture)
    $document = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-quarantine-time'
        schemaVersion = 2
        generationId = [string]$Plan.generationId
        transactionPath = Join-Path $RunDirectory 'transaction.json'
        targetPath = [string]$Transaction.targetPath
        quarantinePath = [string]$Transaction.quarantinePath
        createdAtUtc = $createdAtText
        elapsedTimeSource = [string]$TrustedTime.elapsedTimeSource
        elapsedTimeStartMilliseconds = [long]$TrustedTime.elapsedMilliseconds
        bootSessionId = [string]$TrustedTime.bootSessionId
    }
    $snapshot = New-CodexHookCapabilityJson `
        -Path $anchorPath `
        -Document $document `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($anchorPath) `
        -Scope 'safe-delete quarantine-time anchor publish'
    return [pscustomobject][ordered]@{
        path = $anchorPath
        sha256 = [string]$snapshot.sha256
        identity = @($snapshot.identity)
        createdAtUtc = $createdAtText
    }
}

function New-CodexSafeTreeDeletePlan {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'plan'
    $metricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
    $policy = Read-CodexSafeTreeDeletePolicy `
        -PolicyPath $PolicyPath `
        -MetricsObserver $metricsObserver
    $target = Resolve-CodexSafeTreeDeleteTarget `
        -TargetPath $TargetPath `
        -CapabilityRoot $CapabilityRoot `
        -Policy $policy
    $tree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $target.targetPath `
        -CapabilityRoot $target.capabilityRoot `
        -AllowedExactPaths @($target.targetPath) `
        -AllowHardLinks:([bool]$target.allowHardLinks) `
        -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
        -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
        -MetricsObserver $metricsObserver `
        -Name 'safe-delete plan snapshot'
    Assert-CodexSafeTreeDeleteTargetTreePolicy `
        -Target $target `
        -TreeManifest $tree `
        -TreePath $target.targetPath
    $generationId = [guid]::NewGuid().ToString('D')
    $now = [datetimeoffset]::UtcNow
    $topLevelEntries = @($tree.entries | Where-Object {
        $_.relativePath -cne '.' -and $_.relativePath -notmatch '/'
    } | ForEach-Object { [string]$_.relativePath })
    $fileIdentitiesV2 = New-CodexSafeTreeDeletePlanFileIdentitiesV2 `
        -TargetPath $target.targetPath `
        -TreeManifest $tree
    $document = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-plan'
        schemaVersion = 1
        generationId = $generationId
        createdAtUtc = $now.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        expiresAtUtc = $now.AddMinutes(30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        policyPath = $policy.path
        policySha256 = $policy.sha256
        policyEntryId = $target.policyEntryId
        targetPath = $target.targetPath
        capabilityRoot = $target.capabilityRoot
        treeManifest = $tree
        fileIdentitiesV2 = @($fileIdentitiesV2)
        summary = [pscustomobject][ordered]@{
            fileCount = @($tree.entries | Where-Object kind -ceq 'file').Count
            directoryCount = @($tree.entries | Where-Object kind -ceq 'directory').Count
            topLevelEntries = $topLevelEntries
        }
    }

    $evidenceRootPath = Initialize-CodexSafeTreeDeleteEvidenceRoot -EvidenceRoot $EvidenceRoot
    $runDirectory = Join-Path $evidenceRootPath ("{0}-{1}" -f $now.ToString('yyyyMMddTHHmmssZ'), $generationId)
    [void](New-CodexHookCapabilityDirectory `
        -Path $runDirectory `
        -CapabilityRoot $evidenceRootPath `
        -Name 'safe-delete run evidence' `
        -RequireMissing)
    $planPath = Join-Path $runDirectory 'plan.json'
    Set-CodexHookCapabilityJson `
        -Path $planPath `
        -Document $document `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($planPath) `
        -Scope 'safe-delete plan publish'
    $planSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $planPath `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($planPath) `
        -Name 'safe-delete plan published'
    & $metricsObserver 'hash-read' 0L ([long]$planSnapshot.bytes.Length)

    return [pscustomobject][ordered]@{
        planned = $true
        targetPath = $target.targetPath
        policyEntryId = $target.policyEntryId
        fileCount = $document.summary.fileCount
        directoryCount = $document.summary.directoryCount
        planPath = $planPath
        planSha256 = $planSnapshot.sha256
        expiresAtUtc = $document.expiresAtUtc
        metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
    }
}

function ConvertFrom-CodexSafeTreeDeleteFileIdentityV2Record {
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$Scope
    )

    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $Record `
        -Names @(
            'relativePath', 'volumeSerialNumber', 'fileId128',
            'fileSize', 'lastWriteTimeUtc', 'capturedAtUtc'
        ) `
        -Scope $Scope
    if ($Record.relativePath -isnot [string]) {
        throw "$Scope relativePath 必须是 JSON string。"
    }
    $relativePath = [string]$Record.relativePath
    Assert-CodexHookDirectoryTreeRelativePath -RelativePath $relativePath -Scope $Scope
    if ($relativePath -ceq '.') {
        throw "$Scope 不得使用根目录 relativePath。"
    }
    $volumeSerialNumber = ConvertTo-CodexSafeTreeDeleteUInt64JsonInteger `
        -Value $Record.volumeSerialNumber `
        -Scope "$Scope volumeSerialNumber"
    if ($Record.fileId128 -isnot [string]) {
        throw "$Scope fileId128 必须是 Base64 JSON string。"
    }
    try {
        $fileId128 = [Convert]::FromBase64String([string]$Record.fileId128)
    } catch {
        throw "$Scope fileId128 不是合法 Base64。"
    }
    if ($null -eq $fileId128 -or $fileId128.Length -ne 16) {
        throw "$Scope fileId128 解码后必须是 16 字节。"
    }
    if ($Record.fileSize -isnot [long] -or [long]$Record.fileSize -lt 0L) {
        throw "$Scope fileSize 必须是非负 JSON integer。"
    }
    $lastWrite = [datetimeoffset]::MinValue
    if ($Record.lastWriteTimeUtc -isnot [string] -or
        -not [datetimeoffset]::TryParseExact(
            [string]$Record.lastWriteTimeUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$lastWrite)) {
        throw "$Scope lastWriteTimeUtc 非法。"
    }
    $captured = [datetimeoffset]::MinValue
    if ($Record.capturedAtUtc -isnot [string] -or
        -not [datetimeoffset]::TryParseExact(
            [string]$Record.capturedAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$captured)) {
        throw "$Scope capturedAtUtc 非法。"
    }

    $identity = [CodexSafeTreeDelete.FileIdentityV2]::new()
    $identity.VolumeSerialNumber = $volumeSerialNumber
    $identity.FileId128 = $fileId128
    $identity.FileSize = [long]$Record.fileSize
    $identity.LastWriteTimeUtc = $lastWrite.UtcDateTime
    $identity.CapturedAtUtc = $captured.UtcDateTime
    return [pscustomobject][ordered]@{
        relativePath = $relativePath
        identity = $identity
    }
}

function Read-CodexSafeTreeDeleteFileIdentityV2FromPlan {
    param([Parameter(Mandatory)][object]$Plan)

    if ($null -eq $Plan -or $null -eq $Plan.PSObject) {
        throw 'safe-delete plan 不是对象。'
    }
    if ($Plan.artifactType -cne 'env-governance.codex-safe-tree-delete-plan') {
        throw 'safe-delete plan artifact 非法。'
    }
    if (-not (@($Plan.PSObject.Properties.Name) -contains 'fileIdentitiesV2')) {
        throw 'safe-delete plan 缺少 fileIdentitiesV2，拒绝将旧 identity 假装为 FileIdentityV2。'
    }
    if ($Plan.fileIdentitiesV2 -isnot [Array]) {
        throw 'safe-delete plan fileIdentitiesV2 必须是 JSON array。'
    }
    if ($null -eq $Plan.treeManifest -or $null -eq $Plan.treeManifest.PSObject) {
        throw 'safe-delete plan treeManifest 非法。'
    }

    $plannedFilePaths = [Collections.Generic.List[string]]::new()
    $plannedFileSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Plan.treeManifest.entries)) {
        if ([string]$entry.kind -cne 'file') { continue }
        $relativePath = [string]$entry.relativePath
        if (-not $plannedFileSet.Add($relativePath)) {
            throw "safe-delete plan treeManifest file relativePath 重复：$relativePath"
        }
        $plannedFilePaths.Add($relativePath)
    }

    $records = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $index = 0
    foreach ($record in @($Plan.fileIdentitiesV2)) {
        $converted = ConvertFrom-CodexSafeTreeDeleteFileIdentityV2Record `
            -Record $record `
            -Scope "safe-delete plan fileIdentitiesV2[$index]"
        if (-not $seen.Add([string]$converted.relativePath)) {
            throw "safe-delete plan fileIdentitiesV2 relativePath 重复：$($converted.relativePath)"
        }
        $records.Add($converted)
        $index += 1
    }

    if ($seen.Count -ne $plannedFileSet.Count -or
        @($plannedFileSet | Where-Object { -not $seen.Contains($_) }).Count -ne 0) {
        throw 'safe-delete plan fileIdentitiesV2 必须与 treeManifest file 集合精确对应。'
    }

    $byPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $records) {
        $byPath.Add([string]$record.relativePath, $record)
    }
    $ordered = [Collections.Generic.List[object]]::new()
    foreach ($relativePath in $plannedFilePaths) {
        $ordered.Add($byPath[$relativePath])
    }
    return $ordered
}

function Get-CodexSafeTreeDeleteNamespaceState {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $entry = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [Management.Automation.ItemNotFoundException] {
        return [pscustomobject][ordered]@{
            present = $false
            entryType = 'absent'
        }
    }

    $entryType = if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        'reparse-point'
    } elseif ($entry.PSIsContainer) {
        'directory'
    } elseif ($entry -is [IO.FileInfo]) {
        'file'
    } else {
        'other'
    }
    return [pscustomobject][ordered]@{
        present = $true
        entryType = $entryType
    }
}

function Read-CodexSafeTreeDeleteObservedV1Transaction {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExpectedTargetPath,
        [Parameter(Mandatory)][string]$ExpectedQuarantinePath
    )

    if ($Document.schemaVersion -isnot [long] -or [long]$Document.schemaVersion -ne 1L) {
        throw 'safe-delete observed transaction schemaVersion 必须是 JSON integer 1。'
    }
    if ($Plan.artifactType -cne 'env-governance.codex-safe-tree-delete-plan' -or
        $Plan.schemaVersion -isnot [long] -or [long]$Plan.schemaVersion -ne 1L -or
        $Plan.generationId -isnot [string] -or $Plan.targetPath -isnot [string]) {
        throw 'safe-delete observed transaction v1 的 plan artifact/schema 非法。'
    }
    $planGenerationId = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$Plan.generationId, 'D', [ref]$planGenerationId)) {
        throw 'safe-delete observed transaction v1 的 plan generationId 非法。'
    }
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $Document `
        -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'planPath', 'planSha256',
            'targetPath', 'quarantinePath', 'status', 'updatedAtUtc'
        ) `
        -Scope 'safe-delete observed transaction v1'
    foreach ($stringProperty in @(
            'artifactType', 'generationId', 'planPath', 'planSha256',
            'targetPath', 'quarantinePath', 'status', 'updatedAtUtc')) {
        if ($Document.$stringProperty -isnot [string]) {
            throw "safe-delete observed transaction v1 $stringProperty 必须是 JSON string。"
        }
    }
    $updatedAtUtc = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParseExact(
            [string]$Document.updatedAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$updatedAtUtc)) {
        throw 'safe-delete observed transaction v1 updatedAtUtc 非法。'
    }
    if ($Document.artifactType -cne 'env-governance.codex-safe-tree-delete-transaction' -or
        [string]$Document.status -cnotin @(
            'prepared', 'quarantined', 'purging', 'purged', 'restored', 'rolled-back')) {
        throw 'safe-delete observed transaction v1 状态或 schema 非法。'
    }
    if ([string]$Document.generationId -cne [string]$Plan.generationId -or
        -not (Test-CodexSafeTreeDeletePathEqual -Left $Document.planPath -Right $PlanPath) -or
        [string]$Document.planSha256 -cne $PlanSha256 -or
        -not (Test-CodexSafeTreeDeletePathEqual -Left $Document.targetPath -Right $ExpectedTargetPath) -or
        -not (Test-CodexSafeTreeDeletePathEqual `
            -Left $Document.quarantinePath `
            -Right $ExpectedQuarantinePath)) {
        throw "safe-delete observed transaction v1 与受管 plan 不一致：$TransactionPath"
    }

    return [pscustomobject][ordered]@{
        targetPath = [string]$Document.targetPath
        quarantinePath = [string]$Document.quarantinePath
        status = [string]$Document.status
        updatedAtUtc = [string]$Document.updatedAtUtc
    }
}

function Assert-CodexSafeTreeDeletePlanExpiration {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$Scope,
        [switch]$AllowExpiredPlan
    )

    $expiresAt = [datetimeoffset]::MinValue
    if ($Plan.expiresAtUtc -isnot [string] -or
        -not [datetimeoffset]::TryParseExact(
            [string]$Plan.expiresAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$expiresAt) -or
        (-not $AllowExpiredPlan -and $expiresAt -le [datetimeoffset]::UtcNow)) {
        throw "$Scope 已过期或时间非法。"
    }
}

function Read-CodexSafeTreeDeleteArchiveSource {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [scriptblock]$MetricsObserver
    )

    if ($ApprovedTransactionSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'ApprovedTransactionSha256 格式非法。'
    }
    $fullEvidenceRoot = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'safe-delete archive evidence root'
    $fullTransactionPath = Assert-CodexHookDPath -Value $TransactionPath -Name 'safe-delete archive transaction path'
    if ([IO.Path]::GetFileName($fullTransactionPath) -cne 'transaction.json' -or
        -not (Test-CodexHookPathWithin -Path $fullTransactionPath -ParentPath $fullEvidenceRoot) -or
        (Test-CodexSafeTreeDeletePathEqual -Left $fullTransactionPath -Right $fullEvidenceRoot)) {
        throw 'safe-delete archive transaction path 不在受管 evidence run 下。'
    }
    $runDirectory = Split-Path -Parent $fullTransactionPath
    if (-not (Test-CodexSafeTreeDeletePathEqual `
            -Left (Split-Path -Parent $runDirectory) `
            -Right $fullEvidenceRoot)) {
        throw 'safe-delete archive transaction 必须位于 evidence root 的直接 operation run 下。'
    }
    [void](Assert-CodexHookCapabilityPath `
        -Path $fullTransactionPath `
        -CapabilityRoot $fullEvidenceRoot `
        -AllowedExactPaths @($fullTransactionPath) `
        -Name 'safe-delete archive transaction')

    $planPath = Join-Path $runDirectory 'plan.json'
    $planSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $planPath `
        -Name 'safe-delete archive plan' `
        -AllowedExactPaths @($planPath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$planSnapshot.bytes.Length)
    }
    Assert-CodexHookStrictJsonText -JsonText $planSnapshot.text
    $plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeletePlanDocumentProperties `
        -Plan $plan `
        -Scope 'safe-delete archive plan'
    if ($plan.artifactType -cne 'env-governance.codex-safe-tree-delete-plan' -or
        $plan.schemaVersion -isnot [long] -or [long]$plan.schemaVersion -ne 1L) {
        throw 'safe-delete archive plan artifact/schema 非法。'
    }
    foreach ($stringProperty in @(
            'generationId', 'createdAtUtc', 'expiresAtUtc', 'policyPath', 'policySha256',
            'policyEntryId', 'targetPath', 'capabilityRoot')) {
        if ($plan.$stringProperty -isnot [string]) {
            throw "safe-delete archive plan $stringProperty 必须是 JSON string。"
        }
    }
    $planGenerationId = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$plan.generationId, 'D', [ref]$planGenerationId) -or
        [string]$plan.policySha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'safe-delete archive plan generationId 或 policy SHA-256 非法。'
    }
    Assert-CodexSafeTreeDeletePlanExpiration `
        -Plan $plan `
        -Scope 'safe-delete archive plan' `
        -AllowExpiredPlan
    [void](ConvertTo-CodexHookExpectedDirectoryTreeManifest `
        -Manifest $plan.treeManifest `
        -Scope 'safe-delete archive plan')
    $expectedTargetPath = Assert-CodexHookDPath `
        -Value ([string]$plan.targetPath) `
        -Name 'safe-delete archive plan target'
    $expectedQuarantinePath = Join-Path `
        (Split-Path -Parent $expectedTargetPath) `
        ('.codex-safe-delete-{0}.quarantine' -f ([string]$plan.generationId))

    $transactionSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $fullTransactionPath `
        -Name 'safe-delete archive transaction' `
        -AllowedExactPaths @($fullTransactionPath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$transactionSnapshot.bytes.Length)
    }
    if ([string]$transactionSnapshot.sha256 -cne $ApprovedTransactionSha256) {
        throw 'safe-delete archive approved transaction SHA-256 不匹配。'
    }
    Assert-CodexHookStrictJsonText -JsonText $transactionSnapshot.text
    $transaction = $transactionSnapshot.text |
        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    if ($transaction.schemaVersion -isnot [long] -or
        [long]$transaction.schemaVersion -notin @(1L, 2L, 3L)) {
        throw 'safe-delete archive transaction schemaVersion 必须是 JSON integer 1、2 或 3。'
    }
    $transactionSchemaVersion = [long]$transaction.schemaVersion
    $restoreJournalAnchorCount = 0L
    if ($transactionSchemaVersion -eq 1L) {
        $observedTransaction = Read-CodexSafeTreeDeleteObservedV1Transaction `
            -Document $transaction `
            -TransactionPath $fullTransactionPath `
            -PlanPath $planPath `
            -PlanSha256 ([string]$planSnapshot.sha256) `
            -Plan $plan `
            -ExpectedTargetPath $expectedTargetPath `
            -ExpectedQuarantinePath $expectedQuarantinePath
    } else {
        $transaction = ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument `
            -Document $transaction `
            -AllowArchiveRestoreAnchorRefusal
        if ($transactionSchemaVersion -eq 3L) {
            $restoreJournalAnchorCount = [long]@($transaction.restoreJournalAnchors).Count
        }
        Assert-CodexSafeTreeDeleteStrictTransactionEvidence `
            -Transaction $transaction `
            -Plan $plan `
            -PlanPath $planPath `
            -PlanSha256 ([string]$planSnapshot.sha256) `
            -TargetPath $expectedTargetPath `
            -QuarantinePath $expectedQuarantinePath `
            -RunDirectory $runDirectory `
            -MetricsObserver $MetricsObserver
        Assert-CodexSafeTreeDeleteTerminalDirectoryEvidence `
            -RunDirectory $runDirectory `
            -Transaction $transaction `
            -Plan $plan `
            -MetricsObserver $MetricsObserver
        $observedTransaction = [pscustomobject][ordered]@{
            targetPath = [string]$transaction.targetPath
            quarantinePath = [string]$transaction.quarantinePath
            status = [string]$transaction.status
            updatedAtUtc = [string]$transaction.updatedAtUtc
        }
    }

    return [pscustomobject][ordered]@{
        runDirectory = $runDirectory
        planPath = $planPath
        planSha256 = [string]$planSnapshot.sha256
        planIdentity = @($planSnapshot.probe.identity)
        plan = $plan
        transactionPath = $fullTransactionPath
        transactionSha256 = [string]$transactionSnapshot.sha256
        transactionIdentity = @($transactionSnapshot.probe.identity)
        transactionSchemaVersion = $transactionSchemaVersion
        transactionStatus = [string]$observedTransaction.status
        transactionUpdatedAtUtc = [string]$observedTransaction.updatedAtUtc
        targetPath = [string]$observedTransaction.targetPath
        quarantinePath = [string]$observedTransaction.quarantinePath
        restoreJournalAnchorCount = $restoreJournalAnchorCount
    }
}

function Read-CodexSafeTreeDeleteTerminalArchive {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [scriptblock]$MetricsObserver
    )

    $archivePath = Join-Path $RunDirectory 'terminal-archive.json'
    $archiveSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $archivePath `
        -Name 'safe-delete terminal archive' `
        -AllowedExactPaths @($archivePath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$archiveSnapshot.bytes.Length)
    }
    Assert-CodexHookStrictJsonText -JsonText $archiveSnapshot.text
    $archive = $archiveSnapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $archive `
        -Names @(
            'artifactType', 'schemaVersion', 'generationId',
            'planPath', 'planSha256', 'planIdentity',
            'transactionPath', 'transactionSha256', 'transactionIdentity',
            'transactionSchemaVersion', 'transactionStatus', 'transactionUpdatedAtUtc',
            'targetPath', 'quarantinePath', 'quarantineAbsent',
            'restoreJournalAnchorCount', 'archivedAtUtc'
        ) `
        -Scope 'safe-delete terminal archive'
    foreach ($stringProperty in @(
            'artifactType', 'generationId', 'planPath', 'planSha256',
            'transactionPath', 'transactionSha256', 'transactionStatus',
            'transactionUpdatedAtUtc', 'targetPath', 'quarantinePath', 'archivedAtUtc')) {
        if ($archive.$stringProperty -isnot [string]) {
            throw "safe-delete terminal archive $stringProperty 必须是 JSON string。"
        }
    }
    $archivedAtUtc = [datetimeoffset]::MinValue
    if ($archive.artifactType -cne 'env-governance.codex-safe-tree-delete-terminal-archive' -or
        $archive.schemaVersion -isnot [long] -or [long]$archive.schemaVersion -ne 1L -or
        $archive.transactionSchemaVersion -isnot [long] -or
        [long]$archive.transactionSchemaVersion -notin @(1L, 2L, 3L) -or
        $archive.quarantineAbsent -isnot [bool] -or -not [bool]$archive.quarantineAbsent -or
        $archive.restoreJournalAnchorCount -isnot [long] -or
        [long]$archive.restoreJournalAnchorCount -ne 0L -or
        [string]$archive.transactionStatus -cne 'purged' -or
        -not [datetimeoffset]::TryParseExact(
            [string]$archive.archivedAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$archivedAtUtc)) {
        throw 'safe-delete terminal archive schema 或判据声明非法。'
    }
    $expectedPlanPath = Join-Path $RunDirectory 'plan.json'
    $expectedTransactionPath = Join-Path $RunDirectory 'transaction.json'
    if (-not (Test-CodexSafeTreeDeletePathEqual -Left $archive.planPath -Right $expectedPlanPath) -or
        -not (Test-CodexSafeTreeDeletePathEqual `
            -Left $archive.transactionPath -Right $expectedTransactionPath)) {
        throw 'safe-delete terminal archive 引用越出 operation run。'
    }
    $source = Read-CodexSafeTreeDeleteArchiveSource `
        -TransactionPath $expectedTransactionPath `
        -ApprovedTransactionSha256 ([string]$archive.transactionSha256) `
        -EvidenceRoot $EvidenceRoot `
        -MetricsObserver $MetricsObserver
    if ([string]$archive.generationId -cne [string]$source.plan.generationId -or
        [string]$archive.planSha256 -cne [string]$source.planSha256 -or
        [long]$archive.transactionSchemaVersion -ne [long]$source.transactionSchemaVersion -or
        [string]$archive.transactionUpdatedAtUtc -cne [string]$source.transactionUpdatedAtUtc -or
        -not (Test-CodexSafeTreeDeletePathEqual -Left $archive.targetPath -Right $source.targetPath) -or
        -not (Test-CodexSafeTreeDeletePathEqual `
            -Left $archive.quarantinePath -Right $source.quarantinePath)) {
        throw 'safe-delete terminal archive 与当前受管 evidence 内容不一致。'
    }
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($archive.planIdentity) `
        -Actual @($source.planIdentity) `
        -Scope 'safe-delete terminal archive plan'
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($archive.transactionIdentity) `
        -Actual @($source.transactionIdentity) `
        -Scope 'safe-delete terminal archive transaction'
    if ([string]$source.transactionStatus -cne 'purged') {
        throw 'safe-delete terminal archive transaction status 已漂移。'
    }
    $quarantineState = Get-CodexSafeTreeDeleteNamespaceState -Path $source.quarantinePath
    if ([bool]$quarantineState.present) {
        throw 'safe-delete terminal archive quarantine 已重新出现。'
    }
    if ([long]$source.restoreJournalAnchorCount -ne 0L) {
        throw 'safe-delete terminal archive Restore journal anchors 已出现。'
    }
    $targetState = Get-CodexSafeTreeDeleteNamespaceState -Path $source.targetPath
    return [pscustomobject][ordered]@{
        path = $archivePath
        sha256 = [string]$archiveSnapshot.sha256
        identity = @($archiveSnapshot.probe.identity)
        document = $archive
        source = $source
        targetState = $targetState
        quarantineState = $quarantineState
    }
}

function New-CodexSafeTreeDeleteArchiveRefusal {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][object]$MetricsState
    )

    return [pscustomobject][ordered]@{
        archived = $false
        alreadyArchived = $false
        refusalReason = $Reason
        metrics = Complete-CodexSafeTreeDeleteMetrics -State $MetricsState
    }
}

function Invoke-CodexSafeTreeDeleteArchive {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'archive'
    $metricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
    $initial = Read-CodexSafeTreeDeleteArchiveSource `
        -TransactionPath $TransactionPath `
        -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
        -EvidenceRoot $EvidenceRoot `
        -MetricsObserver $metricsObserver
    if ([string]$initial.transactionStatus -cne 'purged') {
        return New-CodexSafeTreeDeleteArchiveRefusal `
            -Reason 'transaction-status-not-purged' -MetricsState $metricsState
    }
    if ([bool](Get-CodexSafeTreeDeleteNamespaceState -Path $initial.quarantinePath).present) {
        return New-CodexSafeTreeDeleteArchiveRefusal `
            -Reason 'quarantine-present' -MetricsState $metricsState
    }
    if ([long]$initial.restoreJournalAnchorCount -ne 0L) {
        return New-CodexSafeTreeDeleteArchiveRefusal `
            -Reason 'restore-journal-anchors-present' -MetricsState $metricsState
    }

    $mutexHash = Get-CodexHookTextSha256 -Text $initial.targetPath.ToUpperInvariant()
    $mutex = [Threading.Mutex]::new($false, "Local\CodexSafeTreeDelete-$mutexHash")
    $held = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'safe-delete target mutex busy。' }
        $source = Read-CodexSafeTreeDeleteArchiveSource `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
            -EvidenceRoot $EvidenceRoot `
            -MetricsObserver $metricsObserver
        if ([string]$source.transactionStatus -cne 'purged') {
            return New-CodexSafeTreeDeleteArchiveRefusal `
                -Reason 'transaction-status-not-purged' -MetricsState $metricsState
        }
        if ([bool](Get-CodexSafeTreeDeleteNamespaceState -Path $source.quarantinePath).present) {
            return New-CodexSafeTreeDeleteArchiveRefusal `
                -Reason 'quarantine-present' -MetricsState $metricsState
        }
        if ([long]$source.restoreJournalAnchorCount -ne 0L) {
            return New-CodexSafeTreeDeleteArchiveRefusal `
                -Reason 'restore-journal-anchors-present' -MetricsState $metricsState
        }

        $archivePath = Join-Path $source.runDirectory 'terminal-archive.json'
        if ([IO.File]::Exists($archivePath)) {
            $existing = Read-CodexSafeTreeDeleteTerminalArchive `
                -RunDirectory $source.runDirectory `
                -EvidenceRoot $EvidenceRoot `
                -MetricsObserver $metricsObserver
            return [pscustomobject][ordered]@{
                archived = $true
                alreadyArchived = $true
                archivePath = [string]$existing.path
                archiveSha256 = [string]$existing.sha256
                archivedAtUtc = [string]$existing.document.archivedAtUtc
                metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
            }
        }
        $archivedAtUtc = [datetimeoffset]::UtcNow.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture)
        $archiveDocument = [pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-terminal-archive'
            schemaVersion = 1L
            generationId = [string]$source.plan.generationId
            planPath = [string]$source.planPath
            planSha256 = [string]$source.planSha256
            planIdentity = @($source.planIdentity)
            transactionPath = [string]$source.transactionPath
            transactionSha256 = [string]$source.transactionSha256
            transactionIdentity = @($source.transactionIdentity)
            transactionSchemaVersion = [long]$source.transactionSchemaVersion
            transactionStatus = [string]$source.transactionStatus
            transactionUpdatedAtUtc = [string]$source.transactionUpdatedAtUtc
            targetPath = [string]$source.targetPath
            quarantinePath = [string]$source.quarantinePath
            quarantineAbsent = $true
            restoreJournalAnchorCount = 0L
            archivedAtUtc = $archivedAtUtc
        }
        [void](New-CodexHookCapabilityJson `
            -Path $archivePath `
            -Document $archiveDocument `
            -CapabilityRoot $source.runDirectory `
            -AllowedExactPaths @($archivePath) `
            -Scope 'safe-delete terminal archive publish')
        $published = Read-CodexSafeTreeDeleteTerminalArchive `
            -RunDirectory $source.runDirectory `
            -EvidenceRoot $EvidenceRoot `
            -MetricsObserver $metricsObserver
        return [pscustomobject][ordered]@{
            archived = $true
            alreadyArchived = $false
            archivePath = [string]$published.path
            archiveSha256 = [string]$published.sha256
            archivedAtUtc = [string]$published.document.archivedAtUtc
            metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
        }
    } finally {
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Resolve-CodexSafeTreeDeleteArchivedStatusOperation {
    param(
        [Parameter(Mandatory)][object]$RunItem,
        [Parameter(Mandatory)][string]$CurrentPolicySha256,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][bool]$CandidatePolicyRequested,
        [Parameter(Mandatory)][scriptblock]$MetricsObserver
    )

    $archive = Read-CodexSafeTreeDeleteTerminalArchive `
        -RunDirectory ([string]$RunItem.FullName) `
        -EvidenceRoot $FullEvidenceRoot `
        -MetricsObserver $MetricsObserver
    $source = $archive.source
    $targetState = $archive.targetState
    $quarantineState = $archive.quarantineState
    $deletionOutcome = New-CodexSafeTreeDeleteOutcome `
        -NamespaceAbsent (-not [bool]$targetState.present) `
        -LogicalCompletion $true
    $operation = [pscustomobject][ordered]@{
        operationId = [string]$RunItem.Name
        runDirectory = [string]$RunItem.FullName
        lifecycle = 'terminal'
        safeActions = @()
        targetPath = [string]$source.targetPath
        quarantinePath = [string]$source.quarantinePath
        targetPresent = [bool]$targetState.present
        quarantinePresent = [bool]$quarantineState.present
        targetEntryType = [string]$targetState.entryType
        quarantineEntryType = [string]$quarantineState.entryType
        namespaceAbsent = $deletionOutcome.namespaceAbsent
        logicalCompletion = $deletionOutcome.logicalCompletion
        physicalReclaimStatus = $deletionOutcome.physicalReclaimStatus
        physicalReclaimReason = $deletionOutcome.physicalReclaimReason
        deletionOutcome = $deletionOutcome
        policyCompatible = [string]$source.plan.policySha256 -ceq $CurrentPolicySha256
        schemaCompatible = [long]$source.transactionSchemaVersion -in @(2L, 3L)
        candidatePolicyCompatible = if ($CandidatePolicyRequested) { $true } else { $null }
        planSchemaVersion = [long]$source.plan.schemaVersion
        transactionSchemaVersion = [long]$source.transactionSchemaVersion
        transactionStatus = [string]$source.transactionStatus
        transactionUpdatedAtUtc = [string]$source.transactionUpdatedAtUtc
        journalStatus = 'archived'
        errors = @()
    }
    return [pscustomobject][ordered]@{
        complete = $true
        operation = $operation
    }
}

function Resolve-CodexSafeTreeDeleteStatusOperation {
    param(
        [Parameter(Mandatory)][object]$RunItem,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$CurrentPolicySha256,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][bool]$CandidatePolicyRequested,
        [AllowNull()][object]$CandidatePolicy,
        [Parameter(Mandatory)][object]$MetricsState,
        [Parameter(Mandatory)][scriptblock]$TreeMetricsObserver
    )

    $complete = $true
        $errors = [Collections.Generic.List[string]]::new()
        $lifecycle = 'manual-review'
        $safeActions = @()
        $targetPath = $null
        $quarantinePath = $null
        $targetPresent = $null
        $quarantinePresent = $null
        $targetEntryType = 'unknown'
        $quarantineEntryType = 'unknown'
        $planSchemaVersion = $null
        $transactionSchemaVersion = $null
        $transactionStatus = $null
        $transactionUpdatedAtUtc = $null
        $policyCompatible = $false
        $schemaCompatible = $false
        $candidatePolicyCompatible = $null
        $journalStatus = 'not-evaluated'
        try {
            if (-not $runItem.PSIsContainer -or
                ($runItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'evidence record 必须是 no-follow 普通目录。'
            }
            $runDirectory = Assert-CodexHookDPath -Value $runItem.FullName -Name 'safe-delete status run'
            [void](Assert-CodexHookCapabilityPath `
                -Path $runDirectory `
                -CapabilityRoot $fullEvidenceRoot `
                -AllowedExactPaths @($runDirectory) `
                -Name 'safe-delete status run')
            $archivePath = Join-Path $runDirectory 'terminal-archive.json'
            if ([IO.File]::Exists($archivePath)) {
                return Resolve-CodexSafeTreeDeleteArchivedStatusOperation `
                    -RunItem $runItem `
                    -CurrentPolicySha256 $CurrentPolicySha256 `
                    -FullEvidenceRoot $FullEvidenceRoot `
                    -CandidatePolicyRequested $CandidatePolicyRequested `
                    -MetricsObserver $TreeMetricsObserver
            }
            $planPath = Join-Path $runDirectory 'plan.json'
            $transactionPath = Join-Path $runDirectory 'transaction.json'
            if (-not [IO.File]::Exists($planPath)) {
                if ([IO.File]::Exists($transactionPath)) {
                    $invalidSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                        -Path $transactionPath `
                        -Name 'safe-delete status orphan transaction' `
                        -AllowedExactPaths @($transactionPath)
                    $metricsState.bytesHashed = [long]$metricsState.bytesHashed + $invalidSnapshot.bytes.Length
                    Assert-CodexHookStrictJsonText -JsonText $invalidSnapshot.text
                }
                throw 'evidence record 缺少 plan.json。'
            }
            $planSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                -Path $planPath `
                -Name 'safe-delete status plan' `
                -AllowedExactPaths @($planPath)
            $metricsState.bytesHashed = [long]$metricsState.bytesHashed + $planSnapshot.bytes.Length
            Assert-CodexHookStrictJsonText -JsonText $planSnapshot.text
            $plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
            $planSchemaVersion = [long]$plan.schemaVersion
            try {
                $approvedPlan = Read-CodexSafeTreeDeleteApprovedPlan `
                    -PlanPath $planPath `
                    -ApprovedPlanSha256 ([string]$planSnapshot.sha256) `
                    -PolicyPath $PolicyPath `
                    -EvidenceRoot $fullEvidenceRoot `
                    -AllowMissingTarget `
                    -AllowExpiredPlan `
                    -AllowPolicyShaDrift `
                    -MetricsObserver $treeMetricsObserver
            } catch {
                $planApprovalError = $_.Exception.Message
                if (-not [IO.File]::Exists($transactionPath)) { throw }
                $transactionSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                    -Path $transactionPath `
                    -Name 'safe-delete status observed transaction after plan rejection' `
                    -AllowedExactPaths @($transactionPath)
                $metricsState.bytesHashed =
                    [long]$metricsState.bytesHashed + $transactionSnapshot.bytes.Length
                Assert-CodexHookStrictJsonText -JsonText $transactionSnapshot.text
                $transaction = $transactionSnapshot.text |
                    ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
                $transactionSchemaVersion = [long]$transaction.schemaVersion
                if ($transactionSchemaVersion -ne 1L) { throw }
                if ($plan.targetPath -isnot [string] -or $plan.generationId -isnot [string]) { throw }
                $observedTargetPath = [string]$plan.targetPath
                $observedQuarantinePath = Join-Path `
                    (Split-Path -Parent $observedTargetPath) `
                    ('.codex-safe-delete-{0}.quarantine' -f ([string]$plan.generationId))
                $observedTransaction = Read-CodexSafeTreeDeleteObservedV1Transaction `
                    -Document $transaction `
                    -TransactionPath $transactionPath `
                    -PlanPath $planPath `
                    -PlanSha256 ([string]$planSnapshot.sha256) `
                    -Plan $plan `
                    -ExpectedTargetPath $observedTargetPath `
                    -ExpectedQuarantinePath $observedQuarantinePath
                $targetPath = [string]$observedTransaction.targetPath
                $quarantinePath = [string]$observedTransaction.quarantinePath
                $transactionStatus = [string]$observedTransaction.status
                $transactionUpdatedAtUtc = [string]$observedTransaction.updatedAtUtc
                $schemaCompatible = $false
                $journalStatus = 'unavailable'
                $errors.Add("plan 当前语义拒绝：$planApprovalError")
                throw 'transaction v1 仅支持 Status 只读观测；Purge/Restore 不可恢复且继续拒绝。'
            }
            $policyCompatible = [string]$plan.policySha256 -ceq $CurrentPolicySha256
            $targetPath = [string]$approvedPlan.target.targetPath
            $quarantinePath = Join-Path `
                (Split-Path -Parent $targetPath) `
                ('.codex-safe-delete-{0}.quarantine' -f ([string]$plan.generationId))
            $targetState = Get-CodexSafeTreeDeleteNamespaceState `
                -Path $targetPath
            $quarantineState = Get-CodexSafeTreeDeleteNamespaceState `
                -Path $quarantinePath
            $targetPresent = [bool]$targetState.present
            $quarantinePresent = [bool]$quarantineState.present
            $targetEntryType = [string]$targetState.entryType
            $quarantineEntryType = [string]$quarantineState.entryType
            if ($targetEntryType -cin @('file', 'reparse-point', 'other') -or
                $quarantineEntryType -cin @('file', 'reparse-point', 'other')) {
                throw 'safe-delete Status target/quarantine namespace entry 不是普通目录。'
            }
            if (-not [IO.File]::Exists($transactionPath)) {
                $schemaCompatible = $true
                $lifecycle = if ($targetEntryType -ceq 'directory' -and
                    $quarantineEntryType -ceq 'absent') { 'planned' } else { 'inconsistent' }
                $safeActions = if ($lifecycle -ceq 'planned') { @('apply') } else { @('manual-review') }
                $journalStatus = 'not-started'
                if ($lifecycle -ceq 'planned') {
                    $plannedTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                        -Path $targetPath `
                        -CapabilityRoot ([string]$approvedPlan.target.capabilityRoot) `
                        -AllowedExactPaths @($targetPath) `
                        -AllowHardLinks:([bool]$approvedPlan.target.allowHardLinks) `
                        -AllowInternalDirectoryJunctions:([bool]$approvedPlan.target.allowInternalDirectoryJunctions) `
                        -InternalDirectoryJunctionTargetRoot $targetPath `
                        -MetricsObserver $treeMetricsObserver `
                        -Name 'safe-delete status planned tree'
                    if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plannedTree) -cne
                        (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
                        throw 'safe-delete Status planned tree manifest 漂移。'
                    }
                } else {
                    $complete = $false
                    $errors.Add('planned operation 的 target/quarantine namespace 不一致。')
                }
            } else {
                $journalStatus = 'invalid'
                $transactionSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                    -Path $transactionPath `
                    -Name 'safe-delete status transaction' `
                    -AllowedExactPaths @($transactionPath)
                $metricsState.bytesHashed = [long]$metricsState.bytesHashed + $transactionSnapshot.bytes.Length
                Assert-CodexHookStrictJsonText -JsonText $transactionSnapshot.text
                $transaction = $transactionSnapshot.text |
                    ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
                $transactionSchemaVersion = [long]$transaction.schemaVersion
                if ($transaction.PSObject.Properties['status'] -and
                    $transaction.status -is [string]) {
                    $transactionStatus = [string]$transaction.status
                }
                if ($transaction.PSObject.Properties['updatedAtUtc'] -and
                    $transaction.updatedAtUtc -is [string]) {
                    $transactionUpdatedAtUtc = [string]$transaction.updatedAtUtc
                }
                if ($transactionSchemaVersion -eq 1L) {
                    $observedTransaction = Read-CodexSafeTreeDeleteObservedV1Transaction `
                        -Document $transaction `
                        -TransactionPath $transactionPath `
                        -PlanPath $planPath `
                        -PlanSha256 ([string]$planSnapshot.sha256) `
                        -Plan $plan `
                        -ExpectedTargetPath $targetPath `
                        -ExpectedQuarantinePath $quarantinePath
                    $targetPath = [string]$observedTransaction.targetPath
                    $quarantinePath = [string]$observedTransaction.quarantinePath
                    $transactionStatus = [string]$observedTransaction.status
                    $transactionUpdatedAtUtc = [string]$observedTransaction.updatedAtUtc
                    $schemaCompatible = $false
                    $journalStatus = 'unavailable'
                    $lifecycle = 'manual-review'
                    $safeActions = @('manual-review')
                    $complete = $false
                    $errors.Add(
                        'transaction v1 仅支持 Status 只读观测；Purge/Restore 不可恢复且继续拒绝。')
                } else {
                if ($transactionSchemaVersion -eq 3L -and
                    @($transaction.restoreJournalAnchors).Count -ne 0) {
                    $expectedIntentPath = Join-Path $runDirectory 'restore-intent.json'
                    $expectedRenamePath = Join-Path $runDirectory 'restore-renamed.json'
                    $expectedVerificationPath = Join-Path $runDirectory 'restore-verified.json'
                    $expectedCompletePath = Join-Path $runDirectory 'restore-complete.json'
                    foreach ($restoreAnchor in @($transaction.restoreJournalAnchors)) {
                        if ([string]$restoreAnchor.intentPath -cne $expectedIntentPath -or
                            [string]$restoreAnchor.renamePath -cne $expectedRenamePath -or
                            [string]$restoreAnchor.verificationPath -cne $expectedVerificationPath -or
                            [string]$restoreAnchor.completePath -cne $expectedCompletePath) {
                            throw 'safe-delete Status Restore journal anchor path 越出 operation run。'
                        }
                    }
                }
                $approvedTransaction = Read-CodexSafeTreeDeleteApprovedTransaction `
                    -TransactionPath $transactionPath `
                    -ApprovedTransactionSha256 ([string]$transactionSnapshot.sha256) `
                    -PolicyPath $PolicyPath `
                    -EvidenceRoot $fullEvidenceRoot `
                    -AllowRestoreState `
                    -MetricsObserver $treeMetricsObserver
                $transaction = $approvedTransaction.document
                $transactionSchemaVersion = [long]$transaction.schemaVersion
                $schemaCompatible = $true
                $transactionStatus = [string]$transaction.status
                $transactionUpdatedAtUtc = [string]$transaction.updatedAtUtc
                $journalStatus = if (@($transaction.directoryCommitAnchors).Count -eq 0) {
                    'none'
                } else {
                    'present'
                }
                if ($transactionStatus -cin @('prepared', 'quarantined', 'restored', 'rolled-back') -and
                    @($transaction.directoryCommitAnchors).Count -ne 0) {
                    $journalStatus = 'invalid'
                    throw "$transactionStatus transaction 不得包含 directory commit journal。"
                }
                if ($transactionStatus -ceq 'purging') {
                    if ($targetEntryType -ceq 'absent' -and $quarantineEntryType -ceq 'directory') {
                        $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot `
                            -Target $approvedTransaction.approvedPlan.target
                        $quarantineTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                            -Path $quarantinePath `
                            -CapabilityRoot $quarantineCapabilityRoot `
                            -AllowedExactPaths @($quarantinePath) `
                            -AllowHardLinks:([bool]$approvedTransaction.approvedPlan.target.allowHardLinks) `
                            -AllowInternalDirectoryJunctions:([bool]$approvedTransaction.approvedPlan.target.allowInternalDirectoryJunctions) `
                            -InternalDirectoryJunctionTargetRoot $targetPath `
                            -MetricsObserver $treeMetricsObserver `
                            -Name 'safe-delete status purge-resumable tree'
                        Assert-CodexSafeTreeDeletePartialPurgeManifest `
                            -CurrentManifest $quarantineTree `
                            -PlannedManifest $plan.treeManifest
                        if (@($transaction.directoryCommitAnchors).Count -ne 0 -or
                            [string]$approvedTransaction.approvedPlan.target.rootDeletionPurpose -ceq
                                'empty-project-state') {
                            [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
                                -RunDirectory $runDirectory `
                                -Transaction $transaction `
                                -Plan $plan `
                                -MetricsObserver $treeMetricsObserver)
                        }
                        $lifecycle = 'purge-resumable'
                        $safeActions = @('purge')
                    } else {
                        $lifecycle = 'inconsistent'
                        $safeActions = @('manual-review')
                        $complete = $false
                        $errors.Add('purging operation 的 target/quarantine namespace 不可恢复。')
                    }
                } elseif ($transactionStatus -ceq 'purged') {
                    if ($quarantineEntryType -cne 'absent') {
                        throw 'purged transaction 的 target/quarantine namespace 仍存在。'
                    }
                    if ($targetEntryType -cne 'absent') {
                        if ([string]$approvedTransaction.approvedPlan.target.rootDeletionPurpose -cne
                                'rebuildable-build-output' -or
                            $targetEntryType -cne 'directory') {
                            throw 'purged transaction 的 target/quarantine namespace 仍存在。'
                        }
                        $rebuiltTargetGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
                            [string]$approvedTransaction.approvedPlan.target.capabilityRoot,
                            $targetPath,
                            $false)
                        try {
                            $rebuiltTargetIdentity = @(
                                [string]$rebuiltTargetGuard.VolumeSerialNumber,
                                [string]$rebuiltTargetGuard.FileIndex)
                            Assert-CodexHookDirectoryTreeIdentity `
                                -Expected $rebuiltTargetIdentity `
                                -Actual $rebuiltTargetIdentity `
                                -Scope 'safe-delete Status rebuilt target'
                            if (Test-CodexHookDirectoryTreeIdentityEqual `
                                    -Expected @($plan.treeManifest.rootIdentity) `
                                    -Actual $rebuiltTargetIdentity) {
                                throw 'purged rebuildable-build-output transaction 的 target identity 未变化，无法证明曾完成删除。'
                            }
                        } finally {
                            $rebuiltTargetGuard.Dispose()
                        }
                    }
                    if (@($transaction.directoryCommitAnchors).Count -ne 0 -or
                        [string]$approvedTransaction.approvedPlan.target.rootDeletionPurpose -ceq
                            'empty-project-state') {
                        [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
                            -RunDirectory $runDirectory `
                            -Transaction $transaction `
                            -Plan $plan `
                            -RequireComplete `
                            -MetricsObserver $treeMetricsObserver)
                        $journalStatus = 'complete'
                    } else {
                        $journalStatus = 'not-applicable'
                    }
                    $lifecycle = 'terminal'
                    $safeActions = @()
                } elseif ($transactionStatus -cin @('restored', 'rolled-back')) {
                    if ($targetEntryType -cne 'directory' -or $quarantineEntryType -cne 'absent') {
                        throw "$transactionStatus transaction 的 live namespace 不一致。"
                    }
                    $terminalTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                        -Path $targetPath `
                        -CapabilityRoot ([string]$approvedTransaction.approvedPlan.target.capabilityRoot) `
                        -AllowedExactPaths @($targetPath) `
                        -AllowHardLinks:([bool]$approvedTransaction.approvedPlan.target.allowHardLinks) `
                        -AllowInternalDirectoryJunctions:([bool]$approvedTransaction.approvedPlan.target.allowInternalDirectoryJunctions) `
                        -InternalDirectoryJunctionTargetRoot $targetPath `
                        -MetricsObserver $treeMetricsObserver `
                        -Name 'safe-delete Status terminal restored tree'
                    if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $terminalTree) -cne
                        (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
                        throw "$transactionStatus transaction 的 target tree 漂移。"
                    }
                    if ($transactionStatus -ceq 'restored') {
                        $intentPath = Join-Path $runDirectory 'restore-intent.json'
                        $renamedPath = Join-Path $runDirectory 'restore-renamed.json'
                        $verifiedPath = Join-Path $runDirectory 'restore-verified.json'
                        $completePath = Join-Path $runDirectory 'restore-complete.json'
                        $intentJournal = Read-CodexSafeTreeDeleteRestoreJournal `
                            -Path $intentPath `
                            -RunDirectory $runDirectory `
                            -Kind intent `
                            -Transaction $transaction `
                            -Plan $plan `
                            -MetricsObserver $treeMetricsObserver
                        $renameJournal = Read-CodexSafeTreeDeleteRestoreJournal `
                            -Path $renamedPath `
                            -RunDirectory $runDirectory `
                            -Kind renamed `
                            -Transaction $transaction `
                            -Plan $plan `
                            -MetricsObserver $treeMetricsObserver
                        $verificationJournal = Read-CodexSafeTreeDeleteRestoreJournal `
                            -Path $verifiedPath `
                            -RunDirectory $runDirectory `
                            -Kind verified `
                            -Transaction $transaction `
                            -Plan $plan `
                            -MetricsObserver $treeMetricsObserver
                        $completeJournal = Read-CodexSafeTreeDeleteRestoreJournal `
                            -Path $completePath `
                            -RunDirectory $runDirectory `
                            -Kind complete `
                            -Transaction $transaction `
                            -Plan $plan `
                            -MetricsObserver $treeMetricsObserver
                        Assert-CodexSafeTreeDeleteRestoreJournalReference `
                            -Document $renameJournal.document -Reference intent -Journal $intentJournal `
                            -Scope 'safe-delete Status restored rename journal'
                        foreach ($reference in @(
                                [pscustomobject]@{ name = 'intent'; journal = $intentJournal },
                                [pscustomobject]@{ name = 'rename'; journal = $renameJournal })) {
                            Assert-CodexSafeTreeDeleteRestoreJournalReference `
                                -Document $verificationJournal.document `
                                -Reference $reference.name `
                                -Journal $reference.journal `
                                -Scope 'safe-delete Status restored verification journal'
                        }
                        foreach ($reference in @(
                                [pscustomobject]@{ name = 'intent'; journal = $intentJournal },
                                [pscustomobject]@{ name = 'rename'; journal = $renameJournal },
                                [pscustomobject]@{ name = 'verification'; journal = $verificationJournal })) {
                            Assert-CodexSafeTreeDeleteRestoreJournalReference `
                                -Document $completeJournal.document `
                                -Reference $reference.name `
                                -Journal $reference.journal `
                                -Scope 'safe-delete Status restored complete journal'
                        }
                        $journalStatus = 'complete'
                    } else {
                        $journalStatus = 'not-applicable'
                    }
                    $lifecycle = 'terminal'
                    $safeActions = @()
                } elseif ($transactionStatus -cin @('prepared', 'quarantined')) {
                    if ($targetEntryType -ceq 'absent' -and $quarantineEntryType -ceq 'directory') {
                        $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot `
                            -Target $approvedTransaction.approvedPlan.target
                        $quarantineTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                            -Path $quarantinePath `
                            -CapabilityRoot $quarantineCapabilityRoot `
                            -AllowedExactPaths @($quarantinePath) `
                            -AllowHardLinks:([bool]$approvedTransaction.approvedPlan.target.allowHardLinks) `
                            -AllowInternalDirectoryJunctions:([bool]$approvedTransaction.approvedPlan.target.allowInternalDirectoryJunctions) `
                            -InternalDirectoryJunctionTargetRoot $targetPath `
                            -MetricsObserver $treeMetricsObserver `
                            -Name 'safe-delete status recoverable tree'
                        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $quarantineTree) -cne
                            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
                            throw 'safe-delete Status recoverable tree manifest 漂移。'
                        }
                        $lifecycle = 'recoverable'
                        $safeActions = @('restore', 'purge')
                    } else {
                        $lifecycle = 'inconsistent'
                        $safeActions = @('manual-review')
                        $complete = $false
                        $errors.Add('prepared/quarantined operation 的 target/quarantine namespace 不一致。')
                    }
                } else {
                    throw 'transaction status 未知。'
                }
                }
            }
            if (-not $policyCompatible -and $null -eq $transactionSchemaVersion) {
                $complete = $false
                $lifecycle = 'manual-review'
                $safeActions = @('manual-review')
                $errors.Add(
                    'plan policy SHA 已漂移；当前严格写路径不可执行该计划。')
            }
        } catch {
            $complete = $false
            $errors.Add($_.Exception.Message)
            $lifecycle = 'manual-review'
            $safeActions = @('manual-review')
        }

        $namespaceAbsent = if ($null -eq $targetPath -or $null -eq $targetPresent) {
            $null
        } else {
            -not [bool]$targetPresent
        }
        $logicalCompletion = $lifecycle -ceq 'terminal' -and $transactionStatus -ceq 'purged'
        if ($candidatePolicyRequested) {
            $candidatePolicyCompatible = $lifecycle -ceq 'terminal'
            if (-not $candidatePolicyCompatible -and
                $schemaCompatible -and $policyCompatible -and
                $transactionSchemaVersion -eq 3L) {
                try {
                    $candidateTarget = Resolve-CodexSafeTreeDeleteTarget `
                        -TargetPath ([string]$plan.targetPath) `
                        -CapabilityRoot ([string]$plan.capabilityRoot) `
                        -Policy $candidatePolicy `
                        -RequireExisting:$false
                    if ([string]$candidateTarget.policyEntryId -cne [string]$plan.policyEntryId) {
                        throw 'candidate policy entry id drifted.'
                    }
                    Assert-CodexSafeTreeDeleteTargetTreePolicy `
                        -Target $candidateTarget `
                        -TreeManifest $plan.treeManifest
                    $candidatePolicyCompatible = $true
                } catch {
                    $candidatePolicyCompatible = $false
                }
            } elseif (-not $candidatePolicyCompatible -and
                $schemaCompatible -and $policyCompatible -and
                [string]$plan.policySha256 -ceq [string]$candidatePolicy.sha256) {
                $candidatePolicyCompatible = $true
            }
        }
        $deletionOutcome = New-CodexSafeTreeDeleteOutcome `
            -NamespaceAbsent $namespaceAbsent `
            -LogicalCompletion $logicalCompletion
        $operation = [pscustomobject][ordered]@{
            operationId = [string]$runItem.Name
            runDirectory = [string]$runItem.FullName
            lifecycle = $lifecycle
            safeActions = @($safeActions)
            targetPath = $targetPath
            quarantinePath = $quarantinePath
            targetPresent = $targetPresent
            quarantinePresent = $quarantinePresent
            targetEntryType = $targetEntryType
            quarantineEntryType = $quarantineEntryType
            namespaceAbsent = $deletionOutcome.namespaceAbsent
            logicalCompletion = $deletionOutcome.logicalCompletion
            physicalReclaimStatus = $deletionOutcome.physicalReclaimStatus
            physicalReclaimReason = $deletionOutcome.physicalReclaimReason
            deletionOutcome = $deletionOutcome
            policyCompatible = $policyCompatible
            schemaCompatible = $schemaCompatible
            candidatePolicyCompatible = $candidatePolicyCompatible
            planSchemaVersion = $planSchemaVersion
            transactionSchemaVersion = $transactionSchemaVersion
            transactionStatus = $transactionStatus
            transactionUpdatedAtUtc = $transactionUpdatedAtUtc
            journalStatus = $journalStatus
            errors = @($errors)
        }
        return [pscustomobject][ordered]@{
            complete = $complete
            operation = $operation
        }
    }

function Get-CodexSafeTreeDeleteStatus {
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [string]$CandidatePolicyPath,
        [string]$ApprovedCandidatePolicySha256
    )

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    $fullEvidenceRoot = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'safe-delete status evidence root'
    if (-not [IO.Directory]::Exists($fullEvidenceRoot)) {
        throw 'safe-delete status evidence root 不存在。'
    }
    $evidenceParent = Split-Path -Parent $fullEvidenceRoot
    [void](Assert-CodexHookCapabilityPath `
        -Path $fullEvidenceRoot `
        -CapabilityRoot $evidenceParent `
        -AllowedExactPaths @($fullEvidenceRoot) `
        -Name 'safe-delete status evidence root')
    $treeMetricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
    $policy = Read-CodexSafeTreeDeletePolicy `
        -PolicyPath $PolicyPath `
        -MetricsObserver $treeMetricsObserver
    $candidatePolicy = $null
    $candidatePolicyRequested =
        -not [string]::IsNullOrWhiteSpace($CandidatePolicyPath) -or
        -not [string]::IsNullOrWhiteSpace($ApprovedCandidatePolicySha256)
    if ($candidatePolicyRequested) {
        if ([string]::IsNullOrWhiteSpace($CandidatePolicyPath) -or
            [string]::IsNullOrWhiteSpace($ApprovedCandidatePolicySha256)) {
            throw 'safe-delete candidate policy preflight 要求 path 与 approved SHA-256。'
        }
        if ($ApprovedCandidatePolicySha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'safe-delete candidate policy approved SHA-256 格式非法。'
        }
        $candidatePolicy = Read-CodexSafeTreeDeletePolicy `
            -PolicyPath $CandidatePolicyPath `
            -MetricsObserver $treeMetricsObserver
        if ([string]$candidatePolicy.sha256 -cne $ApprovedCandidatePolicySha256) {
            throw 'safe-delete candidate policy approved SHA-256 不匹配。'
        }
        if ([long]$candidatePolicy.schemaVersion -ne 5L) {
            throw 'safe-delete candidate policy activation preflight 只接受 schema v5。'
        }
    }
    $operations = [Collections.Generic.List[object]]::new()
    $complete = $true

    foreach ($runItem in @(Get-ChildItem -LiteralPath $fullEvidenceRoot -Force -ErrorAction Stop |
            Sort-Object -Property Name -CaseSensitive)) {
        $metricsState.entriesScanned = [long]$metricsState.entriesScanned + 1L
        $operationStatus = Resolve-CodexSafeTreeDeleteStatusOperation `
            -RunItem $runItem `
            -PolicyPath $PolicyPath `
            -CurrentPolicySha256 ([string]$policy.sha256) `
            -FullEvidenceRoot $fullEvidenceRoot `
            -CandidatePolicyRequested $candidatePolicyRequested `
            -CandidatePolicy $candidatePolicy `
            -MetricsState $metricsState `
            -TreeMetricsObserver $treeMetricsObserver
        $operations.Add($operationStatus.operation)
        if (-not [bool]$operationStatus.complete) {
            $complete = $false
        }
    }

    $blockingRecords = @(if ($candidatePolicyRequested) {
        $operations | Where-Object {
            $_.lifecycle -cne 'terminal' -and -not [bool]$_.candidatePolicyCompatible
        } | ForEach-Object { [string]$_.operationId }
    } else {
        $operations | Where-Object {
            $_.lifecycle -cne 'terminal' -and
            (-not [bool]$_.schemaCompatible -or
                -not [bool]$_.policyCompatible -or
                @($_.errors).Count -ne 0)
        } | ForEach-Object { [string]$_.operationId }
    })
    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-status'
        schemaVersion = 1
        capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        complete = $complete
        policyPath = [string]$policy.path
        policySha256 = [string]$policy.sha256
        policySchemaVersion = [long]$policy.schemaVersion
        migrationReadiness = [pscustomobject][ordered]@{
            evaluated = $candidatePolicyRequested
            candidatePolicyPath = if ($null -eq $candidatePolicy) { $null } else { [string]$candidatePolicy.path }
            candidatePolicySha256 = if ($null -eq $candidatePolicy) { $null } else { [string]$candidatePolicy.sha256 }
            candidatePolicySchemaVersion = if ($null -eq $candidatePolicy) { $null } else { [long]$candidatePolicy.schemaVersion }
            ready = if ($candidatePolicyRequested) {
                $blockingRecords.Count -eq 0
            } else {
                $complete -and $blockingRecords.Count -eq 0
            }
            blockingRecords = @($blockingRecords)
        }
        operations = @($operations)
        metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
    }
}

function Get-CodexSafeTreeDeleteManifestSha256 {
    param([Parameter(Mandatory)][object]$Manifest)
    $canonical = $Manifest | ConvertTo-Json -Depth 100 -Compress
    return Get-CodexHookTextSha256 -Text $canonical
}

function Assert-CodexSafeTreeDeletePartialPurgeManifest {
    param(
        [Parameter(Mandatory)][object]$CurrentManifest,
        [Parameter(Mandatory)][object]$PlannedManifest
    )

    $current = ConvertTo-CodexHookExpectedDirectoryTreeManifest `
        -Manifest $CurrentManifest `
        -Scope 'safe-delete purge resume current'
    $planned = ConvertTo-CodexHookExpectedDirectoryTreeManifest `
        -Manifest $PlannedManifest `
        -Scope 'safe-delete purge resume planned'
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($planned.rootIdentity) `
        -Actual @($current.rootIdentity) `
        -Scope 'safe-delete purge resume root'

    foreach ($entry in @($CurrentManifest.entries)) {
        $relativePath = [string]$entry.relativePath
        $currentEntry = $current.entriesByPath[$relativePath]
        $plannedEntry = $planned.entriesByPath[$relativePath]
        if ($null -eq $plannedEntry -or
            [string]$plannedEntry.relativePath -cne [string]$currentEntry.relativePath -or
            [string]$plannedEntry.kind -cne [string]$currentEntry.kind -or
            [string]$plannedEntry.sha256 -cne [string]$currentEntry.sha256) {
            throw 'safe-delete purge resume tree manifest 漂移。'
        }
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @($plannedEntry.identity) `
            -Actual @($currentEntry.identity) `
            -Scope "safe-delete purge resume $relativePath"
    }
}

function Read-CodexSafeTreeDeleteApprovedPlan {
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$ApprovedPlanSha256,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$AllowMissingTarget,
        [switch]$AllowExpiredPlan,
        [switch]$AllowPolicyShaDrift,
        [scriptblock]$MetricsObserver
    )

    if ($ApprovedPlanSha256 -notmatch '^[0-9a-f]{64}$') { throw 'ApprovedPlanSha256 格式非法。' }
    $fullEvidenceRoot = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'safe-delete evidence root'
    $fullPlanPath = Assert-CodexHookDPath -Value $PlanPath -Name 'safe-delete plan path'
    if ([IO.Path]::GetFileName($fullPlanPath) -cne 'plan.json' -or
        -not (Test-CodexHookPathWithin -Path $fullPlanPath -ParentPath $fullEvidenceRoot) -or
        (Test-CodexSafeTreeDeletePathEqual -Left $fullPlanPath -Right $fullEvidenceRoot)) {
        throw 'safe-delete plan path 不在受管 evidence run 下。'
    }
    $runDirectory = Split-Path -Parent $fullPlanPath
    [void](Assert-CodexHookCapabilityPath `
        -Path $fullPlanPath `
        -CapabilityRoot $fullEvidenceRoot `
        -AllowedExactPaths @($fullPlanPath) `
        -Name 'safe-delete approved plan')
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $fullPlanPath `
        -Name 'safe-delete approved plan' `
        -AllowedExactPaths @($fullPlanPath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$snapshot.bytes.Length)
    }
    if ($snapshot.sha256 -cne $ApprovedPlanSha256) { throw 'safe-delete approved plan SHA-256 不匹配。' }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $plan = $snapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeletePlanDocumentProperties `
        -Plan $plan `
        -Scope 'safe-delete plan'
    if ($plan.artifactType -cne 'env-governance.codex-safe-tree-delete-plan' -or [int]$plan.schemaVersion -ne 1) {
        throw 'safe-delete plan artifact/schema 非法。'
    }
    $generationId = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$plan.generationId, 'D', [ref]$generationId)) {
        throw 'safe-delete plan generationId 非法。'
    }
    Assert-CodexSafeTreeDeletePlanExpiration `
        -Plan $plan `
        -Scope 'safe-delete plan' `
        -AllowExpiredPlan:$AllowExpiredPlan

    $policy = Read-CodexSafeTreeDeletePolicy `
        -PolicyPath $PolicyPath `
        -MetricsObserver $MetricsObserver
    if ($plan.policyPath -cne $policy.path -or
        (-not $AllowPolicyShaDrift -and $plan.policySha256 -cne $policy.sha256)) {
        throw 'safe-delete policy 自计划生成后已漂移。'
    }
    $target = Resolve-CodexSafeTreeDeleteTarget `
        -TargetPath ([string]$plan.targetPath) `
        -CapabilityRoot ([string]$plan.capabilityRoot) `
        -Policy $policy `
        -RequireExisting:(-not $AllowMissingTarget)
    if ($target.policyEntryId -cne [string]$plan.policyEntryId) {
        throw 'safe-delete plan policy entry 漂移。'
    }
    [void](ConvertTo-CodexHookExpectedDirectoryTreeManifest `
        -Manifest $plan.treeManifest `
        -Scope 'safe-delete approved plan')
    Assert-CodexSafeTreeDeleteTargetTreePolicy -Target $target -TreeManifest $plan.treeManifest

    return [pscustomobject][ordered]@{
        path = $fullPlanPath
        sha256 = [string]$snapshot.sha256
        runDirectory = $runDirectory
        document = $plan
        target = $target
    }
}

function Invoke-CodexSafeTreeDeleteQuarantine {
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$ApprovedPlanSha256,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$FailAfterRenameForTest,
        [scriptblock]$BeforeQuarantineMutexForTest,
        [scriptblock]$QuarantineCheckpointForTest
    )

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'apply'
    $primaryMetricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
    $repeatMetricsObserver = New-CodexSafeTreeDeleteMetricsObserver `
        -State $metricsState `
        -IncludeLogicalBytes:$false
    $approved = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath $PlanPath `
        -ApprovedPlanSha256 $ApprovedPlanSha256 `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot `
        -MetricsObserver $repeatMetricsObserver
    $plan = $approved.document
    $target = $approved.target
    $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $target
    $currentTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $target.targetPath `
        -CapabilityRoot $target.capabilityRoot `
        -AllowedExactPaths @($target.targetPath) `
        -AllowHardLinks:([bool]$target.allowHardLinks) `
        -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
        -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
        -MetricsObserver $primaryMetricsObserver `
        -Name 'safe-delete apply preflight'
    Assert-CodexSafeTreeDeleteTargetTreePolicy `
        -Target $target `
        -TreeManifest $currentTree `
        -TreePath $target.targetPath
    if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $currentTree) -cne
        (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
        throw 'safe-delete apply preflight tree manifest 漂移。'
    }

    $quarantinePath = Join-Path `
        (Split-Path -Parent $target.targetPath) `
        ('.codex-safe-delete-{0}.quarantine' -f ([string]$plan.generationId))
    [void](Assert-CodexHookCapabilityPath `
        -Path $quarantinePath `
        -CapabilityRoot $quarantineCapabilityRoot `
        -AllowedExactPaths @($quarantinePath) `
        -Name 'safe-delete quarantine target')
    if ([IO.Directory]::Exists($quarantinePath) -or [IO.File]::Exists($quarantinePath)) {
        throw 'safe-delete quarantine target 已存在。'
    }

    $transactionPath = Join-Path $approved.runDirectory 'transaction.json'
    $transactionProperties = [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-transaction'
        schemaVersion = if ([long]$target.policySchemaVersion -eq 5L) { 3 } else { 2 }
        generationId = [string]$plan.generationId
        planPath = $approved.path
        planSha256 = $approved.sha256
        targetPath = $target.targetPath
        quarantinePath = $quarantinePath
        directoryCommitAnchors = @()
        status = 'prepared'
        updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ([long]$target.policySchemaVersion -eq 5L) {
        $transactionProperties.quarantineTimeAnchor = $null
        $transactionProperties.restoreJournalAnchors = @()
    }
    $transaction = [pscustomobject]$transactionProperties
    if ($null -ne $BeforeQuarantineMutexForTest) {
        & $BeforeQuarantineMutexForTest $target.targetPath $quarantinePath
    }

    $mutexHash = Get-CodexHookTextSha256 -Text $target.targetPath.ToUpperInvariant()
    $mutex = [Threading.Mutex]::new($false, "Local\CodexSafeTreeDelete-$mutexHash")
    $held = $false
    $renamed = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'safe-delete target mutex busy。' }
        if ([IO.Directory]::Exists($quarantinePath) -or [IO.File]::Exists($quarantinePath)) {
            throw 'safe-delete quarantine target 已存在。'
        }
        $lockedTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $target.targetPath `
            -CapabilityRoot $target.capabilityRoot `
            -AllowedExactPaths @($target.targetPath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $repeatMetricsObserver `
            -Name 'safe-delete apply locked preflight'
        Assert-CodexSafeTreeDeleteTargetTreePolicy `
            -Target $target `
            -TreeManifest $lockedTree `
            -TreePath $target.targetPath
        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $lockedTree) -cne
            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
            throw 'safe-delete apply locked preflight tree manifest 漂移。'
        }
        $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete(
            [string]$target.capabilityRoot,
            [string]$target.targetPath)
        try {
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($plan.treeManifest.rootIdentity) `
                -Actual @($guard.VolumeSerialNumber, $guard.FileIndex) `
                -Scope 'safe-delete quarantine root'
            Set-CodexHookCapabilityJson `
                -Path $transactionPath `
                -Document $transaction `
                -CapabilityRoot $approved.runDirectory `
                -AllowedExactPaths @($transactionPath) `
                -Scope 'safe-delete transaction prepare'
            [void]$guard.RenameToSibling($quarantinePath)
            $renamed = $true
            if ($null -ne $QuarantineCheckpointForTest) {
                & $QuarantineCheckpointForTest `
                    $target.targetPath `
                    $quarantinePath `
                    'after-quarantine-rename-before-status'
            }
            if ($FailAfterRenameForTest) { throw 'safe-delete fixture failure after rename' }
        } finally {
            $guard.Dispose()
        }

        if ([IO.Directory]::Exists($target.targetPath)) {
            throw 'safe-delete quarantine 后原目标仍存在。'
        }
        $quarantinedTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $quarantinePath `
            -CapabilityRoot $quarantineCapabilityRoot `
            -AllowedExactPaths @($quarantinePath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $repeatMetricsObserver `
            -Name 'safe-delete quarantine postcheck'
        Assert-CodexSafeTreeDeleteTargetTreePolicy `
            -Target $target `
            -TreeManifest $quarantinedTree `
            -TreePath $quarantinePath
        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $quarantinedTree) -cne
            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
            throw 'safe-delete quarantine postcheck tree manifest 漂移。'
        }

        if ([long]$transaction.schemaVersion -eq 3L) {
            $transaction.quarantineTimeAnchor = New-CodexSafeTreeDeleteQuarantineTimeAnchor `
                -Transaction $transaction `
                -Plan $plan `
                -RunDirectory $approved.runDirectory
        }
        $transaction.status = 'quarantined'
        $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Set-CodexHookCapabilityJson `
            -Path $transactionPath `
            -Document $transaction `
            -CapabilityRoot $approved.runDirectory `
            -AllowedExactPaths @($transactionPath) `
            -Scope 'safe-delete transaction quarantined'
        $transactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
            -Path $transactionPath `
            -CapabilityRoot $approved.runDirectory `
            -AllowedExactPaths @($transactionPath) `
            -Name 'safe-delete transaction published'
        & $repeatMetricsObserver 'hash-read' 0L ([long]$transactionSnapshot.bytes.Length)
        return [pscustomobject][ordered]@{
            quarantined = $true
            targetPath = $target.targetPath
            quarantinePath = $quarantinePath
            transactionPath = $transactionPath
            transactionSha256 = $transactionSnapshot.sha256
            recoverable = $true
            metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
        }
    } catch {
        $failure = $_
        if ($renamed -and [IO.Directory]::Exists($quarantinePath) -and -not [IO.Directory]::Exists($target.targetPath)) {
            try {
                $rollbackGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete(
                    [string]$quarantineCapabilityRoot,
                    [string]$quarantinePath)
                try {
                    Assert-CodexHookDirectoryTreeIdentity `
                        -Expected @($plan.treeManifest.rootIdentity) `
                        -Actual @($rollbackGuard.VolumeSerialNumber, $rollbackGuard.FileIndex) `
                        -Scope 'safe-delete quarantine rollback root'
                    [void]$rollbackGuard.RenameToSibling([string]$target.targetPath)
                } finally {
                    $rollbackGuard.Dispose()
                }
                $transaction.status = 'rolled-back'
                $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                Set-CodexHookCapabilityJson `
                    -Path $transactionPath `
                    -Document $transaction `
                    -CapabilityRoot $approved.runDirectory `
                    -AllowedExactPaths @($transactionPath) `
                    -Scope 'safe-delete transaction rolled back'
            } catch {
                throw "safe-delete quarantine 失败且 rollback 未完成：$($failure.Exception.Message)；rollback：$($_.Exception.Message)"
            }
        }
        throw $failure
    } finally {
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument {
    param(
        [Parameter(Mandatory)][object]$Document,
        [switch]$AllowArchiveRestoreAnchorRefusal
    )

    if ($Document.schemaVersion -isnot [long] -or
        [long]$Document.schemaVersion -notin @(2L, 3L)) {
        throw 'safe-delete transaction schemaVersion 必须是 JSON integer 2 或 3。'
    }
    $transactionSchemaVersion = [long]$Document.schemaVersion
    $transactionNames = @(
        'artifactType', 'schemaVersion', 'generationId', 'planPath', 'planSha256',
        'targetPath', 'quarantinePath', 'directoryCommitAnchors', 'status', 'updatedAtUtc'
    )
    if ($transactionSchemaVersion -eq 3L) {
        $transactionNames += @('quarantineTimeAnchor', 'restoreJournalAnchors')
    }
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $Document `
        -Names $transactionNames `
        -Scope 'safe-delete transaction'
    foreach ($stringProperty in @(
            'artifactType', 'generationId', 'planPath', 'planSha256',
            'targetPath', 'quarantinePath', 'status', 'updatedAtUtc')) {
        if ($Document.$stringProperty -isnot [string]) {
            throw "safe-delete transaction $stringProperty 必须是 JSON string。"
        }
    }
    $updatedAtUtc = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParseExact(
            [string]$Document.updatedAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$updatedAtUtc)) {
        throw 'safe-delete transaction updatedAtUtc 非法。'
    }
    if ($Document.artifactType -cne 'env-governance.codex-safe-tree-delete-transaction' -or
        [string]$Document.status -cnotin @(
            'prepared', 'quarantined', 'purging', 'purged', 'restored', 'rolled-back')) {
        throw 'safe-delete transaction 状态或 schema 非法。'
    }
    if ($Document.directoryCommitAnchors -isnot [Array]) {
        throw 'safe-delete transaction directoryCommitAnchors 必须是 JSON array。'
    }
    if ([string]$Document.status -ceq 'prepared' -and
        @($Document.directoryCommitAnchors).Count -ne 0) {
        throw 'safe-delete prepared transaction 不得包含 directory commit anchor。'
    }
    if ($transactionSchemaVersion -eq 3L) {
        if ($Document.restoreJournalAnchors -isnot [Array]) {
            throw 'safe-delete transaction v3 restoreJournalAnchors 必须是 JSON array。'
        }
        if ([string]$Document.status -cin @('quarantined', 'purging', 'purged', 'restored') -and
            $null -eq $Document.quarantineTimeAnchor) {
            throw 'safe-delete transaction v3 非 prepared 状态缺少 quarantine-time anchor。'
        }
        if ([string]$Document.status -ceq 'restored' -and
            @($Document.restoreJournalAnchors).Count -ne 1) {
            throw 'safe-delete restored transaction v3 必须绑定一个 Restore journal anchor。'
        }
        if (-not $AllowArchiveRestoreAnchorRefusal -and
            @($Document.restoreJournalAnchors).Count -ne 0 -and
            [string]$Document.status -cnotin @('restored')) {
            throw 'safe-delete transaction v3 Restore anchors 与状态不一致。'
        }
    }
    return $Document
}

function Assert-CodexSafeTreeDeleteStrictTransactionEvidence {
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$QuarantinePath,
        [Parameter(Mandatory)][string]$RunDirectory,
        [scriptblock]$MetricsObserver
    )

    if ([string]$Transaction.generationId -cne [string]$Plan.generationId -or
        [string]$Transaction.planPath -cne $PlanPath -or
        [string]$Transaction.planSha256 -cne $PlanSha256 -or
        [string]$Transaction.targetPath -cne $TargetPath) {
        throw 'safe-delete transaction 与 plan 绑定不一致。'
    }
    if ([string]$Transaction.quarantinePath -cne $QuarantinePath) {
        throw 'safe-delete transaction quarantine path 非法。'
    }

    $transactionSchemaVersion = [long]$Transaction.schemaVersion
    if ($transactionSchemaVersion -eq 3L -and $null -ne $Transaction.quarantineTimeAnchor) {
        [void](Read-CodexSafeTreeDeleteQuarantineTimeAnchor `
            -Anchor $Transaction.quarantineTimeAnchor `
            -Transaction $Transaction `
            -Plan $Plan `
            -RunDirectory $RunDirectory `
            -MetricsObserver $MetricsObserver)
    }
    if ($transactionSchemaVersion -ne 3L -or
        @($Transaction.restoreJournalAnchors).Count -eq 0) {
        return
    }
    if (@($Transaction.restoreJournalAnchors).Count -ne 1) {
        throw 'safe-delete transaction v3 Restore journal anchor 数量非法。'
    }
    $restoreAnchor = @($Transaction.restoreJournalAnchors)[0]
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $restoreAnchor `
        -Names @(
            'intentPath', 'intentSha256', 'intentIdentity',
            'renamePath', 'renameSha256', 'renameIdentity',
            'verificationPath', 'verificationSha256', 'verificationIdentity',
            'completePath', 'completeSha256', 'completeIdentity') `
        -Scope 'safe-delete transaction v3 Restore journal anchor'
    $intentJournal = Read-CodexSafeTreeDeleteRestoreJournal `
        -Path ([string]$restoreAnchor.intentPath) `
        -RunDirectory $RunDirectory `
        -Kind intent `
        -Transaction $Transaction `
        -Plan $Plan `
        -MetricsObserver $MetricsObserver
    $completeJournal = Read-CodexSafeTreeDeleteRestoreJournal `
        -Path ([string]$restoreAnchor.completePath) `
        -RunDirectory $RunDirectory `
        -Kind complete `
        -Transaction $Transaction `
        -Plan $Plan `
        -MetricsObserver $MetricsObserver
    $renameJournal = Read-CodexSafeTreeDeleteRestoreJournal `
        -Path ([string]$restoreAnchor.renamePath) `
        -RunDirectory $RunDirectory `
        -Kind renamed `
        -Transaction $Transaction `
        -Plan $Plan `
        -MetricsObserver $MetricsObserver
    $verificationJournal = Read-CodexSafeTreeDeleteRestoreJournal `
        -Path ([string]$restoreAnchor.verificationPath) `
        -RunDirectory $RunDirectory `
        -Kind verified `
        -Transaction $Transaction `
        -Plan $Plan `
        -MetricsObserver $MetricsObserver
    if ([string]$restoreAnchor.intentSha256 -cne [string]$intentJournal.sha256 -or
        [string]$restoreAnchor.renameSha256 -cne [string]$renameJournal.sha256 -or
        [string]$restoreAnchor.verificationSha256 -cne [string]$verificationJournal.sha256 -or
        [string]$restoreAnchor.completeSha256 -cne [string]$completeJournal.sha256) {
        throw 'safe-delete transaction v3 Restore journal anchor SHA-256 漂移。'
    }
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($restoreAnchor.intentIdentity) `
        -Actual @($intentJournal.identity) `
        -Scope 'safe-delete transaction v3 Restore intent anchor'
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($restoreAnchor.renameIdentity) `
        -Actual @($renameJournal.identity) `
        -Scope 'safe-delete transaction v3 Restore rename anchor'
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($restoreAnchor.verificationIdentity) `
        -Actual @($verificationJournal.identity) `
        -Scope 'safe-delete transaction v3 Restore verification anchor'
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($restoreAnchor.completeIdentity) `
        -Actual @($completeJournal.identity) `
        -Scope 'safe-delete transaction v3 Restore complete anchor'
    Assert-CodexSafeTreeDeleteRestoreJournalReference `
        -Document $renameJournal.document -Reference intent -Journal $intentJournal `
        -Scope 'safe-delete transaction v3 Restore rename anchor'
    foreach ($reference in @(
            [pscustomobject]@{ name = 'intent'; journal = $intentJournal },
            [pscustomobject]@{ name = 'rename'; journal = $renameJournal })) {
        Assert-CodexSafeTreeDeleteRestoreJournalReference `
            -Document $verificationJournal.document `
            -Reference $reference.name `
            -Journal $reference.journal `
            -Scope 'safe-delete transaction v3 Restore verification anchor'
    }
    foreach ($reference in @(
            [pscustomobject]@{ name = 'intent'; journal = $intentJournal },
            [pscustomobject]@{ name = 'rename'; journal = $renameJournal },
            [pscustomobject]@{ name = 'verification'; journal = $verificationJournal })) {
        Assert-CodexSafeTreeDeleteRestoreJournalReference `
            -Document $completeJournal.document `
            -Reference $reference.name `
            -Journal $reference.journal `
            -Scope 'safe-delete transaction v3 Restore complete anchor'
    }
}

function Assert-CodexSafeTreeDeleteTerminalDirectoryEvidence {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$Plan,
        [scriptblock]$MetricsObserver
    )

    if ([string]$Transaction.status -cne 'purged') { return }
    if (@($Transaction.directoryCommitAnchors).Count -ne 0) {
        [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
            -RunDirectory $RunDirectory `
            -Transaction $Transaction `
            -Plan $Plan `
            -RequireComplete `
            -MetricsObserver $MetricsObserver)
        return
    }
    $unanchoredJournals = @(Get-ChildItem -LiteralPath $RunDirectory -File -Force -ErrorAction Stop |
        Where-Object Name -Match '^directory-delete-.+-(freeze|commit)\.json$')
    if ($unanchoredJournals.Count -ne 0) {
        throw 'safe-delete purged transaction 存在未锚定的 directory journal。'
    }
}

function Read-CodexSafeTreeDeleteApprovedTransaction {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$AllowRestoreState,
        [scriptblock]$MetricsObserver
    )

    if ($ApprovedTransactionSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'ApprovedTransactionSha256 格式非法。'
    }
    $fullEvidenceRoot = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'safe-delete evidence root'
    $fullTransactionPath = Assert-CodexHookDPath -Value $TransactionPath -Name 'safe-delete transaction path'
    if ([IO.Path]::GetFileName($fullTransactionPath) -cne 'transaction.json' -or
        -not (Test-CodexHookPathWithin -Path $fullTransactionPath -ParentPath $fullEvidenceRoot) -or
        (Test-CodexSafeTreeDeletePathEqual -Left $fullTransactionPath -Right $fullEvidenceRoot)) {
        throw 'safe-delete transaction path 不在受管 evidence run 下。'
    }
    [void](Assert-CodexHookCapabilityPath `
        -Path $fullTransactionPath `
        -CapabilityRoot $fullEvidenceRoot `
        -AllowedExactPaths @($fullTransactionPath) `
        -Name 'safe-delete approved transaction')
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $fullTransactionPath `
        -Name 'safe-delete approved transaction' `
        -AllowedExactPaths @($fullTransactionPath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$snapshot.bytes.Length)
    }
    if ($snapshot.sha256 -cne $ApprovedTransactionSha256) {
        throw 'safe-delete approved transaction SHA-256 不匹配。'
    }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $transaction = $snapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $transaction = ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument `
        -Document $transaction
    $transactionSchemaVersion = [long]$transaction.schemaVersion
    if (-not $AllowRestoreState -and
        [string]$transaction.status -cnotin @('prepared', 'quarantined', 'purging')) {
        throw 'safe-delete transaction 不是可 Purge 状态。'
    }

    $approvedPlan = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath ([string]$transaction.planPath) `
        -ApprovedPlanSha256 ([string]$transaction.planSha256) `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot `
        -AllowMissingTarget `
        -AllowExpiredPlan `
        -AllowPolicyShaDrift:($transactionSchemaVersion -eq 3L) `
        -MetricsObserver $MetricsObserver
    $plan = $approvedPlan.document
    if ($transactionSchemaVersion -eq 3L -and
        [long]$approvedPlan.target.policySchemaVersion -ne 5L) {
        throw 'safe-delete transaction v3 policy rollback requires manual-review.'
    }
    $expectedQuarantinePath = Join-Path `
        (Split-Path -Parent $approvedPlan.target.targetPath) `
        ('.codex-safe-delete-{0}.quarantine' -f ([string]$plan.generationId))
    Assert-CodexSafeTreeDeleteStrictTransactionEvidence `
        -Transaction $transaction `
        -Plan $plan `
        -PlanPath ([string]$approvedPlan.path) `
        -PlanSha256 ([string]$approvedPlan.sha256) `
        -TargetPath ([string]$approvedPlan.target.targetPath) `
        -QuarantinePath $expectedQuarantinePath `
        -RunDirectory ([string]$approvedPlan.runDirectory) `
        -MetricsObserver $MetricsObserver
    if (-not $AllowRestoreState -and
        ([IO.Directory]::Exists($approvedPlan.target.targetPath) -or
            [IO.File]::Exists($approvedPlan.target.targetPath))) {
        throw 'safe-delete purge 前原目标已重新出现。'
    }
    if (-not $AllowRestoreState -and [string]$transaction.status -ceq 'prepared' -and
        (-not [IO.Directory]::Exists([string]$transaction.quarantinePath) -or
            [IO.File]::Exists([string]$transaction.quarantinePath))) {
        throw 'safe-delete prepared transaction 不满足 quarantine crash recovery 条件。'
    }

    return [pscustomobject][ordered]@{
        path = $fullTransactionPath
        sha256 = [string]$snapshot.sha256
        document = $transaction
        approvedPlan = $approvedPlan
    }
}

function Read-CodexSafeTreeDeleteRestoreJournal {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][ValidateSet('intent', 'renamed', 'verified', 'complete')][string]$Kind,
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$Plan,
        [scriptblock]$MetricsObserver
    )

    $fullRunDirectory = Assert-CodexHookDPath `
        -Value $RunDirectory `
        -Name 'safe-delete restore operation run directory'
    $fullPath = Assert-CodexHookDPath `
        -Value $Path `
        -Name "safe-delete restore $Kind journal path"
    $expectedPath = Join-Path $fullRunDirectory "restore-$Kind.json"
    if ($fullPath -cne $expectedPath -or
        -not (Test-CodexHookPathWithin -Path $fullPath -ParentPath $fullRunDirectory)) {
        throw "safe-delete restore $Kind journal path 越出 operation run 或命名非法。"
    }
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $fullPath `
        -Name "safe-delete restore $Kind journal" `
        -AllowedExactPaths @($fullPath)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$snapshot.bytes.Length)
    }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $document = $snapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $names = @(
        'artifactType', 'schemaVersion', 'generationId', 'transactionPath',
        'sourcePath', 'destinationPath', 'state', 'createdAtUtc'
    )
    if ($Kind -cin @('renamed', 'verified', 'complete')) {
        $names += @('intentPath', 'intentSha256', 'intentIdentity')
    }
    if ($Kind -cin @('verified', 'complete')) {
        $names += @('renamePath', 'renameSha256', 'renameIdentity')
    }
    if ($Kind -cin @('renamed', 'verified', 'complete')) {
        $names += @('targetRootIdentity')
    }
    if ($Kind -cin @('verified', 'complete')) {
        $names += @('targetTreeManifestSha256')
    }
    if ($Kind -ceq 'complete') {
        $names += @('verificationPath', 'verificationSha256', 'verificationIdentity')
    }
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $document `
        -Names $names `
        -Scope "safe-delete restore $Kind journal"
    if ($document.artifactType -cne "env-governance.codex-safe-tree-delete-restore-$Kind" -or
        $document.schemaVersion -isnot [long] -or [long]$document.schemaVersion -ne 1L -or
        [string]$document.generationId -cne [string]$Plan.generationId -or
        [string]$document.transactionPath -cne (Join-Path $fullRunDirectory 'transaction.json') -or
        [string]$document.sourcePath -cne [string]$Transaction.quarantinePath -or
        [string]$document.destinationPath -cne [string]$Transaction.targetPath -or
        [string]$document.state -cne $Kind) {
        throw "safe-delete restore $Kind journal 绑定非法。"
    }
    $createdAtUtc = [datetimeoffset]::MinValue
    if ($document.createdAtUtc -isnot [string] -or
        -not [datetimeoffset]::TryParseExact(
            [string]$document.createdAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$createdAtUtc)) {
        throw "safe-delete restore $Kind journal createdAtUtc 非法。"
    }
    if ($Kind -cin @('renamed', 'verified', 'complete')) {
        if ([string]$document.intentPath -cne (Join-Path $fullRunDirectory 'restore-intent.json') -or
            [string]$document.intentSha256 -notmatch '^[0-9a-f]{64}$') {
            throw "safe-delete restore $Kind journal intent 引用非法。"
        }
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @($document.intentIdentity) `
            -Actual @($document.intentIdentity) `
            -Scope "safe-delete restore $Kind intent journal identity"
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @($Plan.treeManifest.rootIdentity) `
            -Actual @($document.targetRootIdentity) `
            -Scope "safe-delete restore $Kind target root identity"
    }
    if ($Kind -cin @('verified', 'complete')) {
        if ([string]$document.renamePath -cne (Join-Path $fullRunDirectory 'restore-renamed.json') -or
            [string]$document.renameSha256 -notmatch '^[0-9a-f]{64}$' -or
            [string]$document.targetTreeManifestSha256 -cne
                (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $Plan.treeManifest)) {
            throw "safe-delete restore $Kind journal rename 或 tree manifest 引用非法。"
        }
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @($document.renameIdentity) `
            -Actual @($document.renameIdentity) `
            -Scope "safe-delete restore $Kind rename journal identity"
    }
    if ($Kind -ceq 'complete') {
        if ([string]$document.verificationPath -cne (Join-Path $fullRunDirectory 'restore-verified.json') -or
            [string]$document.verificationSha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'safe-delete restore complete journal verification 引用非法。'
        }
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @($document.verificationIdentity) `
            -Actual @($document.verificationIdentity) `
            -Scope 'safe-delete restore complete verification journal identity'
    }
    return [pscustomobject][ordered]@{
        path = $fullPath
        sha256 = [string]$snapshot.sha256
        identity = @($snapshot.probe.identity)
        document = $document
    }
}

function Assert-CodexSafeTreeDeleteRestoreJournalReference {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][ValidateSet('intent', 'rename', 'verification')][string]$Reference,
        [Parameter(Mandatory)][object]$Journal,
        [Parameter(Mandatory)][string]$Scope
    )

    $pathName = "${Reference}Path"
    $shaName = "${Reference}Sha256"
    $identityName = "${Reference}Identity"
    if ([string]$Document.$pathName -cne [string]$Journal.path -or
        [string]$Document.$shaName -cne [string]$Journal.sha256 -or
        -not (Test-CodexHookDirectoryTreeIdentityEqual `
            -Expected @($Document.$identityName) `
            -Actual @($Journal.identity))) {
        throw "$Scope 未精确绑定 $Reference journal path、SHA-256 与 file identity。"
    }
}

function Invoke-CodexSafeTreeDeleteRestore {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [scriptblock]$RestoreCheckpointForTest
    )

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'restore'
    $metricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
    $repeatMetricsObserver = New-CodexSafeTreeDeleteMetricsObserver `
        -State $metricsState `
        -IncludeLogicalBytes $false
    $initial = Read-CodexSafeTreeDeleteApprovedTransaction `
        -TransactionPath $TransactionPath `
        -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot `
        -AllowRestoreState `
        -MetricsObserver $repeatMetricsObserver
    $targetPath = [string]$initial.document.targetPath
    $mutexHash = Get-CodexHookTextSha256 -Text $targetPath.ToUpperInvariant()
    $mutex = [Threading.Mutex]::new($false, "Local\CodexSafeTreeDelete-$mutexHash")
    $held = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'safe-delete target mutex busy。' }
        $approved = Read-CodexSafeTreeDeleteApprovedTransaction `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
            -PolicyPath $PolicyPath `
            -EvidenceRoot $EvidenceRoot `
            -AllowRestoreState `
            -MetricsObserver $repeatMetricsObserver
        $transaction = $approved.document
        $plan = $approved.approvedPlan.document
        $target = $approved.approvedPlan.target
        $status = [string]$transaction.status
        if ($status -ceq 'purging') { throw 'safe-delete Restore 拒绝 purging transaction。' }
        if ($status -cin @('purged', 'rolled-back')) {
            throw 'safe-delete Restore 拒绝不可恢复的 terminal transaction。'
        }
        $runDirectory = Split-Path -Parent $approved.path
        $intentPath = Join-Path $runDirectory 'restore-intent.json'
        $renamedPath = Join-Path $runDirectory 'restore-renamed.json'
        $verifiedPath = Join-Path $runDirectory 'restore-verified.json'
        $completePath = Join-Path $runDirectory 'restore-complete.json'
        $quarantinePath = [string]$transaction.quarantinePath
        $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $target
        $targetState = Get-CodexSafeTreeDeleteNamespaceState -Path ([string]$target.targetPath)
        $quarantineState = Get-CodexSafeTreeDeleteNamespaceState -Path $quarantinePath
        if ([string]$targetState.entryType -cnotin @('absent', 'directory') -or
            [string]$quarantineState.entryType -cnotin @('absent', 'directory')) {
            throw 'safe-delete Restore target/quarantine namespace entry 不是普通目录。'
        }
        $targetPresent = [string]$targetState.entryType -ceq 'directory'
        $quarantinePresent = [string]$quarantineState.entryType -ceq 'directory'

        if ($status -ceq 'restored') {
            if (-not $targetPresent -or $quarantinePresent -or
                -not [IO.File]::Exists($intentPath) -or -not [IO.File]::Exists($completePath)) {
                throw 'safe-delete restored transaction live state 不一致。'
            }
            $targetTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                -Path $target.targetPath `
                -CapabilityRoot $target.capabilityRoot `
                -AllowedExactPaths @($target.targetPath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -MetricsObserver $metricsObserver `
                -Name 'safe-delete restore replay target snapshot'
            if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $targetTree) -cne
                (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
                throw 'safe-delete restored transaction target tree 漂移。'
            }
            $intent = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $intentPath -RunDirectory $runDirectory -Kind intent `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
            $renamed = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $renamedPath -RunDirectory $runDirectory -Kind renamed `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
            $verified = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $verifiedPath -RunDirectory $runDirectory -Kind verified `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
            $complete = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $completePath -RunDirectory $runDirectory -Kind complete `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
            Assert-CodexSafeTreeDeleteRestoreJournalReference `
                -Document $renamed.document -Reference intent -Journal $intent `
                -Scope 'safe-delete restored rename journal'
            foreach ($reference in @(
                    [pscustomobject]@{ name = 'intent'; journal = $intent },
                    [pscustomobject]@{ name = 'rename'; journal = $renamed })) {
                Assert-CodexSafeTreeDeleteRestoreJournalReference `
                    -Document $verified.document -Reference $reference.name -Journal $reference.journal `
                    -Scope 'safe-delete restored verification journal'
            }
            foreach ($reference in @(
                    [pscustomobject]@{ name = 'intent'; journal = $intent },
                    [pscustomobject]@{ name = 'rename'; journal = $renamed },
                    [pscustomobject]@{ name = 'verification'; journal = $verified })) {
                Assert-CodexSafeTreeDeleteRestoreJournalReference `
                    -Document $complete.document -Reference $reference.name -Journal $reference.journal `
                    -Scope 'safe-delete restored complete journal'
            }
            return [pscustomobject][ordered]@{
                restored = $true
                alreadyRestored = $true
                targetPath = $target.targetPath
                quarantinePath = $quarantinePath
                transactionPath = $approved.path
                transactionSha256 = $approved.sha256
                namespaceAbsent = $false
                logicalCompletion = $false
                physicalReclaimStatus = 'not-applicable'
                metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
            }
        }
        if ($status -cnotin @('prepared', 'quarantined')) {
            throw 'safe-delete Restore transaction 状态非法。'
        }
        if (($targetPresent -and $quarantinePresent) -or (-not $targetPresent -and -not $quarantinePresent)) {
            throw 'safe-delete Restore source/destination existence 状态冲突。'
        }
        if ($targetPresent -and -not [IO.File]::Exists($intentPath)) {
            throw 'safe-delete Restore target 已存在且缺少 rename intent。'
        }

        $treePath = if ($quarantinePresent) { $quarantinePath } else { [string]$target.targetPath }
        $treeCapabilityRoot = if ($quarantinePresent) { $quarantineCapabilityRoot } else { [string]$target.capabilityRoot }
        $tree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $treePath `
            -CapabilityRoot $treeCapabilityRoot `
            -AllowedExactPaths @($treePath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $metricsObserver `
            -Name 'safe-delete restore tree preflight'
        Assert-CodexSafeTreeDeleteTargetTreePolicy -Target $target -TreeManifest $tree -TreePath $treePath
        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $tree) -cne
            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
            throw 'safe-delete Restore tree manifest 漂移。'
        }

        $intent = $null
        if ([IO.File]::Exists($intentPath)) {
            $intent = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $intentPath -RunDirectory $runDirectory -Kind intent `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        } else {
            $intentDocument = [pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-restore-intent'
                schemaVersion = 1
                generationId = [string]$plan.generationId
                transactionPath = $approved.path
                sourcePath = $quarantinePath
                destinationPath = [string]$target.targetPath
                state = 'intent'
                createdAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }
            [void](New-CodexHookCapabilityJson `
                -Path $intentPath `
                -Document $intentDocument `
                -CapabilityRoot $runDirectory `
                -AllowedExactPaths @($intentPath) `
                -Scope 'safe-delete restore intent publish')
            $intent = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $intentPath -RunDirectory $runDirectory -Kind intent `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        }
        if ($null -ne $RestoreCheckpointForTest) {
            & $RestoreCheckpointForTest $target.targetPath $quarantinePath 'after-intent'
        }

        if ($quarantinePresent) {
            $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete(
                [string]$quarantineCapabilityRoot,
                $quarantinePath)
            try {
                Assert-CodexHookDirectoryTreeIdentity `
                    -Expected @($plan.treeManifest.rootIdentity) `
                    -Actual @($guard.VolumeSerialNumber, $guard.FileIndex) `
                    -Scope 'safe-delete restore root'
                [void]$guard.RenameToSibling([string]$target.targetPath)
            } finally {
                $guard.Dispose()
            }
            if ($null -ne $RestoreCheckpointForTest) {
                & $RestoreCheckpointForTest $target.targetPath $quarantinePath 'after-rename'
            }
        }
        if (-not [IO.Directory]::Exists($target.targetPath) -or [IO.Directory]::Exists($quarantinePath)) {
            throw 'safe-delete Restore rename postcheck 失败。'
        }
        if ([IO.File]::Exists($renamedPath)) {
            $renamed = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $renamedPath -RunDirectory $runDirectory -Kind renamed `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        } else {
            $renamedDocument = [pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-restore-renamed'
                schemaVersion = 1
                generationId = [string]$plan.generationId
                transactionPath = $approved.path
                sourcePath = $quarantinePath
                destinationPath = [string]$target.targetPath
                state = 'renamed'
                createdAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                intentPath = [string]$intent.path
                intentSha256 = [string]$intent.sha256
                intentIdentity = @($intent.identity)
                targetRootIdentity = @($plan.treeManifest.rootIdentity)
            }
            [void](New-CodexHookCapabilityJson `
                -Path $renamedPath `
                -Document $renamedDocument `
                -CapabilityRoot $runDirectory `
                -AllowedExactPaths @($renamedPath) `
                -Scope 'safe-delete restore renamed publish')
            $renamed = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $renamedPath -RunDirectory $runDirectory -Kind renamed `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        }
        Assert-CodexSafeTreeDeleteRestoreJournalReference `
            -Document $renamed.document -Reference intent -Journal $intent `
            -Scope 'safe-delete restore renamed journal'
        $restoredTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $target.targetPath `
            -CapabilityRoot $target.capabilityRoot `
            -AllowedExactPaths @($target.targetPath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $repeatMetricsObserver `
            -Name 'safe-delete restore target postcheck'
        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $restoredTree) -cne
            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
            throw 'safe-delete Restore target postcheck tree manifest 漂移。'
        }
        $targetTreeManifestSha256 = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $restoredTree
        if ([IO.File]::Exists($verifiedPath)) {
            $verified = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $verifiedPath -RunDirectory $runDirectory -Kind verified `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        } else {
            $verifiedDocument = [pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-restore-verified'
                schemaVersion = 1
                generationId = [string]$plan.generationId
                transactionPath = $approved.path
                sourcePath = $quarantinePath
                destinationPath = [string]$target.targetPath
                state = 'verified'
                createdAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                intentPath = [string]$intent.path
                intentSha256 = [string]$intent.sha256
                intentIdentity = @($intent.identity)
                renamePath = [string]$renamed.path
                renameSha256 = [string]$renamed.sha256
                renameIdentity = @($renamed.identity)
                targetRootIdentity = @($plan.treeManifest.rootIdentity)
                targetTreeManifestSha256 = [string]$targetTreeManifestSha256
            }
            [void](New-CodexHookCapabilityJson `
                -Path $verifiedPath `
                -Document $verifiedDocument `
                -CapabilityRoot $runDirectory `
                -AllowedExactPaths @($verifiedPath) `
                -Scope 'safe-delete restore verified publish')
            $verified = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $verifiedPath -RunDirectory $runDirectory -Kind verified `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        }
        Assert-CodexSafeTreeDeleteRestoreJournalReference `
            -Document $verified.document -Reference intent -Journal $intent `
            -Scope 'safe-delete restore verified journal'
        Assert-CodexSafeTreeDeleteRestoreJournalReference `
            -Document $verified.document -Reference rename -Journal $renamed `
            -Scope 'safe-delete restore verified journal'
        if ($null -ne $RestoreCheckpointForTest) {
            & $RestoreCheckpointForTest $target.targetPath $quarantinePath 'after-target-verification'
        }

        if ([IO.File]::Exists($completePath)) {
            $complete = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $completePath -RunDirectory $runDirectory -Kind complete `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        } else {
            $completeDocument = [pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-restore-complete'
                schemaVersion = 1
                generationId = [string]$plan.generationId
                transactionPath = $approved.path
                sourcePath = $quarantinePath
                destinationPath = [string]$target.targetPath
                state = 'complete'
                createdAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                intentPath = [string]$intent.path
                intentSha256 = [string]$intent.sha256
                intentIdentity = @($intent.identity)
                renamePath = [string]$renamed.path
                renameSha256 = [string]$renamed.sha256
                renameIdentity = @($renamed.identity)
                targetRootIdentity = @($plan.treeManifest.rootIdentity)
                targetTreeManifestSha256 = [string]$targetTreeManifestSha256
                verificationPath = [string]$verified.path
                verificationSha256 = [string]$verified.sha256
                verificationIdentity = @($verified.identity)
            }
            [void](New-CodexHookCapabilityJson `
                -Path $completePath `
                -Document $completeDocument `
                -CapabilityRoot $runDirectory `
                -AllowedExactPaths @($completePath) `
                -Scope 'safe-delete restore complete publish')
            $complete = Read-CodexSafeTreeDeleteRestoreJournal `
                -Path $completePath -RunDirectory $runDirectory -Kind complete `
                -Transaction $transaction -Plan $plan -MetricsObserver $repeatMetricsObserver
        }
        foreach ($reference in @(
                [pscustomobject]@{ name = 'intent'; journal = $intent },
                [pscustomobject]@{ name = 'rename'; journal = $renamed },
                [pscustomobject]@{ name = 'verification'; journal = $verified })) {
            Assert-CodexSafeTreeDeleteRestoreJournalReference `
                -Document $complete.document -Reference $reference.name -Journal $reference.journal `
                -Scope 'safe-delete restore complete journal'
        }
        if ($null -ne $RestoreCheckpointForTest) {
            & $RestoreCheckpointForTest $target.targetPath $quarantinePath 'after-complete-journal'
        }
        if ([long]$transaction.schemaVersion -eq 3L) {
            $transaction.restoreJournalAnchors = @([pscustomobject][ordered]@{
                intentPath = [string]$intent.path
                intentSha256 = [string]$intent.sha256
                intentIdentity = @($intent.identity)
                renamePath = [string]$renamed.path
                renameSha256 = [string]$renamed.sha256
                renameIdentity = @($renamed.identity)
                verificationPath = [string]$verified.path
                verificationSha256 = [string]$verified.sha256
                verificationIdentity = @($verified.identity)
                completePath = [string]$complete.path
                completeSha256 = [string]$complete.sha256
                completeIdentity = @($complete.identity)
            })
        }
        $transaction.status = 'restored'
        $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Set-CodexHookCapabilityJson `
            -Path $approved.path `
            -Document $transaction `
            -CapabilityRoot $runDirectory `
            -AllowedExactPaths @($approved.path) `
            -Scope 'safe-delete restored transaction publish'
        $finalSnapshot = Get-CodexHookCapabilityFileSnapshot `
            -Path $approved.path `
            -CapabilityRoot $runDirectory `
            -AllowedExactPaths @($approved.path) `
            -Name 'safe-delete restored transaction published'
        & $repeatMetricsObserver 'hash-read' 0L ([long]$finalSnapshot.bytes.Length)
        if ($null -ne $RestoreCheckpointForTest) {
            & $RestoreCheckpointForTest $target.targetPath $quarantinePath 'after-transaction-publication'
        }
        return [pscustomobject][ordered]@{
            restored = $true
            alreadyRestored = $false
            targetPath = $target.targetPath
            quarantinePath = $quarantinePath
            transactionPath = $approved.path
            transactionSha256 = [string]$finalSnapshot.sha256
            namespaceAbsent = $false
            logicalCompletion = $false
            physicalReclaimStatus = 'not-applicable'
            metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
        }
    } finally {
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-CodexSafeTreeDeleteAbortOperationKeys {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$GenerationId,
        [scriptblock]$MetricsObserver
    )

    $fullRunDirectory = Assert-CodexHookDPath `
        -Value $RunDirectory `
        -Name 'safe-delete abort journal root'
    $operationKeys = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $freezePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($abortPathCandidate in @([IO.Directory]::EnumerateFiles(
            $fullRunDirectory,
            'directory-delete-*-abort.json',
            [IO.SearchOption]::TopDirectoryOnly))) {
        $abortPath = Assert-CodexHookDPath `
            -Value $abortPathCandidate `
            -Name 'safe-delete abort journal path'
        [void](Assert-CodexHookCapabilityPath `
            -Path $abortPath `
            -CapabilityRoot $fullRunDirectory `
            -AllowedExactPaths @($abortPath) `
            -Name 'safe-delete abort journal')
        if ([IO.Path]::GetFileName($abortPath) -notmatch '^directory-delete-.+-abort\.json$') {
            throw 'safe-delete abort journal 命名非法。'
        }
        $abortSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $abortPath `
            -Name 'safe-delete abort journal' `
            -AllowedExactPaths @($abortPath)
        if ($null -ne $MetricsObserver) {
            & $MetricsObserver 'hash-read' 0L ([long]$abortSnapshot.bytes.Length)
        }
        Assert-CodexHookStrictJsonText -JsonText $abortSnapshot.text
        $abort = $abortSnapshot.text |
            ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $abort `
            -Names @(
                'artifactType', 'schemaVersion', 'generationId', 'operationId',
                'directoryPath', 'relativePath', 'volumeSerialNumber', 'fileIndex',
                'state', 'restoredSecurityDescriptorSddl',
                'freezeIntentPath', 'freezeIntentSha256', 'freezeIntentIdentity', 'createdAtUtc'
            ) `
            -Scope 'safe-delete abort journal'
        if ([string]$abort.artifactType -cne
                'env-governance.codex-safe-tree-delete-directory-abort-intent' -or
            [long]$abort.schemaVersion -ne 2 -or
            [string]$abort.generationId -cne $GenerationId -or
            [string]$abort.operationId -notmatch '^[0-9a-f]{32}$' -or
            [string]$abort.state -cne 'aborted' -or
            [string]$abort.freezeIntentSha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'safe-delete abort journal artifact、schema 或状态非法。'
        }
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @([string]$abort.volumeSerialNumber, [string]$abort.fileIndex) `
            -Actual @([string]$abort.volumeSerialNumber, [string]$abort.fileIndex) `
            -Scope 'safe-delete abort journal directory identity'
        Assert-CodexHookDirectoryTreeIdentity `
            -Expected @($abort.freezeIntentIdentity) `
            -Actual @($abort.freezeIntentIdentity) `
            -Scope 'safe-delete abort journal freeze identity'
        $freezePath = Assert-CodexHookDPath `
            -Value ([string]$abort.freezeIntentPath) `
            -Name 'safe-delete abort freeze journal path'
        if (-not (Test-CodexHookPathWithin -Path $freezePath -ParentPath $fullRunDirectory) -or
            [IO.Path]::GetFileName($freezePath) -notmatch '^directory-delete-.+-freeze\.json$' -or
            -not [IO.File]::Exists($freezePath)) {
            throw 'safe-delete abort freeze journal path 越界、命名非法或缺失。'
        }
        $freezeSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $freezePath `
            -Name 'safe-delete abort referenced freeze journal' `
            -AllowedExactPaths @($freezePath)
        if ($null -ne $MetricsObserver) {
            & $MetricsObserver 'hash-read' 0L ([long]$freezeSnapshot.bytes.Length)
        }
        if ([string]$freezeSnapshot.sha256 -cne [string]$abort.freezeIntentSha256 -or
            -not (Test-CodexHookDirectoryTreeIdentityEqual `
                -Expected @($abort.freezeIntentIdentity) `
                -Actual @($freezeSnapshot.probe.identity))) {
            throw 'safe-delete abort referenced freeze journal SHA-256 或 file identity 漂移。'
        }
        Assert-CodexHookStrictJsonText -JsonText $freezeSnapshot.text
        $freeze = $freezeSnapshot.text |
            ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $freeze `
            -Names @(
                'artifactType', 'schemaVersion', 'generationId', 'operationId',
                'directoryPath', 'relativePath', 'volumeSerialNumber', 'fileIndex',
                'state', 'originalSecurityDescriptorSddl',
                'requestedFrozenSecurityDescriptorSddl', 'createdAtUtc'
            ) `
            -Scope 'safe-delete abort referenced freeze journal'
        if ([string]$freeze.artifactType -cne
                'env-governance.codex-safe-tree-delete-directory-freeze-intent' -or
            [long]$freeze.schemaVersion -ne 2 -or
            [string]$freeze.state -cne 'freeze-prepared' -or
            [string]$freeze.generationId -cne [string]$abort.generationId -or
            [string]$freeze.operationId -cne [string]$abort.operationId -or
            [string]$freeze.directoryPath -cne [string]$abort.directoryPath -or
            [string]$freeze.relativePath -cne [string]$abort.relativePath -or
            [string]$freeze.volumeSerialNumber -cne [string]$abort.volumeSerialNumber -or
            [string]$freeze.fileIndex -cne [string]$abort.fileIndex -or
            -not [CodexHookGovernance.VerifiedDirectoryChainGuard]::SecurityDescriptorsHaveEquivalentDacl(
                [string]$freeze.originalSecurityDescriptorSddl,
                [string]$abort.restoredSecurityDescriptorSddl)) {
            throw 'safe-delete abort/freeze journal 绑定或 DACL 恢复语义非法。'
        }
        $operationKey = '{0}|{1}' -f $GenerationId, ([string]$abort.operationId)
        if (-not $operationKeys.Add($operationKey)) {
            throw 'safe-delete abort journal operation 重复。'
        }
        if (-not $freezePaths.Add($freezePath)) {
            throw 'safe-delete abort journal freeze 引用重复。'
        }
    }
    [pscustomobject][ordered]@{
        operationKeys = $operationKeys
        freezePaths = $freezePaths
    }
}

function Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$Plan,
        [switch]$RequireComplete,
        [scriptblock]$MetricsObserver
    )

    $fullRunDirectory = Assert-CodexHookDPath `
        -Value $RunDirectory `
        -Name 'safe-delete anchored directory journal root'
    $expectedDirectories = @($Plan.treeManifest.entries | Where-Object kind -ceq 'directory')
    if ($expectedDirectories.Count -eq 0 -or
        @($Plan.treeManifest.entries | Where-Object kind -cne 'directory').Count -ne 0) {
        throw 'safe-delete anchored directory journal 只适用于纯目录树。'
    }
    $expectedByIdentity = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($expectedDirectory in $expectedDirectories) {
        $identityKey = '{0}|{1}' -f
            ([string]$expectedDirectory.identity[0]),
            ([string]$expectedDirectory.identity[1])
        if ($expectedByIdentity.ContainsKey($identityKey)) {
            throw 'safe-delete 计划目录 identity 重复。'
        }
        $expectedByIdentity.Add($identityKey, $expectedDirectory)
    }

    $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $operationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $anchoredCommitPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $anchoredFreezePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $abortJournals = Get-CodexSafeTreeDeleteAbortOperationKeys `
        -RunDirectory $fullRunDirectory `
        -GenerationId ([string]$Plan.generationId) `
        -MetricsObserver $MetricsObserver
    $abortOperationKeys = $abortJournals.operationKeys
    $abortFreezePaths = $abortJournals.freezePaths
    foreach ($anchor in @($Transaction.directoryCommitAnchors)) {
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $anchor `
            -Names @(
                'generationId', 'operationId', 'directoryPath', 'relativePath',
                'volumeSerialNumber', 'fileIndex',
                'freezeIntentPath', 'freezeIntentSha256', 'freezeIntentIdentity',
                'commitIntentPath', 'commitIntentSha256', 'commitIntentIdentity'
            ) `
            -Scope 'safe-delete directory commit anchor'
        $identityKey = '{0}|{1}' -f
            ([string]$anchor.volumeSerialNumber),
            ([string]$anchor.fileIndex)
        if ([string]$anchor.generationId -cne [string]$Plan.generationId -or
            [string]$anchor.operationId -notmatch '^[0-9a-f]{32}$' -or
            [string]$anchor.freezeIntentSha256 -notmatch '^[0-9a-f]{64}$' -or
            [string]$anchor.commitIntentSha256 -notmatch '^[0-9a-f]{64}$' -or
            -not $expectedByIdentity.ContainsKey($identityKey) -or
            -not $covered.Add($identityKey) -or
            -not $operationIds.Add([string]$anchor.operationId)) {
            throw 'safe-delete directory commit anchor generation、identity 或 operation 重复。'
        }
        $expectedDirectory = $expectedByIdentity[$identityKey]
        $expectedDirectoryPath = if ([string]$expectedDirectory.relativePath -ceq '.') {
            [string]$Transaction.quarantinePath
        } else {
            Join-Path `
                ([string]$Transaction.quarantinePath) `
                ([string]$expectedDirectory.relativePath).Replace('/', '\\')
        }
        if ([string]$anchor.relativePath -cne [string]$expectedDirectory.relativePath -or
            [string]$anchor.directoryPath -cne $expectedDirectoryPath) {
            throw 'safe-delete directory commit anchor 路径与计划不一致。'
        }

        $freezePath = Assert-CodexHookDPath `
            -Value ([string]$anchor.freezeIntentPath) `
            -Name 'safe-delete anchored freeze journal path'
        $commitPath = Assert-CodexHookDPath `
            -Value ([string]$anchor.commitIntentPath) `
            -Name 'safe-delete anchored commit journal path'
        if (-not (Test-CodexHookPathWithin -Path $freezePath -ParentPath $fullRunDirectory) -or
            -not (Test-CodexHookPathWithin -Path $commitPath -ParentPath $fullRunDirectory) -or
            [IO.Path]::GetFileName($freezePath) -notmatch '^directory-delete-.+-freeze\.json$' -or
            [IO.Path]::GetFileName($commitPath) -notmatch '^directory-delete-.+-commit\.json$' -or
            ($freezePath -replace '-freeze\.json$', '') -cne
                ($commitPath -replace '-commit\.json$', '')) {
            throw 'safe-delete anchored directory journal path 越界或 operation 不一致。'
        }
        if (-not $anchoredCommitPaths.Add($commitPath)) {
            throw 'safe-delete anchored commit path 重复。'
        }
        if (-not $anchoredFreezePaths.Add($freezePath)) {
            throw 'safe-delete anchored freeze path 重复。'
        }
        $operationKey = '{0}|{1}' -f ([string]$anchor.generationId), ([string]$anchor.operationId)
        if ($abortOperationKeys.Contains($operationKey)) {
            throw 'safe-delete 同一 directory operation 同时存在 commit 与 abort。'
        }
        if (-not [IO.File]::Exists($freezePath) -or -not [IO.File]::Exists($commitPath)) {
            throw 'safe-delete 缺失 transaction 锚定的 commit-authorized directory journal。'
        }
        $freezeSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $freezePath `
            -Name 'safe-delete anchored freeze journal' `
            -AllowedExactPaths @($freezePath)
        $commitSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $commitPath `
            -Name 'safe-delete anchored commit journal' `
            -AllowedExactPaths @($commitPath)
        if ($null -ne $MetricsObserver) {
            & $MetricsObserver 'hash-read' 0L ([long]$freezeSnapshot.bytes.Length)
            & $MetricsObserver 'hash-read' 0L ([long]$commitSnapshot.bytes.Length)
        }
        if ([string]$freezeSnapshot.sha256 -cne [string]$anchor.freezeIntentSha256 -or
            [string]$commitSnapshot.sha256 -cne [string]$anchor.commitIntentSha256 -or
            -not (Test-CodexHookDirectoryTreeIdentityEqual `
                -Expected @($anchor.freezeIntentIdentity) `
                -Actual @($freezeSnapshot.probe.identity)) -or
            -not (Test-CodexHookDirectoryTreeIdentityEqual `
                -Expected @($anchor.commitIntentIdentity) `
                -Actual @($commitSnapshot.probe.identity))) {
            throw 'safe-delete anchored directory journal SHA-256 或 file identity 漂移。'
        }
        Assert-CodexHookStrictJsonText -JsonText $freezeSnapshot.text
        Assert-CodexHookStrictJsonText -JsonText $commitSnapshot.text
        $freeze = $freezeSnapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        $commit = $commitSnapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $freeze `
            -Names @(
                'artifactType', 'schemaVersion', 'generationId', 'operationId',
                'directoryPath', 'relativePath', 'volumeSerialNumber', 'fileIndex',
                'state', 'originalSecurityDescriptorSddl',
                'requestedFrozenSecurityDescriptorSddl', 'createdAtUtc'
            ) `
            -Scope 'safe-delete anchored freeze journal'
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $commit `
            -Names @(
                'artifactType', 'schemaVersion', 'generationId', 'operationId',
                'directoryPath', 'relativePath', 'volumeSerialNumber', 'fileIndex',
                'state', 'originalSecurityDescriptorSddl',
                'requestedFrozenSecurityDescriptorSddl', 'appliedFrozenSecurityDescriptorSddl',
                'freezeIntentPath', 'freezeIntentSha256', 'freezeIntentIdentity', 'createdAtUtc'
            ) `
            -Scope 'safe-delete anchored commit journal'
        if ([string]$freeze.artifactType -cne
                'env-governance.codex-safe-tree-delete-directory-freeze-intent' -or
            [long]$freeze.schemaVersion -ne 2 -or
            [string]$commit.artifactType -cne
                'env-governance.codex-safe-tree-delete-directory-commit-intent' -or
            [long]$commit.schemaVersion -ne 2 -or
            [string]$freeze.state -cne 'freeze-prepared' -or
            [string]$commit.state -cne 'commit-authorized' -or
            [string]$freeze.generationId -cne [string]$anchor.generationId -or
            [string]$freeze.operationId -cne [string]$anchor.operationId -or
            [string]$commit.operationId -cne [string]$anchor.operationId -or
            [string]$freeze.directoryPath -cne [string]$anchor.directoryPath -or
            [string]$commit.directoryPath -cne [string]$anchor.directoryPath -or
            [string]$freeze.relativePath -cne [string]$anchor.relativePath -or
            [string]$commit.relativePath -cne [string]$anchor.relativePath -or
            [string]$freeze.volumeSerialNumber -cne [string]$anchor.volumeSerialNumber -or
            [string]$commit.volumeSerialNumber -cne [string]$anchor.volumeSerialNumber -or
            [string]$freeze.fileIndex -cne [string]$anchor.fileIndex -or
            [string]$commit.fileIndex -cne [string]$anchor.fileIndex -or
            [string]$commit.freezeIntentPath -cne $freezePath -or
            [string]$commit.freezeIntentSha256 -cne [string]$freezeSnapshot.sha256 -or
            -not (Test-CodexHookDirectoryTreeIdentityEqual `
                -Expected @($commit.freezeIntentIdentity) `
                -Actual @($freezeSnapshot.probe.identity)) -or
            [string]$freeze.originalSecurityDescriptorSddl -cne
                [string]$commit.originalSecurityDescriptorSddl -or
            [string]$freeze.requestedFrozenSecurityDescriptorSddl -cne
                [string]$commit.requestedFrozenSecurityDescriptorSddl -or
            -not [CodexHookGovernance.VerifiedDirectoryChainGuard]::IsValidAlternateDataStreamWriteFreeze(
                [string]$commit.originalSecurityDescriptorSddl,
                [string]$commit.requestedFrozenSecurityDescriptorSddl,
                [string]$commit.appliedFrozenSecurityDescriptorSddl)) {
            throw 'safe-delete anchored freeze/commit journal 绑定或 DACL 冻结语义非法。'
        }
        $abortPath = $commitPath -replace '-commit\.json$', '-abort.json'
        if ([IO.File]::Exists($abortPath)) {
            throw 'safe-delete 同一 directory operation 同时存在 commit 与 abort。'
        }
    }

    if ($RequireComplete) {
        foreach ($commitPathCandidate in @([IO.Directory]::EnumerateFiles(
                $fullRunDirectory,
                'directory-delete-*-commit.json',
                [IO.SearchOption]::TopDirectoryOnly))) {
            $commitPath = Assert-CodexHookDPath `
                -Value $commitPathCandidate `
                -Name 'safe-delete complete commit journal path'
            if (-not $anchoredCommitPaths.Contains($commitPath)) {
                throw 'safe-delete 缺失 quarantine 时存在未被 transaction 锚定的 commit journal。'
            }
        }
        foreach ($freezePathCandidate in @([IO.Directory]::EnumerateFiles(
                $fullRunDirectory,
                'directory-delete-*-freeze.json',
                [IO.SearchOption]::TopDirectoryOnly))) {
            $freezePath = Assert-CodexHookDPath `
                -Value $freezePathCandidate `
                -Name 'safe-delete complete freeze journal path'
            if (-not $anchoredFreezePaths.Contains($freezePath) -and
                -not $abortFreezePaths.Contains($freezePath)) {
                throw 'safe-delete 缺失 quarantine 时存在未终结的 freeze journal。'
            }
        }
        if ($covered.Count -ne $expectedByIdentity.Count) {
            throw 'safe-delete anchored commit 未覆盖全部计划目录。'
        }
    }
    return $covered.Count
}

function Complete-CodexSafeTreeDeleteCommittedMissingQuarantine {
    param(
        [Parameter(Mandatory)][object]$ApprovedTransaction,
        [Parameter(Mandatory)][object]$MetricsState,
        [Parameter(Mandatory)][scriptblock]$MetricsObserver
    )

    $transaction = $ApprovedTransaction.document
    $approvedPlan = $ApprovedTransaction.approvedPlan
    $plan = $approvedPlan.document
    $target = $approvedPlan.target
    if ([string]$transaction.status -cne 'purging' -or
        [string]$target.rootDeletionPurpose -cne 'empty-project-state' -or
        [IO.Directory]::Exists([string]$transaction.quarantinePath) -or
        [IO.File]::Exists([string]$transaction.quarantinePath)) {
        throw 'safe-delete 缺失 quarantine 不满足 commit journal 恢复条件。'
    }

    $runDirectory = Split-Path -Parent $ApprovedTransaction.path
    [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
        -RunDirectory $runDirectory `
        -Transaction $transaction `
        -Plan $plan `
        -RequireComplete `
        -MetricsObserver $MetricsObserver)
    $transaction.status = 'purged'
    $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
        'o',
        [Globalization.CultureInfo]::InvariantCulture)
    Set-CodexHookCapabilityJson `
        -Path $ApprovedTransaction.path `
        -Document $transaction `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($ApprovedTransaction.path) `
        -Scope 'safe-delete committed missing quarantine recovery'
    $finalSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $ApprovedTransaction.path `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($ApprovedTransaction.path) `
        -Name 'safe-delete committed missing quarantine transaction published'
    & $MetricsObserver 'hash-read' 0L ([long]$finalSnapshot.bytes.Length)
    return [pscustomobject][ordered]@{
        purged = $true
        targetPath = [string]$transaction.targetPath
        quarantinePath = [string]$transaction.quarantinePath
        transactionPath = $ApprovedTransaction.path
        transactionSha256 = $finalSnapshot.sha256
        recoverable = $false
        recoveredFromCommitJournal = $true
        namespaceAbsent = $true
        logicalCompletion = $true
        physicalReclaimStatus = 'unknown'
        physicalReclaimReason = 'independent-filesystem-allocation-evidence-unavailable'
        deletionOutcome = New-CodexSafeTreeDeleteOutcome `
            -NamespaceAbsent $true `
            -LogicalCompletion $true
        metrics = Complete-CodexSafeTreeDeleteMetrics -State $MetricsState
    }
}

function Invoke-CodexSafeTreeDeletePurge {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [scriptblock]$BeforePurgeMutexForTest,
        [scriptblock]$BeforeDirectoryTreeDeleteForTest,
        [scriptblock]$DirectoryDeleteCheckpointForTest,
        [scriptblock]$LeafDeleteFaultForTest,
        [scriptblock]$LeafDeleteCheckpointForTest,
        [object]$LeafRetryPolicyForTest,
        [scriptblock]$LeafRetryElapsedMillisecondsForTest,
        [scriptblock]$LeafRetryDelayForTest,
        [Nullable[datetimeoffset]]$TrustedNowUtc,
        [Nullable[long]]$TrustedElapsedNowMilliseconds,
        [string]$TrustedBootSessionId,
        [scriptblock]$TrustedBootSessionSourceForTest,
        [switch]$TrustedTimeRestartAmbiguous,
        [switch]$ReturnFailureMetrics
    )

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'purge'
    $metricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
    $repeatMetricsObserver = New-CodexSafeTreeDeleteMetricsObserver `
        -State $metricsState `
        -IncludeLogicalBytes:$false
    $metricsState.retryResult = 'not-needed'
    $leafRetryPolicy = if ($null -ne $LeafRetryPolicyForTest) {
        $LeafRetryPolicyForTest
    } else {
        [pscustomobject][ordered]@{
            schemaVersion = 1
            maxAttempts = 3
            wallTimeBudgetMs = 1000
            delayMilliseconds = @(10, 25)
            allowedWindowsErrors = @(32, 33, 170)
        }
    }
    $metricsState.retryContract = [pscustomobject][ordered]@{
        schemaVersion = [long]$leafRetryPolicy.schemaVersion
        maxAttempts = [long]$leafRetryPolicy.maxAttempts
        wallTimeBudgetMs = [long]$leafRetryPolicy.wallTimeBudgetMs
        delayMilliseconds = @($leafRetryPolicy.delayMilliseconds)
        allowedErrorCategories = @('sharing-violation', 'lock-violation', 'busy')
    }
    $retryObserver = {
        param([object]$Event)
        if ([string]$Event.result -ceq 'retrying') {
            $metricsState.retryAttempts = [long]$metricsState.retryAttempts + 1L
            $metricsState.retryResult = 'retrying'
            $metricsState.retryEvents.Add($Event)
        } elseif ([string]$Event.result -in @('succeeded', 'failed') -and
            $metricsState.retryEvents.Count -ne 0) {
            $last = $metricsState.retryEvents[$metricsState.retryEvents.Count - 1]
            if ([string]$last.result -ceq 'retrying') {
                $last.revalidation = [string]$Event.revalidation
                $last.result = [string]$Event.result
            }
        }
    }.GetNewClosure()
    $deleteState = [pscustomobject][ordered]@{ anyCommit = $false }
    $deleteCommitCallback = {
        param([string]$Path, [string]$Kind)
        $deleteState.anyCommit = $true
    }.GetNewClosure()
    $initialApproved = Read-CodexSafeTreeDeleteApprovedTransaction `
        -TransactionPath $TransactionPath `
        -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot `
        -MetricsObserver $repeatMetricsObserver
    $initialTarget = $initialApproved.approvedPlan.target
    if ($null -ne $BeforePurgeMutexForTest) {
        & $BeforePurgeMutexForTest $initialTarget.targetPath
    }
    $mutexHash = Get-CodexHookTextSha256 -Text $initialTarget.targetPath.ToUpperInvariant()
    $mutex = [Threading.Mutex]::new($false, "Local\CodexSafeTreeDelete-$mutexHash")
    $held = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'safe-delete target mutex busy。' }
        $approved = Read-CodexSafeTreeDeleteApprovedTransaction `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
            -PolicyPath $PolicyPath `
            -EvidenceRoot $EvidenceRoot `
            -MetricsObserver $repeatMetricsObserver
        $transaction = $approved.document
        $plan = $approved.approvedPlan.document
        $target = $approved.approvedPlan.target
        $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $target
        $quarantinePath = [string]$transaction.quarantinePath
        if (-not [IO.Directory]::Exists($quarantinePath) -and
            -not [IO.File]::Exists($quarantinePath)) {
            return Complete-CodexSafeTreeDeleteCommittedMissingQuarantine `
                -ApprovedTransaction $approved `
                -MetricsState $metricsState `
                -MetricsObserver $repeatMetricsObserver
        }
        $currentTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $quarantinePath `
            -CapabilityRoot $quarantineCapabilityRoot `
            -AllowedExactPaths @($quarantinePath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $metricsObserver `
            -Name 'safe-delete purge locked preflight'
        Assert-CodexSafeTreeDeleteTargetTreePolicy `
            -Target $target `
            -TreeManifest $currentTree `
            -TreePath $quarantinePath
        $purgeManifest = $plan.treeManifest
        if ([string]$transaction.status -cin @('prepared', 'quarantined')) {
            if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $currentTree) -cne
                (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
                throw 'safe-delete purge locked preflight tree manifest 漂移。'
            }
        } else {
            Assert-CodexSafeTreeDeletePartialPurgeManifest `
                -CurrentManifest $currentTree `
                -PlannedManifest $plan.treeManifest
            $purgeManifest = $currentTree
        }

        if ([long]$transaction.schemaVersion -eq 3L) {
            $trustedTimeArguments = @{
                RestartAmbiguous = [bool]$TrustedTimeRestartAmbiguous
            }
            if ($null -ne $TrustedNowUtc) {
                $trustedTimeArguments.WallClockUtc = [datetimeoffset]$TrustedNowUtc
            }
            if ($null -ne $TrustedElapsedNowMilliseconds) {
                $trustedTimeArguments.ElapsedMilliseconds = [long]$TrustedElapsedNowMilliseconds
            }
            if (-not [string]::IsNullOrWhiteSpace($TrustedBootSessionId)) {
                $trustedTimeArguments.BootSessionId = $TrustedBootSessionId
            }
            if ($null -ne $TrustedBootSessionSourceForTest) {
                $trustedTimeArguments.BootSessionSourceForTest = $TrustedBootSessionSourceForTest
            }
            $trustedTime = Get-CodexSafeTreeDeleteTrustedElapsedTimeSample @trustedTimeArguments
            if ($null -eq $transaction.quarantineTimeAnchor) {
                $transaction.quarantineTimeAnchor = New-CodexSafeTreeDeleteQuarantineTimeAnchor `
                    -Transaction $transaction `
                    -Plan $plan `
                    -RunDirectory (Split-Path -Parent $approved.path) `
                    -TrustedTime $trustedTime
                $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
                    'o',
                    [Globalization.CultureInfo]::InvariantCulture)
                Set-CodexHookCapabilityJson `
                    -Path $approved.path `
                    -Document $transaction `
                    -CapabilityRoot (Split-Path -Parent $approved.path) `
                    -AllowedExactPaths @($approved.path) `
                    -Scope 'safe-delete conservative quarantine-time anchor binding'
            }
            $anchor = Read-CodexSafeTreeDeleteQuarantineTimeAnchor `
                -Anchor $transaction.quarantineTimeAnchor `
                -Transaction $transaction `
                -Plan $plan `
                -RunDirectory (Split-Path -Parent $approved.path) `
                -MetricsObserver $repeatMetricsObserver
            Assert-CodexSafeTreeDeleteQuarantineGrace `
                -Anchor $anchor `
                -MinimumAgeMinutes ([long]$target.minimumQuarantineAgeMinutes) `
                -TrustedTime $trustedTime
        }

        $runDirectory = Split-Path -Parent $approved.path
        if ([string]$target.rootDeletionPurpose -ceq 'empty-project-state') {
            [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
                -RunDirectory $runDirectory `
                -Transaction $transaction `
                -Plan $plan `
                -MetricsObserver $repeatMetricsObserver)
        }
        if ([string]$transaction.status -ceq 'prepared') {
            $transaction.status = 'quarantined'
            $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture)
            Set-CodexHookCapabilityJson `
                -Path $approved.path `
                -Document $transaction `
                -CapabilityRoot $runDirectory `
                -AllowedExactPaths @($approved.path) `
                -Scope 'safe-delete recovered prepared transaction'
        }
        if ([string]$transaction.status -ceq 'quarantined') {
            $transaction.status = 'purging'
            $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture)
            Set-CodexHookCapabilityJson `
                -Path $approved.path `
                -Document $transaction `
                -CapabilityRoot $runDirectory `
                -AllowedExactPaths @($approved.path) `
                -Scope 'safe-delete transaction purging'
        }

        $anchorDirectoryCommit = {
            param([Parameter(Mandatory)][object]$Anchor)

            Assert-CodexSafeTreeDeleteExactProperties `
                -Value $Anchor `
                -Names @(
                    'generationId', 'operationId', 'directoryPath', 'relativePath',
                    'volumeSerialNumber', 'fileIndex',
                    'freezeIntentPath', 'freezeIntentSha256', 'freezeIntentIdentity',
                    'commitIntentPath', 'commitIntentSha256', 'commitIntentIdentity'
                ) `
                -Scope 'safe-delete directory commit anchor candidate'
            if ([string]$Anchor.generationId -cne [string]$plan.generationId -or
                [string]$Anchor.operationId -notmatch '^[0-9a-f]{32}$' -or
                [string]$Anchor.freezeIntentSha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]$Anchor.commitIntentSha256 -notmatch '^[0-9a-f]{64}$') {
                throw 'safe-delete directory commit anchor candidate 状态非法。'
            }
            $matchingPlannedDirectories = @($plan.treeManifest.entries | Where-Object {
                $_.kind -ceq 'directory' -and
                [string]$_.identity[0] -ceq [string]$Anchor.volumeSerialNumber -and
                [string]$_.identity[1] -ceq [string]$Anchor.fileIndex
            })
            if ($matchingPlannedDirectories.Count -ne 1 -or
                [string]$matchingPlannedDirectories[0].relativePath -cne
                    [string]$Anchor.relativePath) {
                throw 'safe-delete directory commit anchor candidate 不属于唯一计划目录。'
            }
            $expectedDirectoryPath = if ([string]$Anchor.relativePath -ceq '.') {
                $quarantinePath
            } else {
                Join-Path $quarantinePath ([string]$Anchor.relativePath).Replace('/', '\\')
            }
            if ([string]$Anchor.directoryPath -cne $expectedDirectoryPath) {
                throw 'safe-delete directory commit anchor candidate 路径非法。'
            }
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($Anchor.freezeIntentIdentity) `
                -Actual @($Anchor.freezeIntentIdentity) `
                -Scope 'safe-delete freeze journal anchor identity'
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($Anchor.commitIntentIdentity) `
                -Actual @($Anchor.commitIntentIdentity) `
                -Scope 'safe-delete commit journal anchor identity'

            $existingByIdentity = @($transaction.directoryCommitAnchors | Where-Object {
                [string]$_.volumeSerialNumber -ceq [string]$Anchor.volumeSerialNumber -and
                [string]$_.fileIndex -ceq [string]$Anchor.fileIndex
            })
            $existingByOperation = @($transaction.directoryCommitAnchors | Where-Object {
                [string]$_.operationId -ceq [string]$Anchor.operationId
            })
            if ($existingByIdentity.Count -ne 0 -or $existingByOperation.Count -ne 0) {
                if ($existingByIdentity.Count -eq 1 -and
                    $existingByOperation.Count -eq 1 -and
                    (($existingByIdentity[0] | ConvertTo-Json -Depth 16 -Compress) -ceq
                        ($Anchor | ConvertTo-Json -Depth 16 -Compress))) {
                    return
                }
                throw 'safe-delete directory commit anchor identity 或 operation 冲突。'
            }
            $transaction.directoryCommitAnchors = @($transaction.directoryCommitAnchors) + @($Anchor)
            $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture)
            Set-CodexHookCapabilityJson `
                -Path $approved.path `
                -Document $transaction `
                -CapabilityRoot $runDirectory `
                -AllowedExactPaths @($approved.path) `
                -Scope 'safe-delete transaction directory commit anchor'
        }
        if ($null -ne $BeforeDirectoryTreeDeleteForTest) {
            & $BeforeDirectoryTreeDeleteForTest $quarantinePath
        }
        try {
            Remove-CodexHookCapabilityDirectoryTree `
                -Path $quarantinePath `
                -CapabilityRoot $quarantineCapabilityRoot `
                -AllowedExactPaths @($quarantinePath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -ExpectedRootIdentity @($plan.treeManifest.rootIdentity) `
                -ExpectedTreeManifest $purgeManifest `
                -RejectNamedStreams:([string]$target.rootDeletionPurpose -ceq 'empty-project-state') `
                -NamedStreamDeleteIntentRoot $runDirectory `
                -NamedStreamDeleteGenerationId ([string]$plan.generationId) `
                -NamedStreamDeleteJournalAnchors @($transaction.directoryCommitAnchors) `
                -NamedStreamDeleteCommitAnchor $anchorDirectoryCommit `
                -NamedStreamDeleteCheckpointForTest $DirectoryDeleteCheckpointForTest `
                -LeafRetryPolicy $leafRetryPolicy `
                -LeafRetryFaultForTest $LeafDeleteFaultForTest `
                -LeafRetryObserver $retryObserver `
                -LeafRetryElapsedMillisecondsForTest $LeafRetryElapsedMillisecondsForTest `
                -LeafRetryDelayForTest $LeafRetryDelayForTest `
                -LeafDeleteCheckpointForTest $LeafDeleteCheckpointForTest `
                -MetricsObserver $repeatMetricsObserver `
                -DeleteCommitCallback $deleteCommitCallback `
                -Scope 'safe-delete approved purge'
        } catch {
            $purgeFailure = $_
            if (-not [bool]$deleteState.anyCommit -and
                @($transaction.directoryCommitAnchors).Count -eq 0 -and
                [IO.Directory]::Exists($quarantinePath)) {
                $unchangedTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                    -Path $quarantinePath `
                    -CapabilityRoot $quarantineCapabilityRoot `
                    -AllowedExactPaths @($quarantinePath) `
                    -AllowHardLinks:([bool]$target.allowHardLinks) `
                    -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                    -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                    -MetricsObserver $repeatMetricsObserver `
                    -Name 'safe-delete zero-commit purge rollback snapshot'
                if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $unchangedTree) -ceq
                    (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
                    $transaction.status = 'quarantined'
                    $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
                        'o',
                        [Globalization.CultureInfo]::InvariantCulture)
                    Set-CodexHookCapabilityJson `
                        -Path $approved.path `
                        -Document $transaction `
                        -CapabilityRoot $runDirectory `
                        -AllowedExactPaths @($approved.path) `
                        -Scope 'safe-delete zero-commit purge rollback'
                }
            }
            $metricsState.retryResult = if ([long]$metricsState.retryAttempts -gt 0L) {
                'failed-after-retry'
            } else {
                'failed-without-retry'
            }
            $failureMetrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
            if ($ReturnFailureMetrics) {
                return [pscustomobject][ordered]@{
                    purged = $false
                    refusalReason = 'leaf-delete-failed'
                    transactionPath = $approved.path
                    recoverable = [string]$transaction.status -ceq 'quarantined'
                    purgeResumable = [string]$transaction.status -ceq 'purging'
                    metrics = $failureMetrics
                }
            }
            $purgeFailure.Exception.Data['CodexSafeTreeDeleteMetrics'] = $failureMetrics
            throw $purgeFailure
        }
        if ([IO.Directory]::Exists($quarantinePath) -or [IO.File]::Exists($quarantinePath)) {
            throw 'safe-delete purge postcheck 目标仍存在。'
        }
        if ([string]$target.rootDeletionPurpose -ceq 'empty-project-state') {
            [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
                -RunDirectory $runDirectory `
                -Transaction $transaction `
                -Plan $plan `
                -RequireComplete `
                -MetricsObserver $repeatMetricsObserver)
        }

        $transaction.status = 'purged'
        if ([long]$metricsState.retryAttempts -gt 0L) {
            $metricsState.retryResult = 'succeeded-after-retry'
        }
        $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture)
        Set-CodexHookCapabilityJson `
            -Path $approved.path `
            -Document $transaction `
            -CapabilityRoot $runDirectory `
            -AllowedExactPaths @($approved.path) `
            -Scope 'safe-delete transaction purged'
        $finalSnapshot = Get-CodexHookCapabilityFileSnapshot `
            -Path $approved.path `
            -CapabilityRoot $runDirectory `
            -AllowedExactPaths @($approved.path) `
            -Name 'safe-delete purge transaction published'
        & $repeatMetricsObserver 'hash-read' 0L ([long]$finalSnapshot.bytes.Length)

        return [pscustomobject][ordered]@{
            purged = $true
            targetPath = $target.targetPath
            quarantinePath = $quarantinePath
            transactionPath = $approved.path
            transactionSha256 = $finalSnapshot.sha256
            recoverable = $false
            namespaceAbsent = $true
            logicalCompletion = $true
            physicalReclaimStatus = 'unknown'
            physicalReclaimReason = 'independent-filesystem-allocation-evidence-unavailable'
            deletionOutcome = New-CodexSafeTreeDeleteOutcome `
                -NamespaceAbsent $true `
                -LogicalCompletion $true
            metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
        }
    } finally {
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Find-CodexSafeTreeDeleteRecoverableTransaction {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
    $target = Resolve-CodexSafeTreeDeleteTarget `
        -TargetPath $TargetPath `
        -CapabilityRoot $CapabilityRoot `
        -Policy $policy `
        -RequireExisting:$false
    $fullEvidenceRoot = Initialize-CodexSafeTreeDeleteEvidenceRoot -EvidenceRoot $EvidenceRoot
    $matches = [Collections.Generic.List[object]]::new()
    $unsupportedMatches = [Collections.Generic.List[object]]::new()
    foreach ($transactionPath in [IO.Directory]::EnumerateFiles($fullEvidenceRoot, 'transaction.json', [IO.SearchOption]::AllDirectories)) {
        $transactionFullPath = Assert-CodexHookDPath -Value $transactionPath -Name 'safe-delete recover transaction path'
        [void](Assert-CodexHookCapabilityPath `
            -Path $transactionFullPath `
            -CapabilityRoot $fullEvidenceRoot `
            -AllowedExactPaths @($transactionFullPath) `
            -Name 'safe-delete recover transaction')
        $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $transactionFullPath `
            -Name 'safe-delete recover transaction' `
            -AllowedExactPaths @($transactionFullPath)
        Assert-CodexHookStrictJsonText -JsonText $snapshot.text
        $transaction = $snapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        $status = [string]$transaction.status
        if ($status -cnotin @('prepared', 'quarantined', 'purging')) { continue }
        if (-not (Test-CodexSafeTreeDeletePathEqual `
                -Left ([string]$transaction.targetPath) `
                -Right ([string]$target.targetPath))) { continue }
        if ([IO.Directory]::Exists($target.targetPath)) { continue }
        $quarantineExists = [IO.Directory]::Exists([string]$transaction.quarantinePath) -and
            -not [IO.File]::Exists([string]$transaction.quarantinePath)
        if (-not $quarantineExists -and $status -cne 'purging') { continue }
        if ($transaction.schemaVersion -isnot [long] -or
            [long]$transaction.schemaVersion -notin @(2L, 3L)) {
            $unsupportedMatches.Add([pscustomobject][ordered]@{
                transactionPath = $transactionFullPath
                schemaVersion = $transaction.schemaVersion
            })
            continue
        }
        $matches.Add([pscustomobject][ordered]@{
            transactionPath = $transactionFullPath
            transactionSha256 = $snapshot.sha256
            quarantinePath = [string]$transaction.quarantinePath
            updatedAtUtc = [string]$transaction.updatedAtUtc
        })
    }
    if ($unsupportedMatches.Count -ne 0) {
        $hasSupportedMatch = $matches.Count -ne 0
        return [pscustomobject][ordered]@{
            transactionPath = [string]$unsupportedMatches[0].transactionPath
            transactionSha256 = $null
            updatedAtUtc = $null
            skipAction = if ($hasSupportedMatch) {
                'skipped-ambiguous-transaction-schema'
            } else {
                'skipped-unsupported-transaction-schema'
            }
            skipReason = if ($hasSupportedMatch) {
                'transaction-schema-ambiguous'
            } else {
                'transaction-schema-unsupported'
            }
            schemaVersion = $unsupportedMatches[0].schemaVersion
            supportedTransactionCount = $matches.Count
            unsupportedTransactionCount = $unsupportedMatches.Count
        }
    }
    if ($matches.Count -gt 1) { throw 'safe-delete recoverable transaction 不唯一。' }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function New-CodexSafeTreeDeleteProducerLease {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath
    )

    $policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
    $target = Resolve-CodexSafeTreeDeleteTarget `
        -TargetPath $TargetPath `
        -CapabilityRoot $CapabilityRoot `
        -Policy $policy
    if ([long]$policy.schemaVersion -ne 5L -or
        [string]$target.producerFenceMode -cne 'os-handle-required') {
        throw 'safe-delete producer lease 仅对 policy v5 os-handle-required capability 开放。'
    }
    $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        [string]$target.capabilityRoot,
        [string]$target.targetPath,
        $false)
    try {
        $guard | Add-Member `
            -NotePropertyName identity `
            -NotePropertyValue @([string]$guard.VolumeSerialNumber, [string]$guard.FileIndex) `
            -Force
        $guard | Add-Member `
            -NotePropertyName producerFenceMode `
            -NotePropertyValue 'os-handle-required' `
            -Force
        return $guard
    } catch {
        $guard.Dispose()
        throw
    }
}

function Invoke-CodexSafeTreeDeleteBatchPurge {
    param(
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
    if ([long]$policy.schemaVersion -eq 5L) {
        $batchEntry = @($policy.entries | Where-Object {
            Test-CodexSafeTreeDeletePathEqual `
                -Left ([string]$_.capabilityRoot) `
                -Right (Assert-CodexHookDPath -Value $CapabilityRoot -Name 'safe-delete batch capability root')
        })
        if ($batchEntry.Count -ne 1 -or
            [string]$batchEntry[0].producerFenceMode -cne 'os-handle-required') {
            throw 'safe-delete BatchPurge 只允许已接入 OS-backed producer fence 的 policy v5 capability。'
        }
    }
    $seenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $canonicalTargets = [Collections.Generic.List[string]]::new()
    foreach ($targetPath in @($TargetPaths)) {
        $target = Resolve-CodexSafeTreeDeleteTarget `
            -TargetPath $targetPath `
            -CapabilityRoot $CapabilityRoot `
            -Policy $policy `
            -RequireExisting:$false
        if (-not $seenTargets.Add([string]$target.targetPath)) {
            throw 'safe-delete batch target 重复。'
        }
        $canonicalTargets.Add([string]$target.targetPath)
    }
    [void](Initialize-CodexSafeTreeDeleteEvidenceRoot -EvidenceRoot $EvidenceRoot)

    $results = [Collections.Generic.List[object]]::new()
    foreach ($targetPath in @($canonicalTargets)) {
        $recoverable = $null
        $activeTransactionPath = $null
        $activeQuarantinePath = $null
        try {
            $recoverable = Find-CodexSafeTreeDeleteRecoverableTransaction `
                -TargetPath $targetPath `
                -CapabilityRoot $CapabilityRoot `
                -PolicyPath $PolicyPath `
                -EvidenceRoot $EvidenceRoot
            if ($null -ne $recoverable -and
                $null -ne $recoverable.PSObject.Properties['skipAction']) {
                $results.Add([pscustomobject][ordered]@{
                    targetPath = $targetPath
                    action = [string]$recoverable.skipAction
                    reason = [string]$recoverable.skipReason
                    purged = $false
                    transactionPath = [string]$recoverable.transactionPath
                    transactionSchemaVersion = $recoverable.schemaVersion
                    supportedTransactionCount = [long]$recoverable.supportedTransactionCount
                    unsupportedTransactionCount = [long]$recoverable.unsupportedTransactionCount
                })
                continue
            }
            if ($null -ne $recoverable) {
                $activeTransactionPath = [string]$recoverable.transactionPath
                $activeQuarantinePath = [string]$recoverable.quarantinePath
                $purge = Invoke-CodexSafeTreeDeletePurge `
                    -TransactionPath ([string]$recoverable.transactionPath) `
                    -ApprovedTransactionSha256 ([string]$recoverable.transactionSha256) `
                    -PolicyPath $PolicyPath `
                    -EvidenceRoot $EvidenceRoot
                $results.Add([pscustomobject][ordered]@{
                    targetPath = $targetPath
                    action = 'recovered-purged'
                    purged = [bool]$purge.purged
                    transactionPath = [string]$purge.transactionPath
                })
                continue
            }
            if (-not [IO.Directory]::Exists($targetPath)) {
                $results.Add([pscustomobject][ordered]@{
                    targetPath = $targetPath
                    action = 'already-absent'
                    purged = $false
                    transactionPath = $null
                })
                continue
            }

            $plan = New-CodexSafeTreeDeletePlan `
                -TargetPath $targetPath `
                -CapabilityRoot $CapabilityRoot `
                -PolicyPath $PolicyPath `
                -EvidenceRoot $EvidenceRoot
            $apply = Invoke-CodexSafeTreeDeleteQuarantine `
                -PlanPath ([string]$plan.planPath) `
                -ApprovedPlanSha256 ([string]$plan.planSha256) `
                -PolicyPath $PolicyPath `
                -EvidenceRoot $EvidenceRoot
            $activeTransactionPath = [string]$apply.transactionPath
            $activeQuarantinePath = [string]$apply.quarantinePath
            $purge = Invoke-CodexSafeTreeDeletePurge `
                -TransactionPath ([string]$apply.transactionPath) `
                -ApprovedTransactionSha256 ([string]$apply.transactionSha256) `
                -PolicyPath $PolicyPath `
                -EvidenceRoot $EvidenceRoot
            $results.Add([pscustomobject][ordered]@{
                targetPath = $targetPath
                action = 'planned-applied-purged'
                purged = [bool]$purge.purged
                transactionPath = [string]$purge.transactionPath
            })
        } catch {
            $targetFailureMessage = [string]$_.Exception.Message
            if (-not [string]::IsNullOrWhiteSpace($activeTransactionPath)) {
                $transactionSha256 = $null
                $transactionStatus = $null
                $transactionObservationError = $null
                try {
                    $transactionSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                        -Path $activeTransactionPath `
                        -Name 'safe-delete batch failed transaction observation' `
                        -AllowedExactPaths @($activeTransactionPath)
                    Assert-CodexHookStrictJsonText -JsonText $transactionSnapshot.text
                    $transactionDocument = $transactionSnapshot.text |
                        ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
                    $transactionSha256 = [string]$transactionSnapshot.sha256
                    if ($transactionDocument.PSObject.Properties['status'] -and
                        $transactionDocument.status -is [string]) {
                        $transactionStatus = [string]$transactionDocument.status
                    }
                } catch {
                    $transactionObservationError = [string]$_.Exception.Message
                }
                $targetNamespace = $null
                $targetNamespaceObservationError = $null
                try {
                    $targetNamespace = Get-CodexSafeTreeDeleteNamespaceState -Path $targetPath
                } catch {
                    $targetNamespaceObservationError = [string]$_.Exception.Message
                }
                $quarantineNamespace = $null
                $quarantineNamespaceObservationError = $null
                try {
                    $quarantineNamespace = Get-CodexSafeTreeDeleteNamespaceState `
                        -Path $activeQuarantinePath
                } catch {
                    $quarantineNamespaceObservationError = [string]$_.Exception.Message
                }
                $results.Add([pscustomobject][ordered]@{
                    targetPath = $targetPath
                    action = 'applied-purge-failed'
                    reason = 'purge-failed-after-apply'
                    error = $targetFailureMessage
                    purged = $false
                    transactionPath = $activeTransactionPath
                    transactionSha256 = $transactionSha256
                    transactionStatus = $transactionStatus
                    transactionObservationError = $transactionObservationError
                    quarantinePath = $activeQuarantinePath
                    targetPresent = if ($null -eq $targetNamespace) {
                        $null
                    } else {
                        [bool]$targetNamespace.present
                    }
                    targetEntryType = if ($null -eq $targetNamespace) {
                        'unknown'
                    } else {
                        [string]$targetNamespace.entryType
                    }
                    targetNamespaceObservationError = $targetNamespaceObservationError
                    quarantinePresent = if ($null -eq $quarantineNamespace) {
                        $null
                    } else {
                        [bool]$quarantineNamespace.present
                    }
                    quarantineEntryType = if ($null -eq $quarantineNamespace) {
                        'unknown'
                    } else {
                        [string]$quarantineNamespace.entryType
                    }
                    quarantineNamespaceObservationError = $quarantineNamespaceObservationError
                    recoverable = $transactionStatus -ceq 'quarantined'
                    purgeResumable = $transactionStatus -ceq 'purging'
                })
                continue
            }
            $failedTransactionPath = $null
            if ($null -ne $recoverable -and
                $null -ne $recoverable.PSObject.Properties['transactionPath']) {
                $failedTransactionPath = [string]$recoverable.transactionPath
            }
            $results.Add([pscustomobject][ordered]@{
                targetPath = $targetPath
                action = 'skipped-target-error'
                reason = 'target-operation-failed'
                error = $targetFailureMessage
                purged = $false
                transactionPath = $failedTransactionPath
            })
        }
    }

    $skippedCount = @($results | Where-Object { $_.action -clike 'skipped-*' }).Count
    $failedCount = @($results | Where-Object { $_.action -clike '*-failed' }).Count
    return [pscustomobject][ordered]@{
        completed = $skippedCount -eq 0 -and $failedCount -eq 0
        targetCount = $canonicalTargets.Count
        purgedCount = @($results | Where-Object { $_.purged -eq $true }).Count
        recoveredCount = @($results | Where-Object { $_.action -ceq 'recovered-purged' }).Count
        alreadyAbsentCount = @($results | Where-Object { $_.action -ceq 'already-absent' }).Count
        skippedCount = $skippedCount
        failedCount = $failedCount
        results = @($results)
    }
}
