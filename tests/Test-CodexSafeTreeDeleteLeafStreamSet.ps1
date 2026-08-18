[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$linkAwareTargetPath = Join-Path $fixtureRoot 'link-aware-build-output'
$linkAwarePolicyPath = Join-Path $fixtureRoot 'link-aware-policy.json'
$linkAwareInternalPath = Join-Path $linkAwareTargetPath '.store\package'
$linkAwareJunctionPath = Join-Path $linkAwareTargetPath 'linked-package'
$linkAwareExternalPath = Join-Path $fixtureRoot 'link-aware-external'
$linkAwareExternalFile = Join-Path $linkAwareExternalPath 'must-survive.txt'
$linkAwareHardLinkPath = Join-Path $linkAwareTargetPath 'shared-cache.bin'
$captureProbePath = Join-Path $fixtureRoot 'capture-probe'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action | Out-Null
    } catch {
        return $_.Exception.Message
    }
    throw $Message
}

function Remove-TestTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$LinkAware,
        [string]$LinkTargetRoot
    )

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshotArguments = @{
        Path = $Path
        CapabilityRoot = $parent
        AllowedExactPaths = @($Path)
        Name = 'safe-delete leaf stream-set test cleanup snapshot'
    }
    $removeArguments = @{
        Path = $Path
        CapabilityRoot = $parent
        AllowedExactPaths = @($Path)
        Scope = 'safe-delete leaf stream-set test cleanup'
    }
    if ($LinkAware) {
        $snapshotArguments.AllowHardLinks = $true
        $snapshotArguments.AllowInternalDirectoryJunctions = $true
        $snapshotArguments.InternalDirectoryJunctionTargetRoot = $LinkTargetRoot
        $removeArguments.AllowHardLinks = $true
        $removeArguments.AllowInternalDirectoryJunctions = $true
        $removeArguments.InternalDirectoryJunctionTargetRoot = $LinkTargetRoot
    }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot @snapshotArguments
    Remove-CodexHookCapabilityDirectoryTree `
        @removeArguments `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot
}

function New-StreamSetPlan {
    param([Parameter(Mandatory)][string]$Path)

    return (& $entryPath `
        -Mode Plan `
        -TargetPath $Path `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot)
}

function New-StreamSetCandidate {
    param([Parameter(Mandatory)][string]$Name)

    $path = Join-Path $fixtureRoot $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $path 'nested'))
    [IO.File]::WriteAllText((Join-Path $path 'payload.txt'), "$Name-payload", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $path 'nested\child.bin'), "$Name-child", [Text.UTF8Encoding]::new($false))
    return $path
}

function Read-PlanDocument {
    param([Parameter(Mandatory)][string]$PlanPath)

    return (Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json -Depth 128 -DateKind String)
}

$runtimeEdition = [string]$PSVersionTable.PSEdition
$runtimeMajor = [int]$PSVersionTable.PSVersion.Major
$runtimeMinor = [int]$PSVersionTable.PSVersion.Minor
Assert-True ($runtimeEdition -ceq 'Core') "本测试要求 PowerShell Core，实际为 $runtimeEdition"
Assert-True (
    $runtimeMajor -gt 7 -or
    ($runtimeMajor -eq 7 -and $runtimeMinor -ge 6)
) "本测试要求 PowerShell 7.6+，实际为 $($PSVersionTable.PSVersion)"

$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($projectRoot))
Assert-True (
    $drive.DriveFormat -ceq 'NTFS'
) "本测试要求 NTFS（stream-set 用例依赖 ADS 命名流，ReFS 不支持），实际为 $($drive.DriveFormat)"

. $hostSafetyLibraryPath
. $libraryPath
Assert-True (
    $null -ne (Get-Command -Name Get-CodexSafeTreeDeleteLeafStreamSet -ErrorAction SilentlyContinue)
) 'RED: Get-CodexSafeTreeDeleteLeafStreamSet 尚不存在'
Assert-True (
    $null -ne (Get-Command -Name Read-CodexSafeTreeDeletePlanStreamSet -ErrorAction SilentlyContinue)
) 'RED: Read-CodexSafeTreeDeletePlanStreamSet 尚不存在'

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'leaf-stream-set-fixture'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))

    # ---- Slice A：Plan 记录完整 stream-set，reader 严格绑定 ----
    [void][IO.Directory]::CreateDirectory($captureProbePath)
    $probeFile = Join-Path $captureProbePath 'probe.txt'
    [IO.File]::WriteAllText($probeFile, 'probe', [Text.UTF8Encoding]::new($false))
    $probeCapture = Get-CodexSafeTreeDeleteLeafStreamSet -LiteralPath $probeFile
    Assert-True (@($probeCapture.StreamNames).Count -eq 1 -and
        [string]$probeCapture.StreamNames[0] -ceq '::$DATA') '普通文件的 stream-set 必须只含默认流'
    Assert-True ([long]$probeCapture.NumberOfLinks -eq 1L) '普通文件 hardlink 计数必须为 1'
    Assert-True (-not $probeCapture.IsDirectory -and -not $probeCapture.IsReparsePoint) '普通文件类型标志必须为 file'
    Assert-True ($null -ne $probeCapture.Identity) 'stream-set 捕获必须同时绑定 FileIdentityV2'
    $probeDirCapture = Get-CodexSafeTreeDeleteLeafStreamSet -LiteralPath $captureProbePath
    Assert-True (@($probeDirCapture.StreamNames).Count -eq 0) '普通目录的原始 stream-set 必须为空集'
    Assert-True ($probeDirCapture.IsDirectory) '目录类型标志必须为 directory'
    [IO.File]::WriteAllText("$probeFile`:ads", 'ads', [Text.UTF8Encoding]::new($false))
    $probeAdsCapture = Get-CodexSafeTreeDeleteLeafStreamSet -LiteralPath $probeFile
    Assert-True (@($probeAdsCapture.StreamNames).Count -eq 2 -and
        @($probeAdsCapture.StreamNames)[1] -ceq ':ads:$DATA') '含 ADS 文件必须枚举出命名流'
    [IO.File]::Delete("$probeFile`:ads")
    $probeMissingError = Assert-Throws -Message 'capture 对缺失 leaf 必须失败闭锁' -Action {
        [void](Get-CodexSafeTreeDeleteLeafStreamSet -LiteralPath (Join-Path $captureProbePath 'missing.txt'))
    }
    Assert-True ($probeMissingError.Length -gt 0) 'capture 对缺失 leaf 必须抛出错误'

    $planTarget = New-StreamSetCandidate -Name 'candidate-plan'
    $planResult = New-StreamSetPlan -Path $planTarget
    Assert-True ($planResult.planned -eq $true) 'Plan 必须成功'
    $planText = [IO.File]::ReadAllText([string]$planResult.planPath, [Text.UTF8Encoding]::new($false))
    $plan = $planText | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-True (
        @($plan.PSObject.Properties.Name) -contains 'leafStreamSetV1'
    ) 'RED: 新 plan 必须并列写出 leafStreamSetV1'
    Assert-True ([long]$plan.leafStreamSetV1.schemaVersion -eq 1L) 'leafStreamSetV1 schemaVersion 必须为 1'
    Assert-True (
        [string]$plan.leafStreamSetV1.consumptionBoundary.apply -ceq 'apply-locked-preflight' -and
        [string]$plan.leafStreamSetV1.consumptionBoundary.purge -ceq 'purge-locked-preflight' -and
        [string]$plan.leafStreamSetV1.consumptionBoundary.streamDrift -ceq 'fail-closed' -and
        [string]$plan.leafStreamSetV1.consumptionBoundary.leafDrift -ceq 'fail-closed' -and
        [string]$plan.leafStreamSetV1.consumptionBoundary.requiresTreeManifestReverification -ceq 'always'
    ) 'leafStreamSetV1 必须记录 Apply/Purge 消费边界、失败闭锁规则与 treeManifest 复验配对要求'
    $manifestPaths = @($plan.treeManifest.entries | ForEach-Object { [string]$_.relativePath } | Sort-Object)
    $streamSetPaths = @($plan.leafStreamSetV1.leaves | ForEach-Object { [string]$_.relativePath } | Sort-Object)
    Assert-True (($manifestPaths -join '|') -ceq ($streamSetPaths -join '|')) `
        'leafStreamSetV1 leaves 必须与 treeManifest 条目集合精确一致'
    $fileLeaf = @($plan.leafStreamSetV1.leaves | Where-Object relativePath -ceq 'payload.txt')
    Assert-True ($fileLeaf.Count -eq 1) 'stream-set 必须包含 payload.txt'
    Assert-True ([string]$fileLeaf[0].kind -ceq 'file') 'payload.txt 必须是 file leaf'
    Assert-True (@($fileLeaf[0].streamNames).Count -eq 1 -and
        [string]$fileLeaf[0].streamNames[0] -ceq '::$DATA') 'file leaf 必须只记录默认流'
    Assert-True ([long]$fileLeaf[0].hardLinkCount -eq 1L) 'file leaf 必须记录 hardlink 计数 1'
    $dirLeaf = @($plan.leafStreamSetV1.leaves | Where-Object relativePath -ceq 'nested')
    Assert-True ($dirLeaf.Count -eq 1 -and [string]$dirLeaf[0].kind -ceq 'directory') '目录 leaf 必须存在'
    Assert-True (@($dirLeaf[0].streamNames).Count -eq 0) '普通目录 leaf 必须记录空 stream-set'
    $rootLeaf = @($plan.leafStreamSetV1.leaves | Where-Object relativePath -ceq '.')
    Assert-True ($rootLeaf.Count -eq 1 -and [string]$rootLeaf[0].kind -ceq 'directory') '根目录 leaf 必须存在'

    $streamSet = Read-CodexSafeTreeDeletePlanStreamSet -Plan $plan
    Assert-True ($null -ne $streamSet -and $null -ne $streamSet.byPath) 'reader 必须返回 byPath 索引'
    Assert-True ($streamSet.byPath.Count -eq $manifestPaths.Count) 'reader 必须覆盖每个 manifest 条目'
    $payloadRow = $streamSet.byPath['payload.txt']
    Assert-True ($null -ne $payloadRow.identity) 'file leaf 必须携带 FileIdentityV2'
    Assert-True ($payloadRow.identity -is [CodexSafeTreeDelete.FileIdentityV2]) 'file leaf identity 必须是 FileIdentityV2'
    $liveIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath (Join-Path $planTarget 'payload.txt')
    Assert-True ($payloadRow.identity -eq $liveIdentity) 'reader 绑定的 identity 必须与当场再取一致'

    $legacyPlan = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $null = $legacyPlan.PSObject.Properties.Remove('leafStreamSetV1')
    $legacyError = Assert-Throws -Message '缺少 leafStreamSetV1 的 plan 必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $legacyPlan)
    }
    Assert-True ($legacyError -match 'leafStreamSetV1') 'legacy plan 拒绝原因必须指向缺失字段'
    Assert-True ($legacyError -match '拒绝|缺少') 'legacy plan 必须失败闭锁'

    $tamperedLeafKind = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $tamperedLeafKind.leafStreamSetV1.leaves[0].kind = 'socket'
    $kindError = Assert-Throws -Message '未知 leaf kind 必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $tamperedLeafKind)
    }
    Assert-True ($kindError -match 'kind') '未知 kind 拒绝必须指向 kind'

    $tamperedMissing = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $tamperedMissing.leafStreamSetV1.leaves = @(
        $tamperedMissing.leafStreamSetV1.leaves | Where-Object relativePath -cne 'payload.txt'
    )
    $missingLeafError = Assert-Throws -Message 'stream-set 缺失已计划 leaf 必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $tamperedMissing)
    }
    Assert-True ($missingLeafError -match 'treeManifest|精确') '缺失 leaf 必须破坏与 treeManifest 的精确对应'

    $tamperedExtra = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $extraLeaf = $tamperedExtra.leafStreamSetV1.leaves[0].PSObject.Copy()
    $extraLeaf.relativePath = 'nested/child.bin'
    $tamperedExtra.leafStreamSetV1.leaves = @($tamperedExtra.leafStreamSetV1.leaves) + @($extraLeaf)
    $dupError = Assert-Throws -Message 'stream-set 重复 relativePath 必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $tamperedExtra)
    }
    Assert-True ($dupError -match '重复') '重复 relativePath 必须失败闭锁'

    $tamperedStreams = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $fileRow = @($tamperedStreams.leafStreamSetV1.leaves | Where-Object relativePath -ceq 'payload.txt')[0]
    $fileRow.streamNames = @('::$DATA', ':secret:$DATA')
    $fileStreamsError = Assert-Throws -Message 'file leaf 声明命名流必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $tamperedStreams)
    }
    Assert-True ($fileStreamsError -match 'stream|流') 'file leaf 命名流声明必须失败闭锁'

    $tamperedBoundary = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $tamperedBoundary.leafStreamSetV1.consumptionBoundary.purge = 'skip'
    $boundaryError = Assert-Throws -Message '消费边界被改写必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $tamperedBoundary)
    }
    Assert-True ($boundaryError -match 'consumptionBoundary|消费边界') '消费边界漂移必须失败闭锁'

    $tamperedPairing = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $tamperedPairing.leafStreamSetV1.consumptionBoundary.requiresTreeManifestReverification = 'never'
    $pairingError = Assert-Throws -Message 'treeManifest 复验配对声明被改写必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $tamperedPairing)
    }
    Assert-True ($pairingError -match 'consumptionBoundary|消费边界') '复验配对漂移必须失败闭锁'

    $legacyBoundary = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $null = $legacyBoundary.leafStreamSetV1.consumptionBoundary.PSObject.Properties.Remove(
        'requiresTreeManifestReverification')
    $legacyBoundaryError = Assert-Throws -Message '缺少复验配对声明的旧消费边界必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePlanStreamSet -Plan $legacyBoundary)
    }
    Assert-True ($legacyBoundaryError -match 'consumptionBoundary|消费边界') '缺字段消费边界必须失败闭锁'

    # file leaf 携带命名流（如 Zone.Identifier ADS）→ Plan 失败闭锁
    $fileAdsPlanTarget = New-StreamSetCandidate -Name 'candidate-plan-file-ads'
    $fileAdsPlanStream = "$((Join-Path $fileAdsPlanTarget 'payload.txt'))`:Zone.Identifier"
    [IO.File]::WriteAllText($fileAdsPlanStream, 'zone', [Text.UTF8Encoding]::new($false))
    try {
        $fileAdsPlanError = Assert-Throws -Message '含 ADS 文件的 Plan 必须失败闭锁' -Action {
            [void](New-StreamSetPlan -Path $fileAdsPlanTarget)
        }
        Assert-True ($fileAdsPlanError -match 'stream|流') 'file leaf 携带命名流必须返回稳定拒绝原因'
    } finally {
        if ([IO.File]::Exists($fileAdsPlanStream)) { [IO.File]::Delete($fileAdsPlanStream) }
    }

    $tamperedLinkCount = Read-PlanDocument -PlanPath ([string]$planResult.planPath)
    $linkRow = @($tamperedLinkCount.leafStreamSetV1.leaves | Where-Object relativePath -ceq 'payload.txt')[0]
    $linkRow.hardLinkCount = [long]2
    # reader 只校验形状，计数与 live 的绑定由 Apply/Purge 复验；这里确认 reader 接受合法形状
    $relaxed = Read-CodexSafeTreeDeletePlanStreamSet -Plan $tamperedLinkCount
    Assert-True ([long]$relaxed.byPath['payload.txt'].hardLinkCount -eq 2L) 'reader 必须原样带出 hardLinkCount'

    # ---- Slice B：Apply 在同一 locked preflight freeze 内消费 stream-set ----
    $applyTarget = New-StreamSetCandidate -Name 'candidate-apply-ok'
    $applyPlan = New-StreamSetPlan -Path $applyTarget
    $applyResult = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$applyPlan.planPath) `
        -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($applyResult.quarantined -eq $true) 'stream-set 匹配时 Apply 必须成功'

    $mtimeTarget = New-StreamSetCandidate -Name 'candidate-apply-mtime'
    $mtimePlan = New-StreamSetPlan -Path $mtimeTarget
    [IO.File]::SetLastWriteTimeUtc((Join-Path $mtimeTarget 'payload.txt'), [datetime]::new(2026, 8, 14, 1, 2, 3, [DateTimeKind]::Utc))
    $mtimeError = Assert-Throws -Message 'plan 后 mtime 漂移必须使 Apply 失败闭锁' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$mtimePlan.planPath) `
            -ApprovedPlanSha256 ([string]$mtimePlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($mtimeError -match 'identity|漂移') 'mtime 漂移必须经由 FileIdentityV2 消费失败'
    Assert-True ([IO.Directory]::Exists($mtimeTarget)) 'mtime 漂移拒绝不得隔离目标'

    $dirAdsTarget = New-StreamSetCandidate -Name 'candidate-apply-dir-ads'
    $dirAdsPlan = New-StreamSetPlan -Path $dirAdsTarget
    [IO.File]::WriteAllText("$((Join-Path $dirAdsTarget 'nested'))`:dir-ads", 'ads', [Text.UTF8Encoding]::new($false))
    $dirAdsError = Assert-Throws -Message 'plan 后目录新增 ADS 必须使 Apply 失败闭锁' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$dirAdsPlan.planPath) `
            -ApprovedPlanSha256 ([string]$dirAdsPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($dirAdsError -match 'stream|流') '目录 ADS 漂移必须经由 stream-set 复验失败'
    Assert-True ([IO.Directory]::Exists($dirAdsTarget)) '目录 ADS 漂移拒绝不得隔离目标'
    [IO.File]::Delete("$((Join-Path $dirAdsTarget 'nested'))`:dir-ads")

    $fileAdsTarget = New-StreamSetCandidate -Name 'candidate-apply-file-ads'
    $fileAdsPlan = New-StreamSetPlan -Path $fileAdsTarget
    [IO.File]::WriteAllText("$((Join-Path $fileAdsTarget 'payload.txt'))`:ads", 'ads', [Text.UTF8Encoding]::new($false))
    $fileAdsError = Assert-Throws -Message 'plan 后文件新增 ADS 必须使 Apply 失败闭锁' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$fileAdsPlan.planPath) `
            -ApprovedPlanSha256 ([string]$fileAdsPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($fileAdsError -match 'stream|流') '文件 ADS 漂移必须失败闭锁'
    Assert-True ([IO.Directory]::Exists($fileAdsTarget)) '文件 ADS 漂移拒绝不得隔离目标'
    [IO.File]::Delete("$((Join-Path $fileAdsTarget 'payload.txt'))`:ads")

    $legacyApplyTarget = New-StreamSetCandidate -Name 'candidate-apply-legacy'
    $legacyApplyPlan = New-StreamSetPlan -Path $legacyApplyTarget
    $legacyApplyDocument = Read-PlanDocument -PlanPath ([string]$legacyApplyPlan.planPath)
    $null = $legacyApplyDocument.PSObject.Properties.Remove('leafStreamSetV1')
    [IO.File]::WriteAllText(
        [string]$legacyApplyPlan.planPath,
        ($legacyApplyDocument | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))
    $legacyApplySnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$legacyApplyPlan.planPath) `
        -CapabilityRoot $evidenceRoot `
        -AllowedExactPaths @([string]$legacyApplyPlan.planPath) `
        -Name 'safe-delete legacy plan rewrite'
    $legacyApplyError = Assert-Throws -Message '缺失 leafStreamSetV1 的 plan 不得进入 Apply' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$legacyApplyPlan.planPath) `
            -ApprovedPlanSha256 ([string]$legacyApplySnapshot.sha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($legacyApplyError -match 'leafStreamSetV1') 'legacy plan Apply 拒绝必须指向缺失字段'
    Assert-True ([IO.Directory]::Exists($legacyApplyTarget)) 'legacy plan 拒绝不得隔离目标'

    # ---- Slice C：Purge 消费 + 每 leaf 最终 disposition ----
    $purgeTarget = New-StreamSetCandidate -Name 'candidate-purge-ok'
    $purgePlan = New-StreamSetPlan -Path $purgeTarget
    $purgeApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$purgePlan.planPath) `
        -ApprovedPlanSha256 ([string]$purgePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($purgeApply.quarantined -eq $true) 'Purge 前置 Apply 必须成功'
    $purgeResult = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$purgeApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$purgeApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($purgeResult.purged -eq $true) 'stream-set 匹配时 Purge 必须成功'
    Assert-True (
        $null -ne $purgeResult.leafDispositionsPath -and
        $null -ne $purgeResult.leafDispositionsSha256
    ) 'RED: Purge 结果必须携带 leaf dispositions 证据位置'
    $dispositionsPath = [string]$purgeResult.leafDispositionsPath
    Assert-True ([IO.File]::Exists($dispositionsPath)) 'leaf dispositions 证据必须持久化'
    $dispositionsText = [IO.File]::ReadAllText($dispositionsPath, [Text.UTF8Encoding]::new($false))
    $dispositions = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-True (
        [string]$dispositions.artifactType -ceq 'env-governance.codex-safe-tree-delete-leaf-dispositions' -and
        [long]$dispositions.schemaVersion -eq 1L
    ) 'leaf dispositions artifact/schema 必须稳定'
    Assert-True ([string]$dispositions.generationId -ceq [string](Read-PlanDocument -PlanPath ([string]$purgePlan.planPath)).generationId) `
        'leaf dispositions 必须绑定 plan generation'
    Assert-True ([string]$dispositions.planSha256 -ceq [string]$purgePlan.planSha256) 'leaf dispositions 必须绑定 plan SHA-256'
    Assert-True ([string]$dispositions.transactionPath -ceq [string]$purgeApply.transactionPath) 'leaf dispositions 必须绑定 transaction path'
    Assert-True ([string]$dispositions.streamSetSource -ceq 'plan.leafStreamSetV1') 'leaf dispositions 必须声明 stream-set 来源'
    $dispositionRows = @($dispositions.leaves)
    Assert-True ($dispositionRows.Count -eq 2) 'leaf dispositions 必须覆盖每个计划 leaf（两个文件）'
    foreach ($row in $dispositionRows) {
        Assert-True ([string]$row.disposition -ceq 'deleted') '完整 Purge 中每个 leaf 必须是 deleted 终态'
        Assert-True ([string]$row.kind -ceq 'file') 'leaf dispositions 必须记录 leaf kind'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row.evidence)) 'leaf dispositions 必须记录复验证据来源'
    }
    Assert-True ([long]$dispositions.summary.plannedLeaves -eq 2L -and
        [long]$dispositions.summary.deleted -eq 2L -and
        [long]$dispositions.summary.absentAtPurgeResume -eq 0L) 'leaf dispositions summary 必须与 leaf 集合一致'
    $dispositionsSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path $dispositionsPath `
        -CapabilityRoot $evidenceRoot `
        -AllowedExactPaths @($dispositionsPath) `
        -Name 'safe-delete leaf dispositions verify'
    Assert-True ([string]$dispositionsSnapshot.sha256 -ceq [string]$purgeResult.leafDispositionsSha256) `
        'Purge 结果中的 dispositions SHA-256 必须与落盘文件一致'

    # disposition 文档 create-only：相同内容幂等复用，不同内容失败闭锁
    $dispositionsDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $republish = Publish-CodexSafeTreeDeleteLeafDispositions `
        -Document $dispositionsDocument `
        -RunDirectory (Split-Path -Parent $dispositionsPath)
    Assert-True ([string]$republish.sha256 -ceq [string]$purgeResult.leafDispositionsSha256) `
        '相同 dispositions 重发布必须幂等复用首份证据'
    $tamperedDispositionDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $tamperedDispositionDocument.summary.deleted = [long]1
    $republishDriftError = Assert-Throws -Message 'dispositions 漂移重发布必须失败闭锁' -Action {
        [void](Publish-CodexSafeTreeDeleteLeafDispositions `
            -Document $tamperedDispositionDocument `
            -RunDirectory (Split-Path -Parent $dispositionsPath))
    }
    Assert-True ($republishDriftError -match '漂移') 'dispositions 漂移重发布必须返回稳定原因'

    # Publish 校验分组：artifactType 错误或 schemaVersion 非法（类型错或值≠1）即拒绝
    $validationProbeDirectory = Join-Path $fixtureRoot 'publish-validation-probe'
    [void][IO.Directory]::CreateDirectory($validationProbeDirectory)
    $invalidArtifactDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $invalidArtifactDocument.artifactType = 'env-governance.codex-safe-tree-delete-wrong'
    $invalidArtifactDocument.schemaVersion = [int]1
    $invalidArtifactError = Assert-Throws `
        -Message 'artifactType 错误且 schemaVersion 为 int 1 的文档必须被拒绝' `
        -Action {
            [void](Publish-CodexSafeTreeDeleteLeafDispositions `
                -Document $invalidArtifactDocument `
                -RunDirectory $validationProbeDirectory)
        }
    Assert-True ($invalidArtifactError -match 'artifact|schema') 'artifactType 错误必须返回稳定拒绝原因'
    $intSchemaDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $intSchemaDocument.schemaVersion = [int]1
    $intSchemaRepublish = Publish-CodexSafeTreeDeleteLeafDispositions `
        -Document $intSchemaDocument `
        -RunDirectory (Split-Path -Parent $dispositionsPath)
    Assert-True ([string]$intSchemaRepublish.sha256 -ceq [string]$purgeResult.leafDispositionsSha256) `
        'schemaVersion 为 JSON integer 1 的合法文档必须幂等接受'

    # 幂等收口 reader：绑定+载荷双校验（缺失 quarantine 恢复路径消费）
    $dispositionsStreamSet = Read-CodexSafeTreeDeletePlanStreamSet `
        -Plan (Read-PlanDocument -PlanPath ([string]$purgePlan.planPath))
    $readerRunDirectory = Split-Path -Parent $dispositionsPath
    $readerBinding = @{
        RunDirectory = $readerRunDirectory
        GenerationId = [string]$dispositions.generationId
        PlanSha256 = [string]$dispositions.planSha256
        TransactionPath = [string]$dispositions.transactionPath
        QuarantinePath = [string]$dispositions.quarantinePath
        PurgingTransactionUpdatedAtUtc = [string]$dispositions.purgingTransactionUpdatedAtUtc
        PlanStreamSet = $dispositionsStreamSet
    }
    $publishedRead = Read-CodexSafeTreeDeletePublishedLeafDispositions @readerBinding
    Assert-True ([string]$publishedRead.sha256 -ceq [string]$purgeResult.leafDispositionsSha256) `
        '绑定与载荷合法的既有 dispositions 必须幂等复用并返回原 SHA-256'
    Assert-True ([string]$publishedRead.path -ceq [string]$dispositionsPath) `
        'reader 必须返回既有 dispositions 的精确路径'
    $readerProbeDirectory = Join-Path $fixtureRoot 'published-dispositions-reader-probe'
    [void][IO.Directory]::CreateDirectory($readerProbeDirectory)
    $readerProbeBinding = @{
        RunDirectory = $readerProbeDirectory
        GenerationId = [string]$dispositions.generationId
        PlanSha256 = [string]$dispositions.planSha256
        TransactionPath = [string]$dispositions.transactionPath
        QuarantinePath = [string]$dispositions.quarantinePath
        PurgingTransactionUpdatedAtUtc = [string]$dispositions.purgingTransactionUpdatedAtUtc
        PlanStreamSet = $dispositionsStreamSet
    }
    $readerProbePath = Join-Path $readerProbeDirectory 'leaf-dispositions.json'
    $writeReaderProbe = {
        param([object]$Document)
        [IO.File]::WriteAllText(
            $readerProbePath,
            ($Document | ConvertTo-Json -Depth 32),
            [Text.UTF8Encoding]::new($false))
    }
    $payloadShapeDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $null = $payloadShapeDocument.leaves[0].PSObject.Properties.Remove('evidence')
    & $writeReaderProbe $payloadShapeDocument
    $payloadShapeError = Assert-Throws -Message '载荷行缺字段必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePublishedLeafDispositions @readerProbeBinding)
    }
    Assert-True ($payloadShapeError -match '属性集合') '载荷行形状漂移必须失败闭锁'
    $payloadEnumDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $payloadEnumDocument.leaves[0].disposition = 'archived'
    & $writeReaderProbe $payloadEnumDocument
    $payloadEnumError = Assert-Throws -Message '非法 disposition 必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePublishedLeafDispositions @readerProbeBinding)
    }
    Assert-True ($payloadEnumError -match 'disposition') 'disposition 枚举漂移必须失败闭锁'
    $payloadPairDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $payloadPairDocument.leaves[0].evidence = 'purging-subset-resume'
    & $writeReaderProbe $payloadPairDocument
    $payloadPairError = Assert-Throws -Message 'deleted 行携带 resume evidence 必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePublishedLeafDispositions @readerProbeBinding)
    }
    Assert-True ($payloadPairError -match '配对') 'disposition/evidence 非法配对必须失败闭锁'
    $payloadExtraDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $extraRow = $payloadExtraDocument.leaves[0].PSObject.Copy()
    $extraRow.relativePath = 'nested/extra.txt'
    $payloadExtraDocument.leaves = @($payloadExtraDocument.leaves) + @($extraRow)
    & $writeReaderProbe $payloadExtraDocument
    $payloadExtraError = Assert-Throws -Message '计划外载荷行必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePublishedLeafDispositions @readerProbeBinding)
    }
    Assert-True ($payloadExtraError -match '越出|计划') '计划外载荷行必须失败闭锁'
    $payloadMissingDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $payloadMissingDocument.leaves = @(
        $payloadMissingDocument.leaves | Where-Object relativePath -cne 'nested/child.bin'
    )
    & $writeReaderProbe $payloadMissingDocument
    $payloadMissingError = Assert-Throws -Message '缺失已计划 leaf 的载荷必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePublishedLeafDispositions @readerProbeBinding)
    }
    Assert-True ($payloadMissingError -match '覆盖') '载荷未精确覆盖 plan stream-set 必须失败闭锁'
    $payloadSummaryDocument = $dispositionsText | ConvertFrom-Json -Depth 32 -DateKind String
    $payloadSummaryDocument.summary.deleted = [long]0
    & $writeReaderProbe $payloadSummaryDocument
    $payloadSummaryError = Assert-Throws -Message 'summary 与 leaves 行不一致必须被拒绝' -Action {
        [void](Read-CodexSafeTreeDeletePublishedLeafDispositions @readerProbeBinding)
    }
    Assert-True ($payloadSummaryError -match 'summary') 'summary 重述不一致必须失败闭锁'

    # purging 恢复：已删 leaf 记 absent-at-purge-resume，现存 leaf 记 deleted
    $resumeTarget = New-StreamSetCandidate -Name 'candidate-purge-resume'
    $resumePlan = New-StreamSetPlan -Path $resumeTarget
    $resumeApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$resumePlan.planPath) `
        -ApprovedPlanSha256 ([string]$resumePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $resumeTransaction = Get-Content -Raw -LiteralPath ([string]$resumeApply.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    $resumeTransaction.status = 'purging'
    $resumeTransaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $resumeRunDirectory = Split-Path -Parent ([string]$resumeApply.transactionPath)
    Set-CodexHookCapabilityJson `
        -Path ([string]$resumeApply.transactionPath) `
        -Document $resumeTransaction `
        -CapabilityRoot $resumeRunDirectory `
        -AllowedExactPaths @([string]$resumeApply.transactionPath) `
        -Scope 'safe-delete leaf stream-set resume fixture'
    [IO.File]::Delete((Join-Path ([string]$resumeApply.quarantinePath) 'payload.txt'))
    $resumeTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$resumeApply.transactionPath) `
        -CapabilityRoot $resumeRunDirectory `
        -AllowedExactPaths @([string]$resumeApply.transactionPath) `
        -Name 'safe-delete leaf stream-set resume fixture transaction'
    $resumeResult = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$resumeApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$resumeTransactionSnapshot.sha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($resumeResult.purged -eq $true) 'purging 恢复 Purge 必须成功'
    $resumeDispositions = Get-Content -Raw -LiteralPath ([string]$resumeResult.leafDispositionsPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    $absentRow = @($resumeDispositions.leaves | Where-Object relativePath -ceq 'payload.txt')
    $deletedRow = @($resumeDispositions.leaves | Where-Object relativePath -ceq 'nested/child.bin')
    Assert-True ($absentRow.Count -eq 1 -and [string]$absentRow[0].disposition -ceq 'absent-at-purge-resume') `
        '恢复前已删 leaf 必须记为 absent-at-purge-resume，不得冒充本次复验删除'
    Assert-True ($deletedRow.Count -eq 1 -and [string]$deletedRow[0].disposition -ceq 'deleted') `
        '本次删除 leaf 必须记为 deleted'
    Assert-True ([long]$resumeDispositions.summary.deleted -eq 1L -and
        [long]$resumeDispositions.summary.absentAtPurgeResume -eq 1L) '恢复场景 summary 必须分开计数'

    # Purge 冻结窗口内目录新增 ADS → 失败闭锁
    $purgeAdsTarget = New-StreamSetCandidate -Name 'candidate-purge-dir-ads'
    $purgeAdsPlan = New-StreamSetPlan -Path $purgeAdsTarget
    $purgeAdsApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$purgeAdsPlan.planPath) `
        -ApprovedPlanSha256 ([string]$purgeAdsPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $quarantineNested = Join-Path ([string]$purgeAdsApply.quarantinePath) 'nested'
    [IO.File]::WriteAllText("$quarantineNested`:dir-ads", 'ads', [Text.UTF8Encoding]::new($false))
    $purgeAdsError = Assert-Throws -Message 'quarantine 目录新增 ADS 必须使 Purge 失败闭锁' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$purgeAdsApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$purgeAdsApply.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($purgeAdsError -match 'stream|流') 'Purge 目录 ADS 漂移必须经由 stream-set 复验失败'
    Assert-True ([IO.Directory]::Exists([string]$purgeAdsApply.quarantinePath)) 'Purge 目录 ADS 漂移拒绝必须保留 quarantine'
    [IO.File]::Delete("$quarantineNested`:dir-ads")

    # Purge 冻结窗口内文件 mtime 漂移 → FileIdentityV2 复验失败
    $purgeMtimeTarget = New-StreamSetCandidate -Name 'candidate-purge-mtime'
    $purgeMtimePlan = New-StreamSetPlan -Path $purgeMtimeTarget
    $purgeMtimeApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$purgeMtimePlan.planPath) `
        -ApprovedPlanSha256 ([string]$purgeMtimePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    [IO.File]::SetLastWriteTimeUtc(
        (Join-Path ([string]$purgeMtimeApply.quarantinePath) 'payload.txt'),
        [datetime]::new(2026, 8, 14, 4, 5, 6, [DateTimeKind]::Utc))
    $purgeMtimeError = Assert-Throws -Message 'quarantine 文件 mtime 漂移必须使 Purge 失败闭锁' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$purgeMtimeApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$purgeMtimeApply.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($purgeMtimeError -match 'identity|漂移') 'Purge mtime 漂移必须经由 FileIdentityV2 复验失败'
    Assert-True ([IO.Directory]::Exists([string]$purgeMtimeApply.quarantinePath)) 'Purge mtime 漂移拒绝必须保留 quarantine'

    # 在途 legacy transaction（plan 缺 leafStreamSetV1）→ Purge 失败闭锁
    $legacyPurgeTarget = New-StreamSetCandidate -Name 'candidate-purge-legacy'
    $legacyPurgePlan = New-StreamSetPlan -Path $legacyPurgeTarget
    $legacyPurgeApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$legacyPurgePlan.planPath) `
        -ApprovedPlanSha256 ([string]$legacyPurgePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $legacyPurgeDocument = Read-PlanDocument -PlanPath ([string]$legacyPurgePlan.planPath)
    $null = $legacyPurgeDocument.PSObject.Properties.Remove('leafStreamSetV1')
    [IO.File]::WriteAllText(
        [string]$legacyPurgePlan.planPath,
        ($legacyPurgeDocument | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false))
    $legacyPurgePlanSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$legacyPurgePlan.planPath) `
        -CapabilityRoot $evidenceRoot `
        -AllowedExactPaths @([string]$legacyPurgePlan.planPath) `
        -Name 'safe-delete legacy purge plan rewrite'
    $legacyTransaction = Get-Content -Raw -LiteralPath ([string]$legacyPurgeApply.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    $legacyTransaction.planSha256 = [string]$legacyPurgePlanSnapshot.sha256
    $legacyRunDirectory = Split-Path -Parent ([string]$legacyPurgeApply.transactionPath)
    Set-CodexHookCapabilityJson `
        -Path ([string]$legacyPurgeApply.transactionPath) `
        -Document $legacyTransaction `
        -CapabilityRoot $legacyRunDirectory `
        -AllowedExactPaths @([string]$legacyPurgeApply.transactionPath) `
        -Scope 'safe-delete legacy purge fixture'
    $legacyTransactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$legacyPurgeApply.transactionPath) `
        -CapabilityRoot $legacyRunDirectory `
        -AllowedExactPaths @([string]$legacyPurgeApply.transactionPath) `
        -Name 'safe-delete legacy purge fixture transaction'
    $legacyPurgeError = Assert-Throws -Message '在途 legacy transaction 必须使 Purge 失败闭锁' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$legacyPurgeApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$legacyTransactionSnapshot.sha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($legacyPurgeError -match 'leafStreamSetV1') 'legacy transaction Purge 拒绝必须指向缺失字段'
    Assert-True ([IO.Directory]::Exists([string]$legacyPurgeApply.quarantinePath)) 'legacy transaction 拒绝必须保留 quarantine'

    # ---- Slice D：reparse/junction 与 hardlink alias 覆盖 ----
    [void][IO.Directory]::CreateDirectory($linkAwareTargetPath)
    [void][IO.Directory]::CreateDirectory($linkAwareExternalPath)
    [IO.File]::WriteAllText($linkAwareExternalFile, 'must-survive', [Text.UTF8Encoding]::new($false))
    $linkAwarePolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'leaf-stream-set-link-aware'
                capabilityRoot = $linkAwareTargetPath
                minimumDescendantDepth = 0
                rootDeletionPurpose = 'rebuildable-build-output'
                allowHardLinks = $true
                allowInternalDirectoryJunctions = $true
                deniedExactPaths = @()
            }
        )
    }
    [IO.File]::WriteAllText(
        $linkAwarePolicyPath,
        ($linkAwarePolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    [void][IO.Directory]::CreateDirectory($linkAwareInternalPath)
    [IO.File]::WriteAllText(
        (Join-Path $linkAwareInternalPath 'package.json'),
        '{"name":"leaf-stream-set"}',
        [Text.UTF8Encoding]::new($false))
    [void](New-Item -ItemType Junction -Path $linkAwareJunctionPath -Target $linkAwareInternalPath)
    [void](New-Item -ItemType HardLink -Path $linkAwareHardLinkPath -Target $linkAwareExternalFile)
    $linkAwarePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $linkAwareTargetPath `
        -CapabilityRoot $linkAwareTargetPath `
        -FixturePolicyPath $linkAwarePolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($linkAwarePlan.planned -eq $true) 'link-aware Plan 必须成功'
    $linkAwarePlanDocument = Read-PlanDocument -PlanPath ([string]$linkAwarePlan.planPath)
    $junctionLeaf = @($linkAwarePlanDocument.leafStreamSetV1.leaves |
        Where-Object kind -ceq 'directory-junction')
    Assert-True ($junctionLeaf.Count -eq 1) 'stream-set 必须记录 junction leaf'
    Assert-True ([string]$junctionLeaf[0].relativePath -ceq 'linked-package') 'junction leaf 必须按相对路径记录'
    Assert-True (@($junctionLeaf[0].streamNames).Count -eq 0) 'junction leaf 不得携带命名流'
    $hardLinkLeaf = @($linkAwarePlanDocument.leafStreamSetV1.leaves |
        Where-Object relativePath -ceq 'shared-cache.bin')
    Assert-True ($hardLinkLeaf.Count -eq 1) 'stream-set 必须记录 hardlink leaf'
    Assert-True ([long]$hardLinkLeaf[0].hardLinkCount -eq 2L) 'hardlink leaf 必须记录完整 alias 计数 2'

    $linkAwareApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$linkAwarePlan.planPath) `
        -ApprovedPlanSha256 ([string]$linkAwarePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $linkAwarePolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($linkAwareApply.quarantined -eq $true) 'link-aware Apply 必须成功'
    $linkAwarePurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$linkAwareApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$linkAwareApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $linkAwarePolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($linkAwarePurge.purged -eq $true) 'link-aware Purge 必须成功'
    $linkAwareDispositions = Get-Content -Raw -LiteralPath ([string]$linkAwarePurge.leafDispositionsPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    $junctionDisposition = @($linkAwareDispositions.leaves | Where-Object kind -ceq 'directory-junction')
    Assert-True ($junctionDisposition.Count -eq 1 -and
        [string]$junctionDisposition[0].disposition -ceq 'deleted') 'junction leaf 必须有 deleted 终态'
    Assert-True ([IO.File]::ReadAllText($linkAwareExternalFile) -ceq 'must-survive') '外部 hardlink 源文件必须存活'
    [void][IO.Directory]::CreateDirectory($linkAwareTargetPath)

    # hardlink alias 在冻结窗口内变化（目标外新增 alias）→ Apply 失败闭锁
    [void][IO.Directory]::CreateDirectory($linkAwareInternalPath)
    [IO.File]::WriteAllText(
        (Join-Path $linkAwareInternalPath 'package.json'),
        '{"name":"leaf-stream-set-alias"}',
        [Text.UTF8Encoding]::new($false))
    [void](New-Item -ItemType Junction -Path $linkAwareJunctionPath -Target $linkAwareInternalPath)
    [void](New-Item -ItemType HardLink -Path $linkAwareHardLinkPath -Target $linkAwareExternalFile)
    $aliasPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $linkAwareTargetPath `
        -CapabilityRoot $linkAwareTargetPath `
        -FixturePolicyPath $linkAwarePolicyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $outsideAliasPath = Join-Path $linkAwareExternalPath 'outside-alias.bin'
    [void](New-Item -ItemType HardLink -Path $outsideAliasPath -Target $linkAwareExternalFile)
    $aliasError = Assert-Throws -Message '冻结窗口内 hardlink alias 新增必须使 Apply 失败闭锁' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$aliasPlan.planPath) `
            -ApprovedPlanSha256 ([string]$aliasPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $linkAwarePolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($aliasError -match 'hardlink|漂移') 'hardlink alias 漂移必须经由 stream-set 复验失败'
    Assert-True ([IO.Directory]::Exists($linkAwareTargetPath)) 'hardlink alias 漂移拒绝不得隔离目标'
    [IO.File]::Delete($outsideAliasPath)

    # junction 目标被替换 → Apply 失败闭锁（reparse data 漂移）
    & $env:ComSpec /d /c rmdir $linkAwareJunctionPath | Out-Null
    [void][IO.Directory]::CreateDirectory((Join-Path $linkAwareTargetPath '.store\other'))
    [void](New-Item -ItemType Junction -Path $linkAwareJunctionPath -Target (Join-Path $linkAwareTargetPath '.store\other'))
    $junctionReplaceError = Assert-Throws -Message 'junction 替换必须使 Apply 失败闭锁' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$aliasPlan.planPath) `
            -ApprovedPlanSha256 ([string]$aliasPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $linkAwarePolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($junctionReplaceError -match 'reparse|junction|漂移') 'junction 替换必须失败闭锁'
    Assert-True ([IO.Directory]::Exists($linkAwareTargetPath)) 'junction 替换拒绝不得隔离目标'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteLeafStreamSet'
        slices = 4
    }
} finally {
    foreach ($leftoverStream in @(
            "$((Join-Path $fixtureRoot 'candidate-apply-dir-ads\nested'))`:dir-ads",
            "$((Join-Path $fixtureRoot 'candidate-apply-file-ads\payload.txt'))`:ads")) {
        try {
            if ([IO.File]::Exists($leftoverStream)) { [IO.File]::Delete($leftoverStream) }
        } catch { }
    }
    if ([IO.Directory]::Exists($linkAwareJunctionPath)) {
        & $env:ComSpec /d /c rmdir $linkAwareJunctionPath | Out-Null
    }
    foreach ($linkLeftover in @(
            $linkAwareHardLinkPath,
            (Join-Path $linkAwareExternalPath 'outside-alias.bin'))) {
        try {
            if ([IO.File]::Exists($linkLeftover)) { [IO.File]::Delete($linkLeftover) }
        } catch { }
    }
    if ([IO.Directory]::Exists($fixtureRoot)) {
        foreach ($quarantineLeftover in @([IO.Directory]::GetDirectories($fixtureRoot, '.codex-safe-delete-*.quarantine'))) {
            Remove-TestTree -Path $quarantineLeftover
        }
        Remove-TestTree -Path $fixtureRoot
    }
}
