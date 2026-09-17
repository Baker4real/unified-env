[CmdletBinding()]
param(
    [ValidateSet('All', 'Normal', 'Attack')]
    [string]$Slice = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# GitHub #60 seam + #61 parser + #62 Plan identity binding + #63 Apply + #64 Purge +
# #65 Restore / Status / crash recovery + #66 consumed-grant hardening +
# #72 production revoke:
# retired-evidence-root independent contract, synthetic fixture, purpose parsing,
# exact-root targeting, Plan field contract, Plan-time fail-closed combinations,
# Apply quarantine/transaction with target-directory FileIdentityV2 re-verification,
# Purge freeze/commit journal with quarantine-root directory identity re-verification,
# Restore/Status/crash-replay, consumed leftover grant, old SHA replay, analog revoke,
# content drift, and path alias / junction / symlink / hardlink / ADS fail-closed.
# Independent -Slice Normal|Attack share the same fixture helper. Does not write live production policy.
# Production policy must have zero retired-evidence-root entries after #72.

$projectRoot = Split-Path -Parent $PSScriptRoot
$contractPath = Join-Path $projectRoot 'docs/specs/2026-09-15-safe-tree-delete-retired-evidence-root.md'
$parentSpecPath = Join-Path $projectRoot 'docs/specs/2026-07-24-safe-tree-delete-capability.md'
$libraryPath = Join-Path $projectRoot 'scripts/lib/CodexSafeTreeDelete.ps1'
$productionPolicyPath = Join-Path $projectRoot 'managed/safe-tree-delete/policy.json'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action | Out-Null } catch { return $_.Exception.Message }
    throw $Message
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Haystack,
        [Parameter(Mandatory)][string]$Needle,
        [Parameter(Mandatory)][string]$Message
    )
    Assert-True ($Haystack.Contains($Needle)) $Message
}

function Assert-RetiredEvidenceRootProductionRevoked {
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$MessagePrefix
    )

    $parent = @($Policy.entries | Where-Object { [string]$_.id -ceq 'codex-run-evidence' })
    Assert-True ($parent.Count -eq 1) "$MessagePrefix 生产 policy 必须保留 codex-run-evidence"
    Assert-True (
        [string]$parent[0].capabilityRoot -ceq 'D:\agents\run-evidence' -and
        [int]$parent[0].minimumDescendantDepth -eq 2 -and
        [string]$parent[0].rootDeletionPurpose -ceq 'none'
    ) "$MessagePrefix codex-run-evidence 默认深度仍必须是 2 且 purpose=none"
    Assert-True (
        @($parent[0].deniedExactPaths) -contains 'D:\agents\run-evidence\safe-tree-delete'
    ) "$MessagePrefix 必须继续拒绝 D:\agents\run-evidence\safe-tree-delete"

    $retired = @($Policy.entries | Where-Object {
        [string]$_.rootDeletionPurpose -ceq 'retired-evidence-root'
    })
    Assert-True ($retired.Count -eq 0) "$MessagePrefix 生产 policy 必须零 retired-evidence-root 条目"

    $revokedRoots = @(
        'D:\agents\run-evidence\clock-countdown-ui-spec-20260915',
        'D:\agents\run-evidence\clock-countdown-ui-tickets-20260915'
    )
    foreach ($revokedRoot in $revokedRoots) {
        $match = @($Policy.entries | Where-Object { [string]$_.capabilityRoot -ceq $revokedRoot })
        Assert-True ($match.Count -eq 0) "$MessagePrefix 已撤销路径不得残留登记: $revokedRoot"
        $revokedId = [IO.Path]::GetFileName($revokedRoot)
        $matchById = @($Policy.entries | Where-Object { [string]$_.id -ceq $revokedId })
        Assert-True ($matchById.Count -eq 0) "$MessagePrefix 已撤销 id 不得残留: $revokedId"
    }

    $runEvidencePrefix = 'D:\agents\run-evidence\'
    $runEvidenceChildren = @($Policy.entries | Where-Object {
        ([string]$_.capabilityRoot).StartsWith($runEvidencePrefix, [StringComparison]::OrdinalIgnoreCase)
    })
    Assert-True ($runEvidenceChildren.Count -eq 0) (
        "$MessagePrefix 不得放宽 run-evidence 下的父级或兄弟目录")
}

function Get-IndependentSha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Test-FileId128Equal {
    param(
        [Parameter(Mandatory)][byte[]]$Left,
        [Parameter(Mandatory)][byte[]]$Right
    )
    return [Linq.Enumerable]::SequenceEqual($Left, $Right)
}

function Assert-RetiredEvidenceRootPlanBindings {
    param(
        [Parameter(Mandatory)]$PlanResult,
        [Parameter(Mandatory)][string]$ExpectedTargetPath,
        [Parameter(Mandatory)][string]$ExpectedPolicyPath,
        [Parameter(Mandatory)][string]$ExpectedPolicyEntryId,
        [Parameter(Mandatory)][string]$PayloadRelativePath
    )

    Assert-True ($PlanResult.planned -eq $true) '精确登记的 retired-evidence-root 必须可被识别并生成计划'
    Assert-True ([IO.File]::Exists([string]$PlanResult.planPath)) 'Plan 必须写出可回读 plan.json'
    Assert-True ([string]$PlanResult.planSha256 -cmatch '^[0-9a-f]{64}$') 'CLI 必须返回 plan SHA-256'
    Assert-True ([string]$PlanResult.policyEntryId -ceq $ExpectedPolicyEntryId) (
        '精确登记目标必须绑定对应 grant 条目')
    Assert-True ([string]$PlanResult.targetPath -ceq $ExpectedTargetPath) (
        '运行目标必须精确等于登记的 capability root')
    Assert-True ([IO.Directory]::Exists($ExpectedTargetPath)) 'Plan 不得删除获批目标'

    $planBytes = [IO.File]::ReadAllBytes([string]$PlanResult.planPath)
    $expectedPlanSha = Get-IndependentSha256Hex -Bytes $planBytes
    Assert-True ([string]$PlanResult.planSha256 -ceq $expectedPlanSha) (
        'planSha256 必须等于独立计算的 plan.json SHA-256')

    $planText = [IO.File]::ReadAllText(
        [string]$PlanResult.planPath,
        [Text.UTF8Encoding]::new($false))
    $plan = $planText | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $topLevel = @($plan.PSObject.Properties.Name)
    Assert-True ($plan.artifactType -ceq 'env-governance.codex-safe-tree-delete-plan') (
        'plan artifactType 必须是现役 plan 合同')
    Assert-True ([long]$plan.schemaVersion -eq 1L) 'plan schemaVersion 必须保持现役 1'
    Assert-True ($topLevel -notcontains 'rootDeletionPurpose') 'purpose 不得写入 plan'
    Assert-True ($topLevel -notcontains 'purpose') 'purpose 不得写入 plan'

    $expectedPolicyPath = [IO.Path]::GetFullPath($ExpectedPolicyPath)
    Assert-True ([string]$plan.policyPath -ceq $expectedPolicyPath) (
        'plan.policyPath 必须绑定当时 policy 路径')
    $policyBytes = [IO.File]::ReadAllBytes($expectedPolicyPath)
    $expectedPolicySha = Get-IndependentSha256Hex -Bytes $policyBytes
    Assert-True ([string]$plan.policySha256 -ceq $expectedPolicySha) (
        'plan.policySha256 必须等于独立计算的 policy 文件 SHA-256')
    Assert-True ([string]$plan.policyEntryId -ceq $ExpectedPolicyEntryId) (
        'plan.policyEntryId 必须绑定授权条目')
    Assert-True ([string]$plan.targetPath -ceq $ExpectedTargetPath) (
        'plan.targetPath 必须等于获批 capability root')
    Assert-True ([string]$plan.capabilityRoot -ceq $ExpectedTargetPath) (
        'plan.capabilityRoot 必须等于获批精确根')

    $generationId = [guid]::Empty
    Assert-True ([guid]::TryParseExact([string]$plan.generationId, 'D', [ref]$generationId)) (
        'generationId 必须是可回读的 operation identity')
    $runLeaf = Split-Path -Leaf (Split-Path -Parent ([string]$PlanResult.planPath))
    Assert-True ($runLeaf.Contains([string]$plan.generationId)) (
        'operation run 目录必须锚定 generationId')

    Assert-True ($topLevel -contains 'treeManifest') 'plan 必须包含 treeManifest'
    $rootIdentity = @($plan.treeManifest.rootIdentity)
    Assert-True ($rootIdentity.Count -eq 2) 'treeManifest.rootIdentity 必须是现役二元 identity'
    Assert-True ([string]$rootIdentity[0] -cmatch '^[0-9a-f]{8}$') (
        '目标目录 identity 卷序列号必须是 lower-hex 8')
    Assert-True ([string]$rootIdentity[1] -cmatch '^[0-9a-f]{16}$') (
        '目标目录 identity FileIndex 必须是 lower-hex 16')
    $liveTree = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $ExpectedTargetPath `
        -CapabilityRoot $ExpectedTargetPath `
        -AllowedExactPaths @($ExpectedTargetPath) `
        -Name 'retired-evidence-root plan live tree'
    Assert-True (
        [string]$liveTree.rootIdentity[0] -ceq [string]$rootIdentity[0] -and
        [string]$liveTree.rootIdentity[1] -ceq [string]$rootIdentity[1]
    ) 'plan 目标目录 identity 必须与当场再取的 tree rootIdentity 一致'
    $manifestSha = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest
    Assert-True ($manifestSha -cmatch '^[0-9a-f]{64}$') (
        'treeManifest 必须能独立算出树清单 SHA-256')

    $payloadAbsolute = $ExpectedTargetPath
    foreach ($segment in $PayloadRelativePath.Split('/')) {
        $payloadAbsolute = Join-Path $payloadAbsolute $segment
    }
    Assert-True ([IO.File]::Exists($payloadAbsolute)) "plan 绑定的 payload 必须仍在：$payloadAbsolute"
    $expectedPayloadSha = Get-IndependentSha256Hex -Bytes ([IO.File]::ReadAllBytes($payloadAbsolute))
    $payloadEntry = @($plan.treeManifest.entries | Where-Object {
        [string]$_.kind -ceq 'file' -and [string]$_.relativePath -ceq $PayloadRelativePath
    })
    Assert-True ($payloadEntry.Count -eq 1) "treeManifest 必须包含 $PayloadRelativePath"
    Assert-True ([string]$payloadEntry[0].sha256 -ceq $expectedPayloadSha) (
        "treeManifest SHA-256 必须等于独立计算的文件内容哈希：$PayloadRelativePath")

    Assert-True ($topLevel -contains 'fileIdentitiesV2') 'plan 必须并列写出 fileIdentitiesV2'
    Assert-True ($plan.fileIdentitiesV2 -is [Array]) 'fileIdentitiesV2 必须是 JSON array'
    $identityRecord = @($plan.fileIdentitiesV2 | Where-Object {
        [string]$_.relativePath -ceq $PayloadRelativePath
    })
    Assert-True ($identityRecord.Count -eq 1) "fileIdentitiesV2 必须包含 $PayloadRelativePath"
    $fileId128 = [Convert]::FromBase64String([string]$identityRecord[0].fileId128)
    Assert-True ($fileId128.Length -eq 16) "$PayloadRelativePath fileId128 解码后必须是 16 字节"
    $liveFile = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $payloadAbsolute
    Assert-True (
        (Test-FileId128Equal -Left $fileId128 -Right $liveFile.FileId128)
    ) "$PayloadRelativePath 的 FileIdentityV2 必须与当场再取一致"

    $liveTarget = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $ExpectedTargetPath
    Assert-True ($liveTarget.FileId128.Length -eq 16) (
        '目标目录 FileIdentityV2 必须是 16 字节 FILE_ID_INFO')
    $targetRecord = @($plan.fileIdentitiesV2 | Where-Object {
        [string]$_.relativePath -ceq '.'
    })
    Assert-True ($targetRecord.Count -eq 1) (
        'fileIdentitiesV2 必须用现役记录形状绑定目标目录 relativePath=.')
    $targetFileId128 = [Convert]::FromBase64String([string]$targetRecord[0].fileId128)
    Assert-True ($targetFileId128.Length -eq 16) '目标目录 fileId128 解码后必须是 16 字节'
    Assert-True (
        (Test-FileId128Equal -Left $targetFileId128 -Right $liveTarget.FileId128)
    ) '目标目录 FileIdentityV2 必须与当场再取一致'

    $readBack = @(Read-CodexSafeTreeDeleteFileIdentityV2FromPlan -Plan $plan)
    Assert-True (@($readBack | Where-Object relativePath -ceq $PayloadRelativePath).Count -eq 1) (
        "现役 fileIdentitiesV2 读回仍必须覆盖 $PayloadRelativePath")
    Assert-True (@($readBack | Where-Object relativePath -ceq '.').Count -eq 0) (
        '现役 fileIdentitiesV2 读回仍只返回 file 集合，目标目录身份留在 plan.json')
}

function Assert-RetiredEvidenceRootNeighborsIntact {
    param(
        [Parameter(Mandatory)][string]$UnregisteredPath,
        [Parameter(Mandatory)][string]$ProtectedEvidenceRoot,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [string]$OtherApprovedPath,
        [string]$OtherApprovedPayload,
        [Parameter(Mandatory)][string]$MessagePrefix
    )

    Assert-True ([IO.Directory]::Exists($UnregisteredPath)) (
        "${MessagePrefix}：未登记同级必须仍在")
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $UnregisteredPath 'payload.txt')) -ceq
            'payload-unregistered-sibling'
    ) "${MessagePrefix}：未登记同级 payload 必须不变"
    Assert-True ([IO.Directory]::Exists($ProtectedEvidenceRoot)) (
        "${MessagePrefix}：protected analog 必须仍在")
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $ProtectedEvidenceRoot 'payload.txt')) -ceq
            'payload-safe-tree-delete'
    ) "${MessagePrefix}：protected analog payload 必须不变"
    Assert-True ([IO.Directory]::Exists($CapabilityRoot)) (
        "${MessagePrefix}：analog 父根必须仍在")
    if (-not [string]::IsNullOrWhiteSpace($OtherApprovedPath)) {
        Assert-True ([IO.Directory]::Exists($OtherApprovedPath)) (
            "${MessagePrefix}：另一获批根必须仍在")
        if (-not [string]::IsNullOrWhiteSpace($OtherApprovedPayload)) {
            Assert-True (
                [IO.File]::ReadAllText((Join-Path $OtherApprovedPath 'payload.txt')) -ceq
                    $OtherApprovedPayload
            ) "${MessagePrefix}：另一获批根 payload 必须不变"
        }
    }
}

function Invoke-RetiredEvidenceRootQuarantineDirectoryRecreate {
    param([Parameter(Mandatory)][string]$QuarantinePath)

    $parent = Split-Path -Parent $QuarantinePath
    $temp = Join-Path $parent ('recreate-{0}' -f [guid]::NewGuid().ToString('N'))
    [IO.Directory]::Move($QuarantinePath, $temp)
    [void][IO.Directory]::CreateDirectory($QuarantinePath)
    foreach ($entry in [IO.Directory]::GetFileSystemEntries($temp)) {
        $name = Split-Path -Leaf $entry
        [IO.Directory]::Move($entry, (Join-Path $QuarantinePath $name))
    }
    [IO.Directory]::Delete($temp)
}

function Assert-RetiredEvidenceRootPurgeJournalsReadable {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$TransactionPath
    )

    Assert-True ([IO.Directory]::Exists($RunDirectory)) 'Purge run 目录必须仍在'
    $freezeFiles = @(Get-ChildItem -LiteralPath $RunDirectory -Filter 'directory-delete-*-freeze.json')
    $commitFiles = @(Get-ChildItem -LiteralPath $RunDirectory -Filter 'directory-delete-*-commit.json')
    Assert-True ($freezeFiles.Count -ge 1) 'Purge 必须留下可回读 freeze journal'
    Assert-True ($commitFiles.Count -ge 1) 'Purge 必须留下可回读 commit journal'
    foreach ($commitFile in $commitFiles) {
        $commitDoc = Get-Content -Raw -LiteralPath $commitFile.FullName |
            ConvertFrom-Json -Depth 32 -DateKind String
        Assert-True (
            [string]$commitDoc.artifactType -ceq
                'env-governance.codex-safe-tree-delete-directory-commit-intent'
        ) 'commit journal artifactType 必须可回读'
        Assert-True ([string]$commitDoc.state -ceq 'commit-authorized') (
            'commit journal 状态必须是 commit-authorized')
        $freezePath = [string]$commitDoc.freezeIntentPath
        Assert-True ([IO.File]::Exists($freezePath)) 'commit 引用的 freeze journal 必须仍可回读'
        $freezeBytes = [IO.File]::ReadAllBytes($freezePath)
        $expectedFreezeSha = Get-IndependentSha256Hex -Bytes $freezeBytes
        Assert-True ([string]$commitDoc.freezeIntentSha256 -ceq $expectedFreezeSha) (
            'commit 锚定的 freeze SHA-256 必须等于独立回读')
        $freezeDoc = Get-Content -Raw -LiteralPath $freezePath |
            ConvertFrom-Json -Depth 32 -DateKind String
        Assert-True (
            [string]$freezeDoc.artifactType -ceq
                'env-governance.codex-safe-tree-delete-directory-freeze-intent'
        ) 'freeze journal artifactType 必须可回读'
        Assert-True ([string]$freezeDoc.state -ceq 'freeze-prepared') (
            'freeze journal 状态必须是 freeze-prepared')
    }

    Assert-True ([IO.File]::Exists($TransactionPath)) 'Purge 后 transaction 必须可回读'
    $purgedTransaction = Get-Content -Raw -LiteralPath $TransactionPath |
        ConvertFrom-Json -Depth 32 -DateKind String
    Assert-True ($purgedTransaction.status -ceq 'purged') '成功 Purge 的 transaction 必须是 purged'
    $anchors = @($purgedTransaction.directoryCommitAnchors)
    Assert-True ($anchors.Count -ge 1) 'purged transaction 必须锚定 directory commit'
    $rootAnchors = @($anchors | Where-Object { [string]$_.relativePath -ceq '.' })
    Assert-True ($rootAnchors.Count -eq 1) 'directory commit anchors 必须覆盖计划根目录 .'
}

function Get-RetiredEvidenceRootStatusOperation {
    param(
        [Parameter(Mandatory)]$Status,
        [Parameter(Mandatory)][string]$PlanPath
    )

    $runDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $PlanPath))
    $matches = @($Status.operations | Where-Object {
        [string]$_.runDirectory -ceq $runDirectory
    })
    Assert-True ($matches.Count -eq 1) (
        "Status 必须恰好一条对应 operation：$runDirectory")
    return $matches[0]
}

function New-MutatedRetiredEvidenceRootPlanCopy {
    param(
        [Parameter(Mandatory)][string]$SourcePlanPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][scriptblock]$Mutate
    )

    $runDirectory = Join-Path $EvidenceRoot ('mutated-{0}' -f [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $planPath = Join-Path $runDirectory 'plan.json'
    $plan = [IO.File]::ReadAllText($SourcePlanPath, [Text.UTF8Encoding]::new($false)) |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    & $Mutate $plan
    [IO.File]::WriteAllText(
        $planPath,
        ($plan | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))
    return [pscustomobject][ordered]@{
        planPath = $planPath
        planSha256 = Get-IndependentSha256Hex -Bytes ([IO.File]::ReadAllBytes($planPath))
    }
}

function Write-ScratchPolicy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Entries,
        [long]$SchemaVersion = 4L
    )
    $document = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = $SchemaVersion
        entries = @($Entries)
    }
    [IO.File]::WriteAllText(
        $Path,
        ($document | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
}

function New-RetiredEvidencePolicyEntry {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [long]$MinimumDescendantDepth = 0L,
        [string]$RootDeletionPurpose = 'retired-evidence-root',
        [string[]]$DeniedExactPaths = @(),
        [Nullable[bool]]$AllowHardLinks,
        [Nullable[bool]]$AllowInternalDirectoryJunctions
    )
    $entry = [ordered]@{
        id = $Id
        capabilityRoot = $CapabilityRoot
        minimumDescendantDepth = $MinimumDescendantDepth
        rootDeletionPurpose = $RootDeletionPurpose
        deniedExactPaths = [string[]]$DeniedExactPaths
    }
    if ($null -ne $AllowHardLinks) {
        $entry.allowHardLinks = [bool]$AllowHardLinks
    }
    if ($null -ne $AllowInternalDirectoryJunctions) {
        $entry.allowInternalDirectoryJunctions = [bool]$AllowInternalDirectoryJunctions
    }
    return [pscustomobject]$entry
}

function Get-RetiredEvidenceRootApprovedPath {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$Id
    )
    $match = @($Fixture.approvedTargets | Where-Object { [string]$_.id -ceq $Id })
    Assert-True ($match.Count -eq 1) "fixture 必须包含获批目标 $Id"
    return [IO.Path]::GetFullPath([string]$match[0].path)
}

function Remove-RetiredEvidenceRootScratchTree {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        $Fixture,
        $CreatedReparsePoints
    )

    foreach ($reparsePath in @($CreatedReparsePoints)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reparsePath)) {
            if ([IO.Directory]::Exists([string]$reparsePath)) {
                & $env:ComSpec /d /c ('rmdir "{0}"' -f [string]$reparsePath) | Out-Null
            }
            if ([IO.File]::Exists([string]$reparsePath)) {
                [IO.File]::Delete([string]$reparsePath)
            }
        }
    }
    if ($null -eq $Fixture -or [string]::IsNullOrWhiteSpace([string]$Fixture.scratchRoot)) {
        return
    }
    $cleanupRoot = [IO.Path]::GetFullPath([string]$Fixture.scratchRoot)
    $allowedPrefix = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.scratch')).TrimEnd('\') + '\safe-tree-delete-tests-'
    if ($cleanupRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Directory]::Exists($cleanupRoot)) {
        [IO.Directory]::Delete($cleanupRoot, $true)
    }
}

function Write-RetiredEvidenceRootAnalogPolicyWithoutEntry {
    param(
        [Parameter(Mandatory)][string]$SourcePolicyPath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$RemoveId
    )

    $document = Get-Content -Raw -LiteralPath $SourcePolicyPath |
        ConvertFrom-Json -Depth 32 -DateKind String
    $kept = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($document.entries)) {
        if ([string]$entry.id -cne $RemoveId) {
            $kept.Add($entry)
        }
    }
    $document.entries = $kept.ToArray()
    [IO.File]::WriteAllText(
        $DestinationPath,
        ($document | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
}

function Assert-RetiredEvidenceRootConsumedGrantAndReplay {
    param(
        [Parameter(Mandatory)][string]$FixtureCli,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$GrantPolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][string]$TransactionPath,
        [Parameter(Mandatory)][string]$UnregisteredPath,
        [Parameter(Mandatory)][string]$ProtectedEvidenceRoot,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [string]$ExpectedPayload,
        [switch]$TargetMustExist
    )

    $consumedPlanReject = Assert-Throws -Message '消费后残留 grant 不得批准新 Plan' -Action {
        & $FixtureCli `
            -Mode Plan `
            -TargetPath $TargetPath `
            -CapabilityRoot $TargetPath `
            -FixturePolicyPath $GrantPolicyPath `
            -FixtureEvidenceRoot $EvidenceRoot
    }
    Assert-True ($consumedPlanReject -match '许可已消费') (
        "消费后残留 grant 必须拒绝新 Plan：$consumedPlanReject")
    $replayApplyReject = Assert-Throws -Message '消费后重放旧 Plan SHA 必须拒绝' -Action {
        & $FixtureCli `
            -Mode Apply `
            -PlanPath $PlanPath `
            -ApprovedPlanSha256 $PlanSha256 `
            -ConfirmApply `
            -FixturePolicyPath $GrantPolicyPath `
            -FixtureEvidenceRoot $EvidenceRoot
    }
    Assert-True ($replayApplyReject -match '许可已消费') (
        "消费后重放旧 Plan SHA 必须拒绝：$replayApplyReject")
    $currentTransactionSha = Get-IndependentSha256Hex -Bytes (
        [IO.File]::ReadAllBytes($TransactionPath))
    $replayPurgeReject = Assert-Throws -Message '消费后重放旧 transaction SHA 必须拒绝' -Action {
        & $FixtureCli `
            -Mode Purge `
            -TransactionPath $TransactionPath `
            -ApprovedTransactionSha256 $currentTransactionSha `
            -ConfirmPurge `
            -FixturePolicyPath $GrantPolicyPath `
            -FixtureEvidenceRoot $EvidenceRoot
    }
    Assert-True ($replayPurgeReject -match '可 Purge 状态|许可已消费') (
        "消费后重放旧 transaction SHA 必须拒绝：$replayPurgeReject")
    if ($TargetMustExist) {
        Assert-True ([IO.Directory]::Exists($TargetPath)) '消费后拒绝不得删除重建或 Restore 后的目标'
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPayload)) {
            Assert-True (
                [IO.File]::ReadAllText((Join-Path $TargetPath 'payload.txt')) -ceq $ExpectedPayload
            ) '消费后拒绝不得改写目标 payload'
        }
    }
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $UnregisteredPath `
        -ProtectedEvidenceRoot $ProtectedEvidenceRoot `
        -CapabilityRoot $CapabilityRoot `
        -MessagePrefix '消费后残留 grant / 旧 SHA 重放'
}

function Invoke-RetiredEvidenceRootConsumedRunTamperReject {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$FixtureCli,
        [Parameter(Mandatory)][string]$FixtureHelperPath,
        [Parameter(Mandatory)][ValidateSet(
            'IllegalPlanJson', 'MissingPlan', 'MissingTransaction', 'JunctionRun'
        )][string]$Tamper
    )

    . $FixtureHelperPath
    $fixture = $null
    $createdReparse = [Collections.Generic.List[string]]::new()
    try {
        $fixture = New-CodexSafeTreeDeleteRetiredEvidenceRootFixture -ProjectRoot $ProjectRoot
        $approvedA = Get-RetiredEvidenceRootApprovedPath -Fixture $fixture -Id 'approved-retired-evidence-a'
        $grantPolicyPath = [string]$fixture.grantPolicyPath
        $operationEvidenceRoot = [string]$fixture.operationEvidenceRoot
        $plan = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedA `
            -CapabilityRoot $approvedA `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($plan.planned -eq $true) "tamper 夹具必须先 Plan：$Tamper"
        $apply = & $FixtureCli `
            -Mode Apply `
            -PlanPath ([string]$plan.planPath) `
            -ApprovedPlanSha256 ([string]$plan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($apply.quarantined -eq $true) "tamper 夹具必须先 Apply：$Tamper"
        $purge = & $FixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$apply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$apply.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($purge.purged -eq $true) "tamper 夹具必须先 Purge：$Tamper"
        [void][IO.Directory]::CreateDirectory($approvedA)
        [IO.File]::WriteAllText(
            (Join-Path $approvedA 'payload.txt'),
            "rebuilt-after-$Tamper",
            [Text.UTF8Encoding]::new($false))

        $runDirectory = Split-Path -Parent ([string]$apply.transactionPath)
        $runPlanPath = Join-Path $runDirectory 'plan.json'
        $runTransactionPath = Join-Path $runDirectory 'transaction.json'
        switch ($Tamper) {
            'IllegalPlanJson' {
                [IO.File]::WriteAllText(
                    $runPlanPath,
                    '{"artifactType":',
                    [Text.UTF8Encoding]::new($false))
            }
            'MissingPlan' {
                Assert-True ([IO.File]::Exists($runPlanPath)) '抽掉 plan.json 前必须存在'
                [IO.File]::Delete($runPlanPath)
            }
            'MissingTransaction' {
                Assert-True ([IO.File]::Exists($runTransactionPath)) '抽掉 transaction.json 前必须存在'
                [IO.File]::Delete($runTransactionPath)
            }
            'JunctionRun' {
                $displaced = "$runDirectory-displaced"
                [IO.Directory]::Move($runDirectory, $displaced)
                [void](New-Item -ItemType Junction -Path $runDirectory -Target $displaced)
                $createdReparse.Add($runDirectory)
            }
        }

        $reject = Assert-Throws -Message "消费后 $Tamper 必须使新 Plan 失败闭锁" -Action {
            & $FixtureCli `
                -Mode Plan `
                -TargetPath $approvedA `
                -CapabilityRoot $approvedA `
                -FixturePolicyPath $grantPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($reject -match '无法证明许可未消费') (
            "消费后 $Tamper 必须失败闭锁，不得把残留 grant 当成未消费：$reject")
        Assert-True ([IO.Directory]::Exists($approvedA)) (
            "消费后 $Tamper 失败闭锁不得删除重建目标")
        Assert-True (
            [IO.File]::ReadAllText((Join-Path $approvedA 'payload.txt')) -ceq
                "rebuilt-after-$Tamper"
        ) "消费后 $Tamper 失败闭锁不得改写重建 payload"
    }
    finally {
        Remove-RetiredEvidenceRootScratchTree `
            -ProjectRoot $ProjectRoot `
            -Fixture $fixture `
            -CreatedReparsePoints $createdReparse
    }
}

function Invoke-RetiredEvidenceRootNormalSlice {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$FixtureCli,
        [Parameter(Mandatory)][string]$FixtureHelperPath
    )

    . $FixtureHelperPath
    $fixture = $null
    try {
        $fixture = New-CodexSafeTreeDeleteRetiredEvidenceRootFixture -ProjectRoot $ProjectRoot
        $capabilityRoot = [IO.Path]::GetFullPath([string]$fixture.capabilityRoot)
        $protectedEvidenceRoot = [IO.Path]::GetFullPath([string]$fixture.protectedEvidenceRoot)
        $unregisteredPath = [IO.Path]::GetFullPath([string]$fixture.unregisteredSibling.path)
        $approvedA = Get-RetiredEvidenceRootApprovedPath -Fixture $fixture -Id 'approved-retired-evidence-a'
        $approvedB = Get-RetiredEvidenceRootApprovedPath -Fixture $fixture -Id 'approved-retired-evidence-b'
        $approvedC = Get-RetiredEvidenceRootApprovedPath -Fixture $fixture -Id 'approved-retired-evidence-c'
        $operationEvidenceRoot = [string]$fixture.operationEvidenceRoot
        $grantPolicyPath = [string]$fixture.grantPolicyPath

        $depthReject = Assert-Throws -Message '一级 analog 子目录必须被现役深度规则拒绝' -Action {
            & $FixtureCli `
                -Mode Plan `
                -TargetPath $approvedA `
                -CapabilityRoot $capabilityRoot `
                -FixturePolicyPath ([string]$fixture.parentOnlyPolicyPath) `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($depthReject -match '最小后代深度') (
            "独立 Normal slice 默认拒绝必须返回深度原因：$depthReject")

        $rebuildPlan = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedB `
            -CapabilityRoot $approvedB `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-RetiredEvidenceRootPlanBindings `
            -PlanResult $rebuildPlan `
            -ExpectedTargetPath $approvedB `
            -ExpectedPolicyPath $grantPolicyPath `
            -ExpectedPolicyEntryId 'approved-retired-evidence-b' `
            -PayloadRelativePath 'payload.txt'
        $rebuildPlanDocument = [IO.File]::ReadAllText(
            [string]$rebuildPlan.planPath, [Text.UTF8Encoding]::new($false)) |
            ConvertFrom-Json -Depth 128 -DateKind String
        $rebuildDot = @($rebuildPlanDocument.fileIdentitiesV2 | Where-Object {
            [string]$_.relativePath -ceq '.'
        })[0]
        $rebuildBoundHex = [BitConverter]::ToString(
            [Convert]::FromBase64String([string]$rebuildDot.fileId128))
        Assert-True ($rebuildBoundHex -ceq [string]$fixture.rebuild.rebuiltFileIdHex) (
            '独立 Normal slice 未消费重建必须绑定当前身份')
        $rebuildApply = & $FixtureCli `
            -Mode Apply `
            -PlanPath ([string]$rebuildPlan.planPath) `
            -ApprovedPlanSha256 ([string]$rebuildPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($rebuildApply.quarantined -eq $true) '未消费重建目录必须可 Apply'
        $rebuildRestore = & $FixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$rebuildApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$rebuildApply.transactionSha256) `
            -ConfirmRestore `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($rebuildRestore.restored -eq $true) '独立 Normal slice 必须可 Restore 未消费重建目录'

        $planA = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedA `
            -CapabilityRoot $approvedA `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-RetiredEvidenceRootPlanBindings `
            -PlanResult $planA `
            -ExpectedTargetPath $approvedA `
            -ExpectedPolicyPath $grantPolicyPath `
            -ExpectedPolicyEntryId 'approved-retired-evidence-a' `
            -PayloadRelativePath 'payload.txt'
        $applyA = & $FixtureCli `
            -Mode Apply `
            -PlanPath ([string]$planA.planPath) `
            -ApprovedPlanSha256 ([string]$planA.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($applyA.quarantined -eq $true) '独立 Normal slice 必须可 Apply 获批目标'
        $purgeA = & $FixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$applyA.transactionPath) `
            -ApprovedTransactionSha256 ([string]$applyA.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($purgeA.purged -eq $true) '独立 Normal slice 必须可 Purge'
        Assert-True (-not [IO.Directory]::Exists($approvedA)) 'Purge 后原路径必须不存在'
        Assert-RetiredEvidenceRootNeighborsIntact `
            -UnregisteredPath $unregisteredPath `
            -ProtectedEvidenceRoot $protectedEvidenceRoot `
            -CapabilityRoot $capabilityRoot `
            -OtherApprovedPath $approvedC `
            -OtherApprovedPayload 'payload-approved-retired-evidence-c' `
            -MessagePrefix '独立 Normal slice Purge'

        $planC = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedC `
            -CapabilityRoot $approvedC `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        $applyC = & $FixtureCli `
            -Mode Apply `
            -PlanPath ([string]$planC.planPath) `
            -ApprovedPlanSha256 ([string]$planC.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        $restoreC = & $FixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$applyC.transactionPath) `
            -ApprovedTransactionSha256 ([string]$applyC.transactionSha256) `
            -ConfirmRestore `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($restoreC.restored -eq $true) '独立 Normal slice 必须可 Restore'
        Assert-True (
            [IO.File]::ReadAllText((Join-Path $approvedC 'payload.txt')) -ceq
                'payload-approved-retired-evidence-c'
        ) 'Restore 必须完整恢复 payload'
        Assert-RetiredEvidenceRootNeighborsIntact `
            -UnregisteredPath $unregisteredPath `
            -ProtectedEvidenceRoot $protectedEvidenceRoot `
            -CapabilityRoot $capabilityRoot `
            -MessagePrefix '独立 Normal slice Restore'
    }
    finally {
        Remove-RetiredEvidenceRootScratchTree -ProjectRoot $ProjectRoot -Fixture $fixture
    }

    return [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteRetiredEvidenceRoot'
        slice = 'Normal'
        slices = @(
            'normal-default-reject',
            'normal-unconsumed-rebuild',
            'normal-purge',
            'normal-restore'
        )
    }
}

function Invoke-RetiredEvidenceRootAttackSlice {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$FixtureCli,
        [Parameter(Mandatory)][string]$FixtureHelperPath,
        [Parameter(Mandatory)][string]$ProductionPolicyPath
    )

    . $FixtureHelperPath
    $fixture = $null
    $createdReparse = [Collections.Generic.List[string]]::new()
    try {
        $fixture = New-CodexSafeTreeDeleteRetiredEvidenceRootFixture -ProjectRoot $ProjectRoot
        $capabilityRoot = [IO.Path]::GetFullPath([string]$fixture.capabilityRoot)
        $protectedEvidenceRoot = [IO.Path]::GetFullPath([string]$fixture.protectedEvidenceRoot)
        $unregisteredPath = [IO.Path]::GetFullPath([string]$fixture.unregisteredSibling.path)
        $approvedA = Get-RetiredEvidenceRootApprovedPath -Fixture $fixture -Id 'approved-retired-evidence-a'
        $approvedB = Get-RetiredEvidenceRootApprovedPath -Fixture $fixture -Id 'approved-retired-evidence-b'
        $approvedC = Get-RetiredEvidenceRootApprovedPath -Fixture $fixture -Id 'approved-retired-evidence-c'
        $operationEvidenceRoot = [string]$fixture.operationEvidenceRoot
        $grantPolicyPath = [string]$fixture.grantPolicyPath
        $scratchRoot = [string]$fixture.scratchRoot

        $hardlinkExternal = Join-Path $scratchRoot 'attack-hardlink-external.txt'
        [IO.File]::WriteAllText($hardlinkExternal, 'external-must-survive', [Text.UTF8Encoding]::new($false))
        $hardlinkInside = Join-Path $approvedA 'hardlinked.txt'
        [void](New-Item -ItemType HardLink -Path $hardlinkInside -Target $hardlinkExternal)
        $hardlinkReject = Assert-Throws -Message '未授权 hardlink 必须失败闭锁' -Action {
            & $FixtureCli `
                -Mode Plan `
                -TargetPath $approvedA `
                -CapabilityRoot $approvedA `
                -FixturePolicyPath $grantPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($hardlinkReject -match 'hard link') (
            "hardlink 拒绝必须返回稳定原因：$hardlinkReject")
        Assert-True (
            [IO.File]::ReadAllText($hardlinkExternal) -ceq 'external-must-survive'
        ) 'hardlink 拒绝不得改写外部源文件'
        [IO.File]::Delete($hardlinkInside)

        $symlinkOutside = Join-Path $scratchRoot 'attack-symlink-outside'
        [void][IO.Directory]::CreateDirectory($symlinkOutside)
        [IO.File]::WriteAllText(
            (Join-Path $symlinkOutside 'must-survive.txt'),
            'symlink-outside',
            [Text.UTF8Encoding]::new($false))
        $symlinkInside = Join-Path $approvedA 'symlinked-dir'
        $symlinkCreated = $false
        try {
            [void](New-Item -ItemType SymbolicLink -Path $symlinkInside -Target $symlinkOutside)
            $symlinkCreated = $true
            $createdReparse.Add($symlinkInside)
        } catch {
            $symlinkCreated = $false
        }
        if ($symlinkCreated) {
            $symlinkReject = Assert-Throws -Message '未授权 symlink 必须失败闭锁' -Action {
                & $FixtureCli `
                    -Mode Plan `
                    -TargetPath $approvedA `
                    -CapabilityRoot $approvedA `
                    -FixturePolicyPath $grantPolicyPath `
                    -FixtureEvidenceRoot $operationEvidenceRoot
            }
            Assert-True ($symlinkReject -match 'reparse') (
                "symlink 拒绝必须返回 reparse 原因：$symlinkReject")
            Assert-True (
                [IO.File]::ReadAllText((Join-Path $symlinkOutside 'must-survive.txt')) -ceq
                    'symlink-outside'
            ) 'symlink 拒绝不得触及外部内容'
            & $env:ComSpec /d /c ('rmdir "{0}"' -f $symlinkInside) | Out-Null
            $createdReparse.Remove($symlinkInside) | Out-Null
        } else {
            $junctionInside = Join-Path $approvedA 'junction-alias'
            [void](New-Item -ItemType Junction -Path $junctionInside -Target $symlinkOutside)
            $createdReparse.Add($junctionInside)
            $junctionReject = Assert-Throws -Message '未授权 directory junction 必须失败闭锁' -Action {
                & $FixtureCli `
                    -Mode Plan `
                    -TargetPath $approvedA `
                    -CapabilityRoot $approvedA `
                    -FixturePolicyPath $grantPolicyPath `
                    -FixtureEvidenceRoot $operationEvidenceRoot
            }
            Assert-True ($junctionReject -match 'reparse') (
                "junction 拒绝必须返回 reparse 原因：$junctionReject")
            & $env:ComSpec /d /c ('rmdir "{0}"' -f $junctionInside) | Out-Null
            $createdReparse.Remove($junctionInside) | Out-Null
        }

        $aliasPath = Join-Path $capabilityRoot 'path-alias-junction'
        [void](New-Item -ItemType Junction -Path $aliasPath -Target $approvedA)
        $createdReparse.Add($aliasPath)
        $aliasPolicyPath = Join-Path $scratchRoot 'attack-path-alias-policy.json'
        Write-ScratchPolicy -Path $aliasPolicyPath -Entries @(
            (New-RetiredEvidencePolicyEntry `
                -Id 'path-alias-junction' `
                -CapabilityRoot $aliasPath)
        )
        $aliasReject = Assert-Throws -Message '路径别名 junction 不得作为 capability root' -Action {
            & $FixtureCli `
                -Mode Plan `
                -TargetPath $aliasPath `
                -CapabilityRoot $aliasPath `
                -FixturePolicyPath $aliasPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($aliasReject -match 'reparse') (
            "路径别名 junction 必须失败闭锁：$aliasReject")
        & $env:ComSpec /d /c ('rmdir "{0}"' -f $aliasPath) | Out-Null
        $createdReparse.Remove($aliasPath) | Out-Null

        $adsPayload = Join-Path $approvedA 'payload.txt'
        Set-Content -LiteralPath $adsPayload -Stream 'zone' -Value 'ads' -NoNewline
        $adsReject = Assert-Throws -Message '文件 ADS 必须在 Plan 失败闭锁' -Action {
            & $FixtureCli `
                -Mode Plan `
                -TargetPath $approvedA `
                -CapabilityRoot $approvedA `
                -FixturePolicyPath $grantPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($adsReject -match 'alternate data stream') (
            "独立 Attack slice 文件 ADS 必须拒绝：$adsReject")
        Remove-Item -LiteralPath $adsPayload -Stream 'zone' -Force

        $planA = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedA `
            -CapabilityRoot $approvedA `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-RetiredEvidenceRootPlanBindings `
            -PlanResult $planA `
            -ExpectedTargetPath $approvedA `
            -ExpectedPolicyPath $grantPolicyPath `
            -ExpectedPolicyEntryId 'approved-retired-evidence-a' `
            -PayloadRelativePath 'payload.txt'
        $payloadA = Join-Path $approvedA 'payload.txt'
        $originalPayloadA = [IO.File]::ReadAllText($payloadA)
        $fileIdBefore = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $payloadA
        [IO.File]::WriteAllText($payloadA, 'content-drifted-payload', [Text.UTF8Encoding]::new($false))
        $fileIdAfter = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $payloadA
        Assert-True (
            (Test-FileId128Equal -Left $fileIdBefore.FileId128 -Right $fileIdAfter.FileId128)
        ) '内容漂移夹具必须保持文件 FileIdentityV2'
        $contentDriftApplyReject = Assert-Throws -Message '内容漂移必须拒绝 Apply' -Action {
            & $FixtureCli `
                -Mode Apply `
                -PlanPath ([string]$planA.planPath) `
                -ApprovedPlanSha256 ([string]$planA.planSha256) `
                -ConfirmApply `
                -FixturePolicyPath $grantPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($contentDriftApplyReject -match '漂移|IdentityMismatch|manifest') (
            "内容漂移 Apply 必须失败闭锁：$contentDriftApplyReject")
        Assert-True ([IO.Directory]::Exists($approvedA)) '内容漂移拒绝不得改名目标'
        [IO.File]::WriteAllText($payloadA, $originalPayloadA, [Text.UTF8Encoding]::new($false))
        $planA = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedA `
            -CapabilityRoot $approvedA `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-RetiredEvidenceRootPlanBindings `
            -PlanResult $planA `
            -ExpectedTargetPath $approvedA `
            -ExpectedPolicyPath $grantPolicyPath `
            -ExpectedPolicyEntryId 'approved-retired-evidence-a' `
            -PayloadRelativePath 'payload.txt'

        $driftedPolicyPath = Join-Path $scratchRoot 'attack-grant-policy-sha-drift.json'
        $grantForDrift = Get-Content -Raw -LiteralPath $grantPolicyPath |
            ConvertFrom-Json -Depth 32
        $parentForDrift = @($grantForDrift.entries | Where-Object {
            [string]$_.id -ceq 'fixture-run-evidence-analog'
        })[0]
        $deniedForDrift = [Collections.Generic.List[string]]::new()
        foreach ($deniedPath in @($parentForDrift.deniedExactPaths)) {
            $deniedForDrift.Add([string]$deniedPath)
        }
        $deniedForDrift.Add((Join-Path $capabilityRoot 'attack-sha-drift-placeholder'))
        $parentForDrift.deniedExactPaths = [string[]]$deniedForDrift
        [IO.File]::WriteAllText(
            $driftedPolicyPath,
            ($grantForDrift | ConvertTo-Json -Depth 10),
            [Text.UTF8Encoding]::new($false))
        $policyDriftApplyReject = Assert-Throws -Message 'policy SHA 漂移必须拒绝 Apply' -Action {
            & $FixtureCli `
                -Mode Apply `
                -PlanPath ([string]$planA.planPath) `
                -ApprovedPlanSha256 ([string]$planA.planSha256) `
                -ConfirmApply `
                -FixturePolicyPath $driftedPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($policyDriftApplyReject -match '漂移') (
            "Apply 必须停止在策略 SHA 漂移：$policyDriftApplyReject")

        $applyA = & $FixtureCli `
            -Mode Apply `
            -PlanPath ([string]$planA.planPath) `
            -ApprovedPlanSha256 ([string]$planA.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($applyA.quarantined -eq $true) 'Attack slice 获批目标必须可 Apply'
        $policyDriftPurgeReject = Assert-Throws -Message 'policy SHA 漂移必须拒绝 Purge' -Action {
            & $FixtureCli `
                -Mode Purge `
                -TransactionPath ([string]$applyA.transactionPath) `
                -ApprovedTransactionSha256 ([string]$applyA.transactionSha256) `
                -ConfirmPurge `
                -FixturePolicyPath $driftedPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($policyDriftPurgeReject -match '漂移') (
            "Purge 必须停止在策略 SHA 漂移：$policyDriftPurgeReject")

        $extraLeaf = Join-Path ([string]$applyA.quarantinePath) 'extra-unplanned.txt'
        [IO.File]::WriteAllText($extraLeaf, 'unplanned', [Text.UTF8Encoding]::new($false))
        $extraLeafReject = Assert-Throws -Message 'quarantine extra leaf 必须拒绝 Purge' -Action {
            & $FixtureCli `
                -Mode Purge `
                -TransactionPath ([string]$applyA.transactionPath) `
                -ApprovedTransactionSha256 ([string]$applyA.transactionSha256) `
                -ConfirmPurge `
                -FixturePolicyPath $grantPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($extraLeafReject -match '漂移|manifest|fileIdentitiesV2 缺少|extra-unplanned') (
            "quarantine extra leaf 必须失败闭锁：$extraLeafReject")
        [IO.File]::Delete($extraLeaf)

        $purgeA = & $FixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$applyA.transactionPath) `
            -ApprovedTransactionSha256 ([string]$applyA.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($purgeA.purged -eq $true) 'Attack slice 必须先成功 Purge 才能证明消费后拒绝'
        [void][IO.Directory]::CreateDirectory($approvedA)
        [IO.File]::WriteAllText(
            (Join-Path $approvedA 'payload.txt'),
            'rebuilt-after-purge',
            [Text.UTF8Encoding]::new($false))
        $rebuiltIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $approvedA
        $planADocument = [IO.File]::ReadAllText(
            [string]$planA.planPath, [Text.UTF8Encoding]::new($false)) |
            ConvertFrom-Json -Depth 128 -DateKind String
        $plannedDot = @($planADocument.fileIdentitiesV2 | Where-Object {
            [string]$_.relativePath -ceq '.'
        })[0]
        $plannedFileId = [Convert]::FromBase64String([string]$plannedDot.fileId128)
        Assert-True (
            -not (Test-FileId128Equal -Left $plannedFileId -Right $rebuiltIdentity.FileId128)
        ) 'Purge 后重建目录必须是新 FileId128'
        Assert-RetiredEvidenceRootConsumedGrantAndReplay `
            -FixtureCli $FixtureCli `
            -TargetPath $approvedA `
            -GrantPolicyPath $grantPolicyPath `
            -EvidenceRoot $operationEvidenceRoot `
            -PlanPath ([string]$planA.planPath) `
            -PlanSha256 ([string]$planA.planSha256) `
            -TransactionPath ([string]$applyA.transactionPath) `
            -UnregisteredPath $unregisteredPath `
            -ProtectedEvidenceRoot $protectedEvidenceRoot `
            -CapabilityRoot $capabilityRoot `
            -ExpectedPayload 'rebuilt-after-purge' `
            -TargetMustExist
        $purgedStatus = & $FixtureCli `
            -Mode Status `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        $purgedOperation = Get-RetiredEvidenceRootStatusOperation `
            -Status $purgedStatus `
            -PlanPath ([string]$planA.planPath)
        Assert-True ($purgedOperation.lifecycle -ceq 'manual-review') (
            "purged 后同路径新 identity 的 Status 必须是 manual-review：$($purgedOperation.lifecycle)")

        $revokedPolicyPath = Join-Path $scratchRoot 'attack-grant-policy-revoked-a.json'
        Write-RetiredEvidenceRootAnalogPolicyWithoutEntry `
            -SourcePolicyPath $grantPolicyPath `
            -DestinationPath $revokedPolicyPath `
            -RemoveId 'approved-retired-evidence-a'
        $productionPolicy = Get-Content -LiteralPath $ProductionPolicyPath -Raw |
            ConvertFrom-Json -Depth 32
        Assert-RetiredEvidenceRootProductionRevoked -Policy $productionPolicy -MessagePrefix 'analog 撤销不得改写生产 policy'
        $revokedApplyReject = Assert-Throws -Message 'analog 撤销后重放旧 Plan SHA 必须拒绝' -Action {
            & $FixtureCli `
                -Mode Apply `
                -PlanPath ([string]$planA.planPath) `
                -ApprovedPlanSha256 ([string]$planA.planSha256) `
                -ConfirmApply `
                -FixturePolicyPath $revokedPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($revokedApplyReject -match '漂移|allowlist|许可已消费') (
            "analog 撤销后重放旧 Plan 必须拒绝：$revokedApplyReject")
        $revokedTransactionSha = Get-IndependentSha256Hex -Bytes (
            [IO.File]::ReadAllBytes([string]$applyA.transactionPath))
        $revokedPurgeReject = Assert-Throws -Message 'analog 撤销后重放旧 transaction SHA 必须拒绝' -Action {
            & $FixtureCli `
                -Mode Purge `
                -TransactionPath ([string]$applyA.transactionPath) `
                -ApprovedTransactionSha256 $revokedTransactionSha `
                -ConfirmPurge `
                -FixturePolicyPath $revokedPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($revokedPurgeReject -match '漂移|allowlist|可 Purge 状态|许可已消费') (
            "analog 撤销后重放旧 transaction 必须拒绝：$revokedPurgeReject")
        Assert-True ([IO.Directory]::Exists($approvedA)) '撤销后重放不得删除重建目录'
        Assert-True (
            -not [IO.Path]::GetFullPath($operationEvidenceRoot).StartsWith(
                'D:\agents\run-evidence', [StringComparison]::OrdinalIgnoreCase)
        ) 'Attack slice 不得 live 碰生产 run-evidence'

        $planC = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedC `
            -CapabilityRoot $approvedC `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        $applyC = & $FixtureCli `
            -Mode Apply `
            -PlanPath ([string]$planC.planPath) `
            -ApprovedPlanSha256 ([string]$planC.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        $restoreC = & $FixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$applyC.transactionPath) `
            -ApprovedTransactionSha256 ([string]$applyC.transactionSha256) `
            -ConfirmRestore `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Assert-True ($restoreC.restored -eq $true) 'Attack slice Restore 必须成功以便证明消费后拒绝'
        Assert-RetiredEvidenceRootConsumedGrantAndReplay `
            -FixtureCli $FixtureCli `
            -TargetPath $approvedC `
            -GrantPolicyPath $grantPolicyPath `
            -EvidenceRoot $operationEvidenceRoot `
            -PlanPath ([string]$planC.planPath) `
            -PlanSha256 ([string]$planC.planSha256) `
            -TransactionPath ([string]$applyC.transactionPath) `
            -UnregisteredPath $unregisteredPath `
            -ProtectedEvidenceRoot $protectedEvidenceRoot `
            -CapabilityRoot $capabilityRoot `
            -ExpectedPayload 'payload-approved-retired-evidence-c' `
            -TargetMustExist

        $planB = & $FixtureCli `
            -Mode Plan `
            -TargetPath $approvedB `
            -CapabilityRoot $approvedB `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        $applyB = & $FixtureCli `
            -Mode Apply `
            -PlanPath ([string]$planB.planPath) `
            -ApprovedPlanSha256 ([string]$planB.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $grantPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
        Invoke-RetiredEvidenceRootQuarantineDirectoryRecreate `
            -QuarantinePath ([string]$applyB.quarantinePath)
        $identityPurgeReject = Assert-Throws -Message 'quarantine 目录身份重建必须拒绝 Purge' -Action {
            & $FixtureCli `
                -Mode Purge `
                -TransactionPath ([string]$applyB.transactionPath) `
                -ApprovedTransactionSha256 ([string]$applyB.transactionSha256) `
                -ConfirmPurge `
                -FixturePolicyPath $grantPolicyPath `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($identityPurgeReject -match '目标目录 FileIdentityV2') (
            "quarantine 身份重建必须失败闭锁：$identityPurgeReject")
        Assert-True ([IO.Directory]::Exists([string]$applyB.quarantinePath)) (
            'quarantine 身份漂移拒绝不得删除 quarantine')
    }
    finally {
        Remove-RetiredEvidenceRootScratchTree `
            -ProjectRoot $ProjectRoot `
            -Fixture $fixture `
            -CreatedReparsePoints $createdReparse
    }

    Invoke-RetiredEvidenceRootConsumedRunTamperReject `
        -ProjectRoot $ProjectRoot `
        -FixtureCli $FixtureCli `
        -FixtureHelperPath $FixtureHelperPath `
        -Tamper IllegalPlanJson
    Invoke-RetiredEvidenceRootConsumedRunTamperReject `
        -ProjectRoot $ProjectRoot `
        -FixtureCli $FixtureCli `
        -FixtureHelperPath $FixtureHelperPath `
        -Tamper MissingPlan
    Invoke-RetiredEvidenceRootConsumedRunTamperReject `
        -ProjectRoot $ProjectRoot `
        -FixtureCli $FixtureCli `
        -FixtureHelperPath $FixtureHelperPath `
        -Tamper MissingTransaction
    Invoke-RetiredEvidenceRootConsumedRunTamperReject `
        -ProjectRoot $ProjectRoot `
        -FixtureCli $FixtureCli `
        -FixtureHelperPath $FixtureHelperPath `
        -Tamper JunctionRun

    return [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteRetiredEvidenceRoot'
        slice = 'Attack'
        slices = @(
            'attack-hardlink',
            'attack-symlink-or-junction',
            'attack-path-alias',
            'attack-ads',
            'attack-content-drift',
            'attack-policy-sha-drift',
            'attack-quarantine-extra-leaf',
            'attack-consumed-grant-after-purge',
            'attack-old-sha-replay',
            'attack-analog-revoke-replay',
            'attack-consumed-grant-after-restore',
            'attack-quarantine-identity-rebuild',
            'attack-consumed-run-illegal-plan-json',
            'attack-consumed-run-missing-plan',
            'attack-consumed-run-missing-transaction',
            'attack-consumed-run-junction'
        )
    }
}

Assert-True (Test-Path -LiteralPath $contractPath -PathType Leaf) (
    "retired-evidence-root 独立合同必须存在: $contractPath")
$contract = [IO.File]::ReadAllText($contractPath)

$requiredHeadings = @(
    '## 安全边界',
    '## 状态机',
    '## 失败闭锁',
    '## 精确目标',
    '## 一次性授权',
    '## 身份绑定',
    '## 撤销语义',
    '## Fixture seam'
)
foreach ($heading in $requiredHeadings) {
    Assert-Contains -Haystack $contract -Needle $heading -Message (
        "独立合同缺少必须标题: $heading")
}

Assert-Contains -Haystack $contract -Needle 'retired-evidence-root' -Message (
    '合同必须命名 rootDeletionPurpose=retired-evidence-root')
Assert-Contains -Haystack $contract -Needle '不得把 run-evidence 的默认最小后代深度从 2 改为 1' -Message (
    '合同必须锁定 run-evidence 默认深度仍为 2')
Assert-Contains -Haystack $contract -Needle '只允许精确 capability root' -Message (
    '合同必须要求精确 capability root 删除')
Assert-Contains -Haystack $contract -Needle 'D:\agents\run-evidence' -Message (
    '合同必须以受管 run-evidence 为父边界')
Assert-Contains -Haystack $contract -Needle 'D:\agents\run-evidence\safe-tree-delete' -Message (
    '合同必须保护 safe-tree-delete evidence 根')
Assert-Contains -Haystack $contract -Needle '同名目录重建后不能复用旧授权' -Message (
    '合同必须禁止重建路径复用旧授权')
Assert-Contains -Haystack $contract -Needle '完成或取消本次事务后许可不可继续用于同名重建目录' -Message (
    '合同必须声明一次性消费语义')
Assert-Contains -Haystack $contract -Needle '不改变现有构建产物、空项目状态、退役项目根、Archive 和其他删除用途' -Message (
    '合同必须锁定现有四种用途语义不变')
Assert-Contains -Haystack $contract -Needle '不得把 empty-project-state / retired-project-root 的生产形项目正则套到本用途' -Message (
    '解析规则必须禁止把生产项目正则套到 fixture analog')
Assert-Contains -Haystack $contract -Needle '`policySha256`' -Message (
    '合同必须把策略 SHA 对齐到现役 plan.json 字段 policySha256')
Assert-Contains -Haystack $contract -Needle '`fileIdentitiesV2`' -Message (
    '合同必须把 FileIdentityV2 对齐到现役 plan.json 字段 fileIdentitiesV2')
Assert-Contains -Haystack $contract -Needle '`treeManifest`' -Message (
    '合同必须把树清单对齐到现役 plan.json 字段 treeManifest')
Assert-Contains -Haystack $contract -Needle '`generationId`' -Message (
    '合同必须把 operation identity 对齐到现役 plan.json 字段 generationId')
Assert-Contains -Haystack $contract -Needle '不得把 file-only reader / ApplyFileIdentityMap 当成目标目录复验' -Message (
    '合同必须要求 Apply 独立复验目标目录 FileIdentityV2，而不是套用 file-only reader')
Assert-Contains -Haystack $contract -Needle 'live quarantine 根' -Message (
    '合同必须要求 Purge 用 quarantine 根复验目标目录 FileIdentityV2')
Assert-Contains -Haystack $contract -Needle '成功 Purge 必须先冻结并发布可回读' -Message (
    '合同必须要求 Purge 冻结与 commit journal 可回读')
Assert-Contains -Haystack $contract -Needle '范围不得超出计划' -Message (
    '合同必须锁定 Purge 范围严格等于原始 Plan')
Assert-Contains -Haystack $contract -Needle '不得进入不可审计的半完成态' -Message (
    '合同必须锁定 Apply 中断仍可审计')

$failClosedTriggers = @(
    '未登记同级目标',
    '路径重建',
    'run-evidence 根',
    'safe-tree-delete evidence 根',
    '策略 SHA 漂移',
    'reparse point',
    'named stream',
    'denylist'
)
foreach ($trigger in $failClosedTriggers) {
    Assert-Contains -Haystack $contract -Needle $trigger -Message (
        "失败闭锁必须覆盖: $trigger")
}

Assert-True (Test-Path -LiteralPath $parentSpecPath -PathType Leaf) '现役 capability 合同必须存在'
$parentSpec = [IO.File]::ReadAllText($parentSpecPath)
Assert-Contains -Haystack $parentSpec -Needle 'docs/specs/2026-09-15-safe-tree-delete-retired-evidence-root.md' -Message (
    '现役 capability 合同必须指向 retired-evidence-root 独立合同')
Assert-Contains -Haystack $parentSpec -Needle 'rebuildable-build-output' -Message (
    '现役 capability 合同仍必须声明 rebuildable-build-output')
Assert-Contains -Haystack $parentSpec -Needle 'empty-project-state' -Message (
    '现役 capability 合同仍必须声明 empty-project-state')
Assert-Contains -Haystack $parentSpec -Needle 'retired-project-root' -Message (
    '现役 capability 合同仍必须声明 retired-project-root')
Assert-Contains -Haystack $parentSpec -Needle '项目 `.codex` 根不得冒充构建产物' -Message (
    'rebuildable-build-output 不得冒充项目 .codex 的约束必须保留')
Assert-Contains -Haystack $parentSpec -Needle '整棵树零文件' -Message (
    'empty-project-state 零文件约束必须保留')
Assert-Contains -Haystack $parentSpec -Needle '也不授权其他项目根' -Message (
    'retired-project-root 精确项目根约束必须保留')

$libraryText = [IO.File]::ReadAllText($libraryPath)
Assert-True (
    $libraryText.Contains(
        "-notin @('none', 'rebuildable-build-output', 'empty-project-state', 'retired-project-root', 'retired-evidence-root')")
) 'parser allowlist 必须接受 retired-evidence-root'
Assert-True (
    $libraryText.Contains(
        "-cnotin @('rebuildable-build-output', 'empty-project-state', 'retired-project-root', 'retired-evidence-root')")
) '深度 0 用途集合必须包含 retired-evidence-root'
Assert-True (
    $libraryText.Contains(
        "-cin @('empty-project-state', 'retired-project-root', 'retired-evidence-root')")
) '精确 capability root 检查必须包含 retired-evidence-root'
$statusScanPath = Join-Path $projectRoot 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs'
Assert-True (Test-Path -LiteralPath $statusScanPath -PathType Leaf) 'StatusScan 协作文件必须存在'
$statusScanText = [IO.File]::ReadAllText($statusScanPath)
Assert-True (
    $statusScanText.Contains('entry.RootDeletionPurpose == "retired-evidence-root"')
) 'StatusScan 精确根检查必须包含 retired-evidence-root'
$purgeFnStart = $libraryText.IndexOf('function Invoke-CodexSafeTreeDeletePurge {')
Assert-True ($purgeFnStart -ge 0) 'Purge 实现必须存在'
$purgeFnEnd = $libraryText.IndexOf("`nfunction ", $purgeFnStart + 1)
Assert-True ($purgeFnEnd -gt $purgeFnStart) 'Purge 函数边界必须可切出'
$purgeFnText = $libraryText.Substring($purgeFnStart, $purgeFnEnd - $purgeFnStart)
Assert-True (
    $purgeFnText.Contains('Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity')
) 'Purge 必须独立复验 retired-evidence-root 目标目录 FileIdentityV2，而不是只走 file-only map'
Assert-True ($purgeFnText.Contains('-TreePath $quarantinePath')) (
    'Purge 目录身份 TreePath 必须是 quarantine 根')

$productionPolicy = Get-Content -LiteralPath $productionPolicyPath -Raw | ConvertFrom-Json -Depth 32
Assert-RetiredEvidenceRootProductionRevoked -Policy $productionPolicy -MessagePrefix '#72 生产已撤销'

$scratchHelperPath = Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1'
$fixtureHelperPath = Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteRetiredEvidenceRootFixture.ps1'
Assert-True (Test-Path -LiteralPath $scratchHelperPath -PathType Leaf) 'scratch helper 必须存在'
Assert-True (Test-Path -LiteralPath $fixtureHelperPath -PathType Leaf) (
    'retired-evidence-root fixture helper 必须存在')
. $scratchHelperPath
. $fixtureHelperPath
. (Join-Path $projectRoot 'scripts/lib/CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts/lib/CodexSafeTreeDelete.ps1')

$fixtureCli = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
if ($Slice -ceq 'Normal') {
    return (Invoke-RetiredEvidenceRootNormalSlice `
        -ProjectRoot $projectRoot `
        -FixtureCli $fixtureCli `
        -FixtureHelperPath $fixtureHelperPath)
}
if ($Slice -ceq 'Attack') {
    return (Invoke-RetiredEvidenceRootAttackSlice `
        -ProjectRoot $projectRoot `
        -FixtureCli $fixtureCli `
        -FixtureHelperPath $fixtureHelperPath `
        -ProductionPolicyPath $productionPolicyPath)
}

$productionRunEvidenceRoot = 'D:\agents\run-evidence'
$productionStdEvidenceRoot = Join-Path $productionRunEvidenceRoot 'safe-tree-delete'
$fixture = $null
$createdJunctions = $null
try {
    $fixture = New-CodexSafeTreeDeleteRetiredEvidenceRootFixture -ProjectRoot $projectRoot
    Assert-True ($null -ne $fixture) 'fixture helper 必须返回对象'
    $scratchPrefix = [IO.Path]::GetFullPath((Join-Path $projectRoot '.scratch')).TrimEnd('\') + '\safe-tree-delete-tests-'
    $scratchRoot = [IO.Path]::GetFullPath([string]$fixture.scratchRoot)
    Assert-True ($scratchRoot.StartsWith($scratchPrefix, [StringComparison]::OrdinalIgnoreCase)) (
        "fixture scratch 必须位于 .scratch/safe-tree-delete-tests-* 下: $scratchRoot")
    Assert-True (-not $scratchRoot.StartsWith($productionRunEvidenceRoot, [StringComparison]::OrdinalIgnoreCase)) (
        "fixture 不得写入生产 run-evidence: $scratchRoot")

    $capabilityRoot = [IO.Path]::GetFullPath([string]$fixture.capabilityRoot)
    Assert-True ($capabilityRoot.StartsWith($scratchRoot + '\', [StringComparison]::OrdinalIgnoreCase)) (
        "合成 run-evidence analog 必须位于 scratch 内: $capabilityRoot")
    Assert-True ([IO.Directory]::Exists($capabilityRoot)) '合成 run-evidence analog 必须存在'
    Assert-True ($capabilityRoot -cne $productionRunEvidenceRoot) '合成 analog 不得等于生产 run-evidence 根'

    $protectedEvidenceRoot = [IO.Path]::GetFullPath([string]$fixture.protectedEvidenceRoot)
    Assert-True ($protectedEvidenceRoot.StartsWith($capabilityRoot + '\', [StringComparison]::OrdinalIgnoreCase)) (
        "合成 safe-tree-delete analog 必须是 analog 的一级子目录: $protectedEvidenceRoot")
    Assert-True ([IO.Directory]::Exists($protectedEvidenceRoot)) '合成 safe-tree-delete analog 必须存在'
    Assert-True ($protectedEvidenceRoot -cne $productionStdEvidenceRoot) (
        '合成 analog 不得等于生产 safe-tree-delete evidence 根')

    $approvedTargets = @($fixture.approvedTargets)
    Assert-True ($approvedTargets.Count -ge 2) '获批目标至少要有两个合成目录'
    $grantPolicy = Get-Content -LiteralPath ([string]$fixture.grantPolicyPath) -Raw | ConvertFrom-Json -Depth 32
    $grantPurposeEntries = @($grantPolicy.entries | Where-Object {
        [string]$_.rootDeletionPurpose -ceq 'retired-evidence-root'
    })
    Assert-True ($grantPurposeEntries.Count -eq $approvedTargets.Count) (
        'grant policy 的 retired-evidence-root 条目必须与获批目标一一对应')
    $parentAnalogEntries = @($grantPolicy.entries | Where-Object {
        [string]$_.id -ceq 'fixture-run-evidence-analog'
    })
    Assert-True ($parentAnalogEntries.Count -eq 1) 'grant policy 必须包含合成父条目'
    Assert-True (
        [int]$parentAnalogEntries[0].minimumDescendantDepth -eq 2 -and
        [string]$parentAnalogEntries[0].rootDeletionPurpose -ceq 'none' -and
        [string]$parentAnalogEntries[0].capabilityRoot -ceq $capabilityRoot
    ) '合成父条目必须是深度 2 / none，且不降低 analog 默认深度'
    Assert-True (
        @($parentAnalogEntries[0].deniedExactPaths).Count -eq 1 -and
        [string]$parentAnalogEntries[0].deniedExactPaths[0] -ceq $protectedEvidenceRoot
    ) '合成父条目必须精确拒绝 safe-tree-delete analog'

    foreach ($approved in $approvedTargets) {
        $approvedPath = [IO.Path]::GetFullPath([string]$approved.path)
        $relative = $approvedPath.Substring($capabilityRoot.Length).TrimStart('\', '/')
        $depth = @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 }).Count
        Assert-True ([IO.Directory]::Exists($approvedPath)) "获批目标必须存在: $approvedPath"
        Assert-True ($depth -eq 1) "获批目标必须是 analog 的一级目录: $approvedPath"
        Assert-True ($approvedPath -cne $protectedEvidenceRoot) '获批目标不得是 protected evidence analog'
        $matching = @($grantPurposeEntries | Where-Object {
            [string]$_.capabilityRoot -ceq $approvedPath
        })
        Assert-True ($matching.Count -eq 1) "grant policy 必须精确登记获批目标: $approvedPath"
        Assert-True (
            [int]$matching[0].minimumDescendantDepth -eq 0 -and
            [string]$matching[0].rootDeletionPurpose -ceq 'retired-evidence-root'
        ) "获批目标必须是深度 0 的 retired-evidence-root: $approvedPath"
    }

    $unregisteredPath = [IO.Path]::GetFullPath([string]$fixture.unregisteredSibling.path)
    $unregisteredRelative = $unregisteredPath.Substring($capabilityRoot.Length).TrimStart('\', '/')
    $unregisteredDepth = @($unregisteredRelative -split '[\\/]' | Where-Object { $_.Length -gt 0 }).Count
    Assert-True ([IO.Directory]::Exists($unregisteredPath)) "同级未登记目标必须存在: $unregisteredPath"
    Assert-True ($unregisteredDepth -eq 1) "同级未登记目标必须是 analog 的一级目录: $unregisteredPath"
    Assert-True ($unregisteredPath -cne $protectedEvidenceRoot) '未登记目标不得是 protected evidence analog'
    $approvedPaths = @($approvedTargets | ForEach-Object { [IO.Path]::GetFullPath([string]$_.path) })
    Assert-True ($unregisteredPath -notin $approvedPaths) '未登记目标不得出现在获批清单'
    $unregisteredGrant = @($grantPolicy.entries | Where-Object {
        [string]$_.capabilityRoot -ceq $unregisteredPath
    })
    Assert-True ($unregisteredGrant.Count -eq 0) 'grant policy 不得登记同级未登记目标'

    $hostSafetyPath = Join-Path $projectRoot 'scripts/lib/CodexHostSafety.ps1'
    $libraryPathForIdentity = Join-Path $projectRoot 'scripts/lib/CodexSafeTreeDelete.ps1'
    . $hostSafetyPath
    . $libraryPathForIdentity
    $rebuildPath = [IO.Path]::GetFullPath([string]$fixture.rebuild.path)
    Assert-True ($rebuildPath -in $approvedPaths) '重建路径必须是获批目标之一'
    Assert-True ([IO.Directory]::Exists($rebuildPath)) '重建后同路径必须仍然存在'
    $originalHex = [string]$fixture.rebuild.originalFileIdHex
    $rebuiltHex = [string]$fixture.rebuild.rebuiltFileIdHex
    Assert-True ($originalHex -match '^([0-9A-F]{2}-){15}[0-9A-F]{2}$') (
        "originalFileIdHex 必须是 16 字节 FILE_ID_INFO: $originalHex")
    Assert-True ($rebuiltHex -match '^([0-9A-F]{2}-){15}[0-9A-F]{2}$') (
        "rebuiltFileIdHex 必须是 16 字节 FILE_ID_INFO: $rebuiltHex")
    Assert-True ($originalHex -cne $rebuiltHex) '同名重建后目录身份必须变化'
    $liveIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $rebuildPath
    $liveHex = [BitConverter]::ToString([byte[]]$liveIdentity.FileId128)
    Assert-True ($liveHex -ceq $rebuiltHex) (
        "当前目录身份必须等于重建后身份: live=$liveHex rebuilt=$rebuiltHex")
    Assert-True ($liveHex -cne $originalHex) '当前目录不得仍持有重建前身份'
    $rebuildGrant = @($grantPolicy.entries | Where-Object {
        [string]$_.capabilityRoot -ceq $rebuildPath -and
        [string]$_.rootDeletionPurpose -ceq 'retired-evidence-root'
    })
    Assert-True ($rebuildGrant.Count -eq 1) (
        '重建后 grant policy 仍登记该路径，供后续票证明旧授权不可复用')

    $parentOnlyPolicy = Get-Content -LiteralPath ([string]$fixture.parentOnlyPolicyPath) -Raw |
        ConvertFrom-Json -Depth 32
    $parentOnlyRetired = @($parentOnlyPolicy.entries | Where-Object {
        [string]$_.rootDeletionPurpose -ceq 'retired-evidence-root'
    })
    Assert-True ($parentOnlyRetired.Count -eq 0) (
        'parent-only policy 不得含 retired-evidence-root，以便现役 parser 可加载')
    $parentOnlyAnalog = @($parentOnlyPolicy.entries | Where-Object {
        [string]$_.id -ceq 'fixture-run-evidence-analog'
    })
    Assert-True (
        $parentOnlyAnalog.Count -eq 1 -and
        [int]$parentOnlyAnalog[0].minimumDescendantDepth -eq 2 -and
        [string]$parentOnlyAnalog[0].rootDeletionPurpose -ceq 'none'
    ) 'parent-only policy 必须保留 analog 深度 2 / none'

    $fixtureCli = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
    $operationEvidenceRoot = [string]$fixture.operationEvidenceRoot
    Assert-True ([IO.Directory]::Exists($operationEvidenceRoot)) 'fixture operation evidence 根必须存在'
    Assert-True (
        [IO.Path]::GetFullPath($operationEvidenceRoot).StartsWith($scratchRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    ) 'operation evidence 必须位于 scratch 内'
    Assert-True (
        -not [IO.Path]::GetFullPath($operationEvidenceRoot).StartsWith(
            $productionRunEvidenceRoot, [StringComparison]::OrdinalIgnoreCase)
    ) 'operation evidence 不得写入生产 run-evidence'

    $approvedStablePath = [IO.Path]::GetFullPath([string]$approvedTargets[0].path)
    $approvedRestorePath = [IO.Path]::GetFullPath([string](
        @($approvedTargets | Where-Object { [string]$_.id -ceq 'approved-retired-evidence-c' })[0].path))
    $approvedInterruptPath = [IO.Path]::GetFullPath([string](
        @($approvedTargets | Where-Object { [string]$_.id -ceq 'approved-retired-evidence-d' })[0].path))
    $depthReject = Assert-Throws -Message '一级 analog 子目录必须被现役深度规则拒绝' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $capabilityRoot `
            -FixturePolicyPath ([string]$fixture.parentOnlyPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($depthReject -match '最小后代深度') (
        "一级 evidence 默认拒绝必须返回深度原因: $depthReject")

    $allowlistReject = Assert-Throws -Message '未登记同级目录不得作为独立 capability root' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $unregisteredPath `
            -CapabilityRoot $unregisteredPath `
            -FixturePolicyPath ([string]$fixture.parentOnlyPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($allowlistReject -match 'allowlist') (
        "未登记同级拒绝必须返回 allowlist 原因: $allowlistReject")

    $parsedGrant = Read-CodexSafeTreeDeletePolicy -PolicyPath ([string]$fixture.grantPolicyPath)
    $parsedRetired = @($parsedGrant.entries | Where-Object {
        [string]$_.rootDeletionPurpose -ceq 'retired-evidence-root'
    })
    Assert-True ($parsedRetired.Count -eq $approvedTargets.Count) (
        'parser 必须接受 grant-policy 中的 retired-evidence-root 条目')
    foreach ($parsed in $parsedRetired) {
        Assert-True ([long]$parsed.minimumDescendantDepth -eq 0L) (
            "parser 必须保留 retired-evidence-root 深度 0: $($parsed.id)")
    }

    $approvedPlan = & $fixtureCli `
        -Mode Plan `
        -TargetPath $approvedStablePath `
        -CapabilityRoot $approvedStablePath `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-RetiredEvidenceRootPlanBindings `
        -PlanResult $approvedPlan `
        -ExpectedTargetPath $approvedStablePath `
        -ExpectedPolicyPath ([string]$fixture.grantPolicyPath) `
        -ExpectedPolicyEntryId 'approved-retired-evidence-a' `
        -PayloadRelativePath 'payload.txt'

    $rebuildPlan = & $fixtureCli `
        -Mode Plan `
        -TargetPath $rebuildPath `
        -CapabilityRoot $rebuildPath `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-RetiredEvidenceRootPlanBindings `
        -PlanResult $rebuildPlan `
        -ExpectedTargetPath $rebuildPath `
        -ExpectedPolicyPath ([string]$fixture.grantPolicyPath) `
        -ExpectedPolicyEntryId 'approved-retired-evidence-b' `
        -PayloadRelativePath 'payload.txt'
    $rebuildPlanText = [IO.File]::ReadAllText(
        [string]$rebuildPlan.planPath,
        [Text.UTF8Encoding]::new($false))
    $rebuildPlanDocument = $rebuildPlanText | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $rebuildTargetRecord = @($rebuildPlanDocument.fileIdentitiesV2 | Where-Object {
        [string]$_.relativePath -ceq '.'
    })[0]
    $rebuildBoundHex = [BitConverter]::ToString(
        [Convert]::FromBase64String([string]$rebuildTargetRecord.fileId128))
    Assert-True ($rebuildBoundHex -ceq $rebuiltHex) (
        '未消费 grant 的重建目录 Plan 必须绑定当前身份，而不是重建前身份')
    Assert-True ($rebuildBoundHex -cne $originalHex) (
        '重建目录的 Plan 不得把已替换的旧 FileId128 写成当前身份')

    $missingDotPlan = New-MutatedRetiredEvidenceRootPlanCopy `
        -SourcePlanPath ([string]$approvedPlan.planPath) `
        -EvidenceRoot $operationEvidenceRoot `
        -Mutate {
            param($Plan)
            $kept = [Collections.Generic.List[object]]::new()
            foreach ($record in @($Plan.fileIdentitiesV2)) {
                if ([string]$record.relativePath -cne '.') {
                    $kept.Add($record)
                }
            }
            $Plan.fileIdentitiesV2 = $kept.ToArray()
        }
    $missingDotReject = Assert-Throws -Message '缺目标目录 FileIdentityV2 的 approved Plan 必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Apply `
            -PlanPath ([string]$missingDotPlan.planPath) `
            -ApprovedPlanSha256 ([string]$missingDotPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($missingDotReject -match 'relativePath=\.') (
        "缺 . 的 Apply 必须指向目标目录身份：$missingDotReject")
    Assert-True ([IO.Directory]::Exists($approvedStablePath)) (
        '缺 . 的 Apply 拒绝不得改名获批目标')
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $approvedStablePath 'payload.txt')) -ceq 'payload-approved-retired-evidence-a'
    ) '缺 . 的 Apply 拒绝不得改写 payload'

    $tamperedDotPlan = New-MutatedRetiredEvidenceRootPlanCopy `
        -SourcePlanPath ([string]$approvedPlan.planPath) `
        -EvidenceRoot $operationEvidenceRoot `
        -Mutate {
            param($Plan)
            $dotRecord = @($Plan.fileIdentitiesV2 | Where-Object {
                [string]$_.relativePath -ceq '.'
            })[0]
            $fileId128 = [Convert]::FromBase64String([string]$dotRecord.fileId128)
            $fileId128[8] = $fileId128[8] -bxor 1
            $dotRecord.fileId128 = [Convert]::ToBase64String($fileId128)
        }
    $tamperedDotReject = Assert-Throws -Message '目标目录 FileIdentityV2 漂移必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Apply `
            -PlanPath ([string]$tamperedDotPlan.planPath) `
            -ApprovedPlanSha256 ([string]$tamperedDotPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($tamperedDotReject -match '目标目录 FileIdentityV2') (
        "篡改 . 的 Apply 必须复验目录身份而不是只走 file map：$tamperedDotReject")
    Assert-True ([IO.Directory]::Exists($approvedStablePath)) (
        '目录身份漂移拒绝不得改名获批目标')
    Assert-True ([IO.Directory]::Exists($unregisteredPath)) (
        '目录身份漂移拒绝不得触及未登记同级')
    Assert-True ([IO.Directory]::Exists($protectedEvidenceRoot)) (
        '目录身份漂移拒绝不得触及 protected analog')

    $rebuildPayloadPath = Join-Path $rebuildPath 'payload.txt'
    Set-Content -LiteralPath $rebuildPayloadPath -Stream 'zone' -Value 'ads' -NoNewline
    $namedStreamReject = Assert-Throws -Message '获批根内文件 named stream 必须在 Plan 失败闭锁' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $rebuildPath `
            -CapabilityRoot $rebuildPath `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($namedStreamReject -match 'alternate data stream') (
        "named stream 拒绝必须返回稳定原因: $namedStreamReject")
    Assert-True (
        (Get-Content -LiteralPath $rebuildPayloadPath -Stream 'zone' -Raw) -ceq 'ads'
    ) 'named stream 拒绝不得删除或改写 ADS'
    Remove-Item -LiteralPath $rebuildPayloadPath -Stream 'zone' -Force

    $unregisteredGrantReject = Assert-Throws -Message '邻居获批不得放行未登记同级目录' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $unregisteredPath `
            -CapabilityRoot $unregisteredPath `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($unregisteredGrantReject -match 'allowlist') (
        "grant-policy 下未登记同级仍必须 allowlist 拒绝: $unregisteredGrantReject")

    $approvedChild = Join-Path $approvedStablePath 'nested-child'
    [void][IO.Directory]::CreateDirectory($approvedChild)
    [IO.File]::WriteAllText(
        (Join-Path $approvedChild 'child.txt'),
        'child',
        [Text.UTF8Encoding]::new($false))
    $descendantReject = Assert-Throws -Message '获批根的后代不得作为独立目标' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedChild `
            -CapabilityRoot $approvedStablePath `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($descendantReject -match '精确.*root') (
        "后代目标拒绝必须返回精确 root 原因: $descendantReject")

    $outsideBoundaryReject = Assert-Throws -Message '目标必须位于登记的 capability root 内' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $unregisteredPath `
            -CapabilityRoot $approvedStablePath `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($outsideBoundaryReject -match 'capability root 内') (
        "路径边界拒绝必须返回稳定原因: $outsideBoundaryReject")

    $deniedNested = Join-Path $protectedEvidenceRoot 'nested-run'
    [void][IO.Directory]::CreateDirectory($deniedNested)
    [IO.File]::WriteAllText(
        (Join-Path $deniedNested 'payload.txt'),
        'denied',
        [Text.UTF8Encoding]::new($false))
    $denylistReject = Assert-Throws -Message '父 denylist 必须继续拒绝 safe-tree-delete analog 子树' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $deniedNested `
            -CapabilityRoot $capabilityRoot `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($denylistReject -match 'denylist') (
        "denylist 拒绝必须返回稳定原因: $denylistReject")

    $illegalDepthPath = Join-Path $scratchRoot 'illegal-depth-policy.json'
    Write-ScratchPolicy -Path $illegalDepthPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-depth' `
            -CapabilityRoot $approvedStablePath `
            -MinimumDescendantDepth 2L)
    )
    $illegalDepth = Assert-Throws -Message '深度不为 0 时不得声明 retired-evidence-root' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $approvedStablePath `
            -FixturePolicyPath $illegalDepthPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalDepth -match 'purpose 必须为 none') (
        "非法深度组合必须失败闭锁: $illegalDepth")

    $illegalAnalogRootPath = Join-Path $scratchRoot 'illegal-analog-root-policy.json'
    Write-ScratchPolicy -Path $illegalAnalogRootPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-analog-root' `
            -CapabilityRoot $capabilityRoot)
    )
    $illegalAnalogRoot = Assert-Throws -Message 'analog 根不得登记为 retired-evidence-root' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $capabilityRoot `
            -FixturePolicyPath $illegalAnalogRootPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalAnalogRoot -match '明确一级目录') (
        "analog 根登记必须失败闭锁: $illegalAnalogRoot")

    $illegalProtectedPath = Join-Path $scratchRoot 'illegal-protected-policy.json'
    Write-ScratchPolicy -Path $illegalProtectedPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-protected-evidence' `
            -CapabilityRoot $protectedEvidenceRoot)
    )
    $illegalProtected = Assert-Throws -Message 'safe-tree-delete analog 不得登记为本用途' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $protectedEvidenceRoot `
            -CapabilityRoot $protectedEvidenceRoot `
            -FixturePolicyPath $illegalProtectedPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalProtected -match 'safe-tree-delete evidence 根') (
        "protected analog 登记必须失败闭锁: $illegalProtected")

    $productionRootPolicyPath = Join-Path $scratchRoot 'illegal-production-root-policy.json'
    Write-ScratchPolicy -Path $productionRootPolicyPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-production-run-evidence-root' `
            -CapabilityRoot $productionRunEvidenceRoot)
    )
    $illegalProductionRoot = Assert-Throws -Message '生产 run-evidence 根不得登记为本用途' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $productionRunEvidenceRoot `
            -FixturePolicyPath $productionRootPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalProductionRoot -match '明确一级目录') (
        "生产 run-evidence 根登记必须失败闭锁: $illegalProductionRoot")

    $productionStdPolicyPath = Join-Path $scratchRoot 'illegal-production-std-policy.json'
    Write-ScratchPolicy -Path $productionStdPolicyPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-production-std-evidence' `
            -CapabilityRoot $productionStdEvidenceRoot)
    )
    $illegalProductionStd = Assert-Throws -Message '生产 safe-tree-delete evidence 根不得登记为本用途' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $productionStdEvidenceRoot `
            -FixturePolicyPath $productionStdPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalProductionStd -match 'safe-tree-delete evidence 根') (
        "生产 std evidence 根登记必须失败闭锁: $illegalProductionStd")

    $descendantRoot = Join-Path $approvedStablePath 'nested-capability'
    [void][IO.Directory]::CreateDirectory($descendantRoot)
    $illegalDescendantRegPath = Join-Path $scratchRoot 'illegal-descendant-policy.json'
    Write-ScratchPolicy -Path $illegalDescendantRegPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-descendant-registration' `
            -CapabilityRoot $descendantRoot)
    )
    $illegalDescendantReg = Assert-Throws -Message '获批根的后代不得登记为本用途' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $descendantRoot `
            -CapabilityRoot $descendantRoot `
            -FixturePolicyPath $illegalDescendantRegPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalDescendantReg -match '明确一级目录') (
        "后代登记必须失败闭锁: $illegalDescendantReg")

    $projectRootPolicyPath = Join-Path $scratchRoot 'illegal-project-root-policy.json'
    Write-ScratchPolicy -Path $projectRootPolicyPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-project-root' `
            -CapabilityRoot $projectRoot)
    )
    $illegalProjectRoot = Assert-Throws -Message '项目根不得登记为 retired-evidence-root' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $projectRoot `
            -FixturePolicyPath $projectRootPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalProjectRoot -match '明确一级目录') (
        "项目根登记必须失败闭锁: $illegalProjectRoot")

    $widePathPolicyPath = Join-Path $scratchRoot 'illegal-wide-path-policy.json'
    Write-ScratchPolicy -Path $widePathPolicyPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-wide-path' `
            -CapabilityRoot 'D:\agents')
    )
    $illegalWidePath = Assert-Throws -Message '宽路径不得登记为 retired-evidence-root' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot 'D:\agents' `
            -FixturePolicyPath $widePathPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalWidePath -match '过宽') (
        "宽路径登记必须失败闭锁: $illegalWidePath")

    $linkAwarePolicyPath = Join-Path $scratchRoot 'illegal-link-aware-policy.json'
    Write-ScratchPolicy -Path $linkAwarePolicyPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-link-aware' `
            -CapabilityRoot $approvedStablePath `
            -AllowHardLinks $true `
            -AllowInternalDirectoryJunctions $true)
    )
    $illegalLinkAware = Assert-Throws -Message 'retired-evidence-root 不得启用 link-aware 标志' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $approvedStablePath `
            -FixturePolicyPath $linkAwarePolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($illegalLinkAware -match 'link-aware 能力只允许深度 0 的可重建构建产物根') (
        "link-aware 组合必须失败闭锁: $illegalLinkAware")

    $createdJunctions = [Collections.Generic.List[string]]::new()
    $reparseOutside = Join-Path $scratchRoot 'reparse-outside'
    [void][IO.Directory]::CreateDirectory($reparseOutside)
    [IO.File]::WriteAllText(
        (Join-Path $reparseOutside 'must-survive.txt'),
        'outside',
        [Text.UTF8Encoding]::new($false))
    $reparseLink = Join-Path $approvedStablePath 'linked'
    [void](New-Item -ItemType Junction -Path $reparseLink -Target $reparseOutside)
    $createdJunctions.Add($reparseLink)
    $reparseReject = Assert-Throws -Message '获批根内未授权 reparse 必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $approvedStablePath `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($reparseReject -match 'reparse') (
        "reparse 拒绝必须返回稳定原因: $reparseReject")
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $reparseOutside 'must-survive.txt')) -ceq 'outside'
    ) 'reparse 拒绝不得触及外部内容'

    $ancestorCase = Join-Path $scratchRoot 'ancestor-reparse-case'
    $realAncestorParent = Join-Path $ancestorCase 'real-parent'
    $realAncestorApproved = Join-Path $realAncestorParent 'approved-retired-evidence-j'
    [void][IO.Directory]::CreateDirectory($realAncestorApproved)
    [IO.File]::WriteAllText(
        (Join-Path $realAncestorApproved 'payload.txt'),
        'ancestor',
        [Text.UTF8Encoding]::new($false))
    $junctionAnalog = Join-Path $ancestorCase 'run-evidence-analog'
    [void](New-Item -ItemType Junction -Path $junctionAnalog -Target $realAncestorParent)
    $createdJunctions.Add($junctionAnalog)
    $junctionApproved = Join-Path $junctionAnalog 'approved-retired-evidence-j'
    $ancestorPolicyPath = Join-Path $scratchRoot 'illegal-ancestor-reparse-policy.json'
    Write-ScratchPolicy -Path $ancestorPolicyPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'illegal-ancestor-reparse' `
            -CapabilityRoot $junctionApproved)
    )
    $ancestorReparseReject = Assert-Throws -Message '祖先 reparse 必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $junctionApproved `
            -CapabilityRoot $junctionApproved `
            -FixturePolicyPath $ancestorPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($ancestorReparseReject -match 'reparse') (
        "祖先保护拒绝必须返回 reparse 原因: $ancestorReparseReject")

    foreach ($junctionPath in @($createdJunctions)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$junctionPath) -and
            [IO.Directory]::Exists($junctionPath)) {
            & $env:ComSpec /d /c "rmdir `"$junctionPath`"" | Out-Null
        }
    }
    $createdJunctions.Clear()
    foreach ($extraPath in @(
            (Join-Path $approvedStablePath 'nested-child'),
            (Join-Path $approvedStablePath 'nested-capability'),
            (Join-Path $approvedStablePath 'linked')
        )) {
        if ([IO.Directory]::Exists($extraPath)) {
            [IO.Directory]::Delete($extraPath, $true)
        }
    }

    $hardlinkExternal = Join-Path $scratchRoot 'all-hardlink-external.txt'
    [IO.File]::WriteAllText($hardlinkExternal, 'external-must-survive', [Text.UTF8Encoding]::new($false))
    $hardlinkInside = Join-Path $approvedStablePath 'hardlinked.txt'
    [void](New-Item -ItemType HardLink -Path $hardlinkInside -Target $hardlinkExternal)
    $hardlinkReject = Assert-Throws -Message '未授权 hardlink 必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $approvedStablePath `
            -CapabilityRoot $approvedStablePath `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($hardlinkReject -match 'hard link') (
        "hardlink 拒绝必须返回稳定原因：$hardlinkReject")
    Assert-True (
        [IO.File]::ReadAllText($hardlinkExternal) -ceq 'external-must-survive'
    ) 'hardlink 拒绝不得改写外部源文件'
    [IO.File]::Delete($hardlinkInside)

    $aliasPath = Join-Path $capabilityRoot 'path-alias-junction'
    [void](New-Item -ItemType Junction -Path $aliasPath -Target $approvedStablePath)
    $createdJunctions.Add($aliasPath)
    $aliasPolicyPath = Join-Path $scratchRoot 'all-path-alias-policy.json'
    Write-ScratchPolicy -Path $aliasPolicyPath -Entries @(
        (New-RetiredEvidencePolicyEntry `
            -Id 'path-alias-junction' `
            -CapabilityRoot $aliasPath)
    )
    $aliasReject = Assert-Throws -Message '路径别名 junction 不得作为 capability root' -Action {
        & $fixtureCli `
            -Mode Plan `
            -TargetPath $aliasPath `
            -CapabilityRoot $aliasPath `
            -FixturePolicyPath $aliasPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($aliasReject -match 'reparse') (
        "路径别名 junction 必须失败闭锁：$aliasReject")
    & $env:ComSpec /d /c "rmdir `"$aliasPath`"" | Out-Null
    $createdJunctions.Remove($aliasPath) | Out-Null

    $symlinkOutside = Join-Path $scratchRoot 'all-symlink-outside'
    [void][IO.Directory]::CreateDirectory($symlinkOutside)
    [IO.File]::WriteAllText(
        (Join-Path $symlinkOutside 'must-survive.txt'),
        'symlink-outside',
        [Text.UTF8Encoding]::new($false))
    $symlinkInside = Join-Path $approvedStablePath 'symlinked-dir'
    $symlinkCreated = $false
    try {
        [void](New-Item -ItemType SymbolicLink -Path $symlinkInside -Target $symlinkOutside)
        $symlinkCreated = $true
        $createdJunctions.Add($symlinkInside)
    } catch {
        $symlinkCreated = $false
    }
    if ($symlinkCreated) {
        $symlinkReject = Assert-Throws -Message '未授权 symlink 必须失败闭锁' -Action {
            & $fixtureCli `
                -Mode Plan `
                -TargetPath $approvedStablePath `
                -CapabilityRoot $approvedStablePath `
                -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
                -FixtureEvidenceRoot $operationEvidenceRoot
        }
        Assert-True ($symlinkReject -match 'reparse') (
            "symlink 拒绝必须返回 reparse 原因：$symlinkReject")
        Assert-True (
            [IO.File]::ReadAllText((Join-Path $symlinkOutside 'must-survive.txt')) -ceq
                'symlink-outside'
        ) 'symlink 拒绝不得触及外部内容'
        & $env:ComSpec /d /c "rmdir `"$symlinkInside`"" | Out-Null
        $createdJunctions.Remove($symlinkInside) | Out-Null
    }

    $applyPlan = & $fixtureCli `
        -Mode Plan `
        -TargetPath $approvedStablePath `
        -CapabilityRoot $approvedStablePath `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-RetiredEvidenceRootPlanBindings `
        -PlanResult $applyPlan `
        -ExpectedTargetPath $approvedStablePath `
        -ExpectedPolicyPath ([string]$fixture.grantPolicyPath) `
        -ExpectedPolicyEntryId 'approved-retired-evidence-a' `
        -PayloadRelativePath 'payload.txt'

    $payloadForContentDrift = Join-Path $approvedStablePath 'payload.txt'
    $originalPayloadForContentDrift = [IO.File]::ReadAllText($payloadForContentDrift)
    $contentDriftFileIdBefore = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $payloadForContentDrift
    [IO.File]::WriteAllText(
        $payloadForContentDrift,
        'content-drifted-payload',
        [Text.UTF8Encoding]::new($false))
    $contentDriftFileIdAfter = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $payloadForContentDrift
    Assert-True (
        (Test-FileId128Equal -Left $contentDriftFileIdBefore.FileId128 -Right $contentDriftFileIdAfter.FileId128)
    ) '内容漂移夹具必须保持文件 FileIdentityV2'
    $contentDriftApplyReject = Assert-Throws -Message '内容漂移必须拒绝 Apply' -Action {
        & $fixtureCli `
            -Mode Apply `
            -PlanPath ([string]$applyPlan.planPath) `
            -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($contentDriftApplyReject -match '漂移|IdentityMismatch|manifest') (
        "内容漂移 Apply 必须失败闭锁：$contentDriftApplyReject")
    Assert-True ([IO.Directory]::Exists($approvedStablePath)) '内容漂移拒绝不得改名目标'
    [IO.File]::WriteAllText(
        $payloadForContentDrift,
        $originalPayloadForContentDrift,
        [Text.UTF8Encoding]::new($false))
    $applyPlan = & $fixtureCli `
        -Mode Plan `
        -TargetPath $approvedStablePath `
        -CapabilityRoot $approvedStablePath `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-RetiredEvidenceRootPlanBindings `
        -PlanResult $applyPlan `
        -ExpectedTargetPath $approvedStablePath `
        -ExpectedPolicyPath ([string]$fixture.grantPolicyPath) `
        -ExpectedPolicyEntryId 'approved-retired-evidence-a' `
        -PayloadRelativePath 'payload.txt'

    $plannedStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $plannedOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $plannedStatus `
        -PlanPath ([string]$applyPlan.planPath)
    Assert-True ($plannedOperation.lifecycle -ceq 'planned') (
        "有效 Plan 的 Status 必须是 planned：$($plannedOperation.lifecycle)")
    Assert-True ((@($plannedOperation.safeActions) -join ',') -ceq 'apply') (
        'planned 操作的 safeActions 必须是 apply')

    $unconfirmedApply = & $fixtureCli `
        -Mode Apply `
        -PlanPath ([string]$applyPlan.planPath) `
        -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($unconfirmedApply.quarantined -ne $true) '未确认 Apply 不得隔离'
    Assert-True ($unconfirmedApply.refusalReason -ceq 'confirm-apply-required') (
        'Apply 缺少确认必须结构化拒绝')
    Assert-True ([IO.Directory]::Exists($approvedStablePath)) '未确认 Apply 不得修改获批目标'

    $wrongHashError = Assert-Throws -Message '错误计划哈希必须失败关闭' -Action {
        & $fixtureCli `
            -Mode Apply `
            -PlanPath ([string]$applyPlan.planPath) `
            -ApprovedPlanSha256 ('0' * 64) `
            -ConfirmApply `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($wrongHashError -match 'SHA-256') (
        "错误哈希拒绝必须返回稳定原因: $wrongHashError")
    Assert-True ([IO.Directory]::Exists($approvedStablePath)) '错误计划哈希不得修改获批目标'

    $applyPlanDocument = [IO.File]::ReadAllText(
        [string]$applyPlan.planPath,
        [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 128 -DateKind String
    $rollbackQuarantinePath = Join-Path `
        $capabilityRoot `
        ('.codex-safe-delete-{0}.quarantine' -f ([string]$applyPlanDocument.generationId))
    $rollbackError = Assert-Throws -Message 'Apply 改名后故障必须回滚且可审计' -Action {
        & $fixtureCli `
            -Mode Apply `
            -PlanPath ([string]$applyPlan.planPath) `
            -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
            -ConfirmApply `
            -FixtureFailAfterRename `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($rollbackError -match 'fixture failure after rename') (
        "Apply 中断必须返回原始失败: $rollbackError")
    Assert-True ([IO.Directory]::Exists($approvedStablePath)) 'Apply rollback 必须恢复原目录'
    Assert-True (-not [IO.Directory]::Exists($rollbackQuarantinePath)) (
        'Apply rollback 不得残留 quarantine')
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $approvedStablePath 'payload.txt')) -ceq
            'payload-approved-retired-evidence-a'
    ) 'Apply rollback 必须完整恢复 payload'
    $rollbackTransactionPath = Join-Path (Split-Path -Parent ([string]$applyPlan.planPath)) 'transaction.json'
    Assert-True ([IO.File]::Exists($rollbackTransactionPath)) (
        'Apply 中断必须留下可回读 transaction')
    $rollbackTransaction = Get-Content -Raw -LiteralPath $rollbackTransactionPath |
        ConvertFrom-Json -Depth 32 -DateKind String
    Assert-True ($rollbackTransaction.status -ceq 'rolled-back') (
        'Apply rollback 必须发布 rolled-back transaction')
    Assert-True ([IO.Directory]::Exists($unregisteredPath)) 'Apply rollback 不得触及未登记同级'
    Assert-True ([IO.Directory]::Exists($protectedEvidenceRoot)) 'Apply rollback 不得触及 protected analog'
    Assert-True ([IO.Directory]::Exists($rebuildPath)) 'Apply rollback 不得触及重建目录'

    $applyResult = & $fixtureCli `
        -Mode Apply `
        -PlanPath ([string]$applyPlan.planPath) `
        -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($applyResult.quarantined -eq $true) '精确 approved Plan 必须可隔离'
    Assert-True ($applyResult.recoverable -eq $true) 'Apply 后 transaction 必须可恢复'
    Assert-True (-not [IO.Directory]::Exists($approvedStablePath)) 'Apply 后原目标路径必须不存在'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) (
        'Apply 必须保留同父 quarantine')
    $quarantinedPayload = Join-Path ([string]$applyResult.quarantinePath) 'payload.txt'
    Assert-True (
        [IO.File]::ReadAllText($quarantinedPayload) -ceq 'payload-approved-retired-evidence-a'
    ) 'quarantine 必须可独立回读 payload'
    Assert-True ([IO.File]::Exists([string]$applyResult.transactionPath)) (
        'transaction 必须可独立回读')
    $transactionBytes = [IO.File]::ReadAllBytes([string]$applyResult.transactionPath)
    $expectedTransactionSha = Get-IndependentSha256Hex -Bytes $transactionBytes
    Assert-True ([string]$applyResult.transactionSha256 -ceq $expectedTransactionSha) (
        'transactionSha256 必须等于独立计算的 SHA-256')
    $transaction = Get-Content -Raw -LiteralPath ([string]$applyResult.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    Assert-True ($transaction.status -ceq 'quarantined') '成功 Apply 的 transaction 必须是 quarantined'
    Assert-True ([string]$transaction.targetPath -ceq $approvedStablePath) (
        'transaction 必须绑定原目标路径')
    Assert-True ([string]$transaction.quarantinePath -ceq [string]$applyResult.quarantinePath) (
        'transaction 必须绑定 quarantine 路径')
    Assert-True ([string]$transaction.generationId -ceq [string]$applyPlanDocument.generationId) (
        'transaction 必须锚定 plan generationId')
    Assert-True ([IO.Directory]::Exists($unregisteredPath)) 'Apply 不得触及未登记同级'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $unregisteredPath 'payload.txt')) -ceq
            'payload-unregistered-sibling'
    ) 'Apply 不得改写未登记同级 payload'
    Assert-True ([IO.Directory]::Exists($protectedEvidenceRoot)) 'Apply 不得触及 protected analog'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $protectedEvidenceRoot 'payload.txt')) -ceq
            'payload-safe-tree-delete'
    ) 'Apply 不得改写 protected analog payload'
    Assert-True ([IO.Directory]::Exists($rebuildPath)) 'Apply 获批目标 A 不得触及重建目录 B'
    Assert-True ([IO.Directory]::Exists($capabilityRoot)) 'Apply 不得触及 analog 父根'
    Assert-True ([IO.Directory]::Exists($approvedRestorePath)) 'Apply A 不得触及 Restore 目标 C'
    Assert-True ([IO.Directory]::Exists($approvedInterruptPath)) 'Apply A 不得触及中断目标 D'

    $recoverableStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $recoverableOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $recoverableStatus `
        -PlanPath ([string]$applyPlan.planPath)
    Assert-True ($recoverableOperation.lifecycle -ceq 'recoverable') (
        "quarantined 完整树的 Status 必须是 recoverable：$($recoverableOperation.lifecycle) errors=$($recoverableOperation.errors -join ';')")
    Assert-True (
        (@($recoverableOperation.safeActions) | Sort-Object -CaseSensitive) -join ',' -ceq 'purge,restore'
    ) 'recoverable 操作必须同时暴露 restore 与 purge'

    $rebuildApplyPlan = & $fixtureCli `
        -Mode Plan `
        -TargetPath $rebuildPath `
        -CapabilityRoot $rebuildPath `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-RetiredEvidenceRootPlanBindings `
        -PlanResult $rebuildApplyPlan `
        -ExpectedTargetPath $rebuildPath `
        -ExpectedPolicyPath ([string]$fixture.grantPolicyPath) `
        -ExpectedPolicyEntryId 'approved-retired-evidence-b' `
        -PayloadRelativePath 'payload.txt'
    $rebuildApplyPlanText = [IO.File]::ReadAllText(
        [string]$rebuildApplyPlan.planPath,
        [Text.UTF8Encoding]::new($false))
    $rebuildApplyPlanDocument = $rebuildApplyPlanText |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $rebuildApplyTargetRecord = @($rebuildApplyPlanDocument.fileIdentitiesV2 | Where-Object {
        [string]$_.relativePath -ceq '.'
    })[0]
    $rebuildApplyBoundHex = [BitConverter]::ToString(
        [Convert]::FromBase64String([string]$rebuildApplyTargetRecord.fileId128))
    Assert-True ($rebuildApplyBoundHex -ceq $rebuiltHex) (
        '未消费重建目录的 Apply Plan 必须仍绑定当前身份')
    $rebuildApply = & $fixtureCli `
        -Mode Apply `
        -PlanPath ([string]$rebuildApplyPlan.planPath) `
        -ApprovedPlanSha256 ([string]$rebuildApplyPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($rebuildApply.quarantined -eq $true) '绑定当前身份的未消费重建目录必须可 Apply'
    Assert-True (-not [IO.Directory]::Exists($rebuildPath)) '重建目录 Apply 后原路径必须不存在'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path ([string]$rebuildApply.quarantinePath) 'payload.txt')) -ceq
            'payload-approved-retired-evidence-b'
    ) '重建目录 quarantine 必须可独立回读 payload'
    Assert-True ([IO.Directory]::Exists($unregisteredPath)) '重建目录 Apply 不得触及未登记同级'
    Assert-True ([IO.Directory]::Exists($protectedEvidenceRoot)) '重建目录 Apply 不得触及 protected analog'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) (
        '重建目录 Apply 不得触及另一获批目标的 quarantine')

    $unconfirmedPurge = & $fixtureCli `
        -Mode Purge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($unconfirmedPurge.purged -ne $true) '未确认 Purge 不得删除'
    Assert-True ($unconfirmedPurge.refusalReason -ceq 'confirm-purge-required') (
        'Purge 缺少确认必须结构化拒绝')
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) (
        '未确认 Purge 不得清理 quarantine')
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath ([string]$rebuildApply.quarantinePath) `
        -OtherApprovedPayload 'payload-approved-retired-evidence-b' `
        -MessagePrefix '未确认 Purge'

    $wrongTransactionError = Assert-Throws -Message '错误 transaction 哈希必须失败关闭' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 ('0' * 64) `
            -ConfirmPurge `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($wrongTransactionError -match 'SHA-256') (
        "错误哈希拒绝必须返回稳定原因: $wrongTransactionError")
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) (
        '错误 transaction 哈希不得清理 quarantine')
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath ([string]$rebuildApply.quarantinePath) `
        -OtherApprovedPayload 'payload-approved-retired-evidence-b' `
        -MessagePrefix '错误 transaction 哈希'

    $quarantinePathA = [string]$applyResult.quarantinePath
    $liveQuarantineIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $quarantinePathA
    $plannedDotRecord = @($applyPlanDocument.fileIdentitiesV2 | Where-Object {
        [string]$_.relativePath -ceq '.'
    })
    Assert-True ($plannedDotRecord.Count -eq 1) 'Purge 前 plan 仍必须绑定目标目录 relativePath=.'
    $plannedDotFileId128 = [Convert]::FromBase64String([string]$plannedDotRecord[0].fileId128)
    Assert-True (
        (Test-FileId128Equal -Left $plannedDotFileId128 -Right $liveQuarantineIdentity.FileId128)
    ) 'Apply 改名后 quarantine 目录 FileIdentityV2 必须仍等于 plan 的 relativePath=.'
    Assert-CodexSafeTreeDeleteRetiredEvidenceRootApplyDirectoryIdentity `
        -Plan $applyPlanDocument `
        -Target ([pscustomobject]@{ rootDeletionPurpose = 'retired-evidence-root' }) `
        -TreePath $quarantinePathA `
        -Scope 'retired-evidence-root purge precheck'

    $extraLeafPath = Join-Path $quarantinePathA 'extra-unplanned.txt'
    [IO.File]::WriteAllText($extraLeafPath, 'unplanned', [Text.UTF8Encoding]::new($false))
    $treeDriftReject = Assert-Throws -Message 'quarantine 树漂移必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($treeDriftReject -match '漂移|manifest|fileIdentitiesV2 缺少|extra-unplanned') (
        "树漂移拒绝必须返回稳定原因: $treeDriftReject")
    Assert-True ([IO.Directory]::Exists($quarantinePathA)) '树漂移拒绝不得删除 quarantine'
    Assert-True ([IO.File]::Exists($extraLeafPath)) '树漂移拒绝不得旁路删除计划外文件'
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath ([string]$rebuildApply.quarantinePath) `
        -OtherApprovedPayload 'payload-approved-retired-evidence-b' `
        -MessagePrefix '树漂移拒绝'
    [IO.File]::Delete($extraLeafPath)

    $quarantinedPayloadA = Join-Path $quarantinePathA 'payload.txt'
    $quarantineDirectoryAds = '{0}:dir-ads' -f $quarantinePathA
    [IO.File]::WriteAllText($quarantineDirectoryAds, 'ads', [Text.UTF8Encoding]::new($false))
    $namedStreamPurgeReject = Assert-Throws -Message 'Purge 时 named stream 必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($namedStreamPurgeReject -match 'stream|流') (
        "named stream 拒绝必须返回稳定原因: $namedStreamPurgeReject")
    Assert-True ([IO.Directory]::Exists($quarantinePathA)) 'named stream 拒绝不得删除 quarantine'
    Assert-True ([IO.File]::Exists($quarantineDirectoryAds)) (
        'named stream 拒绝不得删除或改写 ADS')
    Assert-True (
        [IO.File]::ReadAllText($quarantinedPayloadA) -ceq 'payload-approved-retired-evidence-a'
    ) 'named stream 拒绝不得改写 payload'
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath ([string]$rebuildApply.quarantinePath) `
        -OtherApprovedPayload 'payload-approved-retired-evidence-b' `
        -MessagePrefix 'named stream 拒绝'
    $adsStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $adsOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $adsStatus `
        -PlanPath ([string]$applyPlan.planPath)
    Assert-True ($adsOperation.lifecycle -cne 'terminal') (
        "目录 ADS 使 Purge 失败后 Status 不得粉饰成 terminal：$($adsOperation.lifecycle)")
    Assert-True ([string]$adsOperation.transactionStatus -cne 'purged') (
        '目录 ADS 失败 Purge 不得把 transaction 写成 purged')
    [IO.File]::Delete($quarantineDirectoryAds)

    $purgeReparseOutside = Join-Path $scratchRoot 'purge-reparse-outside'
    [void][IO.Directory]::CreateDirectory($purgeReparseOutside)
    [IO.File]::WriteAllText(
        (Join-Path $purgeReparseOutside 'must-survive.txt'),
        'outside-purge',
        [Text.UTF8Encoding]::new($false))
    $purgeReparseLink = Join-Path $quarantinePathA 'linked'
    [void](New-Item -ItemType Junction -Path $purgeReparseLink -Target $purgeReparseOutside)
    $createdJunctions.Add($purgeReparseLink)
    $reparsePurgeReject = Assert-Throws -Message 'Purge 时未授权 reparse 必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($reparsePurgeReject -match 'reparse') (
        "reparse 拒绝必须返回稳定原因: $reparsePurgeReject")
    Assert-True ([IO.Directory]::Exists($quarantinePathA)) 'reparse 拒绝不得删除 quarantine'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $purgeReparseOutside 'must-survive.txt')) -ceq 'outside-purge'
    ) 'reparse 拒绝不得触及外部内容'
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath ([string]$rebuildApply.quarantinePath) `
        -OtherApprovedPayload 'payload-approved-retired-evidence-b' `
        -MessagePrefix 'reparse 拒绝'
    & $env:ComSpec /d /c "rmdir `"$purgeReparseLink`"" | Out-Null
    $createdJunctions.Remove($purgeReparseLink) | Out-Null

    $plannedFileLeaves = @($applyPlanDocument.treeManifest.entries | Where-Object {
        [string]$_.kind -ceq 'file'
    } | ForEach-Object { [string]$_.relativePath })
    Assert-True ($plannedFileLeaves.Count -eq 1 -and $plannedFileLeaves[0] -ceq 'payload.txt') (
        '原始 Plan 的 file leaf 必须恰好是 payload.txt')
    $purgeResult = & $fixtureCli `
        -Mode Purge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($purgeResult.purged -eq $true) '精确 approved transaction 必须可 Purge'
    Assert-True ($purgeResult.recoverable -eq $false) 'Purge 后必须明确标记不可恢复'
    Assert-True (-not [IO.Directory]::Exists($approvedStablePath)) 'Purge 后原目标路径必须不存在'
    Assert-True (-not [IO.Directory]::Exists($quarantinePathA)) 'Purge 后 quarantine 必须不存在'
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath ([string]$rebuildApply.quarantinePath) `
        -OtherApprovedPayload 'payload-approved-retired-evidence-b' `
        -MessagePrefix '成功 Purge'
    Assert-RetiredEvidenceRootPurgeJournalsReadable `
        -RunDirectory (Split-Path -Parent ([string]$applyResult.transactionPath)) `
        -TransactionPath ([string]$applyResult.transactionPath)
    Assert-True (
        $null -ne $purgeResult.leafDispositionsPath -and
        [IO.File]::Exists([string]$purgeResult.leafDispositionsPath)
    ) 'Purge 必须写出可回读 leaf-dispositions'
    $dispositions = Get-Content -Raw -LiteralPath ([string]$purgeResult.leafDispositionsPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    $dispositionPaths = @($dispositions.leaves | ForEach-Object { [string]$_.relativePath })
    Assert-True ($dispositionPaths.Count -eq $plannedFileLeaves.Count) (
        'Purge 范围必须严格等于原始 Plan 的 file leaf 集合')
    foreach ($relativePath in $plannedFileLeaves) {
        Assert-True ($dispositionPaths -contains $relativePath) (
            "leaf-dispositions 必须覆盖计划 leaf：$relativePath")
    }
    foreach ($row in @($dispositions.leaves)) {
        Assert-True ([string]$row.disposition -ceq 'deleted') '完整 Purge 中每个计划 leaf 必须是 deleted'
        Assert-True ($plannedFileLeaves -contains [string]$row.relativePath) (
            'leaf-dispositions 不得包含计划外路径')
    }

    $purgedStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $purgedOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $purgedStatus `
        -PlanPath ([string]$applyPlan.planPath)
    Assert-True ($purgedOperation.lifecycle -ceq 'terminal') (
        "成功 mixed-tree Purge 的 Status 必须是 terminal，不得因 directory journal 误判：$($purgedOperation.lifecycle) errors=$($purgedOperation.errors -join ';')")
    Assert-True ([string]$purgedOperation.transactionStatus -ceq 'purged') (
        'terminal 操作的 transactionStatus 必须仍是 purged')
    Assert-True ([string]$purgedOperation.journalStatus -ceq 'complete') (
        'mixed-tree 成功 Purge 的 directory journal 必须认证为 complete')
    Assert-True (
        (@($purgedOperation.errors) -join ';') -notmatch '只适用于纯目录树'
    ) 'mixed-tree directory journal 不得再套用 empty-project-state 纯目录树门'

    $quarantinePathB = [string]$rebuildApply.quarantinePath
    Invoke-RetiredEvidenceRootQuarantineDirectoryRecreate -QuarantinePath $quarantinePathB
    Assert-True ([IO.Directory]::Exists($quarantinePathB)) '目录重建夹具必须留下同路径 quarantine'
    $recreatedIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $quarantinePathB
    $rebuildPlanDocumentForPurge = [IO.File]::ReadAllText(
        [string]$rebuildApplyPlan.planPath,
        [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 128 -DateKind String
    $rebuildDotRecord = @($rebuildPlanDocumentForPurge.fileIdentitiesV2 | Where-Object {
        [string]$_.relativePath -ceq '.'
    })[0]
    $rebuildPlannedFileId128 = [Convert]::FromBase64String([string]$rebuildDotRecord.fileId128)
    Assert-True (
        -not (Test-FileId128Equal -Left $rebuildPlannedFileId128 -Right $recreatedIdentity.FileId128)
    ) '重建 quarantine 目录身份必须与 plan relativePath=. 不同'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $quarantinePathB 'payload.txt')) -ceq
            'payload-approved-retired-evidence-b'
    ) '目录重建夹具必须保留 payload 文件'
    $directoryIdentityPurgeReject = Assert-Throws -Message 'Purge 目录 FileIdentityV2 漂移必须失败闭锁' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$rebuildApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$rebuildApply.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($directoryIdentityPurgeReject -match '目标目录 FileIdentityV2') (
        "目录身份漂移必须复验 . 而不是只走 file map：$directoryIdentityPurgeReject")
    Assert-True ([IO.Directory]::Exists($quarantinePathB)) (
        '目录身份漂移拒绝不得删除 quarantine')
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $quarantinePathB 'payload.txt')) -ceq
            'payload-approved-retired-evidence-b'
    ) '目录身份漂移拒绝不得旁路删除 payload'
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -MessagePrefix '目录身份漂移拒绝'

    $driftStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $driftOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $driftStatus `
        -PlanPath ([string]$rebuildApplyPlan.planPath)
    Assert-True ($driftOperation.lifecycle -ceq 'manual-review') (
        "身份漂移 quarantine 的 Status 必须是 manual-review：$($driftOperation.lifecycle)")
    $rebuildTransactionSha = Get-IndependentSha256Hex -Bytes (
        [IO.File]::ReadAllBytes([string]$rebuildApply.transactionPath))
    $identityRestoreReject = Assert-Throws -Message 'Restore 必须复验目标目录 FileIdentityV2' -Action {
        & $fixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$rebuildApply.transactionPath) `
            -ApprovedTransactionSha256 $rebuildTransactionSha `
            -ConfirmRestore `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($identityRestoreReject -match '目标目录 FileIdentityV2') (
        "Restore 目录身份漂移必须复验 .：$identityRestoreReject")
    Assert-True ([IO.Directory]::Exists($quarantinePathB)) (
        'Restore 身份漂移拒绝不得把 quarantine 改回目标路径')
    Assert-True (-not [IO.Directory]::Exists($rebuildPath)) (
        'Restore 身份漂移拒绝不得重建原目标路径')

    $purgedATransactionSha = Get-IndependentSha256Hex -Bytes (
        [IO.File]::ReadAllBytes([string]$applyResult.transactionPath))
    $purgedRestoreReject = Assert-Throws -Message '对 purged 再 Restore 必须拒绝' -Action {
        & $fixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 $purgedATransactionSha `
            -ConfirmRestore `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($purgedRestoreReject -match '不可恢复的 terminal') (
        "purged Restore 拒绝必须返回稳定原因：$purgedRestoreReject")

    $restorePlan = & $fixtureCli `
        -Mode Plan `
        -TargetPath $approvedRestorePath `
        -CapabilityRoot $approvedRestorePath `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-RetiredEvidenceRootPlanBindings `
        -PlanResult $restorePlan `
        -ExpectedTargetPath $approvedRestorePath `
        -ExpectedPolicyPath ([string]$fixture.grantPolicyPath) `
        -ExpectedPolicyEntryId 'approved-retired-evidence-c' `
        -PayloadRelativePath 'payload.txt'
    $restoreApply = & $fixtureCli `
        -Mode Apply `
        -PlanPath ([string]$restorePlan.planPath) `
        -ApprovedPlanSha256 ([string]$restorePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($restoreApply.quarantined -eq $true) 'Restore 目标必须可 Apply'
    Assert-True (-not [IO.Directory]::Exists($approvedRestorePath)) 'Apply C 后原路径必须不存在'
    $unconfirmedRestore = & $fixtureCli `
        -Mode Restore `
        -TransactionPath ([string]$restoreApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$restoreApply.transactionSha256) `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($unconfirmedRestore.restored -ne $true) '未确认 Restore 不得改名'
    Assert-True ($unconfirmedRestore.refusalReason -ceq 'confirm-restore-required') (
        'Restore 缺少确认必须结构化拒绝')
    Assert-True ([IO.Directory]::Exists([string]$restoreApply.quarantinePath)) (
        '未确认 Restore 必须保留 quarantine')

    $extraRestoreLeaf = Join-Path ([string]$restoreApply.quarantinePath) 'extra-unplanned-restore.txt'
    [IO.File]::WriteAllText($extraRestoreLeaf, 'unplanned', [Text.UTF8Encoding]::new($false))
    $incompleteRestoreReject = Assert-Throws -Message '不完整 quarantine 必须拒绝 Restore' -Action {
        & $fixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$restoreApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$restoreApply.transactionSha256) `
            -ConfirmRestore `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($incompleteRestoreReject -match '漂移') (
        "不完整 Restore 必须失败闭锁：$incompleteRestoreReject")
    Assert-True ([IO.File]::Exists($extraRestoreLeaf)) '不完整 Restore 拒绝不得旁路删除计划外文件'
    [IO.File]::Delete($extraRestoreLeaf)

    $driftedPolicyPath = Join-Path $scratchRoot 'grant-policy-sha-drift.json'
    $grantPolicyForDrift = Get-Content -Raw -LiteralPath ([string]$fixture.grantPolicyPath) |
        ConvertFrom-Json -Depth 32
    $parentForDrift = @($grantPolicyForDrift.entries | Where-Object {
        [string]$_.id -ceq 'fixture-run-evidence-analog'
    })[0]
    $deniedForDrift = [Collections.Generic.List[string]]::new()
    foreach ($deniedPath in @($parentForDrift.deniedExactPaths)) {
        $deniedForDrift.Add([string]$deniedPath)
    }
    $deniedForDrift.Add((Join-Path $capabilityRoot 'sha-drift-denied-placeholder'))
    $parentForDrift.deniedExactPaths = [string[]]$deniedForDrift
    [IO.File]::WriteAllText(
        $driftedPolicyPath,
        ($grantPolicyForDrift | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $policyDriftRestoreReject = Assert-Throws -Message 'policy SHA 漂移必须拒绝 Restore' -Action {
        & $fixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$restoreApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$restoreApply.transactionSha256) `
            -ConfirmRestore `
            -FixturePolicyPath $driftedPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($policyDriftRestoreReject -match '漂移') (
        "Restore 必须停止在策略 SHA 漂移：$policyDriftRestoreReject")
    Assert-True ([IO.Directory]::Exists([string]$restoreApply.quarantinePath)) (
        '策略 SHA 漂移拒绝不得 Restore')

    $restoreResult = & $fixtureCli `
        -Mode Restore `
        -TransactionPath ([string]$restoreApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$restoreApply.transactionSha256) `
        -ConfirmRestore `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($restoreResult.restored -eq $true) '完整可恢复 transaction 必须可 Restore'
    Assert-True ([IO.Directory]::Exists($approvedRestorePath)) 'Restore 后目标必须回来'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $approvedRestorePath 'payload.txt')) -ceq
            'payload-approved-retired-evidence-c'
    ) 'Restore 必须完整恢复 payload'
    Assert-True (-not [IO.Directory]::Exists([string]$restoreApply.quarantinePath)) (
        'Restore 后 quarantine 必须不在')
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath $quarantinePathB `
        -OtherApprovedPayload 'payload-approved-retired-evidence-b' `
        -MessagePrefix '成功 Restore'
    Assert-True ([IO.Directory]::Exists($approvedInterruptPath)) 'Restore 不得触及中断目标 D'
    $restoredTransaction = Get-Content -Raw -LiteralPath ([string]$restoreApply.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    Assert-True ($restoredTransaction.status -ceq 'restored') 'Restore 后 transaction 必须终端 restored'
    $restoredStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $restoredOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $restoredStatus `
        -PlanPath ([string]$restorePlan.planPath)
    Assert-True ($restoredOperation.lifecycle -ceq 'terminal') (
        "成功 Restore 的 Status 必须是 terminal：$($restoredOperation.lifecycle)")
    Assert-RetiredEvidenceRootConsumedGrantAndReplay `
        -FixtureCli $fixtureCli `
        -TargetPath $approvedRestorePath `
        -GrantPolicyPath ([string]$fixture.grantPolicyPath) `
        -EvidenceRoot $operationEvidenceRoot `
        -PlanPath ([string]$restorePlan.planPath) `
        -PlanSha256 ([string]$restorePlan.planSha256) `
        -TransactionPath ([string]$restoreApply.transactionPath) `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -ExpectedPayload 'payload-approved-retired-evidence-c' `
        -TargetMustExist

    $repeatRestoreReject = Assert-Throws -Message '重复 Restore 必须拒绝' -Action {
        & $fixtureCli `
            -Mode Restore `
            -TransactionPath ([string]$restoreApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$restoreResult.transactionSha256) `
            -ConfirmRestore `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($repeatRestoreReject -match '不可恢复的 terminal') (
        "重复 Restore 拒绝必须返回稳定原因：$repeatRestoreReject")
    $postRestorePurgeReject = Assert-Throws -Message 'Restore 后不得再 Purge 扩大范围' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$restoreApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$restoreResult.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($postRestorePurgeReject -match '可 Purge 状态') (
        "Restore 后 Purge 必须拒绝：$postRestorePurgeReject")
    Assert-True ([IO.Directory]::Exists($approvedRestorePath)) (
        '重复 Restore / 再 Purge 拒绝不得再改目标')
    Assert-True ([IO.Directory]::Exists($unregisteredPath)) (
        '重复 Restore 不得触及未登记同级')

    $interruptPlan = & $fixtureCli `
        -Mode Plan `
        -TargetPath $approvedInterruptPath `
        -CapabilityRoot $approvedInterruptPath `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-RetiredEvidenceRootPlanBindings `
        -PlanResult $interruptPlan `
        -ExpectedTargetPath $approvedInterruptPath `
        -ExpectedPolicyPath ([string]$fixture.grantPolicyPath) `
        -ExpectedPolicyEntryId 'approved-retired-evidence-d' `
        -PayloadRelativePath 'payload.txt'
    $interruptApply = & $fixtureCli `
        -Mode Apply `
        -PlanPath ([string]$interruptPlan.planPath) `
        -ApprovedPlanSha256 ([string]$interruptPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($interruptApply.quarantined -eq $true) '中断目标必须可 Apply'
    $interruptFault = {
        param([string]$Path, [int]$Attempt)
        if ([IO.Path]::GetFileName($Path) -ceq 'z-interrupt.txt') { return 32 }
    }.GetNewClosure()
    $interruptError = Assert-Throws -Message 'Purge 中断必须留下可恢复子集' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$interruptApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$interruptApply.transactionSha256) `
            -ConfirmPurge `
            -FixtureLeafDeleteFault $interruptFault `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($interruptError -match 'Injected safe-delete leaf failure') (
        "Purge 中断必须返回注入失败：$interruptError")
    $interruptTransaction = Get-Content -Raw -LiteralPath ([string]$interruptApply.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    Assert-True ($interruptTransaction.status -ceq 'purging') (
        '首叶 commit 后的中断必须保持 purging')
    Assert-True (
        -not [IO.File]::Exists((Join-Path ([string]$interruptApply.quarantinePath) 'payload.txt')) -and
        [IO.File]::Exists((Join-Path ([string]$interruptApply.quarantinePath) 'z-interrupt.txt'))
    ) '中断必须留下计划未变子集，不得扩大删除'
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath $approvedRestorePath `
        -OtherApprovedPayload 'payload-approved-retired-evidence-c' `
        -MessagePrefix 'Purge 中断'
    $interruptStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $interruptOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $interruptStatus `
        -PlanPath ([string]$interruptPlan.planPath)
    Assert-True ($interruptOperation.lifecycle -ceq 'purge-resumable') (
        "purging 合法子集的 Status 必须是 purge-resumable：$($interruptOperation.lifecycle) errors=$($interruptOperation.errors -join ';')")
    Assert-True ((@($interruptOperation.safeActions) -join ',') -ceq 'purge') (
        'purge-resumable 只能暴露 purge')
    $interruptTransactionSha = Get-IndependentSha256Hex -Bytes (
        [IO.File]::ReadAllBytes([string]$interruptApply.transactionPath))
    $interruptResume = & $fixtureCli `
        -Mode Purge `
        -TransactionPath ([string]$interruptApply.transactionPath) `
        -ApprovedTransactionSha256 $interruptTransactionSha `
        -ConfirmPurge `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($interruptResume.purged -eq $true) '中断重放必须幂等完成剩余计划 leaf'
    Assert-True (-not [IO.Directory]::Exists([string]$interruptApply.quarantinePath)) (
        '中断重放完成后 quarantine 必须不在')
    Assert-True (-not [IO.Directory]::Exists($approvedInterruptPath)) (
        '中断重放不得把目标路径重建出来')
    Assert-RetiredEvidenceRootNeighborsIntact `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -OtherApprovedPath $approvedRestorePath `
        -OtherApprovedPayload 'payload-approved-retired-evidence-c' `
        -MessagePrefix 'Purge 中断重放'
    $resumedStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $resumedOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $resumedStatus `
        -PlanPath ([string]$interruptPlan.planPath)
    Assert-True ($resumedOperation.lifecycle -ceq 'terminal') (
        "中断重放成功 Purge 后 Status 必须是 terminal：$($resumedOperation.lifecycle)")

    $mixedArchive = & $fixtureCli `
        -Mode Archive `
        -TransactionPath ([string]$interruptApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$interruptResume.transactionSha256) `
        -ConfirmArchive `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    Assert-True ($mixedArchive.archived -eq $true) (
        'mixed-tree 成功 Purge 的 Archive 不得因纯目录树门抛错')

    $repeatInterruptPurgeReject = Assert-Throws -Message '对 purged 再 Purge 必须拒绝' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$interruptApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$interruptResume.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($repeatInterruptPurgeReject -match '可 Purge 状态') (
        "purged 再 Purge 必须拒绝：$repeatInterruptPurgeReject")

    [void][IO.Directory]::CreateDirectory($approvedStablePath)
    [IO.File]::WriteAllText(
        (Join-Path $approvedStablePath 'payload.txt'),
        'rebuilt-after-purge',
        [Text.UTF8Encoding]::new($false))
    $rebuiltAfterPurgeStatus = & $fixtureCli `
        -Mode Status `
        -FixturePolicyPath ([string]$fixture.grantPolicyPath) `
        -FixtureEvidenceRoot $operationEvidenceRoot
    $rebuiltAfterPurgeOperation = Get-RetiredEvidenceRootStatusOperation `
        -Status $rebuiltAfterPurgeStatus `
        -PlanPath ([string]$applyPlan.planPath)
    Assert-True ($rebuiltAfterPurgeOperation.lifecycle -ceq 'manual-review') (
        "purged 后同路径新 identity 不得当成 terminal 重建：$($rebuiltAfterPurgeOperation.lifecycle)")
    Assert-RetiredEvidenceRootConsumedGrantAndReplay `
        -FixtureCli $fixtureCli `
        -TargetPath $approvedStablePath `
        -GrantPolicyPath ([string]$fixture.grantPolicyPath) `
        -EvidenceRoot $operationEvidenceRoot `
        -PlanPath ([string]$applyPlan.planPath) `
        -PlanSha256 ([string]$applyPlan.planSha256) `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -UnregisteredPath $unregisteredPath `
        -ProtectedEvidenceRoot $protectedEvidenceRoot `
        -CapabilityRoot $capabilityRoot `
        -ExpectedPayload 'rebuilt-after-purge' `
        -TargetMustExist
    $revokedPolicyPath = Join-Path $scratchRoot 'grant-policy-revoked-a.json'
    Write-RetiredEvidenceRootAnalogPolicyWithoutEntry `
        -SourcePolicyPath ([string]$fixture.grantPolicyPath) `
        -DestinationPath $revokedPolicyPath `
        -RemoveId 'approved-retired-evidence-a'
    $liveProductionPolicy = Get-Content -LiteralPath $productionPolicyPath -Raw |
        ConvertFrom-Json -Depth 32
    Assert-RetiredEvidenceRootProductionRevoked -Policy $liveProductionPolicy -MessagePrefix 'analog 撤销不得改写生产 policy'
    $revokedReplayApplyReject = Assert-Throws -Message 'analog 撤销后重放旧 Plan SHA 必须拒绝' -Action {
        & $fixtureCli `
            -Mode Apply `
            -PlanPath ([string]$applyPlan.planPath) `
            -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $revokedPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($revokedReplayApplyReject -match '漂移|allowlist|许可已消费') (
        "analog 撤销后重放旧 Plan 必须拒绝：$revokedReplayApplyReject")
    $revokedReplayTransactionSha = Get-IndependentSha256Hex -Bytes (
        [IO.File]::ReadAllBytes([string]$applyResult.transactionPath))
    $revokedReplayPurgeReject = Assert-Throws -Message 'analog 撤销后重放旧 transaction SHA 必须拒绝' -Action {
        & $fixtureCli `
            -Mode Purge `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 $revokedReplayTransactionSha `
            -ConfirmPurge `
            -FixturePolicyPath $revokedPolicyPath `
            -FixtureEvidenceRoot $operationEvidenceRoot
    }
    Assert-True ($revokedReplayPurgeReject -match '漂移|allowlist|可 Purge 状态|许可已消费') (
        "analog 撤销后重放旧 transaction 必须拒绝：$revokedReplayPurgeReject")
    Assert-True ([IO.Directory]::Exists($approvedStablePath)) '撤销后重放不得删除重建目录'
}
finally {
    if ($null -ne $createdJunctions) {
        foreach ($junctionPath in @($createdJunctions)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$junctionPath) -and
                [IO.Directory]::Exists($junctionPath)) {
                & $env:ComSpec /d /c "rmdir `"$junctionPath`"" | Out-Null
            }
        }
    }
    if ($null -ne $fixture -and -not [string]::IsNullOrWhiteSpace([string]$fixture.scratchRoot)) {
        $cleanupRoot = [IO.Path]::GetFullPath([string]$fixture.scratchRoot)
        $allowedPrefix = [IO.Path]::GetFullPath((Join-Path $projectRoot '.scratch')).TrimEnd('\') + '\safe-tree-delete-tests-'
        if ($cleanupRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Directory]::Exists($cleanupRoot)) {
            [IO.Directory]::Delete($cleanupRoot, $true)
        }
    }
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteRetiredEvidenceRoot'
    slices = @(
        'contract',
        'approved-fixture',
        'unregistered-sibling',
        'rebuild-path',
        'default-reject',
        'parser-accept',
        'illegal-combinations',
        'exact-root',
        'plan-identity-binding',
        'fail-closed',
        'apply-approved-plan',
        'apply-directory-identity',
        'apply-interrupt',
        'apply-unconsumed-rebuild',
        'purge-approved-transaction',
        'purge-directory-identity',
        'purge-fail-closed',
        'purge-no-collateral',
        'status-planned',
        'status-recoverable',
        'status-terminal-mixed-journal',
        'status-purge-resumable',
        'status-manual-review',
        'restore-approved-transaction',
        'restore-fail-closed',
        'restore-idempotent-reject',
        'crash-replay-idempotent',
        'consumed-grant-after-purge',
        'consumed-grant-after-restore',
        'old-sha-replay',
        'analog-revoke-replay',
        'content-drift',
        'hardlink-fail-closed',
        'path-alias-junction'
    )
}
