[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$samplePath = Join-Path $fixtureRoot 'hash-sample.bin'
$otherPath = Join-Path $fixtureRoot 'hash-other.bin'
$largePath = Join-Path $fixtureRoot 'hash-large.bin'
$symlinkPath = Join-Path $fixtureRoot 'hash-symlink.bin'
$sampleBytes = [Text.Encoding]::UTF8.GetBytes('codex-safe-tree-delete-hash-safely')
$otherBytes = [Text.Encoding]::UTF8.GetBytes('codex-safe-tree-delete-hash-other')

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

function Get-NativeErrorCode {
    param([Parameter(Mandatory)]$ErrorRecord)

    $current = $ErrorRecord.Exception
    while ($null -ne $current) {
        if ($current -is [ComponentModel.Win32Exception]) {
            return [int]$current.NativeErrorCode
        }
        if ($current.HResult -ne 0 -and ($current.HResult -band 0xFFFF) -eq 32) {
            return 32
        }
        $current = $current.InnerException
    }
    return $null
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

Assert-True (Test-Path -LiteralPath $libraryPath -PathType Leaf) 'CodexSafeTreeDelete.ps1 必须存在'
. $libraryPath
Assert-True (
    $null -ne ('CodexSafeTreeDelete.SessionHashCache' -as [type])
) 'RED: CodexSafeTreeDelete.ps1 必须加载 HashCache.cs'
Assert-True (
    $null -ne ('CodexSafeTreeDelete.IdentityMismatchException' -as [type])
) 'RED: IdentityMismatchException 尚不存在'
Assert-True (
    $null -ne [CodexSafeTreeDelete.FileHashComputer].GetMethod('GetHashSafely')
) 'RED: GetHashSafely 尚不存在'
Assert-True (
    $null -ne (Get-Command -Name Get-CodexSafeTreeDeleteHashSafely -ErrorAction SilentlyContinue)
) 'RED: Get-CodexSafeTreeDeleteHashSafely 尚不存在'

if (-not ('CodexSafeTreeDeleteHashSafelyTests.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace CodexSafeTreeDeleteHashSafelyTests
{
    public sealed class ShareProbeState
    {
        public bool Ready;
        public bool Stop;
        public bool Denied;
    }

    public static class NativeMethods
    {
        public const uint GenericRead = 0x80000000;
        public const uint GenericWrite = 0x40000000;
        public const uint OpenExisting = 3;
        public const uint FileFlagBackupSemantics = 0x02000000;
        public const uint FileFlagOpenReparsePoint = 0x00200000;
        public const uint FsctlSetSparse = 0x000900C4;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint controlCode,
            IntPtr inputBuffer,
            uint inputBufferSize,
            IntPtr outputBuffer,
            uint outputBufferSize,
            out uint bytesReturned,
            IntPtr overlapped);

        public static int TryOpen(string path, uint desiredAccess, FileShare shareMode)
        {
            using (SafeFileHandle handle = CreateFileW(
                path,
                desiredAccess,
                shareMode,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    return Marshal.GetLastWin32Error();
                }

                return 0;
            }
        }

        public static int TryOpenWrite(string path)
        {
            return TryOpen(path, GenericWrite, FileShare.ReadWrite);
        }

        public static SafeFileHandle OpenReadShareRead(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                GenericRead,
                FileShare.Read,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Failed to open a FileShare.Read probe handle.");
            }

            return handle;
        }

        public static void CreateSparseZeroFile(string path, long length)
        {
            using (FileStream stream = new FileStream(
                path,
                FileMode.CreateNew,
                FileAccess.ReadWrite,
                FileShare.None))
            {
                uint bytesReturned;
                if (!DeviceIoControl(
                    stream.SafeFileHandle,
                    FsctlSetSparse,
                    IntPtr.Zero,
                    0,
                    IntPtr.Zero,
                    0,
                    out bytesReturned,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Unable to mark the large-file fixture sparse.");
                }

                stream.SetLength(length);
                stream.Flush(true);
            }
        }

        public static void SpinUntilSharingViolation(string path, ShareProbeState state)
        {
            Volatile.Write(ref state.Ready, true);
            while (!Volatile.Read(ref state.Stop))
            {
                if (TryOpenWrite(path) == 32)
                {
                    state.Denied = true;
                    return;
                }
            }
        }
    }
}
'@
}

function Invoke-HashSafelyWhileProbingWriters {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][long]$Length
    )

    [CodexSafeTreeDeleteHashSafelyTests.NativeMethods]::CreateSparseZeroFile($LiteralPath, $Length)
    $currentIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $LiteralPath
    $sessionCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $state = [CodexSafeTreeDeleteHashSafelyTests.ShareProbeState]::new()
    $probe = [powershell]::Create()
    try {
        $null = $probe.AddScript({
            param($TargetPath, $ProbeState)
            [CodexSafeTreeDeleteHashSafelyTests.NativeMethods]::SpinUntilSharingViolation(
                $TargetPath,
                $ProbeState
            )
        }).AddArgument($LiteralPath).AddArgument($state)
        $async = $probe.BeginInvoke()
        $readyDeadline = [datetime]::UtcNow.AddSeconds(5)
        while (-not $state.Ready -and [datetime]::UtcNow -lt $readyDeadline) {
            Start-Sleep -Milliseconds 1
        }
        Assert-True $state.Ready 'sharing 探测线程必须在哈希前进入自旋'
        try {
            [void](Get-CodexSafeTreeDeleteHashSafely `
                -LiteralPath $LiteralPath `
                -ExpectedIdentity $currentIdentity `
                -SessionCache $sessionCache)
        } finally {
            $state.Stop = $true
            $null = $probe.EndInvoke($async)
        }
    } finally {
        $probe.Dispose()
    }

    return [bool]$state.Denied
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [IO.File]::WriteAllBytes($samplePath, $sampleBytes)
    [IO.File]::WriteAllBytes($otherPath, $otherBytes)
    $expectedHash = [Security.Cryptography.SHA256]::HashData($sampleBytes)
    $identity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $samplePath
    $otherIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $otherPath
    Assert-True ($identity -ne $otherIdentity) '两个不同文件的 FileIdentityV2 必须不同'

    $cache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $firstHash = Get-CodexSafeTreeDeleteHashSafely `
        -LiteralPath $samplePath `
        -ExpectedIdentity $identity `
        -SessionCache $cache
    Assert-True ($null -ne $firstHash) 'identity 匹配且 cache 空时必须算出哈希'
    Assert-True ($firstHash.Length -eq 32) 'SHA-256 必须是 32 字节'
    Assert-True (
        (Test-ByteArrayEqual -Left $firstHash -Right $expectedHash)
    ) 'GetHashSafely 必须返回文件内容的 SHA-256'
    $afterFirst = Invoke-SessionHashCacheTryGet -Cache $cache -Identity $identity
    Assert-True $afterFirst.Hit '第一次计算后必须写入 session cache'
    Assert-True (
        (Test-ByteArrayEqual -Left $afterFirst.Hash -Right $expectedHash)
    ) '写入 cache 的哈希必须与计算结果相同'

    $secondHash = Get-CodexSafeTreeDeleteHashSafely `
        -LiteralPath $samplePath `
        -ExpectedIdentity $identity `
        -SessionCache $cache
    Assert-True (
        (Test-ByteArrayEqual -Left $secondHash -Right $firstHash)
    ) '第二次同 identity 必须返回相同哈希'

    $sentinel = [byte[]](1..32)
    $hitCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $hitCache.Set($identity, $sentinel)
    $cachedHash = Get-CodexSafeTreeDeleteHashSafely `
        -LiteralPath $samplePath `
        -ExpectedIdentity $identity `
        -SessionCache $hitCache
    Assert-True (
        (Test-ByteArrayEqual -Left $cachedHash -Right $sentinel)
    ) 'cache 命中时必须返回缓存哈希，不得重算文件内容'
    Assert-True (
        -not (Test-ByteArrayEqual -Left $cachedHash -Right $expectedHash)
    ) 'cache 命中返回值不得被文件真实哈希替换'

    $mismatchCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $mismatchSentinel = [byte[]](32..1)
    $mismatchCache.Set($otherIdentity, $mismatchSentinel)
    $mismatchThrew = $false
    $mismatchException = $null
    try {
        [void](Get-CodexSafeTreeDeleteHashSafely `
            -LiteralPath $samplePath `
            -ExpectedIdentity $otherIdentity `
            -SessionCache $mismatchCache)
    } catch {
        $mismatchThrew = $true
        $mismatchException = Test-IdentityMismatchException -ErrorRecord $_
    }
    Assert-True $mismatchThrew 'identity 不匹配时必须抛出异常'
    Assert-True (
        $null -ne $mismatchException
    ) 'identity 不匹配时必须抛出 IdentityMismatchException，不得读内容后写成别的异常'
    $afterMismatchExpected = Invoke-SessionHashCacheTryGet -Cache $mismatchCache -Identity $otherIdentity
    $afterMismatchActual = Invoke-SessionHashCacheTryGet -Cache $mismatchCache -Identity $identity
    Assert-True $afterMismatchExpected.Hit '不匹配不得改写已有 cache 条目'
    Assert-True (
        (Test-ByteArrayEqual -Left $afterMismatchExpected.Hash -Right $mismatchSentinel)
    ) '不匹配不得把错误哈希写入 expected identity'
    Assert-True (-not $afterMismatchActual.Hit) '不匹配不得把当前文件哈希写入 cache'

    $reader = [CodexSafeTreeDeleteHashSafelyTests.NativeMethods]::OpenReadShareRead($samplePath)
    try {
        $shareThrew = $false
        $shareNativeError = $null
        try {
            [void](Get-CodexSafeTreeDeleteHashSafely `
                -LiteralPath $samplePath `
                -ExpectedIdentity $identity `
                -SessionCache $cache)
        } catch {
            $shareThrew = $true
            $shareNativeError = Get-NativeErrorCode -ErrorRecord $_
        }
        Assert-True $shareThrew '已有 FileShare.Read 句柄时 GetHashSafely 必须失败'
        Assert-True (
            $shareNativeError -eq 32
        ) "GetHashSafely 必须使用 FileShare.None：已有读者时应得到 sharing violation 32，实际为 $shareNativeError"
    } finally {
        $reader.Dispose()
    }

    $releasedStream = [IO.File]::Open(
        $samplePath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite
    )
    $releasedStream.Dispose()

    $writeDenied = Invoke-HashSafelyWhileProbingWriters `
        -LiteralPath $largePath `
        -Length (256L * 1024L * 1024L)
    if (-not $writeDenied) {
        $retryPath = Join-Path $fixtureRoot 'hash-large-retry.bin'
        $writeDenied = Invoke-HashSafelyWhileProbingWriters `
            -LiteralPath $retryPath `
            -Length (1024L * 1024L * 1024L)
    }
    Assert-True $writeDenied '打开期间另一路 CreateFile/FileStream 写入必须因 FileShare.None 得到 sharing violation'

    $null = New-IdentityReparseLink -ItemType SymbolicLink -Path $symlinkPath -Target $samplePath
    $linkIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $symlinkPath
    Assert-True ($linkIdentity -ne $identity) 'symlink 与 target 的 FileIdentityV2 必须不同'
    $linkCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $linkMismatchThrew = $false
    $linkMismatchException = $null
    try {
        [void](Get-CodexSafeTreeDeleteHashSafely `
            -LiteralPath $symlinkPath `
            -ExpectedIdentity $identity `
            -SessionCache $linkCache)
    } catch {
        $linkMismatchThrew = $true
        $linkMismatchException = Test-IdentityMismatchException -ErrorRecord $_
    }
    Assert-True $linkMismatchThrew '对 symlink 传入 target identity 必须失败，不得跟随 target 去 hash'
    Assert-True (
        $null -ne $linkMismatchException
    ) '不跟随 symlink 时必须抛出 IdentityMismatchException'
    $linkCacheAfterMismatch = Invoke-SessionHashCacheTryGet -Cache $linkCache -Identity $identity
    $linkOwnAfterMismatch = Invoke-SessionHashCacheTryGet -Cache $linkCache -Identity $linkIdentity
    Assert-True (-not $linkCacheAfterMismatch.Hit) '跟随失败不得把 target identity 写入 cache'
    Assert-True (-not $linkOwnAfterMismatch.Hit) 'identity 不匹配时不得把 link 自身哈希写入 cache'

    $linkOwnCache = [CodexSafeTreeDelete.SessionHashCache]::new()
    $linkOwnHash = $null
    $linkOwnMismatch = $null
    try {
        $linkOwnHash = Get-CodexSafeTreeDeleteHashSafely `
            -LiteralPath $symlinkPath `
            -ExpectedIdentity $linkIdentity `
            -SessionCache $linkOwnCache
    } catch {
        $linkOwnMismatch = Test-IdentityMismatchException -ErrorRecord $_
        if ($null -ne $linkOwnMismatch) {
            throw '对 link 自身 identity 若 IdentityMismatch，说明跟随了 target'
        }
    }
    if ($null -ne $linkOwnHash) {
        Assert-True (
            -not (Test-ByteArrayEqual -Left $linkOwnHash -Right $expectedHash)
        ) 'hash symlink 不得得到 target 文件内容的 SHA-256'
    }

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteHashSafely'
        slices = 7
    }
} finally {
    $symlinkCleanupPath = Join-Path $fixtureRoot 'hash-symlink.bin'
    if ([IO.File]::Exists($symlinkCleanupPath)) {
        [IO.File]::Delete($symlinkCleanupPath)
    }
    if ([IO.Directory]::Exists($fixtureRoot)) {
        [IO.Directory]::Delete($fixtureRoot, $true)
    }
}
