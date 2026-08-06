Set-StrictMode -Version Latest

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

function Test-CodexSafeTreeDeletePathEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    return [StringComparer]::OrdinalIgnoreCase.Equals($Left, $Right)
}

function Read-CodexSafeTreeDeletePolicy {
    param([Parameter(Mandatory)][string]$PolicyPath)

    $fullPolicyPath = Assert-CodexHookDPath -Value $PolicyPath -Name 'safe-delete policy path'
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot `
        -Path $fullPolicyPath `
        -Name 'safe-delete policy' `
        -AllowedExactPaths @($fullPolicyPath)
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
        [long]$policy.schemaVersion -notin @(3L, 4L)) {
        throw 'safe-delete policy schemaVersion 必须是 JSON integer 3 或 4。'
    }
    $schemaVersion = [long]$policy.schemaVersion
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
            $actualEntryProperties = @($entry.PSObject.Properties.Name)
            if (@($actualEntryProperties | Where-Object { $_ -notin $allowedEntryProperties }).Count -ne 0 -or
                @($baseEntryProperties | Where-Object { $_ -notin $actualEntryProperties }).Count -ne 0) {
                throw 'safe-delete policy entry 属性集合非法。'
            }
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
        if ($schemaVersion -eq 4) {
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
        $denied = [Collections.Generic.List[string]]::new()
        foreach ($candidate in @($entry.deniedExactPaths)) {
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
            deniedExactPaths = @($denied)
        })
    }

    return [pscustomobject][ordered]@{
        path = $fullPolicyPath
        sha256 = [string]$snapshot.sha256
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

function New-CodexSafeTreeDeletePlan {
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
        -Policy $policy
    $tree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $target.targetPath `
        -CapabilityRoot $target.capabilityRoot `
        -AllowedExactPaths @($target.targetPath) `
        -AllowHardLinks:([bool]$target.allowHardLinks) `
        -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
        -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
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

    return [pscustomobject][ordered]@{
        planned = $true
        targetPath = $target.targetPath
        policyEntryId = $target.policyEntryId
        fileCount = $document.summary.fileCount
        directoryCount = $document.summary.directoryCount
        planPath = $planPath
        planSha256 = $planSnapshot.sha256
        expiresAtUtc = $document.expiresAtUtc
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
        [switch]$AllowExpiredPlan
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
    if ($snapshot.sha256 -cne $ApprovedPlanSha256) { throw 'safe-delete approved plan SHA-256 不匹配。' }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $plan = $snapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $plan `
        -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'createdAtUtc', 'expiresAtUtc',
            'policyPath', 'policySha256', 'policyEntryId', 'targetPath', 'capabilityRoot',
            'treeManifest', 'summary'
        ) `
        -Scope 'safe-delete plan'
    if ($plan.artifactType -cne 'env-governance.codex-safe-tree-delete-plan' -or [int]$plan.schemaVersion -ne 1) {
        throw 'safe-delete plan artifact/schema 非法。'
    }
    $generationId = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$plan.generationId, 'D', [ref]$generationId)) {
        throw 'safe-delete plan generationId 非法。'
    }
    $expiresAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParseExact(
        [string]$plan.expiresAtUtc,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$expiresAt) -or (-not $AllowExpiredPlan -and $expiresAt -le [datetimeoffset]::UtcNow)) {
        throw 'safe-delete plan 已过期或时间非法。'
    }

    $policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
    if ($plan.policyPath -cne $policy.path -or $plan.policySha256 -cne $policy.sha256) {
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

    $approved = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath $PlanPath `
        -ApprovedPlanSha256 $ApprovedPlanSha256 `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot
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
    $transaction = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-transaction'
        schemaVersion = 2
        generationId = [string]$plan.generationId
        planPath = $approved.path
        planSha256 = $approved.sha256
        targetPath = $target.targetPath
        quarantinePath = $quarantinePath
        directoryCommitAnchors = @()
        status = 'prepared'
        updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
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
            -Name 'safe-delete quarantine postcheck'
        Assert-CodexSafeTreeDeleteTargetTreePolicy `
            -Target $target `
            -TreeManifest $quarantinedTree `
            -TreePath $quarantinePath
        if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $quarantinedTree) -cne
            (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
            throw 'safe-delete quarantine postcheck tree manifest 漂移。'
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
        return [pscustomobject][ordered]@{
            quarantined = $true
            targetPath = $target.targetPath
            quarantinePath = $quarantinePath
            transactionPath = $transactionPath
            transactionSha256 = $transactionSnapshot.sha256
            recoverable = $true
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

function Read-CodexSafeTreeDeleteApprovedTransaction {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
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
    if ($snapshot.sha256 -cne $ApprovedTransactionSha256) {
        throw 'safe-delete approved transaction SHA-256 不匹配。'
    }
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $transaction = $snapshot.text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-CodexSafeTreeDeleteExactProperties `
        -Value $transaction `
        -Names @(
            'artifactType', 'schemaVersion', 'generationId', 'planPath', 'planSha256',
            'targetPath', 'quarantinePath', 'directoryCommitAnchors', 'status', 'updatedAtUtc'
        ) `
        -Scope 'safe-delete transaction'
    if ($transaction.artifactType -cne 'env-governance.codex-safe-tree-delete-transaction' -or
        [int]$transaction.schemaVersion -ne 2 -or
        [string]$transaction.status -cnotin @('prepared', 'quarantined', 'purging')) {
        throw 'safe-delete transaction 状态或 schema 非法。'
    }
    if ([string]$transaction.status -ceq 'prepared' -and
        @($transaction.directoryCommitAnchors).Count -ne 0) {
        throw 'safe-delete prepared transaction 不得包含 directory commit anchor。'
    }

    $approvedPlan = Read-CodexSafeTreeDeleteApprovedPlan `
        -PlanPath ([string]$transaction.planPath) `
        -ApprovedPlanSha256 ([string]$transaction.planSha256) `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot `
        -AllowMissingTarget `
        -AllowExpiredPlan
    $plan = $approvedPlan.document
    if ($transaction.generationId -cne $plan.generationId -or
        $transaction.targetPath -cne $approvedPlan.target.targetPath) {
        throw 'safe-delete transaction 与 plan 绑定不一致。'
    }
    $expectedQuarantinePath = Join-Path `
        (Split-Path -Parent $approvedPlan.target.targetPath) `
        ('.codex-safe-delete-{0}.quarantine' -f ([string]$plan.generationId))
    if ($transaction.quarantinePath -cne $expectedQuarantinePath) {
        throw 'safe-delete transaction quarantine path 非法。'
    }
    if ([IO.Directory]::Exists($approvedPlan.target.targetPath)) {
        throw 'safe-delete purge 前原目标已重新出现。'
    }
    if ([string]$transaction.status -ceq 'prepared' -and
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

function Get-CodexSafeTreeDeleteAbortOperationKeys {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$GenerationId
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
        [switch]$RequireComplete
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
        -GenerationId ([string]$Plan.generationId)
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
    param([Parameter(Mandatory)][object]$ApprovedTransaction)

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
        -RequireComplete)
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
    return [pscustomobject][ordered]@{
        purged = $true
        targetPath = [string]$transaction.targetPath
        quarantinePath = [string]$transaction.quarantinePath
        transactionPath = $ApprovedTransaction.path
        transactionSha256 = $finalSnapshot.sha256
        recoverable = $false
        recoveredFromCommitJournal = $true
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
        [scriptblock]$DirectoryDeleteCheckpointForTest
    )

    $initialApproved = Read-CodexSafeTreeDeleteApprovedTransaction `
        -TransactionPath $TransactionPath `
        -ApprovedTransactionSha256 $ApprovedTransactionSha256 `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot
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
            -EvidenceRoot $EvidenceRoot
        $transaction = $approved.document
        $plan = $approved.approvedPlan.document
        $target = $approved.approvedPlan.target
        $quarantineCapabilityRoot = Get-CodexSafeTreeDeleteQuarantineCapabilityRoot -Target $target
        $quarantinePath = [string]$transaction.quarantinePath
        if (-not [IO.Directory]::Exists($quarantinePath) -and
            -not [IO.File]::Exists($quarantinePath)) {
            return Complete-CodexSafeTreeDeleteCommittedMissingQuarantine `
                -ApprovedTransaction $approved
        }
        $currentTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
            -Path $quarantinePath `
            -CapabilityRoot $quarantineCapabilityRoot `
            -AllowedExactPaths @($quarantinePath) `
            -AllowHardLinks:([bool]$target.allowHardLinks) `
            -AllowInternalDirectoryJunctions:([bool]$target.allowInternalDirectoryJunctions) `
            -InternalDirectoryJunctionTargetRoot ([string]$target.targetPath) `
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

        $runDirectory = Split-Path -Parent $approved.path
        if ([string]$target.rootDeletionPurpose -ceq 'empty-project-state') {
            [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
                -RunDirectory $runDirectory `
                -Transaction $transaction `
                -Plan $plan)
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
            -Scope 'safe-delete approved purge'
        if ([IO.Directory]::Exists($quarantinePath) -or [IO.File]::Exists($quarantinePath)) {
            throw 'safe-delete purge postcheck 目标仍存在。'
        }
        if ([string]$target.rootDeletionPurpose -ceq 'empty-project-state') {
            [void](Assert-CodexSafeTreeDeleteAnchoredDirectoryJournal `
                -RunDirectory $runDirectory `
                -Transaction $transaction `
                -Plan $plan `
                -RequireComplete)
        }

        $transaction.status = 'purged'
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

        return [pscustomobject][ordered]@{
            purged = $true
            targetPath = $target.targetPath
            quarantinePath = $quarantinePath
            transactionPath = $approved.path
            transactionSha256 = $finalSnapshot.sha256
            recoverable = $false
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
        $matches.Add([pscustomobject][ordered]@{
            transactionPath = $transactionFullPath
            transactionSha256 = $snapshot.sha256
            updatedAtUtc = [string]$transaction.updatedAtUtc
        })
    }
    if ($matches.Count -gt 1) { throw 'safe-delete recoverable transaction 不唯一。' }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Invoke-CodexSafeTreeDeleteBatchPurge {
    param(
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $policy = Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
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

    $results = [Collections.Generic.List[object]]::new()
    foreach ($targetPath in @($canonicalTargets)) {
        $recoverable = Find-CodexSafeTreeDeleteRecoverableTransaction `
            -TargetPath $targetPath `
            -CapabilityRoot $CapabilityRoot `
            -PolicyPath $PolicyPath `
            -EvidenceRoot $EvidenceRoot
        if ($null -ne $recoverable) {
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
    }

    return [pscustomobject][ordered]@{
        completed = $true
        targetCount = $canonicalTargets.Count
        purgedCount = @($results | Where-Object { $_.purged -eq $true }).Count
        recoveredCount = @($results | Where-Object { $_.action -ceq 'recovered-purged' }).Count
        alreadyAbsentCount = @($results | Where-Object { $_.action -ceq 'already-absent' }).Count
        results = @($results)
    }
}
