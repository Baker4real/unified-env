[CmdletBinding()]
param()

# 完整 ProductionSmoke 会在 reports/ 下创建一次性 fixture，并经 live
# invoke-safe-tree-delete.cmd 在 D:\Codex\.codex\run-evidence\safe-tree-delete\
# 留下 operation。与 #22 的隔离：本套件只打 reports/ 下独立 capability 目标，
# 不读写 #22 的 Status/Archive 候选。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$reportsRoot = Join-Path $projectRoot 'reports'
$fixtureRoot = Join-Path $reportsRoot ("safe-tree-delete-production-smoke-{0}" -f ([guid]::NewGuid().ToString('N')))
$payloadPath = Join-Path $fixtureRoot 'readonly-payload.txt'
$batchParent = Join-Path $reportsRoot ("safe-tree-delete-batch-smoke-{0}" -f ([guid]::NewGuid().ToString('N')))
$batchA = Join-Path $batchParent 'old-a'
$batchB = Join-Path $batchParent 'old-b'
$liveWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$sourceWrapper = Join-Path $projectRoot 'scripts\invoke-codex-safe-tree-delete.cmd'
$livePowerShellWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
$sourcePowerShellWrapper = Join-Path $projectRoot 'scripts\invoke-codex-safe-tree-delete-host.ps1'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-LiveSafeDeleteJsonCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = & $liveWrapper @Arguments
    $exitCode = if (Test-Path Variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $text = ($raw -join "`n")
    return [pscustomobject][ordered]@{
        exitCode = $exitCode
        raw = $text
        document = $text | ConvertFrom-Json -Depth 32 -DateKind String
    }
}

function Invoke-LiveSafeDeleteJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $captured = Invoke-LiveSafeDeleteJsonCapture -Arguments $Arguments
    if ($captured.exitCode -ne 0) { throw "live safe-delete wrapper 失败：$($captured.raw)" }
    return $captured.document
}

Assert-True ([IO.File]::Exists($liveWrapper)) 'live safe-delete wrapper 必须存在'
Assert-True ([IO.File]::Exists($sourceWrapper)) 'source safe-delete wrapper 必须存在'
Assert-True ([IO.File]::Exists($livePowerShellWrapper)) 'live PowerShell safe-delete wrapper 必须存在'
Assert-True ([IO.File]::Exists($sourcePowerShellWrapper)) 'source PowerShell safe-delete wrapper 必须存在'
Assert-True (
    (Get-FileHash -LiteralPath $liveWrapper -Algorithm SHA256).Hash -ceq
    (Get-FileHash -LiteralPath $sourceWrapper -Algorithm SHA256).Hash
) 'live/source wrapper SHA-256 必须一致'
Assert-True (
    (Get-FileHash -LiteralPath $livePowerShellWrapper -Algorithm SHA256).Hash -ceq
    (Get-FileHash -LiteralPath $sourcePowerShellWrapper -Algorithm SHA256).Hash
) 'live/source PowerShell wrapper SHA-256 必须一致'

# Archive 缺 -ConfirmArchive 必须经真实 .cmd → 宿主 .ps1 → 生产实现：
# exit 0 + confirm-archive-required，且不写生产证据根。
$unconfirmedArchive = Invoke-LiveSafeDeleteJsonCapture -Arguments @(
    '-Mode', 'Archive',
    '-Json'
)
Assert-True ($unconfirmedArchive.exitCode -eq 0) `
    '缺确认 Archive 必须保持 exit 0，不得被 wrapper 改成非零'
Assert-True (
    $unconfirmedArchive.document.archived -eq $false -and
    [string]$unconfirmedArchive.document.refusalReason -ceq 'confirm-archive-required') `
    '缺确认 Archive 必须返回 confirm-archive-required'

[void][IO.Directory]::CreateDirectory($fixtureRoot)
[IO.File]::WriteAllText($payloadPath, 'production-smoke', [Text.UTF8Encoding]::new($false))
[IO.File]::SetAttributes($payloadPath, [IO.FileAttributes]::ReadOnly)

$plan = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Plan',
    '-TargetPath', $fixtureRoot,
    '-CapabilityRoot', $reportsRoot,
    '-Json'
)
Assert-True ($plan.planned -eq $true) 'live Plan 必须成功'
Assert-True ([IO.Directory]::Exists($fixtureRoot)) 'live Plan 必须保持目标不变'

$apply = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Apply',
    '-PlanPath', [string]$plan.planPath,
    '-ApprovedPlanSha256', [string]$plan.planSha256,
    '-ConfirmApply',
    '-Json'
)
Assert-True ($apply.quarantined -eq $true) 'live Apply 必须完成可恢复隔离'
Assert-True (-not [IO.Directory]::Exists($fixtureRoot)) 'live Apply 后原目标必须不存在'
Assert-True ([IO.Directory]::Exists([string]$apply.quarantinePath)) 'live Apply 必须保留 quarantine'

$purge = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Purge',
    '-TransactionPath', [string]$apply.transactionPath,
    '-ApprovedTransactionSha256', [string]$apply.transactionSha256,
    '-ConfirmPurge',
    '-Json'
)
Assert-True ($purge.purged -eq $true) 'live Purge 必须成功'
Assert-True (-not [IO.Directory]::Exists([string]$apply.quarantinePath)) 'live Purge 后 quarantine 必须不存在'

foreach ($path in @($batchA, $batchB)) {
    [void][IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path 'payload.txt'), $path, [Text.UTF8Encoding]::new($false))
}

$batchPrePlan = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Plan',
    '-TargetPath', $batchA,
    '-CapabilityRoot', $reportsRoot,
    '-Json'
)
$batchPreApply = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Apply',
    '-PlanPath', [string]$batchPrePlan.planPath,
    '-ApprovedPlanSha256', [string]$batchPrePlan.planSha256,
    '-ConfirmApply',
    '-Json'
)
Assert-True ($batchPreApply.quarantined -eq $true) 'live batch smoke 必须制造 recoverable quarantine'

$batch = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'BatchPurge',
    '-TargetPaths', ('{0}::{1}' -f $batchA, $batchB),
    '-CapabilityRoot', $reportsRoot,
    '-ConfirmApply',
    '-ConfirmPurge',
    '-Json'
)
Assert-True ($batch.completed -eq $true) 'live BatchPurge 必须成功'
Assert-True ($batch.purgedCount -eq 2) 'live BatchPurge 必须清理两个目标'
Assert-True ($batch.recoveredCount -eq 1) 'live BatchPurge 必须恢复一个 quarantine'
Assert-True (-not [IO.Directory]::Exists($batchA)) 'live BatchPurge 后 batchA 不得存在'
Assert-True (-not [IO.Directory]::Exists($batchB)) 'live BatchPurge 后 batchB 不得存在'
Assert-True (-not [IO.Directory]::Exists([string]$batchPreApply.quarantinePath)) 'live BatchPurge 后 recoverable quarantine 不得存在'

$batchParentPlan = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Plan',
    '-TargetPath', $batchParent,
    '-CapabilityRoot', $reportsRoot,
    '-Json'
)
$batchParentApply = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Apply',
    '-PlanPath', [string]$batchParentPlan.planPath,
    '-ApprovedPlanSha256', [string]$batchParentPlan.planSha256,
    '-ConfirmApply',
    '-Json'
)
$batchParentPurge = Invoke-LiveSafeDeleteJson -Arguments @(
    '-Mode', 'Purge',
    '-TransactionPath', [string]$batchParentApply.transactionPath,
    '-ApprovedTransactionSha256', [string]$batchParentApply.transactionSha256,
    '-ConfirmPurge',
    '-Json'
)
Assert-True ($batchParentPurge.purged -eq $true) 'live smoke 必须受管清理 batch 父目录'
Assert-True (-not [IO.Directory]::Exists($batchParent)) 'live smoke 不得遗留新的 batch 父目录'

# 不要在 Purge 开始前对 quarantine 持 FileShare.Read 来测 leaf-delete-failed。
# 生产 Purge 会先走 Get-CodexHookCapabilityDirectoryTreeSnapshot
# （scripts/lib/CodexSafeTreeDelete.ps1 约 3847 行，name=safe-delete purge locked preflight）。
# 该预检会因同一把锁卡住或抛错，到不了 delete catch，也打不出 leaf-delete-failed。
# 生产 CLI 没有 FixtureBeforeDirectoryTreeDelete。
# leaf-delete-failed 结构化 JSON 由 ControlPlane Retry 切片
# rollback-snapshot-lock-candidate 在 preflight 之后持锁覆盖，本 live 套件不证明生产 Purge 失败 JSON。

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteProductionSmoke'
    planPath = [string]$plan.planPath
    transactionPath = [string]$purge.transactionPath
    transactionSha256 = [string]$purge.transactionSha256
    batchRecoveredCount = [int]$batch.recoveredCount
    batchParentPurged = [bool]$batchParentPurge.purged
    unconfirmedArchiveExitCode = [int]$unconfirmedArchive.exitCode
    unconfirmedArchiveRefusalReason = [string]$unconfirmedArchive.document.refusalReason
}
