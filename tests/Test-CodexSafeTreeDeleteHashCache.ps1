[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$identitySourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteFileIdentity.cs'
$hashCacheSourcePath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteHashCache.cs'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$samplePath = Join-Path $fixtureRoot 'hash-sample.bin'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-ByteArrayEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right) {
        return $false
    }
    return [Linq.Enumerable]::SequenceEqual($Left, $Right)
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

function Get-FileHandlePosition {
    param([Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)

    $position = -1L
    $ok = [CodexSafeTreeDeleteHashCacheTests.NativeMethods]::SetFilePointerEx(
        $Handle,
        0L,
        [ref]$position,
        [CodexSafeTreeDeleteHashCacheTests.NativeMethods]::FileCurrent
    )
    if (-not $ok) {
        throw (New-Object ComponentModel.Win32Exception)
    }
    return $position
}

function Set-FileHandlePosition {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory)][long]$Position
    )

    $newPosition = -1L
    $ok = [CodexSafeTreeDeleteHashCacheTests.NativeMethods]::SetFilePointerEx(
        $Handle,
        $Position,
        [ref]$newPosition,
        [CodexSafeTreeDeleteHashCacheTests.NativeMethods]::FileBegin
    )
    if (-not $ok) {
        throw (New-Object ComponentModel.Win32Exception)
    }
    return $newPosition
}

$runtimeEdition = [string]$PSVersionTable.PSEdition
$runtimeMajor = [int]$PSVersionTable.PSVersion.Major
$runtimeMinor = [int]$PSVersionTable.PSVersion.Minor
Assert-True ($runtimeEdition -ceq 'Core') "本测试要求 PowerShell Core，实际为 $runtimeEdition"
Assert-True (
    $runtimeMajor -gt 7 -or
    ($runtimeMajor -eq 7 -and $runtimeMinor -ge 6)
) "本测试要求 PowerShell 7.6+，实际为 $($PSVersionTable.PSVersion)"

Assert-True (Test-Path -LiteralPath $identitySourcePath -PathType Leaf) 'CodexSafeTreeDeleteFileIdentity.cs 必须存在'
Assert-True (Test-Path -LiteralPath $hashCacheSourcePath -PathType Leaf) 'RED: CodexSafeTreeDeleteHashCache.cs 尚不存在'

if (-not ('CodexSafeTreeDelete.SessionHashCache' -as [type])) {
    Add-Type -Path $identitySourcePath, $hashCacheSourcePath -ErrorAction Stop
}

if (-not ('CodexSafeTreeDeleteHashCacheTests.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexSafeTreeDeleteHashCacheTests
{
    public static class NativeMethods
    {
        public const uint FileBegin = 0;
        public const uint FileCurrent = 1;

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetFilePointerEx(
            SafeFileHandle hFile,
            long liDistanceToMove,
            out long lpNewFilePointer,
            uint dwMoveMethod);
    }
}
'@
}

Assert-True (
    $null -ne ('CodexSafeTreeDelete.SessionHashCache' -as [type])
) 'RED: SessionHashCache 尚不存在'
Assert-True (
    $null -ne ('CodexSafeTreeDelete.FileHashComputer' -as [type])
) 'RED: FileHashComputer 尚不存在'
Assert-True (
    $null -ne [CodexSafeTreeDelete.FileHashComputer].GetMethod('ComputeHashFromHandle')
) 'RED: ComputeHashFromHandle 尚不存在'

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)

    $identity = New-FileIdentityV2
    $equalIdentity = New-FileIdentityV2 -CapturedAtUtc ([DateTime]::new(2026, 8, 13, 18, 30, 0, [DateTimeKind]::Utc))
    $otherIdentity = New-FileIdentityV2 -FileId128 ([byte[]](16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1))
    $storedHash = [byte[]](1..32)
    $cache = [CodexSafeTreeDelete.SessionHashCache]::new()

    $miss = Invoke-SessionHashCacheTryGet -Cache $cache -Identity $identity
    Assert-True (-not $miss.Hit) '缓存未命中时 TryGet 必须返回 false'
    Assert-True ($null -eq $miss.Hash) '缓存未命中时哈希必须为 null'

    $cache.Set($identity, $storedHash)
    $hit = Invoke-SessionHashCacheTryGet -Cache $cache -Identity $equalIdentity
    Assert-True $hit.Hit '相等 identity（含不同 CapturedAtUtc）必须命中缓存'
    Assert-True ($null -ne $hit.Hash) '缓存命中时哈希不得为 null'
    Assert-True ($hit.Hash.Length -eq 32) '缓存命中时哈希长度必须为 32'
    Assert-True (
        (Test-ByteArrayEqual -Left $hit.Hash -Right $storedHash)
    ) '缓存命中时必须返回写入的哈希'

    $hit.Hash[0] = 0
    $storedHash[0] = 99
    $afterMutation = Invoke-SessionHashCacheTryGet -Cache $cache -Identity $identity
    Assert-True (
        $afterMutation.Hash[0] -eq 1
    ) '调用方改返回值或 Set 入参不得改写缓存内哈希'

    $otherLookup = Invoke-SessionHashCacheTryGet -Cache $cache -Identity $otherIdentity
    Assert-True (-not $otherLookup.Hit) '不同 FileId128 不得命中缓存'
    Assert-True ($null -eq $otherLookup.Hash) '不同 FileId128 未命中时哈希必须为 null'

    $cache.Clear()
    $cleared = Invoke-SessionHashCacheTryGet -Cache $cache -Identity $identity
    Assert-True (-not $cleared.Hit) 'Clear 之后 TryGet 必须未命中'
    Assert-True ($null -eq $cleared.Hash) 'Clear 之后哈希必须为 null'

    $sampleBytes = [byte[]]::new(256)
    for ($i = 0; $i -lt $sampleBytes.Length; $i++) {
        $sampleBytes[$i] = [byte]($i -band 0xFF)
    }
    [IO.File]::WriteAllBytes($samplePath, $sampleBytes)
    $expectedHash = [Security.Cryptography.SHA256]::HashData($sampleBytes)

    $handle = [IO.File]::OpenHandle($samplePath)
    try {
        $before = Set-FileHandlePosition -Handle $handle -Position 100L
        Assert-True ($before -eq 100L) '夹具必须先把 handle position 设到 100'
        Assert-True ((Get-FileHandlePosition -Handle $handle) -eq 100L) '调用前 position 必须为 100'

        $firstHash = [CodexSafeTreeDelete.FileHashComputer]::ComputeHashFromHandle($handle)
        Assert-True ((Get-FileHandlePosition -Handle $handle) -eq 0L) `
            'ComputeHashFromHandle 在 position=100 调用后必须回到 0'
        Assert-True ($null -ne $firstHash) 'ComputeHashFromHandle 必须返回哈希'
        Assert-True ($firstHash.Length -eq 32) 'SHA-256 必须是 32 字节'
        Assert-True (
            (Test-ByteArrayEqual -Left $firstHash -Right $expectedHash)
        ) 'ComputeHashFromHandle 必须返回文件内容的 SHA-256'

        $secondHash = [CodexSafeTreeDelete.FileHashComputer]::ComputeHashFromHandle($handle)
        Assert-True ((Get-FileHandlePosition -Handle $handle) -eq 0L) `
            '第二次 ComputeHashFromHandle 之后 position 必须仍为 0'
        Assert-True (
            (Test-ByteArrayEqual -Left $firstHash -Right $secondHash)
        ) '同一文件两次 ComputeHashFromHandle 必须返回相同哈希'
    } finally {
        $handle.Dispose()
    }

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteHashCache'
        slices = 5
    }
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) {
        [IO.Directory]::Delete($fixtureRoot, $true)
    }
}
