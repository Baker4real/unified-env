[CmdletBinding()]
param(
    # 要检查的工作树，缺省为本脚本所在 checkout。
    [string]$RepositoryRoot,
    # 测试专用 seam（capability spec「安静窗口」记录；生产调用不得传递），两个必须同时给出：
    [string]$StateRootForTest,
    [string]$MutexNameForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# git 的退出码由本脚本自己判断。
$PSNativeCommandUseErrorActionPreference = $false
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# 安静窗口只读检查，条件与语义见 capability spec「部署门与维护窗口」的「安静窗口」小节。
# 不取 deployment mutex、不写任何文件；输出一行 ASCII-only JSON。
# 退出码：0 安静，1 不安静，2 有条件无法判定（或参数不合法）。

. (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDeleteGateHolder.ps1')

$productionStateRoot = 'D:\Codex\.codex\state\safe-tree-delete-deployment'
$productionMutexBase = 'Global\CodexSafeTreeDeleteDeployment'
# 与部署工具 legacy drain 同口径的可执行名，另加跑测试 runner 的 node。
$processNames = @('pwsh.exe', 'powershell.exe', 'cmd.exe', 'node.exe')
$processMarkers = @(
    'invoke-safe-tree-delete',
    'invoke-codex-safe-tree-delete',
    'Invoke-CodexSafeTreeDelete',
    'Deploy-CodexSafeTreeDelete',
    'Update-CodexSafeTreeDeletePolicy',
    'Measure-CodexSafeTreeDelete',
    'Invoke-SafeCleanupJob',
    'Run-PowerShellTests.cjs',
    'Run-ManifestTests.cjs'
)

$hasStateRootSeam = -not [string]::IsNullOrWhiteSpace($StateRootForTest)
$hasMutexSeam = -not [string]::IsNullOrWhiteSpace($MutexNameForTest)
if ($hasStateRootSeam -ne $hasMutexSeam) {
    [pscustomobject][ordered]@{
        quiet = $false
        error = 'StateRootForTest and MutexNameForTest must be given together'
    } | ConvertTo-Json -Compress
    exit 2
}
$testSeamActive = $hasStateRootSeam

if ($testSeamActive) {
    $stateRoot = $StateRootForTest
    $mutexName = $MutexNameForTest
} else {
    $stateRoot = $productionStateRoot
    # current-user 命名空间，与 gate shim、部署工具同名。
    $sid = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutexName = '{0}-u-{1}' -f $productionMutexBase, ($sid -replace '[^0-9]', '')
}
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

$conditions = [Collections.Generic.List[object]]::new()

function Add-Condition {
    # 求值失败的条件记 ok=null 与 error，整体判为无法判定。
    param([string]$Name, [scriptblock]$Evaluate)

    try {
        $result = & $Evaluate
        $conditions.Add([ordered]@{ name = $Name; ok = [bool]$result.ok; detail = $result.detail })
    } catch {
        $conditions.Add([ordered]@{ name = $Name; ok = $null; error = $_.Exception.Message })
    }
}

# 与 Deploy-CodexSafeTreeDelete.ps1 里的同名函数逐字一致（本检查的测试核对），改时两处同改。
function Get-ProcessAncestorIds {
    # 从 StartProcessId 沿 ParentProcessId 上溯，返回它自身及祖先的 PID 集合；到 PID <= 4
    # （System/Idle）或表里没有的 PID 为止。ParentProcessId 只是快照值：祖先的父进程退出后，
    # 它的 PID 可能被更晚创建的进程复用（链外的无关进程，或链下方的进程从而让父链成环）。
    # 真父进程一定早于子进程创建，所以父 PID 上的进程比子进程创建得晚就停；遇到已访问过的
    # PID 也停，保证上溯必然终止。
    param(
        [Parameter(Mandatory)][hashtable]$ProcessesById,
        [Parameter(Mandatory)][int]$StartProcessId
    )

    $ancestors = [Collections.Generic.HashSet[int]]::new()
    $cursor = $StartProcessId
    while ($ProcessesById.ContainsKey($cursor) -and $ancestors.Add($cursor)) {
        $child = $ProcessesById[$cursor]
        $cursor = [int]$child.ParentProcessId
        if ($cursor -le 4) { break }
        if ($ProcessesById.ContainsKey($cursor) -and
            $ProcessesById[$cursor].CreationDate -gt $child.CreationDate) { break }
    }
    return , $ancestors
}

Add-Condition 'gate-idle' {
    # mutex 存在即有进程持有或正在等待它；只打开句柄探测，不取锁。
    $handle = $null
    $mutexPresent = $false
    try {
        $mutexPresent = [Threading.Mutex]::TryOpenExisting($mutexName, [ref]$handle)
    } catch [UnauthorizedAccessException] {
        $mutexPresent = $true
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }
    $holder = $null
    if ([IO.File]::Exists((Get-CodexSafeTreeDeleteGateHolderPath -StateRoot $stateRoot))) {
        $holder = Read-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot
    }
    $liveHolder = $null -ne $holder -and $holder.Contains('stale') -and -not $holder['stale']
    @{
        ok = (-not $mutexPresent -and -not $liveHolder)
        detail = [ordered]@{ mutexPresent = $mutexPresent; holder = $holder }
    }
}

Add-Condition 'no-maintenance-marker' {
    $present = Test-Path -LiteralPath (Join-Path $stateRoot 'maintenance.json')
    @{ ok = -not $present; detail = [ordered]@{ markerPresent = $present } }
}

Add-Condition 'no-managed-delete-or-test-runner-process' {
    # 检查进程自身及祖先链不计（调用方可能正从某个入口里运行本检查）。
    $all = @(Get-CimInstance -ClassName Win32_Process)
    $byId = @{}
    foreach ($process in $all) { $byId[[int]$process.ProcessId] = $process }
    $excluded = Get-ProcessAncestorIds -ProcessesById $byId -StartProcessId ([int]$PID)
    $found =[Collections.Generic.List[object]]::new()
    $unreadable = 0
    foreach ($process in $all) {
        if ($excluded.Contains([int]$process.ProcessId)) { continue }
        if ([string]$process.Name -notin $processNames) { continue }
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            $unreadable++
            continue
        }
        # 测试 seam 生效时只计命令行同时含 fixture state root 的进程（同部署工具 #93 的 drain 范围）。
        if ($testSeamActive -and $commandLine.IndexOf($stateRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }
        foreach ($marker in $processMarkers) {
            if ($commandLine.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                # 只报 PID、进程名与命中的标记，不回显命令行。
                $found.Add([ordered]@{ processId = [int]$process.ProcessId; name = [string]$process.Name; marker = $marker })
                break
            }
        }
    }
    @{
        ok = ($found.Count -eq 0)
        detail = [ordered]@{ processes = @($found); unreadableCommandLines = $unreadable }
    }
}

Add-Condition 'main-tree-clean' {
    # --no-optional-locks：检查本身不刷新 index、不碰 index.lock。
    $entries = @(& git -C $RepositoryRoot --no-optional-locks status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { throw ('git status failed with exit code {0}' -f $LASTEXITCODE) }
    $gitDirectory = @(& git -C $RepositoryRoot rev-parse --absolute-git-dir 2>$null)
    if ($LASTEXITCODE -ne 0 -or $gitDirectory.Count -ne 1) { throw 'git rev-parse --absolute-git-dir failed' }
    $indexLockPresent = [IO.File]::Exists((Join-Path ([string]$gitDirectory[0]) 'index.lock'))
    $changed = @($entries | Where-Object { ([string]$_).Length -gt 0 })
    @{
        ok = ($changed.Count -eq 0 -and -not $indexLockPresent)
        detail = [ordered]@{ changedEntryCount = $changed.Count; indexLockPresent = $indexLockPresent }
    }
}

$quiet = @($conditions | Where-Object { $_.ok -ne $true }).Count -eq 0
$undetermined = @($conditions | Where-Object { $null -eq $_.ok }).Count -gt 0
[pscustomobject][ordered]@{
    quiet = $quiet
    checkedAtUtc = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    repositoryRoot = $RepositoryRoot
    conditions = @($conditions)
} | ConvertTo-Json -Compress -Depth 6 -EscapeHandling EscapeNonAscii
exit $(if ($quiet) { 0 } elseif ($undetermined) { 2 } else { 1 })
