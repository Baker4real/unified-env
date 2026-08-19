[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$samplePath = Join-Path $fixtureRoot 'filesystem-sample.bin'
$sampleBytes = [Text.Encoding]::UTF8.GetBytes('codex-safe-tree-delete-filesystem-detect')
$deletionDeniedPattern = '不允许删除|FILE_ID_INFO'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Recommendation {
    param(
        [Parameter(Mandatory)][string]$FileSystemType,
        [Parameter(Mandatory)][bool]$IsRemote,
        [Parameter(Mandatory)][bool]$SupportsFileId128,
        [Parameter(Mandatory)][bool]$RecommendHashReuse,
        [Parameter(Mandatory)][bool]$RecommendParallel,
        [Parameter(Mandatory)][int]$RecommendedMaxParallelism,
        [Parameter(Mandatory)][bool]$DeletionAllowed
    )

    $actual = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection(
        $FileSystemType,
        $IsRemote,
        $SupportsFileId128
    )
    $scope = "FromDetection($FileSystemType, remote=$IsRemote, fileId=$SupportsFileId128)"
    Assert-True ($null -ne $actual) "$scope 必须返回对象，不得 throw"
    Assert-True ($actual -is [CodexSafeTreeDelete.FileSystemCapabilities]) "$scope 必须返回 FileSystemCapabilities"
    Assert-True ($actual.FileSystemType -ceq $FileSystemType) "$scope FileSystemType 必须是 $FileSystemType，实际为 $($actual.FileSystemType)"
    Assert-True ($actual.IsRemote -eq $IsRemote) "$scope IsRemote 必须是 $IsRemote"
    Assert-True ($actual.SupportsFileId128 -eq $SupportsFileId128) "$scope SupportsFileId128 必须是 $SupportsFileId128"
    Assert-True ($actual.RecommendHashReuse -eq $RecommendHashReuse) "$scope RecommendHashReuse 必须是 $RecommendHashReuse"
    Assert-True ($actual.RecommendParallel -eq $RecommendParallel) "$scope RecommendParallel 必须是 $RecommendParallel"
    Assert-True (
        $actual.RecommendedMaxParallelism -eq $RecommendedMaxParallelism
    ) "$scope RecommendedMaxParallelism 必须是 $RecommendedMaxParallelism，实际为 $($actual.RecommendedMaxParallelism)"
    Assert-True ($actual.DeletionAllowed -eq $DeletionAllowed) "$scope DeletionAllowed 必须是 $DeletionAllowed"
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

function Get-EvidenceRunDirectories {
    if (-not [IO.Directory]::Exists($evidenceRoot)) { return @() }
    return @([IO.Directory]::GetDirectories($evidenceRoot) | Sort-Object)
}

function New-FileSystemCandidate {
    param([Parameter(Mandatory)][string]$Name)

    $path = Join-Path $fixtureRoot $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $path 'nested'))
    [IO.File]::WriteAllText(
        (Join-Path $path 'payload.txt'),
        "$Name-payload",
        [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-FileSystemFixture {
    param(
        [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Purge')][string]$Mode,
        [string]$TargetPath,
        [string]$PlanPath,
        [string]$ApprovedPlanSha256,
        [string]$TransactionPath,
        [string]$ApprovedTransactionSha256,
        [object]$FileSystemCapabilities,
        [string]$LiveCapabilityRoot,
        [string]$LivePolicyPath,
        [string]$LiveEvidenceRoot,
        [switch]$ConfirmApply,
        [switch]$ConfirmPurge
    )

    $arguments = @{
        Mode = $Mode
        FixturePolicyPath = $(if ([string]::IsNullOrWhiteSpace($LivePolicyPath)) { $policyPath } else { $LivePolicyPath })
        FixtureEvidenceRoot = $(if ([string]::IsNullOrWhiteSpace($LiveEvidenceRoot)) { $evidenceRoot } else { $LiveEvidenceRoot })
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
        $arguments.TargetPath = $TargetPath
        $arguments.CapabilityRoot = $(
            if ([string]::IsNullOrWhiteSpace($LiveCapabilityRoot)) { $fixtureRoot } else { $LiveCapabilityRoot }
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
        $arguments.PlanPath = $PlanPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ApprovedPlanSha256)) {
        $arguments.ApprovedPlanSha256 = $ApprovedPlanSha256
    }
    if (-not [string]::IsNullOrWhiteSpace($TransactionPath)) {
        $arguments.TransactionPath = $TransactionPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ApprovedTransactionSha256)) {
        $arguments.ApprovedTransactionSha256 = $ApprovedTransactionSha256
    }
    if ($ConfirmApply) { $arguments.ConfirmApply = $true }
    if ($ConfirmPurge) { $arguments.ConfirmPurge = $true }
    if ($null -ne $FileSystemCapabilities) {
        $arguments.FixtureFileSystemCapabilities = $FileSystemCapabilities
    }
    return & $entryPath @arguments
}

function Get-DeniedFileSystemCases {
    return @(
        [pscustomobject]@{
            name = 'FAT32'
            capabilities = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('FAT32', $false, $false)
        }
        [pscustomobject]@{
            name = 'exFAT'
            capabilities = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('exFAT', $false, $false)
        }
        [pscustomobject]@{
            name = 'no-FILE_ID_INFO'
            capabilities = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $false, $false)
        }
        [pscustomobject]@{
            name = 'network-no-FILE_ID_INFO'
            capabilities = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $true, $false)
        }
    )
}

function Get-LiveDriveInventory {
    return @([IO.DriveInfo]::GetDrives() | ForEach-Object {
        $ready = [bool]$_.IsReady
        $format = $null
        $label = $null
        if ($ready) {
            $format = [string]$_.DriveFormat
            $label = [string]$_.VolumeLabel
        }
        [pscustomobject][ordered]@{
            name = [string]$_.Name
            root = [string]$_.RootDirectory.FullName
            driveType = [string]$_.DriveType
            isReady = $ready
            driveFormat = $format
            volumeLabel = $label
        }
    })
}

function Find-LiveFatFamilyDrives {
    param([Parameter(Mandatory)][object[]]$Inventory)

    return @($Inventory | Where-Object {
        $_.isReady -and
        -not [string]::IsNullOrWhiteSpace([string]$_.driveFormat) -and
        [string]$_.driveFormat -in @('FAT32', 'exFAT')
    })
}

function Find-LiveNetworkDrives {
    param([Parameter(Mandatory)][object[]]$Inventory)

    return @($Inventory | Where-Object {
        $_.isReady -and [string]$_.driveType -ceq 'Network'
    })
}

function New-LiveVolumeProbeDirectory {
    param([Parameter(Mandatory)][string]$Root)

    $fullRoot = [IO.Path]::GetFullPath($Root)
    $probe = Join-Path $fullRoot ('issue35-live-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $probe 'candidate'))
    [IO.File]::WriteAllText(
        (Join-Path (Join-Path $probe 'candidate') 'payload.txt'),
        'issue35-live-fat-family-payload',
        [Text.UTF8Encoding]::new($false))
    return $probe
}

function Get-LiveDisposableFat32Workspace {
    return 'D:\Codex\temp\issue35-livefs-20260815'
}

function Remove-LiveDisposableFat32Volume {
    param([object]$State)

    if ($null -eq $State) { return }
    $errors = [System.Collections.Generic.List[string]]::new()
    if ([bool]$State.folderMounted -and -not [string]::IsNullOrWhiteSpace([string]$State.mountDir)) {
        try {
            Remove-PartitionAccessPath `
                -DiskNumber ([int]$State.diskNumber) `
                -PartitionNumber ([int]$State.partitionNumber) `
                -AccessPath ([string]$State.mountDir) `
                -ErrorAction Stop
        } catch {
            $errors.Add(('Remove-PartitionAccessPath: ' + $_.Exception.Message)) | Out-Null
        }
    }
    if ([bool]$State.mounted -and -not [string]::IsNullOrWhiteSpace([string]$State.vhdPath)) {
        try {
            Invoke-LiveDiskpartScript -Lines @(
                "select vdisk file=`"$([string]$State.vhdPath)`"",
                'detach vdisk'
            ) | Out-Null
        } catch {
            try {
                Dismount-VHD -Path ([string]$State.vhdPath) -ErrorAction Stop
            } catch {
                $errors.Add(('detach vdisk: ' + $_.Exception.Message)) | Out-Null
            }
        }
    }
    if ([bool]$State.created -and -not [string]::IsNullOrWhiteSpace([string]$State.vhdPath) -and
        [IO.File]::Exists([string]$State.vhdPath)) {
        try {
            [IO.File]::Delete([string]$State.vhdPath)
        } catch {
            $errors.Add(('Delete VHD: ' + $_.Exception.Message)) | Out-Null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$State.mountDir) -and
        [IO.Directory]::Exists([string]$State.mountDir)) {
        try {
            [IO.Directory]::Delete([string]$State.mountDir, $false)
        } catch {
            $errors.Add(('Delete mount dir: ' + $_.Exception.Message)) | Out-Null
        }
    }
    if ($errors.Count -gt 0) {
        throw ('清理一次性 FAT32 VHD 失败：' + ($errors -join ' | '))
    }
}

function Invoke-LiveDiskpartScript {
    param([Parameter(Mandatory)][string[]]$Lines)

    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ('issue35-diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($scriptPath, $Lines, [Text.UTF8Encoding]::new($false))
    try {
        $output = & diskpart.exe /s $scriptPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw ("diskpart 退出码=$LASTEXITCODE 输出=$output")
        }
        return $output
    } finally {
        if ([IO.File]::Exists($scriptPath)) { [IO.File]::Delete($scriptPath) }
    }
}

function New-LiveDisposableFat32Volume {
    $workspace = Get-LiveDisposableFat32Workspace
    $state = [pscustomobject][ordered]@{
        workspace = $workspace
        vhdPath = Join-Path $workspace 'issue35-fat32.vhdx'
        mountDir = Join-Path $workspace 'mnt'
        diskNumber = $null
        partitionNumber = $null
        driveRoot = $null
        folderRoot = $null
        created = $false
        mounted = $false
        formatted = $false
        folderMounted = $false
        folderMountError = $null
    }
    [void][IO.Directory]::CreateDirectory($workspace)
    [void][IO.Directory]::CreateDirectory($state.mountDir)
    if ([IO.File]::Exists($state.vhdPath)) {
        try {
            Invoke-LiveDiskpartScript -Lines @(
                "select vdisk file=`"$($state.vhdPath)`"",
                'detach vdisk'
            ) | Out-Null
        } catch { }
        [IO.File]::Delete($state.vhdPath)
    }

    Import-Module Storage -ErrorAction Stop
    $existingDiskNumbers = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($existing in @(Get-Disk)) {
        [void]$existingDiskNumbers.Add([int]$existing.Number)
    }

    Invoke-LiveDiskpartScript -Lines @(
        "create vdisk file=`"$($state.vhdPath)`" maximum=64 type=expandable",
        "select vdisk file=`"$($state.vhdPath)`"",
        'attach vdisk'
    ) | Out-Null
    $state.created = $true
    $state.mounted = $true

    $newDisks = @(Get-Disk | Where-Object { -not $existingDiskNumbers.Contains([int]$_.Number) })
    if ($newDisks.Count -ne 1) {
        throw ("一次性 VHD 挂载后应出现恰好一块新盘，实际=$($newDisks.Count)")
    }
    $disk = $newDisks[0]
    $state.diskNumber = [int]$disk.Number
    if ($state.diskNumber -in @(0, 1, 2)) {
        throw ("拒绝格式化系统/已有磁盘：VHD DiskNumber=$($state.diskNumber)")
    }
    if ([long]$disk.Size -gt 128MB) {
        throw ("拒绝格式化超标磁盘：Size=$($disk.Size)")
    }
    if ([string]$disk.PartitionStyle -cne 'RAW') {
        throw ("拒绝格式化非 RAW 磁盘：PartitionStyle=$($disk.PartitionStyle)")
    }
    if ([bool]$disk.IsSystem -or [bool]$disk.IsBoot) {
        throw '拒绝格式化系统/引导磁盘。'
    }

    Initialize-Disk -Number $state.diskNumber -PartitionStyle MBR -ErrorAction Stop
    $partition = New-Partition -DiskNumber $state.diskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    $state.partitionNumber = [int]$partition.PartitionNumber
    $null = Format-Volume `
        -Partition $partition `
        -FileSystem FAT32 `
        -NewFileSystemLabel 'ISSUE35' `
        -Confirm:$false `
        -ErrorAction Stop
    $state.formatted = $true
    $letter = [string]$partition.DriveLetter
    if ([string]::IsNullOrWhiteSpace($letter)) {
        $letter = [string]((Get-Partition -DiskNumber $state.diskNumber -PartitionNumber $state.partitionNumber).DriveLetter)
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($letter)) '一次性 FAT32 VHD 必须分配盘符，否则 DriveInfo 看不到 FAT32'
    $state.driveRoot = ($letter.TrimEnd(':') + ':\')
    try {
        Add-PartitionAccessPath `
            -DiskNumber $state.diskNumber `
            -PartitionNumber $state.partitionNumber `
            -AccessPath $state.mountDir `
            -ErrorAction Stop
        $state.folderMounted = $true
        $state.folderRoot = $state.mountDir
    } catch {
        $state.folderRoot = $null
        $state.folderMountError = $_.Exception.Message
    }
    return $state
}

function Get-LivePlanBlockLayer {
    param([Parameter(Mandatory)][string]$Message)

    if ($Message -match $deletionDeniedPattern) { return 'deletion-allowed' }
    if ($Message -match '必须位于 D:\\|必须是 D 盘绝对路径') { return 'd-path-governance' }
    return 'other'
}

function Assert-LiveUnsupportedFileSystem {
    param(
        [Parameter(Mandatory)][string]$ProbeRoot,
        [Parameter(Mandatory)][string]$ExpectedFileSystemType,
        [Parameter(Mandatory)][bool]$ExpectRemote
    )

    $candidate = Join-Path $ProbeRoot 'candidate'
    $capabilities = [CodexSafeTreeDelete.FileSystemDetector]::DetectFileSystem($candidate)
    Assert-True ($null -ne $capabilities) '实卷 DetectFileSystem 必须返回对象'
    Assert-True (
        $capabilities -is [CodexSafeTreeDelete.FileSystemCapabilities]
    ) '实卷 DetectFileSystem 必须返回 FileSystemCapabilities'
    Assert-True (
        $capabilities.FileSystemType -ceq $ExpectedFileSystemType
    ) "实卷 FileSystemType 必须是 $ExpectedFileSystemType，实际为 $($capabilities.FileSystemType)"
    Assert-True ($capabilities.IsRemote -eq $ExpectRemote) "实卷 IsRemote 必须是 $ExpectRemote"
    Assert-True ($capabilities.SupportsFileId128 -eq $false) '不支持 FILE_ID_INFO 的实卷 SupportsFileId128 必须为 false'
    Assert-True ($capabilities.RecommendHashReuse -eq $false) '不支持 FILE_ID_INFO 的实卷 RecommendHashReuse 必须为 false'
    Assert-True ($capabilities.RecommendParallel -eq $false) '不支持 FILE_ID_INFO 的实卷 RecommendParallel 必须为 false'
    Assert-True (
        $capabilities.RecommendedMaxParallelism -eq 1
    ) "不支持 FILE_ID_INFO 的实卷 RecommendedMaxParallelism 必须为 1，实际为 $($capabilities.RecommendedMaxParallelism)"
    Assert-True ($capabilities.DeletionAllowed -eq $false) '不支持 FILE_ID_INFO 的实卷 DeletionAllowed 必须为 false'
    $fileId = [CodexSafeTreeDelete.FileSystemDetector]::TestFileIdSupport($candidate)
    Assert-True ($fileId -eq $false) '实卷 TestFileIdSupport 必须为 false'
    $assertError = Assert-Throws -Message '实卷 Assert-CodexSafeTreeDeleteDeletionAllowed 必须失败闭锁' -Action {
        Assert-CodexSafeTreeDeleteDeletionAllowed -TargetPath $candidate
    }
    Assert-True (
        $assertError -match $deletionDeniedPattern
    ) "实卷共同闭锁必须稳定拒绝，实际为 $assertError"
    return $capabilities
}

function Invoke-LiveUnsupportedPlan {
    param(
        [Parameter(Mandatory)][string]$ProbeRoot,
        [Parameter(Mandatory)][string]$CandidatePath
    )

    $liveEvidence = Join-Path $ProbeRoot 'evidence'
    $livePolicyPath = Join-Path $ProbeRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory($liveEvidence)
    $livePolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'filesystem-live-fat-family'
                capabilityRoot = $ProbeRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($liveEvidence)
            }
        )
    }
    [IO.File]::WriteAllText(
        $livePolicyPath,
        ($livePolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $runsBefore = @(
        if ([IO.Directory]::Exists($liveEvidence)) {
            [IO.Directory]::GetDirectories($liveEvidence) | Sort-Object
        }
    )
    $planError = Assert-Throws -Message '实卷 fixture Plan 必须失败闭锁' -Action {
        Invoke-FileSystemFixture `
            -Mode Plan `
            -TargetPath $CandidatePath `
            -LiveCapabilityRoot $ProbeRoot `
            -LivePolicyPath $livePolicyPath `
            -LiveEvidenceRoot $liveEvidence
    }
    Assert-True ([IO.Directory]::Exists($CandidatePath)) '实卷 Plan 拒绝不得改动 target'
    $runsAfter = @(
        if ([IO.Directory]::Exists($liveEvidence)) {
            [IO.Directory]::GetDirectories($liveEvidence) | Sort-Object
        }
    )
    Assert-True (
        ($runsBefore -join '|') -ceq ($runsAfter -join '|')
    ) '实卷 Plan 拒绝不得写入新 plan/run'
    return [pscustomobject][ordered]@{
        error = $planError
        layer = Get-LivePlanBlockLayer -Message $planError
        evidenceRoot = $liveEvidence
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
) "本测试要求本机 NTFS/ReFS，实际为 $($drive.DriveFormat)"
Assert-True (
    $drive.DriveType -ne [IO.DriveType]::Network
) "本测试要求本地卷，实际 DriveType=$($drive.DriveType)"

Assert-True (Test-Path -LiteralPath $identitySourcePath -PathType Leaf) 'RED: CodexSafeTreeDeleteFileIdentity.cs 尚不存在'
Assert-True (Test-Path -LiteralPath $entryPath -PathType Leaf) 'RED: Invoke-CodexSafeTreeDeleteFixture.ps1 尚不存在'
. $hostSafetyLibraryPath
. $libraryPath
Assert-True (
    $null -ne ('CodexSafeTreeDelete.FileSystemDetector' -as [type])
) 'RED: FileSystemDetector 尚不存在'
Assert-True (
    $null -ne ('CodexSafeTreeDelete.FileSystemCapabilities' -as [type])
) 'RED: FileSystemCapabilities 尚不存在'

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [IO.File]::WriteAllBytes($samplePath, $sampleBytes)

    $capabilities = [CodexSafeTreeDelete.FileSystemDetector]::DetectFileSystem($samplePath)
    Assert-True ($null -ne $capabilities) 'DetectFileSystem 必须返回对象'
    Assert-True (
        $capabilities -is [CodexSafeTreeDelete.FileSystemCapabilities]
    ) 'DetectFileSystem 必须返回 FileSystemCapabilities'
    Assert-True (
        $capabilities.FileSystemType -ceq $drive.DriveFormat
    ) "FileSystemType 必须等于 DriveInfo.DriveFormat，实际为 $($capabilities.FileSystemType)"
    Assert-True ($capabilities.IsRemote -eq $false) '本机卷 IsRemote 必须为 false'
    Assert-True ($capabilities.SupportsFileId128 -eq $true) '本机 NTFS/ReFS SupportsFileId128 必须为 true'
    Assert-True ($capabilities.RecommendHashReuse -eq $true) '本机 NTFS/ReFS RecommendHashReuse 必须为 true'
    Assert-True ($capabilities.RecommendParallel -eq $true) '本机 NTFS/ReFS RecommendParallel 必须为 true'
    Assert-True (
        $capabilities.RecommendedMaxParallelism -eq 2
    ) "本机 NTFS/ReFS RecommendedMaxParallelism 必须为 2（#40 20260819 小文件峰值效率），实际为 $($capabilities.RecommendedMaxParallelism)"
    Assert-True (
        $capabilities.DeletionAllowed -eq $true
    ) '本机 NTFS/ReFS 且支持 FILE_ID_INFO 时 DeletionAllowed 必须为 true'

    $supportsFileId = [CodexSafeTreeDelete.FileSystemDetector]::TestFileIdSupport($samplePath)
    Assert-True ($supportsFileId -eq $true) 'TestFileIdSupport 在支持 FILE_ID_INFO 的文件系统上必须返回 true'
    $missingPath = Join-Path $fixtureRoot 'does-not-exist.bin'
    $missingSupport = [CodexSafeTreeDelete.FileSystemDetector]::TestFileIdSupport($missingPath)
    Assert-True ($missingSupport -eq $false) 'TestFileIdSupport 在无法取得 FILE_ID_INFO 时必须返回 false，不得 throw'
    $missingCapabilities = [CodexSafeTreeDelete.FileSystemDetector]::DetectFileSystem($missingPath)
    Assert-True ($null -ne $missingCapabilities) '缺路径 DetectFileSystem 必须返回对象，不得 throw'
    Assert-True ($missingCapabilities.SupportsFileId128 -eq $false) '缺路径 SupportsFileId128 必须为 false'
    Assert-True ($missingCapabilities.DeletionAllowed -eq $false) '缺路径 DeletionAllowed 必须为 false'

    Assert-Recommendation `
        -FileSystemType 'NTFS' `
        -IsRemote $false `
        -SupportsFileId128 $true `
        -RecommendHashReuse $true `
        -RecommendParallel $true `
        -RecommendedMaxParallelism 2 `
        -DeletionAllowed $true
    Assert-Recommendation `
        -FileSystemType 'ReFS' `
        -IsRemote $false `
        -SupportsFileId128 $true `
        -RecommendHashReuse $true `
        -RecommendParallel $true `
        -RecommendedMaxParallelism 2 `
        -DeletionAllowed $true
    Assert-Recommendation `
        -FileSystemType 'NTFS' `
        -IsRemote $true `
        -SupportsFileId128 $true `
        -RecommendHashReuse $false `
        -RecommendParallel $false `
        -RecommendedMaxParallelism 1 `
        -DeletionAllowed $true
    Assert-Recommendation `
        -FileSystemType 'NTFS' `
        -IsRemote $true `
        -SupportsFileId128 $false `
        -RecommendHashReuse $false `
        -RecommendParallel $false `
        -RecommendedMaxParallelism 1 `
        -DeletionAllowed $false
    Assert-Recommendation `
        -FileSystemType 'FAT32' `
        -IsRemote $false `
        -SupportsFileId128 $false `
        -RecommendHashReuse $false `
        -RecommendParallel $false `
        -RecommendedMaxParallelism 1 `
        -DeletionAllowed $false
    Assert-Recommendation `
        -FileSystemType 'exFAT' `
        -IsRemote $false `
        -SupportsFileId128 $false `
        -RecommendHashReuse $false `
        -RecommendParallel $false `
        -RecommendedMaxParallelism 1 `
        -DeletionAllowed $false

    $fat32Suppressed = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('FAT32', $false, $true)
    Assert-True ($null -ne $fat32Suppressed) 'FAT32 + FileId true 必须返回对象，不得 throw'
    Assert-True ($fat32Suppressed.SupportsFileId128 -eq $false) 'FAT32 必须把 SupportsFileId128 压成 false'
    Assert-True ($fat32Suppressed.RecommendHashReuse -eq $false) 'FAT32 RecommendHashReuse 必须为 false'
    Assert-True ($fat32Suppressed.RecommendParallel -eq $false) 'FAT32 RecommendParallel 必须为 false'
    Assert-True ($fat32Suppressed.RecommendedMaxParallelism -eq 1) 'FAT32 RecommendedMaxParallelism 必须为 1'
    Assert-True ($fat32Suppressed.DeletionAllowed -eq $false) 'FAT32 DeletionAllowed 必须为 false'

    Assert-True (
        $null -ne (Get-Command -Name Assert-CodexSafeTreeDeleteDeletionAllowed -ErrorAction SilentlyContinue)
    ) 'RED: Assert-CodexSafeTreeDeleteDeletionAllowed 尚不存在'

    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'filesystem-deletion-lock-fixture'
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

    Assert-CodexSafeTreeDeleteDeletionAllowed -TargetPath $samplePath
    $missingDeletionError = Assert-Throws -Message '缺路径 DetectFileSystem 必须使删除闭锁失败' -Action {
        Assert-CodexSafeTreeDeleteDeletionAllowed -TargetPath $missingPath
    }
    Assert-True (
        $missingDeletionError -match $deletionDeniedPattern
    ) "缺路径闭锁必须稳定拒绝，实际为 $missingDeletionError"

    $deniedCases = @(Get-DeniedFileSystemCases)
    foreach ($denied in $deniedCases) {
        Assert-True ($denied.capabilities.DeletionAllowed -eq $false) "$($denied.name) 预构造能力必须 DeletionAllowed=false"
        $assertError = Assert-Throws -Message "$($denied.name) 共同闭锁必须拒绝" -Action {
            Assert-CodexSafeTreeDeleteDeletionAllowed `
                -TargetPath $samplePath `
                -FileSystemCapabilitiesForTest $denied.capabilities
        }
        Assert-True (
            $assertError -match $deletionDeniedPattern
        ) "$($denied.name) 共同闭锁必须稳定拒绝，实际为 $assertError"
    }

    $allowedNetwork = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $true, $true)
    Assert-True ($allowedNetwork.DeletionAllowed -eq $true) '网络卷 + FileId 必须允许删除'
    Assert-CodexSafeTreeDeleteDeletionAllowed `
        -TargetPath $samplePath `
        -FileSystemCapabilitiesForTest $allowedNetwork

    foreach ($denied in $deniedCases) {
        $planTarget = New-FileSystemCandidate -Name ("candidate-plan-deny-{0}" -f $denied.name)
        $runsBefore = @(Get-EvidenceRunDirectories)
        $planError = Assert-Throws -Message "$($denied.name) Plan 必须失败闭锁" -Action {
            Invoke-FileSystemFixture `
                -Mode Plan `
                -TargetPath $planTarget `
                -FileSystemCapabilities $denied.capabilities
        }
        Assert-True (
            $planError -match $deletionDeniedPattern
        ) "$($denied.name) Plan 必须稳定拒绝，实际为 $planError"
        Assert-True ([IO.Directory]::Exists($planTarget)) "$($denied.name) Plan 拒绝不得改动 target"
        $runsAfter = @(Get-EvidenceRunDirectories)
        Assert-True (
            ($runsBefore -join '|') -ceq ($runsAfter -join '|')
        ) "$($denied.name) Plan 拒绝不得写入新 plan/run"
    }

    $allowedNetworkTarget = New-FileSystemCandidate -Name 'candidate-plan-allow-network-fileid'
    $allowedNetworkPlan = Invoke-FileSystemFixture `
        -Mode Plan `
        -TargetPath $allowedNetworkTarget `
        -FileSystemCapabilities $allowedNetwork
    Assert-True ($allowedNetworkPlan.planned -eq $true) '网络卷 + FileId 不得被一律禁止 Plan'
    Assert-True ([IO.File]::Exists([string]$allowedNetworkPlan.planPath)) '网络卷 + FileId 的 Plan 必须写出 plan.json'

    $livePlanTarget = New-FileSystemCandidate -Name 'candidate-plan-allow-live-ntfs'
    $livePlan = Invoke-FileSystemFixture -Mode Plan -TargetPath $livePlanTarget
    Assert-True ($livePlan.planned -eq $true) '真实 NTFS DetectFileSystem 路径必须仍能 Plan'
    Assert-True ([IO.File]::Exists([string]$livePlan.planPath)) '真实 NTFS Plan 必须写出 plan.json'

    $applyTarget = New-FileSystemCandidate -Name 'candidate-apply-deny'
    $applyPlan = Invoke-FileSystemFixture -Mode Plan -TargetPath $applyTarget
    Assert-True ($applyPlan.planned -eq $true) 'Apply 拒绝用例的前置 NTFS Plan 必须成功'
    $applyTransactionPath = Join-Path (Split-Path -Parent ([string]$applyPlan.planPath)) 'transaction.json'
    foreach ($denied in $deniedCases) {
        $applyError = Assert-Throws -Message "$($denied.name) Apply 必须失败闭锁" -Action {
            Invoke-FileSystemFixture `
                -Mode Apply `
                -PlanPath ([string]$applyPlan.planPath) `
                -ApprovedPlanSha256 ([string]$applyPlan.planSha256) `
                -ConfirmApply `
                -FileSystemCapabilities $denied.capabilities
        }
        Assert-True (
            $applyError -match $deletionDeniedPattern
        ) "$($denied.name) Apply 必须稳定拒绝，实际为 $applyError"
        Assert-True ([IO.Directory]::Exists($applyTarget)) "$($denied.name) Apply 拒绝不得隔离 target"
        Assert-True (-not [IO.File]::Exists($applyTransactionPath)) "$($denied.name) Apply 拒绝不得写入 transaction"
        $applyQuarantines = @([IO.Directory]::GetDirectories(
            $fixtureRoot,
            '.codex-safe-delete-*.quarantine'))
        Assert-True ($applyQuarantines.Count -eq 0) "$($denied.name) Apply 拒绝不得创建 quarantine"
    }

    $purgeTarget = New-FileSystemCandidate -Name 'candidate-purge-deny'
    $purgePlan = Invoke-FileSystemFixture -Mode Plan -TargetPath $purgeTarget
    $purgeApply = Invoke-FileSystemFixture `
        -Mode Apply `
        -PlanPath ([string]$purgePlan.planPath) `
        -ApprovedPlanSha256 ([string]$purgePlan.planSha256) `
        -ConfirmApply
    Assert-True ($purgeApply.quarantined -eq $true) 'Purge 拒绝用例的前置 Apply 必须成功'
    $purgeTransactionPath = [string]$purgeApply.transactionPath
    $purgeTransactionBefore = [IO.File]::ReadAllBytes($purgeTransactionPath)
    $purgeDispositionsPath = Join-Path (Split-Path -Parent $purgeTransactionPath) 'leaf-dispositions.json'
    foreach ($denied in $deniedCases) {
        $purgeError = Assert-Throws -Message "$($denied.name) Purge 必须失败闭锁" -Action {
            Invoke-FileSystemFixture `
                -Mode Purge `
                -TransactionPath $purgeTransactionPath `
                -ApprovedTransactionSha256 ([string]$purgeApply.transactionSha256) `
                -ConfirmPurge `
                -FileSystemCapabilities $denied.capabilities
        }
        Assert-True (
            $purgeError -match $deletionDeniedPattern
        ) "$($denied.name) Purge 必须稳定拒绝，实际为 $purgeError"
        Assert-True (
            [IO.Directory]::Exists([string]$purgeApply.quarantinePath)
        ) "$($denied.name) Purge 拒绝必须保留 quarantine"
        Assert-True (-not [IO.Directory]::Exists($purgeTarget)) "$($denied.name) Purge 拒绝不得把 target 移回或删除原路径之外的状态"
        Assert-True (-not [IO.File]::Exists($purgeDispositionsPath)) "$($denied.name) Purge 拒绝不得写入 leaf-dispositions"
        $purgeTransactionAfter = [IO.File]::ReadAllBytes($purgeTransactionPath)
        Assert-True (
            [Linq.Enumerable]::SequenceEqual($purgeTransactionBefore, $purgeTransactionAfter)
        ) "$($denied.name) Purge 拒绝不得改写 transaction"
    }

    $liveDriveInventory = @(Get-LiveDriveInventory)
    Assert-True ($liveDriveInventory.Count -gt 0) 'GetDrives 必须返回至少一个盘符'
    $liveFatFamilyDrives = @(Find-LiveFatFamilyDrives -Inventory $liveDriveInventory)
    $liveNetworkDrives = @(Find-LiveNetworkDrives -Inventory $liveDriveInventory)
    $liveVhd = $null
    $liveFatSource = 'existing-volume'
    $livePlan = $null
    $liveFolderPlan = $null
    $liveNetworkNote = $null
    $liveCapabilities = $null
    try {
        if ($liveFatFamilyDrives.Count -eq 0) {
            $liveFatSource = 'disposable-vhd'
            try {
                $liveVhd = New-LiveDisposableFat32Volume
            } catch {
                throw (
                    '无法创建一次性 FAT32 VHD 做实卷验收（未 skip）。盘清单=' + (
                        ($liveDriveInventory | ForEach-Object {
                            '{0} type={1} ready={2} fmt={3}' -f $_.name, $_.driveType, $_.isReady, $_.driveFormat
                        }) -join '; '
                    ) + ' 原始错误=' + $_.Exception.ToString()
                )
            }
            $liveDriveInventory = @(Get-LiveDriveInventory)
            $liveFatFamilyDrives = @(Find-LiveFatFamilyDrives -Inventory $liveDriveInventory)
        }
        Assert-True (
            $liveFatFamilyDrives.Count -gt 0
        ) ('本机仍无真实 FAT32/exFAT 卷，实卷切片不能标绿。盘清单=' + (
            ($liveDriveInventory | ForEach-Object {
                '{0} type={1} ready={2} fmt={3}' -f $_.name, $_.driveType, $_.isReady, $_.driveFormat
            }) -join '; '
        ))

        $liveFat = $liveFatFamilyDrives[0]
        $letterProbe = New-LiveVolumeProbeDirectory -Root $liveFat.root
        $liveCapabilities = Assert-LiveUnsupportedFileSystem `
            -ProbeRoot $letterProbe `
            -ExpectedFileSystemType ([string]$liveFat.driveFormat) `
            -ExpectRemote $false
        $livePlan = Invoke-LiveUnsupportedPlan `
            -ProbeRoot $letterProbe `
            -CandidatePath (Join-Path $letterProbe 'candidate')

        if ($null -ne $liveVhd -and [bool]$liveVhd.folderMounted) {
            $folderProbe = New-LiveVolumeProbeDirectory -Root ([string]$liveVhd.folderRoot)
            $folderCandidate = Join-Path $folderProbe 'candidate'
            $folderCaps = [CodexSafeTreeDelete.FileSystemDetector]::DetectFileSystem($folderCandidate)
            Assert-True ($folderCaps.DeletionAllowed -eq $false) 'D 盘挂载点上的实卷 DeletionAllowed 必须为 false'
            $folderAssertError = Assert-Throws -Message 'D 盘挂载点共同闭锁必须失败' -Action {
                Assert-CodexSafeTreeDeleteDeletionAllowed -TargetPath $folderCandidate
            }
            Assert-True (
                $folderAssertError -match $deletionDeniedPattern
            ) "D 盘挂载点共同闭锁必须稳定拒绝，实际为 $folderAssertError"
            $liveFolderPlan = Invoke-LiveUnsupportedPlan `
                -ProbeRoot $folderProbe `
                -CandidatePath $folderCandidate
        }

        if ($liveNetworkDrives.Count -eq 0) {
            $liveNetworkNote = '本机无网络卷，未验证'
        } else {
            $networkProbe = New-LiveVolumeProbeDirectory -Root $liveNetworkDrives[0].root
            $networkCandidate = Join-Path $networkProbe 'candidate'
            $networkCaps = [CodexSafeTreeDelete.FileSystemDetector]::DetectFileSystem($networkCandidate)
            Assert-True ($networkCaps.IsRemote -eq $true) '网络卷 DetectFileSystem.IsRemote 必须为 true'
            Assert-True ($networkCaps.RecommendHashReuse -eq $false) '网络卷 RecommendHashReuse 必须为 false'
            Assert-True ($networkCaps.RecommendParallel -eq $false) '网络卷 RecommendParallel 必须为 false'
            Assert-True (
                $networkCaps.RecommendedMaxParallelism -eq 1
            ) '网络卷 RecommendedMaxParallelism 必须为 1'
            if ($networkCaps.DeletionAllowed -eq $false) {
                $networkPlan = Invoke-LiveUnsupportedPlan `
                    -ProbeRoot $networkProbe `
                    -CandidatePath $networkCandidate
                Assert-True (
                    $networkPlan.layer -ceq 'deletion-allowed'
                ) "网络且无 FileId 时 Plan 必须因 DeletionAllowed 拒绝，实际层=$($networkPlan.layer) 错误=$($networkPlan.error)"
                $liveNetworkNote = 'network-deletion-denied'
            } else {
                $liveNetworkNote = 'network-fileid-allowed-not-denied'
            }
        }
    } finally {
        if ($null -ne $liveVhd) {
            Remove-LiveDisposableFat32Volume -State $liveVhd
        }
    }

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteFileSystem'
        slices = 7
        liveDriveInventory = $liveDriveInventory
        liveFatSource = $liveFatSource
        liveFatFileSystemType = [string]$liveCapabilities.FileSystemType
        liveFatDeletionAllowed = [bool]$liveCapabilities.DeletionAllowed
        livePlanLayer = $(if ($null -eq $livePlan) { $null } else { [string]$livePlan.layer })
        livePlanError = $(if ($null -eq $livePlan) { $null } else { [string]$livePlan.error })
        liveFolderPlanLayer = $(if ($null -eq $liveFolderPlan) { $null } else { [string]$liveFolderPlan.layer })
        liveFolderPlanError = $(if ($null -eq $liveFolderPlan) { $null } else { [string]$liveFolderPlan.error })
        liveNetworkDriveCount = $liveNetworkDrives.Count
        liveNetworkNote = $liveNetworkNote
    }
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) {
        [IO.Directory]::Delete($fixtureRoot, $true)
    }
}
