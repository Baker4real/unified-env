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

$danglingTarget = Join-Path $externalRoot 'must-not-be-created'
$danglingLink = Join-Path $testRoot 'dangling-junction'
$junctionOutput = & $env:ComSpec /d /c "mklink /J `"$danglingLink`" `"$danglingTarget`"" 2>&1
if ($LASTEXITCODE -ne 0) { throw "无法创建 dangling junction fixture：$junctionOutput" }
[void](Assert-Throws -Message 'dangling junction 不得被目录创建跟随' -Action {
    New-CodexHookFixtureDirectory -Path (Join-Path $danglingLink 'child') -Name 'dangling junction child' -RequireMissing | Out-Null
})
Assert-True (-not [IO.Directory]::Exists($danglingTarget)) 'dangling junction 外部 target 必须保持不存在'

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
Assert-True ($policyText -notmatch '\[IO\.File\]::Move\s*\(') 'guarded atomic writer 不得回退到 path-based File.Move'
Assert-True ($policyText -notmatch '\[IO\.FileStream\]::new\s*\(') 'guarded atomic writer 必须由 C# same-handle temp 对象持有 CreateNew handle'
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
