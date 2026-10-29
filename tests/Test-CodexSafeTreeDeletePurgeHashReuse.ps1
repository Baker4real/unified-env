[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (Purge hash reuse / #33):
# 1. Invoke-CodexSafeTreeDeletePurgeFileHash — Plan fileIdentitiesV2 + GetHashSafely
# 2. Invoke-CodexSafeTreeDeletePurge — invocation-local cache, IdentityMismatch, cleanup
# 3. Observable Purge success / rejection and leaf dispositions, not SessionHashCache internals

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$evidenceHome = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'purgehashreuse'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$nestedPath = Join-Path $targetPath 'nested'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$payloadPath = Join-Path $targetPath 'payload.txt'
$childPath = Join-Path $nestedPath 'child.bin'
$payloadBytes = [Text.Encoding]::UTF8.GetBytes('purge-hash-reuse-payload')
$childBytes = [Text.Encoding]::UTF8.GetBytes('purge-hash-reuse-child')
$scale1000Root = Join-Path $evidenceHome 'scale-1000'
$scale10000Root = Join-Path $evidenceHome 'scale-10000'
$scale1000Target = Join-Path $scale1000Root 'candidate'
$scale10000ReuseTarget = Join-Path $scale10000Root 'candidate-reuse'
$scale10000BaselineTarget = Join-Path $scale10000Root 'candidate-baseline'

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

function Invoke-SessionHashCacheTryGet {
    param(
        [Parameter(Mandatory)]$Cache,
        [Parameter(Mandatory)]$Identity
    )

    $hash = $null
    $hit = $Cache.TryGet($Identity, [ref]$hash)
    return [pscustomobject]@{
        Hit = [bool]$hit
        Hash = $hash
    }
}

function Test-ByteArrayEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right) {
        return $false
    }
    return [Linq.Enumerable]::SequenceEqual($Left, $Right)
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
        -Name 'safe-delete purge hash reuse test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete purge hash reuse test cleanup'
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
        $payload[$index] = [byte](($index + 11) % 251)
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

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
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
    $null -ne (Get-Command -Name Get-CodexSafeTreeDeleteHashSafely -ErrorAction SilentlyContinue)
) 'Get-CodexSafeTreeDeleteHashSafely 必须存在'
Assert-True (
    $null -ne (Get-Command -Name ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -ErrorAction SilentlyContinue)
) 'ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap 必须存在'
Assert-True (
    $null -ne (Get-Command -Name Invoke-CodexSafeTreeDeletePurgeFileHash -ErrorAction SilentlyContinue)
) 'RED: Invoke-CodexSafeTreeDeletePurgeFileHash 尚不存在'

$scale1000 = $null
$scale10000 = $null
$applyResult = $null
$purgeResult = $null
$scale1000Apply = $null
$scale1000Purge = $null
$reuseApply = $null
$baselineApply = $null
$reusePurge = $null
$baselinePurge = $null
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
        -Id 'purge-hash-reuse-fixture'

    $planResult = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($planResult.planned -eq $true) 'Plan 必须成功'
    Assert-True ($planResult.fileCount -eq 2) 'Plan 必须包含两个普通文件'
    $plan = Read-JsonDocument -Path ([string]$planResult.planPath)
    Assert-True (@($plan.PSObject.Properties.Name) -contains 'fileIdentitiesV2') 'Plan 必须写出 fileIdentitiesV2'
    Assert-True (@($plan.PSObject.Properties.Name) -contains 'leafStreamSetV1') 'Plan 必须写出 leafStreamSetV1'
    $identityMap = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $plan
    Assert-True ($identityMap.Count -eq 2) 'Purge 必须从 Plan fileIdentitiesV2 读出每个 file 身份'

    $sessionCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $payloadIdentity = $identityMap['payload.txt']
    $beforeFirst = Invoke-SessionHashCacheTryGet -Cache $sessionCache -Identity $payloadIdentity
    Assert-True (-not $beforeFirst.Hit) 'Purge 第一次验证前不得把 Plan 哈希预填进 cache'
    $firstHash = Invoke-CodexSafeTreeDeletePurgeFileHash `
        -LiteralPath $payloadPath `
        -RelativePath 'payload.txt' `
        -ExpectedIdentities $identityMap `
        -SessionCache $sessionCache
    $afterFirst = Invoke-SessionHashCacheTryGet -Cache $sessionCache -Identity $payloadIdentity
    Assert-True $afterFirst.Hit '第一次 GetHashSafely miss 之后 cache 才能有该 identity'
    Assert-True (Test-ByteArrayEqual -Left $firstHash -Right $afterFirst.Hash) '首次 miss 必须把现场计算的哈希写入 cache'

    $secondHash = Invoke-CodexSafeTreeDeletePurgeFileHash `
        -LiteralPath $payloadPath `
        -RelativePath 'payload.txt' `
        -ExpectedIdentities $identityMap `
        -SessionCache $sessionCache
    Assert-True (Test-ByteArrayEqual -Left $firstHash -Right $secondHash) '同一 invocation 内第二次相同 identity 必须 hit 并返回相同哈希'

    $otherIdentity = $identityMap['nested/child.bin']
    $otherBefore = Invoke-SessionHashCacheTryGet -Cache $sessionCache -Identity $otherIdentity
    Assert-True (-not $otherBefore.Hit) '不同 identity 仍必须 miss'
    [void](Invoke-CodexSafeTreeDeletePurgeFileHash `
        -LiteralPath $childPath `
        -RelativePath 'nested/child.bin' `
        -ExpectedIdentities $identityMap `
        -SessionCache $sessionCache)

    $crossCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $crossBefore = Invoke-SessionHashCacheTryGet -Cache $crossCache -Identity $payloadIdentity
    Assert-True (-not $crossBefore.Hit) '跨 invocation 的新 SessionHashCache 必须从空开始'
    $crossHash = Invoke-CodexSafeTreeDeletePurgeFileHash `
        -LiteralPath $payloadPath `
        -RelativePath 'payload.txt' `
        -ExpectedIdentities $identityMap `
        -SessionCache $crossCache
    Assert-True (Test-ByteArrayEqual -Left $firstHash -Right $crossHash) '跨 invocation 再次 miss 必须重新计算同一哈希'
    $crossAfter = Invoke-SessionHashCacheTryGet -Cache $crossCache -Identity $payloadIdentity
    Assert-True $crossAfter.Hit '跨 invocation 的 miss 只能写入自己的 cache'

    $missingError = Assert-Throws -Message '缺少 fileIdentitiesV2 记录必须拒绝' -Action {
        [void](Invoke-CodexSafeTreeDeletePurgeFileHash `
            -LiteralPath $payloadPath `
            -RelativePath 'missing.txt' `
            -ExpectedIdentities $identityMap `
            -SessionCache $sessionCache)
    }
    Assert-True ($missingError -match 'fileIdentitiesV2') '缺少身份必须指向 fileIdentitiesV2'

    $mismatchCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    [IO.File]::WriteAllText($payloadPath, 'tampered-before-purge-hash', [Text.UTF8Encoding]::new($false))
    $mismatchError = $null
    $mismatchRecord = $null
    try {
        [void](Invoke-CodexSafeTreeDeletePurgeFileHash `
            -LiteralPath $payloadPath `
            -RelativePath 'payload.txt' `
            -ExpectedIdentities $identityMap `
            -SessionCache $mismatchCache)
    } catch {
        $mismatchError = $_.Exception.Message
        $mismatchRecord = $_
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($mismatchError)) '文件身份漂移必须拒绝 Purge 哈希验证'
    Assert-True ($mismatchError -match 'IdentityMismatch') 'IdentityMismatch 必须被记录'
    Assert-True ($null -ne (Test-IdentityMismatchException -ErrorRecord $mismatchRecord)) `
        'IdentityMismatchException 必须保留在异常链中'
    $afterMismatch = Invoke-SessionHashCacheTryGet -Cache $mismatchCache -Identity $payloadIdentity
    Assert-True (-not $afterMismatch.Hit) 'IdentityMismatch 不得把错误 identity 写入 cache'
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)

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
    Assert-True ($applyResult.quarantined -eq $true) 'Purge 前置 Apply 必须成功'
    $applyPlanDocument = Read-JsonDocument -Path ([string]$applyPlan.planPath)
    $applyIdentityMap = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $applyPlanDocument
    $quarantinePayload = Join-Path ([string]$applyResult.quarantinePath) 'payload.txt'
    $liveIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $quarantinePayload

    $purgeCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $beforePurge = Invoke-SessionHashCacheTryGet -Cache $purgeCache -Identity $liveIdentity
    Assert-True (-not $beforePurge.Hit) '独立 Purge invocation 不得继承 Apply cache'
    $checkpointHits = [Collections.Generic.List[bool]]::new()
    $purgeResult = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -SessionHashCacheForTest $purgeCache `
        -BeforeDirectoryTreeDeleteForTest {
            param($Quarantine)
            $identity = Get-CodexSafeTreeDeleteFileIdentityV2 `
                -LiteralPath (Join-Path $Quarantine 'payload.txt')
            $checkpointHits.Add(
                [bool]((Invoke-SessionHashCacheTryGet -Cache $purgeCache -Identity $identity).Hit))
        }
    Assert-True ($purgeResult.purged -eq $true) 'Purge 必须在 GetHashSafely 路径上成功删完'
    Assert-True ($checkpointHits.Count -eq 1 -and $checkpointHits[0]) `
        '同一 Purge invocation 内 snapshot 之后的后续访问必须 hit SessionHashCache'
    $afterPurge = Invoke-SessionHashCacheTryGet -Cache $purgeCache -Identity $liveIdentity
    Assert-True (-not $afterPurge.Hit) 'Purge 正常完成时必须清理 SessionHashCache'
    Assert-True (-not [IO.Directory]::Exists([string]$applyResult.quarantinePath)) 'Purge 成功后 quarantine 必须消失'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) 'Purge 成功后原目标必须保持不存在'
    Assert-True (
        -not [string]::IsNullOrWhiteSpace([string]$purgeResult.leafDispositionsPath) -and
        [IO.File]::Exists([string]$purgeResult.leafDispositionsPath)
    ) 'Purge 必须发布 leaf-dispositions.json'
    $dispositions = Read-JsonDocument -Path ([string]$purgeResult.leafDispositionsPath)
    Assert-True ([string]$dispositions.streamSetSource -ceq 'plan.leafStreamSetV1') `
        'leaf dispositions 必须声明 stream-set 来源'
    foreach ($row in @($dispositions.leaves)) {
        Assert-True ([string]$row.disposition -ceq 'deleted') '完整 Purge 中每个 leaf 必须是 deleted'
        Assert-True ([string]$row.disposition -cnotin @('unknown', 'error')) 'unknown/error disposition 不得放行删除'
    }

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
    Assert-True ($securityApply.quarantined -eq $true) 'IdentityMismatch 用例的 Apply 必须成功'
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
                    'tampered-during-purge',
                    [Text.UTF8Encoding]::new($false))
            })
    } catch {
        $securityError = $_.Exception.Message
        $securityRecord = $_
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($securityError)) 'Purge 过程中改文件必须拒绝'
    Assert-True ($securityError -match 'IdentityMismatch') 'Purge 过程中改文件必须记录 IdentityMismatch'
    Assert-True ($null -ne (Test-IdentityMismatchException -ErrorRecord $securityRecord)) `
        'Purge 拒绝必须保留 IdentityMismatchException'
    Assert-True ([IO.Directory]::Exists([string]$securityApply.quarantinePath)) `
        'IdentityMismatch 拒绝不得删除 quarantine'
    Remove-TestTree -Path ([string]$securityApply.quarantinePath)

    [void][IO.Directory]::CreateDirectory($nestedPath)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    $streamDriftPlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $streamDriftApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$streamDriftPlan.planPath) `
        -ApprovedPlanSha256 ([string]$streamDriftPlan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $streamDriftError = Assert-Throws -Message 'Purge stream-set 漂移必须失败闭锁' -Action {
        [void](Invoke-CodexSafeTreeDeletePurge `
            -TransactionPath ([string]$streamDriftApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$streamDriftApply.transactionSha256) `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot `
            -BeforePurgeMutexForTest {
                param($Target)
                $quarantineNested = Join-Path ([string]$streamDriftApply.quarantinePath) 'nested'
                [IO.File]::WriteAllText("$quarantineNested`:dir-ads", 'ads', [Text.UTF8Encoding]::new($false))
            })
    }
    Assert-True ($streamDriftError -match 'stream|流') 'Purge stream-set/freeze 漂移必须记录稳定拒绝'
    Assert-True ([IO.Directory]::Exists([string]$streamDriftApply.quarantinePath)) `
        'stream-set 拒绝不得删除 quarantine'
    Remove-TestTree -Path ([string]$streamDriftApply.quarantinePath)

    Write-Stage -Name 'scale-1000'
    [void][IO.Directory]::CreateDirectory($scale1000Root)
    $scale1000PolicyPath = Join-Path $scale1000Root 'policy.json'
    $scale1000EvidenceRoot = Join-Path $scale1000Root 'evidence'
    [void][IO.Directory]::CreateDirectory($scale1000EvidenceRoot)
    New-FixturePolicy `
        -Path $scale1000PolicyPath `
        -CapabilityRoot $scale1000Root `
        -DeniedPath $scale1000EvidenceRoot `
        -Id 'purge-hash-reuse-scale-1000'
    $scale1000 = New-ScaleTree -Path $scale1000Target -FileCount 1000 -BytesPerFile 64
    $scale1000Plan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scale1000Target `
        -CapabilityRoot $scale1000Root `
        -PolicyPath $scale1000PolicyPath `
        -EvidenceRoot $scale1000EvidenceRoot
    Assert-True ($scale1000Plan.fileCount -eq 1000) '1000 文件 Plan 必须覆盖全部 file'
    $scale1000Apply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$scale1000Plan.planPath) `
        -ApprovedPlanSha256 ([string]$scale1000Plan.planSha256) `
        -PolicyPath $scale1000PolicyPath `
        -EvidenceRoot $scale1000EvidenceRoot
    Assert-True ($scale1000Apply.quarantined -eq $true) '1000 文件 Plan→Apply 必须成功'
    $scale1000Purge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$scale1000Apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$scale1000Apply.transactionSha256) `
        -PolicyPath $scale1000PolicyPath `
        -EvidenceRoot $scale1000EvidenceRoot
    Assert-True ($scale1000Purge.purged -eq $true) '1000 文件 Plan→Apply→Purge 必须成功'
    Assert-True (-not [IO.Directory]::Exists($scale1000Target)) '1000 文件 Purge 后原目标必须不存在'
    Assert-True (-not [IO.Directory]::Exists([string]$scale1000Apply.quarantinePath)) `
        '1000 文件 Purge 后 quarantine 必须不存在'
    $scale1000Dispositions = Read-JsonDocument -Path ([string]$scale1000Purge.leafDispositionsPath)
    Assert-True ([string]$scale1000Dispositions.streamSetSource -ceq 'plan.leafStreamSetV1') `
        '1000 文件 leaf dispositions 必须保持 #54 stream-set 来源'
    Assert-True ([long]$scale1000Dispositions.summary.plannedLeaves -eq 1000L) `
        '1000 文件 leaf dispositions 必须覆盖全部 file leaf'
    Assert-True ([long]$scale1000Dispositions.summary.deleted -eq 1000L) `
        '1000 文件 Purge 必须把每个 leaf 记为 deleted'
    Assert-True ([long]$scale1000Dispositions.summary.absentAtPurgeResume -eq 0L) `
        '1000 文件完整 Purge 不得出现 absent-at-purge-resume'
    $scale1000Record = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue33-scale-1000'
        fileCount = [int]$scale1000.FileCount
        logicalBytes = [long]$scale1000.LogicalBytes
        applyElapsedMs = [long]$scale1000Apply.metrics.elapsedMs
        purgeElapsedMs = [long]$scale1000Purge.metrics.elapsedMs
        purgeBytesHashed = [long]$scale1000Purge.metrics.bytesHashed
        purged = [bool]$scale1000Purge.purged
        leafDispositionsDeleted = [long]$scale1000Dispositions.summary.deleted
        streamSetSource = [string]$scale1000Dispositions.streamSetSource
    }
    [IO.File]::WriteAllText(
        (Join-Path $evidenceHome 'scale-1000.json'),
        ($scale1000Record | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))

    Write-Stage -Name 'scale-create-reuse'
    [void][IO.Directory]::CreateDirectory($scale10000Root)
    $scale10000PolicyPath = Join-Path $scale10000Root 'policy.json'
    $scale10000EvidenceRoot = Join-Path $scale10000Root 'evidence'
    [void][IO.Directory]::CreateDirectory($scale10000EvidenceRoot)
    New-FixturePolicy `
        -Path $scale10000PolicyPath `
        -CapabilityRoot $scale10000Root `
        -DeniedPath $scale10000EvidenceRoot `
        -Id 'purge-hash-reuse-scale-10000'
    $scale10000 = New-ScaleTree -Path $scale10000ReuseTarget -FileCount 10000 -BytesPerFile 4096
    Write-Stage -Name 'scale-create-baseline'
    [void](New-ScaleTree -Path $scale10000BaselineTarget -FileCount 10000 -BytesPerFile 4096)
    Write-Stage -Name 'scale-plan-reuse'
    $reusePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scale10000ReuseTarget `
        -CapabilityRoot $scale10000Root `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    Write-Stage -Name 'scale-plan-baseline'
    $baselinePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scale10000BaselineTarget `
        -CapabilityRoot $scale10000Root `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    Write-Stage -Name 'scale-apply-reuse'
    $reuseApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$reusePlan.planPath) `
        -ApprovedPlanSha256 ([string]$reusePlan.planSha256) `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    Write-Stage -Name 'scale-apply-baseline'
    $baselineApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$baselinePlan.planPath) `
        -ApprovedPlanSha256 ([string]$baselinePlan.planSha256) `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    Assert-True ($reuseApply.quarantined -eq $true) '10k 文件 Apply（reuse 树）必须成功'
    Assert-True ($baselineApply.quarantined -eq $true) '10k 文件 Apply（baseline 树）必须成功'
    Write-Stage -Name 'scale-purge-reuse'
    $reusePurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$reuseApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$reuseApply.transactionSha256) `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    Write-Stage -Name 'scale-purge-baseline'
    $baselinePurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$baselineApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$baselineApply.transactionSha256) `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot `
        -DisablePurgeHashReuseForTest
    Assert-True ($reusePurge.purged -eq $true) '10k 文件 Purge（复用）必须成功'
    Assert-True ($baselinePurge.purged -eq $true) '10k 文件 Purge（无复用 baseline）必须成功'
    Write-Stage -Name 'scale-record'
    $reuseMs = [double]$reusePurge.metrics.elapsedMs
    $baselineMs = [double]$baselinePurge.metrics.elapsedMs
    $speedup = if ($reuseMs -gt 0) { $baselineMs / $reuseMs } else { 0 }
    $scale10000Record = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue33-scale-10000'
        fileCount = 10000
        bytesPerFile = 4096
        method = 'two sibling 10k trees; Purge with SessionHashCache vs -DisablePurgeHashReuseForTest; Apply setup used the default hash-reuse path'
        reuseElapsedMs = [long]$reusePurge.metrics.elapsedMs
        baselineElapsedMs = [long]$baselinePurge.metrics.elapsedMs
        reuseBytesHashed = [long]$reusePurge.metrics.bytesHashed
        baselineBytesHashed = [long]$baselinePurge.metrics.bytesHashed
        speedup = [Math]::Round($speedup, 3)
        targetRange = 'report hash-reuse gain; ticket does not require 1.5-2x'
        metTarget = ($speedup -ge 1.0)
        note = 'bytesHashed on cache hit still accounts file length; not physical bytes read'
    }
    [IO.File]::WriteAllText(
        (Join-Path $evidenceHome 'scale-10000.json'),
        ($scale10000Record | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))

    Write-Stage -Name 'done'
    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeletePurgeHashReuse'
        scale1000ElapsedMs = [long]$scale1000Purge.metrics.elapsedMs
        scale10000Speedup = $scale10000Record.speedup
        scale10000MetTarget = [bool]$scale10000Record.metTarget
    }
} finally {
    $cleanupPaths = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
            $targetPath,
            $scale1000Target,
            $scale10000ReuseTarget,
            $scale10000BaselineTarget,
            $fixtureRoot,
            $scale1000Root,
            $scale10000Root)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $cleanupPaths.Add($candidate)
        }
    }
    foreach ($result in @(
            $applyResult,
            $purgeResult,
            $scale1000Apply,
            $reuseApply,
            $baselineApply)) {
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
