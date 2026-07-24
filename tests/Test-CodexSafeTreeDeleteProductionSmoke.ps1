[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$reportsRoot = Join-Path $projectRoot 'reports'
$fixtureRoot = Join-Path $reportsRoot ("safe-tree-delete-production-smoke-{0}" -f ([guid]::NewGuid().ToString('N')))
$payloadPath = Join-Path $fixtureRoot 'readonly-payload.txt'
$liveWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$sourceWrapper = Join-Path $projectRoot 'scripts\invoke-codex-safe-tree-delete.cmd'
$livePowerShellWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
$sourcePowerShellWrapper = Join-Path $projectRoot 'scripts\invoke-codex-safe-tree-delete-host.ps1'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-LiveSafeDeleteJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = & $liveWrapper @Arguments
    if ($LASTEXITCODE -ne 0) { throw "live safe-delete wrapper 失败：$raw" }
    return ($raw -join "`n") | ConvertFrom-Json -Depth 32 -DateKind String
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

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteProductionSmoke'
    planPath = [string]$plan.planPath
    transactionPath = [string]$purge.transactionPath
    transactionSha256 = [string]$purge.transactionSha256
}
