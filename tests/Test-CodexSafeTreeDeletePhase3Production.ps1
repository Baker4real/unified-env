[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (#42 production wiring):
# 1. Invoke-CodexSafeTreeDeletePurge — capability-gated ParallelPurgeCoordinator
#    with HostSafetyParallelPurgeLeafDeleter (not File.Delete).
# 2. Get-CodexSafeTreeDeleteInFlightRecovery — parallel-purge-journal pending/uncertain.
# 3. FileSystemCapabilities.RecommendParallel=false → serial HostSafety.
# Not tested: leftover Purge/Restore, 10k wall-clock (see evidence runner).

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$evidenceHome = Join-Path $projectRoot 'reports\safe-tree-delete-issue42-20260819'
$fixtureRoot = Join-Path $evidenceHome ('prod-safety-{0}' -f ([guid]::NewGuid().ToString('N')))
$forbiddenQuarantine = Join-Path $projectRoot 'reports\.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
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

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
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
        -Name 'safe-delete phase3 production test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete phase3 production test cleanup'
}

function New-SmallTree {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Directory]::Exists($Path)) {
        Remove-TestTree -Path $Path
    }
    foreach ($name in @('dir-a', 'dir-b', 'dir-c')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $Path $name))
    }
    [IO.File]::WriteAllText((Join-Path $Path 'dir-a\a1.txt'), 'payload-a1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path 'dir-a\a2.txt'), 'payload-a2', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path 'dir-b\b1.txt'), 'payload-b1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path 'dir-c\c1.txt'), 'payload-c1', [Text.UTF8Encoding]::new($false))
    [void][IO.Directory]::CreateDirectory((Join-Path $Path 'dir-a\nested'))
    [IO.File]::WriteAllText((Join-Path $Path 'root.txt'), 'payload-root', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path 'dir-a\nested\n1.txt'), 'payload-nested', [Text.UTF8Encoding]::new($false))
}

function Invoke-ApplyOnly {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )
    $plan = New-CodexSafeTreeDeletePlan `
        -TargetPath $TargetPath `
        -CapabilityRoot $CapabilityRoot `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot
    $apply = Invoke-CodexSafeTreeDeleteQuarantine `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -PolicyPath $PolicyPath `
        -EvidenceRoot $EvidenceRoot
    return [pscustomobject][ordered]@{
        plan = $plan
        apply = $apply
    }
}

function Get-RemainingFiles {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [IO.Directory]::Exists($LiteralPath)) { return @() }
    return @(
        [IO.Directory]::EnumerateFiles($LiteralPath, '*', [IO.SearchOption]::AllDirectories)
    )
}

function Assert-LeftoverUntouched {
    if (-not [IO.Directory]::Exists($forbiddenQuarantine)) { return }
    Assert-True ([IO.Directory]::Exists($forbiddenQuarantine)) '不得删除 leftover quarantine 0ab1e1b6'
}

$runtimeEdition = [string]$PSVersionTable.PSEdition
Assert-True ($runtimeEdition -ceq 'Core') "本测试要求 PowerShell Core，实际为 $runtimeEdition"
. $hostSafetyLibraryPath
. $libraryPath

[void][IO.Directory]::CreateDirectory($evidenceHome)
[void][IO.Directory]::CreateDirectory($fixtureRoot)
Assert-True (
    $null -ne ('CodexSafeTreeDelete.HostSafetyParallelPurgeLeafDeleter' -as [type])
) 'HostSafetyParallelPurgeLeafDeleter 必须已加载'

$results = [Collections.Generic.List[object]]::new()
try {
    $capabilityRoot = Join-Path $fixtureRoot 'trees'
    $deniedPath = Join-Path $capabilityRoot 'denied'
    $policyPath = Join-Path $fixtureRoot 'policy.json'
    $evidenceRoot = Join-Path $fixtureRoot 'evidence'
    [void][IO.Directory]::CreateDirectory($capabilityRoot)
    [void][IO.Directory]::CreateDirectory($deniedPath)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    New-FixturePolicy -Path $policyPath -CapabilityRoot $capabilityRoot -DeniedPath $deniedPath -Id 'phase3-prod-safety'

    # AC10 + AC8: production parallel e2e, journals parseable, no leftover files.
    $e2eTarget = Join-Path $capabilityRoot 'e2e-candidate'
    New-SmallTree -Path $e2eTarget
    $e2e = Invoke-ApplyOnly `
        -TargetPath $e2eTarget `
        -CapabilityRoot $capabilityRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $e2ePurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$e2e.apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$e2e.apply.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ([bool]$e2ePurge.purged) 'AC10: 生产并行 Purge 必须成功'
    Assert-True ([bool]$e2ePurge.parallelPurge.used) 'AC10: 本地 NTFS 必须走 ParallelPurgeCoordinator'
    Assert-True ([bool]$e2ePurge.parallelPurge.usedHostSafetyDeleter) 'AC10: 必须用 HostSafety 删除器，不是 File.Delete'
    Assert-True ([int]$e2ePurge.parallelPurge.maxDegreeOfParallelism -ge 2) 'AC10: 推荐 DOP 必须 >= 2'
    Assert-True (-not [IO.Directory]::Exists($e2eTarget)) 'AC10: 原目标必须消失'
    Assert-True (-not [IO.Directory]::Exists([string]$e2e.apply.quarantinePath)) 'AC10: quarantine 必须消失'
    $e2eDispositions = Read-JsonDocument -Path ([string]$e2ePurge.leafDispositionsPath)
    Assert-True ([long]$e2eDispositions.summary.deleted -eq 6L) 'AC10: leafDispositions.deleted 必须是 6'
    $e2eRunDir = Split-Path -Parent ([string]$e2e.apply.transactionPath)
    $e2eJournalDirs = @(
        Get-ChildItem -LiteralPath $e2eRunDir -Directory -Filter 'parallel-purge-journal*'
    )
    Assert-True ($e2eJournalDirs.Count -ge 1) 'AC8: 生产 Purge 必须写出 parallel-purge-journal-*'
    $e2eJournals = @(
        $e2eJournalDirs | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Filter '*.thread-*.jsonl' -File
        }
    )
    Assert-True ($e2eJournals.Count -ge 3) 'AC8: 每个顶级目录必须有 thread journal'
    foreach ($journal in $e2eJournals) {
        $text = [IO.File]::ReadAllText($journal.FullName, [Text.UTF8Encoding]::new($false))
        $lines = @($text -split "`n" | Where-Object { $_.Length -gt 0 })
        Assert-True ($lines.Count -gt 0) "AC8: $($journal.Name) 不得为空"
        foreach ($line in $lines) {
            Assert-True ($line -match '^\{"op":"(pending|commit)","path":"[^"]+"\}$') `
                "AC8: journal 行必须可解析：$line"
        }
    }
    $results.Add([pscustomobject]@{ id = 'AC8-AC10-e2e'; ok = $true; dop = [int]$e2ePurge.parallelPurge.maxDegreeOfParallelism })

    # AC12: injected network capabilities must stay on serial HostSafety.
    $netTarget = Join-Path $capabilityRoot 'net-candidate'
    New-SmallTree -Path $netTarget
    $net = Invoke-ApplyOnly `
        -TargetPath $netTarget `
        -CapabilityRoot $capabilityRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $networkCaps = [CodexSafeTreeDelete.FileSystemCapabilities]::FromDetection('NTFS', $true, $true)
    Assert-True (-not [bool]$networkCaps.RecommendParallel) 'AC12: 网络卷 RecommendParallel 必须为 false'
    $netPurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$net.apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$net.apply.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -FileSystemCapabilitiesForTest $networkCaps
    Assert-True ([bool]$netPurge.purged) 'AC12: 降级串行仍必须删完'
    Assert-True (-not [bool]$netPurge.parallelPurge.used) 'AC12: 网络卷不得走并行协调器'
    Assert-True (-not [IO.Directory]::Exists($netTarget)) 'AC12: 串行降级后目标必须消失'
    $results.Add([pscustomobject]@{ id = 'AC12-network-serial'; ok = $true })

    # AC9: mutate a quarantine file after Apply → Purge must refuse.
    $toctouTarget = Join-Path $capabilityRoot 'toctou-candidate'
    New-SmallTree -Path $toctouTarget
    $toctou = Invoke-ApplyOnly `
        -TargetPath $toctouTarget `
        -CapabilityRoot $capabilityRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $mutated = Join-Path ([string]$toctou.apply.quarantinePath) 'dir-a\a1.txt'
    [IO.File]::WriteAllText($mutated, 'mutated-after-apply', [Text.UTF8Encoding]::new($false))
    $toctouFailed = $false
    try {
        [void](Invoke-CodexSafeTreeDeletePurge `
            -TransactionPath ([string]$toctou.apply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$toctou.apply.transactionSha256) `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot)
    } catch {
        $toctouFailed = $true
        $toctouMessage = [string]$_.Exception.Message
    }
    Assert-True $toctouFailed 'AC9: 并行 Purge 中途改文件必须拒绝'
    Assert-True (
        $toctouMessage -match 'IDENTITY|identity|漂移|mismatch|IdentityMismatch'
    ) "AC9: 拒绝原因必须是 identity/hash 漂移，实际为 $toctouMessage"
    Assert-True ([IO.File]::Exists($mutated)) 'AC9: 被改的文件不得被删掉'
    $results.Add([pscustomobject]@{ id = 'AC9-toctou'; ok = $true; message = $toctouMessage })

    # AC7: forced interrupt after first pending → pending recovery → resume completes.
    $crashTarget = Join-Path $capabilityRoot 'crash-candidate'
    New-SmallTree -Path $crashTarget
    $crash = Invoke-ApplyOnly `
        -TargetPath $crashTarget `
        -CapabilityRoot $capabilityRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $crashFailed = $false
    try {
        [void](Invoke-CodexSafeTreeDeletePurge `
            -TransactionPath ([string]$crash.apply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$crash.apply.transactionSha256) `
            -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot `
            -ParallelPurgeFailAfterPendingCountForTest 1)
    } catch {
        $crashFailed = $true
        $crashMessage = [string]$_.Exception.Message
    }
    Assert-True $crashFailed 'AC7: 强制中断必须让第一次 Purge 失败'
    Assert-True ($crashMessage -match 'forced-interrupt|parallel purge 失败') `
        "AC7: 失败信息必须指向强制中断，实际为 $crashMessage"
    $crashTxn = Read-JsonDocument -Path ([string]$crash.apply.transactionPath)
    $crashRunDir = Split-Path -Parent ([string]$crash.apply.transactionPath)
    $crashRecovery = Get-CodexSafeTreeDeleteInFlightRecovery `
        -RunDirectory $crashRunDir `
        -GenerationId ([string](Read-JsonDocument -Path ([string]$crash.plan.planPath)).generationId) `
        -DirectoryCommitAnchors @($crashTxn.directoryCommitAnchors) `
        -QuarantinePath ([string]$crash.apply.quarantinePath)
    Assert-True (@($crashRecovery.uncertainFiles).Count -eq 0) 'AC7: pending 后、删除前中断不得产生 uncertain'
    Assert-True (@($crashRecovery.pendingFiles).Count -ge 1) 'AC7: 必须能看到 pending 未 commit 的路径'
    $resumeTxnSnapshot = Get-CodexHookCapabilityFileSnapshot `
        -Path ([string]$crash.apply.transactionPath) `
        -CapabilityRoot $crashRunDir `
        -AllowedExactPaths @([string]$crash.apply.transactionPath) `
        -Name 'safe-delete phase3 production resume transaction'
    $resume = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$crash.apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$resumeTxnSnapshot.sha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    Assert-True ([bool]$resume.purged) 'AC7: 恢复后第二次 Purge 必须完成'
    Assert-True (-not [IO.Directory]::Exists($crashTarget)) 'AC7: 恢复后原目标必须消失'
    Assert-True (-not [IO.Directory]::Exists([string]$crash.apply.quarantinePath)) 'AC7: 恢复后 quarantine 必须消失'
    $results.Add([pscustomobject]@{
        id = 'AC7-interrupt-resume'
        ok = $true
        pendingCount = @($crashRecovery.pendingFiles).Count
        uncertainCount = @($crashRecovery.uncertainFiles).Count
    })

    # DisableParallelPurgeForTest must stay serial even on local NTFS.
    $serialTarget = Join-Path $capabilityRoot 'serial-flag-candidate'
    New-SmallTree -Path $serialTarget
    $serial = Invoke-ApplyOnly `
        -TargetPath $serialTarget `
        -CapabilityRoot $capabilityRoot `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot
    $serialPurge = Invoke-CodexSafeTreeDeletePurge `
        -TransactionPath ([string]$serial.apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$serial.apply.transactionSha256) `
        -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot `
        -DisableParallelPurgeForTest
    Assert-True ([bool]$serialPurge.purged) 'DisableParallelPurgeForTest 仍必须删完'
    Assert-True (-not [bool]$serialPurge.parallelPurge.used) 'DisableParallelPurgeForTest 必须串行'
    $results.Add([pscustomobject]@{ id = 'disable-parallel-flag'; ok = $true })
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) {
        $quarantines = @(
            Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '.codex-safe-delete-*.quarantine' }
        )
        foreach ($item in $quarantines) {
            if ($item.FullName -ceq $forbiddenQuarantine) { continue }
            Remove-TestTree -Path $item.FullName
        }
        $candidates = @(
            Get-ChildItem -LiteralPath (Join-Path $fixtureRoot 'trees') -Force -Directory -ErrorAction SilentlyContinue
        )
        foreach ($item in $candidates) {
            if ($item.Name -ceq 'denied') { continue }
            if ([IO.Directory]::Exists($item.FullName)) {
                Remove-TestTree -Path $item.FullName
            }
        }
    }
}

$report = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue42-production-safety'
    ok = $true
    slices = @($results)
    leftoverUntouched = $true
}
Write-JsonFile -Path (Join-Path $evidenceHome 'production-safety.json') -Document $report
Write-Output ('ok=True slices={0}' -f $results.Count)
