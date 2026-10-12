#requires -Version 7.5
<#
.SYNOPSIS
默认生成只读计划；Apply 必须提供 120 秒内的计划，并重新验证同一用户会话与 shell 身份。
.EXAMPLE
& ./Restart-ExplorerShell.ps1 -PlanPath D:/agents/run-evidence/explorer-shell-recovery/plan.json
.EXAMPLE
& ./Restart-ExplorerShell.ps1 -Mode Apply -PlanPath D:/agents/run-evidence/explorer-shell-recovery/plan.json
.DESCRIPTION
只重启已验证的 shell，不清缓存或修改固定项。打开文件夹或可见文件操作窗口时拒绝执行。
正常 CLI 失败返回非零退出码；-AsObject 返回结构化结果供调用者自行判断 Status。
-TestSessionPath 只接受测试器创建的、同一调用进程拥有的限时隔离会话。
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan','Apply')][string]$Mode = 'Plan',
    [string]$PlanPath,
    [string]$EvidenceDirectory,
    [string]$TestSessionPath,
    [ValidateRange(5,60)][int]$ReadinessTimeoutSeconds = 20,
    [switch]$AsObject
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/ExplorerShellRecovery.ps1"
if ($Mode -eq 'Plan') {
    $output = New-ExplorerRecoveryPlan -TestSessionPath $TestSessionPath -ReadinessTimeoutSeconds $ReadinessTimeoutSeconds
    if ($PlanPath) { Write-ExplorerRecoveryJson -Path $PlanPath -Value $output }
}
else {
    if (-not $PlanPath) { throw 'Apply requires -PlanPath from a fresh read-only Plan.' }
    $plan = Read-ExplorerRecoveryJson -Path $PlanPath
    if (-not $EvidenceDirectory) { $EvidenceDirectory = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PlanPath))) ('apply-' + [guid]::NewGuid().ToString('N')) }
    $context = Get-ExplorerRecoveryContext
    $mutex = [Threading.Mutex]::new($false, (Get-ExplorerRecoveryMutexName -Context $context))
    $locked = $false
    try {
        $locked = $mutex.WaitOne(0)
        if (-not $locked) {
            $output = [pscustomobject][ordered]@{
                SchemaVersion = 1; Mode = 'Apply'; Status = 'refused'; Reason = 'ExplorerRecoveryAlreadyInProgress'
                StopAttempted = $false; DesktopAndTaskbarReady = $false; PinsUnchanged = $null
                ProcessState = 'unchanged'; OriginalIdentity = $plan.Snapshot.ShellProcess; NewIdentity = $null
                LaunchAttempts = @(); EvidenceDirectory = $EvidenceDirectory
            }
            Write-ExplorerRecoveryJson -Path (Join-Path $EvidenceDirectory 'result.json') -Value $output
        }
        else { $output = Invoke-ExplorerRecovery -Plan $plan -TestSessionPath $TestSessionPath -EvidenceDirectory $EvidenceDirectory }
    }
    catch [Threading.AbandonedMutexException] {
        $locked = $true
        $output = [pscustomobject][ordered]@{
            SchemaVersion = 1; Mode = 'Apply'; Status = 'refused'; Reason = 'ExplorerRecoveryLockAbandoned'
            StopAttempted = $false; DesktopAndTaskbarReady = $false; PinsUnchanged = $null
            ProcessState = 'manual-review'; OriginalIdentity = $plan.Snapshot.ShellProcess; NewIdentity = $null
            LaunchAttempts = @(); EvidenceDirectory = $EvidenceDirectory
        }
        Write-ExplorerRecoveryJson -Path (Join-Path $EvidenceDirectory 'result.json') -Value $output
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
if ($AsObject) { $output }
else {
    $output | ConvertTo-Json -Depth 12
    if ($Mode -eq 'Apply' -and $output.Status -ne 'ready') { exit 1 }
}
