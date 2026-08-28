[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 §9：Deploy-CodexSafeTreeDelete.ps1 的部署/回滚状态机测试（fixture state root/shim/
# mutex seam；生产 root 永不被触碰）。覆盖：Bootstrap→Deploy 全路径、崩溃于 10/30/60/70
# 的 RecoverRollback 矩阵、complete 的两种收尾、错 owner/marker/journal 篡改拒绝、
# 终态/在途 run 的二次操作拒绝、部署者持锁时 gate 阻断负控。

$projectRoot = Split-Path -Parent $PSScriptRoot
$deployTool = Join-Path $projectRoot 'scripts\Deploy-CodexSafeTreeDelete.ps1'
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteClosure.ps1')
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action | Out-Null
    } catch {
        return $_.Exception.Message
    }
    throw $Message
}

function New-ScenarioRoot {
    param([Parameter(Mandatory)][string]$Name)
    $root = Join-Path $fixtureRoot $Name
    $stateRoot = Join-Path $root 'state'
    $shimPath = Join-Path $root 'invoke-safe-tree-delete.ps1'
    [void][IO.Directory]::CreateDirectory($stateRoot)
    # fixture shim：与生产同构的薄委托。
    [IO.File]::WriteAllText($shimPath, @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& 'D:\agents\projects\统一环境\scripts\Invoke-CodexSafeTreeDelete.ps1' @args
exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })
'@, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Name = $Name
        Root = $root
        StateRoot = $stateRoot
        ShimPath = $shimPath
        MutexName = ('Local\std-deploy-test-{0}' -f $Name)
        OriginalShimSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [IO.File]::ReadAllBytes($shimPath))).ToLowerInvariant()
    }
}

function Invoke-DeployTool {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$DeploymentId,
        [Parameter(Mandatory)][object]$Scenario,
        [string]$PreviousClosureSha256,
        [int]$StopAfterPhase = 0
    )
    $arguments = @{
        Mode = $Mode
        DeploymentId = $DeploymentId
        StateRootForTest = $Scenario.StateRoot
        ShimPathForTest = $Scenario.ShimPath
        ProjectRootForTest = $projectRoot
        MutexNameForTest = $Scenario.MutexName
    }
    if (-not [string]::IsNullOrWhiteSpace($PreviousClosureSha256)) {
        $arguments.PreviousClosureSha256 = $PreviousClosureSha256
    }
    if ($StopAfterPhase -gt 0) {
        $arguments.StopAfterPhaseForTest = $StopAfterPhase
    }
    & $deployTool @arguments
}

$currentClosure = (Get-CodexSafeTreeDeleteClosure -ProjectRoot $projectRoot).closureSha256

# 密封化：部署 validation 子进程默认走 default variant（csharp walker）；清除套件级
# CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER 预设（如 fixture-base env=0 轮），结束时恢复。
$ambientPlanWalkerEnv = [string]$env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER
if ($null -ne $env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER) {
    Remove-Item Env:\CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER -ErrorAction Stop
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)

    # ---- S1：BootstrapGate → Deploy 全路径 ----
    $s1 = New-ScenarioRoot -Name 's1'
    Write-Output 'STEP s1-bootstrap'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'full-run' -Scenario $s1 -PreviousClosureSha256 $currentClosure | Out-Null
    Assert-True (-not [IO.File]::Exists((Join-Path $s1.StateRoot 'maintenance.json'))) 'BootstrapGate 后 marker 不得存在'
    $gateShimText = [IO.File]::ReadAllText($s1.ShimPath)
    Assert-True ($gateShimText -cmatch 'CodexSafeTreeDeleteDeployment' -or
        $gateShimText -cmatch [regex]::Escape($s1.MutexName)) 'cutover 后 shim 必须是 gate-aware 版本'
    Write-Output 'STEP s1-deploy'
    Invoke-DeployTool -Mode Deploy -DeploymentId 'full-run' -Scenario $s1 | Out-Null
    Assert-True (-not [IO.File]::Exists((Join-Path $s1.StateRoot 'maintenance.json'))) 'complete 后 marker 必须删除'
    $receipt = Get-Content -Raw -LiteralPath (Join-Path $s1.StateRoot 'deployments\full-run\final-receipt.json') | ConvertFrom-Json
    Assert-True ([string]$receipt.outcome -ceq 'complete') 'happy path final receipt 必须 complete'
    $again = Assert-Throws -Message 'terminal run 的 Deploy 必须拒绝' -Action {
        Invoke-DeployTool -Mode Deploy -DeploymentId 'full-run' -Scenario $s1 | Out-Null
    }
    Assert-True ($again -match 'terminal') 'terminal 拒绝必须指向终态'

    # ---- S2：崩溃@10 → bootstrap 回滚（marker 缺席矩阵）----
    $s2 = New-ScenarioRoot -Name 's2'
    Write-Output 'STEP s2-bootstrap'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'crash10' -Scenario $s2 -PreviousClosureSha256 $currentClosure -StopAfterPhase 10 | Out-Null
    Assert-True (([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($s2.ShimPath))).ToLowerInvariant()) -ceq $s2.OriginalShimSha) `
        '崩溃@10 后 shim 必须仍是原字节（cutover 未发生）'
    $retake = Assert-Throws -Message '在途 run 的同 id BootstrapGate 必须拒绝' -Action {
        Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'crash10' -Scenario $s2 -PreviousClosureSha256 $currentClosure | Out-Null
    }
    Assert-True ($retake -match '已存在') '同 id 重复 intent 拒绝必须指向已存在'
    Write-Output 'STEP s2-recover'
    Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'crash10' -Scenario $s2 | Out-Null
    $receipt2 = Get-Content -Raw -LiteralPath (Join-Path $s2.StateRoot 'deployments\crash10\final-receipt.json') | ConvertFrom-Json
    Assert-True ([string]$receipt2.outcome -ceq 'rolled-back') '崩溃@10 恢复必须 rolled-back'

    # ---- S3：在途 run 阻塞新 deploymentId 接管 ----
    $s3 = New-ScenarioRoot -Name 's3'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'old-incomplete' -Scenario $s3 -PreviousClosureSha256 $currentClosure -StopAfterPhase 10 | Out-Null
    $takeover = Assert-Throws -Message '在途 run 未收尾时新 id 必须拒绝' -Action {
        Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'new-takeover' -Scenario $s3 -PreviousClosureSha256 $currentClosure | Out-Null
    }
    Assert-True ($takeover -match '未收尾') '接管拒绝必须指向未收尾 run'
    Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'old-incomplete' -Scenario $s3 | Out-Null
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'new-takeover' -Scenario $s3 -PreviousClosureSha256 $currentClosure | Out-Null
    Write-Output 'S3 takeover-after-recovery OK'

    # ---- S4：崩溃@30 → marker 在场矩阵 + 篡改拒绝 + 回滚 ----
    $s4 = New-ScenarioRoot -Name 's4'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'crash30' -Scenario $s4 -PreviousClosureSha256 $currentClosure | Out-Null
    Write-Output 'STEP s4-deploy30'
    Invoke-DeployTool -Mode Deploy -DeploymentId 'crash30' -Scenario $s4 -StopAfterPhase 30 | Out-Null
    $markerPath = Join-Path $s4.StateRoot 'maintenance.json'
    Assert-True ([IO.File]::Exists($markerPath)) '崩溃@30 后 marker 必须在场'
    $tampered = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
    $tampered.deploymentId = 'someone-else'
    [IO.File]::WriteAllText($markerPath, ($tampered | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $mismatch = Assert-Throws -Message 'marker 不匹配必须拒绝' -Action {
        Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'crash30' -Scenario $s4 | Out-Null
    }
    Assert-True ($mismatch -match 'marker') 'marker 拒绝必须指向 marker'
    $tampered.deploymentId = 'crash30'
    [IO.File]::WriteAllText($markerPath, ($tampered | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'crash30' -Scenario $s4 | Out-Null
    Assert-True (-not [IO.File]::Exists($markerPath)) '回滚后 marker 必须删除'
    Assert-True (([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($s4.ShimPath))).ToLowerInvariant()) -ceq $s4.OriginalShimSha) '回滚后 shim 必须恢复原字节'

    # ---- S5：崩溃@60 → previous closure 前置 + 回滚 ----
    $s5 = New-ScenarioRoot -Name 's5'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'crash60' -Scenario $s5 -PreviousClosureSha256 ('dead' * 8) | Out-Null
    Invoke-DeployTool -Mode Deploy -DeploymentId 'crash60' -Scenario $s5 -StopAfterPhase 60 | Out-Null
    $closureRefuse = Assert-Throws -Message 'previous closure 未就位必须拒绝' -Action {
        Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'crash60' -Scenario $s5 | Out-Null
    }
    Assert-True ($closureRefuse -match 'previous closure') '回滚前置拒绝必须指向 previous closure'

    # ---- S6：崩溃@70 → 恢复完成 target ----
    $s6 = New-ScenarioRoot -Name 's6'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'crash70' -Scenario $s6 -PreviousClosureSha256 $currentClosure | Out-Null
    Invoke-DeployTool -Mode Deploy -DeploymentId 'crash70' -Scenario $s6 -StopAfterPhase 70 | Out-Null
    Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'crash70' -Scenario $s6 | Out-Null
    $receipt6 = Get-Content -Raw -LiteralPath (Join-Path $s6.StateRoot 'deployments\crash70\final-receipt.json') | ConvertFrom-Json
    Assert-True ([string]$receipt6.outcome -ceq 'complete') '崩溃@70 恢复必须完成 target'
    Assert-True (-not [IO.File]::Exists((Join-Path $s6.StateRoot 'maintenance.json'))) '完成 target 后 marker 必须删除'

    # ---- S7：complete 幂等收尾（receipt 缺失补写；marker 残留清除）----
    $s7 = New-ScenarioRoot -Name 's7'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'idempotent' -Scenario $s7 -PreviousClosureSha256 $currentClosure | Out-Null
    Invoke-DeployTool -Mode Deploy -DeploymentId 'idempotent' -Scenario $s7 | Out-Null
    $receipt7Path = Join-Path $s7.StateRoot 'deployments\idempotent\final-receipt.json'
    [void][IO.File]::Delete($receipt7Path)
    Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'idempotent' -Scenario $s7 | Out-Null
    Assert-True ([IO.File]::Exists($receipt7Path)) 'complete + marker 已删 + receipt 缺失必须幂等补写'

    # ---- S8：错 owner / journal 篡改拒绝 ----
    $s8 = New-ScenarioRoot -Name 's8'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'tamper' -Scenario $s8 -PreviousClosureSha256 $currentClosure -StopAfterPhase 10 | Out-Null
    $intentPath8 = Join-Path $s8.StateRoot 'deployments\tamper\00-intent.json'
    $intent8 = Get-Content -Raw -LiteralPath $intentPath8 | ConvertFrom-Json
    $intent8.ownerSid = 'S-1-5-21-0-0-0-0'
    [IO.File]::WriteAllText($intentPath8, ($intent8 | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $ownerRefuse = Assert-Throws -Message '错 owner 必须拒绝' -Action {
        Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'tamper' -Scenario $s8 | Out-Null
    }
    Assert-True ($ownerRefuse -match 'owner') 'owner 拒绝必须指向 owner'
    $intent8.ownerSid = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [IO.File]::WriteAllText($intentPath8, ($intent8 | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $journalFile = Get-ChildItem -LiteralPath (Join-Path $s8.StateRoot 'deployments\tamper\phase-journal') -Filter '*.json' | Select-Object -First 1
    $journalEntry = Get-Content -Raw -LiteralPath $journalFile.FullName | ConvertFrom-Json
    $journalEntry.previousJournalSha256 = 'tampered'
    [IO.File]::WriteAllText($journalFile.FullName, ($journalEntry | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $chainRefuse = Assert-Throws -Message 'journal 链被篡改必须拒绝' -Action {
        Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'tamper' -Scenario $s8 | Out-Null
    }
    Assert-True ($chainRefuse -match '链') 'journal 拒绝必须指向链校验'

    # ---- S9：gate 负控（外部持锁时经 shim 的调用被阻断）----
    $s9 = New-ScenarioRoot -Name 's9'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'gate-proof' -Scenario $s9 -PreviousClosureSha256 $currentClosure | Out-Null
    $sidSuffix = (([string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -replace '[^0-9]', '')
    $holderMutexName = '{0}-u-{1}' -f $s9.MutexName, $sidSuffix
    $holder = [System.Threading.Mutex]::new($false, $holderMutexName)
    [void]$holder.WaitOne()
    try {
        $process = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $s9.ShimPath, '-Mode', 'Status') `
            -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 4
        Assert-True (-not $process.HasExited) '外部持锁时 shim 调用必须被 gate 等待'
        if (-not $process.HasExited) { [void]$process.Kill() }
    } finally {
        [void]$holder.ReleaseMutex()
        $holder.Dispose()
    }
    # marker 在场时 shim 调用必须拒绝。
    $markerPath9 = Join-Path $s9.StateRoot 'maintenance.json'
    [IO.File]::WriteAllText($markerPath9, (@{
        schemaVersion = '1'; deploymentId = 'gate-proof';
        runPath = (Join-Path $s9.StateRoot 'deployments\gate-proof');
        intentSha256 = '0' * 64
    } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $markerRefuseOutput = & pwsh -NoProfile -NonInteractive -File $s9.ShimPath -Mode Status 2>&1 | Out-String
    Assert-True ($markerRefuseOutput -match 'maintenance') 'marker 在场时 shim 必须失败闭锁'
    [void][IO.File]::Delete($markerPath9)
    Invoke-DeployTool -Mode RecoverRollback -DeploymentId 'gate-proof' -Scenario $s9 | Out-Null

    Write-Output 'DEPLOYMENT-TESTS OK'
} finally {
    if ($null -ne $ambientPlanWalkerEnv) {
        $env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER = $ambientPlanWalkerEnv
    } elseif (Test-Path Env:\CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER) {
        Remove-Item Env:\CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        foreach ($journalDir in (Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Directory -Filter 'phase-journal' -ErrorAction SilentlyContinue)) {
            # 状态根是纯 fixture JSON，无受管删除需求；直接清理。
        }
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Output 'DEPLOYMENT DONE'
