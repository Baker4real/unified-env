[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 §9：Deploy-CodexSafeTreeDelete.ps1 的部署/回滚状态机测试（fixture state root/shim/
# mutex seam；生产 root 永不被触碰）。覆盖：Bootstrap→Deploy 全路径、崩溃于 10/30/60/70
# 的 RecoverRollback 矩阵、complete 的两种收尾、错 owner/marker/journal 篡改拒绝、
# 终态/在途 run 的二次操作拒绝、部署者持锁时 gate 阻断负控，以及 #77 等锁超时带
# holder（fixture 项目根 + 替身 entry，经 BootstrapGate 安装的 gate shim）。

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
        ProjectRoot = $projectRoot
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
        ProjectRootForTest = $Scenario.ProjectRoot
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

# ---- #77 gate holder fixture ----
# 等锁超时场景需要真正持锁的 gate shim 进程，因此不能委托生产 entry：fixture 项目根只含
# 仓库 gate shim 源、gate-holder 库与替身 entry；经 -ProjectRootForTest 让 BootstrapGate
# 安装出委托替身 entry 的 gate shim。
$gateHolderProcesses = [Collections.Generic.List[object]]::new()

function New-GateHolderProjectRoot {
    $root = Join-Path $fixtureRoot 'gate-holder-project'
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'tests'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts\lib'))
    foreach ($relative in @(
            'scripts\invoke-codex-safe-tree-delete-gate-shim.ps1',
            'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1')) {
        [IO.File]::Copy((Join-Path $projectRoot $relative), (Join-Path $root $relative))
    }
    # 替身 entry：只记录进入并按 release 信号阻塞，不触碰任何真实状态；退出码 7 用于验证透传。
    [IO.File]::WriteAllText((Join-Path $root 'scripts\Invoke-CodexSafeTreeDelete.ps1'), @'
param([string]$Mode, [string]$TargetPath, [string]$SignalRoot, [switch]$Hold)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText((Join-Path $SignalRoot ('entered-{0}.txt' -f $PID)), [string]$Mode)
if ($Hold) {
    $deadline = [datetime]::UtcNow.AddMinutes(15)
    while (-not [IO.File]::Exists((Join-Path $SignalRoot 'release'))) {
        if ([datetime]::UtcNow -gt $deadline) { exit 9 }
        Start-Sleep -Milliseconds 100
    }
}
'STUB-ENTRY-DONE'
exit 7
'@, [Text.UTF8Encoding]::new($false))
    return $root
}

function New-GateHolderScenario {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$GateProjectRoot
    )
    $root = Join-Path $fixtureRoot $Name
    $scenario = [pscustomobject]@{
        Name = $Name
        Root = $root
        StateRoot = (Join-Path $root 'state')
        SignalRoot = (Join-Path $root 'signals')
        # 文件名刻意不含 invoke-safe-tree-delete：并发部署测试的 legacy drain 按命令行匹配它。
        ShimPath = (Join-Path $root 'gate-shim.ps1')
        ProjectRoot = $GateProjectRoot
        # 每次运行唯一，避免与并发 worktree 的固定 std-deploy-test-* 名冲突。
        MutexName = ('Local\std-deploy-test-{0}-{1}' -f $Name, [guid]::NewGuid().ToString('N'))
    }
    [void][IO.Directory]::CreateDirectory($scenario.StateRoot)
    [void][IO.Directory]::CreateDirectory($scenario.SignalRoot)
    [IO.File]::WriteAllText($scenario.ShimPath, "throw 'fixture placeholder shim'`n", [Text.UTF8Encoding]::new($false))
    return $scenario
}

function Start-FixturePwsh {
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @()
    )
    $info = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # Latin1 一字节一字符：解码后字符全 <= 0x7F 等价于原始输出字节 ASCII-only。
    $info.StandardOutputEncoding = [Text.Encoding]::Latin1
    $info.StandardErrorEncoding = [Text.Encoding]::Latin1
    foreach ($argument in (@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $File) + $Arguments)) {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    $call = [pscustomobject]@{
        Process = $process
        ProcessId = $process.Id
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
    }
    $gateHolderProcesses.Add($call)
    return $call
}

function Wait-GateShimEntered {
    param(
        [Parameter(Mandatory)][object]$Scenario,
        [Parameter(Mandatory)][object]$Call
    )
    $entered = Join-Path $Scenario.SignalRoot ('entered-{0}.txt' -f $Call.ProcessId)
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    while (-not [IO.File]::Exists($entered)) {
        if ($Call.Process.HasExited) {
            throw ('{0}: gate shim 未进入 entry 即退出（exit={1}）：{2}{3}' -f @(
                $Scenario.Name, $Call.Process.ExitCode, $Call.Stdout.Result, $Call.Stderr.Result))
        }
        if ([datetime]::UtcNow -gt $deadline) { throw "$($Scenario.Name): gate shim 90s 内未进入 entry" }
        Start-Sleep -Milliseconds 100
    }
}

function Stop-FixturePwsh {
    param([Parameter(Mandatory)][object]$Call)
    if (-not $Call.Process.HasExited) { $Call.Process.Kill($true) }
    $Call.Process.WaitForExit()
}

function Complete-FixturePwsh {
    param(
        [Parameter(Mandatory)][object]$Call,
        [int]$TimeoutSeconds = 300
    )
    if (-not $Call.Process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-FixturePwsh -Call $Call
        throw "fixture 进程 $($Call.ProcessId) 未在 ${TimeoutSeconds}s 内退出"
    }
    $Call.Process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $Call.Process.ExitCode
        Stdout = $Call.Stdout.GetAwaiter().GetResult()
        Stderr = $Call.Stderr.GetAwaiter().GetResult()
    }
}

function Get-GateTimeoutHolder {
    # 超时契约不变（exit 1、ok=false、refusalReason 原值、stdout ASCII-only），返回 holder。
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-True ($Result.ExitCode -eq 1) "${Label}: 等锁超时必须 exit 1（实际 $($Result.ExitCode)）：$($Result.Stdout)$($Result.Stderr)"
    Assert-True ($Result.Stdout -cmatch '\A[\x00-\x7F]+\z') "${Label}: 超时 stdout 必须 ASCII-only：$($Result.Stdout)"
    $json = $Result.Stdout.Trim() | ConvertFrom-Json -DateKind String
    Assert-True ($json.ok -eq $false) "${Label}: ok 必须为 false"
    Assert-True ([string]$json.refusalReason -ceq 'deployment-mutex-acquire-timeout') "${Label}: refusalReason 不得改变"
    Assert-True ($null -ne $json.PSObject.Properties['holder']) "${Label}: 超时 JSON 必须带 holder：$($Result.Stdout)"
    return $json.holder
}

function Set-GateStateDirectoryCreateFilesDenied {
    # 只对目录本身（不继承）拒绝当前用户建文件：面包屑目录不可写，读与删除不受影响。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Denied
    )
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.AccessControl.FileSystemRights]::CreateFiles,
        [Security.AccessControl.InheritanceFlags]::None,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Deny)
    $directory = [IO.DirectoryInfo]::new($Path)
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl($directory, [Security.AccessControl.AccessControlSections]::Access)
    if ($Denied) { $acl.AddAccessRule($rule) } else { [void]$acl.RemoveAccessRule($rule) }
    [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
}

$sidSuffix = (([string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -replace '[^0-9]', '')
$gateHolderRawMutex = $null
$gateHolderRawMutexOwned = $false
$gateHolderDeniedStateRoot = $null

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

    # ---- S10：#77 等锁超时报告持锁者（gate holder 面包屑）----
    $gateProject = New-GateHolderProjectRoot
    $gateLive = New-GateHolderScenario -Name 'gh-live' -GateProjectRoot $gateProject
    $gateStale = New-GateHolderScenario -Name 'gh-stale' -GateProjectRoot $gateProject
    $gateUnwritable = New-GateHolderScenario -Name 'gh-unwritable' -GateProjectRoot $gateProject

    # 部署工具持锁期间写 mode=deploy 面包屑（BootstrapGate 的 gate 证明至少持锁 4s），收尾前删除。
    Write-Output 'STEP s10-bootstrap'
    $deployObserved = Join-Path $gateLive.SignalRoot 'deploy-holder-observed.json'
    $pollerScript = Join-Path $gateLive.Root 'poll-gate-holder.ps1'
    [IO.File]::WriteAllText($pollerScript, @'
param([string]$BreadcrumbPath, [string]$OutputPath, [string]$ReadyPath, [string]$StopPath)
[IO.File]::WriteAllText($ReadyPath, '')
$deadline = [datetime]::UtcNow.AddMinutes(3)
while ([datetime]::UtcNow -lt $deadline -and -not [IO.File]::Exists($StopPath)) {
    try {
        $stream = [IO.FileStream]::new($BreadcrumbPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
        if ($text.Length -gt 0) { [IO.File]::WriteAllText($OutputPath, $text); exit 0 }
    } catch {
    }
    Start-Sleep -Milliseconds 20
}
exit 3
'@, [Text.UTF8Encoding]::new($false))
    $pollerReady = Join-Path $gateLive.SignalRoot 'poller-ready'
    $pollerStop = Join-Path $gateLive.SignalRoot 'poller-stop'
    $poller = Start-FixturePwsh -File $pollerScript -Arguments @(
        '-BreadcrumbPath', (Join-Path $gateLive.StateRoot 'gate-holder.json'),
        '-OutputPath', $deployObserved, '-ReadyPath', $pollerReady, '-StopPath', $pollerStop)
    $pollerDeadline = [datetime]::UtcNow.AddSeconds(90)
    while (-not [IO.File]::Exists($pollerReady)) {
        Assert-True (-not $poller.Process.HasExited -and [datetime]::UtcNow -lt $pollerDeadline) '面包屑观察进程未就绪'
        Start-Sleep -Milliseconds 100
    }
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'gate-holder' -Scenario $gateLive -PreviousClosureSha256 ('0' * 64) | Out-Null
    [IO.File]::WriteAllText($pollerStop, '')
    [void](Complete-FixturePwsh -Call $poller -TimeoutSeconds 60)
    Assert-True ([IO.File]::Exists($deployObserved)) '部署工具持锁期间必须写面包屑'
    $deployBreadcrumb = Get-Content -Raw -LiteralPath $deployObserved | ConvertFrom-Json -DateKind String
    Assert-True ([string]$deployBreadcrumb.mode -ceq 'deploy' -and [int]$deployBreadcrumb.pid -eq $PID) `
        "部署工具面包屑必须是 mode=deploy 且 pid 为部署进程：$(Get-Content -Raw -LiteralPath $deployObserved)"
    Assert-True (-not [IO.File]::Exists((Join-Path $gateLive.StateRoot 'gate-holder.json'))) '部署工具释放锁前必须删除面包屑'
    # 同源安装：已安装 shim 内联 gate holder lib 原文、不再 dot-source（fixture shim 旁没有 lib\）。
    $installedShimText = [IO.File]::ReadAllText($gateLive.ShimPath, [Text.UTF8Encoding]::new($false))
    $holderLibText = [IO.File]::ReadAllText((Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-True ($installedShimText.Contains($holderLibText.TrimEnd()) -and
        -not $installedShimText.Contains("'lib\CodexSafeTreeDeleteGateHolder.ps1'")) '安装的 gate shim 必须内联同源 gate holder lib 且不再 dot-source'
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'gate-holder' -Scenario $gateStale -PreviousClosureSha256 ('0' * 64) | Out-Null
    Invoke-DeployTool -Mode BootstrapGate -DeploymentId 'gate-holder' -Scenario $gateUnwritable -PreviousClosureSha256 ('0' * 64) | Out-Null

    # 存活持锁者：面包屑只含四个字段，mode 来自 -Mode，不记录其它参数值。
    Write-Output 'STEP s10-holders'
    $secretTarget = Join-Path $gateLive.Root ('target-' + [guid]::NewGuid().ToString('N'))
    $liveHolder = Start-FixturePwsh -File $gateLive.ShimPath -Arguments @(
        '-Mode', 'Purge', '-TargetPath', $secretTarget, '-SignalRoot', $gateLive.SignalRoot, '-Hold')
    Wait-GateShimEntered -Scenario $gateLive -Call $liveHolder
    $liveBreadcrumbPath = Join-Path $gateLive.StateRoot 'gate-holder.json'
    $liveBreadcrumbText = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($liveBreadcrumbPath))
    Assert-True ($liveBreadcrumbText -cmatch '\A[\x20-\x7E]+\z') "面包屑必须 ASCII-only：$liveBreadcrumbText"
    $liveBreadcrumb = $liveBreadcrumbText | ConvertFrom-Json -DateKind String
    Assert-True ((@($liveBreadcrumb.PSObject.Properties.Name) -join ',') -ceq 'pid,processStartUtc,mode,acquiredAtUtc') `
        "面包屑字段必须恰为 pid/processStartUtc/mode/acquiredAtUtc：$liveBreadcrumbText"
    Assert-True ([int]$liveBreadcrumb.pid -eq $liveHolder.ProcessId -and [string]$liveBreadcrumb.mode -ceq 'Purge') `
        "面包屑必须记录持锁 shim 的 pid 与 -Mode：$liveBreadcrumbText"
    Assert-True (-not $liveBreadcrumbText.Contains([IO.Path]::GetFileName($secretTarget))) '面包屑不得记录目标路径'

    # 持锁者被杀：mutex abandoned，下一个获得者覆盖残留；再杀它后由不写面包屑的测试进程接管，
    # 超时方读到的面包屑指向已死进程。
    $killedHolder = Start-FixturePwsh -File $gateStale.ShimPath -Arguments @('-Mode', 'Apply', '-SignalRoot', $gateStale.SignalRoot, '-Hold')
    Wait-GateShimEntered -Scenario $gateStale -Call $killedHolder
    Stop-FixturePwsh -Call $killedHolder
    $successorHolder = Start-FixturePwsh -File $gateStale.ShimPath -Arguments @('-Mode', 'Restore', '-SignalRoot', $gateStale.SignalRoot, '-Hold')
    Wait-GateShimEntered -Scenario $gateStale -Call $successorHolder
    $successorBreadcrumb = Get-Content -Raw -LiteralPath (Join-Path $gateStale.StateRoot 'gate-holder.json') | ConvertFrom-Json -DateKind String
    Assert-True ([int]$successorBreadcrumb.pid -eq $successorHolder.ProcessId -and [string]$successorBreadcrumb.mode -ceq 'Restore') `
        'abandoned 后的下一个获得者必须覆盖面包屑'
    Stop-FixturePwsh -Call $successorHolder
    $gateHolderRawMutex = [System.Threading.Mutex]::new($false, ('{0}-u-{1}' -f $gateStale.MutexName, $sidSuffix))
    try {
        $gateHolderRawMutexOwned = $gateHolderRawMutex.WaitOne([TimeSpan]::FromSeconds(30))
    } catch [System.Threading.AbandonedMutexException] {
        $gateHolderRawMutexOwned = $true
    }
    Assert-True $gateHolderRawMutexOwned '测试进程必须接管 abandoned gate mutex'

    # 面包屑目录不可写：持锁调用照常进入 entry，目录里不留面包屑或临时文件。
    Set-GateStateDirectoryCreateFilesDenied -Path $gateUnwritable.StateRoot -Denied $true
    $gateHolderDeniedStateRoot = $gateUnwritable.StateRoot
    [void](Assert-Throws -Message 'fixture 前提：面包屑目录必须不可写' -Action {
        [IO.File]::WriteAllText((Join-Path $gateUnwritable.StateRoot 'write-probe.txt'), 'x')
    })
    $unwritableHolder = Start-FixturePwsh -File $gateUnwritable.ShimPath -Arguments @('-Mode', 'Plan', '-SignalRoot', $gateUnwritable.SignalRoot, '-Hold')
    Wait-GateShimEntered -Scenario $gateUnwritable -Call $unwritableHolder
    Assert-True (@([IO.Directory]::GetFiles($gateUnwritable.StateRoot)).Count -eq 0) '不可写目录下不得留下面包屑或临时文件'

    # 三路 shim 等待者（2 分钟超时）与进程内部署工具（5 分钟超时）并行等锁。
    Write-Output 'STEP s10-waiters'
    $liveWaiter = Start-FixturePwsh -File $gateLive.ShimPath -Arguments @('-Mode', 'Status', '-SignalRoot', $gateLive.SignalRoot)
    $staleWaiter = Start-FixturePwsh -File $gateStale.ShimPath -Arguments @('-Mode', 'Status', '-SignalRoot', $gateStale.SignalRoot)
    $unknownWaiter = Start-FixturePwsh -File $gateUnwritable.ShimPath -Arguments @('-Mode', 'Status', '-SignalRoot', $gateUnwritable.SignalRoot)
    $deployTimeout = Assert-Throws -Message '外部持锁时部署工具必须等锁超时' -Action {
        Invoke-DeployTool -Mode Deploy -DeploymentId 'gate-holder-wait' -Scenario $gateLive | Out-Null
    }
    Assert-True ($deployTimeout.StartsWith('deployment mutex acquire timeout', [StringComparison]::Ordinal)) `
        "部署工具超时消息前缀不得改变：$deployTimeout"
    Assert-True ($deployTimeout -cmatch 'holder=(\{[\x20-\x7E]+\})\z') "部署工具超时消息必须带 holder JSON：$deployTimeout"
    $deployHolder = $Matches[1] | ConvertFrom-Json -DateKind String
    Assert-True ([int]$deployHolder.pid -eq $liveHolder.ProcessId -and [string]$deployHolder.mode -ceq 'Purge' -and
        $deployHolder.stale -eq $false) "部署工具超时 holder 必须指向存活持锁 shim：$deployTimeout"

    $liveTimeoutHolder = Get-GateTimeoutHolder -Result (Complete-FixturePwsh -Call $liveWaiter) -Label 'gh-live'
    Assert-True ((@($liveTimeoutHolder.PSObject.Properties.Name) -join ',') -ceq 'pid,mode,acquiredAtUtc,heldSeconds,stale') `
        'holder 字段必须为 pid/mode/acquiredAtUtc/heldSeconds/stale'
    Assert-True ([int]$liveTimeoutHolder.pid -eq $liveHolder.ProcessId -and [string]$liveTimeoutHolder.mode -ceq 'Purge') `
        'holder 必须指向持锁 shim 及其 -Mode'
    Assert-True ([string]$liveTimeoutHolder.acquiredAtUtc -ceq [string]$liveBreadcrumb.acquiredAtUtc) 'holder.acquiredAtUtc 必须来自面包屑'
    Assert-True ([long]$liveTimeoutHolder.heldSeconds -ge 110) "heldSeconds 必须反映持锁时长：$($liveTimeoutHolder.heldSeconds)"
    Assert-True ($liveTimeoutHolder.stale -eq $false) '存活持锁者 stale 必须为 false'

    $staleTimeoutHolder = Get-GateTimeoutHolder -Result (Complete-FixturePwsh -Call $staleWaiter) -Label 'gh-stale'
    Assert-True ([int]$staleTimeoutHolder.pid -eq $successorHolder.ProcessId -and $staleTimeoutHolder.stale -eq $true) `
        '持锁者被杀后 holder.stale 必须为 true'

    $unknownTimeoutHolder = Get-GateTimeoutHolder -Result (Complete-FixturePwsh -Call $unknownWaiter) -Label 'gh-unwritable'
    Assert-True ((@($unknownTimeoutHolder.PSObject.Properties.Name) -join ',') -ceq 'state' -and
        [string]$unknownTimeoutHolder.state -ceq 'unknown') '读不到面包屑时 holder 必须为 {state:unknown}'

    # 收尾：不可写目录下的调用照常完成（entry 输出与退出码透传）；存活持锁者释放前删面包屑。
    [IO.File]::WriteAllText((Join-Path $gateUnwritable.SignalRoot 'release'), '')
    $unwritableResult = Complete-FixturePwsh -Call $unwritableHolder -TimeoutSeconds 90
    Assert-True ($unwritableResult.ExitCode -eq 7 -and $unwritableResult.Stdout -cmatch 'STUB-ENTRY-DONE') `
        "面包屑写失败不得阻塞调用：exit=$($unwritableResult.ExitCode) $($unwritableResult.Stdout)$($unwritableResult.Stderr)"
    [void]$gateHolderRawMutex.ReleaseMutex()
    $gateHolderRawMutexOwned = $false
    [IO.File]::WriteAllText((Join-Path $gateLive.SignalRoot 'release'), '')
    $liveResult = Complete-FixturePwsh -Call $liveHolder -TimeoutSeconds 90
    Assert-True ($liveResult.ExitCode -eq 7) "持锁 shim 必须透传 entry 退出码：$($liveResult.ExitCode)"
    Assert-True (-not [IO.File]::Exists($liveBreadcrumbPath)) '持锁 shim 释放锁前必须删除面包屑'
    Write-Output 'S10 gate-holder OK'

    Write-Output 'DEPLOYMENT-TESTS OK'
} finally {
    foreach ($call in $gateHolderProcesses) {
        try { Stop-FixturePwsh -Call $call } catch { }
    }
    if ($gateHolderRawMutexOwned) {
        try { [void]$gateHolderRawMutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $gateHolderRawMutex) { $gateHolderRawMutex.Dispose() }
    if ($null -ne $gateHolderDeniedStateRoot) {
        try { Set-GateStateDirectoryCreateFilesDenied -Path $gateHolderDeniedStateRoot -Denied $false } catch { }
    }
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
