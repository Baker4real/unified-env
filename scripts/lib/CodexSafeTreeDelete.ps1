Set-StrictMode -Version Latest

# #56 §4.3 / #86：本 lib 编译的全部 C# 组件（含 Status fast scan 与 Plan walker）只经
# CodexHostSafetyNativeLoader.ps1 装配：变体 source 集、内容寻址 generation（不覆盖已发布文件）、
# registry、Assembly.Load(byte[])。本文件不维护编译清单，也不再有固定路径程序集缓存。
. (Join-Path $PSScriptRoot 'CodexHostSafetyNativeLoader.ps1')
[void](Invoke-CodexHostSafetyNativeLoad -RequestedVariant (Get-CodexHostSafetyNativeRequestedVariant))

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

function Get-CodexSafeTreeDeleteLeafStreamSet {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        throw 'LiteralPath 不得为空。'
    }

    return [CodexSafeTreeDelete.LeafStreamSetReader]::CaptureLeafStreamSet($LiteralPath)
}

function ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath {
    param(
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Scope
    )

    Assert-CodexHookDirectoryTreeRelativePath -RelativePath $RelativePath -Scope $Scope
    if ($RelativePath -ceq '.') { return $TreePath }
    $absolutePath = $TreePath
    foreach ($segment in $RelativePath.Split('/')) {
        $absolutePath = Join-Path $absolutePath $segment
    }
    return $absolutePath
}

function New-CodexSafeTreeDeletePlanLeafStreamSet {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][object]$TreeManifest
    )

    $leaves = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($TreeManifest.entries)) {
        $relativePath = [string]$entry.relativePath
        $kind = [string]$entry.kind
        if (-not $seen.Add($relativePath)) {
            throw "safe-delete plan leafStreamSetV1 relativePath 重复：$relativePath"
        }
        $absolutePath = ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath `
            -TreePath $TargetPath `
            -RelativePath $relativePath `
            -Scope 'safe-delete plan leafStreamSetV1'
        $capture = Get-CodexSafeTreeDeleteLeafStreamSet -LiteralPath $absolutePath
        $capturedKind = if ([bool]$capture.IsReparsePoint) {
            'directory-junction'
        } elseif ([bool]$capture.IsDirectory) {
            'directory'
        } else {
            'file'
        }
        if ($capturedKind -cne $kind) {
            throw "safe-delete plan leafStreamSetV1 leaf kind 漂移：$relativePath"
        }
        $streamNames = [string[]]@($capture.StreamNames)
        if ($kind -ceq 'file' -and
            -not ($streamNames.Count -eq 1 -and $streamNames[0] -ceq '::$DATA')) {
            throw "safe-delete plan leafStreamSetV1 file leaf 不得携带命名流：$relativePath"
        }
        if ($kind -ceq 'directory-junction' -and $streamNames.Count -ne 0) {
            throw "safe-delete plan leafStreamSetV1 junction leaf 不得携带命名流：$relativePath"
        }
        $leaves.Add([pscustomobject][ordered]@{
            relativePath = $relativePath
            kind = $kind
            streamNames = @($streamNames)
            hardLinkCount = [long]$capture.NumberOfLinks
        })
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        consumptionBoundary = [pscustomobject][ordered]@{
            apply = 'apply-locked-preflight'
            purge = 'purge-locked-preflight'
            streamDrift = 'fail-closed'
            leafDrift = 'fail-closed'
            requiresTreeManifestReverification = 'always'
        }
        leaves = @($leaves)
    }
}

# #56 Wave A：Plan 阶段 C# 单遍 walker 的 PowerShell 包装与捕获派生器。
# 合同：manifest 形状、metrics 事件回放、fail-closed 消息与三遍 PowerShell 路径逐字对齐；
# 依据 docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md §4。
function Get-CodexSafeTreeDeletePlanTreeSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [switch]$AllowHardLinks,
        [switch]$AllowInternalDirectoryJunctions,
        [string]$InternalDirectoryJunctionTargetRoot,
        [scriptblock]$MetricsObserver,
        [scriptblock]$PlanWalkerCheckpointForTest,
        [string]$Name = 'safe-delete plan snapshot'
    )

    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Name
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Name capability root"
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

    # C# walker 的 .NET 异常解包后以 PS 字符串错误抛出，保持与 PowerShell 走树
    # 相同的错误消息形态（否则 PS 会包一层 MethodException 调用上下文）。
    try {
        if ($null -ne $PlanWalkerCheckpointForTest) {
            # 库层测试入口（plan §4.1）：checkpoint 异常不吞；生产 CLI 不透传该参数。
            $checkpointAction = [Action[string, CodexSafeTreeDelete.PlanWalkerCheckpointEvent]]{
                param([string]$checkpointKind, [CodexSafeTreeDelete.PlanWalkerCheckpointEvent]$event)
                & $PlanWalkerCheckpointForTest $checkpointKind $event
            }
            $native = [CodexSafeTreeDelete.PlanTreeSnapshotBuilder]::BuildForTest(
                [string]$fullPath,
                [string]$capabilityRootPath,
                [bool]$AllowHardLinks.IsPresent,
                [bool]$AllowInternalDirectoryJunctions.IsPresent,
                [string]$InternalDirectoryJunctionTargetRoot,
                $checkpointAction)
        } else {
            $native = [CodexSafeTreeDelete.PlanTreeSnapshotBuilder]::Build(
                [string]$fullPath,
                [string]$capabilityRootPath,
                [bool]$AllowHardLinks.IsPresent,
                [bool]$AllowInternalDirectoryJunctions.IsPresent,
                [string]$InternalDirectoryJunctionTargetRoot)
        }
    } catch {
        $walkerMessage = [string]$_.Exception.Message
        if ($null -ne $_.Exception.InnerException -and
            -not [string]::IsNullOrWhiteSpace([string]$_.Exception.InnerException.Message)) {
            $walkerMessage = [string]$_.Exception.InnerException.Message
        }
        throw $walkerMessage
    }
    $entries = [Collections.Generic.List[object]]::new()
    $captures = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($native.Entries)) {
        $kind = [string]$entry.Kind
        $entries.Add([pscustomobject][ordered]@{
            relativePath = [string]$entry.RelativePath
            kind = $kind
            sha256 = $(if ($kind -ceq 'directory') { $null } else { [string]$entry.Sha256Hex })
            identity = @([string]$entry.VolumeSerialNumber, [string]$entry.FileIndex)
        })
        $captures.Add($entry)
        if ($null -ne $MetricsObserver) {
            & $MetricsObserver $kind ([long]$entry.LogicalBytes) ([long]$entry.HashedBytes)
        }
    }

    return [pscustomobject][ordered]@{
        manifest = [pscustomobject][ordered]@{
            schemaVersion = 2
            rootIdentity = @([string]$native.RootVolumeSerialNumber, [string]$native.RootFileIndex)
            entries = @($entries)
        }
        captures = @($captures)
        timings = $native.Timings
    }
}

function New-CodexSafeTreeDeletePlanFileIdentitiesV2FromCaptures {
    param(
        [Parameter(Mandatory)][object]$Captures,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $records = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Captures)) {
        if ([string]$entry.Kind -cne 'file') { continue }
        $relativePath = [string]$entry.RelativePath
        if (-not $seen.Add($relativePath)) {
            throw "safe-delete plan fileIdentitiesV2 relativePath 重复：$relativePath"
        }
        [void](ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
            -TargetPath $TargetPath `
            -RelativePath $relativePath)
        $records.Add((
            ConvertTo-CodexSafeTreeDeleteFileIdentityV2Record `
                -RelativePath $relativePath `
                -Identity $entry.IdentityV2
        ))
    }
    return $records
}

function New-CodexSafeTreeDeletePlanLeafStreamSetFromCaptures {
    param(
        [Parameter(Mandatory)][object]$Captures,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $leaves = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Captures)) {
        $relativePath = [string]$entry.RelativePath
        $kind = [string]$entry.Kind
        if (-not $seen.Add($relativePath)) {
            throw "safe-delete plan leafStreamSetV1 relativePath 重复：$relativePath"
        }
        [void](ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath `
            -TreePath $TargetPath `
            -RelativePath $relativePath `
            -Scope 'safe-delete plan leafStreamSetV1')
        $capturedKind = [string]$entry.CapturedKind
        if ($capturedKind -cne $kind) {
            throw "safe-delete plan leafStreamSetV1 leaf kind 漂移：$relativePath"
        }
        $streamNames = [string[]]@($entry.StreamNames)
        if ($kind -ceq 'file' -and
            -not ($streamNames.Count -eq 1 -and $streamNames[0] -ceq '::$DATA')) {
            throw "safe-delete plan leafStreamSetV1 file leaf 不得携带命名流：$relativePath"
        }
        if ($kind -ceq 'directory-junction' -and $streamNames.Count -ne 0) {
            throw "safe-delete plan leafStreamSetV1 junction leaf 不得携带命名流：$relativePath"
        }
        $leaves.Add([pscustomobject][ordered]@{
            relativePath = $relativePath
            kind = $kind
            streamNames = @($streamNames)
            hardLinkCount = [long]$entry.NumberOfLinks
        })
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        consumptionBoundary = [pscustomobject][ordered]@{
            apply = 'apply-locked-preflight'
            purge = 'purge-locked-preflight'
            streamDrift = 'fail-closed'
            leafDrift = 'fail-closed'
            requiresTreeManifestReverification = 'always'
        }
        leaves = @($leaves)
    }
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
    $allowed = $required + @('fileIdentitiesV2', 'leafStreamSetV1')
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

function Get-CodexSafeTreeDeletePathDepthWithin {
    # 与 Resolve-CodexSafeTreeDeleteTarget 同一深度口径：root 之后的非空路径段数。
    # 调用方保证 Path 位于 Root 之内（Test-CodexHookPathWithin）；两端的尾随分隔符不计段。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $trimmedRoot = $Root.TrimEnd('\', '/')
    $trimmedPath = $Path.TrimEnd('\', '/')
    if ($trimmedPath.Length -le $trimmedRoot.Length) { return 0L }
    $relative = $trimmedPath.Substring($trimmedRoot.Length).TrimStart('\', '/')
    return [long]@($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 }).Count
}

function Get-CodexSafeTreeDeletePolicyStructureViolations {
    # spec #73「加载器结构规则」的唯一实现。Lint 的结构部分直接调用；#84 让加载器调用同一函数并 fail-closed。
    # Entries：已规范化的条目（id、capabilityRoot、minimumDescendantDepth、deniedExactPaths；路径已过
    # Assert-CodexHookDPath）。纯字符串运算，不访问文件系统，不抛错。
    # 返回 violations（rule、entryId、denyIndex、detail；detail 不含路径）与 nestedRoots（parentEntryId、
    # childEntryId、covered：每一对严格嵌套的 root，以及父条目是否有 deny 精确等于子 root）。
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)

    $violations = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Entries)) {
        $root = [string]$entry.capabilityRoot
        $minimumDepth = [long]$entry.minimumDescendantDepth
        $denied = @($entry.deniedExactPaths)
        for ($denyIndex = 0; $denyIndex -lt $denied.Count; $denyIndex++) {
            $deniedPath = [string]$denied[$denyIndex]
            # 越界 deny 由加载器的既有约束拒绝，不在这里重复判断深度。
            if (-not (Test-CodexHookPathWithin -Path $deniedPath -ParentPath $root)) { continue }
            # 规则 1：deny 只拦截「等于它或位于它之内」的目标；比最小后代深度更深的 deny，
            # 可以通过删它的祖先目录绕过。
            $denyDepth = Get-CodexSafeTreeDeletePathDepthWithin -Path $deniedPath -Root $root
            if ($denyDepth -gt $minimumDepth) {
                $violations.Add([pscustomobject][ordered]@{
                    rule = 'deny-deeper-than-minimum-depth'
                    entryId = [string]$entry.id
                    denyIndex = [long]$denyIndex
                    detail = "deny 深度 $denyDepth 大于最小后代深度 $minimumDepth。"
                })
            }
        }
        # 规则 2：深度 0 的条目允许删除 root 本身，任何 deny 都会随 root 一起被删掉。
        if ($minimumDepth -eq 0) {
            for ($denyIndex = 0; $denyIndex -lt $denied.Count; $denyIndex++) {
                $violations.Add([pscustomobject][ordered]@{
                    rule = 'deny-on-depth-zero-entry'
                    entryId = [string]$entry.id
                    denyIndex = [long]$denyIndex
                    detail = '最小后代深度为 0 的条目不得带 deny。'
                })
            }
        }
    }

    # 规则 3：条目按 CapabilityRoot 精确匹配选择，子 root 若没有被父条目的 deny 精确覆盖，传入父 root
    # 就能绕过子条目更严格的约束。按字面对所有「严格位于另一条 root 之内」的组合检查（含多级嵌套）；
    # 相等的 root 是重复 root，由既有加载约束报告。路径比较大小写不敏感、忽略尾随分隔符。
    $nestedRoots = [Collections.Generic.List[object]]::new()
    $entryList = @($Entries)
    foreach ($parent in $entryList) {
        $parentRoot = [string]$parent.capabilityRoot
        foreach ($child in $entryList) {
            $childRoot = [string]$child.capabilityRoot
            if ([StringComparer]::OrdinalIgnoreCase.Equals($parentRoot.TrimEnd('\', '/'), $childRoot.TrimEnd('\', '/')) -or
                -not (Test-CodexHookPathWithin -Path $childRoot -ParentPath $parentRoot)) {
                continue
            }
            $covered = @(@($parent.deniedExactPaths) | Where-Object {
                    [StringComparer]::OrdinalIgnoreCase.Equals(([string]$_).TrimEnd('\', '/'), $childRoot.TrimEnd('\', '/'))
                }).Count -gt 0
            $nestedRoots.Add([pscustomobject][ordered]@{
                parentEntryId = [string]$parent.id
                childEntryId = [string]$child.id
                covered = $covered
            })
            if (-not $covered) {
                $violations.Add([pscustomobject][ordered]@{
                    rule = 'nested-root-not-denied'
                    entryId = [string]$parent.id
                    denyIndex = $null
                    detail = "子条目 $([string]$child.id) 的 root 严格位于本条目 root 之内，但本条目没有 deny 精确等于它。"
                })
            }
        }
    }

    return [pscustomobject][ordered]@{
        violations = $violations.ToArray()
        nestedRoots = $nestedRoots.ToArray()
    }
}

function Get-CodexSafeTreeDeleteLintJsonProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    # 原文可能任意畸形：属性缺失时返回 $null，不受 StrictMode 的属性访问异常影响。
    # 逗号保住 JSON array 原样（单元素数组不被管道展开成元素本身）。
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return , $property.Value
}

function Get-CodexSafeTreeDeletePolicyEntryOwner {
    # owner 由 capability root 按固定前缀推导，不写入 policy、不改 schema；越具体的前缀越先匹配。
    # 推导不出的记为 host 级，不做 owner 检查。levelsAboveRoot：owner 在 root 之上几级（0 为 root 本身）。
    param([Parameter(Mandatory)][string]$CapabilityRoot)

    $root = $CapabilityRoot.TrimEnd('\', '/')
    foreach ($rule in @(
            [pscustomobject]@{ kind = 'worktree'; prefix = 'D:\agents\worktrees\prd-210\' },
            [pscustomobject]@{ kind = 'worktree'; prefix = 'D:\agents\worktrees\' },
            [pscustomobject]@{ kind = 'project'; prefix = 'D:\agents\projects\' },
            [pscustomobject]@{ kind = 'project'; prefix = 'D:\Codex\projects\' })) {
        if (-not $root.StartsWith([string]$rule.prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $segments = @($root.Substring(([string]$rule.prefix).Length) -split '[\\/]' | Where-Object { $_.Length -gt 0 })
        if ($segments.Count -eq 0) { continue }
        return [pscustomobject][ordered]@{
            kind = [string]$rule.kind
            path = [string]$rule.prefix + $segments[0]
            levelsAboveRoot = [long]($segments.Count - 1)
        }
    }
    return [pscustomobject][ordered]@{ kind = 'host'; path = $null; levelsAboveRoot = $null }
}

function Get-CodexSafeTreeDeleteLintEvidenceLayout {
    # 只读枚举已校验的 evidence 根：不读文件内容，不跟随 reparse point（计入非 run 顶层目录，但不进入）。
    # run 目录：顶层、非 reparse、名字为 producer run id（UTC 时间戳-generationId）的目录。
    # 规范位置：<evidence 根>\<顶层目录>\transaction.json，与 BatchPurge 历史扫描 C# 预筛的规范位置同口径
    # （预筛的 historyScan.canonicalFiles 另要求 producer 规范形态且读取、解析成功）；
    # 其余位置的 transaction.json 计入非规范，位置按「最近的 run 祖先」描述，不回显非 run 目录名。
    param([Parameter(Mandatory)][string]$FullEvidenceRoot)

    $runNamePattern = '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $rootPrefix = $FullEvidenceRoot.TrimEnd('\', '/')
    $rootInfo = [IO.DirectoryInfo]::new($FullEvidenceRoot)
    $runDirectories = 0L
    $nonRunTopLevelDirectories = 0L
    foreach ($topLevel in $rootInfo.EnumerateDirectories()) {
        $isReparsePoint = ($topLevel.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if (-not $isReparsePoint -and $topLevel.Name -cmatch $runNamePattern) {
            $runDirectories++
        } else {
            $nonRunTopLevelDirectories++
        }
    }

    $transactionFiles = 0L
    $nonCanonical = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($rootInfo)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($file in $directory.EnumerateFiles()) {
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($file.Name, 'transaction.json')) { continue }
            $transactionFiles++
            $relative = $file.FullName.Substring($rootPrefix.Length).TrimStart('\', '/')
            $segments = @($relative.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries))
            if ($segments.Count -eq 2) { continue }
            # 最近的 run 祖先：从文件所在目录往上找名字为 run id 的段。
            $runSegmentIndex = -1
            for ($index = $segments.Count - 2; $index -ge 0; $index--) {
                if ($segments[$index] -cmatch $runNamePattern) {
                    $runSegmentIndex = $index
                    break
                }
            }
            if ($runSegmentIndex -ge 0) {
                $detail = "位于 run 目录 $($segments[$runSegmentIndex]) 内第 $($segments.Count - 1 - $runSegmentIndex) 层"
                if ($runSegmentIndex -gt 0) { $detail += "；该 run 目录位于 evidence 根下第 $($runSegmentIndex + 1) 层" }
                $detail += '。'
            } else {
                $detail = "不在任何 run 目录内，位于 evidence 根下第 $($segments.Count) 层。"
            }
            $nonCanonical.Add([pscustomobject][ordered]@{ relativePath = $relative; detail = $detail })
        }
        foreach ($child in $directory.EnumerateDirectories()) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $pending.Push($child)
        }
    }

    # 按相对路径 Ordinal 排序，结果与宿主区域设置无关。
    $nonCanonicalItems = $nonCanonical.ToArray()
    [string[]]$sortKeys = @($nonCanonicalItems | ForEach-Object { [string]$_.relativePath })
    [Array]::Sort($sortKeys, $nonCanonicalItems, [StringComparer]::Ordinal)

    return [pscustomobject][ordered]@{
        runDirectories = $runDirectories
        nonRunTopLevelDirectories = $nonRunTopLevelDirectories
        transactionFiles = $transactionFiles
        nonCanonicalTransactions = $nonCanonicalItems
    }
}

function ConvertTo-CodexSafeTreeDeleteLintRedactedText {
    # 加载器与宿主库的错误信息把出错的值接在全角冒号之后（例如 Assert-CodexHookDPath），Lint 只转述冒号前的
    # 规则含义；残留的盘符路径（.NET 异常文本等）一律替换为 <path>，结果不回显任何 policy 路径。
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $cut = $Text.IndexOf([char]0xFF1A)
    if ($cut -ge 0) { $Text = $Text.Substring(0, $cut) }
    return ($Text -replace '(?i)(?<![a-z0-9])[a-z]:[\\/][^\s''"，。；]*', '<path>').Trim()
}

function ConvertTo-CodexSafeTreeDeleteLintEntry {
    # 把一条原文条目规范成结构规则的输入。字段类型、id、深度与路径校验与加载器同口径；任何一项
    # 不合规都返回 $null，该条目不参与结构规则，由加载器裁决（policy-load-refused）报告。
    param([AllowNull()][object]$RawEntry)

    $id = Get-CodexSafeTreeDeleteLintJsonProperty -Object $RawEntry -Name 'id'
    $capabilityRoot = Get-CodexSafeTreeDeleteLintJsonProperty -Object $RawEntry -Name 'capabilityRoot'
    $minimumDepth = Get-CodexSafeTreeDeleteLintJsonProperty -Object $RawEntry -Name 'minimumDescendantDepth'
    $deniedExactPaths = Get-CodexSafeTreeDeleteLintJsonProperty -Object $RawEntry -Name 'deniedExactPaths'
    if ($id -isnot [string] -or $id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or
        $minimumDepth -isnot [long] -or [long]$minimumDepth -lt 0 -or [long]$minimumDepth -gt 16 -or
        $deniedExactPaths -isnot [Array]) {
        return $null
    }
    $denied = [Collections.Generic.List[string]]::new()
    try {
        $root = Assert-CodexHookDPath -Value $capabilityRoot -Name 'safe-delete lint root'
        foreach ($candidate in @($deniedExactPaths)) {
            $deniedPath = Assert-CodexHookDPath -Value $candidate -Name 'safe-delete lint denied path'
            if (-not (Test-CodexHookPathWithin -Path $deniedPath -ParentPath $root)) { return $null }
            $denied.Add($deniedPath)
        }
    } catch {
        return $null
    }

    return [pscustomobject][ordered]@{
        id = [string]$id
        capabilityRoot = $root
        minimumDescendantDepth = [long]$minimumDepth
        deniedExactPaths = $denied.ToArray()
    }
}

function Invoke-CodexSafeTreeDeleteLint {
    # Lint mode（#79，spec #73「实现决策 › Lint 模式」）：只读体检，只报告、不拦截。
    # 结构问题记 error，宿主漂移与 evidence 布局问题记 warning；不写 evidence、不创建 evidence 根、
    # 不改 policy。结果以 JSON 表达，没有 refusalReason，所以入口退出码恒按既有 JSON 约定为 0。
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $fullPolicyPath = Assert-CodexHookDPath -Value $PolicyPath -Name 'safe-delete lint policy path'
    $fullEvidenceRoot = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'safe-delete lint evidence root'
    $findings = [Collections.Generic.List[object]]::new()

    # 加载器在第一条违例处抛错；Lint 另读一次原文，才能在 policy 不可加载时仍逐条报告。
    $rawSha256 = $null
    $rawDocument = $null
    try {
        $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $fullPolicyPath `
            -Name 'safe-delete lint policy' `
            -AllowedExactPaths @($fullPolicyPath)
        $rawSha256 = [string]$snapshot.sha256
        Assert-CodexHookStrictJsonText -JsonText $snapshot.text
        $rawDocument = $snapshot.text | ConvertFrom-Json -Depth 32 -ErrorAction Stop
    } catch {
        $rawDocument = $null
    }
    $loadedPolicy = $null
    $loadRefusal = $null
    try {
        $loadedPolicy = Read-CodexSafeTreeDeletePolicy -PolicyPath $fullPolicyPath
    } catch {
        $loadedPolicy = $null
        $loadRefusal = $_.Exception.Message
    }
    if ($null -ne $loadedPolicy -and [string]$loadedPolicy.sha256 -cne [string]$rawSha256) {
        throw 'safe-delete lint：policy 在读取期间发生变化。'
    }
    if ($null -eq $loadedPolicy) {
        # 现役加载器的裁决：覆盖其余全部既有加载约束（artifact、schema、属性集合、root 过宽、用途与路径
        # 形状等）。加载器在第一条违例处停下，所以下面另按条目逐条报告常见的几类。
        $findings.Add([pscustomobject][ordered]@{
            rule = 'policy-load-refused'
            severity = 'error'
            entryId = $null
            detail = ConvertTo-CodexSafeTreeDeleteLintRedactedText -Text $loadRefusal
        })
    }

    $rawEntries = Get-CodexSafeTreeDeleteLintJsonProperty -Object $rawDocument -Name 'entries'
    $rawEntryList = @()
    if ($rawEntries -is [Array]) { $rawEntryList = @($rawEntries) }
    $rawSchemaVersion = Get-CodexSafeTreeDeleteLintJsonProperty -Object $rawDocument -Name 'schemaVersion'

    # 既有加载约束，逐条报告：重复 id（Ordinal）、重复 root（规范化后大小写不敏感）、深度 0 未声明用途。
    # entryId 只用通过加载器 id 规则的值；其余条目以 entries 序号指代，不回显原文。
    $firstIndexById = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $firstIndexByRoot = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    $entryIds = [Collections.Generic.List[object]]::new()
    for ($entryIndex = 0; $entryIndex -lt $rawEntryList.Count; $entryIndex++) {
        $rawEntry = $rawEntryList[$entryIndex]
        $rawId = Get-CodexSafeTreeDeleteLintJsonProperty -Object $rawEntry -Name 'id'
        $entryId = $null
        if ($rawId -is [string] -and $rawId -match '^[a-z0-9][a-z0-9-]{0,63}$') { $entryId = [string]$rawId }
        $entryIds.Add($entryId)
        if ($null -ne $entryId) {
            if ($firstIndexById.ContainsKey($entryId)) {
                $findings.Add([pscustomobject][ordered]@{
                    rule = 'duplicate-entry-id'
                    severity = 'error'
                    entryId = $entryId
                    detail = "entries[$entryIndex] 的 id 与 entries[$($firstIndexById[$entryId])] 重复。"
                })
            } else {
                $firstIndexById[$entryId] = $entryIndex
            }
        }
        $canonicalRoot = $null
        try {
            $canonicalRoot = Assert-CodexHookDPath `
                -Value (Get-CodexSafeTreeDeleteLintJsonProperty -Object $rawEntry -Name 'capabilityRoot') `
                -Name 'safe-delete lint root'
        } catch {
            $canonicalRoot = $null
        }
        if ($null -ne $canonicalRoot) {
            if ($firstIndexByRoot.ContainsKey($canonicalRoot)) {
                $firstIndex = $firstIndexByRoot[$canonicalRoot]
                $firstLabel = if ($null -ne $entryIds[$firstIndex]) { [string]$entryIds[$firstIndex] } else { "entries[$firstIndex]" }
                $findings.Add([pscustomobject][ordered]@{
                    rule = 'duplicate-capability-root'
                    severity = 'error'
                    entryId = $entryId
                    detail = "entries[$entryIndex] 的 capabilityRoot 与条目 $firstLabel 重复（大小写不敏感）。"
                })
            } else {
                $firstIndexByRoot[$canonicalRoot] = $entryIndex
            }
        }
        $rawDepth = Get-CodexSafeTreeDeleteLintJsonProperty -Object $rawEntry -Name 'minimumDescendantDepth'
        $rawPurpose = Get-CodexSafeTreeDeleteLintJsonProperty -Object $rawEntry -Name 'rootDeletionPurpose'
        if ($rawDepth -is [long] -and [long]$rawDepth -eq 0 -and
            ($rawPurpose -isnot [string] -or
                [string]$rawPurpose -cnotin @('rebuildable-build-output', 'empty-project-state', 'retired-project-root', 'retired-evidence-root'))) {
            $findings.Add([pscustomobject][ordered]@{
                rule = 'depth-zero-purpose-required'
                severity = 'error'
                entryId = $entryId
                detail = "entries[$entryIndex] 最小后代深度为 0，必须声明 root 删除用途（rebuildable-build-output、empty-project-state、retired-project-root 或 retired-evidence-root）。"
            })
        }
    }

    # 结构规则：不依赖宿主，只看 policy 原文。
    $evaluableEntries = [Collections.Generic.List[object]]::new()
    foreach ($rawEntry in $rawEntryList) {
        $entry = ConvertTo-CodexSafeTreeDeleteLintEntry -RawEntry $rawEntry
        if ($null -ne $entry) { $evaluableEntries.Add($entry) }
    }
    $structure = Get-CodexSafeTreeDeletePolicyStructureViolations -Entries $evaluableEntries.ToArray()
    foreach ($violation in @($structure.violations)) {
        $finding = [ordered]@{
            rule = [string]$violation.rule
            severity = 'error'
            entryId = [string]$violation.entryId
        }
        if ($null -ne $violation.denyIndex) { $finding.denyIndex = [long]$violation.denyIndex }
        $finding.detail = [string]$violation.detail
        $findings.Add([pscustomobject]$finding)
    }

    # 宿主规则：只读的存在性检查，全部记 warning。deny 类发现只给条目 id 与 deny 序号，不回显路径。
    foreach ($entry in $evaluableEntries) {
        $root = [string]$entry.capabilityRoot
        if (-not [IO.Directory]::Exists($root)) {
            $findings.Add([pscustomobject][ordered]@{
                rule = 'root-missing'
                severity = 'warning'
                entryId = [string]$entry.id
                detail = if ([IO.File]::Exists($root)) { 'capability root 是文件，不是目录。' } else { 'capability root 不存在。' }
            })
        }
        $owner = Get-CodexSafeTreeDeletePolicyEntryOwner -CapabilityRoot $root
        if ($null -ne $owner.path -and -not [IO.Directory]::Exists([string]$owner.path)) {
            $position = if ([long]$owner.levelsAboveRoot -eq 0) { '即 root 本身' } else { "root 之上第 $($owner.levelsAboveRoot) 级目录" }
            $findings.Add([pscustomobject][ordered]@{
                rule = 'owner-missing'
                severity = 'warning'
                entryId = [string]$entry.id
                detail = "推导出的 $($owner.kind) owner（$position）不存在。"
            })
        }
        $denied = @($entry.deniedExactPaths)
        for ($denyIndex = 0; $denyIndex -lt $denied.Count; $denyIndex++) {
            $deniedPath = [string]$denied[$denyIndex]
            if ([IO.File]::Exists($deniedPath)) {
                # 目标只能是现存普通目录，文件型 deny 拦不住任何删除，只说明 deny 写错了层级或对象。
                $findings.Add([pscustomobject][ordered]@{
                    rule = 'deny-target-is-file'
                    severity = 'warning'
                    entryId = [string]$entry.id
                    denyIndex = [long]$denyIndex
                    detail = 'deny 指向现存文件，不是目录。'
                })
            } elseif (-not [IO.Directory]::Exists($deniedPath)) {
                $findings.Add([pscustomobject][ordered]@{
                    rule = 'deny-target-missing'
                    severity = 'warning'
                    entryId = [string]$entry.id
                    denyIndex = [long]$denyIndex
                    detail = 'deny 指向的路径不存在。'
                })
            }
        }
    }

    # evidence 布局：根不存在时只报告，不创建（不调用 Initialize-CodexSafeTreeDeleteEvidenceRoot）；
    # 存在时与 Status 同一套只读校验（D 盘、无 reparse 祖先）后再枚举。
    $evidenceExists = [IO.Directory]::Exists($fullEvidenceRoot)
    $layout = [pscustomobject][ordered]@{
        runDirectories = 0L
        nonRunTopLevelDirectories = 0L
        transactionFiles = 0L
        nonCanonicalTransactions = @()
    }
    if ($evidenceExists) {
        [void](Assert-CodexHookCapabilityPath `
            -Path $fullEvidenceRoot `
            -CapabilityRoot (Split-Path -Parent $fullEvidenceRoot) `
            -AllowedExactPaths @($fullEvidenceRoot) `
            -Name 'safe-delete lint evidence root')
        $layout = Get-CodexSafeTreeDeleteLintEvidenceLayout -FullEvidenceRoot $fullEvidenceRoot
    } else {
        $findings.Add([pscustomobject][ordered]@{
            rule = 'evidence-root-missing'
            severity = 'warning'
            entryId = $null
            detail = 'evidence 根不存在（Lint 不创建它）。'
        })
    }
    foreach ($nonCanonical in @($layout.nonCanonicalTransactions)) {
        $findings.Add([pscustomobject][ordered]@{
            rule = 'evidence-noncanonical-transaction'
            severity = 'warning'
            entryId = $null
            detail = [string]$nonCanonical.detail
        })
    }
    if ([long]$layout.nonRunTopLevelDirectories -gt 0) {
        $findings.Add([pscustomobject][ordered]@{
            rule = 'evidence-non-run-top-level-directories'
            severity = 'warning'
            entryId = $null
            detail = "evidence 根下有 $($layout.nonRunTopLevelDirectories) 个顶层目录不是 run 目录。"
        })
    }

    return [pscustomobject][ordered]@{
        errorCount = @($findings | Where-Object { [string]$_.severity -ceq 'error' }).Count
        warningCount = @($findings | Where-Object { [string]$_.severity -ceq 'warning' }).Count
        policy = [pscustomobject][ordered]@{
            path = $fullPolicyPath
            sha256 = $rawSha256
            schemaVersion = if ($rawSchemaVersion -is [long]) { [long]$rawSchemaVersion } else { $null }
            entryCount = $rawEntryList.Count
            evaluatedEntryCount = $evaluableEntries.Count
            loadable = $null -ne $loadedPolicy
        }
        evidence = [pscustomobject][ordered]@{
            root = $fullEvidenceRoot
            exists = $evidenceExists
            runDirectories = [long]$layout.runDirectories
            nonRunTopLevelDirectories = [long]$layout.nonRunTopLevelDirectories
            transactionFiles = [long]$layout.transactionFiles
            nonCanonicalTransactionFiles = [long]@($layout.nonCanonicalTransactions).Count
        }
        nestedRoots = @($structure.nestedRoots)
        findings = $findings.ToArray()
    }
}

function Read-CodexSafeTreeDeletePolicy {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$PolicyPath,
        # #82 policy 维护工具的候选只在内存里（DryRun 不落盘）：与磁盘 policy 同一套严格 UTF-8 解码与
        # 校验，SHA-256 按原始字节计算；结果的 path 为 $null。
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][AllowEmptyCollection()][byte[]]$PolicyBytes,
        [scriptblock]$MetricsObserver
    )

    if ($PSCmdlet.ParameterSetName -ceq 'Bytes') {
        $fullPolicyPath = $null
        $snapshot = [pscustomobject]@{
            sha256 = Get-CodexHookBytesSha256 -Bytes $PolicyBytes
            text = ConvertFrom-CodexHookStrictUtf8Bytes -Bytes $PolicyBytes -Name 'safe-delete policy'
            bytes = $PolicyBytes
        }
    } else {
        $fullPolicyPath = Assert-CodexHookDPath -Value $PolicyPath -Name 'safe-delete policy path'
        $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $fullPolicyPath `
            -Name 'safe-delete policy' `
            -AllowedExactPaths @($fullPolicyPath)
    }
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
        if ($root -in @('D:\', 'D:\Codex', 'D:\Codex\.codex', 'D:\Codex\projects', 'D:\agents', 'D:\agents\projects')) {
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
        if ($rootDeletionPurpose -notin @('none', 'rebuildable-build-output', 'empty-project-state', 'retired-project-root', 'retired-evidence-root')) {
            throw "safe-delete policy $id rootDeletionPurpose 非法。"
        }
        if ($minimumDepth -eq 0 -and
            $rootDeletionPurpose -cnotin @('rebuildable-build-output', 'empty-project-state', 'retired-project-root', 'retired-evidence-root')) {
            throw "safe-delete policy $id 深度 0 必须显式限定 root 删除用途。"
        }
        if ($minimumDepth -gt 0 -and $rootDeletionPurpose -cne 'none') {
            throw "safe-delete policy $id 非 root 删除条目的 purpose 必须为 none。"
        }
        if ($rootDeletionPurpose -ceq 'rebuildable-build-output' -and
            $root -notmatch '^D:\\(Codex|agents)\\projects\\[^\\]+\\.+$' -and
            $root -notmatch '^D:\\agents\\worktrees\\prd-210\\[^\\]+\\.+$') {
            throw "safe-delete policy $id 可重建构建产物必须位于项目根之下。"
        }
        if ($rootDeletionPurpose -ceq 'rebuildable-build-output' -and
            $root -match '^D:\\(Codex|agents)\\projects\\[^\\]+\\\.codex$') {
            throw "safe-delete policy $id 项目 .codex 不得声明为可重建构建产物。"
        }
        if ($rootDeletionPurpose -ceq 'empty-project-state' -and
            $root -notmatch '^D:\\(Codex|agents)\\projects\\[^\\]+\\\.codex$') {
            throw "safe-delete policy $id 空项目状态必须精确指向项目 .codex 根。"
        }
        if ($rootDeletionPurpose -ceq 'retired-project-root' -and
            $root -notmatch '^D:\\(Codex|agents)\\projects\\[^\\]+$') {
            throw "safe-delete policy $id 退役项目必须精确指向项目根。"
        }
        if ($rootDeletionPurpose -ceq 'retired-evidence-root') {
            if ($root -notmatch '(?i)\\run-evidence(?:-analog)?\\[^\\]+$') {
                throw "safe-delete policy $id 退役证据目录必须是 run-evidence 父根下的明确一级目录。"
            }
            if ($root -match '(?i)\\run-evidence(?:-analog)?\\safe-tree-delete$') {
                throw "safe-delete policy $id 不得把 safe-tree-delete evidence 根登记为退役证据目录。"
            }
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

function Set-CodexSafeTreeDeleteTargetRefusal {
    param(
        [Parameter(Mandatory)][object]$Decision,
        [Parameter(Mandatory)][string]$Reason,
        # 自有规则传拒绝原文；host-safety 断言抛出的拒绝传其 ErrorRecord，留给 Resolve 原样重抛。
        [Parameter(Mandatory)][object]$Refusal
    )

    $Decision.refusalReason = $Reason
    if ($Refusal -is [Management.Automation.ErrorRecord]) {
        $Decision.refusalErrorRecord = $Refusal
        $Decision.refusalMessage = [string]$Refusal.Exception.Message
    } else {
        $Decision.refusalMessage = [string]$Refusal
    }
    return $Decision
}

function Get-CodexSafeTreeDeleteTargetDecision {
    # Plan（经 Resolve-CodexSafeTreeDeleteTarget）与 Check 共用的目标解析判定，规则只在这里维护。
    # 按固定顺序逐条校验，第一条不通过的规则给出稳定的 refusalReason 和 Plan 会抛出的拒绝原文；不抛出
    # 拒绝，也不读写 evidence，只查询目标路径自身及其祖先的文件系统属性。depth 在通过 root 包含与
    # 两项精确 root 校验后才计算，此前拒绝的判定 depth 为 $null。
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][object]$Policy,
        [bool]$RequireExisting = $true
    )

    $decision = [pscustomobject][ordered]@{
        allowed = $false
        refusalReason = $null
        refusalMessage = $null
        refusalErrorRecord = $null
        targetPath = $TargetPath
        capabilityRoot = $CapabilityRoot
        depth = $null
        entry = $null
    }
    try {
        $fullTarget = Assert-CodexHookDPath -Value $TargetPath -Name 'safe-delete target'
    } catch {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision -Reason 'invalid-target-path' -Refusal $_
    }
    $decision.targetPath = $fullTarget
    try {
        $fullRoot = Assert-CodexHookDPath -Value $CapabilityRoot -Name 'safe-delete capability root'
    } catch {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision -Reason 'invalid-capability-root' -Refusal $_
    }
    $decision.capabilityRoot = $fullRoot
    $entry = @($Policy.entries | Where-Object {
        Test-CodexSafeTreeDeletePathEqual -Left ([string]$_.capabilityRoot) -Right $fullRoot
    })
    if ($entry.Count -ne 1) {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision `
            -Reason 'capability-root-not-allowlisted' `
            -Refusal 'safe-delete capability root 不在受管 allowlist。'
    }
    $decision.entry = $entry[0]
    if (-not (Test-CodexHookPathWithin -Path $fullTarget -ParentPath $fullRoot)) {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision `
            -Reason 'target-outside-capability-root' `
            -Refusal 'safe-delete target 必须位于 capability root 内。'
    }
    if ([string]$entry[0].rootDeletionPurpose -cin @('empty-project-state', 'retired-project-root', 'retired-evidence-root') -and
        -not (Test-CodexSafeTreeDeletePathEqual -Left $fullTarget -Right $fullRoot)) {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision `
            -Reason 'root-deletion-requires-exact-root' `
            -Refusal 'safe-delete root 删除用途只允许精确 capability root。'
    }
    if (([bool]$entry[0].allowHardLinks -or [bool]$entry[0].allowInternalDirectoryJunctions) -and
        -not (Test-CodexSafeTreeDeletePathEqual -Left $fullTarget -Right $fullRoot)) {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision `
            -Reason 'link-aware-requires-exact-root' `
            -Refusal 'safe-delete link-aware 能力只允许精确 capability root。'
    }
    $relative = $fullTarget.Substring($fullRoot.Length).TrimStart('\', '/')
    $decision.depth = @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 }).Count
    if ($decision.depth -lt [int]$entry[0].minimumDescendantDepth) {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision `
            -Reason 'below-minimum-depth' `
            -Refusal 'safe-delete target 未达到策略要求的最小后代深度。'
    }
    foreach ($deniedPath in @($entry[0].deniedExactPaths)) {
        if ((Test-CodexSafeTreeDeletePathEqual -Left $fullTarget -Right $deniedPath) -or
            (Test-CodexHookPathWithin -Path $fullTarget -ParentPath $deniedPath)) {
            return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision `
                -Reason 'target-denied' `
                -Refusal 'safe-delete target 命中 denylist。'
        }
    }
    try {
        [void](Assert-CodexHookCapabilityPath `
            -Path $fullTarget `
            -CapabilityRoot $fullRoot `
            -AllowedExactPaths @($fullTarget) `
            -Name 'safe-delete target')
    } catch {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision -Reason 'capability-path-refused' -Refusal $_
    }
    if ($RequireExisting -and -not [IO.Directory]::Exists($fullTarget)) {
        return Set-CodexSafeTreeDeleteTargetRefusal -Decision $decision `
            -Reason 'target-not-existing-directory' `
            -Refusal 'safe-delete target 必须是现存普通目录。'
    }

    $decision.allowed = $true
    return $decision
}

function Resolve-CodexSafeTreeDeleteTarget {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][object]$Policy,
        [bool]$RequireExisting = $true
    )

    $decision = Get-CodexSafeTreeDeleteTargetDecision `
        -TargetPath $TargetPath `
        -CapabilityRoot $CapabilityRoot `
        -Policy $Policy `
        -RequireExisting $RequireExisting
    if (-not $decision.allowed) {
        # 原样重抛：自有规则抛拒绝原文，host-safety 断言抛原 ErrorRecord；消息、异常类型与错误标识都与
        # 判定拆出之前相同。
        if ($null -ne $decision.refusalErrorRecord) { throw $decision.refusalErrorRecord }
        throw $decision.refusalMessage
    }

    $entry = $decision.entry
    return [pscustomobject][ordered]@{
        targetPath = $decision.targetPath
        capabilityRoot = $decision.capabilityRoot
        policyEntryId = [string]$entry.id
        rootDeletionPurpose = [string]$entry.rootDeletionPurpose
        allowHardLinks = [bool]$entry.allowHardLinks
        allowInternalDirectoryJunctions = [bool]$entry.allowInternalDirectoryJunctions
        minimumQuarantineAgeMinutes = [long]$entry.minimumQuarantineAgeMinutes
        producerFenceMode = [string]$entry.producerFenceMode
        policySchemaVersion = [long]$Policy.schemaVersion
    }
}

function ConvertTo-CodexSafeTreeDeleteCheckRow {
    param([Parameter(Mandatory)][object]$Decision)

    return [pscustomobject][ordered]@{
        targetPath = [string]$Decision.targetPath
        allowed = [bool]$Decision.allowed
        policyEntryId = if ($null -ne $Decision.entry) { [string]$Decision.entry.id } else { $null }
        capabilityRoot = $Decision.capabilityRoot
        depth = $Decision.depth
        refusalReason = $Decision.refusalReason
        refusalMessage = $Decision.refusalMessage
    }
}

function Get-CodexSafeTreeDeleteCheckAutoRow {
    # 省略 CapabilityRoot 时的自动解析：对 policy 的每条条目运行同一判定，root 包含目标的条目是候选。
    # 候选中恰好一条放行才采用它；零条或多条都拒绝，并列出全部候选及各自的判定，不替调用方做授权选择。
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][object]$Policy
    )

    # 加载器保证 policy 至少一条条目、root 互不相同，所以每条条目的 root 都能通过 allowlist 查找。
    $candidates = [Collections.Generic.List[object]]::new()
    $canonicalTarget = $TargetPath
    foreach ($entry in @($Policy.entries)) {
        $decision = Get-CodexSafeTreeDeleteTargetDecision `
            -TargetPath $TargetPath `
            -CapabilityRoot ([string]$entry.capabilityRoot) `
            -Policy $Policy
        if ($decision.refusalReason -ceq 'invalid-target-path') {
            # 目标先于 root 校验，目标非法与选哪条 root 无关：给出与显式 root 相同的拒绝，不列候选。
            $decision.capabilityRoot = $null
            return ConvertTo-CodexSafeTreeDeleteCheckRow -Decision $decision
        }
        $canonicalTarget = $decision.targetPath
        if ($decision.refusalReason -cne 'target-outside-capability-root') { $candidates.Add($decision) }
    }

    $legal = @($candidates | Where-Object { $_.allowed })
    if ($legal.Count -eq 1) { return ConvertTo-CodexSafeTreeDeleteCheckRow -Decision $legal[0] }
    if ($legal.Count -eq 0) {
        $reason = 'no-capability-root'
        $message = 'safe-delete target 没有能合法覆盖它的 capability root。'
    } else {
        $reason = 'ambiguous-capability-root'
        $message = 'safe-delete target 有多条能合法覆盖它的 capability root，须显式指定 CapabilityRoot。'
    }
    return [pscustomobject][ordered]@{
        targetPath = [string]$canonicalTarget
        allowed = $false
        policyEntryId = $null
        capabilityRoot = $null
        depth = $null
        refusalReason = $reason
        refusalMessage = $message
        candidates = @($candidates | ForEach-Object {
                [pscustomobject][ordered]@{
                    policyEntryId = [string]$_.entry.id
                    capabilityRoot = [string]$_.capabilityRoot
                    allowed = [bool]$_.allowed
                    depth = $_.depth
                    refusalReason = $_.refusalReason
                    refusalMessage = $_.refusalMessage
                }
            })
    }
}

function Invoke-CodexSafeTreeDeleteCheck {
    # 只读预检：读 policy，对每个目标运行与 Plan 相同的目标解析判定（Get-CodexSafeTreeDeleteTargetDecision）；
    # 省略 CapabilityRoot 时按 Get-CodexSafeTreeDeleteCheckAutoRow 自动解析。不接收 evidence 根，因此不读
    # 历史、不写 evidence、不建 run 目录。
    param(
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath
    )

    $policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
    $results = [Collections.Generic.List[object]]::new()
    foreach ($targetPath in @($TargetPaths)) {
        if ([string]::IsNullOrWhiteSpace($CapabilityRoot)) {
            $results.Add((Get-CodexSafeTreeDeleteCheckAutoRow -TargetPath $targetPath -Policy $policy))
            continue
        }
        $decision = Get-CodexSafeTreeDeleteTargetDecision `
            -TargetPath $targetPath `
            -CapabilityRoot $CapabilityRoot `
            -Policy $policy
        $results.Add((ConvertTo-CodexSafeTreeDeleteCheckRow -Decision $decision))
    }

    return [pscustomobject][ordered]@{
        allowed = @($results | Where-Object { -not $_.allowed }).Count -eq 0
        targetCount = $results.Count
        results = $results.ToArray()
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

function Get-CodexSafeTreeDeleteFileSystemCapabilities {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [object]$FileSystemCapabilitiesForTest
    )

    if ($null -ne $FileSystemCapabilitiesForTest) {
        if ($FileSystemCapabilitiesForTest -isnot [CodexSafeTreeDelete.FileSystemCapabilities]) {
            throw 'safe-delete FileSystemCapabilitiesForTest 必须是 FileSystemCapabilities。'
        }
        return $FileSystemCapabilitiesForTest
    }

    return [CodexSafeTreeDelete.FileSystemDetector]::DetectFileSystem($TargetPath)
}

function Assert-CodexSafeTreeDeleteDeletionAllowed {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [object]$FileSystemCapabilitiesForTest
    )

    $capabilities = Get-CodexSafeTreeDeleteFileSystemCapabilities `
        -TargetPath $TargetPath `
        -FileSystemCapabilitiesForTest $FileSystemCapabilitiesForTest

    if ($null -eq $capabilities -or -not [bool]$capabilities.DeletionAllowed) {
        throw 'safe-delete 目标文件系统不允许删除：缺少 FILE_ID_INFO 或不支持的文件系统。'
    }
}

function Resolve-CodexSafeTreeDeleteTargetPathArguments {
    param([string[]]$Values)

    # 宿主 .cmd 链只能传单个字符串：BatchPurge 的多个目标、多组 Archive 的 transaction path 与
    # approved SHA-256 都以 '::' 连接，在这里拆回数组。
    $items = @($Values)
    if ($items.Count -eq 1 -and [string]$items[0] -match '::') {
        $items = @(([string]$items[0]).Split([string[]]@('::'), [StringSplitOptions]::RemoveEmptyEntries))
    }
    return @($items)
}

function Invoke-CodexSafeTreeDeleteMode {
    # 生产入口与 fixture 入口共用的 mode 分发：确认拒绝对象、参数校验与库函数调用只在这里维护。
    # 两个入口各自声明同一套 CLI 参数（Mode 的 ValidateSet 在参数绑定阶段、加载本库之前生效；两边的
    # 合同由 tests/Test-CodexSafeTreeDeleteModeDispatch.ps1 钉住），把 $PSBoundParameters 原样作为
    # EntryParameters 传进来，自己负责 policy / evidence 根、输出与退出码。
    # 新增 mode：两个入口的 ValidateSet 同时加上，再在下面的 switch 加分支。
    # 新增 CLI 参数：两个入口同时声明，再在下面按入口声明的类型重建。
    # ModeArgumentsForTest 只由 fixture 入口传入：键是 mode 名，值是追加到该 mode 库函数调用上的测试
    # 参数（*ForTest 钩子等）。与基础参数重名时哈希表相加直接抛错，所以测试参数只能追加，不能改写
    # policy / evidence 根。生产入口不传它，因此没有任何途径注入 fixture 钩子。
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EntryParameters,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [hashtable]$ModeArgumentsForTest
    )

    # 按入口声明的类型重建入口参数：未绑定的 [string] 为 ''，[string[]] 为 $null，[switch] 为未出现。
    [string]$Mode = $EntryParameters['Mode']
    [string]$TargetPath = $EntryParameters['TargetPath']
    [string[]]$TargetPaths = $EntryParameters['TargetPaths']
    [string]$CapabilityRoot = $EntryParameters['CapabilityRoot']
    [string]$PlanPath = $EntryParameters['PlanPath']
    [string]$ApprovedPlanSha256 = $EntryParameters['ApprovedPlanSha256']
    [switch]$ConfirmApply = [bool]$EntryParameters['ConfirmApply']
    [string]$TransactionPath = $EntryParameters['TransactionPath']
    [string]$ApprovedTransactionSha256 = $EntryParameters['ApprovedTransactionSha256']
    [string[]]$TransactionPaths = $EntryParameters['TransactionPaths']
    [string[]]$ApprovedTransactionSha256s = $EntryParameters['ApprovedTransactionSha256s']
    [switch]$ConfirmPurge = [bool]$EntryParameters['ConfirmPurge']
    [switch]$ConfirmRestore = [bool]$EntryParameters['ConfirmRestore']
    [switch]$ConfirmArchive = [bool]$EntryParameters['ConfirmArchive']
    [switch]$Json = [bool]$EntryParameters['Json']

    $testArguments = @{}
    if ($null -ne $ModeArgumentsForTest -and $null -ne $ModeArgumentsForTest[$Mode]) {
        $testArguments = $ModeArgumentsForTest[$Mode]
    }

    switch ($Mode) {
        'Status' {
            $libraryArguments = @{
                PolicyPath = $PolicyPath
                EvidenceRoot = $EvidenceRoot
            } + $testArguments
            # 范围查询（#80）：TargetPaths 同样接受 '::' 连接；不带 TargetPaths 时与全量 Status 完全相同。
            if ($null -ne $TargetPaths) {
                $scopeTargets = @(Resolve-CodexSafeTreeDeleteTargetPathArguments -Values $TargetPaths)
                if ($scopeTargets.Count -eq 0 -or
                    @($scopeTargets | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                    throw 'Status 范围查询要求 TargetPaths 至少一个目标且均不为空。'
                }
                $libraryArguments.TargetPaths = $scopeTargets
            }
            Get-CodexSafeTreeDeleteStatus @libraryArguments
        }
        'Lint' {
            $libraryArguments = @{
                PolicyPath = $PolicyPath
                EvidenceRoot = $EvidenceRoot
            } + $testArguments
            Invoke-CodexSafeTreeDeleteLint @libraryArguments
        }
        'Restore' {
            if (-not $ConfirmRestore) {
                return [pscustomobject][ordered]@{ restored = $false; refusalReason = 'confirm-restore-required' }
            }
            if ([string]::IsNullOrWhiteSpace($TransactionPath) -or
                [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
                throw 'Restore 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
            }
            $libraryArguments = @{
                TransactionPath = $TransactionPath
                ApprovedTransactionSha256 = $ApprovedTransactionSha256
                PolicyPath = $PolicyPath
                EvidenceRoot = $EvidenceRoot
            } + $testArguments
            Invoke-CodexSafeTreeDeleteRestore @libraryArguments
        }
        'Archive' {
            if (-not $ConfirmArchive) {
                return [pscustomobject][ordered]@{ archived = $false; refusalReason = 'confirm-archive-required' }
            }
            # 多组：TransactionPaths 与 ApprovedTransactionSha256s 按位置配对，宿主链传入的 '::' 连接串在这里
            # 拆开。请求级校验全部先于任何一组的处理，校验失败整体抛错、不写 evidence。
            if ($null -ne $TransactionPaths -or $null -ne $ApprovedTransactionSha256s) {
                if (-not [string]::IsNullOrWhiteSpace($TransactionPath) -or
                    -not [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
                    throw ('Archive 不能同时使用单组参数（TransactionPath / ApprovedTransactionSha256）' +
                        '与多组参数（TransactionPaths / ApprovedTransactionSha256s）。')
                }
                $resolvedTransactionPaths = @(Resolve-CodexSafeTreeDeleteTargetPathArguments -Values $TransactionPaths)
                $resolvedApprovedSha256s = @(Resolve-CodexSafeTreeDeleteTargetPathArguments -Values $ApprovedTransactionSha256s)
                if ($null -eq $TransactionPaths -or
                    $null -eq $ApprovedTransactionSha256s -or
                    $resolvedTransactionPaths.Count -eq 0 -or
                    $resolvedTransactionPaths.Count -ne $resolvedApprovedSha256s.Count -or
                    @($resolvedTransactionPaths + $resolvedApprovedSha256s |
                        Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                    throw 'Archive 多组模式要求 TransactionPaths 与 ApprovedTransactionSha256s 一一对应且均不为空。'
                }
                $libraryArguments = @{
                    TransactionPaths = $resolvedTransactionPaths
                    ApprovedTransactionSha256s = $resolvedApprovedSha256s
                    EvidenceRoot = $EvidenceRoot
                } + $testArguments
                return Invoke-CodexSafeTreeDeleteArchiveBatch @libraryArguments
            }
            if ([string]::IsNullOrWhiteSpace($TransactionPath) -or
                [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
                throw 'Archive 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
            }
            $libraryArguments = @{
                TransactionPath = $TransactionPath
                ApprovedTransactionSha256 = $ApprovedTransactionSha256
                EvidenceRoot = $EvidenceRoot
            } + $testArguments
            Invoke-CodexSafeTreeDeleteArchive @libraryArguments
        }
        'Plan' {
            if ([string]::IsNullOrWhiteSpace($TargetPath) -or [string]::IsNullOrWhiteSpace($CapabilityRoot)) {
                throw 'Plan 模式要求 TargetPath 与 CapabilityRoot。'
            }
            $libraryArguments = @{
                TargetPath = $TargetPath
                CapabilityRoot = $CapabilityRoot
                PolicyPath = $PolicyPath
                EvidenceRoot = $EvidenceRoot
            } + $testArguments
            New-CodexSafeTreeDeletePlan @libraryArguments
        }
        'Check' {
            # 只读预检：TargetPath 与 TargetPaths 二者择一（TargetPaths 同样接受 '::' 连接）；CapabilityRoot 可省略。
            $checkTargets = @()
            if ($null -ne $TargetPaths) { $checkTargets = @(Resolve-CodexSafeTreeDeleteTargetPathArguments -Values $TargetPaths) }
            $hasTargetPath = -not [string]::IsNullOrWhiteSpace($TargetPath)
            if ($hasTargetPath -eq ($checkTargets.Count -gt 0) -or
                @($checkTargets | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
                throw 'Check 模式要求 TargetPath 或 TargetPaths（二者择一）。'
            }
            if ($hasTargetPath) { $checkTargets = @($TargetPath) }
            $libraryArguments = @{
                TargetPaths = $checkTargets
                CapabilityRoot = $CapabilityRoot
                PolicyPath = $PolicyPath
            } + $testArguments
            Invoke-CodexSafeTreeDeleteCheck @libraryArguments
        }
        'Apply' {
            if (-not $ConfirmApply) {
                return [pscustomobject][ordered]@{ quarantined = $false; refusalReason = 'confirm-apply-required' }
            }
            if ([string]::IsNullOrWhiteSpace($PlanPath) -or [string]::IsNullOrWhiteSpace($ApprovedPlanSha256)) {
                throw 'Apply 模式要求 PlanPath 与 ApprovedPlanSha256。'
            }
            $libraryArguments = @{
                PlanPath = $PlanPath
                ApprovedPlanSha256 = $ApprovedPlanSha256
                PolicyPath = $PolicyPath
                EvidenceRoot = $EvidenceRoot
            } + $testArguments
            Invoke-CodexSafeTreeDeleteQuarantine @libraryArguments
        }
        'Purge' {
            if (-not $ConfirmPurge) {
                return [pscustomobject][ordered]@{ purged = $false; refusalReason = 'confirm-purge-required' }
            }
            if ([string]::IsNullOrWhiteSpace($TransactionPath) -or [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
                throw 'Purge 模式要求 TransactionPath 与 ApprovedTransactionSha256。'
            }
            $libraryArguments = @{
                TransactionPath = $TransactionPath
                ApprovedTransactionSha256 = $ApprovedTransactionSha256
                PolicyPath = $PolicyPath
                EvidenceRoot = $EvidenceRoot
                ReturnFailureMetrics = [bool]$Json
            } + $testArguments
            Invoke-CodexSafeTreeDeletePurge @libraryArguments
        }
        'BatchPurge' {
            if (-not $ConfirmApply -or -not $ConfirmPurge) {
                return [pscustomobject][ordered]@{ completed = $false; refusalReason = 'confirm-apply-and-purge-required' }
            }
            $resolvedTargets = @(Resolve-CodexSafeTreeDeleteTargetPathArguments -Values $TargetPaths)
            if ($resolvedTargets.Count -eq 0 -or [string]::IsNullOrWhiteSpace($CapabilityRoot)) {
                throw 'BatchPurge 模式要求 TargetPaths 与 CapabilityRoot。'
            }
            $libraryArguments = @{
                TargetPaths = $resolvedTargets
                CapabilityRoot = $CapabilityRoot
                PolicyPath = $PolicyPath
                EvidenceRoot = $EvidenceRoot
            } + $testArguments
            Invoke-CodexSafeTreeDeleteBatchPurge @libraryArguments
        }
        default {
            throw "safe-delete mode 分发缺少分支：$Mode"
        }
    }
}

function New-CodexSafeTreeDeletePlan {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [object]$FileSystemCapabilitiesForTest,
        [switch]$DisablePlanCSharpWalkerForTest,
        [scriptblock]$PlanWalkerCheckpointForTest
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
    Assert-CodexSafeTreeDeleteRetiredEvidenceRootGrantUnconsumed `
        -Target $target `
        -EvidenceRoot $EvidenceRoot
    Assert-CodexSafeTreeDeleteDeletionAllowed `
        -TargetPath $target.targetPath `
        -FileSystemCapabilitiesForTest $FileSystemCapabilitiesForTest
    $planSegments = [pscustomobject][ordered]@{
        walker = $null
        walkerTotalMs = $null
        hashMs = $null
        streamSetMs = $null
        capturesMs = $null
        identityPassMs = $null
        streamSetPassMs = $null
        documentMs = $null
        publishMs = $null
        readbackMs = $null
        utc = [datetimeoffset]::UtcNow.ToString('o')
    }
    $planWalkerAlgorithm = Get-CodexHostSafetyNativeResolvedWalkerAlgorithm
    $usePlanCSharpWalker = (-not $DisablePlanCSharpWalkerForTest.IsPresent) -and
        ($planWalkerAlgorithm -ceq 'csharp-plan-snapshot')
    $planTree = $null
    if ($usePlanCSharpWalker) {
        $planSegments.walker = 'csharp'
        $walkerWatch = [Diagnostics.Stopwatch]::StartNew()
        $planTree = Get-CodexSafeTreeDeletePlanTreeSnapshot `
            -Path $target.targetPath `
            -CapabilityRoot $target.capabilityRoot `
            -AllowedExactPaths @($target.targetPath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $metricsObserver `
            -PlanWalkerCheckpointForTest $PlanWalkerCheckpointForTest `
            -Name 'safe-delete plan snapshot'
        $walkerWatch.Stop()
        $planSegments.walkerTotalMs = [long]$walkerWatch.ElapsedMilliseconds
        $planSegments.hashMs = [long]$planTree.timings.HashMs
        $planSegments.streamSetMs = [long]$planTree.timings.StreamSetMs
        $tree = $planTree.manifest
    } else {
        $planSegments.walker = 'powershell'
        $walkerWatch = [Diagnostics.Stopwatch]::StartNew()
        $tree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $target.targetPath `
            -CapabilityRoot $target.capabilityRoot `
            -AllowedExactPaths @($target.targetPath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $metricsObserver `
            -Name 'safe-delete plan snapshot'
        $walkerWatch.Stop()
        $planSegments.walkerTotalMs = [long]$walkerWatch.ElapsedMilliseconds
    }
    Assert-CodexSafeTreeDeleteTargetTreePolicy `
        -Target $target `
        -TreeManifest $tree `
        -TreePath $target.targetPath
    $generationId = [guid]::NewGuid().ToString('D')
    $now = [datetimeoffset]::UtcNow
    if ($usePlanCSharpWalker) {
        $capturesWatch = [Diagnostics.Stopwatch]::StartNew()
        $fileIdentitiesV2 = New-CodexSafeTreeDeletePlanFileIdentitiesV2FromCaptures `
            -Captures $planTree.captures `
            -TargetPath $target.targetPath
        $leafStreamSetV1 = New-CodexSafeTreeDeletePlanLeafStreamSetFromCaptures `
            -Captures $planTree.captures `
            -TargetPath $target.targetPath
        $capturesWatch.Stop()
        $planSegments.capturesMs = [long]$capturesWatch.ElapsedMilliseconds
    } else {
        $identityWatch = [Diagnostics.Stopwatch]::StartNew()
        $fileIdentitiesV2 = New-CodexSafeTreeDeletePlanFileIdentitiesV2 `
            -TargetPath $target.targetPath `
            -TreeManifest $tree
        $identityWatch.Stop()
        $planSegments.identityPassMs = [long]$identityWatch.ElapsedMilliseconds
        $streamSetWatch = [Diagnostics.Stopwatch]::StartNew()
        $leafStreamSetV1 = New-CodexSafeTreeDeletePlanLeafStreamSet `
            -TargetPath $target.targetPath `
            -TreeManifest $tree
        $streamSetWatch.Stop()
        $planSegments.streamSetPassMs = [long]$streamSetWatch.ElapsedMilliseconds
    }
    if ([string]$target.rootDeletionPurpose -ceq 'retired-evidence-root') {
        $targetDirectoryIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 `
            -LiteralPath $target.targetPath
        $fileIdentitiesV2 = @(
            @($fileIdentitiesV2) + @(
                ConvertTo-CodexSafeTreeDeleteFileIdentityV2Record `
                    -RelativePath '.' `
                    -Identity $targetDirectoryIdentity
            )
        )
    }
    $documentWatch = [Diagnostics.Stopwatch]::StartNew()
    $topLevelEntries = @($tree.entries | Where-Object {
        $_.relativePath -cne '.' -and $_.relativePath -notmatch '/'
    } | ForEach-Object { [string]$_.relativePath })
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
        leafStreamSetV1 = $leafStreamSetV1
        summary = [pscustomobject][ordered]@{
            fileCount = @($tree.entries | Where-Object kind -ceq 'file').Count
            directoryCount = @($tree.entries | Where-Object kind -ceq 'directory').Count
            topLevelEntries = $topLevelEntries
        }
    }
    $documentWatch.Stop()
    $planSegments.documentMs = [long]$documentWatch.ElapsedMilliseconds

    $publishWatch = [Diagnostics.Stopwatch]::StartNew()
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
    $publishWatch.Stop()
    $planSegments.publishMs = [long]$publishWatch.ElapsedMilliseconds
    $readbackWatch = [Diagnostics.Stopwatch]::StartNew()
    $planSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $planPath `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($planPath) `
        -Name 'safe-delete plan published'
    $readbackWatch.Stop()
    $planSegments.readbackMs = [long]$readbackWatch.ElapsedMilliseconds
    & $metricsObserver 'hash-read' 0L ([long]$planSnapshot.bytes.Length)
    $script:CodexSafeTreeDeleteLastPlanSegments = $planSegments

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

    $fileIdentityPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $records) {
        if ([string]$record.relativePath -ceq '.') { continue }
        [void]$fileIdentityPaths.Add([string]$record.relativePath)
    }
    if ($fileIdentityPaths.Count -ne $plannedFileSet.Count -or
        @($plannedFileSet | Where-Object { -not $fileIdentityPaths.Contains($_) }).Count -ne 0) {
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

function ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap {
    param([Parameter(Mandatory)][object]$Plan)

    $records = Read-CodexSafeTreeDeleteFileIdentityV2FromPlan -Plan $Plan
    $map = [Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]::new(
        [StringComparer]::Ordinal)
    foreach ($record in $records) {
        $map.Add([string]$record.relativePath, $record.identity)
    }
    return $map
}

function ConvertTo-CodexSafeTreeDeleteDirectoryIdentityPairFromFileIdentityV2 {
    param(
        [Parameter(Mandatory)][CodexSafeTreeDelete.FileIdentityV2]$Identity,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($null -eq $Identity.FileId128 -or $Identity.FileId128.Length -ne 16) {
        throw "$Scope FileId128 必须是 16 字节。"
    }
    $volumeMask = [uint64]4294967295
    $volume = ([uint32]($Identity.VolumeSerialNumber -band $volumeMask)).ToString('x8')
    $fileId = [byte[]]$Identity.FileId128
    $fileIndexLow = [BitConverter]::ToUInt32($fileId, 0)
    $fileIndexHigh = [BitConverter]::ToUInt32($fileId, 4)
    $fileIndex = '{0:x8}{1:x8}' -f $fileIndexHigh, $fileIndexLow
    return @($volume, $fileIndex)
}

function Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][string]$Scope
    )

    if ([string]$Target.rootDeletionPurpose -cne 'retired-evidence-root') {
        return
    }
    if ($null -eq $Plan.fileIdentitiesV2 -or $Plan.fileIdentitiesV2 -isnot [Array]) {
        throw "$Scope retired-evidence-root 缺少 fileIdentitiesV2 数组。"
    }

    $dotRecords = @($Plan.fileIdentitiesV2 | Where-Object {
        [string]$_.relativePath -ceq '.'
    })
    if ($dotRecords.Count -ne 1) {
        throw "$Scope retired-evidence-root 必须在 fileIdentitiesV2 绑定唯一的目标目录 relativePath=."
    }

    $converted = ConvertFrom-CodexSafeTreeDeleteFileIdentityV2Record `
        -Record $dotRecords[0] `
        -Scope "$Scope retired-evidence-root target directory fileIdentitiesV2"
    $plannedIdentity = $converted.identity
    $plannedPair = ConvertTo-CodexSafeTreeDeleteDirectoryIdentityPairFromFileIdentityV2 `
        -Identity $plannedIdentity `
        -Scope $Scope
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($Plan.treeManifest.rootIdentity) `
        -Actual $plannedPair `
        -Scope "$Scope retired-evidence-root FileIdentityV2 vs treeManifest.rootIdentity"

    $livePath = ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath `
        -TreePath $TreePath `
        -RelativePath '.' `
        -Scope "$Scope retired-evidence-root target directory"
    $liveIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $livePath
    if ($liveIdentity.VolumeSerialNumber -ne $plannedIdentity.VolumeSerialNumber -or
        $null -eq $liveIdentity.FileId128 -or
        $liveIdentity.FileId128.Length -ne 16 -or
        -not [Linq.Enumerable]::SequenceEqual(
            [byte[]]$liveIdentity.FileId128,
            [byte[]]$plannedIdentity.FileId128)) {
        throw "$Scope retired-evidence-root 目标目录 FileIdentityV2 漂移。"
    }
}

function Assert-CodexSafeTreeDeleteRetiredEvidenceRootLivePolicySha {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$PolicyPath,
        [scriptblock]$MetricsObserver
    )

    if ([string]$Target.rootDeletionPurpose -cne 'retired-evidence-root') {
        return
    }
    $policy = Read-CodexSafeTreeDeletePolicy `
        -PolicyPath $PolicyPath `
        -MetricsObserver $MetricsObserver
    if ([string]$Plan.policySha256 -cne [string]$policy.sha256) {
        throw 'safe-delete policy 自计划生成后已漂移。'
    }
}

function Assert-CodexSafeTreeDeleteRetiredEvidenceRootGrantUnconsumed {
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    if ([string]$Target.rootDeletionPurpose -cne 'retired-evidence-root') {
        return
    }

    $fullEvidenceRoot = Assert-CodexHookDPath `
        -Value $EvidenceRoot `
        -Name 'safe-delete retired-evidence-root evidence root'
    if (-not [IO.Directory]::Exists($fullEvidenceRoot) -and
        -not [IO.File]::Exists($fullEvidenceRoot)) {
        return
    }

    $unprovable = 'safe-delete retired-evidence-root 无法证明许可未消费。'
    $rootItem = Get-Item -LiteralPath $fullEvidenceRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw $unprovable
    }

    $targetPath = [string]$Target.targetPath
    $policyEntryId = [string]$Target.policyEntryId
    $runItems = @(Get-ChildItem -LiteralPath $fullEvidenceRoot -Force -ErrorAction Stop)
    foreach ($runItem in $runItems) {
        if (($runItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw $unprovable
        }
        if (-not $runItem.PSIsContainer) {
            continue
        }

        $runDirectory = [string]$runItem.FullName
        $planPath = Join-Path $runDirectory 'plan.json'
        $transactionPath = Join-Path $runDirectory 'transaction.json'
        $planExists = [IO.File]::Exists($planPath)
        $transactionExists = [IO.File]::Exists($transactionPath)
        $hasConsumeEvidence = [IO.File]::Exists((Join-Path $runDirectory 'leaf-dispositions.json')) -or
            [IO.File]::Exists((Join-Path $runDirectory 'restore-complete.json')) -or
            @(Get-ChildItem -LiteralPath $runDirectory -Force -File -Filter 'directory-delete-*-commit.json' -ErrorAction Stop).Count -gt 0
        if (($transactionExists -or $hasConsumeEvidence) -and -not $planExists) {
            throw $unprovable
        }
        if ($hasConsumeEvidence -and -not $transactionExists) {
            throw $unprovable
        }
        if (-not $planExists) {
            continue
        }

        try {
            [void](Assert-CodexHookCapabilityPath `
                -Path $planPath `
                -CapabilityRoot $fullEvidenceRoot `
                -AllowedExactPaths @($planPath) `
                -Name 'safe-delete retired-evidence-root consumed grant plan')
            $planSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                -Path $planPath `
                -Name 'safe-delete retired-evidence-root consumed grant plan' `
                -AllowedExactPaths @($planPath)
            $plan = $planSnapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        } catch {
            throw $unprovable
        }
        if ($plan.PSObject.Properties.Name -notcontains 'policyEntryId' -or
            $plan.policyEntryId -isnot [string] -or
            $plan.PSObject.Properties.Name -notcontains 'targetPath' -or
            $plan.targetPath -isnot [string]) {
            throw $unprovable
        }
        if (-not $transactionExists) {
            continue
        }

        try {
            [void](Assert-CodexHookCapabilityPath `
                -Path $transactionPath `
                -CapabilityRoot $fullEvidenceRoot `
                -AllowedExactPaths @($transactionPath) `
                -Name 'safe-delete retired-evidence-root consumed grant transaction')
            $transactionSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                -Path $transactionPath `
                -Name 'safe-delete retired-evidence-root consumed grant transaction' `
                -AllowedExactPaths @($transactionPath)
            $transaction = $transactionSnapshot.text |
                ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        } catch {
            throw $unprovable
        }
        if ($null -eq $transaction.status -or $transaction.status -isnot [string]) {
            throw $unprovable
        }
        if ([string]$plan.policyEntryId -cne $policyEntryId) {
            continue
        }
        if (-not (Test-CodexSafeTreeDeletePathEqual `
                -Left ([string]$plan.targetPath) `
                -Right $targetPath)) {
            continue
        }
        if ([string]$transaction.status -cin @('purged', 'restored')) {
            throw 'safe-delete retired-evidence-root 许可已消费，不得批准新 Plan 或重放旧授权。'
        }
    }
}

function Assert-CodexSafeTreeDeleteRetiredEvidenceRootLeafDispositions {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][object]$Transaction,
        [scriptblock]$MetricsObserver
    )

    $path = Join-Path $RunDirectory 'leaf-dispositions.json'
    if (-not [IO.File]::Exists($path)) {
        throw 'safe-delete retired-evidence-root purged 缺少可回读 leaf-dispositions。'
    }
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $path `
        -Name 'safe-delete retired-evidence-root leaf-dispositions' `
        -AllowedExactPaths @($path)
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$snapshot.bytes.Length)
    }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $document = $snapshot.text | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $document `
        -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'planSha256',
            'transactionPath', 'quarantinePath', 'purgingTransactionUpdatedAtUtc',
            'streamSetSource', 'liveFreeze', 'leaves', 'summary'
        ) `
        -Scope 'safe-delete retired-evidence-root leaf-dispositions'
    if ([string]$document.artifactType -cne 'env-governance.codex-safe-tree-delete-leaf-dispositions' -or
        ($document.schemaVersion -isnot [long] -and $document.schemaVersion -isnot [int]) -or
        [long]$document.schemaVersion -ne 1L -or
        [string]$document.generationId -cne [string]$Plan.generationId -or
        [string]$document.planSha256 -cne $PlanSha256 -or
        [string]$document.transactionPath -cne (Join-Path $RunDirectory 'transaction.json') -or
        [string]$document.quarantinePath -cne [string]$Transaction.quarantinePath) {
        throw 'safe-delete retired-evidence-root leaf-dispositions 与 plan/transaction 绑定不一致。'
    }
    if ($document.leaves -isnot [Array]) {
        throw 'safe-delete retired-evidence-root leaf-dispositions leaves 必须是 JSON array。'
    }

    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Plan.treeManifest.entries)) {
        if ([string]$entry.kind -cin @('file', 'directory-junction')) {
            [void]$expected.Add([string]$entry.relativePath)
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in @($document.leaves)) {
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $row `
            -Names @('relativePath', 'kind', 'disposition', 'evidence') `
            -Scope 'safe-delete retired-evidence-root leaf-dispositions row'
        $relativePath = [string]$row.relativePath
        if ([string]$row.kind -cnotin @('file', 'directory-junction') -or
            [string]$row.disposition -cnotin @('deleted', 'absent-at-purge-resume') -or
            -not $expected.Contains($relativePath) -or
            -not $seen.Add($relativePath)) {
            throw "safe-delete retired-evidence-root leaf-dispositions 未精确覆盖计划 leaf：$relativePath"
        }
    }
    if ($seen.Count -ne $expected.Count) {
        throw 'safe-delete retired-evidence-root leaf-dispositions 未精确覆盖计划 file/junction leaf。'
    }
}

function Invoke-CodexSafeTreeDeleteApplyFileHash {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]$ExpectedIdentities,
        [Parameter(Mandatory)][CodexSafeTreeDelete.SessionHashCache]$SessionCache,
        [object]$Lease
    )

    $expected = $null
    if (-not $ExpectedIdentities.TryGetValue($RelativePath, [ref]$expected) -or $null -eq $expected) {
        throw "safe-delete apply fileIdentitiesV2 缺少：$RelativePath"
    }
    try {
        if ($null -ne $Lease) {
            $current = [CodexSafeTreeDelete.FileIdentityReader]::GetFileIdentityV2($Lease.Handle)
            if ($current -ne $expected) {
                throw [CodexSafeTreeDelete.IdentityMismatchException]::new($expected, $current)
            }
            $cached = $null
            if ($SessionCache.TryGet($current, [ref]$cached)) {
                return ,$cached
            }
            [byte[]]$hashFromLease = $Lease.ComputeSha256FromHandle()
            $SessionCache.Set($current, $hashFromLease)
            return ,$hashFromLease
        }

        [byte[]]$hash = Get-CodexSafeTreeDeleteHashSafely `
            -LiteralPath $LiteralPath `
            -ExpectedIdentity $expected `
            -SessionCache $SessionCache
        return ,$hash
    } catch {
        $currentException = $_.Exception
        while ($null -ne $currentException) {
            if ($currentException -is [CodexSafeTreeDelete.IdentityMismatchException]) {
                throw [InvalidOperationException]::new(
                    "safe-delete apply IdentityMismatch：$RelativePath",
                    $currentException)
            }
            $currentException = $currentException.InnerException
        }
        throw
    }
}

function New-CodexSafeTreeDeleteApplyFileHashProvider {
    param(
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]$ExpectedIdentities,
        [Parameter(Mandatory)][CodexSafeTreeDelete.SessionHashCache]$SessionCache
    )

    $invokeApplyHash = ${function:Invoke-CodexSafeTreeDeleteApplyFileHash}
    $provider = {
        param([string]$LiteralPath, [string]$RelativePath, [long]$Length, $Lease)
        [byte[]]$hash = & $invokeApplyHash `
            -LiteralPath $LiteralPath `
            -RelativePath $RelativePath `
            -ExpectedIdentities $ExpectedIdentities `
            -SessionCache $SessionCache `
            -Lease $Lease
        return ,$hash
    }
    return $provider.GetNewClosure()
}

function Get-CodexSafeTreeDeleteApplyTreeSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [switch]$AllowHardLinks,
        [switch]$AllowInternalDirectoryJunctions,
        [string]$InternalDirectoryJunctionTargetRoot,
        [scriptblock]$MetricsObserver,
        [Parameter(Mandatory)][CodexSafeTreeDelete.ApplySessionHashCoordinator]$Coordinator,
        [string]$Name = 'safe-delete apply snapshot'
    )

    $fullPath = Assert-CodexHookCapabilityPath `
        -Path $Path `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name $Name
    $capabilityRootPath = Assert-CodexHookDPath -Value $CapabilityRoot -Name "$Name capability root"
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

    $streamCaptures = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $native = [CodexSafeTreeDelete.ApplyTreeSnapshotBuilder]::Build(
        [string]$fullPath,
        [string]$capabilityRootPath,
        [bool]$AllowHardLinks,
        [bool]$AllowInternalDirectoryJunctions,
        [string]$InternalDirectoryJunctionTargetRoot,
        $Coordinator)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($native.Entries)) {
        $kind = [string]$entry.Kind
        $entries.Add([pscustomobject][ordered]@{
            relativePath = [string]$entry.RelativePath
            kind = $kind
            sha256 = $(if ($kind -ceq 'directory') { $null } else { [string]$entry.Sha256Hex })
            identity = @([string]$entry.VolumeSerialNumber, [string]$entry.FileIndex)
        })
        if ([bool]$entry.StreamSetCaptured) {
            $streamCaptures[[string]$entry.RelativePath] = $entry
        }
        if ($null -ne $MetricsObserver) {
            & $MetricsObserver $kind ([long]$entry.LogicalBytes) ([long]$entry.HashedBytes)
        }
    }

    $script:CodexSafeTreeDeleteLastStreamCaptures = $streamCaptures
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        rootIdentity = @(
            [string]$native.RootVolumeSerialNumber,
            [string]$native.RootFileIndex
        )
        entries = @($entries)
    }
}

function Invoke-CodexSafeTreeDeletePurgeFileHash {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]$ExpectedIdentities,
        [Parameter(Mandatory)][CodexSafeTreeDelete.SessionHashCache]$SessionCache,
        [object]$Lease
    )

    $expected = $null
    if (-not $ExpectedIdentities.TryGetValue($RelativePath, [ref]$expected) -or $null -eq $expected) {
        throw "safe-delete purge fileIdentitiesV2 缺少：$RelativePath"
    }
    try {
        if ($null -ne $Lease) {
            $current = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $LiteralPath
            if ($current -ne $expected) {
                throw [CodexSafeTreeDelete.IdentityMismatchException]::new($expected, $current)
            }
            $cached = $null
            if ($SessionCache.TryGet($current, [ref]$cached)) {
                return ,$cached
            }
            [byte[]]$hashFromLease = $Lease.ComputeSha256FromHandle()
            $SessionCache.Set($current, $hashFromLease)
            return ,$hashFromLease
        }

        [byte[]]$hash = Get-CodexSafeTreeDeleteHashSafely `
            -LiteralPath $LiteralPath `
            -ExpectedIdentity $expected `
            -SessionCache $SessionCache
        return ,$hash
    } catch {
        $currentException = $_.Exception
        while ($null -ne $currentException) {
            if ($currentException -is [CodexSafeTreeDelete.IdentityMismatchException]) {
                throw [InvalidOperationException]::new(
                    "safe-delete purge IdentityMismatch：$RelativePath",
                    $currentException)
            }
            $currentException = $currentException.InnerException
        }
        throw
    }
}

function New-CodexSafeTreeDeletePurgeFileLeafBatch {
    param(
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][object]$TreeManifest,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]$ExpectedIdentities
    )

    if ($null -eq $TreeManifest -or $null -eq $TreeManifest.PSObject) {
        throw 'safe-delete purge batch treeManifest 不是对象。'
    }
    $batch = [Collections.Generic.List[CodexSafeTreeDelete.PurgeFileLeaf]]::new()
    foreach ($entry in @($TreeManifest.entries)) {
        if ([string]$entry.kind -cne 'file') {
            continue
        }
        $relativePath = [string]$entry.relativePath
        $expected = $null
        if (-not $ExpectedIdentities.TryGetValue($relativePath, [ref]$expected) -or $null -eq $expected) {
            throw "safe-delete purge batch fileIdentitiesV2 缺少：$relativePath"
        }
        $literalPath = ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
            -TargetPath $TreePath `
            -RelativePath $relativePath
        $batch.Add([CodexSafeTreeDelete.PurgeFileLeaf]::new($literalPath, $relativePath, $expected))
    }
    return ,$batch
}

function Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.IList[CodexSafeTreeDelete.PurgeFileLeaf]]$Leaves,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]$ExpectedIdentities,
        [Parameter(Mandatory)][CodexSafeTreeDelete.SessionHashCache]$SessionCache
    )

    foreach ($leaf in $Leaves) {
        $expected = $null
        if (-not $ExpectedIdentities.TryGetValue($leaf.RelativePath, [ref]$expected) -or $null -eq $expected) {
            throw "safe-delete purge batch fileIdentitiesV2 缺少：$($leaf.RelativePath)"
        }
        try {
            $current = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $leaf.LiteralPath
            if ($current -ne $expected) {
                throw [CodexSafeTreeDelete.IdentityMismatchException]::new($expected, $current)
            }
            $cached = $null
            if ($SessionCache.TryGet($current, [ref]$cached)) {
                continue
            }
            [void](Invoke-CodexSafeTreeDeletePurgeFileHash `
                -LiteralPath $leaf.LiteralPath `
                -RelativePath $leaf.RelativePath `
                -ExpectedIdentities $ExpectedIdentities `
                -SessionCache $SessionCache)
        } catch {
            $currentException = $_.Exception
            while ($null -ne $currentException) {
                if ($currentException -is [CodexSafeTreeDelete.IdentityMismatchException]) {
                    throw [InvalidOperationException]::new(
                        "safe-delete purge IdentityMismatch：$($leaf.RelativePath)",
                        $currentException)
                }
                $currentException = $currentException.InnerException
            }
            throw
        }
    }
}

function New-CodexSafeTreeDeletePurgeFileHashProvider {
    param(
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]$ExpectedIdentities,
        [Parameter(Mandatory)][CodexSafeTreeDelete.SessionHashCache]$SessionCache
    )

    $invokePurgeHash = ${function:Invoke-CodexSafeTreeDeletePurgeFileHash}
    $provider = {
        param([string]$LiteralPath, [string]$RelativePath, [long]$Length, $Lease)
        [byte[]]$hash = & $invokePurgeHash `
            -LiteralPath $LiteralPath `
            -RelativePath $RelativePath `
            -ExpectedIdentities $ExpectedIdentities `
            -SessionCache $SessionCache `
            -Lease $Lease
        return ,$hash
    }
    return $provider.GetNewClosure()
}

function Read-CodexSafeTreeDeletePlanStreamSet {
    param([Parameter(Mandatory)][object]$Plan)

    if ($null -eq $Plan -or $null -eq $Plan.PSObject) {
        throw 'safe-delete plan 不是对象。'
    }
    if ($Plan.artifactType -cne 'env-governance.codex-safe-tree-delete-plan') {
        throw 'safe-delete plan artifact 非法。'
    }
    if (-not (@($Plan.PSObject.Properties.Name) -contains 'leafStreamSetV1')) {
        throw 'safe-delete plan 缺少 leafStreamSetV1，拒绝在缺失完整 stream-set 记录时消费。'
    }
    $section = $Plan.leafStreamSetV1
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $section `
        -Names @('schemaVersion', 'consumptionBoundary', 'leaves') `
        -Scope 'safe-delete plan leafStreamSetV1'
    if ($section.schemaVersion -isnot [long] -or [long]$section.schemaVersion -ne 1L) {
        throw 'safe-delete plan leafStreamSetV1 schemaVersion 非法。'
    }
    $boundary = $section.consumptionBoundary
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $boundary `
        -Names @('apply', 'purge', 'streamDrift', 'leafDrift', 'requiresTreeManifestReverification') `
        -Scope 'safe-delete plan leafStreamSetV1 consumptionBoundary'
    if ([string]$boundary.apply -cne 'apply-locked-preflight' -or
        [string]$boundary.purge -cne 'purge-locked-preflight' -or
        [string]$boundary.streamDrift -cne 'fail-closed' -or
        [string]$boundary.leafDrift -cne 'fail-closed' -or
        [string]$boundary.requiresTreeManifestReverification -cne 'always') {
        throw 'safe-delete plan leafStreamSetV1 consumptionBoundary 非法：消费边界不得漂移。'
    }
    if ($section.leaves -isnot [Array]) {
        throw 'safe-delete plan leafStreamSetV1 leaves 必须是 JSON array。'
    }
    if ($null -eq $Plan.treeManifest -or $null -eq $Plan.treeManifest.PSObject) {
        throw 'safe-delete plan treeManifest 非法。'
    }

    $manifestKinds = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $manifestOrder = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($Plan.treeManifest.entries)) {
        $relativePath = [string]$entry.relativePath
        if (-not $manifestKinds.TryAdd($relativePath, [string]$entry.kind)) {
            throw "safe-delete plan treeManifest relativePath 重复：$relativePath"
        }
        $manifestOrder.Add($relativePath)
    }

    $leafByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $index = 0
    foreach ($leaf in @($section.leaves)) {
        $scope = "safe-delete plan leafStreamSetV1 leaves[$index]"
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $leaf `
            -Names @('relativePath', 'kind', 'streamNames', 'hardLinkCount') `
            -Scope $scope
        if ($leaf.relativePath -isnot [string]) {
            throw "$scope relativePath 必须是 JSON string。"
        }
        $relativePath = [string]$leaf.relativePath
        Assert-CodexHookDirectoryTreeRelativePath -RelativePath $relativePath -Scope $scope
        $kind = [string]$leaf.kind
        if ($kind -cnotin @('file', 'directory', 'directory-junction')) {
            throw "$scope kind 非法：$kind"
        }
        if ($leaf.streamNames -isnot [Array]) {
            throw "$scope streamNames 必须是 JSON array。"
        }
        $streamNames = [Collections.Generic.List[string]]::new()
        $streamNameSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($streamName in @($leaf.streamNames)) {
            if ($streamName -isnot [string] -or
                ([string]$streamName -cnotmatch '^::\$DATA$' -and
                    [string]$streamName -cnotmatch '^:[^:]+:\$DATA$')) {
                throw "$scope streamNames 含非法 stream 名称。"
            }
            if (-not $streamNameSet.Add([string]$streamName)) {
                throw "$scope streamNames 重复：$streamName"
            }
            $streamNames.Add([string]$streamName)
        }
        if ($kind -ceq 'file' -and
            -not ($streamNames.Count -eq 1 -and $streamNames[0] -ceq '::$DATA')) {
            throw "$scope streamNames 非法：file leaf 只能声明默认流。"
        }
        if ($kind -ceq 'directory-junction' -and $streamNames.Count -ne 0) {
            throw "$scope streamNames 非法：junction leaf 不得声明命名流。"
        }
        if ($leaf.hardLinkCount -isnot [long] -and $leaf.hardLinkCount -isnot [int]) {
            throw "$scope hardLinkCount 必须是 JSON integer。"
        }
        $hardLinkCount = [long]$leaf.hardLinkCount
        if ($hardLinkCount -lt 1L) {
            throw "$scope hardLinkCount 必须大于等于 1。"
        }
        if (-not $leafByPath.TryAdd($relativePath, [pscustomobject][ordered]@{
                    relativePath = $relativePath
                    kind = $kind
                    streamNames = [string[]]@($streamNames)
                    hardLinkCount = $hardLinkCount
                })) {
            throw "safe-delete plan leafStreamSetV1 relativePath 重复：$relativePath"
        }
        $index += 1
    }
    if ($leafByPath.Count -ne $manifestKinds.Count) {
        throw 'safe-delete plan leafStreamSetV1 leaves 必须与 treeManifest 条目集合精确对应。'
    }
    foreach ($relativePath in $manifestOrder) {
        if (-not $leafByPath.ContainsKey($relativePath) -or
            [string]$leafByPath[$relativePath].kind -cne [string]$manifestKinds[$relativePath]) {
            throw 'safe-delete plan leafStreamSetV1 leaves 必须与 treeManifest 条目集合精确对应。'
        }
    }

    $identityByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in @(Read-CodexSafeTreeDeleteFileIdentityV2FromPlan -Plan $Plan)) {
        $identityByPath.Add([string]$record.relativePath, $record.identity)
    }

    $leaves = [Collections.Generic.List[object]]::new()
    $byPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($relativePath in $manifestOrder) {
        $leaf = $leafByPath[$relativePath]
        $identity = $null
        if ([string]$leaf.kind -ceq 'file') {
            $identity = $identityByPath[$relativePath]
        }
        $row = [pscustomobject][ordered]@{
            relativePath = [string]$leaf.relativePath
            kind = [string]$leaf.kind
            streamNames = [string[]]@($leaf.streamNames)
            hardLinkCount = [long]$leaf.hardLinkCount
            identity = $identity
        }
        $leaves.Add($row)
        $byPath.Add([string]$leaf.relativePath, $row)
    }

    return [pscustomobject][ordered]@{
        boundary = [pscustomobject][ordered]@{
            apply = [string]$boundary.apply
            purge = [string]$boundary.purge
            streamDrift = [string]$boundary.streamDrift
            leafDrift = [string]$boundary.leafDrift
            requiresTreeManifestReverification = [string]$boundary.requiresTreeManifestReverification
        }
        leaves = @($leaves)
        byPath = $byPath
    }
}

function Assert-CodexSafeTreeDeleteLiveStreamSet {
    param(
        [Parameter(Mandatory)][object]$PlanStreamSet,
        [Parameter(Mandatory)][object]$TreeManifest,
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][ValidateSet('apply', 'purge')][string]$Phase,
        [switch]$AllowMissingPlannedLeaves,
        [object]$CapturedStreamSets
    )

    $scope = "safe-delete $Phase locked preflight leaf stream-set"
    $liveKinds = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($TreeManifest.entries)) {
        $relativePath = [string]$entry.relativePath
        if (-not $liveKinds.TryAdd($relativePath, [string]$entry.kind)) {
            throw "$scope live tree relativePath 重复：$relativePath"
        }
        if (-not $PlanStreamSet.byPath.ContainsKey($relativePath)) {
            throw "$scope 计划外 leaf 漂移：$relativePath"
        }
        if ([string]$PlanStreamSet.byPath[$relativePath].kind -cne [string]$entry.kind) {
            throw "$scope leaf kind 漂移：$relativePath"
        }
    }
    if (-not $AllowMissingPlannedLeaves) {
        foreach ($leaf in @($PlanStreamSet.leaves)) {
            if (-not $liveKinds.ContainsKey([string]$leaf.relativePath)) {
                throw "$scope leaf 缺失漂移：$($leaf.relativePath)"
            }
        }
    }

    foreach ($entry in @($TreeManifest.entries)) {
        $relativePath = [string]$entry.relativePath
        $planned = $PlanStreamSet.byPath[$relativePath]
        $absolutePath = ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath `
            -TreePath $TreePath `
            -RelativePath $relativePath `
            -Scope $scope
        $capture = $null
        $usedAmortizedCapture = $false
        if ($null -ne $CapturedStreamSets -and
            $CapturedStreamSets.ContainsKey($relativePath) -and
            [bool]$CapturedStreamSets[$relativePath].StreamSetCaptured) {
            $usedAmortizedCapture = $true
            $nativeCapture = $CapturedStreamSets[$relativePath]
            $capture = [pscustomobject][ordered]@{
                StreamNames = @($nativeCapture.StreamNames)
                NumberOfLinks = [uint32]$nativeCapture.NumberOfLinks
                IsDirectory = $false
                IsReparsePoint = $false
                Identity = $nativeCapture.IdentityV2
            }
        } else {
            $capture = Get-CodexSafeTreeDeleteLeafStreamSet -LiteralPath $absolutePath
        }
        $capturedKind = if ([bool]$capture.IsReparsePoint) {
            'directory-junction'
        } elseif ([bool]$capture.IsDirectory) {
            'directory'
        } else {
            'file'
        }
        if ($capturedKind -cne [string]$planned.kind) {
            throw "$scope leaf kind 漂移：$relativePath"
        }
        $liveStreams = [string[]]@($capture.StreamNames)
        if (($liveStreams -join "`n") -cne ([string[]]@($planned.streamNames) -join "`n")) {
            throw "$scope stream 漂移：$relativePath"
        }
        if ([string]$planned.kind -ceq 'file') {
            if ([long]$capture.NumberOfLinks -ne [long]$planned.hardLinkCount) {
                throw "$scope leaf hardlink 计数漂移：$relativePath"
            }
            # Amortized capture comes from the same lease the C# walker already
            # compared to fileIdentitiesV2. Re-comparing the PS-wrapped identity
            # object uses -ne reference semantics and false-drifts.
            if (-not $usedAmortizedCapture -and $capture.Identity -ne $planned.identity) {
                throw "$scope leaf FileIdentityV2 identity 漂移：$relativePath"
            }
        }
    }
}

function New-CodexSafeTreeDeleteLeafDispositionDocument {
    param(
        [Parameter(Mandatory)][object]$PlanStreamSet,
        [Parameter(Mandatory)][string]$GenerationId,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$QuarantinePath,
        [Parameter(Mandatory)][string]$PurgingTransactionUpdatedAtUtc,
        [AllowEmptyCollection()][object]$CommittedLeaves,
        [Parameter(Mandatory)][object]$PreflightLiveLeafSet,
        [string]$AbsentLeafEvidence = 'purging-subset-resume'
    )

    $deletedByPath = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($committed in @($CommittedLeaves)) {
        $committedPath = [string]$committed.path
        $committedKind = [string]$committed.kind
        $prefix = $QuarantinePath.TrimEnd('\') + '\'
        if (-not $committedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "safe-delete leaf disposition 删除路径越出 quarantine：$committedPath"
        }
        $relativePath = $committedPath.Substring($prefix.Length).Replace('\', '/')
        Assert-CodexHookDirectoryTreeRelativePath `
            -RelativePath $relativePath `
            -Scope 'safe-delete leaf disposition'
        if (-not $deletedByPath.TryAdd($relativePath, $committedKind)) {
            throw "safe-delete leaf disposition 删除回调重复：$relativePath"
        }
    }

    $rows = [Collections.Generic.List[object]]::new()
    $deletedCount = 0L
    $absentCount = 0L
    foreach ($leaf in @($PlanStreamSet.leaves)) {
        $relativePath = [string]$leaf.relativePath
        $kind = [string]$leaf.kind
        if ($kind -cnotin @('file', 'directory-junction')) { continue }
        if ($deletedByPath.ContainsKey($relativePath)) {
            if ([string]$deletedByPath[$relativePath] -cne $kind) {
                throw "safe-delete leaf disposition 删除回调 kind 漂移：$relativePath"
            }
            $disposition = 'deleted'
            $evidence = 'exclusive-lease-reverification'
            $deletedCount += 1L
        } elseif (-not $PreflightLiveLeafSet.Contains($relativePath)) {
            $disposition = 'absent-at-purge-resume'
            $evidence = $AbsentLeafEvidence
            $absentCount += 1L
        } else {
            throw "safe-delete leaf disposition 无法证明最终状态：$relativePath 既未在本轮删除也不缺席。"
        }
        $rows.Add([pscustomobject][ordered]@{
            relativePath = $relativePath
            kind = $kind
            disposition = $disposition
            evidence = $evidence
        })
    }
    foreach ($relativePath in $deletedByPath.Keys) {
        if (-not $PlanStreamSet.byPath.ContainsKey($relativePath)) {
            throw "safe-delete leaf disposition 删除回调越出计划 leaf：$relativePath"
        }
    }

    return [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-leaf-dispositions'
        schemaVersion = 1
        generationId = $GenerationId
        planSha256 = $PlanSha256
        transactionPath = $TransactionPath
        quarantinePath = $QuarantinePath
        purgingTransactionUpdatedAtUtc = $PurgingTransactionUpdatedAtUtc
        streamSetSource = 'plan.leafStreamSetV1'
        liveFreeze = 'target-mutex-and-per-leaf-exclusive-lease'
        leaves = @($rows)
        summary = [pscustomobject][ordered]@{
            plannedLeaves = [long]$rows.Count
            deleted = $deletedCount
            absentAtPurgeResume = $absentCount
        }
    }
}

function Publish-CodexSafeTreeDeleteLeafDispositions {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    if ($null -eq $Document -or $null -eq $Document.PSObject -or
        [string]$Document.artifactType -cne 'env-governance.codex-safe-tree-delete-leaf-dispositions' -or
        ($Document.schemaVersion -isnot [long] -and $Document.schemaVersion -isnot [int]) -or
        [long]$Document.schemaVersion -ne 1L) {
        throw 'safe-delete leaf dispositions artifact/schema 非法。'
    }
    $path = Join-Path $RunDirectory 'leaf-dispositions.json'
    [void](Assert-CodexHookCapabilityPath `
        -Path $path `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($path) `
        -Name 'safe-delete leaf dispositions')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Document | ConvertTo-Json -Depth 100))
    $sha256 = Get-CodexHookBytesSha256 -Bytes $bytes
    $existing = Get-CodexHookCapabilityFileSnapshot `
        -Path $path `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($path) `
        -Name 'safe-delete leaf dispositions before publish'
    if ([bool]$existing.exists) {
        if ([string]$existing.sha256 -ceq [string]$sha256) {
            return [pscustomobject][ordered]@{
                path = $path
                sha256 = [string]$sha256
            }
        }
        throw 'safe-delete leaf dispositions 漂移：已存在证据与本次内容不一致。'
    }
    [void](New-CodexHookCapabilityJson `
        -Path $path `
        -Document $Document `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($path) `
        -Scope 'safe-delete leaf dispositions publish')
    $published = Get-CodexHookCapabilityFileSnapshot `
        -Path $path `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($path) `
        -Name 'safe-delete leaf dispositions published'
    return [pscustomobject][ordered]@{
        path = $path
        sha256 = [string]$published.sha256
    }
}

function Read-CodexSafeTreeDeletePublishedLeafDispositions {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$GenerationId,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$QuarantinePath,
        [Parameter(Mandatory)][string]$PurgingTransactionUpdatedAtUtc,
        [Parameter(Mandatory)][object]$PlanStreamSet
    )

    $path = Join-Path $RunDirectory 'leaf-dispositions.json'
    $snapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $path `
        -CapabilityRoot $RunDirectory `
        -AllowedExactPaths @($path) `
        -Name 'safe-delete published leaf dispositions'
    if (-not [bool]$snapshot.exists) { return $null }
    if ([string]$snapshot.state -cne 'regular-file' -or $null -eq $snapshot.bytes) {
        throw 'safe-delete 既有 leaf dispositions 不可安全读取。'
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $text = $utf8.GetString([byte[]]$snapshot.bytes)
    } catch {
        throw 'safe-delete 既有 leaf dispositions 不是严格 UTF-8。'
    }
    Assert-CodexHookStrictJsonText -JsonText $text
    $document = $text | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $document `
        -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'planSha256',
            'transactionPath', 'quarantinePath', 'purgingTransactionUpdatedAtUtc',
            'streamSetSource', 'liveFreeze', 'leaves', 'summary'
        ) `
        -Scope 'safe-delete published leaf dispositions'
    if ([string]$document.artifactType -cne 'env-governance.codex-safe-tree-delete-leaf-dispositions' -or
        ($document.schemaVersion -isnot [long] -and $document.schemaVersion -isnot [int]) -or
        [long]$document.schemaVersion -ne 1L) {
        throw 'safe-delete leaf dispositions artifact/schema 非法。'
    }
    if ([string]$document.generationId -cne $GenerationId -or
        [string]$document.planSha256 -cne $PlanSha256 -or
        [string]$document.transactionPath -cne $TransactionPath -or
        [string]$document.quarantinePath -cne $QuarantinePath -or
        [string]$document.purgingTransactionUpdatedAtUtc -cne $PurgingTransactionUpdatedAtUtc -or
        [string]$document.streamSetSource -cne 'plan.leafStreamSetV1') {
        throw 'safe-delete 既有 leaf dispositions 与本 transaction 绑定不一致。'
    }
    if ($document.leaves -isnot [Array]) {
        throw 'safe-delete 既有 leaf dispositions leaves 必须是 JSON array。'
    }
    $expectedByPath = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($streamLeaf in @($PlanStreamSet.leaves)) {
        $streamLeafKind = [string]$streamLeaf.kind
        if ($streamLeafKind -cnotin @('file', 'directory-junction')) { continue }
        [void]$expectedByPath.Add([string]$streamLeaf.relativePath, $streamLeafKind)
    }
    $seenRows = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $deletedCount = 0L
    $absentCount = 0L
    $rowIndex = 0
    foreach ($row in @($document.leaves)) {
        $rowScope = "safe-delete published leaf dispositions leaves[$rowIndex]"
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $row `
            -Names @('relativePath', 'kind', 'disposition', 'evidence') `
            -Scope $rowScope
        if ($row.relativePath -isnot [string]) {
            throw "$rowScope relativePath 必须是 JSON string。"
        }
        $rowRelativePath = [string]$row.relativePath
        Assert-CodexHookDirectoryTreeRelativePath -RelativePath $rowRelativePath -Scope $rowScope
        $rowKind = [string]$row.kind
        if ($rowKind -cnotin @('file', 'directory-junction')) {
            throw "$rowScope kind 非法：$rowKind"
        }
        $rowDisposition = [string]$row.disposition
        $rowEvidence = [string]$row.evidence
        if ($rowDisposition -ceq 'deleted') {
            if ($rowEvidence -cne 'exclusive-lease-reverification') {
                throw "$rowScope disposition/evidence 配对非法：$rowDisposition/$rowEvidence"
            }
            $deletedCount += 1L
        } elseif ($rowDisposition -ceq 'absent-at-purge-resume') {
            if ($rowEvidence -cnotin @('purging-subset-resume', 'committed-missing-quarantine-journal')) {
                throw "$rowScope disposition/evidence 配对非法：$rowDisposition/$rowEvidence"
            }
            $absentCount += 1L
        } else {
            throw "$rowScope disposition 非法：$rowDisposition"
        }
        if (-not $expectedByPath.ContainsKey($rowRelativePath) -or
            [string]$expectedByPath[$rowRelativePath] -cne $rowKind) {
            throw "$rowScope 越出 plan stream-set 计划 leaf：$rowRelativePath"
        }
        if (-not $seenRows.Add($rowRelativePath)) {
            throw "$rowScope relativePath 重复：$rowRelativePath"
        }
        $rowIndex += 1
    }
    if ($seenRows.Count -ne $expectedByPath.Count) {
        throw 'safe-delete 既有 leaf dispositions leaves 未精确覆盖 plan stream-set 的 file/junction leaf。'
    }
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $document.summary `
        -Names @('plannedLeaves', 'deleted', 'absentAtPurgeResume') `
        -Scope 'safe-delete published leaf dispositions summary'
    foreach ($summaryField in @('plannedLeaves', 'deleted', 'absentAtPurgeResume')) {
        if ($document.summary.$summaryField -isnot [long] -and
            $document.summary.$summaryField -isnot [int]) {
            throw "safe-delete published leaf dispositions summary $summaryField 必须是 JSON integer。"
        }
    }
    if ([long]$document.summary.plannedLeaves -ne [long]$document.leaves.Count -or
        [long]$document.summary.deleted -ne $deletedCount -or
        [long]$document.summary.absentAtPurgeResume -ne $absentCount) {
        throw 'safe-delete 既有 leaf dispositions summary 与 leaves 行重述不一致。'
    }
    return [pscustomobject][ordered]@{
        path = [string]$snapshot.path
        sha256 = [string]$snapshot.sha256
    }
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

function Invoke-CodexSafeTreeDeleteArchiveBatch {
    # #85：一次调用归档多组 terminal 记录。每组原样走单组 Invoke-CodexSafeTreeDeleteArchive：独立认证
    # （approved SHA-256、evidence run 位置与内容绑定）、独立 target mutex、独立 create-only 发布。
    # 按输入顺序逐组处理；某组抛错只记入该组结果（archive-operation-failed + 原异常消息），不影响
    # 其他组。成功与结构化拒绝的结果行就是单组返回对象，前面加上本组 transactionPath。
    param(
        [Parameter(Mandatory)][string[]]$TransactionPaths,
        [Parameter(Mandatory)][string[]]$ApprovedTransactionSha256s,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    if ($TransactionPaths.Count -ne $ApprovedTransactionSha256s.Count) {
        throw 'safe-delete archive batch 的 transaction path 与 approved SHA-256 必须一一对应。'
    }
    $results = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $TransactionPaths.Count; $index++) {
        $transactionPath = [string]$TransactionPaths[$index]
        try {
            $archive = Invoke-CodexSafeTreeDeleteArchive `
                -TransactionPath $transactionPath `
                -ApprovedTransactionSha256 ([string]$ApprovedTransactionSha256s[$index]) `
                -EvidenceRoot $EvidenceRoot
            $row = [ordered]@{ transactionPath = $transactionPath }
            foreach ($property in $archive.PSObject.Properties) {
                $row[$property.Name] = $property.Value
            }
            $results.Add([pscustomobject]$row)
        } catch {
            $results.Add([pscustomobject][ordered]@{
                transactionPath = $transactionPath
                archived = $false
                alreadyArchived = $false
                refusalReason = 'archive-operation-failed'
                error = [string]$_.Exception.Message
            })
        }
    }

    $archivedCount = @($results | Where-Object { $_.archived -eq $true }).Count
    $failedCount = @($results | Where-Object { $null -ne $_.PSObject.Properties['error'] }).Count
    return [pscustomobject][ordered]@{
        completed = $archivedCount -eq $results.Count
        transactionCount = $results.Count
        archivedCount = $archivedCount
        alreadyArchivedCount = @($results | Where-Object { $_.alreadyArchived -eq $true }).Count
        refusedCount = $results.Count - $archivedCount - $failedCount
        failedCount = $failedCount
        results = @($results)
    }
}

function Add-CodexSafeTreeDeleteStatusElapsed {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][long]$Milliseconds
    )

    if ($null -eq $State -or $null -eq $State.PSObject.Properties[$Name]) {
        return
    }
    $State.$Name = [long]$State.$Name + $Milliseconds
}

function Resolve-CodexSafeTreeDeleteStatusManagedFilePath {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Name
    )

    if ($FileName -cnotin @('plan.json', 'transaction.json', 'terminal-archive.json')) {
        throw "$Name 不是 Status 受管 evidence 文件。"
    }
    $fullRun = Assert-CodexHookDPath -Value $RunDirectory -Name "$Name run"
    if (-not (Test-CodexSafeTreeDeletePathEqual `
            -Left (Split-Path -Parent $fullRun) `
            -Right $FullEvidenceRoot)) {
        throw "$Name 必须位于 evidence root 的直接 operation run 下。"
    }
    $fullPath = Assert-CodexHookDPath -Value (Join-Path $fullRun $FileName) -Name $Name
    if ($fullPath.Substring(2).Contains(':')) {
        throw "$Name 不得包含 NTFS alternate data stream。"
    }
    if (-not (Test-CodexHookPathWithin -Path $fullPath -ParentPath $fullRun) -or
        (Test-CodexSafeTreeDeletePathEqual -Left $fullPath -Right $fullRun)) {
        throw "$Name 越出 operation run。"
    }
    return $fullPath
}

function Read-CodexSafeTreeDeleteStatusManagedSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$MetricsObserver,
        [AllowNull()][object]$MetricsState,
        [ValidateSet('planTransactionRead', 'terminalArchiveAuth')]
        [string]$ReadSegment = 'planTransactionRead'
    )

    $readWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $native = [CodexHookGovernance.HandleBoundFileReader]::ReadAllBytes($Path)
    } catch {
        $leaf = Get-CodexHookInnermostException -Exception $_.Exception
        if ($leaf -is [CodexHookGovernance.HandlePathMismatchException]) {
            throw "$Name final path 与 lexical path 不一致。"
        }
        throw
    }
    $readWatch.Stop()
    $hashWatch = [Diagnostics.Stopwatch]::StartNew()
    [byte[]]$bytes = $native.Bytes
    $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $hashWatch.Stop()
    if ($null -ne $MetricsObserver) {
        & $MetricsObserver 'hash-read' 0L ([long]$bytes.Length)
    }
    $readSegmentName = if ($ReadSegment -ceq 'terminalArchiveAuth') {
        'segmentTerminalArchiveAuthMs'
    } else {
        'segmentPlanTransactionReadMs'
    }
    Add-CodexSafeTreeDeleteStatusElapsed -State $MetricsState -Name $readSegmentName -Milliseconds $readWatch.ElapsedMilliseconds
    Add-CodexSafeTreeDeleteStatusElapsed -State $MetricsState -Name 'segmentSha256Ms' -Milliseconds $hashWatch.ElapsedMilliseconds
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf
    try {
        $text = if ($hasBom) {
            $utf8.GetString($bytes, 3, $bytes.Length - 3)
        } else {
            $utf8.GetString($bytes)
        }
    } catch {
        throw "$Name 不是严格 UTF-8：$($_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{
        path = $Path
        sha256 = $sha256
        identity = @([string]$native.VolumeSerialNumber, [string]$native.FileIndex)
        text = $text
        bytes = $bytes
    }
}

function Get-CodexSafeTreeDeleteStatusJsonBindings {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Scope
    )

    $extracted = [CodexSafeTreeDelete.StatusJsonTopLevelReader]::ReadWanted($Text, $Names)
    $map = [ordered]@{}
    foreach ($pair in $extracted.GetEnumerator()) {
        $map[$pair.Key] = $pair.Value
    }
    return $map
}

function Get-CodexSafeTreeDeleteStatusJsonString {
    param(
        [Parameter(Mandatory)][object]$Map,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Scope
    )

    if (-not $Map.Contains($Name)) {
        throw "$Scope 缺少 $Name。"
    }
    $element = $Map[$Name]
    if ($element.ValueKind -ne [Text.Json.JsonValueKind]::String) {
        throw "$Scope $Name 必须是 JSON string。"
    }
    return [string]$element.GetString()
}

function Get-CodexSafeTreeDeleteStatusJsonInt64 {
    param(
        [Parameter(Mandatory)][object]$Map,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Scope
    )

    if (-not $Map.Contains($Name)) {
        throw "$Scope 缺少 $Name。"
    }
    $element = $Map[$Name]
    $value = 0L
    if ($element.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
        -not $element.TryGetInt64([ref]$value)) {
        throw "$Scope $Name 必须是 JSON integer。"
    }
    return $value
}

function Get-CodexSafeTreeDeleteStatusJsonArrayCount {
    param(
        [Parameter(Mandatory)][object]$Map,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Map.Contains($Name)) {
        return 0L
    }
    $element = $Map[$Name]
    if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Null) {
        return 0L
    }
    if ($element.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
        throw "safe-delete Status $Name 必须是 JSON array。"
    }
    return [long]$element.GetArrayLength()
}

function Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit {
    $processorCount = [Math]::Max(1, [int][Environment]::ProcessorCount)
    return [int][Math]::Min(8, [Math]::Max(1, $processorCount - 2))
}

function Test-CodexSafeTreeDeleteStatusFastScanEnabled {
    return $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN -cne '0'
}

function Invoke-CodexSafeTreeDeleteStatusFastScan {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RunItems,
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [AllowNull()][object]$MetricsState,
        [Parameter(Mandatory)][int]$DegreeOfParallelism
    )

    $runs = [Collections.Generic.List[CodexSafeTreeDelete.StatusScanRunInput]]::new()
    $index = 0
    foreach ($runItem in @($RunItems)) {
        $runInput = [CodexSafeTreeDelete.StatusScanRunInput]::new()
        $runInput.Index = $index
        $runInput.Name = [string]$runItem.Name
        $runInput.FullName = [string]$runItem.FullName
        $runInput.IsContainer = [bool]$runItem.PSIsContainer
        $runInput.IsReparsePoint = (($runItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        $runs.Add($runInput)
        $index++
    }
    $scanPolicy = [CodexSafeTreeDelete.StatusScanPolicy]@{
        Path = [string]$Policy.path
        Sha256 = [string]$Policy.sha256
        Entries = [Collections.Generic.List[CodexSafeTreeDelete.StatusScanPolicyEntry]]::new()
    }
    foreach ($entry in @($Policy.entries)) {
        $scanEntry = [CodexSafeTreeDelete.StatusScanPolicyEntry]::new()
        $scanEntry.Id = [string]$entry.id
        $scanEntry.CapabilityRoot = [string]$entry.capabilityRoot
        $scanEntry.MinimumDescendantDepth = [long]$entry.minimumDescendantDepth
        $scanEntry.RootDeletionPurpose = [string]$entry.rootDeletionPurpose
        $scanEntry.AllowHardLinks = [bool]$entry.allowHardLinks
        $scanEntry.AllowInternalDirectoryJunctions = [bool]$entry.allowInternalDirectoryJunctions
        $scanEntry.DeniedExactPaths = [Collections.Generic.List[string]]::new()
        foreach ($denied in @([string[]]$entry.deniedExactPaths)) {
            $scanEntry.DeniedExactPaths.Add([string]$denied)
        }
        $scanPolicy.Entries.Add($scanEntry)
    }
    $scanResults = [CodexSafeTreeDelete.StatusScanCoordinator]::Scan(
        $runs, $scanPolicy, $FullEvidenceRoot, $DegreeOfParallelism)
    $byPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($scanResult in @($scanResults)) {
        $runInput = $runs[$scanResult.Index]
        $byPath[[string]$runInput.FullName] = $scanResult
        # Handled results carry their own reads; unhandled active results with a plan
        # snapshot get injected into the prefetch cache below, so their single plan read
        # is counted here instead of a second PowerShell read.
        if ([bool]$scanResult.Handled -or $null -ne $scanResult.PlanSha256) {
            $metricsState.bytesHashed = [long]$metricsState.bytesHashed + [long]$scanResult.BytesHashed
            $metricsState.logicalBytes = [long]$metricsState.logicalBytes + [long]$scanResult.LogicalBytes
            Add-CodexSafeTreeDeleteStatusElapsed `
                -State $MetricsState `
                -Name 'segmentPlanTransactionReadMs' `
                -Milliseconds ([long]$scanResult.PlanTransactionReadMs)
            Add-CodexSafeTreeDeleteStatusElapsed `
                -State $MetricsState `
                -Name 'segmentTerminalArchiveAuthMs' `
                -Milliseconds ([long]$scanResult.TerminalArchiveAuthMs)
            Add-CodexSafeTreeDeleteStatusElapsed `
                -State $MetricsState `
                -Name 'segmentSha256Ms' `
                -Milliseconds ([long]$scanResult.Sha256Ms)
        }
    }
    return $byPath
}

function Select-CodexSafeTreeDeleteStatusScopeRunItems {
    # #80 范围查询在枚举阶段的预筛，fast scan 开关打开或关闭时都执行，所以两条路径的范围结果相同。
    # 每条规范形态记录只读 terminal-archive.json（存在时）或 plan.json 开头直到顶层 targetPath
    # 的一段，作为未经认证的归属声明。声明是合法的 D 盘路径，且原样和规范化后都不与任何范围目标
    # 按 OrdinalIgnoreCase 相等时，记录被排除：不读完整 plan，不进 fast scan，也不进参考路径。
    # 其余记录（非规范形态、读不到或读不全声明、声明不是合法路径）全部保留，交给完整认证和结果过滤。
    # 完整认证得到的 targetPath 与这份声明原样或规范化后按 OrdinalIgnoreCase 相等，所以被排除的
    # 记录在全量 Status 中也不会命中范围。代价：声明可读但完整认证会失败的范围外记录（例如
    # targetPath 之后被截断的 plan）不会作为无法归属的记录出现在范围结果里。
    # 前提：safe-delete gate 独占串行，Status 运行期间没有其他调用写 evidence。gate 若改成共享锁
    # 或允许并发写入 evidence，必须先重新论证这个前提，再保留预筛。
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RunItems,
        [Parameter(Mandatory)][string[]]$ScopeTargets,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][int]$DegreeOfParallelism
    )

    # 输入形态与 Invoke-CodexSafeTreeDeleteStatusFastScan 相同。
    $runs = [Collections.Generic.List[CodexSafeTreeDelete.StatusScanRunInput]]::new()
    $index = 0
    foreach ($runItem in @($RunItems)) {
        $runInput = [CodexSafeTreeDelete.StatusScanRunInput]::new()
        $runInput.Index = $index
        $runInput.Name = [string]$runItem.Name
        $runInput.FullName = [string]$runItem.FullName
        $runInput.IsContainer = [bool]$runItem.PSIsContainer
        $runInput.IsReparsePoint = (($runItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        $runs.Add($runInput)
        $index++
    }
    $keep = [CodexSafeTreeDelete.StatusScanCoordinator]::SelectScopeCandidates(
        $runs, $ScopeTargets, $FullEvidenceRoot, $DegreeOfParallelism)
    for ($index = 0; $index -lt $runs.Count; $index++) {
        if ($keep[$index]) {
            $RunItems[$index]
        }
    }
}

function New-CodexSafeTreeDeleteStatusOperationFromScan {
    param(
        [Parameter(Mandatory)][object]$ScanResult,
        [Parameter(Mandatory)][bool]$CandidatePolicyRequested
    )

    $namespaceAbsent = if ([bool]$ScanResult.HasNamespace) { [bool]$ScanResult.NamespaceAbsent } else { $null }
    $lifecycle = [string]$ScanResult.Lifecycle
    $safeActions = [string[]]$ScanResult.SafeActions
    $logicalCompletion = [bool]$ScanResult.LogicalCompletion
    $errors = [string[]]$ScanResult.Errors
    if ([bool]$ScanResult.RequiresRebuiltTargetIdentity) {
        $identityMatches = $false
        try {
            $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
                [string]$ScanResult.CapabilityRoot,
                [string]$ScanResult.TargetPath,
                $false)
            try {
                $actualIdentity = @(
                    [string]$guard.VolumeSerialNumber,
                    [string]$guard.FileIndex)
                $identityMatches = Test-CodexHookDirectoryTreeIdentityEqual `
                    -Expected @([string[]]$ScanResult.ExpectedTargetRootIdentity) `
                    -Actual $actualIdentity
            } finally {
                $guard.Dispose()
            }
        } catch {
            $lifecycle = 'manual-review'
            $safeActions = @('manual-review')
            $logicalCompletion = $false
            $errors = @($_.Exception.Message)
        }
        if ($lifecycle -ceq 'rebuildable-terminal-identity-pending') {
            if ($identityMatches) {
                $lifecycle = 'manual-review'
                $safeActions = @('manual-review')
                $logicalCompletion = $false
                $errors = @(
                    'purged rebuildable-build-output transaction 的 target identity 未变化，无法证明曾完成删除。')
            } else {
                $lifecycle = 'terminal'
                $safeActions = @()
                $logicalCompletion = $true
            }
        }
    }
    $deletionOutcome = New-CodexSafeTreeDeleteOutcome `
        -NamespaceAbsent $namespaceAbsent `
        -LogicalCompletion $logicalCompletion
    $planSchemaVersion = if ([bool]$ScanResult.HasPlanSchemaVersion) {
        [long]$ScanResult.PlanSchemaVersion
    } else {
        $null
    }
    $transactionSchemaVersion = if ([bool]$ScanResult.HasTransactionSchemaVersion) {
        [long]$ScanResult.TransactionSchemaVersion
    } else {
        $null
    }
    $operation = [pscustomobject][ordered]@{
        operationId = [string]$ScanResult.OperationId
        runDirectory = [string]$ScanResult.RunDirectory
        lifecycle = $lifecycle
        safeActions = $safeActions
        targetPath = $ScanResult.TargetPath
        quarantinePath = $ScanResult.QuarantinePath
        targetPresent = if ([bool]$ScanResult.HasNamespace) { [bool]$ScanResult.TargetPresent } else { $null }
        quarantinePresent = if ([bool]$ScanResult.HasNamespace) { [bool]$ScanResult.QuarantinePresent } else { $null }
        targetEntryType = [string]$ScanResult.TargetEntryType
        quarantineEntryType = [string]$ScanResult.QuarantineEntryType
        namespaceAbsent = $deletionOutcome.namespaceAbsent
        logicalCompletion = $deletionOutcome.logicalCompletion
        physicalReclaimStatus = $deletionOutcome.physicalReclaimStatus
        physicalReclaimReason = $deletionOutcome.physicalReclaimReason
        deletionOutcome = $deletionOutcome
        policyCompatible = [bool]$ScanResult.PolicyCompatible
        schemaCompatible = [bool]$ScanResult.SchemaCompatible
        candidatePolicyCompatible = if ($CandidatePolicyRequested) {
            $lifecycle -ceq 'terminal'
        } else {
            $null
        }
        planSchemaVersion = $planSchemaVersion
        transactionSchemaVersion = $transactionSchemaVersion
        transactionStatus = $ScanResult.TransactionStatus
        transactionUpdatedAtUtc = $ScanResult.TransactionUpdatedAtUtc
        journalStatus = [string]$ScanResult.JournalStatus
        pendingFiles = @()
        uncertainFiles = @()
        errors = $errors
    }
    return [pscustomobject][ordered]@{
        complete = [string]$ScanResult.Lifecycle -notin @('manual-review', 'inconsistent')
        operation = $operation
    }
}

function Read-CodexSafeTreeDeleteStatusUnarchivedPlanPrefetch {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RunItems,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][scriptblock]$MetricsObserver,
        [AllowNull()][object]$MetricsState
    )

    $cache = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.List[object]]::new()
    foreach ($runItem in @($RunItems)) {
        try {
            if (-not $runItem.PSIsContainer -or
                ($runItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            if ([IO.File]::Exists((Join-Path $runItem.FullName 'terminal-archive.json'))) {
                continue
            }
            if (-not [IO.File]::Exists((Join-Path $runItem.FullName 'plan.json'))) {
                continue
            }
            $runDirectory = Assert-CodexHookDPath `
                -Value $runItem.FullName `
                -Name 'safe-delete status run'
            [void](Assert-CodexHookCapabilityPath `
                -Path $runDirectory `
                -CapabilityRoot $FullEvidenceRoot `
                -AllowedExactPaths @($runDirectory) `
                -Name 'safe-delete status run')
            $resolvedPlanPath = Resolve-CodexSafeTreeDeleteStatusManagedFilePath `
                -RunDirectory $runDirectory `
                -FullEvidenceRoot $FullEvidenceRoot `
                -FileName 'plan.json' `
                -Name 'safe-delete status unarchived plan'
            $snapshot = Read-CodexSafeTreeDeleteStatusManagedSnapshot `
                -Path $resolvedPlanPath `
                -Name 'safe-delete status unarchived plan' `
                -MetricsObserver $MetricsObserver `
                -MetricsState $MetricsState `
                -ReadSegment planTransactionRead
            $pending.Add([pscustomobject]@{
                    runDirectory = $runDirectory
                    snapshot = [pscustomobject][ordered]@{
                        sha256 = [string]$snapshot.sha256
                        text = [string]$snapshot.text
                    }
                })
        } catch {
            continue
        }
    }

    $throttle = Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit
    foreach ($item in $pending) {
        $cache[[string]$item.runDirectory] = [pscustomobject][ordered]@{
            snapshot = $item.snapshot
            document = $null
        }
    }
    return [pscustomobject][ordered]@{
        cache = $cache
        throttleLimit = [int]$throttle
        prefetchedCount = [long]$pending.Count
        parsedCount = 0L
    }
}

function Get-CodexSafeTreeDeleteStatusCachedPlanManifestSha256 {
    param(
        [Parameter(Mandatory)][object]$PlanTreeManifest,
        [Parameter(Mandatory)][string]$PlanSha256,
        [AllowNull()][object]$Cache,
        [AllowNull()][string]$PlanText
    )

    if ($PlanSha256 -notmatch '^[0-9a-f]{64}$') {
        return Get-CodexSafeTreeDeleteManifestSha256 -Manifest $PlanTreeManifest
    }
    if ($null -ne $Cache -and $Cache.ContainsKey($PlanSha256)) {
        return [string]$Cache[$PlanSha256]
    }
    $sha = $null
    # issue #58：plan 文本流式重规范化 + SHA，与 ConvertFrom-Json→ConvertTo-Json 往返逐字节等价；
    # 非规范内容（重复属性、非规范数字、深度溢出、缺失/歧义 treeManifest）回退 PS 计算。
    if ($null -ne $PlanText -and $env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST -cne '0') {
        try {
            $sha = [CodexSafeTreeDelete.StatusPlanManifestSha256]::ComputeFromPlanText($PlanText)
        } catch [CodexSafeTreeDelete.StatusFastPathFallbackException] {
            $sha = $null
        }
    }
    if ($null -eq $sha) {
        $sha = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $PlanTreeManifest
    }
    if ($null -ne $Cache) {
        $Cache[$PlanSha256] = $sha
    }
    return $sha
}

function Get-CodexSafeTreeDeleteStatusLiveManifestSha256 {
    param([Parameter(Mandatory)][object]$Snapshot)

    if ($null -ne $Snapshot.PSObject.Properties['statusLiveManifestSha256']) {
        return [string]$Snapshot.statusLiveManifestSha256
    }
    $sha = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $Snapshot
    $Snapshot | Add-Member -NotePropertyName statusLiveManifestSha256 -NotePropertyValue $sha -Force
    return $sha
}

function Get-CodexSafeTreeDeleteStatusTreeSnapshotFast {
    # issue #58：Get-CodexHookCapabilityDirectoryTreeSnapshot 的 C# 单次遍历等价路径。
    # 前置校验、root guard 获取与 PS 参考路径逐句一致；C# 侧任何无法证明逐字节等价的
    # 情形抛 StatusFastPathFallbackException，由调用方回退到 PS 参考路径重放。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @(),
        [bool]$AllowHardLinks,
        [bool]$AllowInternalDirectoryJunctions,
        [AllowNull()][string]$InternalDirectoryJunctionTargetRoot,
        [Parameter(Mandatory)][object]$MetricsState,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AttachLiveManifestSha256
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
    $rootGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $capabilityRootPath,
        $fullPath,
        $false)
    try {
        $fast = [CodexSafeTreeDelete.StatusTreeSnapshotScanner]::Scan(
            $fullPath,
            $AllowHardLinks,
            $AllowInternalDirectoryJunctions,
            $junctionTargetRoot)
        if ([string]$rootGuard.VolumeSerialNumber -cne [string]$fast.RootIdentityVolume -or
            [string]$rootGuard.FileIndex -cne [string]$fast.RootIdentityIndex) {
            throw [CodexSafeTreeDelete.StatusFastPathFallbackException]::new('root-identity-mismatch')
        }
        $entries = $fast.MaterializeEntries()
        $snapshot = [pscustomobject][ordered]@{
            schemaVersion = 2
            rootIdentity = @([string]$fast.RootIdentityVolume, [string]$fast.RootIdentityIndex)
            entries = $entries
        }
        # 与参考路径逐 entry 触发 MetricsObserver 等价的聚合簿记（observer 仅累计这三个计数器）。
        $MetricsState.entriesScanned = [long]$MetricsState.entriesScanned + [long]$fast.Entries.Length
        $MetricsState.logicalBytes = [long]$MetricsState.logicalBytes + [long]$fast.FileContentBytes
        $MetricsState.bytesHashed =
            [long]$MetricsState.bytesHashed + [long]$fast.FileContentBytes + [long]$fast.ReparseDataBytes
        if ($AttachLiveManifestSha256) {
            $snapshot | Add-Member `
                -NotePropertyName statusLiveManifestSha256 `
                -NotePropertyValue ([string]$fast.ManifestSha256) `
                -Force
        }
        return $snapshot
    } finally {
        $rootGuard.Dispose()
    }
}

function Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string[]]$AllowedExactPaths,
        [bool]$AllowHardLinks,
        [bool]$AllowInternalDirectoryJunctions,
        [string]$InternalDirectoryJunctionTargetRoot,
        [scriptblock]$MetricsObserver,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$StatusTreeCache,
        [AllowNull()][object]$MetricsState,
        [switch]$AttachLiveManifestSha256
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $key = '{0}`n{1}`n{2}`n{3}`n{4}' -f @(
            $Path.ToUpperInvariant(),
            $CapabilityRoot.ToUpperInvariant(),
            [int][bool]$AllowHardLinks,
            [int][bool]$AllowInternalDirectoryJunctions,
            $(if ([string]::IsNullOrWhiteSpace($InternalDirectoryJunctionTargetRoot)) {
                ''
            } else {
                $InternalDirectoryJunctionTargetRoot.ToUpperInvariant()
            })
        )
        if ($null -ne $StatusTreeCache -and $StatusTreeCache.ContainsKey($key)) {
            $cached = $StatusTreeCache[$key]
            if ([IO.Directory]::Exists($Path)) {
                $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
                    $CapabilityRoot,
                    $Path,
                    $false)
                try {
                    $currentIdentity = @(
                        [string]$guard.VolumeSerialNumber,
                        [string]$guard.FileIndex)
                    if (Test-CodexHookDirectoryTreeIdentityEqual `
                            -Expected @($cached.rootIdentity) `
                            -Actual $currentIdentity) {
                        return $cached
                    }
                } finally {
                    $guard.Dispose()
                }
            }
        }
        $snapshot = $null
        if ($env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST -cne '0' -and
            $null -ne $MetricsState) {
            try {
                $snapshot = Get-CodexSafeTreeDeleteStatusTreeSnapshotFast `
                    -Path $Path `
                    -CapabilityRoot $CapabilityRoot `
                    -AllowedExactPaths $AllowedExactPaths `
                    -AllowHardLinks:$AllowHardLinks `
                    -AllowInternalDirectoryJunctions:$AllowInternalDirectoryJunctions `
                    -InternalDirectoryJunctionTargetRoot $InternalDirectoryJunctionTargetRoot `
                    -MetricsState $MetricsState `
                    -Name $Name `
                    -AttachLiveManifestSha256:$AttachLiveManifestSha256
            } catch [CodexSafeTreeDelete.StatusFastPathFallbackException] {
                # 非规范/异常输入回退：PS 参考路径重放，含精确的校验错误消息。
                $snapshot = $null
            }
        }
        if ($null -eq $snapshot) {
            $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                -Path $Path `
                -CapabilityRoot $CapabilityRoot `
                -AllowedExactPaths $AllowedExactPaths `
                -AllowHardLinks:$AllowHardLinks `
                -AllowInternalDirectoryJunctions:$AllowInternalDirectoryJunctions `
                -InternalDirectoryJunctionTargetRoot $InternalDirectoryJunctionTargetRoot `
                -MetricsObserver $MetricsObserver `
                -Name $Name
        }
        if ($null -ne $StatusTreeCache) {
            $StatusTreeCache[$key] = $snapshot
        }
        return $snapshot
    } finally {
        $watch.Stop()
        Add-CodexSafeTreeDeleteStatusElapsed `
            -State $MetricsState `
            -Name 'segmentTreeMaterializationMs' `
            -Milliseconds $watch.ElapsedMilliseconds
    }
}

function Read-CodexSafeTreeDeleteStatusTerminalArchive {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [scriptblock]$MetricsObserver,
        [AllowNull()][object]$MetricsState
    )

    $fullEvidenceRoot = Assert-CodexHookDPath -Value $EvidenceRoot -Name 'safe-delete status archive evidence root'
    $archivePath = Resolve-CodexSafeTreeDeleteStatusManagedFilePath `
        -RunDirectory $RunDirectory `
        -FullEvidenceRoot $fullEvidenceRoot `
        -FileName 'terminal-archive.json' `
        -Name 'safe-delete status terminal archive'
    $planPath = Resolve-CodexSafeTreeDeleteStatusManagedFilePath `
        -RunDirectory $RunDirectory `
        -FullEvidenceRoot $fullEvidenceRoot `
        -FileName 'plan.json' `
        -Name 'safe-delete status archive plan'
    $transactionPath = Resolve-CodexSafeTreeDeleteStatusManagedFilePath `
        -RunDirectory $RunDirectory `
        -FullEvidenceRoot $fullEvidenceRoot `
        -FileName 'transaction.json' `
        -Name 'safe-delete status archive transaction'
    $archiveSnapshot = Read-CodexSafeTreeDeleteStatusManagedSnapshot `
        -Path $archivePath `
        -Name 'safe-delete status terminal archive' `
        -MetricsObserver $MetricsObserver `
        -MetricsState $MetricsState `
        -ReadSegment terminalArchiveAuth
    $planSnapshot = Read-CodexSafeTreeDeleteStatusManagedSnapshot `
        -Path $planPath `
        -Name 'safe-delete status archive plan' `
        -MetricsObserver $MetricsObserver `
        -MetricsState $MetricsState `
        -ReadSegment planTransactionRead
    $transactionSnapshot = Read-CodexSafeTreeDeleteStatusManagedSnapshot `
        -Path $transactionPath `
        -Name 'safe-delete status archive transaction' `
        -MetricsObserver $MetricsObserver `
        -MetricsState $MetricsState `
        -ReadSegment planTransactionRead
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
    if (-not (Test-CodexSafeTreeDeletePathEqual -Left $archive.planPath -Right $planPath) -or
        -not (Test-CodexSafeTreeDeletePathEqual -Left $archive.transactionPath -Right $transactionPath)) {
        throw 'safe-delete terminal archive 引用越出 operation run。'
    }
    if ([string]$archive.planSha256 -cne [string]$planSnapshot.sha256 -or
        [string]$archive.transactionSha256 -cne [string]$transactionSnapshot.sha256) {
        throw 'safe-delete terminal archive 与当前受管 evidence 内容不一致。'
    }
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($archive.planIdentity) `
        -Actual @($planSnapshot.identity) `
        -Scope 'safe-delete terminal archive plan'
    Assert-CodexHookDirectoryTreeIdentity `
        -Expected @($archive.transactionIdentity) `
        -Actual @($transactionSnapshot.identity) `
        -Scope 'safe-delete terminal archive transaction'
    $planBindings = Get-CodexSafeTreeDeleteStatusJsonBindings `
        -Text $planSnapshot.text `
        -Names @('artifactType', 'schemaVersion', 'generationId', 'targetPath', 'policySha256') `
        -Scope 'safe-delete status archive plan'
    $planArtifactType = Get-CodexSafeTreeDeleteStatusJsonString `
        -Map $planBindings -Name 'artifactType' -Scope 'safe-delete status archive plan'
    $planSchemaVersion = Get-CodexSafeTreeDeleteStatusJsonInt64 `
        -Map $planBindings -Name 'schemaVersion' -Scope 'safe-delete status archive plan'
    $planGenerationId = Get-CodexSafeTreeDeleteStatusJsonString `
        -Map $planBindings -Name 'generationId' -Scope 'safe-delete status archive plan'
    $planTargetPath = Get-CodexSafeTreeDeleteStatusJsonString `
        -Map $planBindings -Name 'targetPath' -Scope 'safe-delete status archive plan'
    $planPolicySha256 = Get-CodexSafeTreeDeleteStatusJsonString `
        -Map $planBindings -Name 'policySha256' -Scope 'safe-delete status archive plan'
    $planGuid = [guid]::Empty
    if ($planArtifactType -cne 'env-governance.codex-safe-tree-delete-plan' -or
        $planSchemaVersion -ne 1L -or
        -not [guid]::TryParseExact($planGenerationId, 'D', [ref]$planGuid) -or
        $planPolicySha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'safe-delete status archive plan artifact/schema 非法。'
    }
    $expectedTargetPath = Assert-CodexHookDPath `
        -Value $planTargetPath `
        -Name 'safe-delete status archive plan target'
    $expectedQuarantinePath = Join-Path `
        (Split-Path -Parent $expectedTargetPath) `
        ('.codex-safe-delete-{0}.quarantine' -f $planGenerationId)
    $transactionBindings = Get-CodexSafeTreeDeleteStatusJsonBindings `
        -Text $transactionSnapshot.text `
        -Names @(
            'schemaVersion', 'status', 'updatedAtUtc', 'generationId',
            'planPath', 'planSha256', 'targetPath', 'quarantinePath',
            'restoreJournalAnchors'
        ) `
        -Scope 'safe-delete status archive transaction'
    $transactionSchemaVersion = Get-CodexSafeTreeDeleteStatusJsonInt64 `
        -Map $transactionBindings -Name 'schemaVersion' -Scope 'safe-delete status archive transaction'
    if ($transactionSchemaVersion -notin @(1L, 2L, 3L)) {
        throw 'safe-delete status archive transaction schemaVersion 必须是 JSON integer 1、2 或 3。'
    }
    if ($transactionSchemaVersion -eq 1L) {
        $transaction = $transactionSnapshot.text |
            ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        $observed = Read-CodexSafeTreeDeleteObservedV1Transaction `
            -Document $transaction `
            -TransactionPath $transactionPath `
            -PlanPath $planPath `
            -PlanSha256 ([string]$planSnapshot.sha256) `
            -Plan ([pscustomobject][ordered]@{
                artifactType = $planArtifactType
                schemaVersion = $planSchemaVersion
                generationId = $planGenerationId
                targetPath = $expectedTargetPath
            }) `
            -ExpectedTargetPath $expectedTargetPath `
            -ExpectedQuarantinePath $expectedQuarantinePath
        $transactionStatus = [string]$observed.status
        $transactionUpdatedAtUtc = [string]$observed.updatedAtUtc
        $sourceTargetPath = [string]$observed.targetPath
        $sourceQuarantinePath = [string]$observed.quarantinePath
        $restoreJournalAnchorCount = 0L
    } else {
        $transactionStatus = Get-CodexSafeTreeDeleteStatusJsonString `
            -Map $transactionBindings -Name 'status' -Scope 'safe-delete status archive transaction'
        $transactionUpdatedAtUtc = Get-CodexSafeTreeDeleteStatusJsonString `
            -Map $transactionBindings -Name 'updatedAtUtc' -Scope 'safe-delete status archive transaction'
        $transactionGenerationId = Get-CodexSafeTreeDeleteStatusJsonString `
            -Map $transactionBindings -Name 'generationId' -Scope 'safe-delete status archive transaction'
        $transactionPlanPath = Get-CodexSafeTreeDeleteStatusJsonString `
            -Map $transactionBindings -Name 'planPath' -Scope 'safe-delete status archive transaction'
        $transactionPlanSha256 = Get-CodexSafeTreeDeleteStatusJsonString `
            -Map $transactionBindings -Name 'planSha256' -Scope 'safe-delete status archive transaction'
        $sourceTargetPath = Get-CodexSafeTreeDeleteStatusJsonString `
            -Map $transactionBindings -Name 'targetPath' -Scope 'safe-delete status archive transaction'
        $sourceQuarantinePath = Get-CodexSafeTreeDeleteStatusJsonString `
            -Map $transactionBindings -Name 'quarantinePath' -Scope 'safe-delete status archive transaction'
        if ($transactionGenerationId -cne $planGenerationId -or
            [string]$transactionPlanSha256 -cne [string]$planSnapshot.sha256 -or
            -not (Test-CodexSafeTreeDeletePathEqual -Left $transactionPlanPath -Right $planPath) -or
            -not (Test-CodexSafeTreeDeletePathEqual -Left $sourceTargetPath -Right $expectedTargetPath) -or
            -not (Test-CodexSafeTreeDeletePathEqual -Left $sourceQuarantinePath -Right $expectedQuarantinePath)) {
            throw 'safe-delete terminal archive 与当前受管 evidence 内容不一致。'
        }
        $restoreJournalAnchorCount = Get-CodexSafeTreeDeleteStatusJsonArrayCount `
            -Map $transactionBindings -Name 'restoreJournalAnchors'
    }
    if ([string]$archive.generationId -cne $planGenerationId -or
        [long]$archive.transactionSchemaVersion -ne $transactionSchemaVersion -or
        [string]$archive.transactionUpdatedAtUtc -cne $transactionUpdatedAtUtc -or
        -not (Test-CodexSafeTreeDeletePathEqual -Left $archive.targetPath -Right $sourceTargetPath) -or
        -not (Test-CodexSafeTreeDeletePathEqual -Left $archive.quarantinePath -Right $sourceQuarantinePath)) {
        throw 'safe-delete terminal archive 与当前受管 evidence 内容不一致。'
    }
    if ($transactionStatus -cne 'purged') {
        throw 'safe-delete terminal archive transaction status 已漂移。'
    }
    if ($restoreJournalAnchorCount -ne 0L) {
        throw 'safe-delete terminal archive Restore journal anchors 已出现。'
    }
    $quarantineState = Get-CodexSafeTreeDeleteNamespaceState -Path $sourceQuarantinePath
    if ([bool]$quarantineState.present) {
        throw 'safe-delete terminal archive quarantine 已重新出现。'
    }
    $targetState = Get-CodexSafeTreeDeleteNamespaceState -Path $sourceTargetPath
    return [pscustomobject][ordered]@{
        path = $archivePath
        sha256 = [string]$archiveSnapshot.sha256
        identity = @($archiveSnapshot.identity)
        document = $archive
        source = [pscustomobject][ordered]@{
            plan = [pscustomobject][ordered]@{
                artifactType = $planArtifactType
                schemaVersion = $planSchemaVersion
                generationId = $planGenerationId
                targetPath = $expectedTargetPath
                policySha256 = $planPolicySha256
            }
            planSha256 = [string]$planSnapshot.sha256
            planIdentity = @($planSnapshot.identity)
            transactionSha256 = [string]$transactionSnapshot.sha256
            transactionIdentity = @($transactionSnapshot.identity)
            transactionSchemaVersion = $transactionSchemaVersion
            transactionStatus = $transactionStatus
            transactionUpdatedAtUtc = $transactionUpdatedAtUtc
            targetPath = $sourceTargetPath
            quarantinePath = $sourceQuarantinePath
            restoreJournalAnchorCount = $restoreJournalAnchorCount
        }
        targetState = $targetState
        quarantineState = $quarantineState
    }
}

function Resolve-CodexSafeTreeDeleteArchivedStatusOperation {
    param(
        [Parameter(Mandatory)][object]$RunItem,
        [Parameter(Mandatory)][string]$CurrentPolicySha256,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][bool]$CandidatePolicyRequested,
        [Parameter(Mandatory)][scriptblock]$MetricsObserver,
        [AllowNull()][object]$MetricsState
    )

    $archive = Read-CodexSafeTreeDeleteStatusTerminalArchive `
        -RunDirectory ([string]$RunItem.FullName) `
        -EvidenceRoot $FullEvidenceRoot `
        -MetricsObserver $MetricsObserver `
        -MetricsState $MetricsState
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
        pendingFiles = @()
        uncertainFiles = @()
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
        [Parameter(Mandatory)][scriptblock]$TreeMetricsObserver,
        [AllowNull()][object]$StatusTreeCache,
        [AllowNull()][object]$LoadedPolicy,
        [AllowNull()][object]$StatusPlanPrefetch,
        [AllowNull()][object]$PlanManifestShaCache
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
        $pendingFiles = @()
        $uncertainFiles = @()
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
                    -MetricsObserver $TreeMetricsObserver `
                    -MetricsState $MetricsState
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
            $prefetchedPlan = $null
            if ($null -ne $StatusPlanPrefetch -and $StatusPlanPrefetch.ContainsKey($runDirectory)) {
                $prefetchedPlan = $StatusPlanPrefetch[$runDirectory]
            }
            if ($null -ne $prefetchedPlan -and $null -ne $prefetchedPlan.snapshot) {
                $planSnapshot = $prefetchedPlan.snapshot
            } else {
                $planSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                    -Path $planPath `
                    -Name 'safe-delete status plan' `
                    -AllowedExactPaths @($planPath)
                $metricsState.bytesHashed = [long]$metricsState.bytesHashed + $planSnapshot.bytes.Length
            }
            $statusPlanValidationMatches = $false
            if ($null -ne $prefetchedPlan -and
                $prefetchedPlan.PSObject.Properties.Name -contains 'approvedPlanValidation' -and
                $prefetchedPlan.approvedPlanValidation -is [CodexSafeTreeDelete.StatusPlanValidationReceipt] -and
                $null -eq $prefetchedPlan.document) {
                # issue #58 N4：大 plan 文本跨 PS 方法边界会被绑定器整串复制
                # （109M 字符 ≈12s/次）；prefetch 快照与 scanResult 同源（同对象、
                # receipt 同一实例）时内容比对收进 C# 同实例完成，sha256 短串比对
                # 维持快照到 receipt 的内容绑定。其余来源沿用全文比对。
                $prefetchScanResult = if ($prefetchedPlan.PSObject.Properties.Name -contains 'scanResult') {
                    $prefetchedPlan.scanResult
                } else {
                    $null
                }
                if ($null -ne $prefetchScanResult -and
                    $prefetchScanResult -is [CodexSafeTreeDelete.StatusScanResult] -and
                    [object]::ReferenceEquals($planSnapshot, $prefetchedPlan.snapshot) -and
                    [object]::ReferenceEquals(
                        $prefetchedPlan.approvedPlanValidation,
                        $prefetchScanResult.ApprovedPlanValidation) -and
                    $prefetchedPlan.approvedPlanValidation.MatchesPlanSha256(
                        [string]$planSnapshot.sha256)) {
                    $statusPlanValidationMatches =
                        $prefetchScanResult.ValidateReceiptAgainstOwnSnapshot()
                } else {
                    $statusPlanValidationMatches =
                        $prefetchedPlan.approvedPlanValidation.MatchesSnapshot(
                            [string]$planSnapshot.sha256,
                            [string]$planSnapshot.text)
                }
            }
            if (-not $statusPlanValidationMatches) {
                Assert-CodexHookStrictJsonText -JsonText $planSnapshot.text
            }
            if ($statusPlanValidationMatches) {
                # The receipt is issued only for schema 1; the reader owns the sole parse.
                $plan = $null
                $planSchemaVersion = 1L
            } elseif ($null -ne $prefetchedPlan -and $null -ne $prefetchedPlan.document) {
                $plan = $prefetchedPlan.document
            } else {
                $plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
            }
            if ($null -ne $plan) { $planSchemaVersion = [long]$plan.schemaVersion }
            $statusPlanValidation = $null
            if ($statusPlanValidationMatches) {
                $statusPlanValidation = $prefetchedPlan.approvedPlanValidation
            }
            $approvedPreparsedDocument = if ($null -eq $statusPlanValidation) { $plan } else { $null }
            try {
                $approvedPlan = Read-CodexSafeTreeDeleteApprovedPlan `
                    -PlanPath $planPath `
                    -ApprovedPlanSha256 ([string]$planSnapshot.sha256) `
                    -PolicyPath $PolicyPath `
                    -EvidenceRoot $fullEvidenceRoot `
                    -AllowMissingTarget `
                    -AllowExpiredPlan `
                    -AllowPolicyShaDrift `
                    -MetricsObserver $treeMetricsObserver `
                    -PreloadedSnapshot $planSnapshot `
                    -PreparsedDocument $approvedPreparsedDocument `
                    -LoadedPolicy $LoadedPolicy `
                    -PlanManifestShaCache $PlanManifestShaCache `
                    -StatusPlanValidation $statusPlanValidation
                $plan = $approvedPlan.document
                if ($null -ne $statusPlanValidation -and
                    $statusPlanValidationMatches -and
                    $MetricsState.PSObject.Properties.Name -contains 'approvedPlanValidationReuseCount') {
                    $MetricsState.approvedPlanValidationReuseCount =
                        [long]$MetricsState.approvedPlanValidationReuseCount + 1L
                }
            } catch {
                $planApprovalError = $_.Exception.Message
                if (-not [IO.File]::Exists($transactionPath)) { throw }
                if ($null -eq $plan) {
                    $plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
                }
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
                if ($transactionSchemaVersion -notin @(1L, 2L, 3L)) { throw }
                if ($plan.targetPath -isnot [string] -or $plan.generationId -isnot [string]) { throw }
                $observedTargetPath = [string]$plan.targetPath
                $observedQuarantinePath = Join-Path `
                    (Split-Path -Parent $observedTargetPath) `
                    ('.codex-safe-delete-{0}.quarantine' -f ([string]$plan.generationId))
                if ($transactionSchemaVersion -eq 1L) {
                    $observedTransaction = Read-CodexSafeTreeDeleteObservedV1Transaction `
                        -Document $transaction `
                        -TransactionPath $transactionPath `
                        -PlanPath $planPath `
                        -PlanSha256 ([string]$planSnapshot.sha256) `
                        -Plan $plan `
                        -ExpectedTargetPath $observedTargetPath `
                        -ExpectedQuarantinePath $observedQuarantinePath
                } else {
                    $observedDocument = ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument `
                        -Document $transaction
                    if ($plan.artifactType -cne 'env-governance.codex-safe-tree-delete-plan' -or
                        $plan.schemaVersion -isnot [long] -or [long]$plan.schemaVersion -ne 1L) {
                        throw 'safe-delete observed transaction 的 plan artifact/schema 非法。'
                    }
                    $observedPlanGenerationId = [guid]::Empty
                    if (-not [guid]::TryParseExact(
                            [string]$plan.generationId, 'D', [ref]$observedPlanGenerationId)) {
                        throw 'safe-delete observed transaction 的 plan generationId 非法。'
                    }
                    if ([string]$observedDocument.generationId -cne [string]$plan.generationId -or
                        -not (Test-CodexSafeTreeDeletePathEqual `
                            -Left ([string]$observedDocument.planPath) `
                            -Right $planPath) -or
                        [string]$observedDocument.planSha256 -cne [string]$planSnapshot.sha256 -or
                        -not (Test-CodexSafeTreeDeletePathEqual `
                            -Left ([string]$observedDocument.targetPath) `
                            -Right $observedTargetPath) -or
                        -not (Test-CodexSafeTreeDeletePathEqual `
                            -Left ([string]$observedDocument.quarantinePath) `
                            -Right $observedQuarantinePath)) {
                        throw "safe-delete observed transaction 与受管 plan 不一致：$transactionPath"
                    }
                    $observedTransaction = [pscustomobject][ordered]@{
                        targetPath = [string]$observedDocument.targetPath
                        quarantinePath = [string]$observedDocument.quarantinePath
                        status = [string]$observedDocument.status
                        updatedAtUtc = [string]$observedDocument.updatedAtUtc
                    }
                }
                $targetPath = [string]$observedTransaction.targetPath
                $quarantinePath = [string]$observedTransaction.quarantinePath
                $transactionStatus = [string]$observedTransaction.status
                $transactionUpdatedAtUtc = [string]$observedTransaction.updatedAtUtc
                $schemaCompatible = $false
                $journalStatus = 'unavailable'
                $observedTargetState = Get-CodexSafeTreeDeleteNamespaceState -Path $targetPath
                $observedQuarantineState = Get-CodexSafeTreeDeleteNamespaceState -Path $quarantinePath
                $targetPresent = [bool]$observedTargetState.present
                $quarantinePresent = [bool]$observedQuarantineState.present
                $targetEntryType = [string]$observedTargetState.entryType
                $quarantineEntryType = [string]$observedQuarantineState.entryType
                $errors.Add("plan 当前语义拒绝：$planApprovalError")
                if ($transactionSchemaVersion -eq 1L) {
                    throw 'transaction v1 仅支持 Status 只读观测；Purge/Restore 不可恢复且继续拒绝。'
                }
                throw 'plan 被当前 policy 拒绝；transaction 仅支持 Status 只读观测，Apply/Purge/Restore 继续拒绝。'
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
                    $plannedTree = Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
                        -Path $targetPath `
                        -CapabilityRoot ([string]$approvedPlan.target.capabilityRoot) `
                        -AllowedExactPaths @($targetPath) `
                        -AllowHardLinks:([bool]$approvedPlan.target.allowHardLinks) `
                        -AllowInternalDirectoryJunctions:([bool]$approvedPlan.target.allowInternalDirectoryJunctions) `
                        -InternalDirectoryJunctionTargetRoot $targetPath `
                        -MetricsObserver $treeMetricsObserver `
                        -Name 'safe-delete status planned tree' `
                        -StatusTreeCache $StatusTreeCache `
                        -MetricsState $MetricsState `
                        -AttachLiveManifestSha256
                    if ((Get-CodexSafeTreeDeleteStatusLiveManifestSha256 -Snapshot $plannedTree) -cne
                        (Get-CodexSafeTreeDeleteStatusCachedPlanManifestSha256 `
                            -PlanTreeManifest $plan.treeManifest `
                            -PlanSha256 ([string]$planSnapshot.sha256) `
                            -Cache $PlanManifestShaCache `
                            -PlanText ([string]$planSnapshot.text))) {
                        throw 'safe-delete Status planned tree manifest 漂移。'
                    }
                    Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
                        -Plan $plan `
                        -Target $approvedPlan.target `
                        -TreePath $targetPath `
                        -Scope 'safe-delete status planned'
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
                    -MetricsObserver $treeMetricsObserver `
                    -StatusPlanValidation $statusPlanValidation
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
                $inFlightRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
                    -RunDirectory $runDirectory `
                    -GenerationId ([string]$plan.generationId) `
                    -DirectoryCommitAnchors @($transaction.directoryCommitAnchors) `
                    -QuarantinePath $quarantinePath `
                    -MetricsObserver $treeMetricsObserver
                $pendingFiles = @($inFlightRecovery.pendingFiles)
                $uncertainFiles = @($inFlightRecovery.uncertainFiles)
                if ($transactionStatus -cin @('prepared', 'quarantined', 'restored', 'rolled-back') -and
                    @($transaction.directoryCommitAnchors).Count -ne 0) {
                    $journalStatus = 'invalid'
                    throw "$transactionStatus transaction 不得包含 directory commit journal。"
                }
                if ($transactionStatus -ceq 'purging') {
                    if ($targetEntryType -ceq 'absent' -and $quarantineEntryType -ceq 'directory') {
                        $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot `
                            -Target $approvedTransaction.approvedPlan.target
                        $quarantineTree = Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
                            -Path $quarantinePath `
                            -CapabilityRoot $quarantineCapabilityRoot `
                            -AllowedExactPaths @($quarantinePath) `
                            -AllowHardLinks:([bool]$approvedTransaction.approvedPlan.target.allowHardLinks) `
                            -AllowInternalDirectoryJunctions:([bool]$approvedTransaction.approvedPlan.target.allowInternalDirectoryJunctions) `
                            -InternalDirectoryJunctionTargetRoot $targetPath `
                            -MetricsObserver $treeMetricsObserver `
                            -Name 'safe-delete status purge-resumable tree' `
                            -StatusTreeCache $StatusTreeCache `
                            -MetricsState $MetricsState
                        Assert-CodexSafeTreeDeletePartialPurgeManifest `
                            -CurrentManifest $quarantineTree `
                            -PlannedManifest $plan.treeManifest
                        Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
                            -Plan $plan `
                            -Target $approvedTransaction.approvedPlan.target `
                            -TreePath $quarantinePath `
                            -Scope 'safe-delete status purge-resumable'
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
                    if (@($uncertainFiles).Count -gt 0) {
                        $lifecycle = 'manual-review'
                        $safeActions = @('manual-review')
                        $complete = $false
                        $errors.Add(
                            'purging freeze-prepared 路径已消失，状态 uncertain，不得假设已删除；请手工核验后再决定重新 Plan 或保持 manual-review。')
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
                    if ([string]$approvedTransaction.approvedPlan.target.rootDeletionPurpose -ceq
                            'retired-evidence-root') {
                        Assert-CodexSafeTreeDeleteRetiredEvidenceRootLeafDispositions `
                            -RunDirectory $runDirectory `
                            -Plan $plan `
                            -PlanSha256 ([string]$planSnapshot.sha256) `
                            -Transaction $transaction `
                            -MetricsObserver $treeMetricsObserver
                    }
                    $lifecycle = 'terminal'
                    $safeActions = @()
                } elseif ($transactionStatus -cin @('restored', 'rolled-back')) {
                    if ($targetEntryType -cne 'directory' -or $quarantineEntryType -cne 'absent') {
                        throw "$transactionStatus transaction 的 live namespace 不一致。"
                    }
                    $terminalTree = Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
                        -Path $targetPath `
                        -CapabilityRoot ([string]$approvedTransaction.approvedPlan.target.capabilityRoot) `
                        -AllowedExactPaths @($targetPath) `
                        -AllowHardLinks:([bool]$approvedTransaction.approvedPlan.target.allowHardLinks) `
                        -AllowInternalDirectoryJunctions:([bool]$approvedTransaction.approvedPlan.target.allowInternalDirectoryJunctions) `
                        -InternalDirectoryJunctionTargetRoot $targetPath `
                        -MetricsObserver $treeMetricsObserver `
                        -Name 'safe-delete Status terminal restored tree' `
                        -StatusTreeCache $StatusTreeCache `
                        -MetricsState $MetricsState `
                        -AttachLiveManifestSha256
                    if ((Get-CodexSafeTreeDeleteStatusLiveManifestSha256 -Snapshot $terminalTree) -cne
                        (Get-CodexSafeTreeDeleteStatusCachedPlanManifestSha256 `
                            -PlanTreeManifest $plan.treeManifest `
                            -PlanSha256 ([string]$planSnapshot.sha256) `
                            -Cache $PlanManifestShaCache `
                            -PlanText ([string]$planSnapshot.text))) {
                        throw "$transactionStatus transaction 的 target tree 漂移。"
                    }
                    Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
                        -Plan $plan `
                        -Target $approvedTransaction.approvedPlan.target `
                        -TreePath $targetPath `
                        -Scope 'safe-delete status restored'
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
                        $quarantineTree = Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
                            -Path $quarantinePath `
                            -CapabilityRoot $quarantineCapabilityRoot `
                            -AllowedExactPaths @($quarantinePath) `
                            -AllowHardLinks:([bool]$approvedTransaction.approvedPlan.target.allowHardLinks) `
                            -AllowInternalDirectoryJunctions:([bool]$approvedTransaction.approvedPlan.target.allowInternalDirectoryJunctions) `
                            -InternalDirectoryJunctionTargetRoot $targetPath `
                            -MetricsObserver $treeMetricsObserver `
                            -Name 'safe-delete status recoverable tree' `
                            -StatusTreeCache $StatusTreeCache `
                            -MetricsState $MetricsState `
                            -AttachLiveManifestSha256
                        if ((Get-CodexSafeTreeDeleteStatusLiveManifestSha256 -Snapshot $quarantineTree) -cne
                            (Get-CodexSafeTreeDeleteStatusCachedPlanManifestSha256 `
                                -PlanTreeManifest $plan.treeManifest `
                                -PlanSha256 ([string]$planSnapshot.sha256) `
                                -Cache $PlanManifestShaCache `
                                -PlanText ([string]$planSnapshot.text))) {
                            throw 'safe-delete Status recoverable tree manifest 漂移。'
                        }
                        Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
                            -Plan $plan `
                            -Target $approvedTransaction.approvedPlan.target `
                            -TreePath $quarantinePath `
                            -Scope 'safe-delete status recoverable'
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
            if (-not $policyCompatible -and $null -eq $transactionSchemaVersion -and
                -not ($targetEntryType -ceq 'absent' -and $quarantineEntryType -ceq 'absent')) {
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
            pendingFiles = @($pendingFiles)
            uncertainFiles = @($uncertainFiles)
            errors = @($errors)
        }
        return [pscustomobject][ordered]@{
            complete = $complete
            operation = $operation
        }
    }

function Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation {
    # issue #58 N3：receipt 门控的 fallback 快路径。fast scan 已对快照绑定的 plan 完成受管
    # 批准校验（receipt 可证明），本函数只在该结论覆盖、且参考路径可达结果塌缩为唯一记录
    # 的分支上直接组装记录；其余一切输入返回 $null，由调用方回退
    # Resolve-CodexSafeTreeDeleteStatusOperation 参考路径重放。
    # N5 L1：planned 分支的树扫描与 T1 复核读会向 MetricsState 计数，函数主体整体包在
    # try/catch 内——任何未预期异常都把 7 个数值 metrics 字段回滚到入口快照、逐出本调用
    # 新增的树缓存项，然后返回 $null 按单 op 降级（参考重放重新计数，metrics 与纯串行
    # 逐字段一致；不再拖垮整个 worker 触发整批串行重放）。PlanManifestShaCache 的写入是
    # 确定性值，参考重放命中同键同值，保留不回滚。
    param(
        [Parameter(Mandatory)][object]$RunItem,
        [Parameter(Mandatory)][string]$CurrentPolicySha256,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][object]$MetricsState,
        [Parameter(Mandatory)][scriptblock]$TreeMetricsObserver,
        [Parameter(Mandatory)][object]$StatusTreeCache,
        [Parameter(Mandatory)][object]$LoadedPolicy,
        [AllowNull()][object]$StatusPlanPrefetch,
        [AllowNull()][object]$PlanManifestShaCache
    )

    $metricsOnEntry = @{
        entriesScanned = [long]$MetricsState.entriesScanned
        logicalBytes = [long]$MetricsState.logicalBytes
        bytesHashed = [long]$MetricsState.bytesHashed
        segmentPlanTransactionReadMs = [long]$MetricsState.segmentPlanTransactionReadMs
        segmentTerminalArchiveAuthMs = [long]$MetricsState.segmentTerminalArchiveAuthMs
        segmentTreeMaterializationMs = [long]$MetricsState.segmentTreeMaterializationMs
        segmentSha256Ms = [long]$MetricsState.segmentSha256Ms
    }
    $statusTreeCacheKeysOnEntry = @($StatusTreeCache.Keys)
    try {
        if ($env:CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST -ceq '0') { return $null }
        if (-not $RunItem.PSIsContainer -or
            ($RunItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $null
        }
        if ($null -eq $StatusPlanPrefetch) { return $null }
        try {
            $runDirectory = Assert-CodexHookDPath -Value $RunItem.FullName -Name 'safe-delete status run'
            [void](Assert-CodexHookCapabilityPath `
                -Path $runDirectory `
                -CapabilityRoot $FullEvidenceRoot `
                -AllowedExactPaths @($runDirectory) `
                -Name 'safe-delete status run')
        } catch { return $null }
        if ([IO.File]::Exists((Join-Path $runDirectory 'terminal-archive.json'))) { return $null }
        $planPath = Join-Path $runDirectory 'plan.json'
        if (-not [IO.File]::Exists($planPath)) { return $null }
        if (-not $StatusPlanPrefetch.ContainsKey($runDirectory)) { return $null }
        $prefetchedPlan = $StatusPlanPrefetch[$runDirectory]
        if ($null -eq $prefetchedPlan -or
            $null -eq $prefetchedPlan.snapshot -or
            $prefetchedPlan.PSObject.Properties.Name -notcontains 'approvedPlanValidation' -or
            $prefetchedPlan.approvedPlanValidation -isnot [CodexSafeTreeDelete.StatusPlanValidationReceipt] -or
            $null -ne $prefetchedPlan.document) {
            return $null
        }
        $planSnapshot = $prefetchedPlan.snapshot
        $receipt = $prefetchedPlan.approvedPlanValidation
        try {
            $fullPlanPath = Assert-CodexHookDPath -Value $planPath -Name 'safe-delete plan path'
        } catch { return $null }
        # issue #58 N4：大 plan 文本不作为 .NET 方法实参跨边界（PS 绑定器整串复制，
        # 实测 109M 字符单参 ≈6-12s）。prefetch 快照与 receipt 同源（同一
        # StatusScanResult）时，内容比对收进 C# 同实例完成；sha256 短串比对把
        # pscustomobject 快照绑定到 receipt 校验过的内容。
        $prefetchScanResult = if ($prefetchedPlan.PSObject.Properties.Name -contains 'scanResult') {
            $prefetchedPlan.scanResult
        } else {
            $null
        }
        if ($null -eq $prefetchScanResult -or
            $prefetchScanResult -isnot [CodexSafeTreeDelete.StatusScanResult] -or
            -not [object]::ReferenceEquals($receipt, $prefetchScanResult.ApprovedPlanValidation) -or
            -not $receipt.MatchesPlanSha256([string]$planSnapshot.sha256) -or
            -not $receipt.MatchesPlanPath($fullPlanPath) -or
            -not $prefetchScanResult.ValidateReceiptAgainstOwnSnapshot()) {
            return $null
        }
        $planTargetPath = if ($prefetchedPlan.PSObject.Properties.Name -contains 'receiptPlanTargetPath') {
            $prefetchedPlan.receiptPlanTargetPath
        } else {
            $null
        }
        $planCapabilityRoot = if ($prefetchedPlan.PSObject.Properties.Name -contains 'receiptPlanCapabilityRoot') {
            $prefetchedPlan.receiptPlanCapabilityRoot
        } else {
            $null
        }
        $planPolicySha256 = if ($prefetchedPlan.PSObject.Properties.Name -contains 'receiptPlanPolicySha256') {
            $prefetchedPlan.receiptPlanPolicySha256
        } else {
            $null
        }
        $planQuarantinePath = if ($prefetchedPlan.PSObject.Properties.Name -contains 'receiptPlanQuarantinePath') {
            $prefetchedPlan.receiptPlanQuarantinePath
        } else {
            $null
        }
        if ([string]::IsNullOrEmpty($planTargetPath) -or
            [string]::IsNullOrEmpty($planCapabilityRoot) -or
            [string]::IsNullOrEmpty($planPolicySha256) -or
            [string]::IsNullOrEmpty($planQuarantinePath)) {
            return $null
        }
        $policyEntry = @($LoadedPolicy.entries | Where-Object {
            Test-CodexSafeTreeDeletePathEqual `
                -Left ([string]$_.capabilityRoot) `
                -Right ([string]$planCapabilityRoot)
        })
        if ($policyEntry.Count -ne 1) { return $null }

        $policyCompatible = [string]$planPolicySha256 -ceq $CurrentPolicySha256
        $targetPath = [string]$planTargetPath
        $quarantinePath = [string]$planQuarantinePath
        $targetState = Get-CodexSafeTreeDeleteNamespaceState -Path $targetPath
        $quarantineState = Get-CodexSafeTreeDeleteNamespaceState -Path $quarantinePath
        $targetPresent = [bool]$targetState.present
        $quarantinePresent = [bool]$quarantineState.present
        $targetEntryType = [string]$targetState.entryType
        $quarantineEntryType = [string]$quarantineState.entryType

        $complete = $true
        $errors = [Collections.Generic.List[string]]::new()
        $lifecycle = 'manual-review'
        $safeActions = @('manual-review')
        $schemaCompatible = $false
        $journalStatus = 'not-evaluated'
        $transactionSchemaVersion = $null
        $transactionStatus = $null
        $transactionUpdatedAtUtc = $null

        if ($targetEntryType -cin @('file', 'reparse-point', 'other') -or
            $quarantineEntryType -cin @('file', 'reparse-point', 'other')) {
            # 参考路径命名空间类型 throw 分支：journal/schema 保持初值。
            $complete = $false
            $errors.Add('safe-delete Status target/quarantine namespace entry 不是普通目录。')
        } elseif (-not [IO.File]::Exists((Join-Path $runDirectory 'transaction.json'))) {
            # planned 分支：树扫描与 manifest 比对沿用参考 wrapper（缓存与 metrics 逐句一致）。
            $schemaCompatible = $true
            $journalStatus = 'not-started'
            $lifecycle = if ($targetEntryType -ceq 'directory' -and
                $quarantineEntryType -ceq 'absent') { 'planned' } else { 'inconsistent' }
            $safeActions = if ($lifecycle -ceq 'planned') { @('apply') } else { @('manual-review') }
            if ($lifecycle -ceq 'planned') {
                # N4：cache key 取 receipt 已绑定的 scanResult plan SHA（属性读取免封送）。
                $planShaKey = [string]$prefetchScanResult.PlanSha256
                $planManifestSha = $null
                if ($null -ne $PlanManifestShaCache -and $PlanManifestShaCache.ContainsKey($planShaKey)) {
                    $planManifestSha = [string]$PlanManifestShaCache[$planShaKey]
                } else {
                    if ($prefetchedPlan.PSObject.Properties.Name -contains 'planManifestSha256' -and
                        -not [string]::IsNullOrEmpty($prefetchedPlan.planManifestSha256)) {
                        $planManifestSha = [string]$prefetchedPlan.planManifestSha256
                    }
                    if ($null -eq $planManifestSha) {
                        # C# 侧对同一快照的流式 SHA 已确定性失败；在此重试只会把大 plan
                        # 文本再跨一次方法边界（整串复制）。回退参考路径自行解析并计算。
                        return $null
                    }
                    if ($null -ne $PlanManifestShaCache) {
                        $PlanManifestShaCache[$planShaKey] = $planManifestSha
                    }
                }
                $plannedTree = Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot `
                    -Path $targetPath `
                    -CapabilityRoot ([string]$planCapabilityRoot) `
                    -AllowedExactPaths @($targetPath) `
                    -AllowHardLinks:([bool]$policyEntry[0].allowHardLinks) `
                    -AllowInternalDirectoryJunctions:([bool]$policyEntry[0].allowInternalDirectoryJunctions) `
                    -InternalDirectoryJunctionTargetRoot $targetPath `
                    -MetricsObserver $TreeMetricsObserver `
                    -Name 'safe-delete status planned tree' `
                    -StatusTreeCache $StatusTreeCache `
                    -MetricsState $MetricsState `
                    -AttachLiveManifestSha256
                if ((Get-CodexSafeTreeDeleteStatusLiveManifestSha256 -Snapshot $plannedTree) -cne
                    $planManifestSha) {
                    # 参考路径此处 throw 越过 policy 漂移检查，记录只带 manifest 漂移错误。
                    $complete = $false
                    $lifecycle = 'manual-review'
                    $safeActions = @('manual-review')
                    $errors.Add('safe-delete Status planned tree manifest 漂移。')
                }
            } else {
                $complete = $false
                $errors.Add('planned operation 的 target/quarantine namespace 不一致。')
            }
            if ($complete -and -not $policyCompatible) {
                # 参考路径 :4214 的 policy 漂移覆盖（仅 planned 干净分支可达：inconsistent 与
                # manifest 漂移已置 complete=$false，参考语义下漂移错误仍会追加）。
                $complete = $false
                $lifecycle = 'manual-review'
                $safeActions = @('manual-review')
                $errors.Add('plan policy SHA 已漂移；当前严格写路径不可执行该计划。')
            } elseif (-not $complete -and -not $policyCompatible -and
                $errors.Count -eq 1 -and
                $errors[0] -ceq 'planned operation 的 target/quarantine namespace 不一致。') {
                $lifecycle = 'manual-review'
                $safeActions = @('manual-review')
                $errors.Add('plan policy SHA 已漂移；当前严格写路径不可执行该计划。')
            }
        } else {
            # T1 分支：transaction v2 + plan policy SHA 漂移的观测结果塌缩为唯一记录。
            $journalStatus = 'invalid'
            $transactionPath = Join-Path $runDirectory 'transaction.json'
            $transactionSnapshot = $null
            try {
                $transactionSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                    -Path $transactionPath `
                    -Name 'safe-delete status transaction' `
                    -AllowedExactPaths @($transactionPath)
                Assert-CodexHookStrictJsonText -JsonText $transactionSnapshot.text
                $transaction = $transactionSnapshot.text |
                    ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
                $transactionSchemaVersion = [long]$transaction.schemaVersion
            } catch {
                # 参考路径在 transaction 读取/严格校验/解析/schemaVersion 提取上的 throw 记录。
                if ($null -ne $transactionSnapshot) {
                    $MetricsState.bytesHashed =
                        [long]$MetricsState.bytesHashed + [long]$transactionSnapshot.bytes.Length
                }
                $complete = $false
                $transactionSchemaVersion = $null
                $errors.Add($_.Exception.Message)
                $transaction = $null
            }
            if ($null -ne $transaction) {
                if ($transaction.PSObject.Properties['status'] -and $transaction.status -is [string]) {
                    $transactionStatus = [string]$transaction.status
                }
                if ($transaction.PSObject.Properties['updatedAtUtc'] -and
                    $transaction.updatedAtUtc -is [string]) {
                    $transactionUpdatedAtUtc = [string]$transaction.updatedAtUtc
                }
                $committed = $false
                if ([long]$transactionSchemaVersion -eq 2L -and
                    [CodexSafeTreeDelete.StatusScanCoordinator]::TestStatusTransactionV2StrictShape(
                        [string]$transactionSnapshot.text)) {
                    try {
                        $transactionPlanPath = Assert-CodexHookDPath `
                            -Value ([string]$transaction.planPath) `
                            -Name 'safe-delete plan path'
                    } catch { $transactionPlanPath = $null }
                    if ($null -ne $transactionPlanPath -and
                        [IO.Path]::GetFileName($transactionPlanPath) -ceq 'plan.json' -and
                        (Test-CodexSafeTreeDeletePathEqual -Left $transactionPlanPath -Right $fullPlanPath) -and
                        [string]$transaction.planSha256 -ceq [string]$planSnapshot.sha256) {
                        try {
                            [void](Assert-CodexHookCapabilityPath `
                                -Path $fullPlanPath `
                                -CapabilityRoot $FullEvidenceRoot `
                                -AllowedExactPaths @($fullPlanPath) `
                                -Name 'safe-delete approved plan')
                            [void](Assert-CodexHookCapabilityPath `
                                -Path $transactionPath `
                                -CapabilityRoot $FullEvidenceRoot `
                                -AllowedExactPaths @($transactionPath) `
                                -Name 'safe-delete approved transaction')
                            # 参考路径在 Read-ApprovedTransaction 内实时重读 plan/transaction，
                            # 并在内层 Read-ApprovedPlan 重新加载 policy（三项均经 observer 计数）；
                            # 快照漂移时参考结果不再是漂移错误，回退由其自重放。
                            $planVerify = Read-CodexHookSafeUtf8FileSnapshot `
                                -Path $fullPlanPath `
                                -Name 'safe-delete approved plan' `
                                -AllowedExactPaths @($fullPlanPath)
                            $transactionVerify = Read-CodexHookSafeUtf8FileSnapshot `
                                -Path $transactionPath `
                                -Name 'safe-delete approved transaction' `
                                -AllowedExactPaths @($transactionPath)
                            $policyVerify = Read-CodexHookSafeUtf8FileSnapshot `
                                -Path ([string]$LoadedPolicy.path) `
                                -Name 'safe-delete policy' `
                                -AllowedExactPaths @([string]$LoadedPolicy.path)
                            if ([string]$planVerify.sha256 -ceq [string]$planSnapshot.sha256 -and
                                [string]$transactionVerify.sha256 -ceq [string]$transactionSnapshot.sha256 -and
                                [string]$policyVerify.sha256 -ceq $CurrentPolicySha256 -and
                                -not $policyCompatible) {
                                $committed = $true
                                $MetricsState.bytesHashed = [long]$MetricsState.bytesHashed +
                                    (2 * [long]$transactionSnapshot.bytes.Length) +
                                    [long]$planVerify.bytes.Length +
                                    [long]$policyVerify.bytes.Length
                                $complete = $false
                                $errors.Add('safe-delete policy 自计划生成后已漂移。')
                            }
                        } catch { $committed = $false }
                    }
                }
                if (-not $committed) { return $null }
            }
        }

        $deletionOutcome = New-CodexSafeTreeDeleteOutcome `
            -NamespaceAbsent (-not [bool]$targetPresent) `
            -LogicalCompletion $false
        $operation = [pscustomobject][ordered]@{
            operationId = [string]$RunItem.Name
            runDirectory = [string]$RunItem.FullName
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
            candidatePolicyCompatible = $null
            planSchemaVersion = 1L
            transactionSchemaVersion = $transactionSchemaVersion
            transactionStatus = $transactionStatus
            transactionUpdatedAtUtc = $transactionUpdatedAtUtc
            journalStatus = $journalStatus
            pendingFiles = @()
            uncertainFiles = @()
            errors = @($errors)
        }
        return [pscustomobject][ordered]@{
            complete = $complete
            operation = $operation
        }
    } catch {
        # L1 降级：本 op 回退参考路径重放。7 个数值字段回滚到入口快照，重放重新计数；
        # 本调用新增的树缓存项一并逐出（缓存项内容完整，但其扫描计数已回滚，若让重放
        # 命中缓存会少计一遍树扫描）。
        $MetricsState.entriesScanned = [long]$metricsOnEntry.entriesScanned
        $MetricsState.logicalBytes = [long]$metricsOnEntry.logicalBytes
        $MetricsState.bytesHashed = [long]$metricsOnEntry.bytesHashed
        $MetricsState.segmentPlanTransactionReadMs = [long]$metricsOnEntry.segmentPlanTransactionReadMs
        $MetricsState.segmentTerminalArchiveAuthMs = [long]$metricsOnEntry.segmentTerminalArchiveAuthMs
        $MetricsState.segmentTreeMaterializationMs = [long]$metricsOnEntry.segmentTreeMaterializationMs
        $MetricsState.segmentSha256Ms = [long]$metricsOnEntry.segmentSha256Ms
        foreach ($cacheKey in @($StatusTreeCache.Keys)) {
            if ($cacheKey -cnotin $statusTreeCacheKeysOnEntry) {
                [void]$StatusTreeCache.Remove($cacheKey)
            }
        }
        return $null
    }
}

function Invoke-CodexSafeTreeDeleteStatusParallelFallback {
    # issue #58：fallback 逐 op resolve 相互独立，分区到 runspace pool。分区先按"扫描树"
    # 分组：共享同一 target/quarantine 树的 op 进同一组（lease 打开互不兼容，跨 worker 并发
    # 扫同一棵树会 ERROR_SHARING_VIOLATION），组按首现顺序 round-robin 到 worker（确定性）。
    # 每个 worker 持有独立的 metricsState/tree 缓存/manifest SHA 缓存（无共享可变状态），
    # LoadedPolicy/候选 policy/prefetch 快照与 receipt 只读共享；worker 自身读 policy 不计
    # observer（主 runspace 的 policy 读取已计数）。任何基础设施失败由调用方整体回退串行。
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$CurrentPolicySha256,
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][bool]$CandidatePolicyRequested,
        [AllowNull()][object]$CandidatePolicy,
        [Parameter(Mandatory)][object]$LoadedPolicy,
        [Parameter(Mandatory)][object]$PrefetchCache,
        [Parameter(Mandatory)][object]$MetricsState,
        [Parameter(Mandatory)][int]$DegreeOfParallelism
    )

    # 分组按"扫描树"冲突并查：路由路径（target/quarantine 去尾 \）相等或互为目录前缀的
    # op 必同组——quarantine 与子目录 target 常嵌套在父 target 树内（实测确认），精确匹配
    # 分组会导致跨 worker 并发扫嵌套树触发 ERROR_SHARING_VIOLATION。组按首现顺序确定性
    # 合并后 round-robin 到 worker；无路由键的 op 各自成组。
    $groups = [Collections.Generic.List[object]]::new()
    foreach ($input in $Inputs) {
        $opPaths = [Collections.Generic.List[string]]::new()
        foreach ($routePath in @($input.RouteTargetPath, $input.RouteQuarantinePath)) {
            if (-not [string]::IsNullOrEmpty($routePath)) {
                $opPaths.Add([string]$routePath.TrimEnd('\'))
            }
        }
        $hit = $null
        if ($opPaths.Count -gt 0) {
            foreach ($group in $groups) {
                if ([bool]$group.merged) { continue }
                $conflict = $false
                foreach ($existing in $group.paths) {
                    foreach ($candidate in $opPaths) {
                        if ([string]::Equals($existing, $candidate, [StringComparison]::OrdinalIgnoreCase) -or
                            $existing.StartsWith("$candidate\", [StringComparison]::OrdinalIgnoreCase) -or
                            $candidate.StartsWith("$existing\", [StringComparison]::OrdinalIgnoreCase)) {
                            $conflict = $true
                            break
                        }
                    }
                    if ($conflict) { break }
                }
                if ($conflict) {
                    if ($null -eq $hit) {
                        $hit = $group
                    } else {
                        foreach ($mergedPath in $group.paths) {
                            if (-not $hit.paths.Contains($mergedPath)) { $hit.paths.Add($mergedPath) }
                        }
                        foreach ($mergedItem in $group.items) { $hit.items.Add($mergedItem) }
                        $group.merged = $true
                    }
                }
            }
        }
        if ($null -eq $hit) {
            $hit = [pscustomobject]@{
                paths = [Collections.Generic.List[string]]::new()
                items = [Collections.Generic.List[object]]::new()
                merged = $false
            }
            $groups.Add($hit)
        }
        foreach ($opPath in $opPaths) {
            if (-not $hit.paths.Contains($opPath)) { $hit.paths.Add($opPath) }
        }
        $hit.items.Add($input)
    }
    $activeGroups = @($groups | Where-Object { -not [bool]$_.merged })
    $workerCount = [Math]::Min($DegreeOfParallelism, [int]$activeGroups.Count)
    $chunks = @()
    for ($workerIndex = 0; $workerIndex -lt $workerCount; $workerIndex++) {
        $chunks += ,([Collections.Generic.List[object]]::new())
    }
    for ($groupIndex = 0; $groupIndex -lt $activeGroups.Count; $groupIndex++) {
        foreach ($input in $activeGroups[$groupIndex].items) {
            $chunks[$groupIndex % $workerCount].Add($input)
        }
    }
    # worker runspace 有独立 session state，但 native 装配与 Add-Type 类型进程级共享。
    # 预置主 runspace 的 loader registry，避免 worker 走 compat registry（loadedVariant=$null）
    # 后在第二次 dot-source 时触发“未知转移”拒绝；registry 缺位则失败，由调用方回退串行。
    $nativeRegistry = $global:CodexHostSafetyNativeLoaderRegistry
    if ($null -eq $nativeRegistry -or $null -eq $nativeRegistry.assembly) {
        throw 'parallel fallback 要求主 runspace 持有真实 native loader registry。'
    }
    $context = [pscustomobject][ordered]@{
        LibDirectory = $PSScriptRoot
        PolicyPath = $PolicyPath
        CurrentPolicySha256 = $CurrentPolicySha256
        FullEvidenceRoot = $FullEvidenceRoot
        CandidatePolicyRequested = $CandidatePolicyRequested
        CandidatePolicy = $CandidatePolicy
        LoadedPolicy = $LoadedPolicy
        PrefetchCache = $PrefetchCache
        NativeRegistryLoadedVariant = [string]$nativeRegistry.loadedVariant
        NativeRegistryCompileCompositeSha256 = [string]$nativeRegistry.compileCompositeSha256
        NativeRegistryAssemblySha256 = [string]$nativeRegistry.assemblySha256
        NativeRegistryAssembly = $nativeRegistry.assembly
        NativeRegistryRequestedAlgorithm = [string]$nativeRegistry.requestedAlgorithm
    }
    $workerScript = @'
param($chunk, $context)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:CodexHostSafetyNativeLoaderRegistry = [pscustomobject]@{
    loadedVariant = $context.NativeRegistryLoadedVariant
    compileCompositeSha256 = $context.NativeRegistryCompileCompositeSha256
    assemblySha256 = $context.NativeRegistryAssemblySha256
    assembly = $context.NativeRegistryAssembly
    requestedAlgorithm = $context.NativeRegistryRequestedAlgorithm
}
. (Join-Path $context.LibDirectory 'CodexHostSafety.ps1')
. (Join-Path $context.LibDirectory 'CodexSafeTreeDelete.ps1')
$metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
Add-Member -InputObject $metricsState -NotePropertyMembers @{
    segmentDirectoryEnumerationMs = 0L
    segmentPlanTransactionReadMs = 0L
    segmentTerminalArchiveAuthMs = 0L
    segmentTreeMaterializationMs = 0L
    segmentSha256Ms = 0L
    segmentActiveResolveMs = 0L
    segmentArchivedResolveMs = 0L
    segmentPrefetchMs = 0L
    segmentFastScanMs = 0L
    approvedPlanValidationReuseCount = 0L
} -Force
$treeMetricsObserver = New-CodexSafeTreeDeleteMetricsObserver -State $metricsState
$statusTreeCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$planManifestShaCache = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$workerPolicy = Read-CodexSafeTreeDeletePolicy -PolicyPath $context.PolicyPath
if ([string]$workerPolicy.sha256 -cne $context.CurrentPolicySha256) {
    throw 'parallel fallback worker policy SHA-256 与主 runspace 不一致。'
}
$results = [Collections.Generic.List[object]]::new()
foreach ($item in $chunk) {
    $runItem = [pscustomobject][ordered]@{
        Name = [string]$item.Name
        FullName = [string]$item.FullName
        PSIsContainer = [bool]$item.PSIsContainer
        Attributes = [IO.FileAttributes]([long]$item.Attributes)
    }
    $activeWatch = [Diagnostics.Stopwatch]::StartNew()
    $operationStatus = $null
    $receiptFast = $false
    if (-not $context.CandidatePolicyRequested) {
        # N3：receipt 门控快路径；$null = 回退参考路径重放（无副作用，永远安全）。
        $operationStatus = Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation `
            -RunItem $runItem `
            -CurrentPolicySha256 $context.CurrentPolicySha256 `
            -FullEvidenceRoot $context.FullEvidenceRoot `
            -MetricsState $metricsState `
            -TreeMetricsObserver $treeMetricsObserver `
            -StatusTreeCache $statusTreeCache `
            -LoadedPolicy $context.LoadedPolicy `
            -StatusPlanPrefetch $context.PrefetchCache `
            -PlanManifestShaCache $planManifestShaCache
        $receiptFast = $null -ne $operationStatus
    }
    if ($null -eq $operationStatus) {
        $operationStatus = Resolve-CodexSafeTreeDeleteStatusOperation `
            -RunItem $runItem `
            -PolicyPath $context.PolicyPath `
            -CurrentPolicySha256 $context.CurrentPolicySha256 `
            -FullEvidenceRoot $context.FullEvidenceRoot `
            -CandidatePolicyRequested $context.CandidatePolicyRequested `
            -CandidatePolicy $context.CandidatePolicy `
            -MetricsState $metricsState `
            -TreeMetricsObserver $treeMetricsObserver `
            -StatusTreeCache $statusTreeCache `
            -LoadedPolicy $context.LoadedPolicy `
            -StatusPlanPrefetch $context.PrefetchCache `
            -PlanManifestShaCache $planManifestShaCache
    }
    $activeWatch.Stop()
    $results.Add([pscustomobject][ordered]@{
        index = [int]$item.Index
        archived = [bool]$item.IsArchived
        elapsedMs = [long]$activeWatch.ElapsedMilliseconds
        complete = [bool]$operationStatus.complete
        operation = $operationStatus.operation
        receiptFast = $receiptFast
    })
}
[pscustomobject][ordered]@{
    results = $results.ToArray()
    metrics = [pscustomobject][ordered]@{
        entriesScanned = [long]$metricsState.entriesScanned
        logicalBytes = [long]$metricsState.logicalBytes
        bytesHashed = [long]$metricsState.bytesHashed
        segmentPlanTransactionReadMs = [long]$metricsState.segmentPlanTransactionReadMs
        segmentTerminalArchiveAuthMs = [long]$metricsState.segmentTerminalArchiveAuthMs
        segmentTreeMaterializationMs = [long]$metricsState.segmentTreeMaterializationMs
        segmentSha256Ms = [long]$metricsState.segmentSha256Ms
        approvedPlanValidationReuseCount = [long]$metricsState.approvedPlanValidationReuseCount
        statusTreeCacheEntries = [long]$statusTreeCache.Count
        planManifestShaCacheEntries = [long]$planManifestShaCache.Count
    }
}
'@
    $pool = [runspacefactory]::CreateRunspacePool(1, $workerCount)
    $pool.Open()
    $jobs = [Collections.Generic.List[object]]::new()
    try {
        foreach ($chunk in $chunks) {
            $worker = [powershell]::Create()
            $worker.RunspacePool = $pool
            [void]$worker.AddScript($workerScript).AddArgument($chunk).AddArgument($context)
            $jobs.Add([pscustomobject][ordered]@{
                PowerShell = $worker
                Async = $worker.BeginInvoke()
            })
        }
        $resultByIndex = [Collections.Generic.Dictionary[int, object]]::new()
        $resolved = 0L
        $debugOpTimings = $null
        if ($env:CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING -ceq '1') {
            $debugOpTimings = [Collections.Generic.List[string]]::new()
        }
        # N5 M1：worker 全部成功前只合入本地缓冲，不写共享 MetricsState。任一 worker 失败
        # （EndInvoke/错误流/形状/计数校验 throw）时共享 metrics 保持零污染，调用方 catch
        # 归零计数后的串行重放不会与已合入的 worker 簿记双计。
        $mergedReceiptFastResolved = 0L
        $mergedActiveResolveMs = 0L
        $mergedArchivedResolveMs = 0L
        $mergedEntriesScanned = 0L
        $mergedLogicalBytes = 0L
        $mergedBytesHashed = 0L
        $mergedPlanTransactionReadMs = 0L
        $mergedTerminalArchiveAuthMs = 0L
        $mergedTreeMaterializationMs = 0L
        $mergedSha256Ms = 0L
        $mergedApprovedPlanValidationReuseCount = 0L
        $mergedStatusTreeCacheEntries = 0L
        $mergedPlanManifestShaCacheEntries = 0L
        foreach ($job in $jobs) {
            $output = $null
            try {
                $output = $job.PowerShell.EndInvoke($job.Async)
            } catch {
                throw "parallel fallback worker 失败：$($_.Exception.Message)"
            }
            if ($job.PowerShell.Streams.Error.Count -gt 0) {
                throw "parallel fallback worker 报错：$($job.PowerShell.Streams.Error[0].Exception.Message)"
            }
            if ($null -eq $output -or $output.Count -ne 1) {
                throw 'parallel fallback worker 返回形状非法。'
            }
            $workerResult = $output[0]
            foreach ($item in @($workerResult.results)) {
                $resultByIndex[[int]$item.index] = [pscustomobject][ordered]@{
                    complete = [bool]$item.complete
                    operation = $item.operation
                }
                $resolved++
                if ([bool]$item.receiptFast) {
                    $mergedReceiptFastResolved = [long]$mergedReceiptFastResolved + 1L
                }
                if ($null -ne $debugOpTimings) {
                    [void]$debugOpTimings.Add(
                        "$([int]$item.index)|$([bool]$item.archived)|$([long]$item.elapsedMs)")
                }
                if ([bool]$item.archived) {
                    $mergedArchivedResolveMs =
                        [long]$mergedArchivedResolveMs + [long]$item.elapsedMs
                } else {
                    $mergedActiveResolveMs =
                        [long]$mergedActiveResolveMs + [long]$item.elapsedMs
                }
            }
            $workerMetrics = $workerResult.metrics
            $mergedEntriesScanned =
                [long]$mergedEntriesScanned + [long]$workerMetrics.entriesScanned
            $mergedLogicalBytes =
                [long]$mergedLogicalBytes + [long]$workerMetrics.logicalBytes
            $mergedBytesHashed =
                [long]$mergedBytesHashed + [long]$workerMetrics.bytesHashed
            $mergedPlanTransactionReadMs =
                [long]$mergedPlanTransactionReadMs + [long]$workerMetrics.segmentPlanTransactionReadMs
            $mergedTerminalArchiveAuthMs =
                [long]$mergedTerminalArchiveAuthMs + [long]$workerMetrics.segmentTerminalArchiveAuthMs
            $mergedTreeMaterializationMs =
                [long]$mergedTreeMaterializationMs + [long]$workerMetrics.segmentTreeMaterializationMs
            $mergedSha256Ms =
                [long]$mergedSha256Ms + [long]$workerMetrics.segmentSha256Ms
            $mergedApprovedPlanValidationReuseCount =
                [long]$mergedApprovedPlanValidationReuseCount +
                [long]$workerMetrics.approvedPlanValidationReuseCount
            $mergedStatusTreeCacheEntries =
                [long]$mergedStatusTreeCacheEntries + [long]$workerMetrics.statusTreeCacheEntries
            $mergedPlanManifestShaCacheEntries =
                [long]$mergedPlanManifestShaCacheEntries + [long]$workerMetrics.planManifestShaCacheEntries
        }
        if ($resolved -ne $Inputs.Count) {
            throw "parallel fallback 结果数不完整：$resolved / $($Inputs.Count)。"
        }
        # 全部 worker 成功且结果数完整：一次性合入共享 MetricsState（加法可交换，成功路径
        # 的最终值与逐条合入完全一致；合入点之后不再 throw）。
        $MetricsState.parallelFallbackReceiptFastResolved =
            [long]$MetricsState.parallelFallbackReceiptFastResolved + $mergedReceiptFastResolved
        Add-CodexSafeTreeDeleteStatusElapsed `
            -State $MetricsState `
            -Name 'segmentActiveResolveMs' `
            -Milliseconds $mergedActiveResolveMs
        Add-CodexSafeTreeDeleteStatusElapsed `
            -State $MetricsState `
            -Name 'segmentArchivedResolveMs' `
            -Milliseconds $mergedArchivedResolveMs
        $MetricsState.entriesScanned =
            [long]$MetricsState.entriesScanned + $mergedEntriesScanned
        $MetricsState.logicalBytes =
            [long]$MetricsState.logicalBytes + $mergedLogicalBytes
        $MetricsState.bytesHashed =
            [long]$MetricsState.bytesHashed + $mergedBytesHashed
        Add-CodexSafeTreeDeleteStatusElapsed `
            -State $MetricsState `
            -Name 'segmentPlanTransactionReadMs' `
            -Milliseconds $mergedPlanTransactionReadMs
        Add-CodexSafeTreeDeleteStatusElapsed `
            -State $MetricsState `
            -Name 'segmentTerminalArchiveAuthMs' `
            -Milliseconds $mergedTerminalArchiveAuthMs
        Add-CodexSafeTreeDeleteStatusElapsed `
            -State $MetricsState `
            -Name 'segmentTreeMaterializationMs' `
            -Milliseconds $mergedTreeMaterializationMs
        Add-CodexSafeTreeDeleteStatusElapsed `
            -State $MetricsState `
            -Name 'segmentSha256Ms' `
            -Milliseconds $mergedSha256Ms
        $MetricsState.approvedPlanValidationReuseCount =
            [long]$MetricsState.approvedPlanValidationReuseCount +
            $mergedApprovedPlanValidationReuseCount
        $MetricsState.parallelFallbackStatusTreeCacheEntries =
            [long]$MetricsState.parallelFallbackStatusTreeCacheEntries +
            $mergedStatusTreeCacheEntries
        $MetricsState.parallelFallbackPlanManifestShaCacheEntries =
            [long]$MetricsState.parallelFallbackPlanManifestShaCacheEntries +
            $mergedPlanManifestShaCacheEntries
        if ($null -ne $debugOpTimings) {
            Add-Member -InputObject $MetricsState -NotePropertyName debugOpTimings `
                -NotePropertyValue $debugOpTimings.ToArray() -Force
        }
        return [pscustomobject][ordered]@{
            resultByIndex = $resultByIndex
            workerCount = $workerCount
        }
    } finally {
        foreach ($job in $jobs) { $job.PowerShell.Dispose() }
        $pool.Dispose()
    }
}

function Get-CodexSafeTreeDeleteStatus {
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [string]$CandidatePolicyPath,
        # #82：policy 维护工具以内存中的候选字节代替 CandidatePolicyPath（二者只能给一个），DryRun 因此不落盘；
        # 输出的 migrationReadiness.candidatePolicyPath 为 $null。
        [byte[]]$CandidatePolicyBytes,
        [string]$ApprovedCandidatePolicySha256,
        # #80 范围查询：只对 targetPath 与任一目标按 OrdinalIgnoreCase 相等（不做 Unicode 规范化，
        # 与 BatchPurge 一致）的记录作答，祖先与后代路径不算命中；无法确定 targetPath 的记录计入
        # 范围（manual-review，fail-closed）。不传时行为与输出与全量 Status 完全相同。
        [string[]]$TargetPaths
    )

    # 范围目标先于任何 evidence / policy 访问规范化（与 BatchPurge 目标同一 D 盘全路径形态）；
    # 重复目标与 BatchPurge 一样直接报错。
    $scopeTargets = $null
    $scopeTargetSet = $null
    if ($null -ne $TargetPaths) {
        if ($TargetPaths.Count -eq 0) {
            throw 'safe-delete status scope 至少需要一个目标。'
        }
        $scopeTargets = [Collections.Generic.List[string]]::new()
        $scopeTargetSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($scopeTarget in $TargetPaths) {
            $fullScopeTarget = Assert-CodexHookDPath -Value $scopeTarget -Name 'safe-delete status scope target'
            if (-not $scopeTargetSet.Add($fullScopeTarget)) {
                throw 'safe-delete status scope target 重复。'
            }
            $scopeTargets.Add($fullScopeTarget)
        }
    }
    $scopeMatchedRecords = 0L
    $scopeUnattributableRecords = 0L

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'status'
    Add-Member -InputObject $metricsState -NotePropertyMembers @{
        segmentDirectoryEnumerationMs = 0L
        segmentPlanTransactionReadMs = 0L
        segmentTerminalArchiveAuthMs = 0L
        segmentTreeMaterializationMs = 0L
        segmentSha256Ms = 0L
        segmentActiveResolveMs = 0L
        segmentArchivedResolveMs = 0L
        segmentPrefetchMs = 0L
        segmentFastScanMs = 0L
        approvedPlanValidationReuseCount = 0L
        parallelFallbackStatusTreeCacheEntries = 0L
        parallelFallbackPlanManifestShaCacheEntries = 0L
        parallelFallbackWorkers = 0L
        parallelFallbackResolved = 0L
        parallelFallbackReceiptFastResolved = 0L
    } -Force
    $statusTreeCache = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $planManifestShaCache = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal)
    $statusPlanPrefetch = $null
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
    $candidatePolicyPathGiven = -not [string]::IsNullOrWhiteSpace($CandidatePolicyPath)
    $candidatePolicyBytesGiven = $null -ne $CandidatePolicyBytes
    $candidatePolicyRequested =
        $candidatePolicyPathGiven -or $candidatePolicyBytesGiven -or
        -not [string]::IsNullOrWhiteSpace($ApprovedCandidatePolicySha256)
    if ($candidatePolicyRequested) {
        if ($candidatePolicyPathGiven -and $candidatePolicyBytesGiven) {
            throw 'safe-delete candidate policy preflight 只接受 path 或字节之一。'
        }
        if ((-not $candidatePolicyPathGiven -and -not $candidatePolicyBytesGiven) -or
            [string]::IsNullOrWhiteSpace($ApprovedCandidatePolicySha256)) {
            throw 'safe-delete candidate policy preflight 要求 path 与 approved SHA-256。'
        }
        if ($ApprovedCandidatePolicySha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'safe-delete candidate policy approved SHA-256 格式非法。'
        }
        $candidatePolicy = if ($candidatePolicyBytesGiven) {
            Read-CodexSafeTreeDeletePolicy -PolicyBytes $CandidatePolicyBytes -MetricsObserver $treeMetricsObserver
        } else {
            Read-CodexSafeTreeDeletePolicy -PolicyPath $CandidatePolicyPath -MetricsObserver $treeMetricsObserver
        }
        if ([string]$candidatePolicy.sha256 -cne $ApprovedCandidatePolicySha256) {
            throw 'safe-delete candidate policy approved SHA-256 不匹配。'
        }
        # v5 激活预检之外，#82 policy 维护工具用同一预检检查与现役 policy 同 schema 的候选。
        if ([long]$candidatePolicy.schemaVersion -ne 5L -and
            [long]$candidatePolicy.schemaVersion -ne [long]$policy.schemaVersion) {
            throw 'safe-delete candidate policy preflight 只接受 schema v5 或与现役 policy 同 schema 的候选。'
        }
    }
    $operations = [Collections.Generic.List[object]]::new()
    $complete = $true
    $enumWatch = [Diagnostics.Stopwatch]::StartNew()
    $runItems = @(Get-ChildItem -LiteralPath $fullEvidenceRoot -Force -ErrorAction Stop |
        Sort-Object -Property Name -CaseSensitive)
    $enumWatch.Stop()
    $metricsState.segmentDirectoryEnumerationMs = [long]$enumWatch.ElapsedMilliseconds
    $fastScanEnabled = Test-CodexSafeTreeDeleteStatusFastScanEnabled
    $fastResults = $null
    $fastScanMs = 0L
    $fastDop = Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit
    if ($null -ne $scopeTargets) {
        $runItems = @(Select-CodexSafeTreeDeleteStatusScopeRunItems `
            -RunItems $runItems `
            -ScopeTargets $scopeTargets.ToArray() `
            -FullEvidenceRoot $fullEvidenceRoot `
            -DegreeOfParallelism $fastDop)
    }
    $fastHandled = 0L
    $fastFallback = 0L
    if ($fastScanEnabled) {
        $fastWatch = [Diagnostics.Stopwatch]::StartNew()
        $fastResults = Invoke-CodexSafeTreeDeleteStatusFastScan `
            -RunItems $runItems `
            -Policy $policy `
            -FullEvidenceRoot $fullEvidenceRoot `
            -MetricsState $metricsState `
            -DegreeOfParallelism $fastDop
        $fastWatch.Stop()
        $fastScanMs = [long]$fastWatch.ElapsedMilliseconds
        $metricsState.segmentFastScanMs = $fastScanMs
        $statusPlanPrefetch = [pscustomobject][ordered]@{
            cache = [Collections.Generic.Dictionary[string, object]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            throttleLimit = [int]$fastDop
            prefetchedCount = 0L
            parsedCount = 0L
        }
    } else {
        $prefetchWatch = [Diagnostics.Stopwatch]::StartNew()
        $statusPlanPrefetch = Read-CodexSafeTreeDeleteStatusUnarchivedPlanPrefetch `
            -RunItems $runItems `
            -FullEvidenceRoot $fullEvidenceRoot `
            -MetricsObserver $treeMetricsObserver `
            -MetricsState $metricsState
        $prefetchWatch.Stop()
        $metricsState.segmentPrefetchMs = [long]$prefetchWatch.ElapsedMilliseconds
    }

    # issue #58：两遍结构。第一遍完成 fast-handled 转换与 fallback 描述符收集（含 plan 快照
    # 注入 prefetch，保持单读合同）；fallback 子集相互独立，可走 runspace pool 并行（默认开，
    # CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK=0 关闭；并行基础设施失败整体回退串行）。
    $parallelFallbackEnabled = $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK -cne '0'
    $fastOperationByIndex = [Collections.Generic.Dictionary[int, object]]::new()
    $fallbackInputs = [Collections.Generic.List[object]]::new()
    $runItemIndex = 0
    foreach ($runItem in $runItems) {
        $isArchived = [IO.File]::Exists((Join-Path $runItem.FullName 'terminal-archive.json'))
        $fastResult = $null
        if ($null -ne $fastResults) {
            $fastResult = $fastResults[[string]$runItem.FullName]
        }
        if ($null -ne $fastResult -and [bool]$fastResult.Handled) {
            $fastHandled = $fastHandled + 1L
            $fastOperationByIndex[$runItemIndex] = New-CodexSafeTreeDeleteStatusOperationFromScan `
                -ScanResult $fastResult `
                -CandidatePolicyRequested $candidatePolicyRequested
        } else {
            $fastFallback = $fastFallback + 1L
            if ($null -ne $fastResult -and
                $null -ne $fastResult.PlanSha256 -and
                -not $statusPlanPrefetch.cache.ContainsKey([string]$runItem.FullName)) {
                # The scanner already read plan.json; hand the snapshot to the reference
                # resolver so fallback records keep the single-read contract.
                $statusPlanPrefetch.cache[[string]$runItem.FullName] = [pscustomobject][ordered]@{
                    snapshot = [pscustomobject][ordered]@{
                        sha256 = [string]$fastResult.PlanSha256
                        text = [string]$fastResult.PlanText
                    }
                    document = $null
                    approvedPlanValidation = $fastResult.ApprovedPlanValidation
                    # N3：无 transaction 的 receipt op 由 fast scan 并行预算的 manifest SHA；
                    # 未计算（有 transaction 或流式回退）时为 $null，worker 自行计算。
                    planManifestSha256 = if ($null -ne $fastResult.PlanManifestSha256) {
                        [string]$fastResult.PlanManifestSha256
                    } else {
                        $null
                    }
                    # N4：receipt 快路径的 plan 字段直出（C# 侧 receipt 校验的同一
                    # JsonDocument；AssertDPath 规范化），worker 不再重解析大 plan 文本。
                    receiptPlanTargetPath = if ($null -ne $fastResult.ReceiptPlanTargetPath) {
                        [string]$fastResult.ReceiptPlanTargetPath
                    } else {
                        $null
                    }
                    receiptPlanQuarantinePath = if ($null -ne $fastResult.ReceiptPlanQuarantinePath) {
                        [string]$fastResult.ReceiptPlanQuarantinePath
                    } else {
                        $null
                    }
                    receiptPlanCapabilityRoot = if ($null -ne $fastResult.ReceiptPlanCapabilityRoot) {
                        [string]$fastResult.ReceiptPlanCapabilityRoot
                    } else {
                        $null
                    }
                    receiptPlanPolicySha256 = if ($null -ne $fastResult.ReceiptPlanPolicySha256) {
                        [string]$fastResult.ReceiptPlanPolicySha256
                    } else {
                        $null
                    }
                    # N4：receipt 校验的免封送入口。大 plan 文本作为 .NET 方法实参会被
                    # PS 绑定器整串复制（实测 109M 字符 ≈12s/次）；receipt↔快照比对收进
                    # C# 同实例完成（ValidateReceiptAgainstOwnSnapshot）。
                    scanResult = $fastResult
                }
            }
            $fallbackInputs.Add([pscustomobject][ordered]@{
                Index = $runItemIndex
                Name = [string]$runItem.Name
                FullName = [string]$runItem.FullName
                PSIsContainer = [bool]$runItem.PSIsContainer
                Attributes = [long][IO.FileAttributes]$runItem.Attributes
                IsArchived = [bool]$isArchived
                # 共享树路由提示（缺失则不参与分组）。N5 L2：分组键必须用 receipt 携带的
                # AssertDPath 规范化值，不用 raw plan 字符串——同一棵树的不同拼写（相对段、
                # 分隔符、尾斜杠）若落到不同组，worker 实际打开的规范化路径会跨组并发扫同一棵
                # 树触发 lease 冲突。raw TargetPath/QuarantinePath 仅作 operation payload 保留。
                RouteTargetPath = if ($null -ne $fastResult) { [string]$fastResult.ReceiptPlanTargetPath } else { $null }
                RouteQuarantinePath = if ($null -ne $fastResult) { [string]$fastResult.ReceiptPlanQuarantinePath } else { $null }
            })
        }
        $runItemIndex++
    }
    $fallbackResultByIndex = $null
    # issue #58：没有路由键的 fallback op 可能扫描任意一棵树，无法按树做冲突分组，只留给下方
    # 主 runspace 的串行循环解析。该循环在全部 worker 结束后才运行，不会与 worker 对同一棵树
    # 并发持有 lease（FAST_SCAN=0 时所有 op 都没有路由键，Status 因此整轮串行）。
    $parallelInputs = [Collections.Generic.List[object]]::new()
    foreach ($fallbackInput in $fallbackInputs) {
        if (-not [string]::IsNullOrEmpty([string]$fallbackInput.RouteTargetPath) -or
            -not [string]::IsNullOrEmpty([string]$fallbackInput.RouteQuarantinePath)) {
            $parallelInputs.Add($fallbackInput)
        }
    }
    if ($parallelFallbackEnabled -and $parallelInputs.Count -ge 2 -and $fastDop -ge 2) {
        try {
            $parallelResult = Invoke-CodexSafeTreeDeleteStatusParallelFallback `
                -Inputs $parallelInputs `
                -PolicyPath $PolicyPath `
                -CurrentPolicySha256 ([string]$policy.sha256) `
                -FullEvidenceRoot $fullEvidenceRoot `
                -CandidatePolicyRequested $candidatePolicyRequested `
                -CandidatePolicy $candidatePolicy `
                -LoadedPolicy $policy `
                -PrefetchCache $statusPlanPrefetch.cache `
                -MetricsState $metricsState `
                -DegreeOfParallelism $fastDop
            $fallbackResultByIndex = $parallelResult.resultByIndex
            $metricsState.parallelFallbackWorkers = [long]$parallelResult.workerCount
            $metricsState.parallelFallbackResolved = [long]$parallelInputs.Count
        } catch {
            # 并行基础设施失败不改变语义：整体回退到串行参考路径重放。
            $fallbackResultByIndex = $null
            $metricsState.parallelFallbackWorkers = 0L
            $metricsState.parallelFallbackResolved = 0L
        }
    }
    $runItemIndex = 0
    foreach ($runItem in $runItems) {
        $metricsState.entriesScanned = [long]$metricsState.entriesScanned + 1L
        $operationStatus = $null
        if ($fastOperationByIndex.ContainsKey($runItemIndex)) {
            $operationStatus = $fastOperationByIndex[$runItemIndex]
        } elseif ($null -ne $fallbackResultByIndex -and
            $fallbackResultByIndex.ContainsKey($runItemIndex)) {
            $operationStatus = $fallbackResultByIndex[$runItemIndex]
        }
        if ($null -eq $operationStatus) {
            $isArchived = [IO.File]::Exists((Join-Path $runItem.FullName 'terminal-archive.json'))
            $activeWatch = [Diagnostics.Stopwatch]::StartNew()
            $operationStatus = Resolve-CodexSafeTreeDeleteStatusOperation `
                -RunItem $runItem `
                -PolicyPath $PolicyPath `
                -CurrentPolicySha256 ([string]$policy.sha256) `
                -FullEvidenceRoot $fullEvidenceRoot `
                -CandidatePolicyRequested $candidatePolicyRequested `
                -CandidatePolicy $candidatePolicy `
                -MetricsState $metricsState `
                -TreeMetricsObserver $treeMetricsObserver `
                -StatusTreeCache $statusTreeCache `
                -LoadedPolicy $policy `
                -StatusPlanPrefetch $statusPlanPrefetch.cache `
                -PlanManifestShaCache $planManifestShaCache
            $activeWatch.Stop()
            if ($isArchived) {
                $metricsState.segmentArchivedResolveMs =
                    [long]$metricsState.segmentArchivedResolveMs + $activeWatch.ElapsedMilliseconds
            } else {
                $metricsState.segmentActiveResolveMs =
                    [long]$metricsState.segmentActiveResolveMs + $activeWatch.ElapsedMilliseconds
            }
        }
        if ($null -ne $scopeTargetSet) {
            # 范围按完整认证后的 targetPath 判定；范围外的记录既不输出，也不影响 complete 与
            # blockingRecords。targetPath 无法确定的记录一律计入范围。
            $operationTargetPath = [string]$operationStatus.operation.targetPath
            if ([string]::IsNullOrEmpty($operationTargetPath)) {
                $scopeUnattributableRecords++
            } elseif ($scopeTargetSet.Contains($operationTargetPath)) {
                $scopeMatchedRecords++
            } else {
                $runItemIndex++
                continue
            }
        }
        $operations.Add($operationStatus.operation)
        if (-not [bool]$operationStatus.complete) {
            $complete = $false
        }
        $runItemIndex++
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
    $statusFields = [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-status'
        schemaVersion = 1
        capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        complete = $complete
        policyPath = [string]$policy.path
        policySha256 = [string]$policy.sha256
        policySchemaVersion = [long]$policy.schemaVersion
        migrationReadiness = [pscustomobject][ordered]@{
            evaluated = $candidatePolicyRequested
            candidatePolicyPath = if ($null -eq $candidatePolicy -or $null -eq $candidatePolicy.path) { $null } else { [string]$candidatePolicy.path }
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
    if ($null -ne $scopeTargets) {
        # scope 紧挨 complete 之前：complete、blockingRecords 与 ready 都只针对范围内的记录。
        $statusFields.Insert(3, 'scope', [pscustomobject][ordered]@{
            kind = 'targets'
            targets = @($scopeTargets)
            matchedRecords = $scopeMatchedRecords
            unattributableRecords = $scopeUnattributableRecords
        })
    }
    $status = [pscustomobject]$statusFields
    if ($env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS -ceq '1') {
        $status | Add-Member -NotePropertyName statusSegments -NotePropertyValue ([pscustomobject][ordered]@{
            directoryEnumerationMs = [long]$metricsState.segmentDirectoryEnumerationMs
            planTransactionReadMs = [long]$metricsState.segmentPlanTransactionReadMs
            terminalArchiveAuthMs = [long]$metricsState.segmentTerminalArchiveAuthMs
            treeMaterializationMs = [long]$metricsState.segmentTreeMaterializationMs
            sha256Ms = [long]$metricsState.segmentSha256Ms
            activeResolveMs = [long]$metricsState.segmentActiveResolveMs
            archivedResolveMs = [long]$metricsState.segmentArchivedResolveMs
            prefetchMs = [long]$metricsState.segmentPrefetchMs
            fastScanMs = [long]$metricsState.segmentFastScanMs
            approvedPlanValidationReuseCount = [long]$metricsState.approvedPlanValidationReuseCount
            fastScanHandled = [long]$fastHandled
            fastScanFallback = [long]$fastFallback
            fastScanDop = if ($fastScanEnabled) { [int]$fastDop } else { 0 }
            fastScanConsumption = 'status-invocation-local-not-session-hash-cache'
            statusTreeCacheEntries =
                [long]$statusTreeCache.Count + [long]$metricsState.parallelFallbackStatusTreeCacheEntries
            planManifestShaCacheEntries =
                [long]$planManifestShaCache.Count + [long]$metricsState.parallelFallbackPlanManifestShaCacheEntries
            parallelFallbackWorkers = [long]$metricsState.parallelFallbackWorkers
            parallelFallbackResolved = [long]$metricsState.parallelFallbackResolved
            parallelFallbackReceiptFastResolved =
                [long]$metricsState.parallelFallbackReceiptFastResolved
            unarchivedPlanPrefetchCount = if ($null -eq $statusPlanPrefetch) {
                0L
            } else {
                [long]$statusPlanPrefetch.prefetchedCount
            }
            unarchivedPlanParsedCount = if ($null -eq $statusPlanPrefetch) {
                0L
            } else {
                [long]$statusPlanPrefetch.parsedCount
            }
            jsonParseThrottleLimit = if ($null -eq $statusPlanPrefetch) {
                0
            } else {
                [int]$statusPlanPrefetch.throttleLimit
            }
            consumptionBoundary = 'status-invocation-local-not-session-hash-cache'
        })
        if ($env:CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING -ceq '1' -and
            $null -ne $metricsState.PSObject.Properties['debugOpTimings']) {
            $status.statusSegments | Add-Member -NotePropertyName debugOpTimings `
                -NotePropertyValue $metricsState.debugOpTimings -Force
        }
    }
    return $status
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
        [scriptblock]$MetricsObserver,
        [AllowNull()][object]$PreloadedSnapshot,
        [AllowNull()][object]$PreparsedDocument,
        [AllowNull()][object]$LoadedPolicy,
        [AllowNull()][object]$PlanManifestShaCache,
        [AllowNull()][CodexSafeTreeDelete.StatusPlanValidationReceipt]$StatusPlanValidation
    )

    if ($ApprovedPlanSha256 -notmatch '^[0-9a-f]{64}$') { throw 'ApprovedPlanSha256 格式非法。' }
    if ($null -ne $PreparsedDocument -and $null -eq $PreloadedSnapshot) {
        throw 'safe-delete preparsed plan 必须绑定已哈希 snapshot。'
    }
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
    if ($null -ne $PreloadedSnapshot) {
        $snapshot = $PreloadedSnapshot
        if ($snapshot.sha256 -isnot [string] -or
            [string]$snapshot.sha256 -cne $ApprovedPlanSha256) {
            throw 'safe-delete approved plan SHA-256 不匹配。'
        }
        if ($snapshot.text -isnot [string]) {
            throw 'safe-delete preloaded plan snapshot 缺少 text。'
        }
    } else {
        $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $fullPlanPath `
            -Name 'safe-delete approved plan' `
            -AllowedExactPaths @($fullPlanPath)
        if ($null -ne $MetricsObserver) {
            & $MetricsObserver 'hash-read' 0L ([long]$snapshot.bytes.Length)
        }
        if ($snapshot.sha256 -cne $ApprovedPlanSha256) { throw 'safe-delete approved plan SHA-256 不匹配。' }
    }
    $reuseStatusPlanValidation = $AllowMissingTarget -and $AllowExpiredPlan -and
        $null -eq $PreparsedDocument -and $null -ne $StatusPlanValidation -and
        $StatusPlanValidation.MatchesPlanPath($fullPlanPath) -and
        $StatusPlanValidation.MatchesSnapshot([string]$snapshot.sha256, [string]$snapshot.text)
    if ($null -eq $PreloadedSnapshot -and -not $reuseStatusPlanValidation) {
        Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    }
    if ($null -ne $PreparsedDocument) {
        $plan = $PreparsedDocument
    } else {
        $plan = $snapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    }
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

    if ($null -ne $LoadedPolicy) {
        $policy = $LoadedPolicy
        $requestedPolicyPath = Assert-CodexHookDPath -Value $PolicyPath -Name 'safe-delete policy path'
        if (-not (Test-CodexSafeTreeDeletePathEqual `
                -Left $requestedPolicyPath `
                -Right ([string]$policy.path))) {
            throw 'safe-delete loaded policy path 与请求 path 不一致。'
        }
        if ($policy.sha256 -isnot [string] -or [string]$policy.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'safe-delete loaded policy SHA-256 非法。'
        }
    } else {
        $policy = Read-CodexSafeTreeDeletePolicy `
            -PolicyPath $PolicyPath `
            -MetricsObserver $MetricsObserver
    }
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
    # Only Status's read-only approval mode can consume the scanner's snapshot-bound receipt.
    if (-not $reuseStatusPlanValidation) {
        [void](ConvertTo-CodexHookExpectedDirectoryTreeManifest `
            -Manifest $plan.treeManifest `
            -Scope 'safe-delete approved plan')
    }
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
        [scriptblock]$QuarantineCheckpointForTest,
        [object]$FileSystemCapabilitiesForTest,
        [CodexSafeTreeDelete.SessionHashCache]$SessionHashCacheForTest,
        [switch]$DisableApplyHashReuseForTest
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
    Assert-CodexSafeTreeDeleteRetiredEvidenceRootGrantUnconsumed `
        -Target $target `
        -EvidenceRoot $EvidenceRoot
    Assert-CodexSafeTreeDeleteDeletionAllowed `
        -TargetPath $target.targetPath `
        -FileSystemCapabilitiesForTest $FileSystemCapabilitiesForTest
    $planStreamSet = Read-CodexSafeTreeDeletePlanStreamSet -Plan $plan
    $sessionHashCache = $null
    $applyFileIdentities = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $plan
    Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
        -Plan $plan `
        -Target $target `
        -TreePath ([string]$target.targetPath) `
        -Scope 'safe-delete apply preflight'
    $sessionHashCache = if ($null -ne $SessionHashCacheForTest) {
        $SessionHashCacheForTest
    } else {
        [CodexSafeTreeDelete.SessionHashCache]::new()
    }
    $applyReuseEnabled = -not $DisableApplyHashReuseForTest.IsPresent
    $applyCoordinator = [CodexSafeTreeDelete.ApplySessionHashCoordinator]::new(
        $applyFileIdentities,
        $sessionHashCache,
        $applyReuseEnabled)
    $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $target
    $currentTree = if ($applyReuseEnabled) {
        Get-CodexSafeTreeDeleteApplyTreeSnapshot `
            -Path $target.targetPath `
            -CapabilityRoot $target.capabilityRoot `
            -AllowedExactPaths @($target.targetPath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $primaryMetricsObserver `
            -Coordinator $applyCoordinator `
            -Name 'safe-delete apply preflight'
    } else {
        Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $target.targetPath `
            -CapabilityRoot $target.capabilityRoot `
            -AllowedExactPaths @($target.targetPath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
            -MetricsObserver $primaryMetricsObserver `
            -Name 'safe-delete apply preflight'
    }
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
        $lockedTree = if ($applyReuseEnabled) {
            Get-CodexSafeTreeDeleteApplyTreeSnapshot `
                -Path $target.targetPath `
                -CapabilityRoot $target.capabilityRoot `
                -AllowedExactPaths @($target.targetPath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -MetricsObserver $repeatMetricsObserver `
                -Coordinator $applyCoordinator `
                -Name 'safe-delete apply locked preflight'
        } else {
            Get-CodexHookCapabilityDirectoryTreeSnapshot `
                -Path $target.targetPath `
                -CapabilityRoot $target.capabilityRoot `
                -AllowedExactPaths @($target.targetPath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -MetricsObserver $repeatMetricsObserver `
                -Name 'safe-delete apply locked preflight'
        }
        Assert-CodexSafeTreeDeleteTargetTreePolicy `
            -Target $target `
            -TreeManifest $lockedTree `
            -TreePath $target.targetPath
        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $lockedTree) -cne
            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
            throw 'safe-delete apply locked preflight tree manifest 漂移。'
        }
        $applyStreamCaptures = if (Test-Path Variable:Script:CodexSafeTreeDeleteLastStreamCaptures) { $script:CodexSafeTreeDeleteLastStreamCaptures } else { $null }
        Assert-CodexSafeTreeDeleteLiveStreamSet `
            -PlanStreamSet $planStreamSet `
            -TreeManifest $lockedTree `
            -TreePath ([string]$target.targetPath) `
            -Phase 'apply' `
            -CapturedStreamSets $applyStreamCaptures
        Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
            -Plan $plan `
            -Target $target `
            -TreePath ([string]$target.targetPath) `
            -Scope 'safe-delete apply locked preflight'
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
        $quarantinedTree = if ($applyReuseEnabled) {
            Get-CodexSafeTreeDeleteApplyTreeSnapshot `
                -Path $quarantinePath `
                -CapabilityRoot $quarantineCapabilityRoot `
                -AllowedExactPaths @($quarantinePath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -MetricsObserver $repeatMetricsObserver `
                -Coordinator $applyCoordinator `
                -Name 'safe-delete quarantine postcheck'
        } else {
            Get-CodexHookCapabilityDirectoryTreeSnapshot `
                -Path $quarantinePath `
                -CapabilityRoot $quarantineCapabilityRoot `
                -AllowedExactPaths @($quarantinePath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -MetricsObserver $repeatMetricsObserver `
                -Name 'safe-delete quarantine postcheck'
        }
        Assert-CodexSafeTreeDeleteTargetTreePolicy `
            -Target $target `
            -TreeManifest $quarantinedTree `
            -TreePath $quarantinePath
        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $quarantinedTree) -cne
            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
            throw 'safe-delete quarantine postcheck tree manifest 漂移。'
        }
        Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
            -Plan $plan `
            -Target $target `
            -TreePath $quarantinePath `
            -Scope 'safe-delete quarantine postcheck'

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
        if ($null -ne $sessionHashCache) {
            $sessionHashCache.Clear()
        }
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
        [scriptblock]$MetricsObserver,
        [AllowNull()][CodexSafeTreeDelete.StatusPlanValidationReceipt]$StatusPlanValidation
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

    $statusPlanArguments = @{}
    # Keep the live plan/policy reads to detect drift; reuse only content validation.
    if ($AllowRestoreState -and $null -ne $StatusPlanValidation -and
        $StatusPlanValidation.MatchesPlanPath([string]$transaction.planPath)) {
        $statusPlanArguments = @{
            StatusPlanValidation = $StatusPlanValidation
        }
    }
    $approvedPlan = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath ([string]$transaction.planPath) `
        -ApprovedPlanSha256 ([string]$transaction.planSha256) `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot `
        -AllowMissingTarget `
        -AllowExpiredPlan `
        -AllowPolicyShaDrift:($transactionSchemaVersion -eq 3L) `
        -MetricsObserver $MetricsObserver @statusPlanArguments
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
        if ($status -cin @('purged', 'rolled-back') -or
            ($status -ceq 'restored' -and
                [string]$target.rootDeletionPurpose -ceq 'retired-evidence-root')) {
            throw 'safe-delete Restore 拒绝不可恢复的 terminal transaction。'
        }
        Assert-CodexSafeTreeDeleteRetiredEvidenceRootLivePolicySha `
            -Plan $plan `
            -Target $target `
            -PolicyPath $PolicyPath `
            -MetricsObserver $repeatMetricsObserver
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
        Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
            -Plan $plan `
            -Target $target `
            -TreePath $treePath `
            -Scope 'safe-delete restore preflight'
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

function Get-CodexSafeTreeDeleteInFlightRecovery {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$GenerationId,
        [AllowEmptyCollection()][object[]]$DirectoryCommitAnchors = @(),
        [string]$QuarantinePath,
        [scriptblock]$MetricsObserver
    )

    $fullRunDirectory = Assert-CodexHookDPath `
        -Value $RunDirectory `
        -Name 'safe-delete in-flight recovery root'
    $anchoredOperationIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($anchor in @($DirectoryCommitAnchors)) {
        if ($null -eq $anchor -or -not $anchor.PSObject.Properties['operationId']) { continue }
        $anchorOperationId = [string]$anchor.operationId
        if ($anchorOperationId -notmatch '^[0-9a-f]{32}$') {
            throw 'safe-delete in-flight recovery anchor operationId 非法。'
        }
        if (-not $anchoredOperationIds.Add($anchorOperationId)) {
            throw 'safe-delete in-flight recovery anchor operation 重复。'
        }
    }

    $pendingFiles = [Collections.Generic.List[string]]::new()
    $uncertainFiles = [Collections.Generic.List[string]]::new()
    $seenOperations = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($freezePathCandidate in @([IO.Directory]::EnumerateFiles(
            $fullRunDirectory,
            'directory-delete-*-freeze.json',
            [IO.SearchOption]::TopDirectoryOnly))) {
        $freezePath = Assert-CodexHookDPath `
            -Value $freezePathCandidate `
            -Name 'safe-delete in-flight freeze journal path'
        [void](Assert-CodexHookCapabilityPath `
            -Path $freezePath `
            -CapabilityRoot $fullRunDirectory `
            -AllowedExactPaths @($freezePath) `
            -Name 'safe-delete in-flight freeze journal')
        if ([IO.Path]::GetFileName($freezePath) -notmatch '^directory-delete-.+-freeze\.json$') {
            throw 'safe-delete in-flight freeze journal 命名非法。'
        }
        $freezeSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
            -Path $freezePath `
            -Name 'safe-delete in-flight freeze journal' `
            -AllowedExactPaths @($freezePath)
        if ($null -ne $MetricsObserver) {
            & $MetricsObserver 'hash-read' 0L ([long]$freezeSnapshot.bytes.Length)
        }
        # 只分类可识别的 freeze-prepared；畸形/orphan journal 留给既有 abort/anchor 门禁。
        try {
            Assert-CodexHookStrictJsonText -JsonText $freezeSnapshot.text
            $freeze = $freezeSnapshot.text |
                ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        } catch {
            continue
        }
        $requiredFreezeNames = @(
            'artifactType', 'schemaVersion', 'generationId', 'operationId',
            'directoryPath', 'relativePath', 'volumeSerialNumber', 'fileIndex',
            'state', 'originalSecurityDescriptorSddl',
            'requestedFrozenSecurityDescriptorSddl', 'createdAtUtc'
        )
        $actualFreezeNames = @($freeze.PSObject.Properties.Name)
        if (@($requiredFreezeNames | Where-Object { $_ -notin $actualFreezeNames }).Count -ne 0) {
            continue
        }
        if ([string]$freeze.artifactType -cne
                'env-governance.codex-safe-tree-delete-directory-freeze-intent' -or
            [long]$freeze.schemaVersion -ne 2 -or
            [string]$freeze.generationId -cne $GenerationId -or
            [string]$freeze.operationId -notmatch '^[0-9a-f]{32}$' -or
            [string]$freeze.state -cne 'freeze-prepared') {
            continue
        }
        try {
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @([string]$freeze.volumeSerialNumber, [string]$freeze.fileIndex) `
                -Actual @([string]$freeze.volumeSerialNumber, [string]$freeze.fileIndex) `
                -Scope 'safe-delete in-flight freeze journal directory identity'
            $directoryPath = Assert-CodexHookDPath `
                -Value ([string]$freeze.directoryPath) `
                -Name 'safe-delete in-flight freeze directory path'
        } catch {
            continue
        }
        if (-not $seenOperations.Add([string]$freeze.operationId)) {
            throw 'safe-delete in-flight freeze journal operation 重复。'
        }
        $commitPath = $freezePath -replace '-freeze\.json$', '-commit.json'
        $abortPath = $freezePath -replace '-freeze\.json$', '-abort.json'
        if ([IO.File]::Exists($commitPath) -or
            [IO.File]::Exists($abortPath) -or
            $anchoredOperationIds.Contains([string]$freeze.operationId)) {
            continue
        }
        if (-not $seenPaths.Add($directoryPath)) {
            throw 'safe-delete in-flight freeze journal directoryPath 重复。'
        }
        $pathPresent = [IO.Directory]::Exists($directoryPath) -or [IO.File]::Exists($directoryPath)
        if ($pathPresent) {
            $pendingFiles.Add($directoryPath)
        } else {
            $uncertainFiles.Add($directoryPath)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($QuarantinePath)) {
        $parallelJournalRoots = @(
            [IO.Directory]::EnumerateDirectories(
                $fullRunDirectory,
                'parallel-purge-journal*',
                [IO.SearchOption]::TopDirectoryOnly)
        )
        if ($parallelJournalRoots.Count -gt 0) {
            $quarantineFullPath = Assert-CodexHookDPath `
                -Value $QuarantinePath `
                -Name 'safe-delete in-flight parallel purge quarantine'
            $lastOpByRelative = [Collections.Generic.Dictionary[string, string]]::new(
                [StringComparer]::Ordinal)
            foreach ($parallelJournalRoot in $parallelJournalRoots) {
            foreach ($journalPathCandidate in @([IO.Directory]::EnumerateFiles(
                    $parallelJournalRoot,
                    '*.thread-*.jsonl',
                    [IO.SearchOption]::TopDirectoryOnly))) {
                $journalPath = Assert-CodexHookDPath `
                    -Value $journalPathCandidate `
                    -Name 'safe-delete in-flight parallel purge journal path'
                [void](Assert-CodexHookCapabilityPath `
                    -Path $journalPath `
                    -CapabilityRoot $fullRunDirectory `
                    -AllowedExactPaths @($journalPath) `
                    -Name 'safe-delete in-flight parallel purge journal')
                $journalName = [IO.Path]::GetFileName($journalPath)
                if ($journalName -notmatch '^[A-Za-z0-9._-]+\.thread-\d+\.jsonl$') {
                    throw "safe-delete in-flight parallel purge journal 命名非法：$journalName"
                }

                $journalSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
                    -Path $journalPath `
                    -Name 'safe-delete in-flight parallel purge journal' `
                    -AllowedExactPaths @($journalPath)
                if ($null -ne $MetricsObserver) {
                    & $MetricsObserver 'hash-read' 0L ([long]$journalSnapshot.bytes.Length)
                }

                $lines = @(([string]$journalSnapshot.text) -split "`n")
                foreach ($rawLine in $lines) {
                    $line = [string]$rawLine
                    if ($line.Length -eq 0) { continue }
                    if ($line -notmatch '^\{"op":"(pending|commit)","path":"([^"]+)"\}$') {
                        throw "safe-delete in-flight parallel purge journal 行非法：$line"
                    }

                    $op = [string]$Matches[1]
                    $relative = [string]$Matches[2]
                    Assert-CodexHookDirectoryTreeRelativePath `
                        -RelativePath $relative `
                        -Scope 'safe-delete in-flight parallel purge journal path'
                    $existingOp = $null
                    if ($lastOpByRelative.TryGetValue($relative, [ref]$existingOp) -and
                        [string]$existingOp -ceq 'commit') {
                        continue
                    }
                    $lastOpByRelative[$relative] = $op
                }
            }
            }

            foreach ($pair in $lastOpByRelative.GetEnumerator()) {
                $relative = [string]$pair.Key
                $lastOp = [string]$pair.Value
                $absolute = ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
                    -TargetPath $quarantineFullPath `
                    -RelativePath $relative
                $pathPresent = [IO.File]::Exists($absolute) -or [IO.Directory]::Exists($absolute)
                if ($lastOp -ceq 'commit') {
                    if ($pathPresent) {
                        throw "safe-delete parallel purge commit 后路径仍在：$relative"
                    }
                    continue
                }

                if (-not $seenPaths.Add($absolute)) {
                    throw "safe-delete in-flight parallel purge journal 路径重复：$relative"
                }

                if ($pathPresent) {
                    $pendingFiles.Add($absolute)
                } else {
                    $uncertainFiles.Add($absolute)
                }
            }
        }
    }

    $pendingFiles.Sort([StringComparer]::OrdinalIgnoreCase)
    $uncertainFiles.Sort([StringComparer]::OrdinalIgnoreCase)
    return [pscustomobject][ordered]@{
        pendingFiles = @($pendingFiles)
        uncertainFiles = @($uncertainFiles)
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
    if ($expectedDirectories.Count -eq 0) {
        throw 'safe-delete anchored directory journal 缺少计划目录。'
    }
    # Mixed trees still authenticate freeze/commit journals for planned directories.
    # Do not use empty-project-state's "pure directory tree" gate as the only auth.
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
        [IO.Directory]::Exists([string]$transaction.quarantinePath) -or
        [IO.File]::Exists([string]$transaction.quarantinePath)) {
        throw 'safe-delete 缺失 quarantine 不满足 commit journal 恢复条件。'
    }
    $runDirectory = Split-Path -Parent $ApprovedTransaction.path
    $planStreamSet = Read-CodexSafeTreeDeletePlanStreamSet -Plan $plan
    # dispositions 发布先于 purged 落盘；崩溃落在窗口内时以绑定+载荷校验通过的既有证据为准幂等收口，不重建比对。
    $publishedDispositions = Read-CodexSafeTreeDeletePublishedLeafDispositions `
        -RunDirectory $runDirectory `
        -GenerationId ([string]$plan.generationId) `
        -PlanSha256 ([string]$approvedPlan.sha256) `
        -TransactionPath ([string]$ApprovedTransaction.path) `
        -QuarantinePath ([string]$transaction.quarantinePath) `
        -PurgingTransactionUpdatedAtUtc ([string]$transaction.updatedAtUtc) `
        -PlanStreamSet $planStreamSet
    if ($null -eq $publishedDispositions -and
        [string]$target.rootDeletionPurpose -cne 'empty-project-state') {
        throw 'safe-delete 缺失 quarantine 不满足 commit journal 恢复条件。'
    }
    if ([string]$target.rootDeletionPurpose -ceq 'empty-project-state') {
        [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
            -RunDirectory $runDirectory `
            -Transaction $transaction `
            -Plan $plan `
            -RequireComplete `
            -MetricsObserver $MetricsObserver)
    }
    if ($null -ne $publishedDispositions) {
        $leafDispositionPublication = $publishedDispositions
    } else {
        $leafDispositionDocument = New-CodexSafeTreeDeleteLeafDispositionDocument `
            -PlanStreamSet $planStreamSet `
            -GenerationId ([string]$plan.generationId) `
            -PlanSha256 ([string]$approvedPlan.sha256) `
            -TransactionPath ([string]$ApprovedTransaction.path) `
            -QuarantinePath ([string]$transaction.quarantinePath) `
            -PurgingTransactionUpdatedAtUtc ([string]$transaction.updatedAtUtc) `
            -CommittedLeaves @() `
            -PreflightLiveLeafSet ([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)) `
            -AbsentLeafEvidence 'committed-missing-quarantine-journal'
        $leafDispositionPublication = Publish-CodexSafeTreeDeleteLeafDispositions `
            -Document $leafDispositionDocument `
            -RunDirectory $runDirectory
    }
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
        leafDispositionsPath = [string]$leafDispositionPublication.path
        leafDispositionsSha256 = [string]$leafDispositionPublication.sha256
        recoverable = $false
        # 仅缺失 dispositions、按完整 commit journal 重建收口的路径才算 journal 恢复；
        # dispositions 幂等复用路径未以 journal 为恢复依据，必须如实报告 $false。
        recoveredFromCommitJournal = ($null -eq $publishedDispositions)
        pendingFiles = @()
        uncertainFiles = @()
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

function Test-CodexSafeTreeDeleteParallelPurgeEligible {
    param(
        [Parameter(Mandatory)][object]$Capabilities,
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$TreeManifest,
        [switch]$DisablePurgeHashReuseForTest,
        [switch]$DisableParallelPurgeForTest,
        [scriptblock]$LeafDeleteCheckpointForTest,
        [scriptblock]$LeafDeleteFaultForTest,
        [scriptblock]$DirectoryDeleteCheckpointForTest
    )

    if ($DisablePurgeHashReuseForTest -or $DisableParallelPurgeForTest) {
        return $false
    }

    if ($null -eq $Capabilities -or -not [bool]$Capabilities.RecommendParallel) {
        return $false
    }

    if ([string]$Target.rootDeletionPurpose -ceq 'empty-project-state') {
        return $false
    }
    if ([string]$Target.rootDeletionPurpose -ceq 'retired-evidence-root') {
        return $false
    }

    if ($null -ne $LeafDeleteCheckpointForTest -or
        $null -ne $LeafDeleteFaultForTest -or
        $null -ne $DirectoryDeleteCheckpointForTest) {
        return $false
    }

    foreach ($entry in @($TreeManifest.entries)) {
        if ([string]$entry.kind -ceq 'directory-junction') {
            return $false
        }
    }

    return $true
}

function New-CodexSafeTreeDeleteParallelPurgeDirectorySpecs {
    param(
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][object]$TreeManifest
    )

    $specs = [Collections.Generic.List[CodexSafeTreeDelete.HostSafetyParallelPurgeDirectorySpec]]::new()
    foreach ($entry in @($TreeManifest.entries)) {
        if ([string]$entry.kind -cne 'directory') {
            continue
        }

        $relativePath = [string]$entry.relativePath
        if ($relativePath -ceq '.') {
            continue
        }

        $identity = @($entry.identity)
        if ($identity.Count -ne 2) {
            throw "safe-delete parallel purge 目录 identity 非法：$relativePath"
        }

        $spec = [CodexSafeTreeDelete.HostSafetyParallelPurgeDirectorySpec]::new()
        $spec.LiteralPath = ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
            -TargetPath $TreePath `
            -RelativePath $relativePath
        $spec.RelativePath = $relativePath
        $spec.VolumeSerialNumber = [string]$identity[0]
        $spec.FileIndex = [string]$identity[1]
        $specs.Add($spec)
    }

    return $specs
}

function New-CodexSafeTreeDeleteParallelPurgeLeafSpecs {
    param(
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][object]$TreeManifest,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, CodexSafeTreeDelete.FileIdentityV2]]$ExpectedIdentities
    )

    $specs = [Collections.Generic.Dictionary[string, CodexSafeTreeDelete.HostSafetyParallelPurgeLeafSpec]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($TreeManifest.entries)) {
        if ([string]$entry.kind -cne 'file') {
            continue
        }

        $relativePath = [string]$entry.relativePath
        $expected = $null
        if (-not $ExpectedIdentities.TryGetValue($relativePath, [ref]$expected) -or $null -eq $expected) {
            throw "safe-delete parallel purge fileIdentitiesV2 缺少：$relativePath"
        }

        $literalPath = ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
            -TargetPath $TreePath `
            -RelativePath $relativePath
        $sha256 = [string]$entry.sha256
        if ($sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "safe-delete parallel purge 计划 SHA-256 非法：$relativePath"
        }

        $identity = @($entry.identity)
        if ($identity.Count -ne 2) {
            throw "safe-delete parallel purge 计划 identity 非法：$relativePath"
        }

        $spec = [CodexSafeTreeDelete.HostSafetyParallelPurgeLeafSpec]::new()
        $spec.LiteralPath = $literalPath
        $spec.RelativePath = $relativePath
        $spec.Identity = $expected
        $spec.VolumeSerialNumber = [string]$identity[0]
        $spec.FileIndex = [string]$identity[1]
        $spec.Sha256Hex = $sha256
        $specs.Add($literalPath, $spec)
    }

    return $specs
}

function Remove-CodexSafeTreeDeleteEmptyDirectoryTreeAfterParallelPurge {
    param(
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][object]$TreeManifest,
        [AllowEmptyCollection()][string[]]$AllowedExactPaths = @()
    )

    $fullTreePath = Assert-CodexHookCapabilityPath `
        -Path $TreePath `
        -CapabilityRoot $CapabilityRoot `
        -AllowedExactPaths $AllowedExactPaths `
        -Name 'safe-delete parallel purge empty-directory cleanup'
    $directories = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($TreeManifest.entries)) {
        if ([string]$entry.kind -ceq 'directory') {
            $directories.Add($entry)
        }
    }

    $ordered = @($directories | Sort-Object -Property @{
        Expression = {
            $relative = [string]$_.relativePath
            if ($relative -ceq '.') { 0 } else { $relative.Length }
        }
        Descending = $true
    })
    foreach ($entry in $ordered) {
        $relative = [string]$entry.relativePath
        $directoryPath = if ($relative -ceq '.') {
            $fullTreePath
        } else {
            ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
                -TargetPath $fullTreePath `
                -RelativePath $relative
        }
        if (-not [IO.Directory]::Exists($directoryPath)) {
            continue
        }

        [void](Assert-CodexHookCapabilityPath `
            -Path $directoryPath `
            -CapabilityRoot $CapabilityRoot `
            -Name 'safe-delete parallel purge empty directory')
        $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete(
            $CapabilityRoot,
            $directoryPath)
        $deleted = $false
        try {
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($entry.identity) `
                -Actual @($guard.VolumeSerialNumber, $guard.FileIndex) `
                -Scope 'safe-delete parallel purge empty directory identity'
            $guard.DeleteEmptyDirectory()
            $deleted = $true
        } finally {
            if (-not $deleted) {
                $guard.Dispose()
            }
        }
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
        [scriptblock]$AfterLeafDispositionsPublishForTest,
        [object]$LeafRetryPolicyForTest,
        [scriptblock]$LeafRetryElapsedMillisecondsForTest,
        [scriptblock]$LeafRetryDelayForTest,
        [Nullable[datetimeoffset]]$TrustedNowUtc,
        [Nullable[long]]$TrustedElapsedNowMilliseconds,
        [string]$TrustedBootSessionId,
        [scriptblock]$TrustedBootSessionSourceForTest,
        [switch]$TrustedTimeRestartAmbiguous,
        [switch]$ReturnFailureMetrics,
        [object]$FileSystemCapabilitiesForTest,
        [CodexSafeTreeDelete.SessionHashCache]$SessionHashCacheForTest,
        [switch]$DisablePurgeHashReuseForTest,
        [switch]$DisablePurgeBatchForTest,
        [switch]$DisableParallelPurgeForTest,
        [int]$PurgeMaxDegreeOfParallelismForTest = 0,
        [scriptblock]$PurgeFileLeafBatchObserverForTest,
        [scriptblock]$ParallelPurgeAfterPendingFlushedForTest,
        [int]$ParallelPurgeFailAfterPendingCountForTest = 0
    )

    $metricsState = New-CodexSafeTreeDeleteMetricsState -Phase 'purge'
    $sessionHashCache = if ($null -ne $SessionHashCacheForTest) {
        $SessionHashCacheForTest
    } else {
        [CodexSafeTreeDelete.SessionHashCache]::new()
    }
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
    $deleteState = [pscustomobject][ordered]@{
        anyCommit = $false
        committedLeaves = [Collections.Generic.List[object]]::new()
    }
    $deleteCommitCallback = {
        param([string]$Path, [string]$Kind)
        $deleteState.anyCommit = $true
        $deleteState.committedLeaves.Add([pscustomobject][ordered]@{
            path = $Path
            kind = $Kind
        })
    }.GetNewClosure()
    $initialApproved = Read-CodexSafeTreeDeleteApprovedTransaction `
        -TransactionPath $TransactionPath `
        -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot `
        -MetricsObserver $repeatMetricsObserver
    $initialTarget = $initialApproved.approvedPlan.target
    # Apply 后原 target 已不存在；DetectFileSystem 对缺路径会得到 DeletionAllowed=false。
    # 根删除（empty-project-state）的 capabilityRoot 就是已搬走的 target，不能回退到它，
    # 否则会挡住 committed-missing quarantine 恢复。改用仍存在的 quarantine capability root
    #（根删除时是 parent）。
    $deletionProbePath = [string]$initialApproved.document.quarantinePath
    if (-not [IO.Directory]::Exists($deletionProbePath) -and
        -not [IO.File]::Exists($deletionProbePath)) {
        $deletionProbePath = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $initialTarget
    }
    Assert-CodexSafeTreeDeleteDeletionAllowed `
        -TargetPath $deletionProbePath `
        -FileSystemCapabilitiesForTest $FileSystemCapabilitiesForTest
    $purgeCapabilities = Get-CodexSafeTreeDeleteFileSystemCapabilities `
        -TargetPath $deletionProbePath `
        -FileSystemCapabilitiesForTest $FileSystemCapabilitiesForTest
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
        $planStreamSet = Read-CodexSafeTreeDeletePlanStreamSet -Plan $plan
        $purgeFileIdentities = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $plan
        $purgeFileHashProvider = $null
        if (-not $DisablePurgeHashReuseForTest) {
            $purgeFileHashProvider = New-CodexSafeTreeDeletePurgeFileHashProvider `
                -ExpectedIdentities $purgeFileIdentities `
                -SessionCache $sessionHashCache
        }
        $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $target
        $quarantinePath = [string]$transaction.quarantinePath
        $runDirectory = Split-Path -Parent $approved.path
        $inFlightRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
            -RunDirectory $runDirectory `
            -GenerationId ([string]$plan.generationId) `
            -DirectoryCommitAnchors @($transaction.directoryCommitAnchors) `
            -QuarantinePath $quarantinePath `
            -MetricsObserver $repeatMetricsObserver
        if (@($inFlightRecovery.uncertainFiles).Count -gt 0) {
            return [pscustomobject][ordered]@{
                purged = $false
                refusalReason = 'uncertain-pending-paths'
                pendingFiles = @($inFlightRecovery.pendingFiles)
                uncertainFiles = @($inFlightRecovery.uncertainFiles)
                targetPath = [string]$transaction.targetPath
                quarantinePath = $quarantinePath
                transactionPath = $approved.path
                recoverable = $false
                recoveredFromCommitJournal = $false
                logicalCompletion = $false
                metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
            }
        }
        if (-not [IO.Directory]::Exists($quarantinePath) -and
            -not [IO.File]::Exists($quarantinePath)) {
            return Complete-CodexSafeTreeDeleteCommittedMissingQuarantine `
                -ApprovedTransaction $approved `
                -MetricsState $metricsState `
                -MetricsObserver $repeatMetricsObserver
        }
        Assert-CodexSafeTreeDeleteRetiredEvidenceRootLivePolicySha `
            -Plan $plan `
            -Target $target `
            -PolicyPath $PolicyPath `
            -MetricsObserver $repeatMetricsObserver
        Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
            -Plan $plan `
            -Target $target `
            -TreePath $quarantinePath `
            -Scope 'safe-delete purge preflight'
        $purgeTimings = [pscustomobject][ordered]@{
            snapshotMs = 0L
            batchMs = 0L
            coordinatorMs = 0L
            emptyRootMs = 0L
            snapshotKind = 'powershell'
        }
        $snapshotWatch = [Diagnostics.Stopwatch]::StartNew()
        $currentTree = if (-not $DisablePurgeHashReuseForTest) {
            $purgeTimings.snapshotKind = 'csharp-apply-walker'
            $purgeSnapshotCoordinator = [CodexSafeTreeDelete.ApplySessionHashCoordinator]::new(
                $purgeFileIdentities,
                $sessionHashCache,
                $true)
            Get-CodexSafeTreeDeleteApplyTreeSnapshot `
                -Path $quarantinePath `
                -CapabilityRoot $quarantineCapabilityRoot `
                -AllowedExactPaths @($quarantinePath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -MetricsObserver $metricsObserver `
                -Coordinator $purgeSnapshotCoordinator `
                -Name 'safe-delete purge locked preflight'
        } else {
            Get-CodexHookCapabilityDirectoryTreeSnapshot `
                -Path $quarantinePath `
                -CapabilityRoot $quarantineCapabilityRoot `
                -AllowedExactPaths @($quarantinePath) `
                -AllowHardLinks:([bool]$target.allowHardLinks) `
                -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                -MetricsObserver $metricsObserver `
                -FileContentHashProvider $purgeFileHashProvider `
                -Name 'safe-delete purge locked preflight'
        }
        $snapshotWatch.Stop()
        $purgeTimings.snapshotMs = [long]$snapshotWatch.ElapsedMilliseconds
        Assert-CodexSafeTreeDeleteTargetTreePolicy `
            -Target $target `
            -TreeManifest $currentTree `
            -TreePath $quarantinePath
        Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
            -Plan $plan `
            -Target $target `
            -TreePath $quarantinePath `
            -Scope 'safe-delete purge locked preflight'
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
        $purgeResumedFromPurging = [string]$transaction.status -ceq 'purging'
        $preflightLiveLeafSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in @($currentTree.entries)) {
            [void]$preflightLiveLeafSet.Add([string]$entry.relativePath)
        }
        $purgeStreamCaptures = if (Test-Path Variable:Script:CodexSafeTreeDeleteLastStreamCaptures) { $script:CodexSafeTreeDeleteLastStreamCaptures } else { $null }
        Assert-CodexSafeTreeDeleteLiveStreamSet `
            -PlanStreamSet $planStreamSet `
            -TreeManifest $currentTree `
            -TreePath $quarantinePath `
            -Phase 'purge' `
            -AllowMissingPlannedLeaves:$purgeResumedFromPurging `
            -CapturedStreamSets $purgeStreamCaptures

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
        $enablePurgeBatch = -not $DisablePurgeBatchForTest
        $csharpSnapshotFilledCache = [string]$purgeTimings.snapshotKind -ceq 'csharp-apply-walker'
        if ($enablePurgeBatch -and
            (-not $csharpSnapshotFilledCache -or $null -ne $PurgeFileLeafBatchObserverForTest)) {
            # Pass 1: collect file leaves (path + FileIdentityV2) into List<T>.
            # Pass 2: verify hashes via existing PurgeFileHash / GetHashSafely
            # unless the C# preflight walker already filled the session cache.
            # Pass 3+4 stay in Remove-CodexHookCapabilityDirectoryTree or the
            # parallel HostSafety deleter. Never write the whole tree pending
            # and then delete the whole tree.
            $batchWatch = [Diagnostics.Stopwatch]::StartNew()
            $purgeFileLeafBatch = New-CodexSafeTreeDeletePurgeFileLeafBatch `
                -TreePath $quarantinePath `
                -TreeManifest $purgeManifest `
                -ExpectedIdentities $purgeFileIdentities
            if ($null -ne $PurgeFileLeafBatchObserverForTest) {
                & $PurgeFileLeafBatchObserverForTest $purgeFileLeafBatch 'collected'
            }
            if (-not $DisablePurgeHashReuseForTest) {
                if ($purgeFileLeafBatch.Count -gt 0) {
                    Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation `
                        -Leaves $purgeFileLeafBatch `
                        -ExpectedIdentities $purgeFileIdentities `
                        -SessionCache $sessionHashCache
                }
            }
            if ($null -ne $PurgeFileLeafBatchObserverForTest) {
                & $PurgeFileLeafBatchObserverForTest $purgeFileLeafBatch 'validated'
            }
            $batchWatch.Stop()
            $purgeTimings.batchMs = [long]$batchWatch.ElapsedMilliseconds
        }
        if ($null -ne $BeforeDirectoryTreeDeleteForTest) {
            & $BeforeDirectoryTreeDeleteForTest $quarantinePath
        }
        $parallelPurgeInfo = [pscustomobject][ordered]@{
            used = $false
            reason = 'serial-host-safety'
            maxDegreeOfParallelism = 1
            journalFileCount = 0
            deletedCount = 0
            failedCount = 0
            elapsedMs = 0
            journalOverheadPercent = $null
            journalIsWithinTarget = $null
            journalFlushCount = $null
        }
        $useParallelPurge = Test-CodexSafeTreeDeleteParallelPurgeEligible `
            -Capabilities $purgeCapabilities `
            -Target $target `
            -TreeManifest $purgeManifest `
            -DisablePurgeHashReuseForTest:$DisablePurgeHashReuseForTest `
            -DisableParallelPurgeForTest:$DisableParallelPurgeForTest `
            -LeafDeleteCheckpointForTest $LeafDeleteCheckpointForTest `
            -LeafDeleteFaultForTest $LeafDeleteFaultForTest `
            -DirectoryDeleteCheckpointForTest $DirectoryDeleteCheckpointForTest
        try {
            if ($useParallelPurge) {
                $parallelCaps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection(
                    [string]$purgeCapabilities.FileSystemType,
                    [bool]$purgeCapabilities.IsRemote,
                    [bool]$purgeCapabilities.SupportsFileId128)
                if ($PurgeMaxDegreeOfParallelismForTest -ge 1) {
                    $parallelCaps.RecommendedMaxParallelism = [int]$PurgeMaxDegreeOfParallelismForTest
                }

                $parallelJournalStamp = [guid]::NewGuid().ToString('N')
                $parallelJournalRoot = Join-Path $runDirectory (
                    'parallel-purge-journal-{0}' -f $parallelJournalStamp)
                if (-not [IO.Directory]::Exists($parallelJournalRoot)) {
                    [void][IO.Directory]::CreateDirectory($parallelJournalRoot)
                }

                $leafSpecs = New-CodexSafeTreeDeleteParallelPurgeLeafSpecs `
                    -TreePath $quarantinePath `
                    -TreeManifest $purgeManifest `
                    -ExpectedIdentities $purgeFileIdentities
                $directorySpecs = New-CodexSafeTreeDeleteParallelPurgeDirectorySpecs `
                    -TreePath $quarantinePath `
                    -TreeManifest $purgeManifest
                $cacheLock = [object]::new()
                $coordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
                    $quarantinePath,
                    $parallelJournalRoot,
                    $quarantineCapabilityRoot,
                    $runDirectory,
                    $parallelCaps)
                try {
                    $coordinator.CreateLeafDeleter =
                        [CodexSafeTreeDelete.HostSafetyParallelPurgeLeafDeleter]::CreateFactory(
                            $quarantineCapabilityRoot,
                            $quarantinePath,
                            [bool]$target.allowHardLinks,
                            $leafSpecs,
                            $directorySpecs,
                            $sessionHashCache,
                            $cacheLock)
                    if ($null -ne $ParallelPurgeAfterPendingFlushedForTest) {
                        $afterPending = $ParallelPurgeAfterPendingFlushedForTest
                        $coordinator.AfterPendingFlushed = {
                            param([string]$JournalFilePath, [string]$FilePath)
                            & $afterPending $JournalFilePath $FilePath
                        }.GetNewClosure()
                    }
                    if ($ParallelPurgeFailAfterPendingCountForTest -gt 0) {
                        $coordinator.FailAfterPendingFlushedCount =
                            [int]$ParallelPurgeFailAfterPendingCountForTest
                    }

                    $parallelResult = $coordinator.Purge()
                } finally {
                    $coordinator.Dispose()
                }

                $journalPerf = $parallelResult.JournalPerformance
                $parallelPurgeInfo = [pscustomobject][ordered]@{
                    used = $true
                    reason = 'capabilities-recommend-parallel'
                    maxDegreeOfParallelism = [int]$coordinator.MaxDegreeOfParallelism
                    journalFileCount = [int]$parallelResult.JournalFileCount
                    deletedCount = [int]$parallelResult.DeletedCount
                    failedCount = [int]$parallelResult.FailedCount
                    elapsedMs = [long]$parallelResult.ElapsedMs
                    journalOverheadPercent = $(if ($null -ne $journalPerf) {
                        [double]$journalPerf.OverheadPercent
                    } else { $null })
                    journalIsWithinTarget = $(if ($null -ne $journalPerf) {
                        [bool]$journalPerf.IsWithinTarget
                    } else { $null })
                    journalFlushCount = $(if ($null -ne $journalPerf) {
                        [int]$journalPerf.FlushCount
                    } else { $null })
                    usedHostSafetyDeleter = [bool]$parallelResult.UsedHostSafetyDeleter
                    timings = $purgeTimings
                }
                foreach ($relative in @($parallelResult.DeletedRelativePaths)) {
                    $deletedPath = ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative `
                        -TargetPath $quarantinePath `
                        -RelativePath $relative
                    & $deleteCommitCallback $deletedPath 'file'
                }

                if ([int]$parallelResult.FailedCount -gt 0) {
                    $firstError = if (@($parallelResult.Errors).Count -gt 0) {
                        [string]$parallelResult.Errors[0]
                    } else {
                        'parallel purge failed without an error message'
                    }
                    throw "safe-delete parallel purge 失败：$firstError"
                }

                if ([int]$parallelResult.DeletedCount -ne $leafSpecs.Count) {
                    throw (
                        "safe-delete parallel purge 删除计数不一致：" +
                        "$($parallelResult.DeletedCount)/$($leafSpecs.Count)"
                    )
                }

                $purgeTimings.coordinatorMs = [long]$parallelResult.ElapsedMs
                # C# coordinator 只按文件枚举分组：不含任何文件的顶层分支（含整树
                # 纯空目录）不会产生分组，其目录必须在这里按 manifest 先叶后根补删
                #（幂等，跳过 coordinator 已删除的目录），否则根删除的 empty 断言
                # 会稳定失败并让 transaction 停在 purging/quarantined。resume-from-
                # purging 时 $purgeManifest 是当前存活子集，其目录 identity 与现场
                # 一致；非 resume 时 Apply 改名不改变目录 identity，plan manifest
                # 条目仍然有效。
                Remove-CodexSafeTreeDeleteEmptyDirectoryTreeAfterParallelPurge `
                    -TreePath $quarantinePath `
                    -CapabilityRoot $quarantineCapabilityRoot `
                    -TreeManifest $purgeManifest `
                    -AllowedExactPaths @($quarantinePath)
                $emptyRootWatch = [Diagnostics.Stopwatch]::StartNew()
                if ([IO.Directory]::Exists($quarantinePath)) {
                    $rootEntry = @($purgeManifest.entries | Where-Object {
                        [string]$_.kind -ceq 'directory' -and [string]$_.relativePath -ceq '.'
                    })
                    if ($rootEntry.Count -ne 1) {
                        throw 'safe-delete parallel purge 缺少根目录 manifest 条目。'
                    }
                    $rootGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete(
                        $quarantineCapabilityRoot,
                        $quarantinePath)
                    $rootDeleted = $false
                    try {
                        Assert-CodexHookDirectoryTreeIdentity `
                            -Expected @($rootEntry[0].identity) `
                            -Actual @($rootGuard.VolumeSerialNumber, $rootGuard.FileIndex) `
                            -Scope 'safe-delete parallel purge empty root identity'
                        $rootGuard.DeleteEmptyDirectory()
                        $rootDeleted = $true
                    } finally {
                        if (-not $rootDeleted) {
                            $rootGuard.Dispose()
                        }
                    }
                }
                $emptyRootWatch.Stop()
                $purgeTimings.emptyRootMs = [long]$emptyRootWatch.ElapsedMilliseconds
            } else {
                Remove-CodexHookCapabilityDirectoryTree `
                    -Path $quarantinePath `
                    -CapabilityRoot $quarantineCapabilityRoot `
                    -AllowedExactPaths @($quarantinePath) `
                    -AllowHardLinks:([bool]$target.allowHardLinks) `
                    -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                    -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                    -ExpectedRootIdentity @($plan.treeManifest.rootIdentity) `
                    -ExpectedTreeManifest $purgeManifest `
                    -RejectNamedStreams:([string]$target.rootDeletionPurpose -cin @(
                        'empty-project-state', 'retired-evidence-root')) `
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
                    -FileContentHashProvider $purgeFileHashProvider `
                    -Scope 'safe-delete approved purge'
            }
        } catch {
            $purgeFailure = $_
            if (-not [bool]$deleteState.anyCommit -and
                @($transaction.directoryCommitAnchors).Count -eq 0 -and
                [IO.Directory]::Exists($quarantinePath)) {
                try {
                    $unchangedTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
                        -Path $quarantinePath `
                        -CapabilityRoot $quarantineCapabilityRoot `
                        -AllowedExactPaths @($quarantinePath) `
                        -AllowHardLinks:([bool]$target.allowHardLinks) `
                        -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
                        -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
                        -MetricsObserver $repeatMetricsObserver `
                        -FileContentHashProvider $purgeFileHashProvider `
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
                } catch {
                    # 回滚快照/lease 失败不得改写 transaction，也不得盖住原来的 purge 失败。
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

        $leafDispositionDocument = New-CodexSafeTreeDeleteLeafDispositionDocument `
            -PlanStreamSet $planStreamSet `
            -GenerationId ([string]$plan.generationId) `
            -PlanSha256 ([string]$approved.approvedPlan.sha256) `
            -TransactionPath ([string]$approved.path) `
            -QuarantinePath $quarantinePath `
            -PurgingTransactionUpdatedAtUtc ([string]$transaction.updatedAtUtc) `
            -CommittedLeaves $deleteState.committedLeaves `
            -PreflightLiveLeafSet $preflightLiveLeafSet
        $leafDispositionPublication = Publish-CodexSafeTreeDeleteLeafDispositions `
            -Document $leafDispositionDocument `
            -RunDirectory $runDirectory
        if ($null -ne $AfterLeafDispositionsPublishForTest) {
            & $AfterLeafDispositionsPublishForTest `
                ([string]$leafDispositionPublication.path) `
                ([string]$leafDispositionPublication.sha256)
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
            leafDispositionsPath = [string]$leafDispositionPublication.path
            leafDispositionsSha256 = [string]$leafDispositionPublication.sha256
            recoverable = $false
            pendingFiles = @()
            uncertainFiles = @()
            namespaceAbsent = $true
            logicalCompletion = $true
            physicalReclaimStatus = 'unknown'
            physicalReclaimReason = 'independent-filesystem-allocation-evidence-unavailable'
            deletionOutcome = New-CodexSafeTreeDeleteOutcome `
                -NamespaceAbsent $true `
                -LogicalCompletion $true
            parallelPurge = $parallelPurgeInfo
            metrics = Complete-CodexSafeTreeDeleteMetrics -State $metricsState
        }
    } finally {
        if ($null -ne $sessionHashCache) {
            $sessionHashCache.Clear()
        }
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-CodexSafeTreeDeleteBatchHistoryScanEnabled {
    # kill switch：只有字符串 '0' 生效，退回逐目标参考查找（Find-CodexSafeTreeDeleteRecoverableTransaction）。
    return $env:CODEX_SAFE_TREE_DELETE_BATCH_HISTORY_SCAN -cne '0'
}

function New-CodexSafeTreeDeleteHistoryScanMetrics {
    param([Parameter(Mandatory)][ValidateSet('fast', 'reference')][string]$Mode)

    # BatchPurge 结果的 historyScan 字段。fast 模式每个枚举到的文件先过 C# 预筛（#78，
    # StatusScanCoordinator.ClassifyBatchHistoryTransaction）：canonicalFiles 是预筛裁决了的
    # 文件（run 目录第一层、producer 规范形态，且路径链、读取与解析都成功），其中能证明与本批
    # 任何目标都不匹配的计入 excludedByPrefilter 并跳过；fallbackFiles 是预筛不裁决、回退到
    # 参考认证链的文件。fullyAuthenticated 是扫描阶段走完参考认证链的文件数（成功扫描时等于
    # enumeratedFiles - excludedByPrefilter），不含处理阶段的候选重新认证。reference 模式不做
    # 预筛：每个文件都计入 fallbackFiles，各计数为逐目标扫描的累计值。
    return [pscustomobject][ordered]@{
        mode = $Mode
        scanCount = 0L
        enumeratedFiles = 0L
        canonicalFiles = 0L
        fallbackFiles = 0L
        excludedByPrefilter = 0L
        fullyAuthenticated = 0L
        elapsedMs = 0L
    }
}

function Set-CodexSafeTreeDeleteHistoryScanFailure {
    param(
        [Parameter(Mandatory)][object]$Metrics,
        [Parameter(Mandatory)][ValidateSet('scan', 'reauthentication')][string]$Phase,
        [AllowNull()][string]$TargetPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    # 只记录首个失败；后续失败不覆盖。
    if ($null -ne $Metrics.PSObject.Properties['failure']) { return }
    $Metrics | Add-Member -NotePropertyName failure -NotePropertyValue ([pscustomobject][ordered]@{
        phase = $Phase
        targetPath = if ([string]::IsNullOrEmpty($TargetPath)) { $null } else { $TargetPath }
        message = $Message
    })
}

function Read-CodexSafeTreeDeleteRecoverableHistoryRecord {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$FullEvidenceRoot
    )

    # 历史 transaction 的完整参考认证链：D 盘路径、capability 路径链（含 reparse 祖先）、
    # 句柄绑定读取与 SHA、严格 JSON、解析。逐目标参考查找、整批扫描与处理阶段的候选重新
    # 认证共用本函数，错误信息（-Name）因此在两种模式下逐字相同。
    $transactionFullPath = Assert-CodexHookDPath -Value $TransactionPath -Name 'safe-delete recover transaction path'
    [void](Assert-CodexHookCapabilityPath `
        -Path $transactionFullPath `
        -CapabilityRoot $FullEvidenceRoot `
        -AllowedExactPaths @($transactionFullPath) `
        -Name 'safe-delete recover transaction')
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $transactionFullPath `
        -Name 'safe-delete recover transaction' `
        -AllowedExactPaths @($transactionFullPath)
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $transaction = $snapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    return [pscustomobject][ordered]@{
        transactionPath = $transactionFullPath
        sha256 = [string]$snapshot.sha256
        status = [string]$transaction.status
        document = $transaction
    }
}

function New-CodexSafeTreeDeleteRecoverableAdjudication {
    param([Parameter(Mandatory)][string]$TargetPath)

    return [pscustomobject][ordered]@{
        targetPath = $TargetPath
        supportedMatches = [Collections.Generic.List[object]]::new()
        unsupportedMatches = [Collections.Generic.List[object]]::new()
        targetPresentAfterRecheck = $null
    }
}

function Add-CodexSafeTreeDeleteRecoverableCandidate {
    param(
        [Parameter(Mandatory)][object]$Adjudication,
        [Parameter(Mandatory)][object]$Record
    )

    # 调用方已确认：status 属于 prepared/quarantined/purging，且 targetPath 与目标
    # OrdinalIgnoreCase 相等（不做 Unicode 规范化）。
    $transaction = $Record.document
    $status = [string]$Record.status
    # 目标存在性判定只做一次并缓存（lazy 到首个路径匹配的事务才求值）：
    # 与 BatchPurge already-absent 分支同理，Directory.Exists 的
    # GetFileAttributesEx 瞬态假阴性会把 stale quarantined/purging 事务误判
    # 为可恢复，BatchPurge 随之报 recovered-purged 但真实目标树未删。Exists
    # 命中即真，未命中走防御性复核；不在循环内逐事务重判（evidence 事务数
    # 大会叠加 N×400ms），也不在扫描前无条件复核（无匹配事务的纯缺席目标
    # 不必支付该延迟）。
    if ($null -eq $Adjudication.targetPresentAfterRecheck) {
        $Adjudication.targetPresentAfterRecheck = [IO.Directory]::Exists([string]$Adjudication.targetPath) -or
            (Test-CodexSafeTreeDeleteTargetDirPresentAfterRecheck `
                -TargetPath ([string]$Adjudication.targetPath))
    }
    if ($Adjudication.targetPresentAfterRecheck) { return }
    $quarantineExists = [IO.Directory]::Exists([string]$transaction.quarantinePath) -and
        -not [IO.File]::Exists([string]$transaction.quarantinePath)
    if (-not $quarantineExists -and $status -cne 'purging') { return }
    if ($transaction.schemaVersion -isnot [long] -or
        [long]$transaction.schemaVersion -notin @(2L, 3L)) {
        $Adjudication.unsupportedMatches.Add([pscustomobject][ordered]@{
            transactionPath = [string]$Record.transactionPath
            schemaVersion = $transaction.schemaVersion
        })
        return
    }
    $Adjudication.supportedMatches.Add([pscustomobject][ordered]@{
        transactionPath = [string]$Record.transactionPath
        transactionSha256 = [string]$Record.sha256
        quarantinePath = [string]$transaction.quarantinePath
        updatedAtUtc = [string]$transaction.updatedAtUtc
    })
}

function Complete-CodexSafeTreeDeleteRecoverableAdjudication {
    param([Parameter(Mandatory)][object]$Adjudication)

    $supportedMatches = $Adjudication.supportedMatches
    $unsupportedMatches = $Adjudication.unsupportedMatches
    if ($unsupportedMatches.Count -ne 0) {
        $hasSupportedMatch = $supportedMatches.Count -ne 0
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
            supportedTransactionCount = $supportedMatches.Count
            unsupportedTransactionCount = $unsupportedMatches.Count
        }
    }
    if ($supportedMatches.Count -gt 1) { throw 'safe-delete recoverable transaction 不唯一。' }
    if ($supportedMatches.Count -eq 0) { return $null }
    return $supportedMatches[0]
}

function Get-CodexSafeTreeDeleteRecoverableTransactionCandidates {
    param(
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [Parameter(Mandatory)][object]$Metrics
    )

    # BatchPurge 整批一次的历史扫描：产出只在本次调用内存中有效的索引
    # 目标（OrdinalIgnoreCase，不做 Unicode 规范化）→ 候选记录（保持枚举顺序）。
    # 每个文件先过 C# 预筛（#78）：只有它能证明「参考认证链必然成功、且与本批任何目标都
    # 不匹配」的文件被排除；其余文件的认证、status 过滤与 targetPath 比较和逐目标参考查找
    # 逐字相同。被排除的文件不会让参考链抛错，所以首个失败文件与 reference 模式相同；
    # 任何异常都向上抛出，由调用方按「扫描阶段失败」处理整批。
    $candidates = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($targetPath in @($TargetPaths)) {
        $candidates[$targetPath] = [Collections.Generic.List[object]]::new()
    }
    $prefilterTargets = [string[]]@($TargetPaths)
    $fallbackDecision = [CodexSafeTreeDelete.BatchHistoryPrefilterDecision]::Fallback
    $excludedDecision = [CodexSafeTreeDelete.BatchHistoryPrefilterDecision]::Excluded
    $Metrics.scanCount = [long]$Metrics.scanCount + 1L
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($transactionPath in [IO.Directory]::EnumerateFiles($FullEvidenceRoot, 'transaction.json', [IO.SearchOption]::AllDirectories)) {
            $Metrics.enumeratedFiles = [long]$Metrics.enumeratedFiles + 1L
            $decision = [CodexSafeTreeDelete.StatusScanCoordinator]::ClassifyBatchHistoryTransaction(
                $transactionPath,
                $FullEvidenceRoot,
                $prefilterTargets)
            if ($decision -eq $fallbackDecision) {
                $Metrics.fallbackFiles = [long]$Metrics.fallbackFiles + 1L
            } else {
                $Metrics.canonicalFiles = [long]$Metrics.canonicalFiles + 1L
                if ($decision -eq $excludedDecision) {
                    $Metrics.excludedByPrefilter = [long]$Metrics.excludedByPrefilter + 1L
                    continue
                }
            }
            $record = Read-CodexSafeTreeDeleteRecoverableHistoryRecord `
                -TransactionPath $transactionPath `
                -FullEvidenceRoot $FullEvidenceRoot
            $Metrics.fullyAuthenticated = [long]$Metrics.fullyAuthenticated + 1L
            if ($record.status -cnotin @('prepared', 'quarantined', 'purging')) { continue }
            foreach ($targetPath in @($TargetPaths)) {
                if (Test-CodexSafeTreeDeletePathEqual `
                        -Left ([string]$record.document.targetPath) `
                        -Right $targetPath) {
                    $candidates[$targetPath].Add($record)
                    break
                }
            }
        }
    } finally {
        $watch.Stop()
        $Metrics.elapsedMs = [long]$Metrics.elapsedMs + [long]$watch.ElapsedMilliseconds
    }
    return , $candidates
}

function Confirm-CodexSafeTreeDeleteRecoverableTransactionCandidates {
    param(
        [Parameter(Mandatory)][string]$FullEvidenceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Candidates
    )

    # 处理到目标时的候选重新认证：完整参考认证链再走一遍，并要求字节与扫描时相同
    # （SHA-256 一致）。任何异常或 SHA 不一致都向上抛出，由调用方视为「扫描后历史被
    # 外部改动」。
    $confirmed = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $Candidates) {
        $record = Read-CodexSafeTreeDeleteRecoverableHistoryRecord `
            -TransactionPath ([string]$candidate.transactionPath) `
            -FullEvidenceRoot $FullEvidenceRoot
        if ([string]$record.sha256 -cne [string]$candidate.sha256) {
            throw "safe-delete BatchPurge 历史候选内容在扫描后发生变化：$([string]$record.transactionPath)"
        }
        $confirmed.Add($record)
    }
    return , $confirmed
}

function Resolve-CodexSafeTreeDeleteRecoverableTransactionFromCandidates {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Candidates
    )

    # 与逐目标参考查找相同的裁决步骤与时机：目标存在性复查与隔离目录存在性检查都在
    # 处理到本目标时才执行。
    $adjudication = New-CodexSafeTreeDeleteRecoverableAdjudication -TargetPath $TargetPath
    foreach ($record in $Candidates) {
        Add-CodexSafeTreeDeleteRecoverableCandidate -Adjudication $adjudication -Record $record
    }
    return Complete-CodexSafeTreeDeleteRecoverableAdjudication -Adjudication $adjudication
}

function Find-CodexSafeTreeDeleteRecoverableTransaction {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [AllowNull()][object]$HistoryScanMetrics
    )

    # 逐目标参考查找（kill switch 生效时 BatchPurge 的行为）：每次调用完整扫描一遍历史，
    # 匹配记录在枚举过程中就地裁决。
    $policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
    $target = Resolve-CodexSafeTreeDeleteTarget `
        -TargetPath $TargetPath `
        -CapabilityRoot $CapabilityRoot `
        -Policy $policy `
        -RequireExisting:$false
    $fullEvidenceRoot = Initialize-CodexSafeTreeDeleteEvidenceRoot -EvidenceRoot $EvidenceRoot
    $metrics = if ($null -ne $HistoryScanMetrics) {
        $HistoryScanMetrics
    } else {
        New-CodexSafeTreeDeleteHistoryScanMetrics -Mode 'reference'
    }
    $adjudication = New-CodexSafeTreeDeleteRecoverableAdjudication -TargetPath ([string]$target.targetPath)
    $metrics.scanCount = [long]$metrics.scanCount + 1L
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # 只有扫描步骤（枚举、认证、status/targetPath 过滤）的异常记为 historyScan.failure；
    # 匹配记录的裁决异常（例如不唯一）属于目标结果，不记为扫描失败。
    $inScanStep = $true
    try {
        foreach ($transactionPath in [IO.Directory]::EnumerateFiles($fullEvidenceRoot, 'transaction.json', [IO.SearchOption]::AllDirectories)) {
            # reference 模式不做预筛：每个文件都走参考认证链。
            $metrics.enumeratedFiles = [long]$metrics.enumeratedFiles + 1L
            $metrics.fallbackFiles = [long]$metrics.fallbackFiles + 1L
            $record = Read-CodexSafeTreeDeleteRecoverableHistoryRecord `
                -TransactionPath $transactionPath `
                -FullEvidenceRoot $fullEvidenceRoot
            $metrics.fullyAuthenticated = [long]$metrics.fullyAuthenticated + 1L
            if ($record.status -cnotin @('prepared', 'quarantined', 'purging')) { continue }
            if (-not (Test-CodexSafeTreeDeletePathEqual `
                    -Left ([string]$record.document.targetPath) `
                    -Right ([string]$target.targetPath))) { continue }
            $inScanStep = $false
            Add-CodexSafeTreeDeleteRecoverableCandidate -Adjudication $adjudication -Record $record
            $inScanStep = $true
        }
    } catch {
        if ($inScanStep) {
            Set-CodexSafeTreeDeleteHistoryScanFailure `
                -Metrics $metrics `
                -Phase 'scan' `
                -TargetPath ([string]$target.targetPath) `
                -Message ([string]$_.Exception.Message)
        }
        throw
    } finally {
        $watch.Stop()
        $metrics.elapsedMs = [long]$metrics.elapsedMs + [long]$watch.ElapsedMilliseconds
    }
    return Complete-CodexSafeTreeDeleteRecoverableAdjudication -Adjudication $adjudication
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

function Test-CodexSafeTreeDeleteTargetDirListedInParent {
    param(
        [Parameter(Mandatory)][string]$TargetPath
    )

    # 独立于目标路径属性查询的存在性旁证：直接枚举父目录（Windows 上的
    # NtQueryDirectoryFile 通道），命中同名目录项即视为目标可见。
    # 路径计算或枚举的任何异常一律按"未见"处理，不抛出：本函数是旁证通道，
    # 失败不放大，由上层探测循环的 Directory.Exists 重试兜底，全部探测均
    # 未见才允许 already-absent 判定。
    try {
        # 尾部分隔符必须先剪除：GetDirectoryName('D:\a\b\') 会退化返回目标
        # 自身而非其父目录，破坏 parent/leaf 语义（GetFullPath 保留尾部斜杠，
        # 该形态可从调用方真实到达）。
        $trimmedTargetPath = ([string]$TargetPath).TrimEnd('\', '/')
        $parentPath = [IO.Path]::GetDirectoryName($trimmedTargetPath)
        $leafName = [IO.Path]::GetFileName($trimmedTargetPath)
        if ([string]::IsNullOrEmpty($parentPath) -or [string]::IsNullOrEmpty($leafName)) {
            return $false
        }
        if (-not [IO.Directory]::Exists($parentPath)) { return $false }
        foreach ($entry in [IO.DirectoryInfo]::new($parentPath).EnumerateFileSystemInfos()) {
            if ($entry -is [IO.DirectoryInfo] -and
                [string]::Equals($entry.Name, $leafName, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    } catch {
        return $false
    }
}

function Test-CodexSafeTreeDeleteTargetDirPresentAfterRecheck {
    param(
        [Parameter(Mandatory)][string]$TargetPath
    )

    # BatchPurge already-absent 防御性复核（2026-08 批量误判修复）。
    # Directory.Exists 走目标路径元数据查询，杀毒/过滤器驱动瞬时占用可把
    # 物理存在的目录误报为 false，曾导致 BatchPurge 把第一个真实目标静默判为
    # already-absent。复核共 3 次探测、间隔 200ms：立即一次、退避两次，最长
    # 额外等待 400ms/目标，低于本仓库 leaf-delete retry 1000ms 总预算的既有
    # 先例；200ms 足以跨过常见亚百毫秒级过滤器瞬态窗口。代价按缺席目标数
    # 线性叠加（每条 ~400ms，50 条缺席 ≈ 20s 级），存在目标零额外开销；
    # 当前典型批量量级（10 条级）实际影响在秒级以内。每次探测同时用父目录
    # 枚举做旁证（见 Test-CodexSafeTreeDeleteTargetDirListedInParent）。
    foreach ($probeIndex in 0..2) {
        if ($probeIndex -gt 0) { Start-Sleep -Milliseconds 200 }
        if ([IO.Directory]::Exists($TargetPath)) { return $true }
        if (Test-CodexSafeTreeDeleteTargetDirListedInParent -TargetPath $TargetPath) {
            return $true
        }
    }
    return $false
}

function New-CodexSafeTreeDeleteBatchTargetSkippedResult {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Message
    )

    return [pscustomobject][ordered]@{
        targetPath = $TargetPath
        action = 'skipped-target-error'
        reason = 'target-operation-failed'
        error = $Message
        purged = $false
        transactionPath = $null
    }
}

function Invoke-CodexSafeTreeDeleteBatchPurge {
    param(
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        # 只供 fixture 入口注入：fast 模式扫描成功后、处理第一个目标前调用，参数是
        # {targetPaths, candidates[{targetPath, transactionPath}]}。生产入口不传。
        [scriptblock]$AfterBatchHistoryScanForTest
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
    $fullEvidenceRoot = Initialize-CodexSafeTreeDeleteEvidenceRoot -EvidenceRoot $EvidenceRoot

    # 历史查找的两种方式（结果除 historyScan 外逐字段相同）：
    # - fast（默认）：目标去重后、处理第一个目标前整批只扫一次历史，得到只在本次调用内存中
    #   有效的「目标 → 候选记录」索引；处理到某个目标时，先对它的候选做完整参考认证并要求
    #   字节与扫描时相同，再按与参考查找相同的步骤裁决。
    # - reference（CODEX_SAFE_TREE_DELETE_BATCH_HISTORY_SCAN='0'）：逐目标调用
    #   Find-CodexSafeTreeDeleteRecoverableTransaction，每个目标各扫一遍历史（改造前的行为）。
    # 前提：两种方式等价，依赖 safe-delete gate 的独占串行，即批处理期间只有本调用会写
    # evidence。本批自己写入的记录 targetPath 都是本批某个目标，而目标已按 OrdinalIgnoreCase
    # 去重，所以这些记录不会成为其他目标的候选；本批对候选的唯一改动是处理该目标时 Purge
    # 改写它自己的 transaction，此后不再查找该目标。gate 若改成共享锁或允许并发写入
    # evidence，必须先重新论证这个前提，再保留 fast 模式。
    $fastHistoryScan = Test-CodexSafeTreeDeleteBatchHistoryScanEnabled
    $historyScan = New-CodexSafeTreeDeleteHistoryScanMetrics `
        -Mode $(if ($fastHistoryScan) { 'fast' } else { 'reference' })
    $candidateIndex = $null
    $historyScanFailureMessage = $null
    if ($fastHistoryScan) {
        try {
            $candidateIndex = Get-CodexSafeTreeDeleteRecoverableTransactionCandidates `
                -FullEvidenceRoot $fullEvidenceRoot `
                -TargetPaths @($canonicalTargets) `
                -Metrics $historyScan
        } catch {
            # 扫描阶段任何异常（含候选首次认证失败）：本批每个目标都 skipped-target-error。
            $historyScanFailureMessage = [string]$_.Exception.Message
            Set-CodexSafeTreeDeleteHistoryScanFailure `
                -Metrics $historyScan `
                -Phase 'scan' `
                -TargetPath $null `
                -Message $historyScanFailureMessage
        }
        if ($null -eq $historyScanFailureMessage -and $null -ne $AfterBatchHistoryScanForTest) {
            $hookCandidates = [Collections.Generic.List[object]]::new()
            foreach ($targetPath in @($canonicalTargets)) {
                foreach ($candidate in $candidateIndex[$targetPath]) {
                    $hookCandidates.Add([pscustomobject][ordered]@{
                        targetPath = $targetPath
                        transactionPath = [string]$candidate.transactionPath
                    })
                }
            }
            & $AfterBatchHistoryScanForTest ([pscustomobject][ordered]@{
                targetPaths = @($canonicalTargets)
                candidates = @($hookCandidates)
            })
        }
    }

    $results = [Collections.Generic.List[object]]::new()
    $historyInvalidatedMessage = $null
    foreach ($targetPath in @($canonicalTargets)) {
        if ($null -ne $historyScanFailureMessage) {
            $results.Add((New-CodexSafeTreeDeleteBatchTargetSkippedResult `
                -TargetPath $targetPath `
                -Message $historyScanFailureMessage))
            continue
        }
        if ($null -ne $historyInvalidatedMessage) {
            $results.Add((New-CodexSafeTreeDeleteBatchTargetSkippedResult `
                -TargetPath $targetPath `
                -Message $historyInvalidatedMessage))
            continue
        }
        $confirmedCandidates = $null
        if ($fastHistoryScan) {
            try {
                $confirmedCandidates = Confirm-CodexSafeTreeDeleteRecoverableTransactionCandidates `
                    -FullEvidenceRoot $fullEvidenceRoot `
                    -Candidates $candidateIndex[$targetPath]
            } catch {
                # 候选重新认证失败：视为扫描后历史被外部改动，当前目标和剩余目标全部
                # skipped-target-error；已完成目标的结果保持不变。
                $historyInvalidatedMessage =
                    "safe-delete BatchPurge 历史候选重新认证失败，视为扫描后历史被外部改动：$([string]$_.Exception.Message)"
                Set-CodexSafeTreeDeleteHistoryScanFailure `
                    -Metrics $historyScan `
                    -Phase 'reauthentication' `
                    -TargetPath $targetPath `
                    -Message $historyInvalidatedMessage
                $results.Add((New-CodexSafeTreeDeleteBatchTargetSkippedResult `
                    -TargetPath $targetPath `
                    -Message $historyInvalidatedMessage))
                continue
            }
        }
        $recoverable = $null
        $activeTransactionPath = $null
        $activeQuarantinePath = $null
        try {
            if ($fastHistoryScan) {
                $recoverable = Resolve-CodexSafeTreeDeleteRecoverableTransactionFromCandidates `
                    -TargetPath $targetPath `
                    -Candidates $confirmedCandidates
            } else {
                $recoverable = Find-CodexSafeTreeDeleteRecoverableTransaction `
                    -TargetPath $targetPath `
                    -CapabilityRoot $CapabilityRoot `
                    -PolicyPath $PolicyPath `
                    -EvidenceRoot $EvidenceRoot `
                    -HistoryScanMetrics $historyScan
            }
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
            if (-not [IO.Directory]::Exists($targetPath) -and
                -not (Test-CodexSafeTreeDeleteTargetDirPresentAfterRecheck -TargetPath $targetPath)) {
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
        historyScan = $historyScan
    }
}
