[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$samplePath = Join-Path $fixtureRoot 'identity-sample.bin'
$sampleBytes = [Text.Encoding]::UTF8.GetBytes('codex-safe-tree-delete-file-identity-v2')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function ConvertTo-FileIdHex {
    param([Parameter(Mandatory)][byte[]]$FileId128)
    return [BitConverter]::ToString($FileId128)
}

function Test-FileId128Equal {
    param(
        [Parameter(Mandatory)][byte[]]$Left,
        [Parameter(Mandatory)][byte[]]$Right
    )
    return [Linq.Enumerable]::SequenceEqual($Left, $Right)
}

function Get-NativeErrorCode {
    param([Parameter(Mandatory)]$ErrorRecord)

    $current = $ErrorRecord.Exception
    while ($null -ne $current) {
        if ($current -is [ComponentModel.Win32Exception]) {
            return [int]$current.NativeErrorCode
        }
        $current = $current.InnerException
    }
    return $null
}

function New-FileIdentityV2 {
    param(
        [UInt64]$VolumeSerialNumber = 1UL,
        [byte[]]$FileId128 = [byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16),
        [long]$FileSize = 42L,
        [DateTime]$LastWriteTimeUtc = [DateTime]::new(2026, 8, 13, 12, 0, 0, [DateTimeKind]::Utc),
        [DateTime]$CapturedAtUtc = [DateTime]::new(2026, 8, 13, 12, 0, 1, [DateTimeKind]::Utc)
    )

    $constructed = [CodexSafeTreeDelete.FileIdentityV2]::new()
    $constructed.VolumeSerialNumber = $VolumeSerialNumber
    $constructed.FileId128 = $FileId128
    $constructed.FileSize = $FileSize
    $constructed.LastWriteTimeUtc = $LastWriteTimeUtc
    $constructed.CapturedAtUtc = $CapturedAtUtc
    return $constructed
}

function New-IdentityReparseLink {
    param(
        [Parameter(Mandatory)][ValidateSet('SymbolicLink', 'Junction')][string]$ItemType,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )

    try {
        return New-Item -ItemType $ItemType -Path $Path -Target $Target -ErrorAction Stop
    } catch {
        throw "无法创建 $ItemType 以验证不跟随 reparse：Path=$Path Target=$Target 原因=$($_.Exception.Message)"
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

Assert-True (Test-Path -LiteralPath $identitySourcePath -PathType Leaf) 'RED: CodexSafeTreeDeleteFileIdentity.cs 尚不存在'
. $libraryPath
Assert-True (
    $null -ne (Get-Command -Name Get-CodexSafeTreeDeleteFileIdentityV2 -ErrorAction SilentlyContinue)
) 'RED: Get-CodexSafeTreeDeleteFileIdentityV2 尚不存在'

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [IO.File]::WriteAllBytes($samplePath, $sampleBytes)

    $identity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $samplePath
    Assert-True ($null -ne $identity) 'Get-CodexSafeTreeDeleteFileIdentityV2 必须返回对象'
    Assert-True ($identity.VolumeSerialNumber -is [UInt64]) 'VolumeSerialNumber 必须是 UInt64'
    Assert-True ($identity.VolumeSerialNumber -ne 0UL) 'VolumeSerialNumber 必须非零'
    Assert-True ($null -ne $identity.FileId128) 'FileId128 不得为 null'
    Assert-True ($identity.FileId128 -is [byte[]]) 'FileId128 必须是 byte[]'
    Assert-True ($identity.FileId128.Length -eq 16) "FileId128 长度必须是 16，实际为 $($identity.FileId128.Length)"
    $fileIdIsAllZero = $true
    foreach ($octet in $identity.FileId128) {
        if ($octet -ne [byte]0) {
            $fileIdIsAllZero = $false
            break
        }
    }
    Assert-True (-not $fileIdIsAllZero) 'FileId128 不得全为零'
    Assert-True ($identity.FileSize -is [long]) 'FileSize 必须是 Int64'
    Assert-True ($identity.FileSize -eq [long]$sampleBytes.Length) "FileSize 必须等于写入字节数，实际为 $($identity.FileSize)"
    Assert-True ($identity.LastWriteTimeUtc -is [DateTime]) 'LastWriteTimeUtc 必须是 DateTime'
    Assert-True ($identity.LastWriteTimeUtc.Kind -eq [DateTimeKind]::Utc) 'LastWriteTimeUtc 必须是 UTC'
    $nowUtc = [DateTime]::UtcNow
    $age = $nowUtc - $identity.LastWriteTimeUtc
    Assert-True ($age.TotalMinutes -lt 5 -and $age.TotalMinutes -gt -5) "LastWriteTimeUtc 必须接近当前时间，实际为 $($identity.LastWriteTimeUtc.ToString('o'))"

    $identityAgain = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $samplePath
    Assert-True ($null -ne $identityAgain.FileId128) '第二次调用 FileId128 不得为 null'
    Assert-True ($identityAgain.FileId128.Length -eq 16) '第二次调用 FileId128 长度必须是 16'
    Assert-True (
        (Test-FileId128Equal -Left $identity.FileId128 -Right $identityAgain.FileId128)
    ) '同一文件两次调用的 FileId128 必须一致'
    Assert-True ($identity.VolumeSerialNumber -eq $identityAgain.VolumeSerialNumber) '同一文件两次调用的 VolumeSerialNumber 必须一致'
    Assert-True ($identity.FileSize -eq $identityAgain.FileSize) '同一文件两次调用的 FileSize 必须一致'

    $otherPath = Join-Path $fixtureRoot 'identity-other.bin'
    [IO.File]::WriteAllBytes($otherPath, [Text.Encoding]::UTF8.GetBytes('other-file-identity'))
    $otherIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $otherPath
    Assert-True ($otherIdentity.FileId128.Length -eq 16) '另一文件 FileId128 长度必须是 16'
    Assert-True (
        -not (Test-FileId128Equal -Left $identity.FileId128 -Right $otherIdentity.FileId128)
    ) "两个不同文件的 FileId128 必须不同：left=$(ConvertTo-FileIdHex $identity.FileId128) right=$(ConvertTo-FileIdHex $otherIdentity.FileId128)"

    $missingPath = Join-Path $fixtureRoot 'does-not-exist.bin'
    $missingThrew = $false
    $missingNativeError = $null
    $missingMessage = $null
    try {
        [void](Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $missingPath)
    } catch {
        $missingThrew = $true
        $missingNativeError = Get-NativeErrorCode -ErrorRecord $_
        $missingMessage = $_.Exception.Message
    }
    Assert-True $missingThrew '缺失路径必须失败'
    Assert-True (
        $missingNativeError -eq 2 -or
        $missingNativeError -eq 3
    ) "缺失路径必须以 Win32 ERROR_FILE_NOT_FOUND/ERROR_PATH_NOT_FOUND fail-closed，不得靠 Test-Path 预检：native=$missingNativeError message=$missingMessage"

    $symlinkPath = Join-Path $fixtureRoot 'identity-symlink.bin'
    $null = New-IdentityReparseLink -ItemType SymbolicLink -Path $symlinkPath -Target $samplePath
    $symlinkIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $symlinkPath
    Assert-True ($symlinkIdentity.FileId128.Length -eq 16) 'symlink FileId128 长度必须是 16'
    Assert-True (
        -not (Test-FileId128Equal -Left $symlinkIdentity.FileId128 -Right $identity.FileId128)
    ) "symlink 必须返回 link 自身 FileId128，不得跟随 target：link=$(ConvertTo-FileIdHex $symlinkIdentity.FileId128) target=$(ConvertTo-FileIdHex $identity.FileId128)"

    $junctionTargetDir = Join-Path $fixtureRoot 'junction-target-dir'
    $junctionPath = Join-Path $fixtureRoot 'identity-junction'
    [void][IO.Directory]::CreateDirectory($junctionTargetDir)
    $junctionTargetIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $junctionTargetDir
    $null = New-IdentityReparseLink -ItemType Junction -Path $junctionPath -Target $junctionTargetDir
    $junctionIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $junctionPath
    Assert-True ($junctionIdentity.FileId128.Length -eq 16) 'junction FileId128 长度必须是 16'
    Assert-True (
        -not (Test-FileId128Equal -Left $junctionIdentity.FileId128 -Right $junctionTargetIdentity.FileId128)
    ) "junction 必须返回 link 自身 FileId128，不得跟随 target：link=$(ConvertTo-FileIdHex $junctionIdentity.FileId128) target=$(ConvertTo-FileIdHex $junctionTargetIdentity.FileId128)"

    Assert-True (
        $identity -is [IEquatable[CodexSafeTreeDelete.FileIdentityV2]]
    ) 'FileIdentityV2 必须实现 IEquatable<FileIdentityV2>'

    $mtime = [DateTime]::new(2026, 8, 13, 12, 0, 0, [DateTimeKind]::Utc)
    $fileId = [byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
    $equalLeft = New-FileIdentityV2 -VolumeSerialNumber 0xABCDEF01UL -FileId128 $fileId -FileSize 4096L -LastWriteTimeUtc $mtime -CapturedAtUtc ([DateTime]::new(2026, 8, 13, 12, 0, 1, [DateTimeKind]::Utc))
    $equalRight = New-FileIdentityV2 -VolumeSerialNumber 0xABCDEF01UL -FileId128 ([byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)) -FileSize 4096L -LastWriteTimeUtc $mtime -CapturedAtUtc ([DateTime]::new(2026, 8, 13, 18, 30, 0, [DateTimeKind]::Utc))
    Assert-True ($equalLeft.CapturedAtUtc -ne $equalRight.CapturedAtUtc) '相等性夹具的 CapturedAtUtc 必须不同'
    Assert-True $equalLeft.Equals($equalRight) '字段相同且 CapturedAtUtc 不同时 Equals(FileIdentityV2) 必须为 true'
    Assert-True $equalLeft.Equals([object]$equalRight) '字段相同且 CapturedAtUtc 不同时 Equals(object) 必须为 true'
    Assert-True ($equalLeft -eq $equalRight) '字段相同且 CapturedAtUtc 不同时 == 必须为 true'
    Assert-True (-not ($equalLeft -ne $equalRight)) '字段相同且 CapturedAtUtc 不同时 != 必须为 false'
    Assert-True (
        $equalLeft.GetHashCode() -eq $equalRight.GetHashCode()
    ) '字段相同且 CapturedAtUtc 不同时 GetHashCode 必须相同'

    $cache = [Collections.Generic.Dictionary[CodexSafeTreeDelete.FileIdentityV2, string]]::new()
    $cache.Add($equalLeft, 'session-hash')
    Assert-True $cache.ContainsKey($equalRight) 'Dictionary 必须能用内容相同的另一实例查到键'
    Assert-True ($cache[$equalRight] -ceq 'session-hash') 'Dictionary 用内容相同实例取出的值必须一致'

    $differentFileId = New-FileIdentityV2 -VolumeSerialNumber 0xABCDEF01UL -FileId128 ([byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17)) -FileSize 4096L -LastWriteTimeUtc $mtime -CapturedAtUtc $equalLeft.CapturedAtUtc
    Assert-True (-not $equalLeft.Equals($differentFileId)) 'FileId128 不同时 Equals 必须为 false'
    Assert-True ($equalLeft -ne $differentFileId) 'FileId128 不同时 != 必须为 true'
    Assert-True (-not $cache.ContainsKey($differentFileId)) 'FileId128 不同的实例不得命中 Dictionary 键'

    $shortIdentity = New-FileIdentityV2 -FileId128 ([byte[]](1, 2, 3, 4, 5, 6, 7))
    $shortHashThrew = $false
    try {
        [void]$shortIdentity.GetHashCode()
    } catch {
        $shortHashThrew = $true
    }
    Assert-True $shortHashThrew 'FileId128 不足 8 字节时 GetHashCode 必须 fail-closed，不得吞掉'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteIdentityV2'
        slices = 6
    }
} finally {
    $junctionCleanupPath = Join-Path $fixtureRoot 'identity-junction'
    if ([IO.Directory]::Exists($junctionCleanupPath)) {
        & $env:ComSpec /d /c rmdir $junctionCleanupPath | Out-Null
        if ($LASTEXITCODE -ne 0 -and [IO.Directory]::Exists($junctionCleanupPath)) {
            throw "清理 junction 失败：exit=$LASTEXITCODE path=$junctionCleanupPath"
        }
    }
    $symlinkCleanupPath = Join-Path $fixtureRoot 'identity-symlink.bin'
    if ([IO.File]::Exists($symlinkCleanupPath)) {
        [IO.File]::Delete($symlinkCleanupPath)
    }
    if ([IO.Directory]::Exists($fixtureRoot)) {
        [IO.Directory]::Delete($fixtureRoot, $true)
    }
}
