[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('BootstrapGate', 'Deploy', 'RecoverRollback')][string]$Mode,
    [Parameter(Mandatory)][string]$DeploymentId,
    [Parameter()][string]$PreviousClosureSha256,
    # 测试专用 seam（capability spec 记录；生产调用不得传递）：
    [string]$StateRootForTest,
    [string]$ShimPathForTest,
    [string]$ProjectRootForTest,
    [string]$MutexNameForTest,
    [int]$StopAfterPhaseForTest = 0,
    # #93：等锁时长测试覆盖。只在上述测试 seam 生效时可用；缺省保持生产默认
    # （部署工具 5 分钟、安装的 gate shim 2 分钟）。
    [ValidateRange(0, [int]::MaxValue)][int]$GateWaitSecondsForTest = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$InstalledShimGateWaitSecondsForTest = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 §9：safe-tree-delete 部署唯一 owner。只接受 BootstrapGate | Deploy | RecoverRollback，
# 不复用业务 Mode，不 commit/push。状态根固定（生产）：<root>/deployments/<id>/{00-intent.json,
# shim-backup.bin,phase-journal/,invocations/}、<root>/maintenance.json。
# marker 唯一 schema：{schemaVersion,deploymentId,runPath,intentSha256}；状态从已认证
# intent 与 create-only、前序 SHA 链接的 phase journals 推导。手工删 marker、raw cache/source
# 替换或另写临时恢复命令均不构成恢复。
#
# 边界声明：仓库工作树内容不属于本工具可写面（host 经 shim 委托 repo）。source switch =
# 校验 live closure 等于 intent.targetClosureSha256；回滚到 previous closure 由版本控制
# 完成，RecoverRollback 只做"已就位"认证，不回退 repo 字节。shim 与 marker 的字节操作
# 全部由本工具持有 deployment mutex 时执行。

$productionStateRoot = 'D:\Codex\.codex\state\safe-tree-delete-deployment'
$productionShimPath = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'
$productionProjectRoot = 'D:\agents\projects\统一环境'
$productionMutexName = 'Global\CodexSafeTreeDeleteDeployment'

$testSeamActive = -not [string]::IsNullOrWhiteSpace($StateRootForTest) -or
    -not [string]::IsNullOrWhiteSpace($ShimPathForTest) -or
    -not [string]::IsNullOrWhiteSpace($ProjectRootForTest) -or
    -not [string]::IsNullOrWhiteSpace($MutexNameForTest)

# #93：等锁覆盖只在测试 seam 生效时可用；生产调用路径（不带测试 seam）传它们直接拒绝，
# 且拒绝发生在任何 I/O（状态根创建、取锁）之前。
if (-not $testSeamActive -and ($GateWaitSecondsForTest -ne 0 -or $InstalledShimGateWaitSecondsForTest -ne 0)) {
    throw 'GateWaitSecondsForTest 与 InstalledShimGateWaitSecondsForTest 只在测试 seam 生效时可用。'
}

$stateRoot = if (-not [string]::IsNullOrWhiteSpace($StateRootForTest)) { $StateRootForTest } else { $productionStateRoot }
$shimPath = if (-not [string]::IsNullOrWhiteSpace($ShimPathForTest)) { $ShimPathForTest } else { $productionShimPath }
$projectRoot = if (-not [string]::IsNullOrWhiteSpace($ProjectRootForTest)) { $ProjectRootForTest } else { $productionProjectRoot }
$mutexName = if (-not [string]::IsNullOrWhiteSpace($MutexNameForTest)) { $MutexNameForTest } else { $productionMutexName }

function Get-DeploymentPhaseName {
    # 显式 switch 查找：OrderedDictionary 的整数下标在 PS 里会被解释为序号位置而非键，
    # 会产生越界（#56 §9 实测）。
    param([Parameter(Mandatory)][int]$Sequence)

    switch ($Sequence) {
        10 { return 'gate-bootstrap-started' }
        20 { return 'shim-cutover' }
        30 { return 'marker-active' }
        40 { return 'legacy-drained' }
        50 { return 'source-switch-started' }
        60 { return 'source-switched' }
        70 { return 'validation-passed' }
        80 { return 'complete' }
        default { throw "未知 phase 序号：$Sequence" }
    }
}

if ($DeploymentId -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
    throw "deploymentId 非法：$DeploymentId"
}

. (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDeleteClosure.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDeleteGateHolder.ps1')

$deploymentsRoot = Join-Path $stateRoot 'deployments'
$runPath = Join-Path $deploymentsRoot $DeploymentId
$intentPath = Join-Path $runPath '00-intent.json'
$shimBackupPath = Join-Path $runPath 'shim-backup.bin'
$journalRoot = Join-Path $runPath 'phase-journal'
$invocationsRoot = Join-Path $runPath 'invocations'
$finalReceiptPath = Join-Path $runPath 'final-receipt.json'
$markerPath = Join-Path $stateRoot 'maintenance.json'

function Get-FileSha256HexText {
    param([Parameter(Mandatory)][string]$Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function Write-CreateOnlyJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document
    )
    if ([IO.File]::Exists($Path)) {
        throw "create-only 文件已存在，拒绝覆盖：$Path"
    }
    [IO.File]::WriteAllText(
        $Path,
        ($Document | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 16)
}

function Get-JournalEntries {
    if (-not [IO.Directory]::Exists($journalRoot)) { return @() }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($file in ([IO.Directory]::GetFiles($journalRoot, '*.json') | Sort-Object)) {
        $entry = Read-JsonFile -Path $file
        $entry | Add-Member -NotePropertyName fileName -NotePropertyValue ([IO.Path]::GetFileName($file))
        $rows.Add($entry)
    }
    return @($rows)
}

function Test-JournalChainValid {
    param([Parameter(Mandatory)][object]$Entries)

    $previousSha = ''
    $previousSequence = 0
    foreach ($entry in $Entries) {
        if ([int]$entry.sequence -le $previousSequence) {
            return $false
        }
        if ([string]$entry.previousJournalSha256 -cne $previousSha) {
            return $false
        }
        $previousSequence = [int]$entry.sequence
        $previousSha = [string]$entry.entrySha256
    }
    return $true
}

function Write-PhaseJournal {
    param(
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][string]$Phase
    )
    [void][IO.Directory]::CreateDirectory($journalRoot)
    $entries = @(Get-JournalEntries)
    if (-not (Test-JournalChainValid -Entries $entries)) {
        throw 'phase journal 链校验失败，拒绝追加。'
    }
    if ($entries.Count -gt 0 -and [int]$entries[-1].sequence -ge $Sequence) {
        throw "phase journal 乱序或重复：last=$($entries[-1].sequence) new=$Sequence"
    }
    $previousSha = $(if ($entries.Count -gt 0) { [string]$entries[-1].entrySha256 } else { '' })
    $fileName = '{0:D2}-{1}.json' -f $Sequence, $Phase
    $path = Join-Path $journalRoot $fileName
    $entry = [pscustomobject][ordered]@{
        schemaVersion = 1
        sequence = $Sequence
        phase = $Phase
        utc = [datetimeoffset]::UtcNow.ToString('o')
        previousJournalSha256 = $previousSha
    }
    $entrySha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes(($entry | ConvertTo-Json -Depth 8 -Compress)))).ToLowerInvariant()
    $entry | Add-Member -NotePropertyName entrySha256 -NotePropertyValue $entrySha
    Write-CreateOnlyJson -Path $path -Document $entry
    return $entry
}

function Get-CertifiedState {
    # 返回 {intent, entries, lastSequence, lastPhase, terminal, markerPresent, marker}
    $intent = $null
    if ([IO.File]::Exists($intentPath)) { $intent = Read-JsonFile -Path $intentPath }
    $entries = @(Get-JournalEntries)
    if ($entries.Count -gt 0 -and -not (Test-JournalChainValid -Entries $entries)) {
        throw 'phase journal 链校验失败。'
    }
    $lastSequence = $(if ($entries.Count -gt 0) { [int]$entries[-1].sequence } else { 0 })
    $lastPhase = $(if ($entries.Count -gt 0) { [string]$entries[-1].phase } else { '' })
    $terminal = ($lastPhase -ceq 'complete') -or ($lastPhase -like '*-rollback-complete')
    $markerPresent = [IO.File]::Exists($markerPath)
    $marker = $null
    if ($markerPresent) { $marker = Read-JsonFile -Path $markerPath }
    return [pscustomobject]@{
        intent = $intent
        entries = $entries
        lastSequence = $lastSequence
        lastPhase = $lastPhase
        terminal = $terminal
        markerPresent = $markerPresent
        marker = $marker
        finalReceiptPresent = [IO.File]::Exists($finalReceiptPath)
    }
}

function Assert-DeploymentIdentity {
    param([Parameter(Mandatory)][object]$State)

    if ($null -eq $State.intent) {
        throw "deployment run 不存在：$runPath"
    }
    $currentSid = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ([string]$State.intent.ownerSid -cne $currentSid) {
        throw 'deployment intent owner SID 与当前用户不一致，拒绝。'
    }
    $intentSha = Get-FileSha256HexText -Path $intentPath
    if ($State.markerPresent) {
        $marker = $State.marker
        if ([string]$marker.schemaVersion -cne '1' -or
            [string]$marker.deploymentId -cne $DeploymentId -or
            -not [string]$marker.runPath -ceq $runPath -or
            [string]$marker.intentSha256 -cne $intentSha) {
            throw 'maintenance marker 四字段与当前 run 不匹配，拒绝。'
        }
    }
}

function Get-GateShimContent {
    # 安装内容 = 仓库 gate shim，其中唯一一行 gate holder lib dot-source 替换为同一 project
    # root 下该 lib 的原文（#77：已安装 shim 自包含，取锁前不加载任何仓库代码；面包屑的写、
    # 读与 stale 判定仍只有 scripts\lib\CodexSafeTreeDeleteGateHolder.ps1 一份源码）。生产
    # 安装除此内联外不做其它改写；测试 seam 再把 shim 的生产常量重写为测试值。
    $utf8 = [Text.UTF8Encoding]::new($false)
    $shimSource = Join-Path $projectRoot 'scripts\invoke-codex-safe-tree-delete-gate-shim.ps1'
    $holderLibSource = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1'
    $content = [IO.File]::ReadAllText($shimSource, $utf8)
    $holderInclude = ". (Join-Path `$PSScriptRoot 'lib\CodexSafeTreeDeleteGateHolder.ps1')"
    $includeCount = [regex]::Matches($content, [regex]::Escape($holderInclude)).Count
    if ($includeCount -ne 1) {
        throw "gate shim 必须恰好含一行 gate holder lib dot-source（实际 $includeCount 处），拒绝安装。"
    }
    $content = $content.Replace($holderInclude, (
        "# >>> inlined: scripts/lib/CodexSafeTreeDeleteGateHolder.ps1`n" +
        [IO.File]::ReadAllText($holderLibSource, $utf8).TrimEnd() +
        "`n# <<< inlined: scripts/lib/CodexSafeTreeDeleteGateHolder.ps1"))
    if (-not $testSeamActive) {
        return $utf8.GetBytes($content)
    }
    $content = $content.Replace(
        "'D:\Codex\.codex\state\safe-tree-delete-deployment'",
        ('''' + $stateRoot + ''''))
    $content = $content.Replace(
        "'D:\agents\projects\统一环境\scripts\Invoke-CodexSafeTreeDelete.ps1'",
        ('''' + (Join-Path $projectRoot 'scripts\Invoke-CodexSafeTreeDelete.ps1') + ''''))
    $content = $content.Replace(
        "'Global\CodexSafeTreeDeleteDeployment'",
        ('''' + $mutexName + ''''))
    if ($InstalledShimGateWaitSecondsForTest -gt 0) {
        # #93：测试 seam 安装时把 shim 的生产等锁上限重写为测试秒数；字面量必须恰好一处，
        # 否则说明 shim 源漂移，失败闭锁而不是静默跳过。
        $productionShimWait = '[TimeSpan]::FromMinutes(2)'
        $waitLiteralCount = [regex]::Matches($content, [regex]::Escape($productionShimWait)).Count
        if ($waitLiteralCount -ne 1) {
            throw "gate shim 必须恰好含一处生产等锁时长字面量（实际 $waitLiteralCount 处），拒绝安装。"
        }
        $content = $content.Replace($productionShimWait, ('[TimeSpan]::FromSeconds({0})' -f $InstalledShimGateWaitSecondsForTest))
    }
    return [Text.UTF8Encoding]::new($false).GetBytes($content)}

function Invoke-ShimCutover {
    if (-not [IO.File]::Exists($shimPath)) {
        throw "宿主 shim 不存在：$shimPath"
    }
    Write-CreateOnlyJson -Path ($shimBackupPath + '.meta.json') -Document ([pscustomobject][ordered]@{
        shimBeforeSha256 = (Get-FileSha256HexText -Path $shimPath)
        length = [long]([IO.File]::ReadAllBytes($shimPath)).Length
    })
    if (-not [IO.File]::Exists($shimBackupPath)) {
        [IO.File]::WriteAllBytes($shimBackupPath, [IO.File]::ReadAllBytes($shimPath))
    }
    $newShimBytes = Get-GateShimContent
    $tempPath = "$shimPath.tmp"
    [IO.File]::WriteAllBytes($tempPath, $newShimBytes)
    # 单文件原子替换（同目录 rename）；rename 前后校验旧/新 SHA。
    $beforeSha = Get-FileSha256HexText -Path $shimPath
    [IO.File]::Move($tempPath, $shimPath + '.new')
    [void][IO.File]::Replace(($shimPath + '.new'), $shimPath, ($shimPath + '.replace-backup'))
    if ([IO.File]::Exists($shimPath + '.replace-backup')) { [void][IO.File]::Delete($shimPath + '.replace-backup') }
    $afterSha = Get-FileSha256HexText -Path $shimPath
    return [pscustomobject]@{
        shimBeforeSha256 = $beforeSha
        shimAfterSha256 = $afterSha
    }
}

function Restore-ShimFromBackup {
    if (-not [IO.File]::Exists($shimBackupPath)) {
        throw "shim backup 缺失，无法回滚：$shimBackupPath"
    }
    $tempPath = "$shimPath.restore"
    [IO.File]::WriteAllBytes($tempPath, [IO.File]::ReadAllBytes($shimBackupPath))
    [void][IO.File]::Replace($tempPath, $shimPath, ($shimPath + '.replace-backup'))
    if ([IO.File]::Exists($shimPath + '.replace-backup')) { [void][IO.File]::Delete($shimPath + '.replace-backup') }
    return (Get-FileSha256HexText -Path $shimPath)
}

function Invoke-GateProof {
    # 部署者持锁期间，经新 shim 的调用必须等待/拒绝（plan §9 shim 生效证明）。
    $proof = Join-Path $runPath ('gate-proof-' + [IO.Path]::GetRandomFileName() + '.ps1')
    [IO.File]::WriteAllText($proof, @'
param()
$mutex = [System.Threading.Mutex]::new($false, 'MUTEX_NAME_PLACEHOLDER')
if ($mutex.WaitOne([TimeSpan]::FromMinutes(2))) {
    'GATE-BYPASSED'
    $mutex.ReleaseMutex()
} else {
    'GATE-WAITED'
}
'@.Replace('MUTEX_NAME_PLACEHOLDER', (Get-DeploymentMutexName -BaseName $mutexName)), [Text.UTF8Encoding]::new($false))
    try {
        $process = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $proof) `
            -PassThru -WindowStyle Hidden
        if ($process.WaitForExit(4000) -and $process.ExitCode -eq 0) {
            # 快速退出说明 gate 没拦住——但需看输出；保守：以未超时退出即失败。
            throw 'gate 生效证明失败：部署者持锁期间子调用未等待。'
        }
        if (-not $process.HasExited) {
            [void]$process.Kill()
            return $true
        }
        throw 'gate 生效证明失败：子调用异常退出。'
    } finally {
        if ([IO.File]::Exists($proof)) { [void][IO.File]::Delete($proof) }
    }
}

function Get-LegacyInventory {
    # 按 executable+PID+starttime+commandline 枚举可能经旧 wrapper/repo entry 启动的
    # safe-delete/native-compile 进程；command line 不可读即失败闭锁。当前进程及其
    # 祖先链（部署工具/测试宿主）不属"旧版调用"，排除。
    # #93：测试 seam 生效时只计命令行同时含本次 state root 的进程（fixture 部署不被
    # 其他会话的受管调用阻塞）；生产不带测试 seam，仍全机枚举，行为不变。
    $all = @(Get-CimInstance Win32_Process)
    $byId = @{}
    foreach ($process in $all) { $byId[[int]$process.ProcessId] = $process }
    $excluded = [Collections.Generic.HashSet[int]]::new()
    $cursor = [int]$PID
    while ($byId.ContainsKey($cursor)) {
        [void]$excluded.Add($cursor)
        $cursor = [int]$byId[$cursor].ParentProcessId
        if ($cursor -le 4) { break }
    }
    $rows = @()
    foreach ($process in $all) {
        if ($excluded.Contains([int]$process.ProcessId)) { continue }
        # 只认"经宿主 wrapper/repo entry 的调用"：可执行为 shell 且命令行含入口脚本名。
        # agent/编辑器等仅引用字符串的进程不计入；native 编译是调用的瞬态子进程，
        # 由入口标记覆盖。
        if ([string]$process.Name -cnotin @('pwsh.exe', 'powershell.exe', 'cmd.exe')) { continue }
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { continue }
        if ($commandLine -cmatch 'invoke-safe-tree-delete' -or
            $commandLine -cmatch 'Invoke-CodexSafeTreeDelete') {
            if ($testSeamActive -and
                $commandLine.IndexOf([string]$stateRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }
            $rows += [pscustomobject]@{
                executable = [string]$process.ExecutablePath
                processId = [int]$process.ProcessId
                commandLine = $commandLine
            }
        }
    }
    return @($rows)
}

function Write-InvocationReceipt {
    [void][IO.Directory]::CreateDirectory($invocationsRoot)
    $sequence = 1
    foreach ($existing in ([IO.Directory]::GetFiles($invocationsRoot, '*.json') | Sort-Object)) {
        $sequence = [Math]::Max($sequence, ([int]([IO.Path]::GetFileName($existing).Split('-')[0])) + 1)
    }
    $receiptPath = Join-Path $invocationsRoot ('{0:D4}-{1}-{2}.json' -f @(
        $sequence, $Mode, [guid]::NewGuid().ToString('N')))
    Write-CreateOnlyJson -Path $receiptPath -Document ([pscustomobject][ordered]@{
        mode = $Mode
        deploymentId = $DeploymentId
        utc = [datetimeoffset]::UtcNow.ToString('o')
        argv = @($PSBoundParameters.Keys | Sort-Object | ForEach-Object {
            '{0}={1}' -f $_, [string]$PSBoundParameters[$_]
        })
    })
}

function Get-DeploymentMutexName {
    # current-user cross-session 语义：mutex 名内嵌 owner SID 命名空间，不同用户
    # 得到不同 mutex，天然互不干扰（PS7 下 System.Threading.AccessControl 的类型
    # 解析不可用，无法走 MutexAcl 显式 ACL；此处以 SID 命名空间实现同等隔离语义）。
    param([Parameter(Mandatory)][string]$BaseName)

    $sid = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return ('{0}-u-{1}' -f $BaseName, ($sid -replace '[^0-9]', ''))
}

function Open-DeploymentMutex {
    param([Parameter(Mandatory)][string]$Name)

    return [System.Threading.Mutex]::new($false, $Name)
}

function Stop-IfRequested {
    param([Parameter(Mandatory)][int]$Sequence)
    if ($StopAfterPhaseForTest -gt 0 -and $Sequence -ge $StopAfterPhaseForTest) {
        Write-Output ("STOPPED-AFTER-PHASE {0}" -f $Sequence)
        exit 0
    }
}

# ---------------- main ----------------
[void][IO.Directory]::CreateDirectory($stateRoot)
# #93：等锁上限默认 5 分钟（生产不变）；GateWaitSecondsForTest 只在测试 seam 生效时可用。
$gateWaitTimeout = if ($GateWaitSecondsForTest -gt 0) {
    [TimeSpan]::FromSeconds($GateWaitSecondsForTest)
} else {
    [TimeSpan]::FromMinutes(5)
}
$mutex = Open-DeploymentMutex -Name (Get-DeploymentMutexName -BaseName $mutexName)
if (-not $mutex.WaitOne($gateWaitTimeout)) {
    # #77：超时消息前缀不变，追加持锁者（ASCII JSON；读不到时为 {"state":"unknown"}）。
    throw ('deployment mutex acquire timeout。holder={0}' -f (
        (Read-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot) |
            ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii))
}
try {
    # #77：持锁期间留 mode=deploy 面包屑；写失败是有意降级，不阻塞部署。
    [void](Write-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot -Mode 'deploy')
    Write-InvocationReceipt
    $state = Get-CertifiedState

    switch ($Mode) {
        'BootstrapGate' {
            if ($state.finalReceiptPresent) {
                throw "deployment 已 terminal，拒绝再次 BootstrapGate：$DeploymentId"
            }
            if ($null -ne $state.intent) {
                throw "deployment run 已存在；先 RecoverRollback 旧 run：$DeploymentId"
            }
            if ($state.markerPresent) {
                throw 'maintenance marker 在场（另一活动部署），拒绝 BootstrapGate。'
            }
            foreach ($other in ([IO.Directory]::GetDirectories($deploymentsRoot) | Sort-Object)) {
                $otherFinal = Join-Path $other 'final-receipt.json'
                $otherIntent = Join-Path $other '00-intent.json'
                if ([IO.File]::Exists($otherIntent) -and -not [IO.File]::Exists($otherFinal)) {
                    throw ("存在未收尾 deployment（{0}），先 RecoverRollback。" -f [IO.Path]::GetFileName($other))
                }
            }
            if ([string]::IsNullOrWhiteSpace($PreviousClosureSha256)) {
                throw 'BootstrapGate 需要 -PreviousClosureSha256（部署前现场 closure 证据）。'
            }
            $closure = Get-CodexSafeTreeDeleteClosure -ProjectRoot $projectRoot
            $targetShimSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                (Get-GateShimContent))).ToLowerInvariant()
            [void][IO.Directory]::CreateDirectory($runPath)
            Write-CreateOnlyJson -Path $intentPath -Document ([pscustomobject][ordered]@{
                schemaVersion = 1
                deploymentId = $DeploymentId
                ownerSid = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                createdAtUtc = [datetimeoffset]::UtcNow.ToString('o')
                previousClosureSha256 = ([string]$PreviousClosureSha256).ToLowerInvariant()
                targetClosureSha256 = [string]$closure.closureSha256
                shimBeforeSha256 = (Get-FileSha256HexText -Path $shimPath)
                shimTargetSha256 = $targetShimSha
            })
            [void](Write-PhaseJournal -Sequence 10 -Phase 'gate-bootstrap-started')
            Stop-IfRequested -Sequence 10

            $cutover = Invoke-ShimCutover
            if ([string]$cutover.shimAfterSha256 -cne $targetShimSha) {
                throw 'shim cutover 后 SHA 与 intent 不一致。'
            }
            [void](Write-PhaseJournal -Sequence 20 -Phase 'shim-cutover')
            if (Invoke-GateProof) {
                Write-Output 'GATE-PROOF OK（部署者持锁期间新调用被 gate 等待）'
            }
            Stop-IfRequested -Sequence 20
            Write-Output ("BOOTSTRAP-GATE OK deploymentId={0} targetClosure={1}" -f $DeploymentId, $closure.closureSha256)
        }
        'Deploy' {
            Assert-DeploymentIdentity -State $state
            if ($null -eq $state.intent) { throw 'Deploy 需要 BootstrapGate 先行。' }
            if ($state.terminal) { throw 'deployment 已 terminal，拒绝 Deploy。' }
            if ($state.lastSequence -lt 20) { throw 'Deploy 需要 phase 20 已认证。' }
            if ($state.lastSequence -ge 30 -and -not $state.markerPresent) {
                throw 'phase>=30 但 marker 缺失，拒绝继续（走 RecoverRollback）。'
            }
            if ($state.lastSequence -lt 30) {
                if ($state.markerPresent) { throw 'phase<30 但 marker 在场，状态矛盾。' }
                Write-CreateOnlyJson -Path $markerPath -Document ([pscustomobject][ordered]@{
                    schemaVersion = '1'
                    deploymentId = $DeploymentId
                    runPath = $runPath
                    intentSha256 = (Get-FileSha256HexText -Path $intentPath)
                })
                [void](Write-PhaseJournal -Sequence 30 -Phase 'marker-active')
            }
            Stop-IfRequested -Sequence 30

            if ($state.lastSequence -lt 40) {
                $stableZero = 0
                $lastInventory = @()
                for ($round = 0; $round -lt 120; $round++) {
                    $inventory = @(Get-LegacyInventory)
                    $lastInventory = $inventory
                    if ($inventory.Count -eq 0) {
                        $stableZero++
                        if ($stableZero -ge 2) { break }
                    } else {
                        $stableZero = 0
                    }
                    Start-Sleep -Seconds 5
                }
                if ($stableZero -lt 2) {
                    $detail = (@($lastInventory) | ForEach-Object {
                        '[{0}] {1}' -f [int]$_.processId, [string]$_.commandLine
                    }) -join "`n"
                    throw ("legacy drain 未收敛（仍存在旧版 safe-tree 进程）。inventory:`n{0}" -f $detail)
                }
                [void](Write-PhaseJournal -Sequence 40 -Phase 'legacy-drained')
                $state = Get-CertifiedState
            }
            Stop-IfRequested -Sequence 40

            if ($state.lastSequence -lt 50) {
                [void](Write-PhaseJournal -Sequence 50 -Phase 'source-switch-started')
                $state = Get-CertifiedState
            }
            Stop-IfRequested -Sequence 50

            if ($state.lastSequence -lt 60) {
                $closure = Get-CodexSafeTreeDeleteClosure -ProjectRoot $projectRoot
                if ([string]$closure.closureSha256 -cne [string]$state.intent.targetClosureSha256) {
                    throw 'source switch 失败：live closure 与 intent.targetClosureSha256 不一致。'
                }
                [void](Write-PhaseJournal -Sequence 60 -Phase 'source-switched')
                $state = Get-CertifiedState
            }
            Stop-IfRequested -Sequence 60

            if ($state.lastSequence -lt 70) {
                # validation：native default variant 可加载 + 小树 Plan 走新 walker 成功。
                $validationScript = Join-Path $runPath ('validation-' + [IO.Path]::GetRandomFileName() + '.ps1')
                [IO.File]::WriteAllText($validationScript, @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = 'PROJECT_ROOT_PLACEHOLDER'
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$root = Join-Path 'D:\Codex\temp' ('std-validation-' + [guid]::NewGuid().ToString('N'))
$cap = Join-Path $root 'cap'; $ev = Join-Path $cap 'evidence'
[void][IO.Directory]::CreateDirectory((Join-Path $cap 'tree'))
[void][IO.Directory]::CreateDirectory($ev)
[IO.File]::WriteAllText((Join-Path $cap 'tree\f.txt'), 'v', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $cap 'policy.json'), (@{
    artifactType='env-governance.codex-safe-tree-delete-policy';schemaVersion=3;entries=@(@{
        id='deploy-validation';capabilityRoot=$cap;minimumDescendantDepth=1;rootDeletionPurpose='none';deniedExactPaths=@($ev)})
} | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$plan = New-CodexSafeTreeDeletePlan -TargetPath (Join-Path $cap 'tree') -CapabilityRoot $cap -PolicyPath (Join-Path $cap 'policy.json') -EvidenceRoot $ev
if ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -cne 'csharp') { throw 'validation: 默认必须 csharp walker' }
Remove-Item -LiteralPath $root -Recurse -Force
'@.Replace('PROJECT_ROOT_PLACEHOLDER', $projectRoot), [Text.UTF8Encoding]::new($false))
                try {
                    $process = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $validationScript) -PassThru -WindowStyle Hidden -Wait
                    if ($process.ExitCode -ne 0) { throw "validation 子进程失败（exit=$($process.ExitCode)）。" }
                } finally {
                    if ([IO.File]::Exists($validationScript)) { [void][IO.File]::Delete($validationScript) }
                }
                [void](Write-PhaseJournal -Sequence 70 -Phase 'validation-passed')
                $state = Get-CertifiedState
            }
            Stop-IfRequested -Sequence 70

            if ($state.lastSequence -lt 80) {
                if (-not $state.markerPresent) { throw '完成前 marker 必须在场。' }
                [void][IO.File]::Delete($markerPath)
                if ([IO.File]::Exists($markerPath)) { throw 'marker 删除后仍存在。' }
                [void](Write-PhaseJournal -Sequence 80 -Phase 'complete')
            }
            if (-not [IO.File]::Exists($finalReceiptPath)) {
                Write-CreateOnlyJson -Path $finalReceiptPath -Document ([pscustomobject][ordered]@{
                    outcome = 'complete'
                    deploymentId = $DeploymentId
                    completedUtc = [datetimeoffset]::UtcNow.ToString('o')
                    targetClosureSha256 = [string]$state.intent.targetClosureSha256
                })
            }
            Write-Output ("DEPLOY OK deploymentId={0}" -f $DeploymentId)
        }
        'RecoverRollback' {
            Assert-DeploymentIdentity -State $state
            if ($null -eq $state.intent) { throw 'RecoverRollback 需要 run 存在。' }
            if ($state.finalReceiptPresent) { throw 'run 已 terminal，拒绝再次恢复。' }
            $last = $state.lastSequence
            $lastPhase = $state.lastPhase
            if ($lastPhase -like '*-rollback-started') {
                if (-not $state.markerPresent) { throw 'rollback-in-progress 但 marker 缺失，矩阵拒绝。' }
                $rollPhase = $lastPhase -replace '-rollback-started$', ''
                $rollSequence = [int]$rollPhase.Split('-')[0]
                if ($rollSequence -ge 30) {
                    $restoredSha = Restore-ShimFromBackup
                    $backupMeta = Read-JsonFile -Path ($shimBackupPath + '.meta.json')
                    if ([string]$restoredSha -cne [string]$backupMeta.shimBeforeSha256) {
                        throw 'shim 回滚后 SHA 与备份元数据不一致。'
                    }
                }
                [void](Write-PhaseJournal -Sequence ($rollSequence + 1) -Phase ("{0}-rollback-complete" -f $rollPhase))
                [void][IO.File]::Delete($markerPath)
                if (-not [IO.File]::Exists($finalReceiptPath)) {
                    Write-CreateOnlyJson -Path $finalReceiptPath -Document ([pscustomobject][ordered]@{
                        outcome = 'rolled-back'
                        deploymentId = $DeploymentId
                        completedUtc = [datetimeoffset]::UtcNow.ToString('o')
                    })
                }
                Write-Output 'RECOVER-ROLLBACK OK（继续未完 rollback 至完成）'
                break
            }
            if ($last -ge 10 -and $last -le 20) {
                if ($state.markerPresent) { throw 'phase 10–20 时 marker 必须缺席，矩阵拒绝。' }
                $restoredSha = $null
                if ($last -eq 20 -and [IO.File]::Exists($shimBackupPath)) {
                    $restoredSha = Restore-ShimFromBackup
                    $backupMeta = Read-JsonFile -Path ($shimBackupPath + '.meta.json')
                    if ([string]$restoredSha -cne [string]$backupMeta.shimBeforeSha256) {
                        throw 'bootstrap 回滚后 shim SHA 与备份元数据不一致。'
                    }
                }
                [void](Write-PhaseJournal -Sequence ($last + 1) -Phase ("{0}-rollback-complete" -f (Get-DeploymentPhaseName -Sequence $last)))
                Write-CreateOnlyJson -Path $finalReceiptPath -Document ([pscustomobject][ordered]@{
                    outcome = 'rolled-back'
                    deploymentId = $DeploymentId
                    completedUtc = [datetimeoffset]::UtcNow.ToString('o')
                    restoredShimSha256 = $restoredSha
                })
                Write-Output 'RECOVER-ROLLBACK OK（bootstrap 回滚）'
                break
            }
            if ($last -ge 30 -and $last -le 80) {
                if (-not $state.markerPresent) {
                    if ($lastPhase -ceq 'complete') {
                        # 矩阵③ marker-absent 分支：terminal phase 已落盘 → 验证 live 现场后幂等补 final receipt。
                        $closure = Get-CodexSafeTreeDeleteClosure -ProjectRoot $projectRoot
                        if ([string]$closure.closureSha256 -cne [string]$state.intent.targetClosureSha256) {
                            throw 'complete 收尾失败：live closure 与 target 不一致。'
                        }
                        if (-not [IO.File]::Exists($finalReceiptPath)) {
                            Write-CreateOnlyJson -Path $finalReceiptPath -Document ([pscustomobject][ordered]@{
                                outcome = 'complete'
                                deploymentId = $DeploymentId
                                completedUtc = [datetimeoffset]::UtcNow.ToString('o')
                                targetClosureSha256 = [string]$state.intent.targetClosureSha256
                            })
                        }
                        Write-Output 'RECOVER-ROLLBACK OK（complete + marker 已删：幂等补 final receipt）'
                        break
                    }
                    throw 'phase 30–70/complete 但 marker 缺失，矩阵拒绝。'
                }
                if ($lastPhase -ceq 'complete') {
                    # marker 仍在（完成未收尾）：验证现场后删除 marker 并补 final receipt。
                    [void][IO.File]::Delete($markerPath)
                    if ([IO.File]::Exists($markerPath)) { throw 'marker 删除失败。' }
                    if (-not [IO.File]::Exists($finalReceiptPath)) {
                        Write-CreateOnlyJson -Path $finalReceiptPath -Document ([pscustomobject][ordered]@{
                            outcome = 'complete'
                            deploymentId = $DeploymentId
                            completedUtc = [datetimeoffset]::UtcNow.ToString('o')
                            targetClosureSha256 = [string]$state.intent.targetClosureSha256
                        })
                    }
                    Write-Output 'RECOVER-ROLLBACK OK（complete 收尾：marker 移除 + final receipt）'
                    break
                }
                if ($last -eq 70) {
                    # validation 已过：完成 target（source 已验证 + marker 收尾）。
                    [void](Write-PhaseJournal -Sequence 80 -Phase 'complete')
                    [void][IO.File]::Delete($markerPath)
                    Write-CreateOnlyJson -Path $finalReceiptPath -Document ([pscustomobject][ordered]@{
                        outcome = 'complete'
                        deploymentId = $DeploymentId
                        completedUtc = [datetimeoffset]::UtcNow.ToString('o')
                        targetClosureSha256 = [string]$state.intent.targetClosureSha256
                    })
                    Write-Output 'RECOVER-ROLLBACK OK（validation 已过 → 完成 target）'
                    break
                }
                # 30–60：回滚。repo 字节回退不属本工具可写面——认证 previous closure 已就位
                # 才继续；否则失败闭锁并保留 marker。
                $closure = Get-CodexSafeTreeDeleteClosure -ProjectRoot $projectRoot
                if ([string]$closure.closureSha256 -cne [string]$state.intent.previousClosureSha256) {
                    throw ('回滚前置失败：live closure 既非 previous 也非可继续状态；' +
                        '先以版本控制恢复 previous closure 再重试 RecoverRollback。')
                }
                [void](Write-PhaseJournal -Sequence ($last + 1) -Phase ("{0}-rollback-started" -f (Get-DeploymentPhaseName -Sequence $last)))
                $restoredSha = Restore-ShimFromBackup
                $backupMeta = Read-JsonFile -Path ($shimBackupPath + '.meta.json')
                if ([string]$restoredSha -cne [string]$backupMeta.shimBeforeSha256) {
                    throw 'shim 回滚后 SHA 与备份元数据不一致。'
                }
                [void](Write-PhaseJournal -Sequence ($last + 2) -Phase ("{0}-rollback-complete" -f (Get-DeploymentPhaseName -Sequence $last)))
                [void][IO.File]::Delete($markerPath)
                Write-CreateOnlyJson -Path $finalReceiptPath -Document ([pscustomobject][ordered]@{
                    outcome = 'rolled-back'
                    deploymentId = $DeploymentId
                    completedUtc = [datetimeoffset]::UtcNow.ToString('o')
                })
                Write-Output 'RECOVER-ROLLBACK OK（回滚 previous closure）'
                break
            }
            throw "无法认证的 phase 状态（last=$last phase=$lastPhase），矩阵拒绝。"
        }
    }
} finally {
    Remove-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot
    [void]$mutex.ReleaseMutex()
    $mutex.Dispose()
}
