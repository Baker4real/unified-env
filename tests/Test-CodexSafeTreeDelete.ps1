[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$productionEntryPath = Join-Path $projectRoot 'scripts\Invoke-CodexSafeTreeDelete.ps1'
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$productionPolicyPath = Join-Path $projectRoot 'managed\safe-tree-delete\policy.json'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$targetPath = Join-Path $fixtureRoot 'candidate'
$rootTargetParent = Join-Path $fixtureRoot 'root-target-parent'
$rootTargetPath = Join-Path $rootTargetParent 'build-output'
$rollbackRootParent = Join-Path $fixtureRoot 'rollback-root-parent'
$rollbackRootTarget = Join-Path $rollbackRootParent 'build-output'
$rollbackSiblingPath = Join-Path $rollbackRootParent 'must-survive.txt'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$invalidProjectRootPolicyPath = Join-Path $fixtureRoot 'invalid-project-root-policy.json'
$invalidStateRootPolicyPath = Join-Path $fixtureRoot 'invalid-state-root-policy.json'
$largeSparseTargetPath = Join-Path $fixtureRoot 'large-sparse-candidate'
$largeSparseFilePath = Join-Path $largeSparseTargetPath 'large-zero.bin'
$largeSparseQuarantinePath = $null

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action | Out-Null } catch { return $_.Exception.Message }
    throw $Message
}

function Get-ExceptionChainText {
    param([Parameter(Mandatory)][Exception]$Exception)

    $parts = [Collections.Generic.List[string]]::new()
    $current = $Exception
    while ($null -ne $current) {
        $nativeErrorCode = if ($current.PSObject.Properties.Name -contains 'NativeErrorCode') {
            "; NativeErrorCode=$($current.NativeErrorCode)"
        } else { '' }
        $parts.Add("$($current.GetType().FullName): $($current.Message)$nativeErrorCode")
        $current = $current.InnerException
    }
    return $parts -join ' -> '
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class CodexSafeDeleteSparseFixture
{
    private const uint FsctlSetSparse = 0x000900C4;
    private const uint DeleteAccess = 0x00010000;
    private const uint OpenExisting = 3;
    private const uint FileAttributeNormal = 0x00000080;
    private const uint FileFlagOpenReparsePoint = 0x00200000;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device,
        uint controlCode,
        IntPtr inputBuffer,
        uint inputBufferSize,
        IntPtr outputBuffer,
        uint outputBufferSize,
        out uint bytesReturned,
        IntPtr overlapped);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        FileShare shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    public static void CreateZeroFile(string path, long length)
    {
        using (FileStream stream = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
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
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to mark the large-file fixture sparse.");
            }
            stream.SetLength(length);
            stream.Flush(true);
        }
    }

    public static long WaitForDeleteShare(string path, int timeoutMilliseconds)
    {
        Stopwatch stopwatch = Stopwatch.StartNew();
        while (stopwatch.ElapsedMilliseconds < timeoutMilliseconds)
        {
            using (SafeFileHandle handle = CreateFileW(
                path,
                DeleteAccess,
                FileShare.Read | FileShare.Write | FileShare.Delete,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero))
            {
                if (!handle.IsInvalid)
                {
                    return stopwatch.ElapsedMilliseconds;
                }
                int error = Marshal.GetLastWin32Error();
                if (error != 5 && error != 32)
                {
                    throw new Win32Exception(error, "Unable to probe DELETE sharing for the sparse fixture.");
                }
            }
            Thread.Sleep(50);
        }
        throw new TimeoutException("The sparse fixture did not release DELETE sharing within the test timeout.");
    }
}
'@

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete test cleanup'
}

function New-InterruptedPurgeFixture {
    param([Parameter(Mandatory)][string]$Path)

    [void][IO.Directory]::CreateDirectory($Path)
    [IO.File]::WriteAllText(
        (Join-Path $Path 'already-purged.txt'),
        'already-purged',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $Path 'still-present.txt'),
        'still-present',
        [Text.UTF8Encoding]::new($false))
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $Path `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $transaction = Get-Content -Raw -LiteralPath ([string]$apply.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String
    $transaction.status = 'purging'
    $transaction.updatedAtUtc = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $runDirectory = Split-Path -Parent ([string]$apply.transactionPath)
    Set-CodexHookCapabilityJson `
        -Path ([string]$apply.transactionPath) `
        -Document $transaction `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @([string]$apply.transactionPath) `
        -Scope 'safe-delete partial purge fixture'
    [IO.File]::Delete((Join-Path ([string]$apply.quarantinePath) 'already-purged.txt'))
    $transactionSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$apply.transactionPath) `
        -CapabilityRoot $runDirectory `
        -AllowedExactPaths @([string]$apply.transactionPath) `
        -Name 'safe-delete partial purge fixture transaction'
    return [pscustomobject][ordered]@{
        targetPath = $Path
        quarantinePath = [string]$apply.quarantinePath
        transactionPath = [string]$apply.transactionPath
        transactionSha256 = [string]$transactionSnapshot.sha256
        remainingPath = Join-Path ([string]$apply.quarantinePath) 'still-present.txt'
    }
}

. $hostSafetyLibraryPath

$gitIgnoreLines = @([IO.File]::ReadAllLines((Join-Path $projectRoot '.gitignore')))
Assert-True (
    $gitIgnoreLines -ccontains 'reports/safe-tree-delete-test-*/'
) 'safe-delete fixture 必须被 Git 精确忽略，避免仓库 watcher 扫描大文件'

[void][IO.Directory]::CreateDirectory($targetPath)
$payloadPath = Join-Path $targetPath 'payload.txt'
[IO.File]::WriteAllText($payloadPath, 'keep-until-apply', [Text.UTF8Encoding]::new($false))
[IO.File]::SetAttributes($payloadPath, [IO.FileAttributes]::ReadOnly)
[void][IO.Directory]::CreateDirectory($rootTargetPath)
[IO.File]::WriteAllText((Join-Path $rootTargetPath 'root-payload.txt'), 'root-target', [Text.UTF8Encoding]::new($false))
[void][IO.Directory]::CreateDirectory($rollbackRootTarget)
[IO.File]::WriteAllText((Join-Path $rollbackRootTarget 'rollback-payload.txt'), 'rollback-target', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($rollbackSiblingPath, 'must-survive', [Text.UTF8Encoding]::new($false))
$policy = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 2
    entries = @(
        [pscustomobject][ordered]@{
            id = 'fixture'
            capabilityRoot = $fixtureRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            deniedExactPaths = @($evidenceRoot)
        },
        [pscustomobject][ordered]@{
            id = 'fixture-root-target'
            capabilityRoot = $rootTargetPath
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        },
        [pscustomobject][ordered]@{
            id = 'fixture-root-rollback'
            capabilityRoot = $rollbackRootTarget
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        }
    )
}
[IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

try {
    Assert-True ([IO.File]::Exists($productionEntryPath)) '生产安全删除 CLI 必须存在'
    Assert-True ([IO.File]::Exists($entryPath)) '安全删除 fixture CLI 必须存在'
    $productionCommand = Get-Command -Name $productionEntryPath
    foreach ($forbiddenParameter in @('Fixture', 'FixturePolicyPath', 'FixtureEvidenceRoot', 'PolicyPath', 'EvidenceRoot')) {
        Assert-True (-not $productionCommand.Parameters.ContainsKey($forbiddenParameter)) "生产 CLI 不得暴露 $forbiddenParameter"
    }
    $productionPolicy = Get-Content -LiteralPath $productionPolicyPath -Raw | ConvertFrom-Json -Depth 32
    $legacyTempEntries = @($productionPolicy.entries | Where-Object { $_.id -ceq 'codex-legacy-temp' })
    Assert-True ($legacyTempEntries.Count -eq 1) '生产策略必须唯一声明 legacy temp capability root'
    $legacyTempEntry = $legacyTempEntries[0]
    Assert-True ($legacyTempEntry.capabilityRoot -ceq 'D:\Codex\.tmp') 'legacy temp capability root 必须精确指向 D:\Codex\.tmp'
    Assert-True ($legacyTempEntry.minimumDescendantDepth -eq 1) 'legacy temp capability root 不得删除根目录自身'
    Assert-True ($legacyTempEntry.rootDeletionPurpose -ceq 'none') 'legacy temp capability root 不得声明 root 删除用途'
    $productionPolicyExpectations = @(
        [pscustomobject]@{
            id = 'codex-managed-temp'
            capabilityRoot = 'D:\Codex\.codex\tmp'
            minimumDescendantDepth = 2
            rootDeletionPurpose = 'none'
        },
        [pscustomobject]@{
            id = 'environment-hook-pycache'
            capabilityRoot = 'D:\Codex\projects\统一环境\managed\codex-hooks\hooks\__pycache__'
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
        },
        [pscustomobject]@{
            id = 'environment-scripts-pycache'
            capabilityRoot = 'D:\Codex\projects\统一环境\scripts\__pycache__'
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
        },
        [pscustomobject]@{
            id = 'environment-tests-pycache'
            capabilityRoot = 'D:\Codex\projects\统一环境\tests\__pycache__'
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
        }
    )
    foreach ($expectedPolicyEntry in $productionPolicyExpectations) {
        $matchingPolicyEntries = @($productionPolicy.entries | Where-Object {
            $_.id -ceq $expectedPolicyEntry.id
        })
        Assert-True ($matchingPolicyEntries.Count -eq 1) "生产策略必须唯一声明 $($expectedPolicyEntry.id) capability root"
        $matchingPolicyEntry = $matchingPolicyEntries[0]
        Assert-True `
            ($matchingPolicyEntry.capabilityRoot -ceq $expectedPolicyEntry.capabilityRoot) `
            "$($expectedPolicyEntry.id) capability root 路径不匹配"
        Assert-True `
            ($matchingPolicyEntry.minimumDescendantDepth -eq $expectedPolicyEntry.minimumDescendantDepth) `
            "$($expectedPolicyEntry.id) minimumDescendantDepth 不匹配"
        Assert-True `
            ($matchingPolicyEntry.rootDeletionPurpose -ceq $expectedPolicyEntry.rootDeletionPurpose) `
            "$($expectedPolicyEntry.id) rootDeletionPurpose 不匹配"
        Assert-True `
            (@($matchingPolicyEntry.deniedExactPaths).Count -eq 0) `
            "$($expectedPolicyEntry.id) 不得隐含额外 denylist"
    }
    $planResult = & $entryPath `
        -Mode Plan `
        -TargetPath $targetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot

    Assert-True ($planResult.planned -eq $true) 'Plan 必须返回 planned=true'
    Assert-True ([IO.File]::Exists([string]$planResult.planPath)) 'Plan 必须发布受管计划文件'
    Assert-True ([string]$planResult.planSha256 -match '^[0-9a-f]{64}$') 'Plan 必须返回精确 SHA-256 capability'
    Assert-True ([IO.Directory]::Exists($targetPath)) 'Plan 必须保持目标只读不变'

    $unconfirmedApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$planResult.planPath) `
        -ApprovedPlanSha256 ([string]$planResult.planSha256) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($unconfirmedApply.refusalReason -ceq 'confirm-apply-required') 'Apply 缺少确认必须结构化拒绝'
    Assert-True ([IO.Directory]::Exists($targetPath)) '未确认 Apply 不得修改目标'

    $wrongHashError = Assert-Throws -Message '错误计划哈希必须失败关闭' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$planResult.planPath) `
            -ApprovedPlanSha256 ('0' * 64) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($wrongHashError -match 'hash|SHA-256|尚未实现') '错误哈希拒绝必须返回稳定原因'
    Assert-True ([IO.Directory]::Exists($targetPath)) '错误计划哈希不得修改目标'

    $applyResult = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$planResult.planPath) `
        -ApprovedPlanSha256 ([string]$planResult.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($applyResult.quarantined -eq $true) 'Apply 必须返回 quarantined=true'
    Assert-True (-not [IO.Directory]::Exists($targetPath)) 'Apply 必须原子移除原目标命名'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) 'Apply 必须保留可恢复隔离目录'
    $quarantinedPayload = Join-Path ([string]$applyResult.quarantinePath) 'payload.txt'
    Assert-True ([IO.File]::ReadAllText($quarantinedPayload) -ceq 'keep-until-apply') '隔离目录必须完整保留 payload'
    Assert-True (([IO.File]::GetAttributes($quarantinedPayload) -band [IO.FileAttributes]::ReadOnly) -ne 0) '隔离不得改写 ReadOnly 属性'

    $unconfirmedPurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($unconfirmedPurge.refusalReason -ceq 'confirm-purge-required') 'Purge 缺少确认必须结构化拒绝'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) '未确认 Purge 不得清理隔离目录'

    $wrongTransactionError = Assert-Throws -Message '错误 transaction 哈希必须失败关闭' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$applyResult.transactionPath) `
            -ApprovedTransactionSha256 ('0' * 64) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($wrongTransactionError -match 'hash|SHA-256|尚未实现') '错误 transaction 哈希拒绝必须返回稳定原因'
    Assert-True ([IO.Directory]::Exists([string]$applyResult.quarantinePath)) '错误 transaction 哈希不得清理隔离目录'

    $purgeResult = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$applyResult.transactionPath) `
        -ApprovedTransactionSha256 ([string]$applyResult.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($purgeResult.purged -eq $true) 'Purge 必须返回 purged=true'
    Assert-True (-not [IO.Directory]::Exists([string]$applyResult.quarantinePath)) 'Purge 必须清理精确隔离目录'
    Assert-True ($purgeResult.recoverable -eq $false) 'Purge 后必须明确标记不可恢复'

    [void][IO.Directory]::CreateDirectory($largeSparseTargetPath)
    [CodexSafeDeleteSparseFixture]::CreateZeroFile($largeSparseFilePath, [int64]2147483648)
    $largeSparseItem = Get-Item -LiteralPath $largeSparseFilePath -Force
    Assert-True ($largeSparseItem.Length -eq [int64]2147483648) '大文件 fixture 逻辑长度必须精确为 2 GiB'
    Assert-True (
        ($largeSparseItem.Attributes -band [IO.FileAttributes]::SparseFile) -ne 0
    ) '大文件 fixture 必须保留 NTFS SparseFile 属性'

    $largeSparsePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $largeSparseTargetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($largeSparsePlan.planned -eq $true) 'Plan 必须支持 2 GiB sparse 普通文件'
    Assert-True ([IO.File]::Exists($largeSparseFilePath)) '大文件 Plan 必须保持目标文件存在'
    $largeSparsePlanDocument = Get-Content -Raw -LiteralPath ([string]$largeSparsePlan.planPath) |
        ConvertFrom-Json -Depth 128
    $largeSparseEntries = @($largeSparsePlanDocument.treeManifest.entries | Where-Object {
        $_.relativePath -ceq 'large-zero.bin' -and $_.kind -ceq 'file'
    })
    Assert-True ($largeSparseEntries.Count -eq 1) '大文件 Plan manifest 必须唯一记录 sparse 文件'
    Assert-True (
        [string]$largeSparseEntries[0].sha256 -ceq 'a7c744c13cc101ed66c29f672f92455547889cc586ce6d44fe76ae824958ea51'
    ) '2 GiB sparse 零文件必须匹配独立固定 SHA-256'
    $deleteShareWaitMilliseconds = [CodexSafeDeleteSparseFixture]::WaitForDeleteShare($largeSparseFilePath, 30000)
    Assert-True ($deleteShareWaitMilliseconds -lt 30000) '大文件 fixture 必须在有界等待内允许 DELETE share'

    try {
        $largeSparseApply = & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$largeSparsePlan.planPath) `
            -ApprovedPlanSha256 ([string]$largeSparsePlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    } catch {
        throw "大文件 Apply 失败：$(Get-ExceptionChainText -Exception $_.Exception)"
    }
    $largeSparseQuarantinePath = [string]$largeSparseApply.quarantinePath
    Assert-True ($largeSparseApply.quarantined -eq $true) 'Apply 必须隔离包含 2 GiB sparse 文件的目录'
    Assert-True (-not [IO.Directory]::Exists($largeSparseTargetPath)) '大文件 Apply 后原目标必须不存在'
    Assert-True ([IO.Directory]::Exists($largeSparseQuarantinePath)) '大文件 Apply 必须保留 quarantine'

    $largeSparsePurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$largeSparseApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$largeSparseApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($largeSparsePurge.purged -eq $true) 'Purge 必须删除包含 2 GiB sparse 文件的 quarantine'
    Assert-True (-not [IO.Directory]::Exists($largeSparseQuarantinePath)) '大文件 Purge 后不得残留 quarantine'

    $partialPurge = New-InterruptedPurgeFixture `
        -Path (Join-Path $fixtureRoot 'partial-purge-candidate')
    $partialPurgeResult = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$partialPurge.transactionPath) `
        -ApprovedTransactionSha256 ([string]$partialPurge.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($partialPurgeResult.purged -eq $true) '显式 Purge 必须恢复 purging transaction 的部分删除状态'
    Assert-True (-not [IO.Directory]::Exists([string]$partialPurge.quarantinePath)) '部分删除恢复后不得残留 quarantine'

    $partialDrift = New-InterruptedPurgeFixture `
        -Path (Join-Path $fixtureRoot 'partial-purge-content-drift')
    [IO.File]::WriteAllText(
        [string]$partialDrift.remainingPath,
        'content-drift',
        [Text.UTF8Encoding]::new($false))
    $partialDriftError = Assert-Throws -Message 'purging transaction 内容漂移必须失败关闭' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$partialDrift.transactionPath) `
            -ApprovedTransactionSha256 ([string]$partialDrift.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($partialDriftError -match '漂移') 'purging transaction 内容漂移必须返回稳定原因'
    Assert-True ([IO.Directory]::Exists([string]$partialDrift.quarantinePath)) '内容漂移拒绝必须保留 quarantine 现场'
    Assert-True ([IO.File]::ReadAllText([string]$partialDrift.remainingPath) -ceq 'content-drift') '内容漂移拒绝不得修改现场文件'

    $partialUnexpected = New-InterruptedPurgeFixture `
        -Path (Join-Path $fixtureRoot 'partial-purge-unplanned-node')
    $unexpectedPath = Join-Path ([string]$partialUnexpected.quarantinePath) 'unplanned.txt'
    [IO.File]::WriteAllText($unexpectedPath, 'unplanned', [Text.UTF8Encoding]::new($false))
    $partialUnexpectedError = Assert-Throws -Message 'purging transaction 未计划节点必须失败关闭' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$partialUnexpected.transactionPath) `
            -ApprovedTransactionSha256 ([string]$partialUnexpected.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($partialUnexpectedError -match '漂移') 'purging transaction 未计划节点必须返回稳定原因'
    Assert-True ([IO.File]::Exists($unexpectedPath)) '未计划节点拒绝必须原样保留现场'

    $partialReplacement = New-InterruptedPurgeFixture `
        -Path (Join-Path $fixtureRoot 'partial-purge-file-replacement')
    $replacementPath = Join-Path ([string]$partialReplacement.quarantinePath) 'replacement.tmp'
    [IO.File]::WriteAllText($replacementPath, 'still-present', [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($replacementPath, [string]$partialReplacement.remainingPath, $true)
    $partialReplacementError = Assert-Throws -Message 'purging transaction 同内容文件替换必须失败关闭' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$partialReplacement.transactionPath) `
            -ApprovedTransactionSha256 ([string]$partialReplacement.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($partialReplacementError -match 'identity|漂移') 'purging transaction 文件 identity 漂移必须返回稳定原因'
    Assert-True ([IO.File]::Exists([string]$partialReplacement.remainingPath)) '文件 identity 漂移拒绝必须保留替换文件'

    $partialRootReplacement = New-InterruptedPurgeFixture `
        -Path (Join-Path $fixtureRoot 'partial-purge-root-replacement')
    $parkedQuarantine = '{0}.parked' -f ([string]$partialRootReplacement.quarantinePath)
    [IO.Directory]::Move([string]$partialRootReplacement.quarantinePath, $parkedQuarantine)
    [void][IO.Directory]::CreateDirectory([string]$partialRootReplacement.quarantinePath)
    [IO.File]::WriteAllText(
        (Join-Path ([string]$partialRootReplacement.quarantinePath) 'still-present.txt'),
        'still-present',
        [Text.UTF8Encoding]::new($false))
    $partialRootReplacementError = Assert-Throws -Message 'purging transaction quarantine root 替换必须失败关闭' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$partialRootReplacement.transactionPath) `
            -ApprovedTransactionSha256 ([string]$partialRootReplacement.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($partialRootReplacementError -match 'identity|漂移') 'purging transaction root identity 漂移必须返回稳定原因'
    Assert-True ([IO.Directory]::Exists([string]$partialRootReplacement.quarantinePath)) 'root identity 漂移拒绝必须保留替换目录'
    Assert-True ([IO.Directory]::Exists($parkedQuarantine)) 'root identity 漂移拒绝不得触及原隔离目录'

    $partialTargetReappeared = New-InterruptedPurgeFixture `
        -Path (Join-Path $fixtureRoot 'partial-purge-target-reappeared')
    [void][IO.Directory]::CreateDirectory([string]$partialTargetReappeared.targetPath)
    [IO.File]::WriteAllText(
        (Join-Path ([string]$partialTargetReappeared.targetPath) 'new-owner.txt'),
        'new-owner',
        [Text.UTF8Encoding]::new($false))
    $partialTargetReappearedError = Assert-Throws -Message 'purging transaction 原目标重新出现必须失败关闭' -Action {
        & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$partialTargetReappeared.transactionPath) `
            -ApprovedTransactionSha256 ([string]$partialTargetReappeared.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($partialTargetReappearedError -match '重新出现') 'purging transaction 原目标重新出现必须返回稳定原因'
    Assert-True ([IO.Directory]::Exists([string]$partialTargetReappeared.targetPath)) '原目标重新出现拒绝不得触及新目录'
    Assert-True ([IO.Directory]::Exists([string]$partialTargetReappeared.quarantinePath)) '原目标重新出现拒绝必须保留 quarantine'

    $rootParentEscapeError = Assert-Throws -Message 'minimumDescendantDepth=0 不得授权父目录' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath $rootTargetParent `
            -CapabilityRoot $rootTargetPath `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rootParentEscapeError -match 'capability root 内') '精确 root 策略必须拒绝父目录逃逸'

    $rollbackPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $rollbackRootTarget `
        -CapabilityRoot $rollbackRootTarget `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $rollbackPlanDocument = Get-Content -Raw -LiteralPath ([string]$rollbackPlan.planPath) | ConvertFrom-Json -Depth 128
    $rollbackQuarantinePath = Join-Path `
        $rollbackRootParent `
        ('.codex-safe-delete-{0}.quarantine' -f ([string]$rollbackPlanDocument.generationId))
    $rollbackError = Assert-Throws -Message 'root-target rename 后故障必须回滚' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$rollbackPlan.planPath) `
            -ApprovedPlanSha256 ([string]$rollbackPlan.planSha256) `
            -ConfirmApply `
            -FixtureFailAfterRename `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rollbackError -match 'fixture failure after rename') 'root-target 故障注入必须返回原始失败'
    Assert-True ([IO.Directory]::Exists($rollbackRootTarget)) 'root-target rollback 必须恢复原目录'
    Assert-True (-not [IO.Directory]::Exists($rollbackQuarantinePath)) 'root-target rollback 不得残留 quarantine'
    Assert-True (
        [IO.File]::ReadAllText((Join-Path $rollbackRootTarget 'rollback-payload.txt')) -ceq 'rollback-target'
    ) 'root-target rollback 必须完整恢复 payload'
    Assert-True ([IO.File]::ReadAllText($rollbackSiblingPath) -ceq 'must-survive') 'root-target rollback 不得触及同级文件'
    $rollbackTransactionPath = Join-Path (Split-Path -Parent ([string]$rollbackPlan.planPath)) 'transaction.json'
    $rollbackTransaction = Get-Content -Raw -LiteralPath $rollbackTransactionPath | ConvertFrom-Json -Depth 32
    Assert-True ($rollbackTransaction.status -ceq 'rolled-back') 'root-target rollback 必须发布 rolled-back transaction'

    $rootPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $rootTargetPath `
        -CapabilityRoot $rootTargetPath `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($rootPlan.planned -eq $true) 'minimumDescendantDepth=0 必须允许精确 capability root 计划'
    $rootApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$rootPlan.planPath) `
        -ApprovedPlanSha256 ([string]$rootPlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($rootApply.quarantined -eq $true) '精确 capability root 必须可隔离'
    Assert-True (-not [IO.Directory]::Exists($rootTargetPath)) '精确 capability root 隔离后原路径必须不存在'
    Assert-True ([IO.Directory]::Exists([string]$rootApply.quarantinePath)) '精确 capability root 必须保留同父隔离目录'
    $rootPurge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$rootApply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$rootApply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($rootPurge.purged -eq $true) '精确 capability root 必须可完成 purge'
    Assert-True (-not [IO.Directory]::Exists([string]$rootApply.quarantinePath)) '精确 capability root purge 后不得残留隔离目录'

    $rootDeleteError = Assert-Throws -Message 'capability root 自身必须拒绝' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath $fixtureRoot `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($rootDeleteError -match '最小后代深度') 'minimumDescendantDepth=1 必须继续拒绝 root 删除'

    $invalidProjectRootPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 2
        entries = @([pscustomobject][ordered]@{
            id = 'invalid-project-root'
            capabilityRoot = 'D:\Codex\projects\unsafe-workspace'
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $invalidProjectRootPolicyPath,
        ($invalidProjectRootPolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $projectRootPolicyError = Assert-Throws -Message 'minimumDescendantDepth=0 不得授权项目根' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath 'D:\Codex\projects\unsafe-workspace' `
            -CapabilityRoot 'D:\Codex\projects\unsafe-workspace' `
            -FixturePolicyPath $invalidProjectRootPolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True `
        ($projectRootPolicyError -match '必须位于项目根之下') `
        "项目根授权拒绝必须返回稳定原因，实际为：$projectRootPolicyError"

    $invalidStateRootPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 2
        entries = @([pscustomobject][ordered]@{
            id = 'invalid-state-root'
            capabilityRoot = 'D:\Codex\.codex\skills'
            minimumDescendantDepth = 0
            rootDeletionPurpose = 'rebuildable-build-output'
            deniedExactPaths = @()
        })
    }
    [IO.File]::WriteAllText(
        $invalidStateRootPolicyPath,
        ($invalidStateRootPolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $stateRootPolicyError = Assert-Throws -Message 'depth=0 不得授权 Codex 状态根' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath 'D:\Codex\.codex\skills' `
            -CapabilityRoot 'D:\Codex\.codex\skills' `
            -FixturePolicyPath $invalidStateRootPolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($stateRootPolicyError -match '必须位于项目根之下') '状态根授权必须失败关闭'

    $denylistError = Assert-Throws -Message 'denylist 子树必须拒绝' -Action {
        & $entryPath `
            -Mode Plan `
            -TargetPath $evidenceRoot `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($denylistError -match 'denylist') 'denylist 拒绝必须返回稳定原因'

    $driftTarget = Join-Path $fixtureRoot 'drift-candidate'
    [void][IO.Directory]::CreateDirectory($driftTarget)
    $driftOriginal = Join-Path $driftTarget 'a-original.txt'
    [IO.File]::WriteAllText($driftOriginal, 'original', [Text.UTF8Encoding]::new($false))
    $driftPlan = & $entryPath `
        -Mode Plan `
        -TargetPath $driftTarget `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $driftAdded = Join-Path $driftTarget 'z-added-after-plan.txt'
    [IO.File]::WriteAllText($driftAdded, 'drift', [Text.UTF8Encoding]::new($false))
    $driftError = Assert-Throws -Message '计划后树漂移必须拒绝' -Action {
        & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$driftPlan.planPath) `
            -ApprovedPlanSha256 ([string]$driftPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($driftError -match '漂移') '树漂移拒绝必须返回稳定原因'
    Assert-True ([IO.File]::Exists($driftOriginal) -and [IO.File]::Exists($driftAdded)) '树漂移拒绝必须发生在任何删除前'

    $batchParent = Join-Path $fixtureRoot 'batch-parent'
    $batchA = Join-Path $batchParent 'old-a'
    $batchB = Join-Path $batchParent 'old-b'
    $batchC = Join-Path $batchParent 'old-c'
    $batchD = Join-Path $batchParent 'old-d-partial-purge'
    foreach ($path in @($batchA, $batchB, $batchC)) {
        [void][IO.Directory]::CreateDirectory($path)
        [IO.File]::WriteAllText((Join-Path $path 'payload.txt'), $path, [Text.UTF8Encoding]::new($false))
    }
    $batchPrePlan = & $entryPath `
        -Mode Plan `
        -TargetPath $batchA `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $batchPreApply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$batchPrePlan.planPath) `
        -ApprovedPlanSha256 ([string]$batchPrePlan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($batchPreApply.quarantined -eq $true) 'batch fixture 必须能制造已 quarantine 未 purge 的中间态'
    Assert-True ([IO.Directory]::Exists([string]$batchPreApply.quarantinePath)) 'batch fixture 必须保留待恢复 quarantine'
    $batchPartial = New-InterruptedPurgeFixture -Path $batchD
    Assert-True ([IO.Directory]::Exists([string]$batchPartial.quarantinePath)) 'batch fixture 必须制造 purging 部分删除中间态'

    $unconfirmedBatch = & $entryPath `
        -Mode BatchPurge `
        -TargetPaths @($batchA, $batchB, $batchC, $batchD) `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($unconfirmedBatch.refusalReason -ceq 'confirm-apply-and-purge-required') 'BatchPurge 缺少确认必须结构化拒绝'
    Assert-True ([IO.Directory]::Exists($batchB) -and [IO.Directory]::Exists($batchC)) '未确认 BatchPurge 不得删除新目标'
    Assert-True ([IO.Directory]::Exists([string]$batchPreApply.quarantinePath)) '未确认 BatchPurge 不得清理既有 quarantine'

    $batchResult = & $entryPath `
        -Mode BatchPurge `
        -TargetPaths @($batchA, $batchB, $batchC, $batchD) `
        -CapabilityRoot $fixtureRoot `
        -ConfirmApply `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($batchResult.completed -eq $true) 'BatchPurge 必须完成批量清理'
    Assert-True ($batchResult.targetCount -eq 4) 'BatchPurge 必须报告全部目标数'
    Assert-True ($batchResult.purgedCount -eq 4) 'BatchPurge 必须 purge 新目标和恢复目标'
    Assert-True ($batchResult.recoveredCount -eq 2) 'BatchPurge 必须恢复 quarantined 与 purging transaction'
    Assert-True (-not [IO.Directory]::Exists($batchA)) 'BatchPurge 后原 batchA 不得存在'
    Assert-True (-not [IO.Directory]::Exists($batchB)) 'BatchPurge 后原 batchB 不得存在'
    Assert-True (-not [IO.Directory]::Exists($batchC)) 'BatchPurge 后原 batchC 不得存在'
    Assert-True (-not [IO.Directory]::Exists($batchD)) 'BatchPurge 后原 batchD 不得存在'
    Assert-True (-not [IO.Directory]::Exists([string]$batchPreApply.quarantinePath)) 'BatchPurge 必须清理既有 quarantine'
    Assert-True (-not [IO.Directory]::Exists([string]$batchPartial.quarantinePath)) 'BatchPurge 必须清理 purging 部分删除 quarantine'

    $junctionTarget = Join-Path $fixtureRoot 'junction-candidate'
    $junctionExternal = Join-Path $fixtureRoot 'junction-external'
    $junctionPath = Join-Path $junctionTarget 'linked'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    [void][IO.Directory]::CreateDirectory($junctionExternal)
    [IO.File]::WriteAllText((Join-Path $junctionExternal 'must-survive.txt'), 'outside', [Text.UTF8Encoding]::new($false))
    $junctionOutput = & $env:ComSpec /d /c mklink /J $junctionPath $junctionExternal 2>&1
    if ($LASTEXITCODE -ne 0) { throw "无法创建 safe-delete junction fixture：$junctionOutput" }
    try {
        $junctionError = Assert-Throws -Message 'reparse 子树必须拒绝' -Action {
            & $entryPath `
                -Mode Plan `
                -TargetPath $junctionTarget `
                -CapabilityRoot $fixtureRoot `
                -FixturePolicyPath $policyPath `
                -FixtureEvidenceRoot $evidenceRoot
        }
        Assert-True ($junctionError -match 'reparse') 'reparse 拒绝必须返回稳定原因'
        Assert-True ([IO.File]::Exists((Join-Path $junctionExternal 'must-survive.txt'))) 'reparse 拒绝不得触及外部内容'
    } finally {
        & $env:ComSpec /d /c rmdir $junctionPath | Out-Null
    }

    [pscustomobject][ordered]@{ ok = $true; suite = 'CodexSafeTreeDelete'; slices = 6 }
} finally {
    if ([IO.File]::Exists($largeSparseFilePath)) {
        [IO.File]::SetAttributes($largeSparseFilePath, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($largeSparseFilePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($largeSparseQuarantinePath)) {
        $quarantinedSparsePath = Join-Path $largeSparseQuarantinePath 'large-zero.bin'
        if ([IO.File]::Exists($quarantinedSparsePath)) {
            [IO.File]::SetAttributes($quarantinedSparsePath, [IO.FileAttributes]::Normal)
            [IO.File]::Delete($quarantinedSparsePath)
        }
    }
    Remove-TestTree -Path $fixtureRoot
}
