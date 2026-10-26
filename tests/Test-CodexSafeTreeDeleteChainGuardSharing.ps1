[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test：scripts\lib\CodexHookHandleBoundIO.cs 的 VerifiedDirectoryChainGuard 与 fixture 入口
# tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 Plan。链上非目标目录（含卷根与 trusted root 之上各级）以
# FileShare.Read | FileShare.Write 打开、仍不共享 Delete（2026-10-21 #88 brief 方案 1）：
# - 另一句柄以写权限（共享读写删）持有目标的上级目录时，Acquire 与 AcquireForEmptyDelete 都成功，
#   该上级目录下一棵树的 Plan 预检通过（trusted root 之上、之下各覆盖一级）。
# - guard 持有期间，上级目录里无关条目的改名成功；链上任一目录（上级或目标）的改名或删除失败。
# - 目标层持续冲突（不共享 Delete 的 CWD 式句柄）时 Plan 预检仍以 Win32 32 失败。
# - 链打开失败的异常信息写明失败层级（trusted root 之上第几级 / 之下的相对路径）与 Win32 错误码，
#   异常类型与 NativeErrorCode 不变。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'chain-guard-sharing'

$evidenceRoot = Join-Path $scratchRoot 'evidence'
$policyPath = Join-Path $scratchRoot 'policy.json'
$workspaceRoot = Join-Path $scratchRoot 'workspace'
$candidatePath = Join-Path $workspaceRoot 'cand'
$subtreePath = Join-Path $candidatePath 'subtree'
$innerPath = Join-Path $subtreePath 'inner'
$unrelatedPath = Join-Path $candidatePath 'unrelated'
$conflictPath = Join-Path $workspaceRoot 'conflict'
$siblingFile = Join-Path $scratchRoot 'sibling-note.txt'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete chain guard sharing test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete chain guard sharing test cleanup'
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexHookGovernanceTests
{
    public sealed class ChainGuardSharingMoveResult
    {
        public ChainGuardSharingMoveResult(bool moved, int win32Error)
        {
            Moved = moved;
            Win32Error = win32Error;
        }

        public bool Moved { get; }
        public int Win32Error { get; }
    }

    public static class ChainGuardSharingProbe
    {
        public const uint GenericRead = 0x80000000;
        public const uint GenericWrite = 0x40000000;

        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileExW(string existingPath, string newPath, uint flags);

        public static SafeFileHandle HoldDirectory(string path, uint desiredAccess, FileShare shareMode)
        {
            SafeFileHandle handle = CreateFileW(
                Path.GetFullPath(path),
                desiredAccess,
                shareMode,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            return handle;
        }

        public static ChainGuardSharingMoveResult TryMove(string source, string destination)
        {
            bool moved = MoveFileExW(source, destination, 0);
            return new ChainGuardSharingMoveResult(moved, moved ? 0 : Marshal.GetLastWin32Error());
        }
    }
}
'@

$probeType = [CodexHookGovernanceTests.ChainGuardSharingProbe]
$readWriteAccess = [uint32]($probeType::GenericRead -bor $probeType::GenericWrite)
$shareReadWriteDelete = [IO.FileShare]::Read -bor [IO.FileShare]::Write -bor [IO.FileShare]::Delete

function Invoke-ChainGuardAcquire {
    param(
        [Parameter(Mandatory)][string]$TrustedRoot,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('Acquire', 'EmptyDelete')][string]$Mode
    )

    try {
        $guard = $null
        if ($Mode -ceq 'Acquire') {
            $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($TrustedRoot, $Target, $false)
        } else {
            $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($TrustedRoot, $Target)
        }
        $guard.Dispose()
        return [pscustomobject]@{ opened = $true; message = $null; win32Exception = $null; win32Message = $null }
    } catch {
        $win32 = $_.Exception
        while ($null -ne $win32 -and $win32 -isnot [ComponentModel.Win32Exception]) {
            $win32 = $win32.InnerException
        }
        $win32Message = if ($null -ne $win32) { [string]$win32.Message } else { $null }
        return [pscustomobject]@{ opened = $false; message = [string]$_.Exception.Message; win32Exception = $win32; win32Message = $win32Message }
    }
}

function Invoke-PlanOutcome {
    param([Parameter(Mandatory)][string]$TargetPath)

    try {
        $plan = & $entryPath `
            -Mode Plan `
            -TargetPath $TargetPath `
            -CapabilityRoot $workspaceRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
        return [pscustomobject]@{ planned = [bool]$plan.planned; message = $null; win32Exception = $null }
    } catch {
        $win32 = $_.Exception
        while ($null -ne $win32 -and $win32 -isnot [ComponentModel.Win32Exception]) {
            $win32 = $win32.InnerException
        }
        return [pscustomobject]@{ planned = $false; message = [string]$_.Exception.Message; win32Exception = $win32 }
    }
}

$cleanupError = $null
try {
    [void][IO.Directory]::CreateDirectory($innerPath)
    [void][IO.Directory]::CreateDirectory($conflictPath)
    Write-Utf8File -Path $siblingFile -Text 'chain-guard-sharing-sibling'
    Write-Utf8File -Path $policyPath -Text (([pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-policy'
                schemaVersion = 4
                entries = @([pscustomobject][ordered]@{
                        id = 'chain-guard-sharing-workspace'
                        capabilityRoot = $workspaceRoot
                        minimumDescendantDepth = 1
                        rootDeletionPurpose = 'none'
                        deniedExactPaths = @()
                    })
            }) | ConvertTo-Json -Depth 10)

    # 1a. trusted root 之上的上级目录被另一句柄以写权限（共享读写删）持有：Acquire 与 AcquireForEmptyDelete
    # 都成功，该上级目录下一棵树的 Plan 预检通过。
    $aboveHolder = $probeType::HoldDirectory($scratchRoot, $readWriteAccess, $shareReadWriteDelete)
    try {
        foreach ($mode in @('Acquire', 'EmptyDelete')) {
            $outcome = Invoke-ChainGuardAcquire -TrustedRoot $workspaceRoot -Target $innerPath -Mode $mode
            Assert-True $outcome.opened "trusted root 之上一级被写持有时 $mode 必须成功，实际：$($outcome.message)"
        }
        $abovePlan = Invoke-PlanOutcome -TargetPath $candidatePath
        Assert-True $abovePlan.planned "trusted root 之上一级被写持有时该树的 Plan 必须成功，实际：$($abovePlan.message)"
    } finally {
        $aboveHolder.Dispose()
    }

    # 1b. trusted root 之下的上级目录被同样持有：同一组断言。Plan 目标在被持有上级目录之下——被持有的
    # 目录若作为 Plan 目标本身，属于目标层持续冲突（阶段 3 覆盖），不在本阶段。
    $belowHolder = $probeType::HoldDirectory($candidatePath, $readWriteAccess, $shareReadWriteDelete)
    try {
        foreach ($mode in @('Acquire', 'EmptyDelete')) {
            $outcome = Invoke-ChainGuardAcquire -TrustedRoot $workspaceRoot -Target $innerPath -Mode $mode
            Assert-True $outcome.opened "trusted root 之下一级被写持有时 $mode 必须成功，实际：$($outcome.message)"
        }
        $belowPlan = Invoke-PlanOutcome -TargetPath $subtreePath
        Assert-True $belowPlan.planned "trusted root 之下一级被写持有时该树的 Plan 必须成功，实际：$($belowPlan.message)"
    } finally {
        $belowHolder.Dispose()
    }

    # 2. guard 持有期间：上级目录里无关条目改名成功；链上任一目录（上级或目标）改名或删除失败。
    [void][IO.Directory]::CreateDirectory($unrelatedPath)
    $heldGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($workspaceRoot, $innerPath)
    try {
        $unrelatedMoved = $probeType::TryMove($unrelatedPath, "$unrelatedPath-renamed")
        Assert-True ($unrelatedMoved.Moved) "guard 持有期间 trusted root 之下上级目录里无关条目改名必须成功，实际 Win32 错误 $($unrelatedMoved.Win32Error)"
        $siblingMoved = $probeType::TryMove($siblingFile, (Join-Path $scratchRoot 'sibling-note-2.txt'))
        Assert-True ($siblingMoved.Moved) "guard 持有期间 trusted root 之上上级目录里无关条目改名必须成功，实际 Win32 错误 $($siblingMoved.Win32Error)"

        foreach ($chainDirectory in @($candidatePath, $subtreePath, $innerPath, $workspaceRoot, $scratchRoot)) {
            $chainMoved = $probeType::TryMove($chainDirectory, "$chainDirectory-parked")
            Assert-True (-not $chainMoved.Moved -and $chainMoved.Win32Error -eq 32) (
                "guard 持有期间链上目录改名必须以 Win32 32 失败：$chainDirectory，实际 moved=$($chainMoved.Moved) error=$($chainMoved.Win32Error)")
        }

        foreach ($ancestorDirectory in @($candidatePath, $subtreePath, $workspaceRoot, $scratchRoot)) {
            $ancestorDeleteError = $null
            try {
                [IO.Directory]::Delete($ancestorDirectory)
            } catch [IO.IOException] {
                $ancestorDeleteError = $_.Exception.HResult -band 0xffff
            }
            Assert-True ($ancestorDeleteError -eq 32) (
                "guard 持有期间删除上级目录必须以 Win32 32 失败：$ancestorDirectory，实际：$ancestorDeleteError")
        }

        $deleteError = $null
        try {
            [IO.Directory]::Delete($innerPath)
        } catch [IO.IOException] {
            $deleteError = $_.Exception.HResult -band 0xffff
        }
        Assert-True ($deleteError -eq 32) "guard 持有期间删除目标目录必须以 Win32 32 失败，实际：$deleteError"
    } finally {
        $heldGuard.Dispose()
    }

    # 3. 目标层持续冲突（不共享 Delete 的 CWD 式句柄）：Plan 预检仍以 Win32 32 失败。
    $conflictHolder = $probeType::HoldDirectory(
        $conflictPath,
        $probeType::GenericRead,
        ([IO.FileShare]::Read -bor [IO.FileShare]::Write))
    try {
        $conflictPlan = Invoke-PlanOutcome -TargetPath $conflictPath
        Assert-True (-not $conflictPlan.planned) '目标被不共享 Delete 的句柄持有时 Plan 必须失败'
        Assert-True ($null -ne $conflictPlan.win32Exception -and $conflictPlan.win32Exception.NativeErrorCode -eq 32) (
            "目标层持续冲突必须以 Win32 32 失败，实际：$($conflictPlan.message)")
    } finally {
        $conflictHolder.Dispose()
    }

    # 4. 链打开失败的异常信息写明失败层级与 Win32 错误码；异常类型与 NativeErrorCode 不变。
    $aboveBlocker = $probeType::HoldDirectory($scratchRoot, $probeType::GenericRead, [IO.FileShare]::None)
    try {
        $aboveFailure = Invoke-ChainGuardAcquire -TrustedRoot $workspaceRoot -Target $innerPath -Mode 'Acquire'
        Assert-True (-not $aboveFailure.opened) 'trusted root 之上一级被独占持有时链打开必须失败'
        Assert-True ($null -ne $aboveFailure.win32Exception -and $aboveFailure.win32Exception.NativeErrorCode -eq 32) (
            "链打开失败必须保留 Win32Exception 与 NativeErrorCode 32，实际：$($aboveFailure.message)")
        Assert-True ($aboveFailure.win32Message.StartsWith('Unable to open a verified directory in the path chain', [StringComparison]::Ordinal)) (
            "链打开失败必须保留原消息前缀，实际：$($aboveFailure.win32Message)")
        Assert-True ($aboveFailure.win32Message.Contains('1 level above the trusted root')) (
            "trusted root 之上第几级必须写进失败消息，实际：$($aboveFailure.win32Message)")
        Assert-True ($aboveFailure.win32Message.Contains('Win32 error 32')) (
            "Win32 错误码必须写进失败消息，实际：$($aboveFailure.win32Message)")
    } finally {
        $aboveBlocker.Dispose()
    }

    $belowBlocker = $probeType::HoldDirectory($candidatePath, $probeType::GenericRead, [IO.FileShare]::None)
    try {
        $belowFailure = Invoke-ChainGuardAcquire -TrustedRoot $workspaceRoot -Target $innerPath -Mode 'Acquire'
        Assert-True (-not $belowFailure.opened) 'trusted root 之下一级被独占持有时链打开必须失败'
        Assert-True ($belowFailure.win32Message.Contains("relative path 'cand' below the trusted root")) (
            "trusted root 之下的相对路径必须写进失败消息，实际：$($belowFailure.win32Message)")
        Assert-True ($belowFailure.win32Message.Contains('Win32 error 32')) (
            "Win32 错误码必须写进失败消息，实际：$($belowFailure.win32Message)")
    } finally {
        $belowBlocker.Dispose()
    }

    $rootBlocker = $probeType::HoldDirectory($workspaceRoot, $probeType::GenericRead, [IO.FileShare]::None)
    try {
        $rootFailure = Invoke-ChainGuardAcquire -TrustedRoot $workspaceRoot -Target $innerPath -Mode 'Acquire'
        Assert-True (-not $rootFailure.opened) 'trusted root 被独占持有时链打开必须失败'
        Assert-True ($rootFailure.win32Message.Contains("relative path '.' below the trusted root")) (
            "trusted root 本身必须以相对路径 . 写进失败消息，实际：$($rootFailure.win32Message)")
    } finally {
        $rootBlocker.Dispose()
    }
} finally {
    try {
        Remove-TestTree -Path $scratchRoot
    } catch {
        $cleanupError = $_
    }
}
if ($null -ne $cleanupError) { throw $cleanupError }

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteChainGuardSharing'
    heldAncestorPlans = 2
    chainDirectoriesPinned = 5
    chainAncestorDeletesPinned = 4
}
