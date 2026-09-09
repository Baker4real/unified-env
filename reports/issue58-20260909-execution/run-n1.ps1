$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo='D:/agents/projects/统一环境'
$pwsh='D:/Codex/tools/PowerShell/7.6.5/pwsh.exe'
$evidence='D:/agents/run-evidence/safe-tree-delete'
$policy=Join-Path $repo 'managed/safe-tree-delete/policy.json'
$summary=[ordered]@{phase='N1';rawExitCodes=[ordered]@{};error=$null;observation=$null;environment=@();source=@();scope='仓库直接入口诊断，不是宿主 gate 验收；仅比较冻结管线基线，保留已知 23-op 分叉。'}
foreach($name in @('CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN','CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK','CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST')){
    foreach($target in @('Process','User','Machine')){
        $value=[Environment]::GetEnvironmentVariable($name,$target)
        $summary.environment+=@{name=$name;target=$target;value=$value;default=([string]::IsNullOrEmpty($value) -or $value -ceq '1')}
    }
}
foreach($relative in @('scripts/lib/CodexSafeTreeDelete.ps1','scripts/lib/CodexSafeTreeDeleteStatusScan.cs','scripts/lib/CodexHostSafetyNativeLoader.ps1','scripts/Invoke-CodexSafeTreeDelete.ps1','reports/issue58-20260908/evidence-fingerprint.ps1')){
    $summary.source+=@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $repo $relative)).Hash.ToLowerInvariant()}
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'preflight.json'),($summary|ConvertTo-Json -Depth 8))
if(@($summary.environment|Where-Object{-not $_.default}).Count){throw '三开关存在非默认外部设置，拒绝正式默认诊断。'}
Add-Type -Path (Join-Path $PSScriptRoot 'ProcessObservation.cs')
$observer=[Issue58N1.WriteObservation]::new($evidence,$policy)
try {
    if($observer.WatcherCount -ne 3 -or $observer.Errors.Count){throw '写事件观测不可用。'}
    foreach($step in @('before','diagnostic','after')){
        Write-Output "N1 阶段: $step"
        if($step -eq 'diagnostic'){
            & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'invoke-bounded.ps1') -Payload (Join-Path $PSScriptRoot 'diagnostic-payload.ps1') -Name 'n1-default' -DeadlineMs 180000
        }else{
            & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'invoke-bounded.ps1') -Payload (Join-Path $PSScriptRoot 'fingerprint-payload.ps1') -PayloadArguments $step -Name "fingerprint-$step" -Contract Fingerprint -DeadlineMs 600000
        }
        $summary.rawExitCodes[$step]=$LASTEXITCODE
        if($step -eq 'before' -and $LASTEXITCODE -ne 0){throw 'before 指纹失败，未启动真实 Status。'}
    }
}catch{$summary.error=$_.Exception.Message}finally{
    Start-Sleep -Milliseconds 500
    $summary.observation=@{startedAtUtc=$observer.StartedAtUtc.ToString('o');endedAtUtc=[datetime]::UtcNow.ToString('o');drainMs=500;watcherCount=$observer.WatcherCount;events=$observer.EventCount;kindCounts=$observer.KindCounts;overflow=$observer.OverflowCount;errors=$observer.Errors;valid=($observer.WatcherCount -eq 3 -and $observer.OverflowCount -eq 0 -and $observer.Errors.Count -eq 0);statement='仅在限定范围和窗口内观测；FSW 不是主机级完整写事件审计。'}
    $observer.Dispose()
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'execution-n1.json'),($summary|ConvertTo-Json -Depth 10))
}
Write-Output 'N1 采样及指纹阶段已收口。'
if($null -ne $summary.error -or @($summary.rawExitCodes.Values|Where-Object{$_ -ne 0}).Count){exit 1}
exit 0
