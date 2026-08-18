[CmdletBinding()]
param(
    [switch]$SkipScale
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (Apply hash reuse / #32 + #42 lease window):
# 1. Invoke-CodexSafeTreeDeleteApplyFileHash — Plan fileIdentitiesV2 + GetHashSafely
#    or optional live SafeTreeDeleteFileLease (identity + cache + ComputeSha256FromHandle)
# 2. Get-CodexHookCapabilityDirectoryTreeSnapshot FileContentHashProvider — 4-arg
#    lease while still held; provider must be able to hash from that handle
# 3. Invoke-CodexSafeTreeDeleteQuarantine — session cache, IdentityMismatch, cleanup
# 4. Observable Apply success / rejection, not SessionHashCache internals
# -SkipScale skips the 1k/10k Apply wall-clock slices.

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$evidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue32-20260817'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$nestedPath = Join-Path $targetPath 'nested'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$payloadPath = Join-Path $targetPath 'payload.txt'
$childPath = Join-Path $nestedPath 'child.bin'
$payloadBytes = [Text.Encoding]::UTF8.GetBytes('apply-hash-reuse-payload')
$childBytes = [Text.Encoding]::UTF8.GetBytes('apply-hash-reuse-child')
$scale1000Root = Join-Path $evidenceHome 'scale-1000'
$scale10000Root = Join-Path $evidenceHome 'scale-10000'
$scale1000Target = Join-Path $scale1000Root 'candidate'
$scale10000ReuseTarget = Join-Path $scale10000Root 'candidate-reuse'
$scale10000BaselineTarget = Join-Path $scale10000Root 'candidate-baseline'

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
        -Name 'safe-delete apply hash reuse test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete apply hash reuse test cleanup'
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
        $payload[$index] = [byte](($index + 7) % 251)
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
    $null -ne (Get-Command -Name Invoke-CodexSafeTreeDeleteApplyFileHash -ErrorAction SilentlyContinue)
) 'RED: Invoke-CodexSafeTreeDeleteApplyFileHash 尚不存在'
Assert-True (
    $null -ne (Get-Command -Name ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -ErrorAction SilentlyContinue)
) 'RED: ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap 尚不存在'

$scale1000 = $null
$scale10000 = $null
$applyResult = $null
$scale1000Apply = $null
$reuseApply = $null
$baselineApply = $null
try {
    [void][IO.Directory]::CreateDirectory($nestedPath)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    New-FixturePolicy `
        -Path $policyPath `
        -CapabilityRoot $fixtureRoot `
        -DeniedPath $evidenceRoot `
        -Id 'apply-hash-reuse-fixture'

    $planResult = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($planResult.planned -eq $true) 'Plan 必须成功'
    Assert-True ($planResult.fileCount -eq 2) 'Plan 必须包含两个普通文件'
    $plan = Get-Content -Raw -LiteralPath ([string]$planResult.planPath) |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $identityMap = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $plan
    Assert-True ($identityMap.Count -eq 2) 'Apply 必须从 Plan fileIdentitiesV2 读出每个 file 身份'

    $sessionCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $payloadIdentity = $identityMap['payload.txt']
    $beforeFirst = Invoke-SessionHashCacheTryGet -Cache $sessionCache -Identity $payloadIdentity
    Assert-True (-not $beforeFirst.Hit) 'Apply 第一次验证前不得把 Plan 哈希预填进 cache'
    $firstHash = Invoke-CodexSafeTreeDeleteApplyFileHash `
        -LiteralPath $payloadPath `
        -RelativePath 'payload.txt' `
        -ExpectedIdentities $identityMap `
        -SessionCache $sessionCache
    $afterFirst = Invoke-SessionHashCacheTryGet -Cache $sessionCache -Identity $payloadIdentity
    Assert-True $afterFirst.Hit '第一次 GetHashSafely miss 之后 cache 才能有该 identity'
    Assert-True (Test-ByteArrayEqual -Left $firstHash -Right $afterFirst.Hash) '首次 miss 必须把现场计算的哈希写入 cache'

    $secondHash = Invoke-CodexSafeTreeDeleteApplyFileHash `
        -LiteralPath $payloadPath `
        -RelativePath 'payload.txt' `
        -ExpectedIdentities $identityMap `
        -SessionCache $sessionCache
    Assert-True (Test-ByteArrayEqual -Left $firstHash -Right $secondHash) '同一 invocation 内第二次相同 identity 必须 hit 并返回相同哈希'

    $otherIdentity = $identityMap['nested/child.bin']
    $otherBefore = Invoke-SessionHashCacheTryGet -Cache $sessionCache -Identity $otherIdentity
    Assert-True (-not $otherBefore.Hit) '不同 identity 仍必须 miss'
    [void](Invoke-CodexSafeTreeDeleteApplyFileHash `
        -LiteralPath $childPath `
        -RelativePath 'nested/child.bin' `
        -ExpectedIdentities $identityMap `
        -SessionCache $sessionCache)

    $missingError = Assert-Throws -Message '缺少 fileIdentitiesV2 记录必须拒绝' -Action {
        [void](Invoke-CodexSafeTreeDeleteApplyFileHash `
            -LiteralPath $payloadPath `
            -RelativePath 'missing.txt' `
            -ExpectedIdentities $identityMap `
            -SessionCache $sessionCache)
    }
    Assert-True ($missingError -match 'fileIdentitiesV2') '缺少身份必须指向 fileIdentitiesV2'

    $providerCalls = [Collections.Generic.List[object]]::new()
    $recordingProvider = {
        param([string]$LiteralPath, [string]$RelativePath, [long]$Length, $Lease)
        $canHash = $false
        [byte[]]$hash = $null
        if ($null -ne $Lease) {
            $hash = $Lease.ComputeSha256FromHandle()
            $canHash = ($null -ne $hash -and $hash.Length -eq 32)
        }
        $providerCalls.Add([pscustomobject]@{
            RelativePath = $RelativePath
            HasLease = ($null -ne $Lease)
            LeaseCanComputeSha256 = $canHash
        })
        if ($null -eq $hash -or $hash.Length -ne 32) {
            throw 'recording provider 必须拿到仍可用的 lease 才能算 SHA-256'
        }
        return ,$hash
    }.GetNewClosure()
    $leaseSnapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $targetPath `
        -CapabilityRoot $fixtureRoot `
        -AllowedExactPaths @($targetPath) `
        -FileContentHashProvider $recordingProvider `
        -Name 'safe-delete apply hash reuse lease snapshot'
    Assert-True ($leaseSnapshot.entries.Count -ge 2) 'lease snapshot 必须包含 file 条目'
    Assert-True ($providerCalls.Count -eq 2) 'snapshot 必须对每个 file 调用 provider'
    foreach ($call in $providerCalls) {
        Assert-True ([bool]$call.HasLease) (
            "FileContentHashProvider 必须在 lease 仍持有时收到第 4 参：$($call.RelativePath)"
        )
        Assert-True ([bool]$call.LeaseCanComputeSha256) (
            "第 4 参 lease 在 provider 调用期间必须仍可 ComputeSha256FromHandle：$($call.RelativePath)"
        )
    }

    $parentGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire(
        $fixtureRoot,
        $targetPath,
        $false)
    $heldLease = $null
    try {
        $heldLease = $parentGuard.AcquireSafeTreeDeleteFileLease($payloadPath, $false)
        $leaseCache = [CodexSafeTreeDelete.SessionHashCache]::new()
        $leaseHash = Invoke-CodexSafeTreeDeleteApplyFileHash `
            -LiteralPath $payloadPath `
            -RelativePath 'payload.txt' `
            -ExpectedIdentities $identityMap `
            -SessionCache $leaseCache `
            -Lease $heldLease
        $afterLease = Invoke-SessionHashCacheTryGet -Cache $leaseCache -Identity $payloadIdentity
        Assert-True ($null -ne $leaseHash -and $leaseHash.Length -eq 32) (
            '持有 lease 时 Apply 哈希必须成功，且不得再 GetHashSafely FileShare.None 重开'
        )
        Assert-True $afterLease.Hit 'lease miss 必须把同一 handle 算出的哈希写入 SessionHashCache'
        Assert-True (Test-ByteArrayEqual -Left $leaseHash -Right $afterLease.Hash) (
            'lease miss 写入 cache 的哈希必须与返回值相同'
        )
        $leaseHashHit = Invoke-CodexSafeTreeDeleteApplyFileHash `
            -LiteralPath $payloadPath `
            -RelativePath 'payload.txt' `
            -ExpectedIdentities $identityMap `
            -SessionCache $leaseCache `
            -Lease $heldLease
        Assert-True (Test-ByteArrayEqual -Left $leaseHash -Right $leaseHashHit) (
            '同一 lease 第二次必须 cache hit，不得再读内容'
        )
    } finally {
        if ($null -ne $heldLease) { $heldLease.Dispose() }
        $parentGuard.Dispose()
    }

    $mismatchCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    [IO.File]::WriteAllText($payloadPath, 'tampered-before-hash', [Text.UTF8Encoding]::new($false))
    $mismatchError = $null
    $mismatchRecord = $null
    try {
        [void](Invoke-CodexSafeTreeDeleteApplyFileHash `
            -LiteralPath $payloadPath `
            -RelativePath 'payload.txt' `
            -ExpectedIdentities $identityMap `
            -SessionCache $mismatchCache)
    } catch {
        $mismatchError = $_.Exception.Message
        $mismatchRecord = $_
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($mismatchError)) '文件身份漂移必须拒绝 Apply 哈希验证'
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
    $applyPlanDocument = Get-Content -Raw -LiteralPath ([string]$applyPlan.planPath) |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $applyIdentityMap = ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap -Plan $applyPlanDocument
    $applyPayloadIdentity = $applyIdentityMap['payload.txt']

    $applyCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $checkpointHits = [Collections.Generic.List[bool]]::new()
    $applyResult = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$applyPlan.planPath) `
        -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -SessionHashCacheForTest $applyCache `
        -QuarantineCheckpointForTest {
            param($Target, $Quarantine, $Stage)
            $liveIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 `
                -LiteralPath (Join-Path $Quarantine 'payload.txt')
            $checkpointHits.Add(
                [bool]((Invoke-SessionHashCacheTryGet -Cache $applyCache -Identity $liveIdentity).Hit))
        }
    Assert-True ($applyResult.quarantined -eq $true) 'Apply 必须在 GetHashSafely 路径上成功'
    Assert-True ($checkpointHits.Count -eq 1 -and $checkpointHits[0]) `
        '同一 Apply invocation 内重复验证必须 hit SessionHashCache'
    $afterApply = Invoke-SessionHashCacheTryGet -Cache $applyCache -Identity $applyPayloadIdentity
    Assert-True (-not $afterApply.Hit) 'Apply 正常完成时必须清理 SessionHashCache'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) 'Apply 成功后 quarantine 必须存在'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) 'Apply 成功后原目标必须移走'
    Remove-TestTree -Path ([string]$applyResult.quarantinePath)

    [void][IO.Directory]::CreateDirectory($nestedPath)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    $securityPlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $securityError = $null
    $securityRecord = $null
    try {
        [void](Invoke-CodexSafeTreeDeleteQuarantine `
            -PlanPath ([string]$securityPlan.planPath) `
            -ApprovedPlanSha256 ([string]$securityPlan.planSha256) `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot `
            -BeforeQuarantineMutexForTest {
                param($Target, $Quarantine)
                [IO.File]::WriteAllText(
                    (Join-Path $Target 'payload.txt'),
                    'tampered-during-apply',
                    [Text.UTF8Encoding]::new($false))
            })
    } catch {
        $securityError = $_.Exception.Message
        $securityRecord = $_
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($securityError)) 'Apply 过程中改文件必须拒绝'
    Assert-True ($securityError -match 'IdentityMismatch') 'Apply 过程中改文件必须记录 IdentityMismatch'
    Assert-True ($null -ne (Test-IdentityMismatchException -ErrorRecord $securityRecord)) `
        'Apply 拒绝必须保留 IdentityMismatchException'
    Assert-True ([IO.Directory]::Exists($targetPath)) 'IdentityMismatch 拒绝不得隔离目标'

    $scale10000Record = $null
    if ($SkipScale) {
        [pscustomobject][ordered]@{
            ok = $true
            suite = 'CodexSafeTreeDeleteHashReuse'
            skipScale = $true
            scale1000ElapsedMs = $null
            scale10000Speedup = $null
            scale10000MetTarget = $null
        }
        return
    }

    [void][IO.Directory]::CreateDirectory($scale1000Root)
    $scale1000PolicyPath = Join-Path $scale1000Root 'policy.json'
    $scale1000EvidenceRoot = Join-Path $scale1000Root 'evidence'
    [void][IO.Directory]::CreateDirectory($scale1000EvidenceRoot)
    New-FixturePolicy `
        -Path $scale1000PolicyPath `
        -CapabilityRoot $scale1000Root `
        -DeniedPath $scale1000EvidenceRoot `
        -Id 'apply-hash-reuse-scale-1000'
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
    Assert-True (-not [IO.Directory]::Exists($scale1000Target)) '1000 文件 Apply 后原目标必须移走'
    $scale1000Record = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue32-scale-1000'
        fileCount = [int]$scale1000.FileCount
        logicalBytes = [long]$scale1000.LogicalBytes
        applyElapsedMs = [long]$scale1000Apply.metrics.elapsedMs
        applyBytesHashed = [long]$scale1000Apply.metrics.bytesHashed
        quarantined = [bool]$scale1000Apply.quarantined
    }
    [IO.File]::WriteAllText(
        (Join-Path $evidenceHome 'scale-1000.json'),
        ($scale1000Record | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
    Remove-TestTree -Path ([string]$scale1000Apply.quarantinePath)

    [void][IO.Directory]::CreateDirectory($scale10000Root)
    $scale10000PolicyPath = Join-Path $scale10000Root 'policy.json'
    $scale10000EvidenceRoot = Join-Path $scale10000Root 'evidence'
    [void][IO.Directory]::CreateDirectory($scale10000EvidenceRoot)
    New-FixturePolicy `
        -Path $scale10000PolicyPath `
        -CapabilityRoot $scale10000Root `
        -DeniedPath $scale10000EvidenceRoot `
        -Id 'apply-hash-reuse-scale-10000'
    $scale10000 = New-ScaleTree -Path $scale10000ReuseTarget -FileCount 10000 -BytesPerFile 4096
    [void](New-ScaleTree -Path $scale10000BaselineTarget -FileCount 10000 -BytesPerFile 4096)
    $reusePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scale10000ReuseTarget `
        -CapabilityRoot $scale10000Root `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    $baselinePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $scale10000BaselineTarget `
        -CapabilityRoot $scale10000Root `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    $reuseApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$reusePlan.planPath) `
        -ApprovedPlanSha256 ([string]$reusePlan.planSha256) `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot
    $baselineApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$baselinePlan.planPath) `
        -ApprovedPlanSha256 ([string]$baselinePlan.planSha256) `
        -PolicyPath $scale10000PolicyPath `
        -EvidenceRoot $scale10000EvidenceRoot `
        -DisableApplyHashReuseForTest
    Assert-True ($reuseApply.quarantined -eq $true) '10k 文件 Apply（复用）必须成功'
    Assert-True ($baselineApply.quarantined -eq $true) '10k 文件 Apply（无复用 baseline）必须成功'
    $reuseMs = [double]$reuseApply.metrics.elapsedMs
    $baselineMs = [double]$baselineApply.metrics.elapsedMs
    $speedup = if ($reuseMs -gt 0) { $baselineMs / $reuseMs } else { 0 }
    $scale10000Record = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue32-scale-10000'
        fileCount = 10000
        bytesPerFile = 4096
        method = 'two sibling 10k trees; Apply with SessionHashCache vs -DisableApplyHashReuseForTest'
        reuseElapsedMs = [long]$reuseApply.metrics.elapsedMs
        baselineElapsedMs = [long]$baselineApply.metrics.elapsedMs
        reuseBytesHashed = [long]$reuseApply.metrics.bytesHashed
        baselineBytesHashed = [long]$baselineApply.metrics.bytesHashed
        speedup = [Math]::Round($speedup, 3)
        targetRange = '1.5-2x vs no-reuse baseline'
        metTarget = ($speedup -ge 1.5)
    }
    [IO.File]::WriteAllText(
        (Join-Path $evidenceHome 'scale-10000.json'),
        ($scale10000Record | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
    Remove-TestTree -Path ([string]$reuseApply.quarantinePath)
    Remove-TestTree -Path ([string]$baselineApply.quarantinePath)

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteHashReuse'
        skipScale = $false
        scale1000ElapsedMs = [long]$scale1000Apply.metrics.elapsedMs
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
    foreach ($result in @($applyResult, $scale1000Apply, $reuseApply, $baselineApply)) {
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
