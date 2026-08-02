[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1')

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw "断言失败：$Message" }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    } catch {
        return $_.Exception.Message
    }
    throw "未拒绝：$Message"
}

function Invoke-HiddenProcess {
    param([Parameter(Mandatory)][string]$FilePath,[Parameter(Mandatory)][string[]]$Arguments)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() "子进程无法启动：$FilePath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-True ($process.WaitForExit(10000)) "子进程超时：$FilePath"
        [pscustomobject]@{ exitCode=$process.ExitCode; stdout=$stdoutTask.GetAwaiter().GetResult(); stderr=$stderrTask.GetAwaiter().GetResult() }
    } finally {
        if (-not $process.HasExited) { try { $process.Kill($true) } catch {} }
        $process.Dispose()
    }
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexHookGovernanceTests
{
    public sealed class RenameAttempt
    {
        public RenameAttempt(bool moved, int win32Error)
        {
            Moved = moved;
            Win32Error = win32Error;
        }

        public bool Moved { get; }
        public int Win32Error { get; }
    }

    public static class DirectoryRenameAttacker
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileExW(string existingPath, string newPath, uint flags);

        public static RenameAttempt TryMove(string source, string destination)
        {
            bool moved = MoveFileExW(source, destination, 0);
            return new RenameAttempt(moved, moved ? 0 : Marshal.GetLastWin32Error());
        }
    }

    public sealed class ReparseAttackResult
    {
        public ReparseAttackResult(bool openSucceeded, int openWin32Error, bool setSucceeded, int setWin32Error)
        {
            OpenSucceeded = openSucceeded;
            OpenWin32Error = openWin32Error;
            SetSucceeded = setSucceeded;
            SetWin32Error = setWin32Error;
        }

        public bool OpenSucceeded { get; }
        public int OpenWin32Error { get; }
        public bool SetSucceeded { get; }
        public int SetWin32Error { get; }
    }

    public static class DirectoryReparseAttacker
    {
        private const uint GenericWrite = 0x40000000;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FsctlSetReparsePoint = 0x000900A4;
        private const uint IoReparseTagMountPoint = 0xA0000003;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint controlCode,
            byte[] inputBuffer,
            int inputBufferSize,
            IntPtr outputBuffer,
            int outputBufferSize,
            out int bytesReturned,
            IntPtr overlapped);

        public static ReparseAttackResult TrySetMountPoint(string directoryPath, string targetPath)
        {
            SafeFileHandle handle = CreateFileW(
                Path.GetFullPath(directoryPath),
                GenericWrite,
                FileShare.Read | FileShare.Write | FileShare.Delete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int openError = Marshal.GetLastWin32Error();
                handle.Dispose();
                return new ReparseAttackResult(false, openError, false, 0);
            }

            try
            {
                byte[] buffer = BuildMountPointBuffer(Path.GetFullPath(targetPath));
                int bytesReturned;
                bool set = DeviceIoControl(
                    handle,
                    FsctlSetReparsePoint,
                    buffer,
                    buffer.Length,
                    IntPtr.Zero,
                    0,
                    out bytesReturned,
                    IntPtr.Zero);
                return new ReparseAttackResult(true, 0, set, set ? 0 : Marshal.GetLastWin32Error());
            }
            finally
            {
                handle.Dispose();
            }
        }

        private static byte[] BuildMountPointBuffer(string targetPath)
        {
            string substituteName = @"\??\" + targetPath;
            string printName = targetPath;
            byte[] substituteBytes = Encoding.Unicode.GetBytes(substituteName);
            byte[] printBytes = Encoding.Unicode.GetBytes(printName);
            ushort printOffset = checked((ushort)(substituteBytes.Length + sizeof(char)));
            int pathBufferLength = printOffset + printBytes.Length + sizeof(char);
            ushort reparseDataLength = checked((ushort)(8 + pathBufferLength));
            byte[] buffer = new byte[8 + reparseDataLength];

            Buffer.BlockCopy(BitConverter.GetBytes(IoReparseTagMountPoint), 0, buffer, 0, sizeof(uint));
            Buffer.BlockCopy(BitConverter.GetBytes(reparseDataLength), 0, buffer, 4, sizeof(ushort));
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)0), 0, buffer, 6, sizeof(ushort));
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)0), 0, buffer, 8, sizeof(ushort));
            Buffer.BlockCopy(BitConverter.GetBytes(checked((ushort)substituteBytes.Length)), 0, buffer, 10, sizeof(ushort));
            Buffer.BlockCopy(BitConverter.GetBytes(printOffset), 0, buffer, 12, sizeof(ushort));
            Buffer.BlockCopy(BitConverter.GetBytes(checked((ushort)printBytes.Length)), 0, buffer, 14, sizeof(ushort));
            Buffer.BlockCopy(substituteBytes, 0, buffer, 16, substituteBytes.Length);
            Buffer.BlockCopy(printBytes, 0, buffer, 16 + printOffset, printBytes.Length);
            return buffer;
        }
    }
}
'@

$fixtureRoot = Join-Path $ProjectRoot 'reports\codex-hook-deployment-test'
$testRoot = Join-Path $fixtureRoot 'directory-guard-test'
$externalRoot = Join-Path $fixtureRoot 'directory-guard-external'
foreach ($path in @($testRoot, $externalRoot)) {
    if ([IO.Directory]::Exists($path)) { Remove-Item -LiteralPath $path -Recurse -Force }
    [void][IO.Directory]::CreateDirectory($path)
}
$guardedParent = Join-Path $testRoot 'existing-parent'
[void][IO.Directory]::CreateDirectory($guardedParent)
$parkedParent = Join-Path $testRoot 'parked-parent'

$guard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $guardedParent
try {
    $renameAttempt = [CodexHookGovernanceTests.DirectoryRenameAttacker]::TryMove($guardedParent, $parkedParent)
    if ($renameAttempt.Moved) {
        New-Item -ItemType Junction -Path $guardedParent -Target $externalRoot | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $guardedParent 'payload.txt'), 'guarded', [Text.UTF8Encoding]::new($false))

    Assert-True (-not $renameAttempt.Moved -and $renameAttempt.Win32Error -eq 32) 'guard 存活时另一路 rename 必须以 Win32 sharing violation 32 失败'
    Assert-True ([IO.Directory]::Exists($guardedParent) -and -not [IO.Directory]::Exists($parkedParent)) 'guarded parent identity 必须保持原路径'
    Assert-True (@(Get-ChildItem -LiteralPath $externalRoot -Force).Count -eq 0) 'rename+junction 攻击不得向外部 root 写入 payload'
} finally {
    $guard.Dispose()
}

$reparseParent = Join-Path $testRoot 'reparse-parent'
[void][IO.Directory]::CreateDirectory($reparseParent)
$escapePath = Join-Path $externalRoot 'escape.txt'
$reparseGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $reparseParent
$reparseAttack = $null
$escapeObserved = $false
try {
    $reparseAttack = [CodexHookGovernanceTests.DirectoryReparseAttacker]::TrySetMountPoint($reparseParent, $externalRoot)
    if ($reparseAttack.OpenSucceeded -and -not $reparseAttack.SetSucceeded) {
        throw "FSCTL_SET_REPARSE_POINT probe 未按预期执行；win32=$($reparseAttack.SetWin32Error)"
    }
    if ($reparseAttack.SetSucceeded) {
        [IO.File]::WriteAllText((Join-Path $reparseParent 'escape.txt'), 'escaped', [Text.UTF8Encoding]::new($false))
        $escapeObserved = [IO.File]::Exists($escapePath)
    }
} finally {
    $reparseGuard.Dispose()
    $reparseItem = Get-Item -LiteralPath $reparseParent -Force -ErrorAction SilentlyContinue
    if ($null -ne $reparseItem -and ($reparseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $reparseParent -Force
    }
}
Assert-True (-not $reparseAttack.OpenSucceeded -and $reparseAttack.OpenWin32Error -eq 32) 'guard 存活时 attacker GENERIC_WRITE open 必须以 Win32 sharing violation 32 失败'
Assert-True (-not $reparseAttack.SetSucceeded -and -not $escapeObserved -and -not [IO.File]::Exists($escapePath)) '真实 FSCTL mount-point attack 不得把全路径写重定向到外部 sibling'

$atomicParent = Join-Path $testRoot 'atomic-parent'
[void][IO.Directory]::CreateDirectory($atomicParent)
$atomicParkedParent = Join-Path $testRoot 'atomic-parent-parked'
$atomicTarget = Join-Path $atomicParent 'target.bin'
[byte[]]$atomicBefore = [Text.UTF8Encoding]::new($false).GetBytes('before')
[byte[]]$atomicAfter = [Text.UTF8Encoding]::new($false).GetBytes('after')
[IO.File]::WriteAllBytes($atomicTarget, $atomicBefore)
$script:atomicRenameAttempt = $null
$script:atomicTempDeleteWin32 = $null
Set-CodexHookAtomicFileBytes `
    -Path $atomicTarget `
    -Bytes $atomicAfter `
    -ExpectedExists $true `
    -ExpectedSha256 (Get-CodexHookBytesSha256 -Bytes $atomicBefore) `
    -AfterSha256 (Get-CodexHookBytesSha256 -Bytes $atomicAfter) `
    -Scope 'directory guard atomic integration' `
    -BeforeMove {
        param($TargetPath)
        $tempCandidates = @(Get-ChildItem -LiteralPath $atomicParent -File -Filter '.codex-hook-*.tmp')
        Assert-True ($tempCandidates.Count -eq 1) 'BeforeMove 期间必须恰有一个 same-handle guarded temp'
        try {
            [IO.File]::Delete($tempCandidates[0].FullName)
            $script:atomicTempDeleteWin32 = 0
        } catch [IO.IOException] {
            $script:atomicTempDeleteWin32 = $_.Exception.HResult -band 0xffff
        }
        $script:atomicRenameAttempt = [CodexHookGovernanceTests.DirectoryRenameAttacker]::TryMove($atomicParent, $atomicParkedParent)
        if ($script:atomicRenameAttempt.Moved) {
            New-Item -ItemType Junction -Path $atomicParent -Target $externalRoot | Out-Null
        }
    }
Assert-True ($null -ne $script:atomicRenameAttempt -and -not $script:atomicRenameAttempt.Moved -and $script:atomicRenameAttempt.Win32Error -eq 32) 'atomic writer 必须在 BeforeMove 攻击期间持有 parent chain guard'
Assert-True ($script:atomicTempDeleteWin32 -eq 32) 'atomic writer 必须让同一 temp handle 跨越 BeforeMove/CAS 并拒绝 leaf 删除'
Assert-True ((Get-CodexHookBytesSha256 -Bytes ([IO.File]::ReadAllBytes($atomicTarget))) -ceq (Get-CodexHookBytesSha256 -Bytes $atomicAfter)) 'guarded atomic writer 必须发布目标 bytes'
Assert-True (@(Get-ChildItem -LiteralPath $externalRoot -Force).Count -eq 0) 'atomic writer 的 rename+junction 攻击不得写入外部 root'

$leaseTarget = Join-Path $atomicParent 'lease-target.bin'
$leaseTempPath = Join-Path $atomicParent '.lease-target.tmp'
[byte[]]$leaseBefore = [Text.UTF8Encoding]::new($false).GetBytes('lease-before')
[byte[]]$leaseAfter = [Text.UTF8Encoding]::new($false).GetBytes('lease-after')
[IO.File]::WriteAllBytes($leaseTarget, $leaseBefore)
$leaseGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
$targetLease = $null
$leaseTemp = $null
try {
    $leaseTemp = $leaseGuard.CreateTempFile($leaseTempPath)
    $leaseTemp.WriteAndFlush($leaseAfter)
    $leaseTempSddl = [string]$leaseTemp.GetSecurityDescriptorSddl()
    $leaseTempAcl = Get-Acl -LiteralPath $leaseTempPath
    Assert-True (-not $leaseTempAcl.AreAccessRulesProtected) 'guarded temp fixture 必须从 inherited/unprotected DACL 开始'
    $leaseTempAcl.SetAccessRuleProtection($true, $true)
    $leaseTempProtectedSddl = [string]$leaseTempAcl.Sddl
    Assert-True ($leaseTempProtectedSddl -match 'D:P') 'guarded temp fixture 必须产生真实 DACL protection 变化'
    $leaseTemp.SetSecurityDescriptorSddl($leaseTempSddl, $leaseTempProtectedSddl)
    $leaseTempProtectedActualSddl = [string]$leaseTemp.GetSecurityDescriptorSddl()
    Assert-True ($leaseTempProtectedActualSddl -match 'D:P') 'guarded temp 必须在同一 handle 上将 inherited DACL 转为 protected DACL'
    $leaseTempSaclError = Assert-Throws -Message 'guarded temp 必须拒绝无法完整处理的 SACL 请求' -Action {
        $leaseTemp.SetSecurityDescriptorSddl($leaseTempProtectedActualSddl, ($leaseTempProtectedActualSddl + 'S:(AU;SA;FA;;;WD)'))
    }
    Assert-True ($leaseTempSaclError -match 'SACL') 'guarded temp 必须对 SACL 请求失败闭锁'
    Assert-True ([string]$leaseTemp.GetSecurityDescriptorSddl() -ceq $leaseTempProtectedActualSddl) '被拒绝的 SACL 请求不得改写 guarded temp ACL'
    $leaseTemp.SetSecurityDescriptorSddl($leaseTempProtectedActualSddl, $leaseTempSddl)
    $leaseTemp.SetSecurityDescriptorSddl($leaseTempSddl, $leaseTempSddl)
    Assert-True ([string]$leaseTemp.GetSecurityDescriptorSddl() -ceq $leaseTempSddl) 'guarded temp 必须在同一 handle 上完成 expected-SDDL CAS 与 postcheck'
    $targetLease = $leaseGuard.AcquireTargetFileLease($leaseTarget)
    Assert-True ((Get-CodexHookBytesSha256 -Bytes ([byte[]]$targetLease.SnapshotBytes)) -ceq (Get-CodexHookBytesSha256 -Bytes $leaseBefore)) 'target lease snapshot 必须来自同一 verified handle'
    $leaseTemp.RenameTo($leaseTarget, $true)
    Assert-True ((Get-CodexHookBytesSha256 -Bytes ([byte[]]$targetLease.ReadAllBytesFromHandle())) -ceq (Get-CodexHookBytesSha256 -Bytes $leaseBefore)) '被替换 target 的旧 lease handle 跨 rename 后仍必须读取旧 bytes'
    $leaseTemp.Dispose()
    $leaseTemp = $null
    Assert-True ((Get-CodexHookBytesSha256 -Bytes ([IO.File]::ReadAllBytes($leaseTarget))) -ceq (Get-CodexHookBytesSha256 -Bytes $leaseAfter)) 'rename 后重新打开 target path 必须读取 approved new bytes'
} finally {
    if ($null -ne $leaseTemp) { $leaseTemp.Dispose() }
    if ($null -ne $targetLease) { $targetLease.Dispose() }
    if ([IO.File]::Exists($leaseTempPath)) { [IO.File]::Delete($leaseTempPath) }
    $leaseGuard.Dispose()
}

$writerConflictTarget = Join-Path $atomicParent 'writer-conflict.bin'
[IO.File]::WriteAllBytes($writerConflictTarget, $leaseBefore)
$writerConflict = [IO.File]::Open(
    $writerConflictTarget,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Write,
    ([IO.FileShare]::Read -bor [IO.FileShare]::Write -bor [IO.FileShare]::Delete))
$writerConflictGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
try {
    $writerConflictError = Assert-Throws -Message '已有内容 writer 时 target lease acquisition 必须失败关闭' -Action {
        $unexpectedLease = $null
        $unexpectedLease = $writerConflictGuard.AcquireTargetFileLease($writerConflictTarget)
        try { } finally { if ($null -ne $unexpectedLease) { $unexpectedLease.Dispose() } }
    }
    Assert-True ($writerConflictError -match 'lease|access|used|另一个进程') '已有 writer 冲突必须返回稳定的 sharing/access 类失败'
} finally {
    $writerConflictGuard.Dispose()
    $writerConflict.Dispose()
}

$deleteTarget = Join-Path $atomicParent 'delete-target.bin'
[byte[]]$deleteBytes = [Text.UTF8Encoding]::new($false).GetBytes('delete-me')
[IO.File]::WriteAllBytes($deleteTarget, $deleteBytes)
Remove-CodexHookFixtureFile -Path $deleteTarget -ExpectedSha256 (Get-CodexHookBytesSha256 -Bytes $deleteBytes) -Scope 'share-read guarded delete'
Assert-True (-not [IO.File]::Exists($deleteTarget)) 'FileShare.Read directory guard 下的普通 child delete 必须保持可用'

$createdNested = Join-Path $testRoot 'created\nested'
[void](New-CodexHookFixtureDirectory -Path $createdNested -Name 'guard-created nested directory' -RequireMissing)
Assert-True ([IO.Directory]::Exists($createdNested)) 'guard 必须逐段创建 trusted root 下的缺失目录'
[void](Assert-Throws -Message 'RequireMissing directory 不得接受预先存在的 target' -Action {
    New-CodexHookFixtureDirectory -Path $createdNested -Name 'already-existing guarded directory' -RequireMissing | Out-Null
})

$emptyDeletePath = Join-Path $testRoot 'identity-bound-empty-delete'
[void][IO.Directory]::CreateDirectory($emptyDeletePath)
$emptyDeleteGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($testRoot, $emptyDeletePath)
try {
    $emptyDeleteParked = "$emptyDeletePath.parked"
    $emptyDeleteMove = [CodexHookGovernanceTests.DirectoryRenameAttacker]::TryMove($emptyDeletePath, $emptyDeleteParked)
    Assert-True (-not $emptyDeleteMove.Moved -and $emptyDeleteMove.Win32Error -eq 32) 'empty-directory delete guard 必须在枚举与删除之间拒绝目录替换'
    $emptyDeleteGuard.DeleteEmptyDirectory()
} finally {
    $emptyDeleteGuard.Dispose()
}

$aclTarget = Join-Path $atomicParent 'acl-target.bin'
$aclParkedTarget = Join-Path $atomicParent 'acl-target-parked.bin'
[IO.File]::WriteAllText($aclTarget, 'acl-target', [Text.UTF8Encoding]::new($false))
$aclGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
$aclLease = $null
try {
    $aclLease = $aclGuard.AcquireAclTargetLease($aclTarget)
    $aclSddl = [string]$aclLease.GetSecurityDescriptorSddl()
    Assert-True (-not [string]::IsNullOrWhiteSpace($aclSddl)) 'ACL lease 必须通过同一 verified handle 读取 Owner/Group/DACL'
    $aclRenameAttempt = [CodexHookGovernanceTests.DirectoryRenameAttacker]::TryMove($aclTarget, $aclParkedTarget)
    Assert-True (-not $aclRenameAttempt.Moved -and $aclRenameAttempt.Win32Error -eq 32) 'ACL lease 存活时目标替换必须以 sharing violation 失败'
    $aclDesired = Get-Acl -LiteralPath $aclTarget
    $aclDesired.SetAccessRuleProtection($true, $true)
    $aclDesiredSddl = [string]$aclDesired.Sddl
    Assert-True ($aclDesiredSddl -cne $aclSddl) 'ACL fixture 必须产生真实 DACL protection 变化'
    # Windows file share flags do not serialize WRITE_DAC. Prove that an ACL-only
    # competitor is visible to the same-handle expected-SDDL gate instead.
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($aclTarget), [Security.AccessControl.FileSecurity]$aclDesired)
    $aclCompetingSddl = [string]$aclLease.GetSecurityDescriptorSddl()
    Assert-True ($aclCompetingSddl -cne $aclSddl) 'ACL-only competitor fixture 必须真实改变同一 target security descriptor'
    $aclCasError = Assert-Throws -Message 'same-handle ACL write 必须拒绝 pre-write SDDL 漂移' -Action {
        $aclLease.SetSecurityDescriptorSddl($aclSddl, $aclDesiredSddl)
    }
    Assert-True ($aclCasError -match 'changed before') 'ACL pre-write CAS 必须返回稳定漂移错误'
    $aclLease.SetSecurityDescriptorSddl($aclCompetingSddl, $aclSddl)
    $aclLease.SetSecurityDescriptorSddl($aclSddl, $aclDesiredSddl)
    $aclActualDesiredSddl = [string]$aclLease.GetSecurityDescriptorSddl()
    Assert-True ($aclActualDesiredSddl -match 'D:P') 'ACL lease 必须在同一目标 handle 上写入并复核 protected DACL；Windows 可规范化 inherited ACE flags'
    $aclLeaseSaclError = Assert-Throws -Message 'ACL lease 必须拒绝无法完整处理的 SACL 请求' -Action {
        $aclLease.SetSecurityDescriptorSddl($aclActualDesiredSddl, ($aclActualDesiredSddl + 'S:(AU;SA;FA;;;WD)'))
    }
    Assert-True ($aclLeaseSaclError -match 'SACL') 'ACL lease 必须对 SACL 请求失败闭锁'
    Assert-True ([string]$aclLease.GetSecurityDescriptorSddl() -ceq $aclActualDesiredSddl) '被拒绝的 SACL 请求不得改写 ACL lease target'
    $aclLease.SetSecurityDescriptorSddl($aclActualDesiredSddl, $aclSddl)
    Assert-True ([string]$aclLease.GetSecurityDescriptorSddl() -ceq $aclSddl) 'ACL lease 必须能在同一目标 handle 上恢复原 Owner/Group/DACL'
} finally {
    if ($null -ne $aclLease) { $aclLease.Dispose() }
    $aclGuard.Dispose()
}
Assert-True ([IO.File]::Exists($aclTarget) -and -not [IO.File]::Exists($aclParkedTarget)) 'ACL lease 释放前目标 identity 必须保持原路径'

$aclHardLink = Join-Path $atomicParent 'acl-hardlink.bin'
New-Item -ItemType HardLink -Path $aclHardLink -Target $aclTarget | Out-Null
$aclHardLinkGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
try {
    $aclHardLinkError = Assert-Throws -Message 'ACL lease 必须拒绝 hardlink target' -Action {
        $unexpectedAclLease = $null
        $unexpectedAclLease = $aclHardLinkGuard.AcquireAclTargetLease($aclHardLink)
        try { } finally { if ($null -ne $unexpectedAclLease) { $unexpectedAclLease.Dispose() } }
    }
    Assert-True ($aclHardLinkError -match 'hard link|link') 'hardlink target 必须返回稳定的 link 拒绝'
} finally {
    $aclHardLinkGuard.Dispose()
    if ([IO.File]::Exists($aclHardLink)) {
        $currentAclHardLink = Get-Item -LiteralPath $aclHardLink -Force
        if ($currentAclHardLink.LinkType -cne 'HardLink') {
            throw "拒绝清理类型不匹配的 ACL hardlink fixture：$aclHardLink"
        }
        [IO.File]::Delete($aclHardLink)
    }
}
Assert-True ([IO.File]::Exists($aclTarget) -and -not [IO.File]::Exists($aclHardLink)) 'ACL hardlink fixture 必须在测试后清理且保留原 target'

$aclDirectory = Join-Path $atomicParent 'acl-directory'
$aclParkedDirectory = Join-Path $atomicParent 'acl-directory-parked'
[void][IO.Directory]::CreateDirectory($aclDirectory)
$aclDirectoryGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
$aclDirectoryLease = $null
try {
    $aclDirectoryLease = $aclDirectoryGuard.AcquireAclTargetLease($aclDirectory)
    Assert-True ([bool]$aclDirectoryLease.IsDirectory) 'ACL directory lease 必须保留 target 类型'
    $aclDirectorySddl = [string]$aclDirectoryLease.GetSecurityDescriptorSddl()
    $aclDirectoryRenameAttempt = [CodexHookGovernanceTests.DirectoryRenameAttacker]::TryMove($aclDirectory, $aclParkedDirectory)
    Assert-True (-not $aclDirectoryRenameAttempt.Moved -and $aclDirectoryRenameAttempt.Win32Error -eq 32) 'ACL directory lease 存活时目录替换必须被拒绝'
    $aclDirectoryLease.SetSecurityDescriptorSddl($aclDirectorySddl)
} finally {
    if ($null -ne $aclDirectoryLease) { $aclDirectoryLease.Dispose() }
    $aclDirectoryGuard.Dispose()
}

$aclJunction = Join-Path $atomicParent 'acl-junction'
$aclJunctionResult = Invoke-HiddenProcess $env:ComSpec @('/d','/c','mklink','/J',$aclJunction,$externalRoot)
if ($aclJunctionResult.exitCode -ne 0) { throw "无法创建 ACL junction fixture：$($aclJunctionResult.stdout)$($aclJunctionResult.stderr)" }
$aclJunctionGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
try {
    $aclJunctionError = Assert-Throws -Message 'ACL lease 必须拒绝 reparse target' -Action {
        $unexpectedAclJunctionLease = $null
        $unexpectedAclJunctionLease = $aclJunctionGuard.AcquireAclTargetLease($aclJunction)
        try { } finally { if ($null -ne $unexpectedAclJunctionLease) { $unexpectedAclJunctionLease.Dispose() } }
    }
    Assert-True ($aclJunctionError -match 'reparse') 'reparse target 必须返回稳定拒绝'
} finally {
    $aclJunctionGuard.Dispose()
    [void](Invoke-HiddenProcess $env:ComSpec @('/d','/c','rmdir',$aclJunction))
}
Assert-True (-not [IO.Directory]::Exists($emptyDeletePath)) '空目录必须通过同一 verified handle 完成 identity-bound delete'

$nonEmptyDeletePath = Join-Path $testRoot 'identity-bound-non-empty-delete'
[void][IO.Directory]::CreateDirectory($nonEmptyDeletePath)
$nonEmptySentinel = Join-Path $nonEmptyDeletePath 'sentinel.txt'
[IO.File]::WriteAllText($nonEmptySentinel, 'must-survive', [Text.UTF8Encoding]::new($false))
$nonEmptyDeleteGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($testRoot, $nonEmptyDeletePath)
try {
    $nonEmptyDeleteError = Assert-Throws -Message 'identity-bound delete 必须拒绝非空目录' -Action {
        $nonEmptyDeleteGuard.DeleteEmptyDirectory()
    }
    Assert-True ($nonEmptyDeleteError -match 'not empty|非空') '非空目录删除必须返回稳定类型错误'
} finally {
    $nonEmptyDeleteGuard.Dispose()
}
Assert-True ([IO.Directory]::Exists($nonEmptyDeletePath) -and [IO.File]::ReadAllText($nonEmptySentinel) -ceq 'must-survive') '非空拒绝不得改写目录或内容'

$danglingTarget = Join-Path $externalRoot 'must-not-be-created'
$danglingLink = Join-Path $testRoot 'dangling-junction'
$staleDanglingLink = Get-Item -LiteralPath $danglingLink -Force -ErrorAction SilentlyContinue
if ($null -ne $staleDanglingLink) {
    if ($staleDanglingLink.LinkType -cne 'Junction' -or [string]$staleDanglingLink.Target -ine $danglingTarget) {
        throw "拒绝清理 identity 不匹配的 dangling junction fixture：$danglingLink"
    }
    $staleCleanup = Invoke-HiddenProcess $env:ComSpec @('/d','/c','rmdir',$danglingLink)
    if ($staleCleanup.exitCode -ne 0) { throw "无法清理遗留 dangling junction fixture：$($staleCleanup.stderr)" }
}
$junctionResult = Invoke-HiddenProcess $env:ComSpec @('/d','/c','mklink','/J',$danglingLink,$danglingTarget)
if ($junctionResult.exitCode -ne 0) { throw "无法创建 dangling junction fixture：$($junctionResult.stdout)$($junctionResult.stderr)" }
try {
    [void](Assert-Throws -Message 'dangling junction 不得被目录创建跟随' -Action {
        New-CodexHookFixtureDirectory -Path (Join-Path $danglingLink 'child') -Name 'dangling junction child' -RequireMissing | Out-Null
    })
    Assert-True (-not [IO.Directory]::Exists($danglingTarget)) 'dangling junction 外部 target 必须保持不存在'
} finally {
    $currentDanglingLink = Get-Item -LiteralPath $danglingLink -Force -ErrorAction SilentlyContinue
    if ($null -ne $currentDanglingLink) {
        if ($currentDanglingLink.LinkType -cne 'Junction' -or [string]$currentDanglingLink.Target -ine $danglingTarget) {
            throw "拒绝清理 identity 不匹配的 dangling junction fixture：$danglingLink"
        }
        $junctionCleanup = Invoke-HiddenProcess $env:ComSpec @('/d','/c','rmdir',$danglingLink)
        if ($junctionCleanup.exitCode -ne 0) { throw "无法清理 dangling junction fixture：$($junctionCleanup.stderr)" }
    }
}
Assert-True ($null -eq (Get-Item -LiteralPath $danglingLink -Force -ErrorAction SilentlyContinue)) 'dangling junction fixture 必须在测试后清理'

$notDirectoryPath = Join-Path $testRoot 'not-a-directory.bin'
[IO.File]::WriteAllBytes($notDirectoryPath, [byte[]](1, 2, 3))
$notDirectoryError = Assert-Throws -Message 'directory chain guard 的 leaf 必须是普通目录' -Action {
    $notDirectoryGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $notDirectoryPath
    try { } finally { if ($null -ne $notDirectoryGuard) { $notDirectoryGuard.Dispose() } }
}
Assert-True ($notDirectoryError -match 'directory|目录') '非目录 leaf 必须返回脱敏类型错误'

$reservedGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
$reservedTempPath = Join-Path $atomicParent '.reserved-target-test.tmp'
$reservedTemp = $null
try {
    $reservedTemp = $reservedGuard.CreateTempFile($reservedTempPath)
    $reservedTemp.WriteAndFlush([Text.UTF8Encoding]::new($false).GetBytes('reserved-target'))
    $reservedTargetError = Assert-Throws -Message 'C# guarded capability 必须在 NT rename 前拒绝 Windows reserved target leaf' -Action {
        $reservedTemp.RenameTo((Join-Path $atomicParent 'CON.txt'), $false)
    }
    Assert-True ($reservedTargetError -match 'reserved|invalid file name') 'reserved target leaf 必须由 deterministic leaf validator 拒绝'
} finally {
    if ($null -ne $reservedTemp) { $reservedTemp.Dispose() }
    if ([IO.File]::Exists($reservedTempPath)) { [IO.File]::Delete($reservedTempPath) }
    $reservedGuard.Dispose()
}

$invalidLeafGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $atomicParent
try {
    $invalidLeafError = Assert-Throws -Message 'C# guarded capability 必须拒绝 wildcard/invalid filename chars' -Action {
        $invalidLeafTemp = $null
        $invalidLeafTemp = $invalidLeafGuard.CreateTempFile((Join-Path $atomicParent 'wild*.tmp'))
        try { } finally { if ($null -ne $invalidLeafTemp) { $invalidLeafTemp.Dispose() } }
    }
    Assert-True ($invalidLeafError -match 'invalid file name') 'wildcard leaf 必须由 deterministic invalid-char validator 拒绝'
} finally {
    $invalidLeafGuard.Dispose()
}

$rawMutationPattern = [regex]'\[IO\.(?:Directory|File)\]::(?:CreateDirectory|Move|Delete|WriteAllBytes|WriteAllText|Replace)\s*\(|\[IO\.FileStream\]::new\s*\('
$engineScriptPaths = @(
    (Join-Path $ProjectRoot 'scripts\New-CodexHookDeploymentPlan.ps1'),
    (Join-Path $ProjectRoot 'scripts\Invoke-CodexHookDeployment.ps1'),
    (Join-Path $ProjectRoot 'scripts\Restore-CodexHookDeployment.ps1')
)
foreach ($engineScriptPath in $engineScriptPaths) {
    $engineScriptText = [IO.File]::ReadAllText($engineScriptPath)
    Assert-True ($rawMutationPattern.Matches($engineScriptText).Count -eq 0) "deployment entry 不得绕过统一 guarded writer：$([IO.Path]::GetFileName($engineScriptPath))"
}

$policyPath = Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1'
$policyText = [IO.File]::ReadAllText($policyPath)
$handleBoundSource = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'scripts\lib\CodexHookHandleBoundIO.cs'))
Assert-True ($policyText -notmatch '\[IO\.File\]::Move\s*\(') 'guarded atomic writer 不得回退到 path-based File.Move'
Assert-True ($policyText -notmatch '\[IO\.FileStream\]::new\s*\(') 'guarded atomic writer 必须由 C# same-handle temp 对象持有 CreateNew handle'
Assert-True ($handleBoundSource -match 'FileRenameInformationEx\s*=\s*65') 'guarded rename 必须固定使用 FileRenameInformationEx=65'
Assert-True ($handleBoundSource -match 'FileRenameReplaceIfExists\s*\|\s*FileRenamePosixSemantics') 'existing-target rename 必须组合 REPLACE 与 POSIX flags'
Assert-True ($handleBoundSource -notmatch 'FileRenameInformation\s*=\s*10') 'guarded rename 不得回退到 class 10'
$atomicWriterStart = $policyText.IndexOf('function Set-CodexHookAtomicFileBytes', [StringComparison]::Ordinal)
$guardedDeleteStart = $policyText.IndexOf('function Remove-CodexHookFixtureFile', [StringComparison]::Ordinal)
$evidenceWriterStart = $policyText.IndexOf('function Set-CodexHookEvidenceJson', [StringComparison]::Ordinal)
Assert-True ($atomicWriterStart -ge 0 -and $guardedDeleteStart -gt $atomicWriterStart -and $evidenceWriterStart -gt $guardedDeleteStart) 'guarded writer function boundaries 必须可识别'
foreach ($rawMutation in $rawMutationPattern.Matches($policyText)) {
    $insideAtomicWriter = $rawMutation.Index -ge $atomicWriterStart -and $rawMutation.Index -lt $guardedDeleteStart
    $insideGuardedDelete = $rawMutation.Index -ge $guardedDeleteStart -and $rawMutation.Index -lt $evidenceWriterStart
    Assert-True ($insideAtomicWriter -or $insideGuardedDelete) 'Policy raw filesystem mutation 只能存在于统一 guarded atomic/delete helper 内'
}

[pscustomobject]@{
    ok = $true
    suite = 'CodexHookDirectoryGuard'
}
