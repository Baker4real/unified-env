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
    if ($policy.artifactType -cne 'env-governance.codex-safe-tree-delete-policy' -or [int]$policy.schemaVersion -ne 2) {
        throw 'safe-delete policy artifact/schema 非法。'
    }
    if (@($policy.entries).Count -eq 0) { throw 'safe-delete policy 不得为空。' }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $canonicalEntries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($policy.entries)) {
        Assert-CodexSafeTreeDeleteExactProperties `
            -Value $entry `
            -Names @('id', 'capabilityRoot', 'minimumDescendantDepth', 'rootDeletionPurpose', 'deniedExactPaths') `
            -Scope 'safe-delete policy entry'
        $id = [string]$entry.id
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or -not $ids.Add($id)) {
            throw 'safe-delete policy entry id 非法或重复。'
        }
        $root = Assert-CodexHookDPath -Value ([string]$entry.capabilityRoot) -Name "safe-delete policy $id root"
        if ($root -in @('D:\', 'D:\Codex', 'D:\Codex\.codex', 'D:\Codex\projects')) {
            throw "safe-delete policy $id root 过宽。"
        }
        if (-not $roots.Add($root)) { throw 'safe-delete policy capabilityRoot 重复。' }
        $minimumDepth = [int]$entry.minimumDescendantDepth
        if ($minimumDepth -lt 0 -or $minimumDepth -gt 16) {
            throw "safe-delete policy $id minimumDescendantDepth 非法。"
        }
        $rootDeletionPurpose = [string]$entry.rootDeletionPurpose
        if ($rootDeletionPurpose -notin @('none', 'rebuildable-build-output')) {
            throw "safe-delete policy $id rootDeletionPurpose 非法。"
        }
        if ($minimumDepth -eq 0 -and $rootDeletionPurpose -cne 'rebuildable-build-output') {
            throw "safe-delete policy $id 深度 0 必须显式限定为可重建构建产物。"
        }
        if ($minimumDepth -gt 0 -and $rootDeletionPurpose -cne 'none') {
            throw "safe-delete policy $id 非 root 删除条目的 purpose 必须为 none。"
        }
        if ($rootDeletionPurpose -ceq 'rebuildable-build-output' -and
            $root -notmatch '^D:\\Codex\\projects\\[^\\]+\\.+$') {
            throw "safe-delete policy $id 可重建构建产物必须位于项目根之下。"
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
    $entry = @($Policy.entries | Where-Object { $_.capabilityRoot -ieq $fullRoot })
    if ($entry.Count -ne 1) { throw 'safe-delete capability root 不在受管 allowlist。' }
    if (-not (Test-CodexHookPathWithin -Path $fullTarget -ParentPath $fullRoot)) {
        throw 'safe-delete target 必须位于 capability root 内。'
    }
    $relative = $fullTarget.Substring($fullRoot.Length).TrimStart('\', '/')
    $depth = @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 }).Count
    if ($depth -lt [int]$entry[0].minimumDescendantDepth) {
        throw 'safe-delete target 未达到策略要求的最小后代深度。'
    }
    foreach ($deniedPath in @($entry[0].deniedExactPaths)) {
        if ($fullTarget -ieq $deniedPath -or (Test-CodexHookPathWithin -Path $fullTarget -ParentPath $deniedPath)) {
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
    }
}

function Get-CodexSafeTreeDeleteQuarantineCapabilityRoot {
    param([Parameter(Mandatory)][object]$Target)

    if ([string]$Target.targetPath -ieq [string]$Target.capabilityRoot) {
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
        -Name 'safe-delete plan snapshot'
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
        $fullPlanPath -ieq $fullEvidenceRoot) {
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
        [switch]$FailAfterRenameForTest
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
        -Name 'safe-delete apply preflight'
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
        schemaVersion = 1
        generationId = [string]$plan.generationId
        planPath = $approved.path
        planSha256 = $approved.sha256
        targetPath = $target.targetPath
        quarantinePath = $quarantinePath
        status = 'prepared'
        updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    Set-CodexHookCapabilityJson `
        -Path $transactionPath `
        -Document $transaction `
        -CapabilityRoot $approved.runDirectory `
        -AllowedExactPaths @($transactionPath) `
        -Scope 'safe-delete transaction prepare'

    $mutexHash = Get-CodexHookTextSha256 -Text $target.targetPath.ToUpperInvariant()
    $mutex = [Threading.Mutex]::new($false, "Local\CodexSafeTreeDelete-$mutexHash")
    $held = $false
    $renamed = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'safe-delete target mutex busy。' }
        $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete(
            [string]$target.capabilityRoot,
            [string]$target.targetPath)
        try {
            Assert-CodexHookDirectoryTreeIdentity `
                -Expected @($plan.treeManifest.rootIdentity) `
                -Actual @($guard.VolumeSerialNumber, $guard.FileIndex) `
                -Scope 'safe-delete quarantine root'
            [void]$guard.RenameToSibling($quarantinePath)
            $renamed = $true
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
            -Name 'safe-delete quarantine postcheck'
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
        $fullTransactionPath -ieq $fullEvidenceRoot) {
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
            'targetPath', 'quarantinePath', 'status', 'updatedAtUtc'
        ) `
        -Scope 'safe-delete transaction'
    if ($transaction.artifactType -cne 'env-governance.codex-safe-tree-delete-transaction' -or
        [int]$transaction.schemaVersion -ne 1 -or $transaction.status -cne 'quarantined') {
        throw 'safe-delete transaction 状态或 schema 非法。'
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

    return [pscustomobject][ordered]@{
        path = $fullTransactionPath
        sha256 = [string]$snapshot.sha256
        document = $transaction
        approvedPlan = $approvedPlan
    }
}

function Invoke-CodexSafeTreeDeletePurge {
    param(
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$ApprovedTransactionSha256,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

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
    $currentTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $quarantinePath `
        -CapabilityRoot $quarantineCapabilityRoot `
        -AllowedExactPaths @($quarantinePath) `
        -Name 'safe-delete purge preflight'
    if ((Get-CodexSafeTreeDeleteManifestSha256 -Manifest $currentTree) -cne
        (Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest)) {
        throw 'safe-delete purge preflight tree manifest 漂移。'
    }

    $runDirectory = Split-Path -Parent $approved.path
    $transaction.status = 'purging'
    $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    Set-CodexHookCapabilityJson `
        -Path $approved.path `
        -Document $transaction `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @($approved.path) `
        -Scope 'safe-delete transaction purging'

    $mutexHash = Get-CodexHookTextSha256 -Text $target.targetPath.ToUpperInvariant()
    $mutex = [Threading.Mutex]::new($false, "Local\CodexSafeTreeDelete-$mutexHash")
    $held = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'safe-delete target mutex busy。' }
        Remove-CodexHookCapabilityDirectoryTree `
            -Path $quarantinePath `
            -CapabilityRoot $quarantineCapabilityRoot `
            -AllowedExactPaths @($quarantinePath) `
            -ExpectedRootIdentity @($plan.treeManifest.rootIdentity) `
            -ExpectedTreeManifest $plan.treeManifest `
            -Scope 'safe-delete approved purge'
    } finally {
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    if ([IO.Directory]::Exists($quarantinePath) -or [IO.File]::Exists($quarantinePath)) {
        throw 'safe-delete purge postcheck 目标仍存在。'
    }

    $transaction.status = 'purged'
    $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
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
}
