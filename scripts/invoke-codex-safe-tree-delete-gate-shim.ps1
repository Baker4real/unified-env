Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

# #56 §9 gate-aware shim：部署工具（Deploy-CodexSafeTreeDelete.ps1）把本文件原子安装为
# D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1。每次调用在任何 dot-source 之前
# 取得 current-user cross-session deployment mutex、检查 maintenance marker，并持锁到
# child/本进程退出。marker 在场时新调用失败闭锁；abandoned marker 不自动清除。
#
# 门禁失败契约（2026-09-02 修复）：WaitOne 的 AbandonedMutexException 意味着所有权已
# 转移给本进程——释放后重试一次，阻止前持有者死亡造成的 abandoned 级联；两次尝试后
# 仍未获得锁时，向 stdout 输出 ASCII-only 结构化 JSON 并以 exit 1 结束，调用方按
# JSON + 退出码分类，不要 grep stderr 短语（历史缺陷：VT 转义码穿插 + 控制台 GBK
# 编码会打断多词短语匹配）。PlainText 渲染消除残余错误文本中的 ANSI 序列。

$codexSafeTreeDeleteDeploymentStateRoot = 'D:\Codex\.codex\state\safe-tree-delete-deployment'
$codexSafeTreeDeleteMaintenanceMarker = Join-Path $codexSafeTreeDeleteDeploymentStateRoot 'maintenance.json'
$codexSafeTreeDeleteRepositoryEntry = 'D:\agents\projects\统一环境\scripts\Invoke-CodexSafeTreeDelete.ps1'

$codexSafeTreeDeleteGateMutexBase = 'Global\CodexSafeTreeDeleteDeployment'
# current-user 命名空间（与 Deploy-CodexSafeTreeDelete.ps1 Get-DeploymentMutexName 同款）。
$codexSafeTreeDeleteGateMutexName = '{0}-u-{1}' -f @(
    $codexSafeTreeDeleteGateMutexBase,
    (([string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -replace '[^0-9]', ''))

$codexSafeTreeDeleteGateMutex = [System.Threading.Mutex]::new($false, $codexSafeTreeDeleteGateMutexName)
$codexSafeTreeDeleteGateAcquired = $false
foreach ($codexSafeTreeDeleteGateAttempt in 1..2) {
    try {
        $codexSafeTreeDeleteGateAcquired = $codexSafeTreeDeleteGateMutex.WaitOne([TimeSpan]::FromMinutes(2))
        break
    } catch [System.Threading.AbandonedMutexException] {
        try { [void]$codexSafeTreeDeleteGateMutex.ReleaseMutex() } catch { }
    }
}
if (-not $codexSafeTreeDeleteGateAcquired) {
    [pscustomobject][ordered]@{
        ok = $false
        refusalReason = 'deployment-mutex-acquire-timeout'
    } | ConvertTo-Json -Compress
    exit 1
}
try {
    if (Test-Path -LiteralPath $codexSafeTreeDeleteMaintenanceMarker) {
        [pscustomobject][ordered]@{
            ok = $false
            refusalReason = 'deployment-maintenance-marker-present'
        } | ConvertTo-Json -Compress
        exit 1
    }
    & $codexSafeTreeDeleteRepositoryEntry @args
    exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })
} finally {
    [void]$codexSafeTreeDeleteGateMutex.ReleaseMutex()
    $codexSafeTreeDeleteGateMutex.Dispose()
}
