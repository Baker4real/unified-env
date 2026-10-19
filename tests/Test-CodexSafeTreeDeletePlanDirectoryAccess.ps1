[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test: fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 Plan。Purge 删除每个目录前要冻结它的
# DACL，目录链 guard 因此对每个计划目录请求 READ_CONTROL、WRITE_DAC 与 DELETE；当前进程缺这些权限时，Plan 必须在
# 写任何 evidence 之前拒绝并点名目录（2026-10-13 实例：owner 为 BUILTIN\Administrators 的子目录让未提权的 Purge
# 删到一半，transaction 停在 purging，Restore 已不可用）。
# 夹具先把目录 owner 设成当前用户，再加 OWNER RIGHTS（S-1-3-4）与当前用户的 WRITE_DAC deny：OWNER RIGHTS 的 ACE 让
# owner 失去隐含的 WRITE_DAC，deny 又排在全部 allow 之前，所以提权与非提权进程都会在同一次打开上拿到
# ERROR_ACCESS_DENIED。删除空目录只要 DELETE，清理不用先改回 ACL。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'plan-directory-access'

$evidenceRoot = Join-Path $scratchRoot 'evidence'
$policyPath = Join-Path $scratchRoot 'policy.json'
$workspaceRoot = Join-Path $scratchRoot 'workspace'
$candidatePath = Join-Path $workspaceRoot 'candidate'
$openPath = Join-Path $candidatePath 'open'
$lockedPath = Join-Path $candidatePath 'locked'
$nestedLockedPath = Join-Path $openPath 'nested-locked'
$rootLockedPath = Join-Path $workspaceRoot 'root-locked'
$rootLockedFile = Join-Path $rootLockedPath 'payload.txt'

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
        -Name 'safe-delete plan directory access test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete plan directory access test cleanup'
}

function Get-EvidenceSnapshot {
    # evidence 目录树的完整快照：相对路径、类型、目录与文件的 LastWriteTimeUtc、文件长度与 SHA-256。
    if (-not [IO.Directory]::Exists($evidenceRoot)) { return '<absent>' }
    $root = [IO.DirectoryInfo]::new($evidenceRoot)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(('.|dir|{0}' -f $root.LastWriteTimeUtc.Ticks))
    foreach ($item in $root.EnumerateFileSystemInfos('*', [IO.SearchOption]::AllDirectories)) {
        $relative = [IO.Path]::GetRelativePath($evidenceRoot, $item.FullName)
        if ($item -is [IO.FileInfo]) {
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($item.FullName)))
            $lines.Add(('{0}|file|{1}|{2}|{3}' -f $relative, $item.Length, $item.LastWriteTimeUtc.Ticks, $hash))
        } else {
            $lines.Add(('{0}|dir|{1}' -f $relative, $item.LastWriteTimeUtc.Ticks))
        }
    }
    return (@($lines | Sort-Object -CaseSensitive) -join "`n")
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
        return [pscustomobject]@{ planned = [bool]$plan.planned; message = $null }
    } catch {
        return [pscustomobject]@{ planned = $false; message = [string]$_.Exception.Message }
    }
}

function Lock-DirectoryWriteDac {
    param([Parameter(Mandatory)][string]$Path)

    $directory = [IO.DirectoryInfo]::new($Path)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $ownerSecurity = [IO.FileSystemAclExtensions]::GetAccessControl(
        $directory,
        [Security.AccessControl.AccessControlSections]::Owner)
    if ($ownerSecurity.GetOwner([Security.Principal.SecurityIdentifier]) -ne $user) {
        $ownerSecurity.SetOwner($user)
        [IO.FileSystemAclExtensions]::SetAccessControl($directory, $ownerSecurity)
    }
    $security = [IO.FileSystemAclExtensions]::GetAccessControl(
        $directory,
        [Security.AccessControl.AccessControlSections]::Access)
    foreach ($sid in @([Security.Principal.SecurityIdentifier]::new('S-1-3-4'), $user)) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::ChangePermissions,
                [Security.AccessControl.InheritanceFlags]::None,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Deny))
    }
    [IO.FileSystemAclExtensions]::SetAccessControl($directory, $security)
}

function Get-DirectoryDeleteOpenError {
    # 与 Plan 预检、Purge 同一次打开；返回 Win32 错误码，打开成功返回 0。
    param([Parameter(Mandatory)][string]$Path)

    try {
        [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($workspaceRoot, $Path).Dispose()
        return 0
    } catch {
        $exception = $_.Exception
        while ($null -ne $exception -and $exception -isnot [ComponentModel.Win32Exception]) {
            $exception = $exception.InnerException
        }
        if ($null -eq $exception) { throw }
        return [int]$exception.NativeErrorCode
    }
}

$refusalPrefix = 'safe-delete 当前进程对 '
$cleanupError = $null
try {
    Write-Utf8File -Path (Join-Path $candidatePath 'payload.txt') -Text 'plan-directory-access-candidate'
    Write-Utf8File -Path (Join-Path $openPath 'payload.txt') -Text 'plan-directory-access-open'
    [void][IO.Directory]::CreateDirectory($lockedPath)
    [void][IO.Directory]::CreateDirectory($nestedLockedPath)
    Write-Utf8File -Path $rootLockedFile -Text 'plan-directory-access-root'
    Write-Utf8File -Path $policyPath -Text (([pscustomobject][ordered]@{
                artifactType = 'env-governance.codex-safe-tree-delete-policy'
                schemaVersion = 4
                entries = @([pscustomobject][ordered]@{
                        id = 'plan-directory-access-workspace'
                        capabilityRoot = $workspaceRoot
                        minimumDescendantDepth = 1
                        rootDeletionPurpose = 'none'
                        deniedExactPaths = @()
                    })
            }) | ConvertTo-Json -Depth 10)

    # 1. 对照：加 deny 之前，同一棵树的两个目标都能 Plan。
    foreach ($target in @($candidatePath, $rootLockedPath)) {
        $control = Invoke-PlanOutcome -TargetPath $target
        Assert-True $control.planned "对照：未加 deny 时 Plan 必须成功（$target），实际：$($control.message)"
    }

    # 2. 夹具自检：加 deny 之后，与 Purge 同一次打开对三个目录都得到 ERROR_ACCESS_DENIED，未加 deny 的 open 仍能打开。
    foreach ($path in @($lockedPath, $nestedLockedPath, $rootLockedPath)) {
        Lock-DirectoryWriteDac -Path $path
        $openError = Get-DirectoryDeleteOpenError -Path $path
        Assert-True ($openError -eq 5) "夹具：加 deny 后打开 $path 必须得到 ERROR_ACCESS_DENIED（5），实际 $openError"
    }
    $unlockedError = Get-DirectoryDeleteOpenError -Path $openPath
    Assert-True ($unlockedError -eq 0) "夹具：未加 deny 的目录必须能打开，实际 Win32 错误 $unlockedError"

    # 3. 两个子目录打不开：Plan 拒绝，按相对路径点名这两个目录且只点名它们，不写任何 evidence。
    $before = Get-EvidenceSnapshot
    $refused = Invoke-PlanOutcome -TargetPath $candidatePath
    Assert-True (-not $refused.planned) '子目录打不开时 Plan 必须拒绝'
    Assert-True ($refused.message.StartsWith($refusalPrefix + '2 个计划目录', [StringComparison]::Ordinal)) (
        "子目录打不开：拒绝原文必须报 2 个目录，实际：$($refused.message)")
    $listedPart = $refused.message.Substring($refused.message.IndexOf('Plan 在改动前拒绝：', [StringComparison]::Ordinal))
    $listed = @($listedPart.Substring('Plan 在改动前拒绝：'.Length).Split('（')[0].Split('、') | Sort-Object -CaseSensitive)
    Assert-True (($listed -join '|') -ceq 'locked|open/nested-locked') (
        "子目录打不开：必须恰好点名 locked 与 open/nested-locked，实际：$($refused.message)")
    Assert-True ((Get-EvidenceSnapshot) -ceq $before) '子目录打不开：Plan 拒绝前不得写 evidence'

    # 4. 目标根本身打不开：以 . 点名目标根。
    $before = Get-EvidenceSnapshot
    $rootRefused = Invoke-PlanOutcome -TargetPath $rootLockedPath
    Assert-True ((-not $rootRefused.planned) -and
        $rootRefused.message.StartsWith($refusalPrefix + '1 个计划目录', [StringComparison]::Ordinal) -and
        $rootRefused.message.Contains('Plan 在改动前拒绝：.（')) (
        "目标根打不开：Plan 必须以 . 点名目标根拒绝，实际：$($rootRefused.message)")
    Assert-True ((Get-EvidenceSnapshot) -ceq $before) '目标根打不开：Plan 拒绝前不得写 evidence'
} finally {
    try {
        # 加了 deny 的目录先单独删掉（只要 DELETE），清理快照之后的删除路径不必再打开它们的 WRITE_DAC。
        foreach ($path in @($nestedLockedPath, $lockedPath)) {
            if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path) }
        }
        if ([IO.File]::Exists($rootLockedFile)) { [IO.File]::Delete($rootLockedFile) }
        if ([IO.Directory]::Exists($rootLockedPath)) { [IO.Directory]::Delete($rootLockedPath) }
        Remove-TestTree -Path $scratchRoot
    } catch {
        $cleanupError = $_
    }
}
if ($null -ne $cleanupError) { throw $cleanupError }

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeletePlanDirectoryAccess'
    lockedDirectories = 3
}
