[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (Purge batch / #37):
# 1. New-CodexSafeTreeDeletePurgeFileLeafBatch — List<PurgeFileLeaf> 覆盖全部 file leaf
# 2. Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation — GetHashSafely / PurgeFileHash
# 3. Invoke-CodexSafeTreeDeletePurge — 默认批量 vs -DisablePurgeBatchForTest；journal 仍按项/目录
# 4. Observable Purge 成功/拒绝与 leaf dispositions，不是 cache 内部字典

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$evidenceHome = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'purgebatch'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$nestedPath = Join-Path $targetPath 'nested'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$payloadPath = Join-Path $targetPath 'payload.txt'
$childPath = Join-Path $nestedPath 'child.bin'
$payloadBytes = [Text.Encoding]::UTF8.GetBytes('purge-batch-payload')
$childBytes = [Text.Encoding]::UTF8.GetBytes('purge-batch-child')
$scaleRoot = Join-Path $evidenceHome 'scale-10000'
$scaleBatchTarget = Join-Path $scaleRoot 'candidate-batch'
$scalePhase1Target = Join-Path $scaleRoot 'candidate-phase1'
$scaleBaselineTarget = Join-Path $scaleRoot 'candidate-baseline'

# 每段万文件操作（建树、Plan、Apply、Purge，含 -Disable*ForTest 对照组）前打一行 STAGE，
# scripts/Get-CiTestTiming.ps1 按这些行把 CI 日志里本测试的耗时切成段。
function Write-Stage {
    param([Parameter(Mandatory)][string]$Name)
    Write-Output ("STAGE {0} utc={1}" -f $Name, [datetimeoffset]::UtcNow.ToString('o'))
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-IdentityMismatchException {
    param([Parameter(Mandatory)]$ErrorRecord)

    $current = $ErrorRecord.Exception
    while ($null -ne $current) {
        if ($current -is [CodexSafeTreeDelete.IdentityMismatchException]) {
            return $current
        }
        $current = $current.InnerException
    }
    return $null
}

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
}

function New-FixturePolicy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$DeniedPath,
        [Parameter(Mandatory)][string]$Id
    )

    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = $Id
                capabilityRoot = $CapabilityRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($DeniedPath)
            }
        )
    }
    [IO.File]::WriteAllText(
        $Path,
        ($policy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete purge batch test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete purge batch test cleanup'
}

function New-ScaleTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$FileCount,
        [Parameter(Mandatory)][int]$BytesPerFile
    )

    if ([IO.Directory]::Exists($Path)) {
        Remove-TestTree -Path $Path
    }
    $directoryCount = [Math]::Max(1, [int][Math]::Ceiling($FileCount / 100.0))
    $payload = [byte[]]::new($BytesPerFile)
    for ($index = 0; $index -lt $payload.Length; $index++) {
        $payload[$index] = [byte](($index + 17) % 251)
    }
    $written = 0
    for ($directoryIndex = 0; $directoryIndex -lt $directoryCount -and $written -lt $FileCount; $directoryIndex++) {
        $directory = Join-Path $Path ('d{0:D3}' -f $directoryIndex)
        [void][IO.Directory]::CreateDirectory($directory)
        $remaining = $FileCount - $written
        $batch = [Math]::Min(100, $remaining)
        for ($fileIndex = 0; $fileIndex -lt $batch; $fileIndex++) {
            $filePath = Join-Path $directory ('f{0:D2}.bin' -f $fileIndex)
            [IO.File]::WriteAllBytes($filePath, $payload)
            $written += 1
        }
    }
    return [pscustomobject]@{
        FileCount = $written
        LogicalBytes = [long]$written * [long]$BytesPerFile
    }
}

Write-Stage -Name 'runtime-check'
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
    $drive.DriveFormat -ceq 'NTFS' -or
    $drive.DriveFormat -ceq 'ReFS'
) "本测试要求 NTFS/ReFS，实际为 $($drive.DriveFormat)"

. $hostSafetyLibraryPath
. $libraryPath
Assert-True (
    $null -ne (Get-Command -Name New-CodexSafeTreeDeletePurgeFileLeafBatch -ErrorAction SilentlyContinue)
) 'RED: New-CodexSafeTreeDeletePurgeFileLeafBatch 必须存在'
Assert-True (
    $null -ne (Get-Command -Name Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation -ErrorAction SilentlyContinue)
) 'RED: Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation 必须存在'
Assert-True (
    $null -ne ('CodexSafeTreeDelete.PurgeFileLeaf' -as [type])
) 'RED: CodexSafeTreeDelete.PurgeFileLeaf 必须存在'

$applyResult = $null
$batchPurge = $null
$phase1Purge = $null
$scaleBatchApply = $null
$scalePhase1Apply = $null
$scaleBaselineApply = $null
try {
    Write-Stage -Name 'fixture-cases'
    [void][IO.Directory]::CreateDirectory($nestedPath)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    New-FixturePolicy `
        -Path $policyPath `
        -CapabilityRoot $fixtureRoot `
        -DeniedPath $evidenceRoot `
        -Id 'purge-batch-fixture'

    $planResult = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($planResult.planned -eq $true) 'Plan 必须成功'
    Assert-True ($planResult.fileCount -eq 2) 'Plan 必须包含两个普通文件'
    $plan = Read-JsonDocument -Path ([string]$planResult.planPath)
    $identityMap = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $plan
    $collected = New-CodexSafeTreeDeletePurgeFileLeafBatch `
        -TreePath $targetPath `
        -TreeManifest $plan.treeManifest `
        -ExpectedIdentities $identityMap
    Assert-True ($collected -is [Collections.Generic.List[CodexSafeTreeDelete.PurgeFileLeaf]]) `
        '收集结构必须是 List<PurgeFileLeaf>，不得用过时 ArrayList'
    Assert-True ($collected.Count -eq 2) '收集数组必须覆盖全部 file leaf'
    $collectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($leaf in $collected) {
        [void]$collectedPaths.Add([string]$leaf.RelativePath)
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$leaf.LiteralPath)) '每个 leaf 必须有绝对路径'
        Assert-True ($null -ne $leaf.Identity) '每个 leaf 必须带 FileIdentityV2'
        Assert-True ([IO.File]::Exists([string]$leaf.LiteralPath)) '收集路径必须指向现有 file leaf'
    }
    Assert-True ($collectedPaths.Contains('payload.txt')) '收集必须包含 payload.txt'
    Assert-True ($collectedPaths.Contains('nested/child.bin')) '收集必须包含 nested/child.bin'

    $sessionCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation `
        -Leaves $collected `
        -ExpectedIdentities $identityMap `
        -SessionCache $sessionCache
    $payloadIdentity = $identityMap['payload.txt']
    $cached = $null
    Assert-True ($sessionCache.TryGet($payloadIdentity, [ref]$cached)) `
        '第二遍验证必须走 GetHashSafely / PurgeFileHash 并写入 session cache'

    $applyPlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $applyResult = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$applyPlan.planPath) `
        -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($applyResult.quarantined -eq $true) '批量 Purge 前置 Apply 必须成功'

    $batchEvents = [Collections.Generic.List[string]]::new()
    $observedBatches = [Collections.Generic.List[object]]::new()
    $batchPurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -PurgeFileLeafBatchObserverForTest {
            param($Leaves, $Phase)
            $observedBatches.Add($Leaves)
            $batchEvents.Add([string]$Phase)
        }
    Assert-True ($batchPurge.purged -eq $true) '默认 Purge 必须走批量收集/验证并删完'
    Assert-True ($batchEvents.Contains('collected')) 'Purge 必须先收集 leaf'
    Assert-True ($batchEvents.Contains('validated')) 'Purge 必须在删除前批量验证'
    Assert-True ($observedBatches.Count -ge 1 -and $observedBatches[0].Count -eq 2) `
        'Purge 收集数组必须覆盖 quarantine 内全部 file leaf'
    Assert-True (-not [IO.Directory]::Exists([string]$applyResult.quarantinePath)) '批量 Purge 后 quarantine 必须消失'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) '批量 Purge 后原目标必须保持不存在'
    $batchDispositions = Read-JsonDocument -Path ([string]$batchPurge.leafDispositionsPath)
    Assert-True ([long]$batchDispositions.summary.deleted -eq 2L) '批量 Purge dispositions 必须把每个 leaf 记为 deleted'
    Assert-True ([string]$batchDispositions.streamSetSource -ceq 'plan.leafStreamSetV1') `
        '批量 Purge 必须保持 #54 stream-set 来源'

    [void][IO.Directory]::CreateDirectory($nestedPath)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    $phase1Plan = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $phase1Apply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$phase1Plan.planPath) `
        -ApprovedPlanSha256 ([string]$phase1Plan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $phase1Events = [Collections.Generic.List[string]]::new()
    $phase1Purge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$phase1Apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$phase1Apply.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -DisablePurgeBatchForTest `
        -PurgeFileLeafBatchObserverForTest {
            param($Leaves, $Phase)
            $phase1Events.Add([string]$Phase)
        }
    Assert-True ($phase1Purge.purged -eq $true) 'DisablePurgeBatchForTest 必须仍能删完（Phase 1 控制流）'
    Assert-True ($phase1Events.Count -eq 0) 'DisablePurgeBatchForTest 不得走批量收集/验证'
    $phase1Dispositions = Read-JsonDocument -Path ([string]$phase1Purge.leafDispositionsPath)
    Assert-True ([long]$phase1Dispositions.summary.deleted -eq [long]$batchDispositions.summary.deleted) `
        '批量与逐个 Purge 的 deleted 计数必须相同'
    Assert-True ([string]$phase1Dispositions.streamSetSource -ceq [string]$batchDispositions.streamSetSource) `
        '批量与逐个 Purge 的 stream-set 来源必须相同'
    Assert-True (-not [IO.Directory]::Exists([string]$phase1Apply.quarantinePath)) `
        '逐个 Purge 后 quarantine 必须同样消失'

    [void][IO.Directory]::CreateDirectory($nestedPath)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    $securityPlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $securityApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$securityPlan.planPath) `
        -ApprovedPlanSha256 ([string]$securityPlan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $securityError = $null
    $securityRecord = $null
    try {
        [void](Invoke-CodexSafeTreeDeletePurge `
            -TransactionPath ([string]$securityApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$securityApply.transactionSha256) `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot `
            -BeforePurgeMutexForTest {
                param($Target)
                $quarantinePayloadPath = Join-Path ([string]$securityApply.quarantinePath) 'payload.txt'
                [IO.File]::WriteAllText(
                    $quarantinePayloadPath,
                    'tampered-during-purge-batch',
                    [Text.UTF8Encoding]::new($false))
            })
    } catch {
        $securityError = $_.Exception.Message
        $securityRecord = $_
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($securityError)) '批量 Purge 过程中改文件必须拒绝'
    Assert-True ($securityError -match 'IdentityMismatch') '批量 Purge 必须记录 IdentityMismatch'
    Assert-True ($null -ne (Test-IdentityMismatchException -ErrorRecord $securityRecord)) `
        '批量 Purge 拒绝必须保留 IdentityMismatchException'
    Assert-True ([IO.Directory]::Exists([string]$securityApply.quarantinePath)) `
        'IdentityMismatch 拒绝不得删除 quarantine'
    Remove-TestTree -Path ([string]$securityApply.quarantinePath)

    Write-Stage -Name 'scale-create-batch'
    [void][IO.Directory]::CreateDirectory($scaleRoot)
    $scalePolicyPath = Join-Path $scaleRoot 'policy.json'
    $scaleEvidenceRoot = Join-Path $scaleRoot 'evidence'
    [void][IO.Directory]::CreateDirectory($scaleEvidenceRoot)
    New-FixturePolicy `
        -Path $scalePolicyPath `
        -CapabilityRoot $scaleRoot `
        -DeniedPath $scaleEvidenceRoot `
        -Id 'purge-batch-scale-10000'
    [void](New-ScaleTree -Path $scaleBatchTarget -FileCount 10000 -BytesPerFile 4096)
    Write-Stage -Name 'scale-create-phase1'
    [void](New-ScaleTree -Path $scalePhase1Target -FileCount 10000 -BytesPerFile 4096)
    Write-Stage -Name 'scale-create-baseline'
    [void](New-ScaleTree -Path $scaleBaselineTarget -FileCount 10000 -BytesPerFile 4096)
    Write-Stage -Name 'scale-plan-batch'
    $batchPlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scaleBatchTarget `
        -CapabilityRoot $scaleRoot `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot
    Write-Stage -Name 'scale-plan-phase1'
    $phase1ScalePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scalePhase1Target `
        -CapabilityRoot $scaleRoot `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot
    Write-Stage -Name 'scale-plan-baseline'
    $baselinePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scaleBaselineTarget `
        -CapabilityRoot $scaleRoot `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot
    Write-Stage -Name 'scale-apply-batch'
    $scaleBatchApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$batchPlan.planPath) `
        -ApprovedPlanSha256 ([string]$batchPlan.planSha256) `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot `
        -DisableApplyHashReuseForTest
    Write-Stage -Name 'scale-apply-phase1'
    $scalePhase1Apply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$phase1ScalePlan.planPath) `
        -ApprovedPlanSha256 ([string]$phase1ScalePlan.planSha256) `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot `
        -DisableApplyHashReuseForTest
    Write-Stage -Name 'scale-apply-baseline'
    $scaleBaselineApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$baselinePlan.planPath) `
        -ApprovedPlanSha256 ([string]$baselinePlan.planSha256) `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot `
        -DisableApplyHashReuseForTest
    Assert-True ($scaleBatchApply.quarantined -eq $true) '10k 批量树 Apply 必须成功'
    Assert-True ($scalePhase1Apply.quarantined -eq $true) '10k Phase1 树 Apply 必须成功'
    Assert-True ($scaleBaselineApply.quarantined -eq $true) '10k baseline 树 Apply 必须成功'

    Write-Stage -Name 'scale-purge-batch'
    $scaleBatchPurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$scaleBatchApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$scaleBatchApply.transactionSha256) `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot
    Write-Stage -Name 'scale-purge-phase1'
    $scalePhase1Purge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$scalePhase1Apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$scalePhase1Apply.transactionSha256) `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot `
        -DisablePurgeBatchForTest
    Write-Stage -Name 'scale-purge-baseline'
    $scaleBaselinePurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$scaleBaselineApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$scaleBaselineApply.transactionSha256) `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot `
        -DisablePurgeHashReuseForTest `
        -DisablePurgeBatchForTest
    Assert-True ($scaleBatchPurge.purged -eq $true) '10k 批量 Purge 必须成功'
    Assert-True ($scalePhase1Purge.purged -eq $true) '10k Phase1 Purge 必须成功'
    Assert-True ($scaleBaselinePurge.purged -eq $true) '10k baseline Purge 必须成功'

    Write-Stage -Name 'scale-record'
    $batchMs = [double]$scaleBatchPurge.metrics.elapsedMs
    $phase1Ms = [double]$scalePhase1Purge.metrics.elapsedMs
    $baselineMs = [double]$scaleBaselinePurge.metrics.elapsedMs
    $speedupVsPhase1 = if ($batchMs -gt 0) { $phase1Ms / $batchMs } else { 0 }
    $speedupVsBaseline = if ($batchMs -gt 0) { $baselineMs / $batchMs } else { 0 }
    $scaleRecord = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue37-scale-10000'
        fileCount = 10000
        bytesPerFile = 4096
        method = 'three sibling 10k trees x 4KB; Apply used -DisableApplyHashReuseForTest; Purge batch (default) vs Phase1 (-DisablePurgeBatchForTest) vs baseline (-DisablePurgeHashReuseForTest -DisablePurgeBatchForTest). Not the #36 1.526 GiB pipeline.'
        batchElapsedMs = [long]$scaleBatchPurge.metrics.elapsedMs
        phase1ElapsedMs = [long]$scalePhase1Purge.metrics.elapsedMs
        baselineElapsedMs = [long]$scaleBaselinePurge.metrics.elapsedMs
        batchBytesHashed = [long]$scaleBatchPurge.metrics.bytesHashed
        phase1BytesHashed = [long]$scalePhase1Purge.metrics.bytesHashed
        baselineBytesHashed = [long]$scaleBaselinePurge.metrics.bytesHashed
        speedupVsPhase1 = [Math]::Round($speedupVsPhase1, 3)
        speedupVsBaseline = [Math]::Round($speedupVsBaseline, 3)
        targetVsPhase1 = '1.2-1.5x extra over Phase 1'
        targetVsBaseline = '3.5-4x cumulative over no-reuse baseline'
        metTargetVsPhase1 = ($speedupVsPhase1 -ge 1.2)
        metTargetVsBaseline = ($speedupVsBaseline -ge 3.5)
        metTarget = (($speedupVsPhase1 -ge 1.2) -and ($speedupVsBaseline -ge 3.5))
        note = 'Do not fabricate 1.2x/3.5x. bytesHashed on cache hit still accounts file length.'
    }
    [void][IO.Directory]::CreateDirectory($evidenceHome)
    [IO.File]::WriteAllText(
        (Join-Path $evidenceHome 'scale-10000.json'),
        ($scaleRecord | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))

    Write-Stage -Name 'done'
    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeletePurgeBatch'
        scale10000SpeedupVsPhase1 = $scaleRecord.speedupVsPhase1
        scale10000SpeedupVsBaseline = $scaleRecord.speedupVsBaseline
        scale10000MetTarget = [bool]$scaleRecord.metTarget
        scale10000MetTargetVsPhase1 = [bool]$scaleRecord.metTargetVsPhase1
        scale10000MetTargetVsBaseline = [bool]$scaleRecord.metTargetVsBaseline
    }
} finally {
    $cleanupPaths = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
            $targetPath,
            $scaleBatchTarget,
            $scalePhase1Target,
            $scaleBaselineTarget,
            $fixtureRoot,
            $scaleRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $cleanupPaths.Add($candidate)
        }
    }
    foreach ($result in @(
            $applyResult,
            $batchPurge,
            $phase1Purge,
            $scaleBatchApply,
            $scalePhase1Apply,
            $scaleBaselineApply)) {
        if ($null -ne $result -and
            $result.PSObject.Properties['quarantinePath'] -and
            -not [string]::IsNullOrWhiteSpace([string]$result.quarantinePath)) {
            $cleanupPaths.Add([string]$result.quarantinePath)
        }
    }
    foreach ($path in $cleanupPaths) {
        if ([IO.Directory]::Exists($path)) {
            Remove-TestTree -Path $path
        }
    }
}
