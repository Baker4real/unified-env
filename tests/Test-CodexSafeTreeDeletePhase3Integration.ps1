[CmdletBinding()]
param(
    [switch]$SkipBaseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (Phase 3 integration / #42):
# 1. Production Plan→Apply→Purge: New-CodexSafeTreeDeletePlan →
#    Invoke-CodexSafeTreeDeleteQuarantine → Invoke-CodexSafeTreeDeletePurge
#    (capability-gated ParallelPurgeCoordinator + HostSafety deleter).
#    Baseline disables hash reuse (and therefore parallel).
# 2. ParallelPurgeCoordinator File.Delete on issue42 fixture trees only.
#    10k DOP 2/4 reused from #40 raw JSON after path/fileCount/degree verify;
#    do not pin wallClockMs or #41 OverheadPercent snapshots.
# 3. Observable: wall clock layers A vs B, IdentityMismatch, leafDispositions,
#    journal jsonl parse, RecommendParallel=false → DOP=1, leftover untouched.
# Not tested: leftover Purge/Restore, ProductionSmoke, #36 1.526 GiB rerun.

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$evidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue42-20260819'
$fixtureRoot = Join-Path $evidenceHome ('fixtures-{0}' -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$nestedPath = Join-Path $targetPath 'nested'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$payloadPath = Join-Path $targetPath 'payload.txt'
$childPath = Join-Path $nestedPath 'child.bin'
$payloadBytes = [Text.Encoding]::UTF8.GetBytes('phase3-integration-payload')
$childBytes = [Text.Encoding]::UTF8.GetBytes('phase3-integration-child')
$scaleRoot = Join-Path $evidenceHome 'scale-phase3'
$scaleProdTarget = Join-Path $scaleRoot 'candidate-phase3-prod'
$scaleBaselineTarget = Join-Path $scaleRoot 'candidate-baseline'
$scaleFileCount = 10000
$scaleBytesPerFile = 4096
$scaleTotalBytes = [long]$scaleFileCount * [long]$scaleBytesPerFile
$scaleHeadroomBytes = 256L * 1024L * 1024L
$scaleRequiredBytes = (2L * $scaleTotalBytes) + $scaleHeadroomBytes
$forbiddenQuarantine = Join-Path $projectRoot 'reports\.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine'
$forbiddenTransaction = 'D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json'
$issue36ScalePath = Join-Path $projectRoot 'reports\safe-tree-delete-issue36-20260817\scale-phase1.json'
$issue37ScalePath = Join-Path $projectRoot 'reports\safe-tree-delete-issue37-20260817\scale-10000.json'
$issue40AnalysisPath = Join-Path $projectRoot 'reports\safe-tree-delete-issue40-20260817\analysis.json'
$issue40Dop1Path = Join-Path $projectRoot 'reports\safe-tree-delete-issue40-20260817\raw\small-10k-1kb-dop01.json'
$issue40Dop2Path = Join-Path $projectRoot 'reports\safe-tree-delete-issue40-20260817\raw\small-10k-1kb-dop02.json'
$issue40Dop4Path = Join-Path $projectRoot 'reports\safe-tree-delete-issue40-20260817\raw\small-10k-1kb-dop04.json'
$issue41ScalePath = Join-Path $projectRoot 'reports\safe-tree-delete-issue41-20260817\scale-10000.json'
$issue39JournalDir = Join-Path $projectRoot 'reports\safe-tree-delete-issue39-20260817\fixtures-fc0b2f39ab6a401e961dde5c68d1cd22\scale-10000-journal'

function Write-Stage {
    param([Parameter(Mandatory)][string]$Name)
    Write-Output ("STAGE {0} utc={1}" -f $Name, [datetimeoffset]::UtcNow.ToString('o'))
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-HasJsonProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    return $null -ne $Object.PSObject.Properties[$Name]
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
        ($Document | ConvertTo-Json -Depth 12),
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
        -Name 'safe-delete phase3 integration test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete phase3 integration test cleanup'
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

function Assert-LeftoverUntouched {
    param([Parameter(Mandatory)][string]$When)

    Assert-True ([IO.Directory]::Exists($forbiddenQuarantine)) (
        "生产 leftover quarantine 必须仍在 ($When): $forbiddenQuarantine"
    )
    Assert-True ([IO.File]::Exists($forbiddenTransaction)) (
        "生产 leftover transaction.json 必须仍在 ($When): $forbiddenTransaction"
    )
}

function Read-JournalTextFromSecondHandle {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $stream = [IO.File]::Open(
        $LiteralPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Test-JsonlParseable {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $text = Read-JournalTextFromSecondHandle -LiteralPath $LiteralPath
    $lines = @(
        $text -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 }
    )
    $parsed = 0
    foreach ($line in $lines) {
        $row = $line | ConvertFrom-Json -Depth 8 -DateKind String -ErrorAction Stop
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row.op)) (
            "jsonl 行必须有 op: $LiteralPath"
        )
        $parsed += 1
    }
    return [pscustomobject][ordered]@{
        path = $LiteralPath
        lineCount = $lines.Count
        parsedCount = $parsed
        parseable = ($parsed -eq $lines.Count -and $parsed -gt 0)
    }
}

function New-FixtureFile {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$Text = 'x'
    )
    $parent = Split-Path -Parent $LiteralPath
    if (-not [IO.Directory]::Exists($parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
    [IO.File]::WriteAllText($LiteralPath, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-Pipeline {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$DisableHashReuse,
        [switch]$DisablePurgeBatch
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
    if ($DisablePurgeBatch) {
        $purgeArguments.DisablePurgeBatchForTest = $true
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
        parallelPurge = $(if ($null -ne $purge.PSObject.Properties['parallelPurge']) {
            $purge.parallelPurge
        } else { $null })
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
Assert-LeftoverUntouched -When 'start'
$availableBytes = [long]$drive.AvailableFreeSpace
if ($availableBytes -lt $scaleRequiredBytes) {
    $blocked = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue42-blocked-disk'
        availableFreeBytes = $availableBytes
        requiredBytes = $scaleRequiredBytes
        peakSiblingTreeBytes = 2L * $scaleTotalBytes
        fileCount = $scaleFileCount
        bytesPerFile = $scaleBytesPerFile
        reason = 'D: free space below two sequential 10k x 4KB trees plus 256MiB headroom'
    }
    Write-JsonFile -Path (Join-Path $evidenceHome 'blocked-disk.json') -Document $blocked
    throw (
        "BLOCKED: D: availableFreeBytes=$availableBytes requiredBytes=$scaleRequiredBytes " +
        "(two sequential 10k x 4KB trees plus 256MiB headroom)"
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
Assert-True (
    $null -ne ('CodexSafeTreeDelete.ParallelPurgeCoordinator' -as [type])
) 'ParallelPurgeCoordinator 类型必须已由库加载（生产 Purge 按能力门控接入）'

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
$networkProbeCaps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $true, $true)
$networkDop = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::ResolveMaxDegreeOfParallelism($networkProbeCaps)
Assert-True ($networkProbeCaps.RecommendParallel -eq $false) (
    '无就绪 Network 卷时，FromDetection(NTFS, isRemote=true) RecommendParallel 必须为 false'
)
Assert-True ($networkProbeCaps.RecommendedMaxParallelism -eq 1) (
    'Network FromDetection RecommendedMaxParallelism 必须为 1'
)
Assert-True ($networkDop -eq 1) 'RecommendParallel=false 时 ResolveMaxDegreeOfParallelism 必须为 1'
$networkReason = if ($networkDrives.Count -eq 0) {
    'no ready Network volume; #35 maintainer waiver; do not elevate or mount; live Network e2e unverified'
} else {
    'ready Network volume present but live Network e2e is not a #42 gate; #35 waiver'
}
$fsProbe = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue42-filesystem-probe'
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
    networkDegrade = [pscustomobject][ordered]@{
        fromDetectionRecommendParallel = [bool]$networkProbeCaps.RecommendParallel
        fromDetectionRecommendedMaxParallelism = [int]$networkProbeCaps.RecommendedMaxParallelism
        resolveMaxDegreeOfParallelism = [int]$networkDop
        liveReadyVolumeCount = $networkDrives.Count
        liveVolumeVerified = $false
        reason = $networkReason
        waiver = '#35'
    }
    fat32LiveE2e = [pscustomobject][ordered]@{
        verified = $false
        reason = $(if ($fatFamily.Count -eq 0) {
            'no ready FAT32/exFAT volume; #35 maintainer waiver'
        } else {
            'ready FAT-family volume present but live FAT32 e2e is not a #42 gate'
        })
        readyVolumeCount = $fatFamily.Count
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
$phase3Prod = $null
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
        -Id 'phase3-integration-fixture'

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

    $purgeResult = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ($purgeResult.purged -eq $true) '成功路径 Purge 必须删完'
    Assert-True (-not [IO.Directory]::Exists([string]$applyResult.quarantinePath)) '成功路径 quarantine 必须消失'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) '成功路径原目标必须保持不存在'
    $dispositions = Read-JsonDocument -Path ([string]$purgeResult.leafDispositionsPath)
    Assert-True ([long]$dispositions.summary.deleted -eq 2L) '成功路径每个 file leaf 必须 deleted'
    foreach ($row in @($dispositions.leaves)) {
        Assert-True ([string]$row.disposition -ceq 'deleted') '完整 Purge 中每个 leaf 必须是 deleted'
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
    $e2eDispositions = Read-JsonDocument -Path ([string]$e2e.purge.leafDispositionsPath)
    Assert-True ([long]$e2eDispositions.summary.deleted -eq [long]$e2e.plan.fileCount) `
        'e2e leafDispositions.deleted 必须对齐 fileCount'

    Write-Stage -Name 'coordinator-journal'
    $coordRoot = Join-Path $fixtureRoot 'coordinator'
    $multiTree = Join-Path $coordRoot 'multi-tree'
    $multiJournal = Join-Path $coordRoot 'multi-journal'
    $failTree = Join-Path $coordRoot 'fail-tree'
    $failJournal = Join-Path $coordRoot 'fail-journal'
    $journalCopyRoot = Join-Path $evidenceHome 'coordinator-journals'
    [void][IO.Directory]::CreateDirectory($multiJournal)
    [void][IO.Directory]::CreateDirectory($failJournal)
    [void][IO.Directory]::CreateDirectory($journalCopyRoot)
    $optimizeCaps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $false, $true)
    $multiFiles = @(
        (Join-Path $multiTree 'dir-a\a1.txt'),
        (Join-Path $multiTree 'dir-a\a2.txt'),
        (Join-Path $multiTree 'dir-b\b1.txt'),
        (Join-Path $multiTree 'dir-b\b2.txt'),
        (Join-Path $multiTree 'dir-c\c1.txt'),
        (Join-Path $multiTree 'dir-d\d1.txt')
    )
    foreach ($path in $multiFiles) {
        New-FixtureFile -LiteralPath $path
    }
    $coordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
        $multiTree,
        $multiJournal,
        $evidenceHome,
        $optimizeCaps)
    try {
        Assert-True ($coordinator.MaxDegreeOfParallelism -eq 2) 'optimize coordinator DOP 必须是 2（#40 20260819 峰值效率）'
        $multiResult = $coordinator.Purge()
    } finally {
        $coordinator.Dispose()
    }
    Assert-True ($multiResult.DeletedCount -eq 6) 'coordinator 夹具 6 个文件必须删掉'
    Assert-True ($multiResult.FailedCount -eq 0) 'coordinator 成功路径不得失败'
    $liveJournalFiles = @(
        Get-ChildItem -LiteralPath $multiJournal -Filter '*.jsonl' -File |
            ForEach-Object { $_.FullName }
    )
    Assert-True ($liveJournalFiles.Count -ge 4) 'coordinator 每个顶级目录必须有 journal'
    $liveParse = @($liveJournalFiles | ForEach-Object { Test-JsonlParseable -LiteralPath $_ })
    foreach ($row in $liveParse) {
        Assert-True ([bool]$row.parseable) "coordinator journal 必须可解析: $($row.path)"
        $leafName = Split-Path -Leaf $row.path
        [IO.File]::Copy($row.path, (Join-Path $journalCopyRoot $leafName), $true)
    }

    New-FixtureFile -LiteralPath (Join-Path $failTree 'dir-ok\ok.txt')
    New-FixtureFile -LiteralPath (Join-Path $failTree 'dir-other\other.txt')
    $lockedPath = Join-Path $failTree 'dir-lock\locked.txt'
    New-FixtureFile -LiteralPath $lockedPath
    $lockStream = [IO.File]::Open(
        $lockedPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    $failResult = $null
    try {
        $failCoordinator = [CodexSafeTreeDelete.ParallelPurgeCoordinator]::new(
            $failTree,
            $failJournal,
            $evidenceHome,
            $optimizeCaps)
        try {
            $failResult = $failCoordinator.Purge()
        } finally {
            $failCoordinator.Dispose()
        }
    } finally {
        $lockStream.Dispose()
    }
    Assert-True ($failResult.FailedCount -eq 1) '锁住的文件必须记为失败'
    Assert-True ($failResult.DeletedCount -eq 2) '未锁文件仍必须删掉'
    $failJournalFiles = @(
        Get-ChildItem -LiteralPath $failJournal -Filter '*.jsonl' -File |
            ForEach-Object { $_.FullName }
    )
    Assert-True ($failJournalFiles.Count -ge 1) '失败后 journal 必须仍在'
    $failParse = @($failJournalFiles | ForEach-Object { Test-JsonlParseable -LiteralPath $_ })
    foreach ($row in $failParse) {
        Assert-True ([bool]$row.parseable) "失败后 journal 必须仍可读可解析: $($row.path)"
        $leafName = 'fail-' + (Split-Path -Leaf $row.path)
        [IO.File]::Copy($row.path, (Join-Path $journalCopyRoot $leafName), $true)
    }
    $failJournalText = @(
        $failJournalFiles | ForEach-Object { Read-JournalTextFromSecondHandle -LiteralPath $_ }
    ) -join ''
    Assert-True ($failJournalText.Contains('{"op":"pending","path":"dir-lock/locked.txt"}')) `
        '失败文件必须已写 pending'
    Assert-True (-not $failJournalText.Contains('{"op":"commit","path":"dir-lock/locked.txt"}')) `
        '失败文件不得 commit'
    if ([IO.File]::Exists($lockedPath)) {
        [IO.File]::Delete($lockedPath)
    }

    $issue39Journals = @()
    if ([IO.Directory]::Exists($issue39JournalDir)) {
        $issue39Journals = @(
            Get-ChildItem -LiteralPath $issue39JournalDir -Filter '*.jsonl' -File |
                ForEach-Object { $_.FullName }
        )
    }
    Assert-True ($issue39Journals.Count -ge 4) '#39 10k journal 必须仍在且可引用'
    $issue39Parse = @($issue39Journals | ForEach-Object { Test-JsonlParseable -LiteralPath $_ })
    foreach ($row in $issue39Parse) {
        Assert-True ([bool]$row.parseable) "#39 journal 必须可解析: $($row.path)"
    }

    $coordRecord = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue42-coordinator-journal'
        method = 'ParallelPurgeCoordinator File.Delete on issue42 fixture trees only; not production Purge'
        liveMulti = [pscustomobject][ordered]@{
            fileCount = [int]$multiResult.FileCount
            deletedCount = [int]$multiResult.DeletedCount
            failedCount = [int]$multiResult.FailedCount
            elapsedMs = [long]$multiResult.ElapsedMs
            journalFileCount = [int]$multiResult.JournalFileCount
            parseable = @($liveParse)
        }
        liveFailAfterLock = [pscustomobject][ordered]@{
            deletedCount = [int]$failResult.DeletedCount
            failedCount = [int]$failResult.FailedCount
            journalsStillParseable = $true
            parseable = @($failParse)
        }
        issue39ScaleJournals = [pscustomobject][ordered]@{
            directory = $issue39JournalDir
            fileCount = $issue39Journals.Count
            parseable = @($issue39Parse)
        }
    }
    Write-JsonFile -Path (Join-Path $evidenceHome 'coordinator-journal.json') -Document $coordRecord

    Write-Stage -Name 'reuse-issue40-raw'
    foreach ($rawPath in @($issue40Dop1Path, $issue40Dop2Path, $issue40Dop4Path, $issue40AnalysisPath)) {
        Assert-True ([IO.File]::Exists($rawPath)) "复用 #40 必须核文件仍在: $rawPath"
    }
    $rawDop1 = Read-JsonDocument -Path $issue40Dop1Path
    $rawDop2 = Read-JsonDocument -Path $issue40Dop2Path
    $rawDop4 = Read-JsonDocument -Path $issue40Dop4Path
    Assert-True ([int]$rawDop1.fileCount -eq 10000) '#40 DOP1 raw 必须是 10k'
    Assert-True ([int]$rawDop2.fileCount -eq 10000) '#40 DOP2 raw 必须是 10k'
    Assert-True ([int]$rawDop4.fileCount -eq 10000) '#40 DOP4 raw 必须是 10k'
    Assert-True ([int]$rawDop1.degree -eq 1) '#40 DOP1 raw degree 必须是 1'
    Assert-True ([int]$rawDop2.degree -eq 2) '#40 DOP2 raw degree 必须是 2'
    Assert-True ([int]$rawDop4.degree -eq 4) '#40 DOP4 raw degree 必须是 4'
    Assert-True (Test-HasJsonProperty -Object $rawDop1 -Name 'wallClockMs') '#40 DOP1 raw 必须含 wallClockMs'
    Assert-True (Test-HasJsonProperty -Object $rawDop2 -Name 'wallClockMs') '#40 DOP2 raw 必须含 wallClockMs'
    Assert-True (Test-HasJsonProperty -Object $rawDop4 -Name 'wallClockMs') '#40 DOP4 raw 必须含 wallClockMs'
    Assert-True ([long]$rawDop1.wallClockMs -gt 0) '#40 DOP1 wallClockMs 必须为正（不钉历史快照）'
    Assert-True ([long]$rawDop2.wallClockMs -gt 0) '#40 DOP2 wallClockMs 必须为正（不钉历史快照）'
    Assert-True ([long]$rawDop4.wallClockMs -gt 0) '#40 DOP4 wallClockMs 必须为正（不钉历史快照）'
    $issue40Analysis = Read-JsonDocument -Path $issue40AnalysisPath
    Assert-True ($null -ne $issue40Analysis) '#40 analysis.json 必须可解析'

    Write-Stage -Name 'citations'
    foreach ($citePath in @($issue36ScalePath, $issue37ScalePath, $issue41ScalePath)) {
        Assert-True ([IO.File]::Exists($citePath)) "引用报告必须仍在: $citePath"
    }
    $issue36 = Read-JsonDocument -Path $issue36ScalePath
    $issue37 = Read-JsonDocument -Path $issue37ScalePath
    $issue41 = Read-JsonDocument -Path $issue41ScalePath
    Assert-True (Test-HasJsonProperty -Object $issue36 -Name 'speedup') '#36 报告必须含 speedup 字段（不钉历史 1.02）'
    Assert-True ((Test-HasJsonProperty -Object $issue36 -Name 'metTarget') -and $issue36.metTarget -is [bool]) `
        '#36 报告必须含 bool metTarget（不钉达成状态；本套件先跑的 Phase1Integration 会用当前生产管线重写该快照，#42 并行 Purge 落地后新测可合法翻 true，见性能 spec 操作者指南）'
    [void][double]$issue36.speedup
    Assert-True (Test-HasJsonProperty -Object $issue37 -Name 'speedupVsBaseline') '#37 报告必须含 speedupVsBaseline 字段（不钉历史 0.964）'
    Assert-True ((Test-HasJsonProperty -Object $issue37 -Name 'metTarget') -and $issue37.metTarget -is [bool]) `
        '#37 报告必须含 bool metTarget（不钉达成状态；PurgeBatch 重测可改写该快照的达成状态）'
    [void][double]$issue37.speedupVsBaseline
    Assert-True ((Test-HasJsonProperty -Object $issue41 -Name 'IsWithinTarget') -and $issue41.IsWithinTarget -is [bool]) `
        '#41 报告必须含 bool IsWithinTarget（不钉达成状态；重测可改写该快照的达成状态）'
    Assert-True (Test-HasJsonProperty -Object $issue41 -Name 'OverheadPercent') `
        '#41 报告必须含 OverheadPercent 字段（不钉 18.659 或后续重测百分比）'
    [void][double]$issue41.OverheadPercent

    Write-Stage -Name 'scale-create'
    [void][IO.Directory]::CreateDirectory($scaleRoot)
    $scalePolicyPath = Join-Path $scaleRoot 'policy.json'
    $scaleEvidenceRoot = Join-Path $scaleRoot 'evidence'
    [void][IO.Directory]::CreateDirectory($scaleEvidenceRoot)
    New-FixturePolicy `
        -Path $scalePolicyPath `
        -CapabilityRoot $scaleRoot `
        -DeniedPath $scaleEvidenceRoot `
        -Id 'phase3-integration-scale'
    $baselinePartialPath = Join-Path $evidenceHome 'baseline-partial.json'
    $baselineReused = $false
    if ($SkipBaseline) {
        Assert-True ([IO.File]::Exists($baselinePartialPath)) (
            'SkipBaseline 必须能读到已有 baseline-partial.json'
        )
        $baselinePartial = Read-JsonDocument -Path $baselinePartialPath
        Assert-True ([long]$baselinePartial.elapsedMs -eq 513510) (
            'SkipBaseline 复用的 baseline 合计必须仍是 513510ms'
        )
        Assert-True ([int]$baselinePartial.fileCount -eq $scaleFileCount) (
            'SkipBaseline 复用的 baseline fileCount 必须是 10000'
        )
        Assert-True ([int]$baselinePartial.bytesPerFile -eq $scaleBytesPerFile) (
            'SkipBaseline 复用的 baseline bytesPerFile 必须是 4096'
        )
        $baselineReused = $true
        $baseline = [pscustomobject][ordered]@{
            planElapsedMs = [long]$baselinePartial.planElapsedMs
            applyElapsedMs = [long]$baselinePartial.applyElapsedMs
            purgeElapsedMs = [long]$baselinePartial.purgeElapsedMs
            elapsedMs = [long]$baselinePartial.elapsedMs
            applyBytesHashed = [long]$baselinePartial.applyBytesHashed
            purgeBytesHashed = [long]$baselinePartial.purgeBytesHashed
            plan = [pscustomobject]@{ fileCount = [int]$baselinePartial.fileCount }
            apply = [pscustomobject]@{ quarantined = $true; quarantinePath = $null }
            purge = [pscustomobject]@{ purged = $true }
        }
        $baselineDispositions = [pscustomobject]@{
            summary = [pscustomobject]@{ deleted = [long]$baselinePartial.leafDispositionsDeleted }
        }
        Write-Stage -Name 'scale-baseline-reused'
    } else {
        $scaleCreated = New-ScaleTree `
            -Path $scaleBaselineTarget `
            -FileCount $scaleFileCount `
            -BytesPerFile $scaleBytesPerFile
        Assert-True ($scaleCreated.FileCount -eq $scaleFileCount) 'baseline scale 树必须写出 10000 个文件'
        Assert-True ($scaleCreated.LogicalBytes -eq $scaleTotalBytes) 'baseline scale 树总大小必须是 4KB x 10000'

        Write-Stage -Name 'scale-baseline-prod'
        $baseline = Invoke-Pipeline `
            -TargetPath $scaleBaselineTarget `
            -CapabilityRoot $scaleRoot `
            -PolicyPath $scalePolicyPath `
            -EvidenceRoot $scaleEvidenceRoot `
            -DisableHashReuse `
            -DisablePurgeBatch
        Assert-True ($baseline.plan.fileCount -eq $scaleFileCount) 'baseline Plan 必须覆盖 10000 个文件'
        Assert-True ($baseline.apply.quarantined -eq $true) 'baseline Apply 必须成功'
        Assert-True ($baseline.purge.purged -eq $true) 'baseline Purge 必须成功'
        Assert-True (-not [IO.Directory]::Exists($scaleBaselineTarget)) 'baseline Purge 后原目标必须不存在'
        Assert-True (-not [IO.Directory]::Exists([string]$baseline.apply.quarantinePath)) `
            'baseline Purge 后 quarantine 必须不存在'
        $baselineDispositions = Read-JsonDocument -Path ([string]$baseline.purge.leafDispositionsPath)
        Assert-True ([long]$baselineDispositions.summary.deleted -eq [long]$scaleFileCount) `
            'baseline leafDispositions.deleted 必须对齐 fileCount'
        $baselinePartial = [pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-issue42-baseline-partial'
            planElapsedMs = [long]$baseline.planElapsedMs
            applyElapsedMs = [long]$baseline.applyElapsedMs
            purgeElapsedMs = [long]$baseline.purgeElapsedMs
            elapsedMs = [long]$baseline.elapsedMs
            applyBytesHashed = [long]$baseline.applyBytesHashed
            purgeBytesHashed = [long]$baseline.purgeBytesHashed
            leafDispositionsDeleted = [long]$baselineDispositions.summary.deleted
            fileCount = $scaleFileCount
            bytesPerFile = $scaleBytesPerFile
        }
        Write-JsonFile -Path $baselinePartialPath -Document $baselinePartial
    }

    $phase3Attempts = [Collections.Generic.List[object]]::new()
    $phase3LastError = $null
    for ($phase3Attempt = 1; $phase3Attempt -le 3; $phase3Attempt++) {
        Write-Stage -Name ('scale-phase3-create-{0}' -f $phase3Attempt)
        $phase3Created = New-ScaleTree `
            -Path $scaleProdTarget `
            -FileCount $scaleFileCount `
            -BytesPerFile $scaleBytesPerFile
        Assert-True ($phase3Created.FileCount -eq $scaleFileCount) 'phase3-prod scale 树必须写出 10000 个文件'
        Assert-True ($phase3Created.LogicalBytes -eq $scaleTotalBytes) 'phase3-prod scale 树总大小必须是 4KB x 10000'

        Write-Stage -Name ('scale-phase3-prod-{0}' -f $phase3Attempt)
        try {
            $phase3Prod = Invoke-Pipeline `
                -TargetPath $scaleProdTarget `
                -CapabilityRoot $scaleRoot `
                -PolicyPath $scalePolicyPath `
                -EvidenceRoot $scaleEvidenceRoot
            $phase3Attempts.Add([pscustomobject][ordered]@{
                attempt = $phase3Attempt
                ok = $true
                elapsedMs = [long]$phase3Prod.elapsedMs
            })
            $phase3LastError = $null
            break
        } catch {
            $chain = [Collections.Generic.List[object]]::new()
            $native = $null
            $current = $_.Exception
            while ($null -ne $current) {
                $row = [ordered]@{
                    type = [string]$current.GetType().FullName
                    message = [string]$current.Message
                }
                if ($current -is [ComponentModel.Win32Exception]) {
                    $row.nativeErrorCode = [int]$current.NativeErrorCode
                    $native = [int]$current.NativeErrorCode
                }
                $chain.Add([pscustomobject]$row)
                $current = $current.InnerException
            }
            $phase3LastError = $_
            $phase3Attempts.Add([pscustomobject][ordered]@{
                attempt = $phase3Attempt
                ok = $false
                nativeErrorCode = $native
                message = [string]$_.Exception.Message
                chain = @($chain)
            })
            Write-JsonFile -Path (Join-Path $evidenceHome 'phase3-prod-attempts.json') -Document ([pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-issue42-phase3-prod-attempts'
                attempts = @($phase3Attempts)
            })
            if ([IO.Directory]::Exists($scaleProdTarget)) {
                Remove-TestTree -Path $scaleProdTarget
            }
            $quarantineCandidates = @(
                Get-ChildItem -LiteralPath $scaleRoot -Force -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '.codex-safe-delete-*.quarantine' }
            )
            foreach ($quarantineDir in $quarantineCandidates) {
                if ($quarantineDir.FullName -ceq $forbiddenQuarantine) { continue }
                Remove-TestTree -Path $quarantineDir.FullName
            }
            if ($native -ne 32 -or $phase3Attempt -eq 3) {
                Write-JsonFile -Path (Join-Path $evidenceHome 'phase3-prod-failure.json') -Document ([pscustomobject][ordered]@{
                    artifactType = 'env-governance.codex-safe-tree-delete-issue42-phase3-prod-failure'
                    message = [string]$_.Exception.Message
                    type = [string]$_.Exception.GetType().FullName
                    chain = @($chain)
                    bytesPerFile = $scaleBytesPerFile
                    attempts = @($phase3Attempts)
                })
                throw
            }
        }
    }
    if ($null -ne $phase3LastError) {
        throw $phase3LastError
    }
    Assert-True ($phase3Prod.plan.fileCount -eq $scaleFileCount) 'phase3-prod Plan 必须覆盖 10000 个文件'
    Assert-True ($phase3Prod.apply.quarantined -eq $true) 'phase3-prod Apply 必须成功'
    Assert-True ($phase3Prod.purge.purged -eq $true) 'phase3-prod Purge 必须成功'
    Assert-True (-not [IO.Directory]::Exists($scaleProdTarget)) 'phase3-prod Purge 后原目标必须不存在'
    Assert-True (-not [IO.Directory]::Exists([string]$phase3Prod.apply.quarantinePath)) `
        'phase3-prod Purge 后 quarantine 必须不存在'
    $phase3Dispositions = Read-JsonDocument -Path ([string]$phase3Prod.purge.leafDispositionsPath)
    Assert-True ([long]$phase3Dispositions.summary.deleted -eq [long]$scaleFileCount) `
        'phase3-prod leafDispositions.deleted 必须对齐 fileCount'
    Assert-True (
        $null -ne $phase3Prod.parallelPurge -and [bool]$phase3Prod.parallelPurge.used
    ) 'phase3-prod 必须走生产 ParallelPurgeCoordinator'

    Write-Stage -Name 'scale-record'
    $baselineMs = [double]$baseline.elapsedMs
    $phase3Ms = [double]$phase3Prod.elapsedMs
    $ratio = if ($baselineMs -gt 0) { $phase3Ms / $baselineMs } else { 0 }
    $speedup = if ($phase3Ms -gt 0) { $baselineMs / $phase3Ms } else { 0 }
    $metBest = ($speedup -ge 6.0)
    $metTypical = ($speedup -ge 4.0)
    $dop1Ms = [double]$rawDop1.wallClockMs
    $dop4Speedup = if ([double]$rawDop4.wallClockMs -gt 0) { $dop1Ms / [double]$rawDop4.wallClockMs } else { 0 }
    $dop2Speedup = if ([double]$rawDop2.wallClockMs -gt 0) { $dop1Ms / [double]$rawDop2.wallClockMs } else { 0 }
    $scaleRecord = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue42-scale-phase3'
        fileCount = $scaleFileCount
        bytesPerFile = $scaleBytesPerFile
        totalBytes = $scaleTotalBytes
        doNotSynthesize6x = $true
        blocked = $false
        baselineReused = [bool]$baselineReused
        phase3ProdAttempts = @($phase3Attempts)
        method = $(if ($baselineReused) {
            'phase3-prod 10k x 4KB Plan→Apply→Purge after snapshot/Apply lease-reuse fix; A.baseline reused from baseline-partial.json (513510ms; trees were cleaned after that run, not rerun). A=production serial HostSafety. B=coordinator File.Delete 10k x 1KB reused from #40 raw. Do not add B into A.'
        } else {
            'sequential 10k x 4KB trees (baseline then phase3-prod; 4KB matches #32/#37 proven Apply hash-reuse size after 1KB exclusive-open failures); same working tree and library; A=production Plan→Apply→Purge (serial HostSafety); B=coordinator File.Delete 10k x 1KB reused from #40 raw. Do not add B into A. phase3-prod retries ERROR_SHARING_VIOLATION (32) up to 3 times with a fresh tree.'
        })
        A_production = [pscustomobject][ordered]@{
            path = 'Plan→Apply→Purge via Invoke-CodexSafeTreeDelete*; Purge = capability-gated ParallelPurgeCoordinator + HostSafety deleter when RecommendParallel'
            baseline = [pscustomobject][ordered]@{
                flags = @(
                    'DisableApplyHashReuseForTest',
                    'DisablePurgeHashReuseForTest',
                    'DisablePurgeBatchForTest'
                )
                reused = [bool]$baselineReused
                source = 'reports/safe-tree-delete-issue42-20260817/baseline-partial.json'
                planElapsedMs = [long]$baseline.planElapsedMs
                applyElapsedMs = [long]$baseline.applyElapsedMs
                purgeElapsedMs = [long]$baseline.purgeElapsedMs
                elapsedMs = [long]$baseline.elapsedMs
                applyBytesHashed = [long]$baseline.applyBytesHashed
                purgeBytesHashed = [long]$baseline.purgeBytesHashed
                leafDispositionsDeleted = [long]$baselineDispositions.summary.deleted
            }
            phase3Prod = [pscustomobject][ordered]@{
                flags = @(
                    'default hash reuse',
                    'default purge batch collect',
                    'production ParallelPurgeCoordinator when RecommendParallel'
                )
                parallelPurge = $phase3Prod.parallelPurge
                completed = $true
                planElapsedMs = [long]$phase3Prod.planElapsedMs
                applyElapsedMs = [long]$phase3Prod.applyElapsedMs
                purgeElapsedMs = [long]$phase3Prod.purgeElapsedMs
                elapsedMs = [long]$phase3Prod.elapsedMs
                applyBytesHashed = [long]$phase3Prod.applyBytesHashed
                purgeBytesHashed = [long]$phase3Prod.purgeBytesHashed
                leafDispositionsDeleted = [long]$phase3Dispositions.summary.deleted
            }
            ratio = [Math]::Round($ratio, 3)
            speedup = [Math]::Round($speedup, 3)
            targetBest = 'A.phase3Prod/A.baseline <= 0.17 (>=6x) — production wall clock only'
            targetTypical = 'A.phase3Prod/A.baseline <= 0.25 (>=4x) — production wall clock only'
            metTargetBest = [bool]$metBest
            metTargetTypical = [bool]$metTypical
        }
        B_coordinator = [pscustomobject][ordered]@{
            path = 'ParallelPurgeCoordinator File.Delete on fixture trees only; not production Purge'
            reusedFrom = '#40'
            rawVerified = $true
            dop1 = [pscustomobject][ordered]@{
                wallClockMs = [long]$rawDop1.wallClockMs
                rawPath = $issue40Dop1Path
                degree = 1
            }
            dop2Typical = [pscustomobject][ordered]@{
                wallClockMs = [long]$rawDop2.wallClockMs
                rawPath = $issue40Dop2Path
                degree = 2
                speedupVsDop1 = [Math]::Round($dop2Speedup, 3)
            }
            dop4Best = [pscustomobject][ordered]@{
                wallClockMs = [long]$rawDop4.wallClockMs
                rawPath = $issue40Dop4Path
                degree = 4
                speedupVsDop1 = [Math]::Round($dop4Speedup, 3)
            }
            note = 'Fixture File.Delete speedups stay in B. Production A uses HostSafety deleter, not these numbers.'
        }
        citations = [pscustomobject][ordered]@{
            issue36 = [pscustomobject][ordered]@{
                speedup = [double]$issue36.speedup
                metTarget = [bool]$issue36.metTarget
                path = $issue36ScalePath
                note = '10k x 160KiB production Plan→Apply→Purge cited from current scale-phase1.json; metTarget=false; not a regression pin'
            }
            issue37 = [pscustomobject][ordered]@{
                speedupVsBaseline = [double]$issue37.speedupVsBaseline
                metTarget = [bool]$issue37.metTarget
                path = $issue37ScalePath
                note = '10k x 4KB Purge batch cited from current scale-10000.json; metTarget=false; not a regression pin'
            }
            issue40 = [pscustomobject][ordered]@{
                analysisPath = $issue40AnalysisPath
                smallDop4Ms = [long]$rawDop4.wallClockMs
                smallDop1Ms = [long]$rawDop1.wallClockMs
                smallDop4Speedup = [Math]::Round($dop4Speedup, 3)
                smallDop2Ms = [long]$rawDop2.wallClockMs
                smallDop2Speedup = [Math]::Round($dop2Speedup, 3)
                note = 'coordinator fixture table from current #40 raw files; not production Purge; wall-clock is cited not pinned'
            }
            issue41 = [pscustomobject][ordered]@{
                overheadPercent = [double]$issue41.OverheadPercent
                isWithinTarget = [bool]$issue41.IsWithinTarget
                path = $issue41ScalePath
                formula = 'TotalFlushTimeMs / elapsedMs * 100; thread-sum flush, not wall-clock disguise'
                note = 'OverheadPercent cited from current scale-10000.json; IsWithinTarget=false; do not pin a historical percentage'
            }
        }
    }
    Write-JsonFile -Path (Join-Path $evidenceHome 'scale-phase3.json') -Document $scaleRecord

    $leftoverGuard = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue42-leftover-guard'
        quarantineExists = [IO.Directory]::Exists($forbiddenQuarantine)
        transactionExists = [IO.File]::Exists($forbiddenTransaction)
        quarantinePath = $forbiddenQuarantine
        transactionPath = $forbiddenTransaction
        touched = $false
    }
    Write-JsonFile -Path (Join-Path $evidenceHome 'leftover-guard.json') -Document $leftoverGuard
    Assert-LeftoverUntouched -When 'after-scale'

    Write-Stage -Name 'done'
    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeletePhase3Integration'
        fileCount = $scaleFileCount
        bytesPerFile = $scaleBytesPerFile
        productionBaselineElapsedMs = [long]$baseline.elapsedMs
        productionPhase3ElapsedMs = [long]$phase3Prod.elapsedMs
        productionSpeedup = $scaleRecord.A_production.speedup
        productionRatio = $scaleRecord.A_production.ratio
        metTargetBest = [bool]$metBest
        metTargetTypical = [bool]$metTypical
        coordinatorDop4Ms = [long]$rawDop4.wallClockMs
        coordinatorDop2Ms = [long]$rawDop2.wallClockMs
        coordinatorDop4SpeedupVsDop1 = [Math]::Round($dop4Speedup, 3)
        networkLiveE2eVerified = $false
        leftoverUntouched = $true
        journalOverheadCited = [double]$issue41.OverheadPercent
        journalOverheadIsWithinTarget = $false
    }
} finally {
    $cleanupPaths = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
            $targetPath,
            $scaleProdTarget,
            $scaleBaselineTarget,
            $fixtureRoot,
            $scaleRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $cleanupPaths.Add($candidate)
        }
    }
    foreach ($result in @($applyResult, $purgeSecurityApply, $e2e, $baseline, $phase3Prod)) {
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
        if ($path -ceq $forbiddenQuarantine) { continue }
        if ([IO.Directory]::Exists($path)) {
            Remove-TestTree -Path $path
        }
    }
    Assert-LeftoverUntouched -When 'finally'
}
