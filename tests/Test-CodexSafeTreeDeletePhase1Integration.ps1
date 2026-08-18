[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (Phase 1 integration / #36):
# 1. New-CodexSafeTreeDeletePlan → Invoke-CodexSafeTreeDeleteQuarantine → Invoke-CodexSafeTreeDeletePurge
# 2. Baseline = same library with -DisableApplyHashReuseForTest / -DisablePurgeHashReuseForTest
# 3. Observable wall clock, IdentityMismatch refusal, quarantine/purge vs plan, FS probe
# Not tested here: SessionHashCache internals, ProductionSmoke, leftover Purge/Restore/Archive

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$evidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue36-20260817'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$nestedPath = Join-Path $targetPath 'nested'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$payloadPath = Join-Path $targetPath 'payload.txt'
$childPath = Join-Path $nestedPath 'child.bin'
$payloadBytes = [Text.Encoding]::UTF8.GetBytes('phase1-integration-payload')
$childBytes = [Text.Encoding]::UTF8.GetBytes('phase1-integration-child')
$scaleRoot = Join-Path $evidenceHome 'scale-phase1'
$scaleReuseTarget = Join-Path $scaleRoot 'candidate-reuse'
$scaleBaselineTarget = Join-Path $scaleRoot 'candidate-baseline'
$scaleFileCount = 10000
$scaleBytesPerFile = 163840
$scaleTotalBytes = [long]$scaleFileCount * [long]$scaleBytesPerFile
$scaleHeadroomBytes = 2L * 1024L * 1024L * 1024L
$scaleRequiredBytes = (2L * $scaleTotalBytes) + $scaleHeadroomBytes

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

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Document | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
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
    Write-JsonFile -Path $Path -Document $policy
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete phase1 integration test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete phase1 integration test cleanup'
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
        $payload[$index] = [byte](($index + 13) % 251)
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

function Get-LiveDriveInventory {
    return @([IO.DriveInfo]::GetDrives() | ForEach-Object {
        $ready = [bool]$_.IsReady
        $format = $null
        $driveType = [string]$_.DriveType
        $available = $null
        if ($ready) {
            try {
                $format = [string]$_.DriveFormat
                $available = [long]$_.AvailableFreeSpace
            } catch {
                $format = $null
                $available = $null
            }
        }
        [pscustomobject][ordered]@{
            name = [string]$_.Name
            driveType = $driveType
            isReady = $ready
            driveFormat = $format
            availableFreeBytes = $available
        }
    })
}

function Invoke-Pipeline {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$DisableHashReuse
    )

    $plan = New-CodexSafeTreeDeletePlan `
        -TargetPath $TargetPath `
        -CapabilityRoot $CapabilityRoot `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot
    $applyArguments = @{
        PlanPath = [string]$plan.planPath
        ApprovedPlanSha256 = [string]$plan.planSha256
        PolicyPath = $PolicyPath
        EvidenceRoot = $EvidenceRoot
    }
    if ($DisableHashReuse) {
        $applyArguments.DisableApplyHashReuseForTest = $true
    }
    $apply = Invoke-CodexSafeTreeDeleteQuarantine @applyArguments
    $purgeArguments = @{
        TransactionPath = [string]$apply.transactionPath
        ApprovedTransactionSha256 = [string]$apply.transactionSha256
        PolicyPath = $PolicyPath
        EvidenceRoot = $EvidenceRoot
    }
    if ($DisableHashReuse) {
        $purgeArguments.DisablePurgeHashReuseForTest = $true
    }
    $purge = Invoke-CodexSafeTreeDeletePurge @purgeArguments
    $planMs = [long]$plan.metrics.elapsedMs
    $applyMs = [long]$apply.metrics.elapsedMs
    $purgeMs = [long]$purge.metrics.elapsedMs
    return [pscustomobject][ordered]@{
        plan = $plan
        apply = $apply
        purge = $purge
        planElapsedMs = $planMs
        applyElapsedMs = $applyMs
        purgeElapsedMs = $purgeMs
        elapsedMs = $planMs + $applyMs + $purgeMs
        applyBytesHashed = [long]$apply.metrics.bytesHashed
        purgeBytesHashed = [long]$purge.metrics.bytesHashed
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

[void][IO.Directory]::CreateDirectory($evidenceHome)
$availableBytes = [long]$drive.AvailableFreeSpace
if ($availableBytes -lt $scaleRequiredBytes) {
    $blocked = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue36-blocked-disk'
        availableFreeBytes = $availableBytes
        requiredBytes = $scaleRequiredBytes
        peakSiblingTreeBytes = 2L * $scaleTotalBytes
        fileCount = $scaleFileCount
        bytesPerFile = $scaleBytesPerFile
        reason = 'D: free space below two sibling 1-2GB trees plus 2GiB headroom'
    }
    Write-JsonFile -Path (Join-Path $evidenceHome 'blocked-disk.json') -Document $blocked
    throw (
        "BLOCKED: D: availableFreeBytes=$availableBytes requiredBytes=$scaleRequiredBytes " +
        "(two sibling trees plus 2GiB headroom)"
    )
}

. $hostSafetyLibraryPath
. $libraryPath
Assert-True (
    $null -ne (Get-Command -Name New-CodexSafeTreeDeletePlan -ErrorAction SilentlyContinue)
) 'New-CodexSafeTreeDeletePlan 必须存在'
Assert-True (
    $null -ne (Get-Command -Name Invoke-CodexSafeTreeDeleteQuarantine -ErrorAction SilentlyContinue)
) 'Invoke-CodexSafeTreeDeleteQuarantine 必须存在'
Assert-True (
    $null -ne (Get-Command -Name Invoke-CodexSafeTreeDeletePurge -ErrorAction SilentlyContinue)
) 'Invoke-CodexSafeTreeDeletePurge 必须存在'

Write-Stage -Name 'fs-probe'
$capabilities = [CodexSafeTreeDelete.FileSystemDetector]::DetectFileSystem($evidenceHome)
$supportsFileId = [CodexSafeTreeDelete.FileSystemDetector]::TestFileIdSupport($evidenceHome)
$driveInventory = Get-LiveDriveInventory
$fatFamily = @($driveInventory | Where-Object {
    $_.isReady -and [string]$_.driveFormat -in @('FAT32', 'exFAT')
})
$networkDrives = @($driveInventory | Where-Object {
    $_.isReady -and [string]$_.driveType -ceq 'Network'
})
$fat32Reason = if ($fatFamily.Count -eq 0) {
    'no ready FAT32/exFAT volume; #35 maintainer waiver; diskpart/format not in #36 scope'
} else {
    'ready FAT-family volume present but live FAT32 e2e is not a #36 gate'
}
$networkReason = if ($networkDrives.Count -eq 0) {
    'no ready network drive; live network e2e is not a #36 gate'
} else {
    'ready network drive present but live network e2e is not a #36 gate'
}
$fsProbe = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue36-filesystem-probe'
    driveFormat = [string]$drive.DriveFormat
    driveType = [string]$drive.DriveType
    availableFreeBytes = $availableBytes
    requiredBytes = $scaleRequiredBytes
    fileIdInfoSupported = [bool]$supportsFileId
    detector = [pscustomobject][ordered]@{
        fileSystemType = [string]$capabilities.FileSystemType
        isRemote = [bool]$capabilities.IsRemote
        supportsFileId128 = [bool]$capabilities.SupportsFileId128
        recommendHashReuse = [bool]$capabilities.RecommendHashReuse
        recommendParallel = [bool]$capabilities.RecommendParallel
        deletionAllowed = [bool]$capabilities.DeletionAllowed
    }
    fat32LiveE2e = [pscustomobject][ordered]@{
        verified = $false
        reason = $fat32Reason
        readyVolumeCount = $fatFamily.Count
    }
    networkLiveE2e = [pscustomobject][ordered]@{
        verified = $false
        reason = $networkReason
        readyVolumeCount = $networkDrives.Count
    }
    readyDrives = @($driveInventory)
}
Write-JsonFile -Path (Join-Path $evidenceHome 'filesystem-probe.json') -Document $fsProbe
Assert-True ([bool]$capabilities.DeletionAllowed) '本机探测必须允许删除（NTFS/ReFS + FILE_ID_INFO）'
Assert-True ([bool]$supportsFileId) '本机 FILE_ID_INFO 探测必须成功'

$applyResult = $null
$purgeSecurityApply = $null
$e2e = $null
$baseline = $null
$phase1 = $null
try {
    Write-Stage -Name 'safety-toctou-e2e'
    [void][IO.Directory]::CreateDirectory($nestedPath)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    New-FixturePolicy `
        -Path $policyPath `
        -CapabilityRoot $fixtureRoot `
        -DeniedPath $evidenceRoot `
        -Id 'phase1-integration-fixture'

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

    $applyResult = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$planResult.planPath) `
        -ApprovedPlanSha256 ([string]$planResult.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($applyResult.quarantined -eq $true) '成功路径 Apply 必须隔离'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) '成功路径 quarantine 必须存在'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) '成功路径原目标必须移走'
    $quarantineFiles = @(
        [IO.Directory]::GetFiles([string]$applyResult.quarantinePath, '*', [IO.SearchOption]::AllDirectories)
    )
    Assert-True ($quarantineFiles.Count -eq 2) 'quarantine 文件数必须与 plan 一致'

    $purgeResult = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($purgeResult.purged -eq $true) '成功路径 Purge 必须删完'
    Assert-True (-not [IO.Directory]::Exists([string]$applyResult.quarantinePath)) '成功路径 quarantine 必须消失'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) '成功路径原目标必须保持不存在'
    $dispositions = Read-JsonDocument -Path ([string]$purgeResult.leafDispositionsPath)
    Assert-True ([string]$dispositions.streamSetSource -ceq 'plan.leafStreamSetV1') `
        'leaf dispositions 必须声明 stream-set 来源'
    Assert-True ([long]$dispositions.summary.deleted -eq 2L) '成功路径每个 file leaf 必须 deleted'
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

    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    $purgeSecurityPlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $purgeSecurityApply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$purgeSecurityPlan.planPath) `
        -ApprovedPlanSha256 ([string]$purgeSecurityPlan.planSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($purgeSecurityApply.quarantined -eq $true) 'Purge TOCTOU 用例的 Apply 必须成功'
    $purgeSecurityError = $null
    $purgeSecurityRecord = $null
    try {
        [void](Invoke-CodexSafeTreeDeletePurge `
            -TransactionPath ([string]$purgeSecurityApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$purgeSecurityApply.transactionSha256) `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot `
            -BeforePurgeMutexForTest {
                param($Target)
                $quarantinePayloadPath = Join-Path ([string]$purgeSecurityApply.quarantinePath) 'payload.txt'
                [IO.File]::WriteAllText(
                    $quarantinePayloadPath,
                    'tampered-during-purge',
                    [Text.UTF8Encoding]::new($false))
            })
    } catch {
        $purgeSecurityError = $_.Exception.Message
        $purgeSecurityRecord = $_
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($purgeSecurityError)) 'Purge 过程中改文件必须拒绝'
    Assert-True ($purgeSecurityError -match 'IdentityMismatch') 'Purge 过程中改文件必须记录 IdentityMismatch'
    Assert-True ($null -ne (Test-IdentityMismatchException -ErrorRecord $purgeSecurityRecord)) `
        'Purge 拒绝必须保留 IdentityMismatchException'
    Assert-True ([IO.Directory]::Exists([string]$purgeSecurityApply.quarantinePath)) `
        'IdentityMismatch 拒绝不得删除 quarantine'
    Remove-TestTree -Path ([string]$purgeSecurityApply.quarantinePath)

    [void][IO.Directory]::CreateDirectory($nestedPath)
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($childPath, $childBytes)
    $e2e = Invoke-Pipeline `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($e2e.plan.planned -eq $true) '集成 Plan 必须成功'
    Assert-True ($e2e.apply.quarantined -eq $true) '集成 Apply 必须成功'
    Assert-True ($e2e.purge.purged -eq $true) '集成 Purge 必须成功'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) '集成结束后原目标必须不存在'
    Assert-True (-not [IO.Directory]::Exists([string]$e2e.apply.quarantinePath)) `
        '集成结束后 quarantine 必须不存在'

    Write-Stage -Name 'scale-create'
    [void][IO.Directory]::CreateDirectory($scaleRoot)
    $scalePolicyPath = Join-Path $scaleRoot 'policy.json'
    $scaleEvidenceRoot = Join-Path $scaleRoot 'evidence'
    [void][IO.Directory]::CreateDirectory($scaleEvidenceRoot)
    New-FixturePolicy `
        -Path $scalePolicyPath `
        -CapabilityRoot $scaleRoot `
        -DeniedPath $scaleEvidenceRoot `
        -Id 'phase1-integration-scale'
    $scaleCreated = New-ScaleTree `
        -Path $scaleReuseTarget `
        -FileCount $scaleFileCount `
        -BytesPerFile $scaleBytesPerFile
    [void](New-ScaleTree `
        -Path $scaleBaselineTarget `
        -FileCount $scaleFileCount `
        -BytesPerFile $scaleBytesPerFile)
    Assert-True ($scaleCreated.FileCount -eq $scaleFileCount) 'scale 树必须写出 10000 个文件'
    Assert-True ($scaleCreated.LogicalBytes -eq $scaleTotalBytes) 'scale 树总大小必须是 160KiB x 10000'
    Assert-True (
        $scaleCreated.LogicalBytes -ge 1L * 1024L * 1024L * 1024L -and
        $scaleCreated.LogicalBytes -le 2L * 1024L * 1024L * 1024L
    ) 'scale 树总大小必须落在 1-2 GiB'

    Write-Stage -Name 'scale-baseline'
    $baseline = Invoke-Pipeline `
        -TargetPath $scaleBaselineTarget `
        -CapabilityRoot $scaleRoot `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot `
        -DisableHashReuse
    Assert-True ($baseline.plan.fileCount -eq $scaleFileCount) 'baseline Plan 必须覆盖 10000 个文件'
    Assert-True ($baseline.apply.quarantined -eq $true) 'baseline Apply 必须成功'
    Assert-True ($baseline.purge.purged -eq $true) 'baseline Purge 必须成功'
    Assert-True (-not [IO.Directory]::Exists($scaleBaselineTarget)) 'baseline Purge 后原目标必须不存在'
    Assert-True (-not [IO.Directory]::Exists([string]$baseline.apply.quarantinePath)) `
        'baseline Purge 后 quarantine 必须不存在'
    $baselineDispositions = Read-JsonDocument -Path ([string]$baseline.purge.leafDispositionsPath)
    Assert-True ([long]$baselineDispositions.summary.deleted -eq [long]$scaleFileCount) `
        'baseline Purge 必须删除全部 file leaf'

    Write-Stage -Name 'scale-phase1'
    $phase1 = Invoke-Pipeline `
        -TargetPath $scaleReuseTarget `
        -CapabilityRoot $scaleRoot `
        -PolicyPath $scalePolicyPath `
        -EvidenceRoot $scaleEvidenceRoot
    Assert-True ($phase1.plan.fileCount -eq $scaleFileCount) 'phase1 Plan 必须覆盖 10000 个文件'
    Assert-True ($phase1.apply.quarantined -eq $true) 'phase1 Apply 必须成功'
    Assert-True ($phase1.purge.purged -eq $true) 'phase1 Purge 必须成功'
    Assert-True (-not [IO.Directory]::Exists($scaleReuseTarget)) 'phase1 Purge 后原目标必须不存在'
    Assert-True (-not [IO.Directory]::Exists([string]$phase1.apply.quarantinePath)) `
        'phase1 Purge 后 quarantine 必须不存在'
    $phase1Dispositions = Read-JsonDocument -Path ([string]$phase1.purge.leafDispositionsPath)
    Assert-True ([long]$phase1Dispositions.summary.deleted -eq [long]$scaleFileCount) `
        'phase1 Purge 必须删除全部 file leaf'

    Write-Stage -Name 'scale-record'
    $baselineMs = [double]$baseline.elapsedMs
    $phase1Ms = [double]$phase1.elapsedMs
    $ratio = if ($baselineMs -gt 0) { $phase1Ms / $baselineMs } else { 0 }
    $speedup = if ($phase1Ms -gt 0) { $baselineMs / $phase1Ms } else { 0 }
    $scaleRecord = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue36-scale-phase1'
        fileCount = $scaleFileCount
        bytesPerFile = $scaleBytesPerFile
        totalBytes = $scaleTotalBytes
        method = 'two sibling 10k trees of 160KiB (1.526GiB each); same working tree and library; baseline Plan→Apply→Purge with -DisableApplyHashReuseForTest and -DisablePurgeHashReuseForTest; phase1 same pipeline with SessionHashCache; no git checkout of old implementation'
        baselineElapsedMs = [long]$baseline.elapsedMs
        phase1ElapsedMs = [long]$phase1.elapsedMs
        baseline = [pscustomobject][ordered]@{
            planElapsedMs = [long]$baseline.planElapsedMs
            applyElapsedMs = [long]$baseline.applyElapsedMs
            purgeElapsedMs = [long]$baseline.purgeElapsedMs
            applyBytesHashed = [long]$baseline.applyBytesHashed
            purgeBytesHashed = [long]$baseline.purgeBytesHashed
        }
        phase1 = [pscustomobject][ordered]@{
            planElapsedMs = [long]$phase1.planElapsedMs
            applyElapsedMs = [long]$phase1.applyElapsedMs
            purgeElapsedMs = [long]$phase1.purgeElapsedMs
            applyBytesHashed = [long]$phase1.applyBytesHashed
            purgeBytesHashed = [long]$phase1.purgeBytesHashed
        }
        ratio = [Math]::Round($ratio, 3)
        speedup = [Math]::Round($speedup, 3)
        target = 'Phase1/baseline <= 0.33 (>=3x)'
        metTarget = ($ratio -le 0.33 -and $ratio -gt 0)
    }
    Write-JsonFile -Path (Join-Path $evidenceHome 'scale-phase1.json') -Document $scaleRecord

    Write-Stage -Name 'done'
    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeletePhase1Integration'
        fileCount = $scaleFileCount
        bytesPerFile = $scaleBytesPerFile
        totalBytes = $scaleTotalBytes
        baselineElapsedMs = [long]$baseline.elapsedMs
        phase1ElapsedMs = [long]$phase1.elapsedMs
        speedup = $scaleRecord.speedup
        ratio = $scaleRecord.ratio
        metTarget = [bool]$scaleRecord.metTarget
        fat32LiveE2eVerified = $false
        networkLiveE2eVerified = $false
    }
} finally {
    $cleanupPaths = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
            $targetPath,
            $scaleReuseTarget,
            $scaleBaselineTarget,
            $fixtureRoot,
            $scaleRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $cleanupPaths.Add($candidate)
        }
    }
    foreach ($result in @($applyResult, $purgeSecurityApply, $e2e, $baseline, $phase1)) {
        if ($null -eq $result) { continue }
        $quarantine = $null
        if ($result.PSObject.Properties['quarantinePath']) {
            $quarantine = [string]$result.quarantinePath
        } elseif (
            $result.PSObject.Properties['apply'] -and
            $null -ne $result.apply -and
            $result.apply.PSObject.Properties['quarantinePath']
        ) {
            $quarantine = [string]$result.apply.quarantinePath
        }
        if (-not [string]::IsNullOrWhiteSpace($quarantine)) {
            $cleanupPaths.Add($quarantine)
        }
    }
    foreach ($path in $cleanupPaths) {
        if ([IO.Directory]::Exists($path)) {
            Remove-TestTree -Path $path
        }
    }
}
