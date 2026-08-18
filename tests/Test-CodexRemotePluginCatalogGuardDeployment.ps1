[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $projectRoot 'scripts\Invoke-CodexRemotePluginCatalogGuard.ps1'
$runtimePath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\CodexRemotePluginCatalogGuard.ps1'
$policyPath = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard\policy.json'
$operationsPath = Join-Path $projectRoot 'docs\env-governance\remote-plugin-catalog-guard.md'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $entryPath -PathType Leaf) 'Check/Repair/Remove 治理入口不存在（预期 RED）'
Assert-True (Test-Path -LiteralPath $runtimePath -PathType Leaf) 'guard runtime source 不存在'
Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) 'guard policy source 不存在'
Assert-True (Test-Path -LiteralPath $operationsPath -PathType Leaf) 'guard 最少运维文档不存在（预期 RED）'

$entry = Get-Content -Raw -LiteralPath $entryPath
foreach ($required in @(
    "[ValidateSet('Check', 'Repair', 'Remove')]",
    'D:\Codex\.codex\catalog-guard',
    'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe',
    'D:\Codex\tools\python314-official\pythonw.exe',
    'Codex Remote Plugin Catalog Guard',
    'New-ScheduledTaskTrigger -AtLogOn',
    'CreateNoWindow'
)) {
    Assert-True $entry.Contains($required, [StringComparison]::Ordinal) "治理入口缺少固定合同：$required"
}
Assert-True (-not $entry.Contains('retired-skill-menu-surface.cjs', [StringComparison]::OrdinalIgnoreCase)) '治理入口不得调用综合退休清理器'
Assert-True (-not $entry.Contains('ExecutionPolicy', [StringComparison]::OrdinalIgnoreCase)) '治理入口不得修改或绕过 ExecutionPolicy'

$runtime = Get-Content -Raw -LiteralPath $runtimePath
Assert-True (-not $runtime.Contains('plugins\cache\openai-curated-remote', [StringComparison]::OrdinalIgnoreCase)) 'guard runtime 不得接触插件安装目录'
Assert-True (-not $runtime.Contains('D:\Codex\.codex\skills', [StringComparison]::OrdinalIgnoreCase)) 'guard runtime 不得接触 skill 安装目录'
foreach ($required in @(
    'AcquirePreparedTempFile($Path)',
    '.quarantine',
    '.publish',
    '.txn',
    '.vendor-abort',
    'EnumerateFileSystemEntries',
    'Invoke-CatalogTransactionReconciliation',
    'catalog-transaction-pending',
    'catalog-publish-io-failure'
)) {
    Assert-True $runtime.Contains($required, [StringComparison]::Ordinal) "runtime 缺少 crash-safe transaction 合同：$required"
}
Assert-True ($runtime.Contains('CurrentUserOnly = $true', [StringComparison]::Ordinal) -and $runtime.Contains('CurrentSessionOnly = $false', [StringComparison]::Ordinal)) 'runtime 必须使用 current-user-only 跨会话同步对象'
Assert-True ($entry.Contains('CurrentUserOnly = $true', [StringComparison]::Ordinal) -and $entry.Contains('CurrentSessionOnly = $false', [StringComparison]::Ordinal)) '治理入口必须使用 current-user-only 跨会话同步对象'
Assert-True (-not $runtime.Contains('Local\CodexRemotePluginCatalogGuard', [StringComparison]::Ordinal) -and -not $entry.Contains('Local\CodexRemotePluginCatalogGuard', [StringComparison]::Ordinal)) 'runtime/wrapper 不得残留 session-local 同步对象'
Assert-True (-not $runtime.Contains('scripts\remote-plugin-catalog-guard', [StringComparison]::OrdinalIgnoreCase) -and -not $entry.Contains('scripts\remote-plugin-catalog-guard', [StringComparison]::OrdinalIgnoreCase)) 'runtime/wrapper 不得残留过时 live 路径'
Assert-True $entry.Contains('ConvertFrom-StrictWatchStateJson', [StringComparison]::Ordinal) '治理入口必须严格解析 watcher state JSON'

$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json -Depth 32
Assert-True ($policy.schemaVersion -eq 2 -and $policy.mutexName -ceq 'CodexRemotePluginCatalogGuardV2' -and $policy.stopEventName -ceq 'CodexRemotePluginCatalogGuardStopV2') 'policy schema 或跨会话同步 identity 漂移'
$expectedTargets = [ordered]@{
    heygen = 'plugin_asdk_app_69418aad55e08191aa5e437b649ca2e4'
    hyperframes = 'Plugin_d72b815ecf6481919e3beede9c71ef08'
    remotion = 'plugins~Plugin_efd07789186881918253a50acfc32762'
    superpowers = 'plugins~Plugin_60aea7460bd4819199fd97a9553a5e12'
}
$actualTargets = [ordered]@{}
foreach ($target in @($policy.targets)) { $actualTargets[[string]$target.name] = [string]$target.id }
Assert-True (($actualTargets.Keys -join "`0") -ceq ($expectedTargets.Keys -join "`0")) 'policy target 名称或顺序漂移'
foreach ($name in $expectedTargets.Keys) { Assert-True ($actualTargets[$name] -ceq $expectedTargets[$name]) "policy target ID 漂移：$name" }

$operations = Get-Content -Raw -LiteralPath $operationsPath
foreach ($required in @(
    'quarantine',
    'no-replace',
    'reconcile',
    'vendor-abort',
    'transaction',
    'delete disposition',
    'txnIdentity',
    'publishIdentity',
    'vendorAbortIdentity',
    'handle-bound lease'
)) {
    Assert-True $operations.Contains($required, [StringComparison]::OrdinalIgnoreCase) "运维文档缺少 transaction 协议：$required"
}

Write-Output 'PASS Test-CodexRemotePluginCatalogGuardDeployment contracts=35 targets=4 canonicalLiveRoot=1 crossSessionCurrentUser=1 crashRecovery=1 strictState=1'
