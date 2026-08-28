Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 §9 gate-aware shim：部署工具（Deploy-CodexSafeTreeDelete.ps1）把本文件原子安装为
# D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1。每次调用在任何 dot-source 之前
# 取得 current-user cross-session deployment mutex、检查 maintenance marker，并持锁到
# child/本进程退出。marker 在场时新调用失败闭锁；abandoned marker 不自动清除。

$codexSafeTreeDeleteDeploymentStateRoot = 'D:\Codex\.codex\state\safe-tree-delete-deployment'
$codexSafeTreeDeleteMaintenanceMarker = Join-Path $codexSafeTreeDeleteDeploymentStateRoot 'maintenance.json'
$codexSafeTreeDeleteRepositoryEntry = 'D:\agents\projects\统一环境\scripts\Invoke-CodexSafeTreeDelete.ps1'

$codexSafeTreeDeleteGateMutexBase = 'Global\CodexSafeTreeDeleteDeployment'
# current-user 命名空间（与 Deploy-CodexSafeTreeDelete.ps1 Get-DeploymentMutexName 同款）。
$codexSafeTreeDeleteGateMutexName = '{0}-u-{1}' -f @(
    $codexSafeTreeDeleteGateMutexBase,
    (([string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -replace '[^0-9]', ''))

$codexSafeTreeDeleteGateMutex = [System.Threading.Mutex]::new($false, $codexSafeTreeDeleteGateMutexName)
if (-not $codexSafeTreeDeleteGateMutex.WaitOne([TimeSpan]::FromMinutes(2))) {
    throw 'safe-tree-delete deployment mutex acquire timeout（maintenance 窗口持有者未释放）。'
}
try {
    if (Test-Path -LiteralPath $codexSafeTreeDeleteMaintenanceMarker) {
        throw 'safe-tree-delete 处于 deployment maintenance 窗口：拒绝新调用（maintenance marker present）。'
    }
    & $codexSafeTreeDeleteRepositoryEntry @args
    exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })
} finally {
    [void]$codexSafeTreeDeleteGateMutex.ReleaseMutex()
    $codexSafeTreeDeleteGateMutex.Dispose()
}
