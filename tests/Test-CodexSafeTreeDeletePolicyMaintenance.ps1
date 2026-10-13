[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #82，spec #73「policy 维护工具」):
# 次接缝 2：维护工具 scripts\Update-CodexSafeTreeDeletePolicy.ps1 的测试专用参数（policy 路径、evidence 根、
# mutex 名、marker 路径、阶段停止、阶段暂停、等锁上限）。只观察工具输出的 JSON 与退出码、落盘后的 policy 字节，
# 以及 fixture 目录树在调用前后的快照；在途记录经 fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1
# 的 Plan/Apply/Purge 构造。本套件不读写生产 policy、生产 evidence 根或部署状态目录，也不执行生产入口。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1')
$toolPath = Join-Path $projectRoot 'scripts\Update-CodexSafeTreeDeletePolicy.ps1'
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'policy-maintenance'
$utf8 = [Text.UTF8Encoding]::new($false)
$sidSuffix = (([string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -replace '[^0-9]', '')
$childProcesses = [Collections.Generic.List[object]]::new()

# 与仓库 managed/safe-tree-delete/policy.json 同一书写格式：UTF-8 无 BOM、LF、两空格缩进、末尾换行。
# {TARGETS} 与 {SPARE} 是场景内 JSON 转义后的 root。fixture-spare 的 deny 比最小后代深度更深，是现役
# policy 已有的结构违例（规则 1）。
$basePolicyTemplate = @'
{
  "artifactType": "env-governance.codex-safe-tree-delete-policy",
  "schemaVersion": 4,
  "entries": [
    {
      "id": "fixture-main",
      "capabilityRoot": "{TARGETS}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "deniedExactPaths": [
        "{TARGETS}\\keep"
      ]
    },
    {
      "id": "fixture-spare",
      "capabilityRoot": "{SPARE}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "allowHardLinks": false,
      "allowInternalDirectoryJunctions": false,
      "deniedExactPaths": [
        "{SPARE}\\nested\\deep"
      ]
    }
  ]
}
'@

# fixture-main 追加一条 deny 之后的完整候选（独立真值：手写字面量，不经工具的序列化器生成）。
$addDenyPolicyTemplate = @'
{
  "artifactType": "env-governance.codex-safe-tree-delete-policy",
  "schemaVersion": 4,
  "entries": [
    {
      "id": "fixture-main",
      "capabilityRoot": "{TARGETS}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "deniedExactPaths": [
        "{TARGETS}\\keep",
        "{TARGETS}\\protected"
      ]
    },
    {
      "id": "fixture-spare",
      "capabilityRoot": "{SPARE}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "allowHardLinks": false,
      "allowInternalDirectoryJunctions": false,
      "deniedExactPaths": [
        "{SPARE}\\nested\\deep"
      ]
    }
  ]
}
'@

# 退役 fixture-spare 之后的完整候选（手写字面量）。
$retireEntryPolicyTemplate = @'
{
  "artifactType": "env-governance.codex-safe-tree-delete-policy",
  "schemaVersion": 4,
  "entries": [
    {
      "id": "fixture-main",
      "capabilityRoot": "{TARGETS}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "deniedExactPaths": [
        "{TARGETS}\\keep"
      ]
    }
  ]
}
'@

# 移除 fixture-main 唯一一条 deny 之后的完整候选（手写字面量；空列表与仓库 policy 同写作 []）。
$removeDenyPolicyTemplate = @'
{
  "artifactType": "env-governance.codex-safe-tree-delete-policy",
  "schemaVersion": 4,
  "entries": [
    {
      "id": "fixture-main",
      "capabilityRoot": "{TARGETS}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "deniedExactPaths": []
    },
    {
      "id": "fixture-spare",
      "capabilityRoot": "{SPARE}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "allowHardLinks": false,
      "allowInternalDirectoryJunctions": false,
      "deniedExactPaths": [
        "{SPARE}\\nested\\deep"
      ]
    }
  ]
}
'@

# 追加 fixture-extra 之后的完整候选（手写字面量；新条目按仓库 policy 的属性顺序写在末尾）。
$addEntryPolicyTemplate = @'
{
  "artifactType": "env-governance.codex-safe-tree-delete-policy",
  "schemaVersion": 4,
  "entries": [
    {
      "id": "fixture-main",
      "capabilityRoot": "{TARGETS}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "deniedExactPaths": [
        "{TARGETS}\\keep"
      ]
    },
    {
      "id": "fixture-spare",
      "capabilityRoot": "{SPARE}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "allowHardLinks": false,
      "allowInternalDirectoryJunctions": false,
      "deniedExactPaths": [
        "{SPARE}\\nested\\deep"
      ]
    },
    {
      "id": "fixture-extra",
      "capabilityRoot": "{EXTRA}",
      "minimumDescendantDepth": 1,
      "rootDeletionPurpose": "none",
      "deniedExactPaths": [
        "{EXTRA}\\a"
      ]
    }
  ]
}
'@

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete policy maintenance test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete policy maintenance test cleanup'
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertTo-JsonPathText {
    param([Parameter(Mandatory)][string]$Path)
    return $Path.Replace('\', '\\')
}

function Expand-PolicyTemplate {
    param(
        [Parameter(Mandatory)][object]$Scenario,
        [Parameter(Mandatory)][string]$Template
    )
    $text = $Template.Replace("`r`n", "`n").
        Replace('{TARGETS}', (ConvertTo-JsonPathText -Path $Scenario.TargetsRoot)).
        Replace('{SPARE}', (ConvertTo-JsonPathText -Path $Scenario.SpareRoot)).
        Replace('{EXTRA}', (ConvertTo-JsonPathText -Path $Scenario.ExtraRoot))
    return $text + "`n"
}

function New-Scenario {
    param([Parameter(Mandatory)][string]$Name)

    $root = Join-Path $scratchRoot $Name
    $scenario = [pscustomobject][ordered]@{
        Name = $Name
        Root = $root
        PolicyDirectory = (Join-Path $root 'policy')
        PolicyPath = (Join-Path $root 'policy\policy.json')
        EvidenceRoot = (Join-Path $root 'evidence')
        TargetsRoot = (Join-Path $root 'targets')
        SpareRoot = (Join-Path $root 'spare')
        ExtraRoot = (Join-Path $root 'extra')
        StateRoot = (Join-Path $root 'state')
        MarkerPath = (Join-Path $root 'state\maintenance.json')
        ChangeSetPath = (Join-Path $root 'change-set.json')
        # 每次运行唯一：不与并发 worktree 的同名场景或部署测试的固定 mutex 名冲突。
        MutexName = ('Local\std-policy-maintenance-test-{0}-{1}' -f $Name, [guid]::NewGuid().ToString('N'))
    }
    foreach ($directory in @($scenario.PolicyDirectory, $scenario.EvidenceRoot, $scenario.TargetsRoot,
            $scenario.SpareRoot, $scenario.StateRoot)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    [IO.File]::WriteAllBytes($scenario.PolicyPath,
        $utf8.GetBytes((Expand-PolicyTemplate -Scenario $scenario -Template $basePolicyTemplate)))
    return $scenario
}

function Set-ChangeSet {
    param(
        [Parameter(Mandatory)][object]$Scenario,
        [Parameter(Mandatory)][object[]]$Changes
    )
    $document = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy-change-set'
        schemaVersion = 1
        changes = @($Changes)
    }
    [IO.File]::WriteAllText($Scenario.ChangeSetPath, ($document | ConvertTo-Json -Depth 16), $utf8)
}

function Get-TreeState {
    # 目录树内每个目录与文件的相对路径及文件 SHA-256，用于证明调用前后零写入。
    param([Parameter(Mandatory)][string]$Path)

    $rows = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -Recurse | Sort-Object -Property FullName)) {
        $relative = [IO.Path]::GetRelativePath($Path, $item.FullName)
        if ($item.PSIsContainer) {
            "dir|$relative"
        } else {
            'file|{0}|{1}' -f $relative, (Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($item.FullName)))
        }
    }
    return (@($rows) -join "`n")
}

function Invoke-PolicyTool {
    # 进程内调用维护工具：返回退出码、原始输出文本与解析后的 JSON（输出不是 JSON 时为 $null）。
    param(
        [Parameter(Mandatory)][object]$Scenario,
        [Parameter(Mandatory)][string]$Mode,
        [string]$ApprovedCandidatePolicySha256,
        [string[]]$ConfirmManualReviewOperationIds = @(),
        [int]$StopAfterPhase = 0,
        # 其余测试 seam 参数（例如暂停 seam）原样传入；四个必备 seam 总是由场景给出。
        [hashtable]$ExtraArguments = @{}
    )
    $arguments = @{
        Mode = $Mode
        ChangeSetPath = $Scenario.ChangeSetPath
        PolicyPathForTest = $Scenario.PolicyPath
        EvidenceRootForTest = $Scenario.EvidenceRoot
        MutexNameForTest = $Scenario.MutexName
        MarkerPathForTest = $Scenario.MarkerPath
    }
    foreach ($name in $ExtraArguments.Keys) { $arguments[$name] = $ExtraArguments[$name] }
    if (-not [string]::IsNullOrWhiteSpace($ApprovedCandidatePolicySha256)) {
        $arguments.ApprovedCandidatePolicySha256 = $ApprovedCandidatePolicySha256
    }
    if ($ConfirmManualReviewOperationIds.Count -gt 0) {
        # 宿主 .cmd 链只能传单个字符串：多个 operation id 以 '::' 连接。
        $arguments.ConfirmManualReviewOperationIds = ($ConfirmManualReviewOperationIds -join '::')
    }
    if ($StopAfterPhase -gt 0) {
        $arguments.StopAfterPhaseForTest = $StopAfterPhase
    }
    $global:LASTEXITCODE = -1
    $output = @(& $toolPath @arguments)
    $exitCode = $global:LASTEXITCODE
    $text = (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $json = $null
    if ($text.StartsWith('{', [StringComparison]::Ordinal)) {
        $json = $text | ConvertFrom-Json -Depth 32 -DateKind String
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
        Json = $json
    }
}

function New-FixtureRecord {
    # 经 fixture 入口在场景 evidence 根下构造一条 operation run：Plan，按 Stage 继续 Apply（quarantined）
    # 与 Purge（purged）。target 位于 fixture-main 的 root 下。
    param(
        [Parameter(Mandatory)][object]$Scenario,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('planned', 'quarantined', 'purged')][string]$Stage = 'planned'
    )
    $target = Join-Path $Scenario.TargetsRoot $Name
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'payload.txt'), "policy-maintenance-$Name", $utf8)
    $plan = & $entryPath -Mode Plan -TargetPath $target -CapabilityRoot $Scenario.TargetsRoot `
        -FixturePolicyPath $Scenario.PolicyPath -FixtureEvidenceRoot $Scenario.EvidenceRoot
    $record = [pscustomobject][ordered]@{
        TargetPath = $target
        PlanPath = [string]$plan.planPath
        OperationId = Split-Path -Leaf (Split-Path -Parent ([string]$plan.planPath))
        TransactionPath = $null
        TransactionSha256 = $null
    }
    if ($Stage -cne 'planned') {
        $apply = & $entryPath -Mode Apply -PlanPath $record.PlanPath -ApprovedPlanSha256 ([string]$plan.planSha256) `
            -ConfirmApply -FixturePolicyPath $Scenario.PolicyPath -FixtureEvidenceRoot $Scenario.EvidenceRoot
        Assert-True ($apply.quarantined -eq $true) "$Name 夹具 Apply 必须成功"
        $record.TransactionPath = [string]$apply.transactionPath
        $record.TransactionSha256 = [string]$apply.transactionSha256
        if ($Stage -ceq 'purged') {
            $purge = & $entryPath -Mode Purge -TransactionPath $record.TransactionPath `
                -ApprovedTransactionSha256 $record.TransactionSha256 -ConfirmPurge `
                -FixturePolicyPath $Scenario.PolicyPath -FixtureEvidenceRoot $Scenario.EvidenceRoot
            Assert-True ($purge.purged -eq $true) "$Name 夹具 Purge 必须成功"
            $record.TransactionSha256 = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($record.TransactionPath))
        }
    }
    return $record
}

function Set-PlanExpired {
    # 与 Status 套件的过期 plan 夹具同一做法：把 plan.json 的 expiresAtUtc 改到过去。
    param([Parameter(Mandatory)][string]$PlanPath)
    $document = Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    $document.expiresAtUtc = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    [IO.File]::WriteAllText($PlanPath, ($document | ConvertTo-Json -Depth 64), $utf8)
}

function Assert-Refusal {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$RefusalReason,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-True ($Result.ExitCode -eq 1) "${Label}: 拒绝必须 exit 1（实际 $($Result.ExitCode)）：$($Result.Text)"
    Assert-True ($Result.Text -cmatch '\A[\x00-\x7F]+\z') "${Label}: 输出必须 ASCII-only：$($Result.Text)"
    Assert-True ($null -ne $Result.Json -and $Result.Json.ok -eq $false) "${Label}: 输出必须是 ok=false 的 JSON：$($Result.Text)"
    Assert-True ([string]$Result.Json.refusalReason -ceq $RefusalReason) `
        "${Label}: refusalReason 必须为 $RefusalReason：$($Result.Text)"
}

function Start-ChildPwsh {
    # 与部署套件同款子进程：mutex 按线程可重入，等锁超时只能在另一进程里观察。
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
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
    }
    $childProcesses.Add($call)
    return $call
}

function Complete-ChildPwsh {
    param(
        [Parameter(Mandatory)][object]$Call,
        [int]$TimeoutSeconds = 120
    )
    if (-not $Call.Process.WaitForExit($TimeoutSeconds * 1000)) {
        $Call.Process.Kill($true)
        $Call.Process.WaitForExit()
        throw "子进程 $($Call.Process.Id) 未在 ${TimeoutSeconds}s 内退出"
    }
    $Call.Process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $Call.Process.ExitCode
        Stdout = $Call.Stdout.GetAwaiter().GetResult()
        Stderr = $Call.Stderr.GetAwaiter().GetResult()
    }
}

function Start-PausedPolicyTool {
    # 子进程运行维护工具（四个 seam 齐全），在第一个不小于 PauseAfterPhase 的阶段边界暂停：工具仍持锁，
    # 在信号目录写 paused-<阶段>，等到 resume 出现再继续。返回时工具已到达暂停点。
    param(
        [Parameter(Mandatory)][object]$Scenario,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][int]$PauseAfterPhase,
        [Parameter(Mandatory)][string]$SignalDirectory,
        [Parameter(Mandatory)][string]$Label
    )
    [void][IO.Directory]::CreateDirectory($SignalDirectory)
    $call = Start-ChildPwsh -File $toolPath -Arguments @(
        '-Mode', $Mode, '-ChangeSetPath', $Scenario.ChangeSetPath,
        '-PolicyPathForTest', $Scenario.PolicyPath, '-EvidenceRootForTest', $Scenario.EvidenceRoot,
        '-MutexNameForTest', $Scenario.MutexName, '-MarkerPathForTest', $Scenario.MarkerPath,
        '-PauseAfterPhaseForTest', [string]$PauseAfterPhase, '-PauseSignalDirectoryForTest', $SignalDirectory)
    $pausedPath = Join-Path $SignalDirectory ('paused-{0}' -f $PauseAfterPhase)
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    while (-not [IO.File]::Exists($pausedPath)) {
        if ($call.Process.HasExited) {
            $early = Complete-ChildPwsh -Call $call
            throw "${Label}: 工具未到达阶段 $PauseAfterPhase 的暂停点就退出（exit $($early.ExitCode)）：$($early.Stdout)$($early.Stderr)"
        }
        Assert-True ([datetime]::UtcNow -lt $deadline) "${Label}: 工具未在 90s 内到达阶段 $PauseAfterPhase 的暂停点"
        Start-Sleep -Milliseconds 50
    }
    return $call
}

function Resume-PausedPolicyTool {
    # 放行暂停中的工具，等它退出；返回形状与 Invoke-PolicyTool 相同。
    param(
        [Parameter(Mandatory)][object]$Call,
        [Parameter(Mandatory)][string]$SignalDirectory
    )
    [IO.File]::WriteAllBytes((Join-Path $SignalDirectory 'resume'), [byte[]]@())
    $done = Complete-ChildPwsh -Call $Call
    $text = $done.Stdout.Trim()
    $json = $null
    if ($text.StartsWith('{', [StringComparison]::Ordinal)) {
        $json = $text | ConvertFrom-Json -Depth 32 -DateKind String
    }
    return [pscustomobject]@{
        ExitCode = $done.ExitCode
        Text = $text
        Json = $json
        Stderr = $done.Stderr
    }
}

function Test-GateMutexFree {
    # 本进程以 0 超时探测同名 mutex：取得即释放并返回 $true；被另一进程持有时返回 $false。
    param([Parameter(Mandatory)][string]$BaseName)
    $probe = [Threading.Mutex]::new($false, ('{0}-u-{1}' -f $BaseName, $sidSuffix))
    try {
        try {
            $acquired = $probe.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if ($acquired) { $probe.ReleaseMutex() }
        return $acquired
    } finally {
        $probe.Dispose()
    }
}

try {
    # ---- 1. maintenance marker 在场：取锁后拒绝，policy、evidence 与状态目录零写入 ----
    Write-Output 'STEP marker'
    $marker = New-Scenario -Name 'marker'
    Set-ChangeSet -Scenario $marker -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $marker.TargetsRoot 'protected') })
    [IO.File]::WriteAllText($marker.MarkerPath, '{"schemaVersion":1}', $utf8)
    $markerBefore = Get-TreeState -Path $marker.Root
    foreach ($mode in @('DryRun', 'Apply')) {
        $markerResult = Invoke-PolicyTool -Scenario $marker -Mode $mode -ApprovedCandidatePolicySha256 $(
            if ($mode -ceq 'Apply') { '0' * 64 } else { $null })
        Assert-Refusal -Result $markerResult -RefusalReason 'deployment-maintenance-marker-present' -Label "marker-$mode"
        Assert-True ((Get-TreeState -Path $marker.Root) -ceq $markerBefore) "marker-${mode}: 拒绝后场景目录必须零写入（含面包屑已删除）"
    }
    Write-Output 'marker OK'

    # ---- 2. DryRun：给出候选 SHA、变更摘要与现役结构违例，不写任何文件。工具在子进程里运行，在阶段 50
    # （候选已被加载器接受、在途检查之前，仍持锁）暂停：此刻与结束后 policy 目录和 evidence 根都与调用前
    # 相同，候选只在内存里 ----
    Write-Output 'STEP dry-run'
    $dry = New-Scenario -Name 'dryrun'
    # 一条 terminal 记录：evidence 根非空，Status 预检确实读它；变更不影响该记录，DryRun 照常放行。
    [void](New-FixtureRecord -Scenario $dry -Name 'done' -Stage 'purged')
    $baseBytes = [IO.File]::ReadAllBytes($dry.PolicyPath)
    $expectedAddDenyBytes = $utf8.GetBytes((Expand-PolicyTemplate -Scenario $dry -Template $addDenyPolicyTemplate))
    Set-ChangeSet -Scenario $dry -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $dry.TargetsRoot 'protected') })
    $dryBefore = Get-TreeState -Path $dry.Root
    $dryPolicyDirectoryBefore = Get-TreeState -Path $dry.PolicyDirectory
    $dryEvidenceBefore = Get-TreeState -Path $dry.EvidenceRoot
    $drySignals = Join-Path $scratchRoot 'dryrun-signals'
    $dryCall = Start-PausedPolicyTool -Scenario $dry -Mode 'DryRun' -PauseAfterPhase 50 -SignalDirectory $drySignals -Label 'dry-run'
    $dryPolicyDirectoryPaused = Get-TreeState -Path $dry.PolicyDirectory
    $dryEvidencePaused = Get-TreeState -Path $dry.EvidenceRoot
    $dryResult = Resume-PausedPolicyTool -Call $dryCall -SignalDirectory $drySignals
    Assert-True ($dryPolicyDirectoryPaused -ceq $dryPolicyDirectoryBefore) `
        "dry-run: 持锁期间 policy 目录必须与调用前相同（不得暂存候选）：$($dryPolicyDirectoryPaused.Replace("`n", ' ; '))"
    Assert-True ($dryEvidencePaused -ceq $dryEvidenceBefore) 'dry-run: 持锁期间 evidence 根必须与调用前相同'
    Assert-True ($dryResult.ExitCode -eq 0) "dry-run: 可放行的变更必须 exit 0（实际 $($dryResult.ExitCode)）：$($dryResult.Text)$($dryResult.Stderr)"
    Assert-True ($dryResult.Text -cmatch '\A[\x00-\x7F]+\z') "dry-run: 输出必须 ASCII-only：$($dryResult.Text)"
    Assert-True ($dryResult.Json.ok -eq $true -and [string]$dryResult.Json.mode -ceq 'DryRun' -and
        $null -eq $dryResult.Json.refusalReason) "dry-run: 必须 ok=true：$($dryResult.Text)"
    Assert-True ([string]$dryResult.Json.livePolicySha256 -ceq (Get-Sha256Hex -Bytes $baseBytes)) `
        'dry-run: livePolicySha256 必须是磁盘现役 policy 原始字节的 SHA-256'
    Assert-True ([string]$dryResult.Json.candidatePolicySha256 -ceq (Get-Sha256Hex -Bytes $expectedAddDenyBytes)) `
        "dry-run: candidatePolicySha256 必须等于手写期望候选的 SHA-256：$($dryResult.Text)"
    Assert-True ($dryResult.Json.written -eq $false -and $null -eq $dryResult.Json.notice) 'dry-run: 不得报告已落盘'
    $dryChanges = @($dryResult.Json.changes)
    Assert-True ($dryChanges.Count -eq 1 -and [string]$dryChanges[0].op -ceq 'add-deny' -and
        [string]$dryChanges[0].entryId -ceq 'fixture-main') "dry-run: changes 摘要不符：$($dryResult.Text)"
    $liveViolations = @($dryResult.Json.structure.liveViolations)
    Assert-True ($liveViolations.Count -eq 1 -and
        [string]$liveViolations[0].rule -ceq 'deny-deeper-than-minimum-depth' -and
        [string]$liveViolations[0].entryId -ceq 'fixture-spare' -and
        $liveViolations[0].denyIndex -eq 0) "dry-run: 现役结构违例必须列入输出：$($dryResult.Text)"
    Assert-True (@($dryResult.Json.structure.newViolations).Count -eq 0) 'dry-run: 不得报告新增违例'
    # gap 3：SafeCleanupJob 描述符不在工具视野内，输出按 job 的 policy 比对口径报告条目变化。
    $cleanupJob = $dryResult.Json.safeCleanupJob
    Assert-True (@($cleanupJob.changedExistingEntryIds).Count -eq 1 -and
        [string]@($cleanupJob.changedExistingEntryIds)[0] -ceq 'fixture-main' -and
        @($cleanupJob.addedEntryIds).Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$cleanupJob.note)) "dry-run: 必须报告 SafeCleanupJob 视角的条目变化：$($dryResult.Text)"
    # 输出按 EscapeNonAscii 转义，worktree 路径里的非 ASCII 段不会原样出现；用 scratch 根的 ASCII 叶名作针。
    Assert-True ($dryResult.Text.IndexOf((Split-Path -Leaf $scratchRoot), [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "dry-run: 输出不得包含 policy 路径值：$($dryResult.Text)"
    Assert-True ((Get-TreeState -Path $dry.PolicyDirectory) -ceq $dryPolicyDirectoryBefore) 'dry-run: 结束后 policy 目录必须与调用前相同'
    Assert-True ((Get-TreeState -Path $dry.EvidenceRoot) -ceq $dryEvidenceBefore) 'dry-run: 结束后 evidence 根必须与调用前相同'
    Assert-True ((Get-TreeState -Path $dry.Root) -ceq $dryBefore) 'dry-run: 场景目录必须零写入（policy、evidence、状态目录与面包屑）'
    Write-Output 'dry-run OK'

    # ---- 3. Apply：带 DryRun 的候选 SHA，原子替换落盘，磁盘字节等于手写期望候选 ----
    Write-Output 'STEP apply'
    $applyResult = Invoke-PolicyTool -Scenario $dry -Mode 'Apply' `
        -ApprovedCandidatePolicySha256 ([string]$dryResult.Json.candidatePolicySha256)
    Assert-True ($applyResult.ExitCode -eq 0 -and $applyResult.Json.ok -eq $true -and
        [string]$applyResult.Json.mode -ceq 'Apply') "apply: 必须成功：$($applyResult.Text)"
    Assert-True ($applyResult.Json.written -eq $true) 'apply: 必须报告已落盘'
    Assert-True ([string]$applyResult.Json.notice -ceq 'policy 已对宿主立即生效，git 提交需另行完成') `
        "apply: 必须提示立即生效与另行提交：$($applyResult.Text)"
    Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($dry.PolicyPath), [byte[]]$expectedAddDenyBytes)) `
        'apply: 磁盘 policy 必须逐字节等于批准的候选'
    $policyDirectoryNames = @([IO.Directory]::GetFileSystemEntries($dry.PolicyDirectory) | ForEach-Object { [IO.Path]::GetFileName($_) })
    Assert-True ($policyDirectoryNames.Count -eq 1 -and $policyDirectoryNames[0] -ceq 'policy.json') `
        "apply: policy 目录不得残留暂存或临时文件：$($policyDirectoryNames -join ',')"
    Assert-True (@([IO.Directory]::GetFileSystemEntries($dry.StateRoot)).Count -eq 0) 'apply: 释放锁后状态目录必须为空（面包屑已删除）'
    Write-Output 'apply OK'

    # ---- 4. Apply 时候选 SHA 与 DryRun 不一致（变更集在复核后被改动）→ 拒绝，磁盘零写入 ----
    Write-Output 'STEP sha-mismatch'
    $mismatch = New-Scenario -Name 'sha-mismatch'
    Set-ChangeSet -Scenario $mismatch -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $mismatch.TargetsRoot 'protected') })
    $reviewed = Invoke-PolicyTool -Scenario $mismatch -Mode 'DryRun'
    Assert-True ($reviewed.ExitCode -eq 0) "sha-mismatch: 复核用 DryRun 必须成功：$($reviewed.Text)"
    Set-ChangeSet -Scenario $mismatch -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $mismatch.TargetsRoot 'other') })
    $mismatchBefore = Get-TreeState -Path $mismatch.Root
    $mismatchResult = Invoke-PolicyTool -Scenario $mismatch -Mode 'Apply' `
        -ApprovedCandidatePolicySha256 ([string]$reviewed.Json.candidatePolicySha256)
    Assert-Refusal -Result $mismatchResult -RefusalReason 'candidate-sha-mismatch' -Label 'sha-mismatch'
    Assert-True ($mismatchResult.Json.written -eq $false) 'sha-mismatch: 不得报告已落盘'
    Assert-True ((Get-TreeState -Path $mismatch.Root) -ceq $mismatchBefore) 'sha-mismatch: 拒绝后场景目录必须零写入'
    Write-Output 'sha-mismatch OK'

    # ---- 5. 用阶段停止模拟中途失败：候选已通过检查（50、60）或临时文件已写入、尚未换名（65），磁盘仍是完整旧 policy ----
    Write-Output 'STEP phase-stop'
    $stop = New-Scenario -Name 'phase-stop'
    Set-ChangeSet -Scenario $stop -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $stop.TargetsRoot 'protected') })
    $stopApproved = [string](Invoke-PolicyTool -Scenario $stop -Mode 'DryRun').Json.candidatePolicySha256
    $stopBefore = Get-TreeState -Path $stop.Root
    foreach ($phase in @(50, 60, 65)) {
        $stopResult = Invoke-PolicyTool -Scenario $stop -Mode 'Apply' -ApprovedCandidatePolicySha256 $stopApproved -StopAfterPhase $phase
        Assert-True ($stopResult.ExitCode -eq 0 -and $stopResult.Text -ceq "STOPPED-AFTER-PHASE $phase") `
            "phase-stop-${phase}: 必须在该阶段停止：$($stopResult.Text)"
        Assert-True ((Get-TreeState -Path $stop.Root) -ceq $stopBefore) `
            "phase-stop-${phase}: 磁盘必须仍是完整旧 policy，且不残留临时文件或面包屑"
    }
    Write-Output 'phase-stop OK'

    # ---- 6. 在途：绑定现役 policy 的未过期 plan 阻止 DryRun 与 Apply；plan 过期后只列入 expiredPlans ----
    Write-Output 'STEP in-flight-planned'
    $planned = New-Scenario -Name 'inflight-planned'
    Set-ChangeSet -Scenario $planned -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $planned.TargetsRoot 'protected') })
    $plannedRecord = New-FixtureRecord -Scenario $planned -Name 'pending'
    $plannedBefore = Get-TreeState -Path $planned.Root
    $plannedDry = Invoke-PolicyTool -Scenario $planned -Mode 'DryRun'
    Assert-Refusal -Result $plannedDry -RefusalReason 'in-flight-records-blocking' -Label 'in-flight-planned-dry-run'
    $plannedBlocking = @($plannedDry.Json.inFlight.blocking)
    Assert-True ($plannedBlocking.Count -eq 1 -and
        [string]$plannedBlocking[0].operationId -ceq $plannedRecord.OperationId -and
        [string]$plannedBlocking[0].lifecycle -ceq 'planned' -and
        [string]$plannedBlocking[0].reason -ceq 'unexpired-plan') "in-flight-planned: 必须列出未过期 plan：$($plannedDry.Text)"
    $plannedApply = Invoke-PolicyTool -Scenario $planned -Mode 'Apply' `
        -ApprovedCandidatePolicySha256 ([string]$plannedDry.Json.candidatePolicySha256)
    Assert-Refusal -Result $plannedApply -RefusalReason 'in-flight-records-blocking' -Label 'in-flight-planned-apply'
    Assert-True ($plannedApply.Json.written -eq $false) 'in-flight-planned: Apply 不得报告已落盘'
    Assert-True ((Get-TreeState -Path $planned.Root) -ceq $plannedBefore) 'in-flight-planned: 阻止后场景目录必须零写入'
    Set-PlanExpired -PlanPath $plannedRecord.PlanPath
    $expiredDry = Invoke-PolicyTool -Scenario $planned -Mode 'DryRun'
    Assert-True ($expiredDry.ExitCode -eq 0 -and $expiredDry.Json.ok -eq $true) `
        "in-flight-planned: 过期 plan 不得阻止：$($expiredDry.Text)"
    Assert-True (@($expiredDry.Json.inFlight.blocking).Count -eq 0 -and
        @($expiredDry.Json.inFlight.expiredPlans).Count -eq 1 -and
        [string]@($expiredDry.Json.inFlight.expiredPlans)[0] -ceq $plannedRecord.OperationId) `
        "in-flight-planned: 过期 plan 必须列入 expiredPlans：$($expiredDry.Text)"
    Write-Output 'in-flight-planned OK'

    # ---- 7. 在途：绑定现役 policy 的 recoverable 记录阻止（v4 policy 下 Apply 写 v2 transaction，不重解析） ----
    Write-Output 'STEP in-flight-recoverable'
    $recoverable = New-Scenario -Name 'inflight-recoverable'
    Set-ChangeSet -Scenario $recoverable -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $recoverable.TargetsRoot 'protected') })
    $recoverableRecord = New-FixtureRecord -Scenario $recoverable -Name 'quarantined' -Stage 'quarantined'
    $recoverableBefore = Get-TreeState -Path $recoverable.Root
    $recoverableDry = Invoke-PolicyTool -Scenario $recoverable -Mode 'DryRun'
    Assert-Refusal -Result $recoverableDry -RefusalReason 'in-flight-records-blocking' -Label 'in-flight-recoverable'
    $recoverableBlocking = @($recoverableDry.Json.inFlight.blocking)
    Assert-True ($recoverableBlocking.Count -eq 1 -and
        [string]$recoverableBlocking[0].operationId -ceq $recoverableRecord.OperationId -and
        [string]$recoverableBlocking[0].lifecycle -ceq 'recoverable' -and
        [string]$recoverableBlocking[0].reason -ceq 'resumable-transaction') `
        "in-flight-recoverable: 必须列出 recoverable 记录：$($recoverableDry.Text)"
    Assert-True ((Get-TreeState -Path $recoverable.Root) -ceq $recoverableBefore) 'in-flight-recoverable: 阻止后场景目录必须零写入'
    Write-Output 'in-flight-recoverable OK'

    # ---- 8. 在途：manual-review 默认阻止；逐个 operation id 显式确认后放行，确认清单写入输出 ----
    Write-Output 'STEP in-flight-manual-review'
    $review = New-Scenario -Name 'inflight-manual-review'
    Set-ChangeSet -Scenario $review -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $review.TargetsRoot 'protected') })
    $reviewRecord = New-FixtureRecord -Scenario $review -Name 'drifted'
    # plan 之后 target 树漂移：Status 把该记录报告为 manual-review（仍绑定现役 policy）。
    [IO.File]::WriteAllText((Join-Path $reviewRecord.TargetPath 'late.txt'), 'late', $utf8)
    $reviewBefore = Get-TreeState -Path $review.Root
    $reviewDry = Invoke-PolicyTool -Scenario $review -Mode 'DryRun'
    Assert-Refusal -Result $reviewDry -RefusalReason 'in-flight-records-blocking' -Label 'in-flight-manual-review'
    $reviewBlocking = @($reviewDry.Json.inFlight.blocking)
    Assert-True ($reviewBlocking.Count -eq 1 -and
        [string]$reviewBlocking[0].operationId -ceq $reviewRecord.OperationId -and
        [string]$reviewBlocking[0].lifecycle -ceq 'manual-review' -and
        [string]$reviewBlocking[0].reason -ceq 'manual-review-unconfirmed') `
        "in-flight-manual-review: 未确认时必须阻止：$($reviewDry.Text)"
    Assert-True ((Get-TreeState -Path $review.Root) -ceq $reviewBefore) 'in-flight-manual-review: 阻止后场景目录必须零写入'
    $confirmations = @($reviewRecord.OperationId, 'not-a-record')
    $confirmedDry = Invoke-PolicyTool -Scenario $review -Mode 'DryRun' -ConfirmManualReviewOperationIds $confirmations
    Assert-True ($confirmedDry.ExitCode -eq 0 -and $confirmedDry.Json.ok -eq $true) `
        "in-flight-manual-review: 确认后必须放行：$($confirmedDry.Text)"
    Assert-True (@($confirmedDry.Json.inFlight.blocking).Count -eq 0 -and
        @($confirmedDry.Json.inFlight.confirmedManualReview).Count -eq 1 -and
        [string]@($confirmedDry.Json.inFlight.confirmedManualReview)[0] -ceq $reviewRecord.OperationId -and
        @($confirmedDry.Json.inFlight.unmatchedConfirmations).Count -eq 1 -and
        [string]@($confirmedDry.Json.inFlight.unmatchedConfirmations)[0] -ceq 'not-a-record') `
        "in-flight-manual-review: 确认清单与未匹配的确认必须写入输出：$($confirmedDry.Text)"
    $confirmedApply = Invoke-PolicyTool -Scenario $review -Mode 'Apply' -ConfirmManualReviewOperationIds $confirmations `
        -ApprovedCandidatePolicySha256 ([string]$confirmedDry.Json.candidatePolicySha256)
    Assert-True ($confirmedApply.ExitCode -eq 0 -and $confirmedApply.Json.written -eq $true -and
        [string]@($confirmedApply.Json.inFlight.confirmedManualReview)[0] -ceq $reviewRecord.OperationId) `
        "in-flight-manual-review: 确认后 Apply 必须落盘并输出确认清单：$($confirmedApply.Text)"
    Write-Output 'in-flight-manual-review OK'

    # ---- 9. 在途：绑定旧 policy（plan 的 policy SHA 不是现役 SHA）的记录只计数，不阻止 ----
    Write-Output 'STEP in-flight-old-policy'
    $old = New-Scenario -Name 'inflight-old-policy'
    Set-ChangeSet -Scenario $old -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $old.TargetsRoot 'protected') })
    [void](New-FixtureRecord -Scenario $old -Name 'stale')
    # 同一文档改成 CRLF 行尾：语义不变、字节与 SHA 改变，与生产 policy 的混合行尾同类。
    $lfText = Expand-PolicyTemplate -Scenario $old -Template $basePolicyTemplate
    $lfLineCount = $lfText.Split("`n").Count - 1
    [IO.File]::WriteAllBytes($old.PolicyPath, $utf8.GetBytes($lfText.Replace("`n", "`r`n")))
    $oldDry = Invoke-PolicyTool -Scenario $old -Mode 'DryRun'
    Assert-True ($oldDry.ExitCode -eq 0 -and $oldDry.Json.ok -eq $true) "in-flight-old-policy: 旧 policy 记录不得阻止：$($oldDry.Text)"
    Assert-True (@($oldDry.Json.inFlight.blocking).Count -eq 0 -and [long]$oldDry.Json.inFlight.boundToOtherPolicyCount -eq 1) `
        "in-flight-old-policy: 旧 policy 记录必须只计数：$($oldDry.Text)"
    Assert-True ($oldDry.Json.liveFormat.reserializesIdentically -eq $false -and
        [long]$oldDry.Json.liveFormat.crlfLineCount -eq $lfLineCount) `
        "in-flight-old-policy: liveFormat 必须报告 CRLF 行尾：$($oldDry.Text)"
    Write-Output 'in-flight-old-policy OK'

    # ---- 10. gap 1：未归档的 terminal 记录在候选下不再解析时列出，不阻止；已归档与仍可解析的不列 ----
    Write-Output 'STEP terminal-resolution'
    $terminal = New-Scenario -Name 'terminal-resolution'
    $lostRecord = New-FixtureRecord -Scenario $terminal -Name 'lost' -Stage 'purged'
    $archivedRecord = New-FixtureRecord -Scenario $terminal -Name 'archived' -Stage 'purged'
    $archive = & $entryPath -Mode Archive -TransactionPath $archivedRecord.TransactionPath `
        -ApprovedTransactionSha256 $archivedRecord.TransactionSha256 -ConfirmArchive `
        -FixturePolicyPath $terminal.PolicyPath -FixtureEvidenceRoot $terminal.EvidenceRoot
    Assert-True ($archive.archived -eq $true) 'archived 夹具 Archive 必须成功'
    [void](New-FixtureRecord -Scenario $terminal -Name 'kept' -Stage 'purged')
    Set-ChangeSet -Scenario $terminal -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $terminal.TargetsRoot 'lost') },
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $terminal.TargetsRoot 'archived') })
    $terminalDry = Invoke-PolicyTool -Scenario $terminal -Mode 'DryRun'
    Assert-True ($terminalDry.ExitCode -eq 0 -and $terminalDry.Json.ok -eq $true -and
        @($terminalDry.Json.inFlight.blocking).Count -eq 0) "terminal-resolution: terminal 记录不得阻止：$($terminalDry.Text)"
    $lostRows = @($terminalDry.Json.inFlight.terminalRecordsLosingResolution)
    Assert-True ($lostRows.Count -eq 1 -and
        [string]$lostRows[0].operationId -ceq $lostRecord.OperationId -and
        [string]$lostRows[0].refusalReason -ceq 'target-denied') `
        "terminal-resolution: 只列出未归档且在候选下不再解析的 terminal 记录：$($terminalDry.Text)"
    Write-Output 'terminal-resolution OK'

    # ---- 11. retire-entry：整条移除；现役违例随条目消失时列入 resolvedViolations ----
    Write-Output 'STEP op-retire-entry'
    $retire = New-Scenario -Name 'op-retire-entry'
    Set-ChangeSet -Scenario $retire -Changes @([pscustomobject][ordered]@{ op = 'retire-entry'; entryId = 'fixture-spare' })
    $retireDry = Invoke-PolicyTool -Scenario $retire -Mode 'DryRun'
    Assert-True ($retireDry.ExitCode -eq 0 -and $retireDry.Json.ok -eq $true) "op-retire-entry: 必须放行：$($retireDry.Text)"
    Assert-True ([string]$retireDry.Json.candidatePolicySha256 -ceq (Get-Sha256Hex -Bytes $utf8.GetBytes(
                (Expand-PolicyTemplate -Scenario $retire -Template $retireEntryPolicyTemplate)))) `
        "op-retire-entry: 候选必须等于手写期望：$($retireDry.Text)"
    Assert-True ([long]$retireDry.Json.entryCount.before -eq 2 -and [long]$retireDry.Json.entryCount.after -eq 1) `
        'op-retire-entry: entryCount 必须为 2 -> 1'
    $resolved = @($retireDry.Json.structure.resolvedViolations)
    Assert-True ($resolved.Count -eq 1 -and [string]$resolved[0].entryId -ceq 'fixture-spare') `
        "op-retire-entry: 随条目消失的违例必须列入 resolvedViolations：$($retireDry.Text)"
    $retireChanges = (@($retireDry.Json.changes) | ForEach-Object { '{0}:{1}' -f $_.op, $_.entryId }) -join ','
    Assert-True ($retireChanges -ceq 'retire-entry:fixture-spare') "op-retire-entry: changes 摘要不符：$($retireDry.Text)"
    Write-Output 'op-retire-entry OK'

    # ---- 12. remove-deny：按路径（Windows 路径不区分大小写）精确移除一条 deny ----
    Write-Output 'STEP op-remove-deny'
    $removeDeny = New-Scenario -Name 'op-remove-deny'
    Set-ChangeSet -Scenario $removeDeny -Changes @(
        [pscustomobject][ordered]@{ op = 'remove-deny'; entryId = 'fixture-main'; path = (Join-Path $removeDeny.TargetsRoot 'KEEP') })
    $removeDenyDry = Invoke-PolicyTool -Scenario $removeDeny -Mode 'DryRun'
    Assert-True ($removeDenyDry.ExitCode -eq 0 -and $removeDenyDry.Json.ok -eq $true) "op-remove-deny: 必须放行：$($removeDenyDry.Text)"
    Assert-True ([string]$removeDenyDry.Json.candidatePolicySha256 -ceq (Get-Sha256Hex -Bytes $utf8.GetBytes(
                (Expand-PolicyTemplate -Scenario $removeDeny -Template $removeDenyPolicyTemplate)))) `
        "op-remove-deny: 候选必须等于手写期望：$($removeDenyDry.Text)"
    Write-Output 'op-remove-deny OK'

    # ---- 13. add-entry：新条目追加在末尾，属性按仓库 policy 的顺序重排；SafeCleanupJob 视角只是新增 ----
    Write-Output 'STEP op-add-entry'
    $addEntry = New-Scenario -Name 'op-add-entry'
    Set-ChangeSet -Scenario $addEntry -Changes @([pscustomobject][ordered]@{
            op = 'add-entry'
            entry = [pscustomobject][ordered]@{
                deniedExactPaths = @((Join-Path $addEntry.ExtraRoot 'a'))
                rootDeletionPurpose = 'none'
                minimumDescendantDepth = 1
                capabilityRoot = $addEntry.ExtraRoot
                id = 'fixture-extra'
            }
        })
    $addEntryDry = Invoke-PolicyTool -Scenario $addEntry -Mode 'DryRun'
    Assert-True ($addEntryDry.ExitCode -eq 0 -and $addEntryDry.Json.ok -eq $true) "op-add-entry: 必须放行：$($addEntryDry.Text)"
    Assert-True ([string]$addEntryDry.Json.candidatePolicySha256 -ceq (Get-Sha256Hex -Bytes $utf8.GetBytes(
                (Expand-PolicyTemplate -Scenario $addEntry -Template $addEntryPolicyTemplate)))) `
        "op-add-entry: 候选必须等于手写期望：$($addEntryDry.Text)"
    $addEntryJob = $addEntryDry.Json.safeCleanupJob
    Assert-True (@($addEntryJob.changedExistingEntryIds).Count -eq 0 -and @($addEntryJob.addedEntryIds).Count -eq 1 -and
        [string]@($addEntryJob.addedEntryIds)[0] -ceq 'fixture-extra') "op-add-entry: SafeCleanupJob 视角必须只是新增：$($addEntryDry.Text)"
    Write-Output 'op-add-entry OK'

    # ---- 14. 拒绝：变更集非法、候选无法加载、候选新增结构违例；每种都不写任何文件 ----
    Write-Output 'STEP refusals'
    $refuse = New-Scenario -Name 'refusals'
    $protectedPath = Join-Path $refuse.TargetsRoot 'protected'
    $refusalCases = @(
        @{ label = 'unknown-op'; reason = 'change-set-invalid'; message = 'op 非法'
            changes = @([pscustomobject][ordered]@{ op = 'rename-entry'; entryId = 'fixture-main' }) },
        @{ label = 'missing-entry'; reason = 'change-set-invalid'; message = '引用的条目不存在'
            changes = @([pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'no-such-entry'; path = $protectedPath }) },
        @{ label = 'duplicate-deny'; reason = 'change-set-invalid'; message = 'deny 已存在于条目'
            changes = @([pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $refuse.TargetsRoot 'keep') }) },
        @{ label = 'non-canonical-path'; reason = 'change-set-invalid'; message = '必须是规范绝对路径'
            changes = @([pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $refuse.TargetsRoot 'sub\..\protected') }) },
        @{ label = 'remove-missing-deny'; reason = 'change-set-invalid'; message = '恰好匹配一条'
            changes = @([pscustomobject][ordered]@{ op = 'remove-deny'; entryId = 'fixture-main'; path = $protectedPath }) },
        @{ label = 'add-entry-duplicate-root'; reason = 'change-set-invalid'; message = 'capabilityRoot 与条目'
            changes = @([pscustomobject][ordered]@{ op = 'add-entry'; entry = [pscustomobject][ordered]@{
                        id = 'fixture-copy'; capabilityRoot = $refuse.TargetsRoot; minimumDescendantDepth = 1
                        rootDeletionPurpose = 'none'; deniedExactPaths = @() } }) },
        @{ label = 'retire-all-entries'; reason = 'candidate-policy-invalid'; message = 'policy 不得为空'
            changes = @(
                [pscustomobject][ordered]@{ op = 'retire-entry'; entryId = 'fixture-main' },
                [pscustomobject][ordered]@{ op = 'retire-entry'; entryId = 'fixture-spare' }) },
        @{ label = 'add-entry-invalid-field'; reason = 'candidate-policy-invalid'; message = 'rootDeletionPurpose 非法'
            changes = @([pscustomobject][ordered]@{ op = 'add-entry'; entry = [pscustomobject][ordered]@{
                        id = 'fixture-extra'; capabilityRoot = $refuse.ExtraRoot; minimumDescendantDepth = 1
                        rootDeletionPurpose = 'bogus'; deniedExactPaths = @() } }) },
        @{ label = 'deny-deeper-than-minimum-depth'; reason = 'candidate-adds-structure-violations'; message = 'structure.newViolations'
            changes = @([pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $refuse.TargetsRoot 'a\b') }) }
    )
    foreach ($case in $refusalCases) {
        Set-ChangeSet -Scenario $refuse -Changes $case.changes
        $caseBefore = Get-TreeState -Path $refuse.Root
        $caseResult = Invoke-PolicyTool -Scenario $refuse -Mode 'DryRun'
        Assert-Refusal -Result $caseResult -RefusalReason $case.reason -Label "refusals-$($case.label)"
        Assert-True (([string]$caseResult.Json.message).Contains([string]$case.message)) `
            "refusals-$($case.label): message 必须说明拒绝原因（含 '$($case.message)'）：$($caseResult.Json.message)"
        Assert-True ((Get-TreeState -Path $refuse.Root) -ceq $caseBefore) "refusals-$($case.label): 拒绝后场景目录必须零写入"
    }
    $structureResult = $caseResult
    $newViolations = @($structureResult.Json.structure.newViolations)
    Assert-True ($newViolations.Count -eq 1 -and [string]$newViolations[0].rule -ceq 'deny-deeper-than-minimum-depth' -and
        [string]$newViolations[0].entryId -ceq 'fixture-main') "refusals: 新增违例必须列入 structure.newViolations：$($structureResult.Text)"
    Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($refuse.PolicyPath),
            [byte[]]$utf8.GetBytes((Expand-PolicyTemplate -Scenario $refuse -Template $basePolicyTemplate)))) 'refusals: policy 必须保持原字节'
    Write-Output 'refusals OK'

    # ---- 15. 等锁超时：本测试进程作为另一持锁者（面包屑 mode=Purge）持有同名 mutex，工具在子进程里
    # 等满测试上限后 exit 1 并报告持锁者；持锁者的面包屑与场景目录零写入 ----
    Write-Output 'STEP gate-timeout'
    $gate = New-Scenario -Name 'gate-timeout'
    Set-ChangeSet -Scenario $gate -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $gate.TargetsRoot 'protected') })
    $heldMutex = [Threading.Mutex]::new($false, ('{0}-u-{1}' -f $gate.MutexName, $sidSuffix))
    $mutexHeld = $false
    try {
        $mutexHeld = $heldMutex.WaitOne([TimeSpan]::FromSeconds(30))
        Assert-True $mutexHeld 'gate-timeout: 测试进程必须先取得同名 mutex'
        Assert-True (Write-CodexSafeTreeDeleteGateHolder -StateRoot $gate.StateRoot -Mode 'Purge') 'gate-timeout: 持锁者面包屑必须写成'
        $gateBefore = Get-TreeState -Path $gate.Root
        $waiter = Start-ChildPwsh -File $toolPath -Arguments @(
            '-Mode', 'DryRun', '-ChangeSetPath', $gate.ChangeSetPath,
            '-PolicyPathForTest', $gate.PolicyPath, '-EvidenceRootForTest', $gate.EvidenceRoot,
            '-MutexNameForTest', $gate.MutexName, '-MarkerPathForTest', $gate.MarkerPath,
            '-GateWaitSecondsForTest', '2')
        $waited = Complete-ChildPwsh -Call $waiter
        $waitedText = "$($waited.Stdout)$($waited.Stderr)"
        Assert-True ($waited.ExitCode -eq 1) "gate-timeout: 等锁超时必须 exit 1（实际 $($waited.ExitCode)）：$waitedText"
        Assert-True ($waited.Stdout -cmatch '\A[\x00-\x7F]+\z') "gate-timeout: stdout 必须 ASCII-only：$waitedText"
        $waitedJson = $waited.Stdout.Trim() | ConvertFrom-Json -DateKind String
        Assert-True ($waitedJson.ok -eq $false -and [string]$waitedJson.refusalReason -ceq 'deployment-mutex-acquire-timeout') `
            "gate-timeout: refusalReason 必须为 deployment-mutex-acquire-timeout：$waitedText"
        $holder = $waitedJson.holder
        Assert-True ($null -ne $holder -and [int]$holder.pid -eq $PID -and [string]$holder.mode -ceq 'Purge' -and
            $holder.stale -eq $false) "gate-timeout: holder 必须报告存活的持锁者（本测试进程、mode=Purge）：$waitedText"
        Assert-True ((Get-TreeState -Path $gate.Root) -ceq $gateBefore) 'gate-timeout: 等锁方不得改动持锁者面包屑或场景目录'
    } finally {
        Remove-CodexSafeTreeDeleteGateHolder -StateRoot $gate.StateRoot
        if ($mutexHeld) { $heldMutex.ReleaseMutex() }
        $heldMutex.Dispose()
    }
    Write-Output 'gate-timeout OK'

    # ---- 16. 持锁面包屑：工具持锁期间在 state root 留 mode=policy-maintenance、pid=工具进程的面包屑，
    # 释放锁前删除。工具在子进程里运行，在阶段 10（已取锁、已写面包屑）暂停：暂停期间读面包屑，并以
    # 同名 mutex 仍被占用证明工具持锁，再放行 ----
    Write-Output 'STEP breadcrumb'
    $crumb = New-Scenario -Name 'breadcrumb'
    Set-ChangeSet -Scenario $crumb -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $crumb.TargetsRoot 'protected') })
    $crumbSignals = Join-Path $crumb.Root 'signals'
    $crumbCall = Start-PausedPolicyTool -Scenario $crumb -Mode 'DryRun' -PauseAfterPhase 10 -SignalDirectory $crumbSignals -Label 'breadcrumb'
    $crumbPath = Join-Path $crumb.StateRoot 'gate-holder.json'
    Assert-True ([IO.File]::Exists($crumbPath)) 'breadcrumb: 工具持锁期间必须写面包屑'
    $observedText = [IO.File]::ReadAllText($crumbPath)
    Assert-True (-not (Test-GateMutexFree -BaseName $crumb.MutexName)) 'breadcrumb: 暂停期间工具必须仍持有 deployment mutex'
    $crumbResult = Resume-PausedPolicyTool -Call $crumbCall -SignalDirectory $crumbSignals
    Assert-True ($crumbResult.ExitCode -eq 0 -and $crumbResult.Json.ok -eq $true) `
        "breadcrumb: DryRun 必须成功：$($crumbResult.Text)$($crumbResult.Stderr)"
    $observed = $observedText | ConvertFrom-Json -DateKind String
    Assert-True ([string]$observed.mode -ceq 'policy-maintenance' -and [int]$observed.pid -eq $crumbCall.Process.Id) `
        "breadcrumb: 面包屑必须是 mode=policy-maintenance 且 pid 为工具进程：$observedText"
    Assert-True (@([IO.Directory]::GetFileSystemEntries($crumb.StateRoot)).Count -eq 0) 'breadcrumb: 释放锁前必须删除面包屑'
    Assert-True (Test-GateMutexFree -BaseName $crumb.MutexName) 'breadcrumb: 工具退出后 mutex 必须已释放'
    Write-Output 'breadcrumb OK'

    # ---- 17. 脚本主体里的任何失败都输出那一行 JSON：参数检查（取锁之前）拒绝为 invalid-arguments，持锁后的
    # 意外异常为 unexpected-error；都 exit 1，场景目录零写入。参数绑定错误不经脚本主体，不在此列 ----
    Write-Output 'STEP failure-json'
    $failure = New-Scenario -Name 'failure-json'
    Set-ChangeSet -Scenario $failure -Changes @(
        [pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $failure.TargetsRoot 'protected') })
    $failureBefore = Get-TreeState -Path $failure.Root
    $argumentCases = @(
        @{ label = 'apply-without-sha'; mode = 'Apply'; sha = $null; ids = @(); extra = @{} },
        @{ label = 'dry-run-with-sha'; mode = 'DryRun'; sha = ('0' * 64); ids = @(); extra = @{} },
        @{ label = 'illegal-operation-id'; mode = 'DryRun'; sha = $null; ids = @('not an id'); extra = @{} },
        @{ label = 'pause-without-signal-directory'; mode = 'DryRun'; sha = $null; ids = @()
            extra = @{ PauseAfterPhaseForTest = 10 } }
    )
    foreach ($case in $argumentCases) {
        $caseResult = Invoke-PolicyTool -Scenario $failure -Mode $case.mode -ApprovedCandidatePolicySha256 $case.sha `
            -ConfirmManualReviewOperationIds $case.ids -ExtraArguments $case.extra
        Assert-Refusal -Result $caseResult -RefusalReason 'invalid-arguments' -Label "failure-json-$($case.label)"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$caseResult.Json.message)) `
            "failure-json-$($case.label): message 必须说明哪个参数不合法：$($caseResult.Text)"
        Assert-True ((Get-TreeState -Path $failure.Root) -ceq $failureBefore) `
            "failure-json-$($case.label): 参数拒绝发生在取锁之前，场景目录必须零写入"
    }
    # 持锁后的意外失败：暂停 seam 的信号目录不存在，写 paused-10 时抛出 .NET 异常。
    $unexpected = Invoke-PolicyTool -Scenario $failure -Mode 'DryRun' -ExtraArguments @{
        PauseAfterPhaseForTest = 10
        PauseSignalDirectoryForTest = (Join-Path $failure.Root 'no-such-signals')
    }
    Assert-Refusal -Result $unexpected -RefusalReason 'unexpected-error' -Label 'failure-json-unexpected'
    Assert-True ((Get-TreeState -Path $failure.Root) -ceq $failureBefore) `
        'failure-json-unexpected: 场景目录必须零写入（面包屑已删除）'
    Write-Output 'failure-json OK'

    # ---- 18. 输出不回显路径：错误文本里带路径的失败（参数值、变更集与现役 policy 的校验信息、.NET 异常
    # 文本）拒绝时 message 只保留规则含义，原始 JSON 里没有盘符路径 ----
    Write-Output 'STEP no-path-output'
    $noPath = New-Scenario -Name 'no-path-output'
    $wildcardPath = Join-Path $noPath.TargetsRoot 'k*eep'
    $pathCases = @(
        @{ label = 'operation-id-path'; reason = 'invalid-arguments'; message = 'operation id'
            invoke = { Invoke-PolicyTool -Scenario $noPath -Mode 'DryRun' -ConfirmManualReviewOperationIds @($noPath.TargetsRoot) } },
        @{ label = 'approved-sha-path'; reason = 'invalid-arguments'; message = 'candidatePolicySha256'
            invoke = { Invoke-PolicyTool -Scenario $noPath -Mode 'Apply' -ApprovedCandidatePolicySha256 $noPath.TargetsRoot } },
        @{ label = 'change-set-path'; reason = 'change-set-invalid'; message = '通配符'
            changes = @([pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = $wildcardPath }) },
        @{ label = 'live-policy-path'; reason = 'live-policy-invalid'; message = '通配符'; corruptLivePolicy = $true },
        @{ label = 'exception-text-path'; reason = 'unexpected-error'; message = '<path>'
            invoke = { Invoke-PolicyTool -Scenario $noPath -Mode 'DryRun' -ExtraArguments @{
                    PauseAfterPhaseForTest = 10
                    PauseSignalDirectoryForTest = (Join-Path $noPath.Root 'no-such-signals') } } }
    )
    foreach ($case in $pathCases) {
        $changes = if ($case.ContainsKey('changes')) { $case.changes } else {
            @([pscustomobject][ordered]@{ op = 'add-deny'; entryId = 'fixture-main'; path = (Join-Path $noPath.TargetsRoot 'protected') })
        }
        Set-ChangeSet -Scenario $noPath -Changes $changes
        $livePolicyTemplate = if ($case.ContainsKey('corruptLivePolicy')) {
            $basePolicyTemplate.Replace('"{TARGETS}\\keep"', '"{TARGETS}\\k*eep"')
        } else {
            $basePolicyTemplate
        }
        [IO.File]::WriteAllBytes($noPath.PolicyPath, $utf8.GetBytes((Expand-PolicyTemplate -Scenario $noPath -Template $livePolicyTemplate)))
        $caseResult = if ($case.ContainsKey('invoke')) { & $case.invoke } else { Invoke-PolicyTool -Scenario $noPath -Mode 'DryRun' }
        Assert-Refusal -Result $caseResult -RefusalReason $case.reason -Label "no-path-$($case.label)"
        Assert-True (([string]$caseResult.Json.message).Contains([string]$case.message)) `
            "no-path-$($case.label): message 必须保留规则含义（含 '$($case.message)'）：$($caseResult.Json.message)"
        # JSON 里的反斜杠转义为 \\；worktree 路径的非 ASCII 段按 EscapeNonAscii 转义，另用 scratch 根的 ASCII 叶名作针。
        Assert-True ($caseResult.Text -notmatch '(?i)(?<![a-z0-9])[a-z]:(\\\\|/)' -and
            $caseResult.Text.IndexOf((Split-Path -Leaf $scratchRoot), [StringComparison]::OrdinalIgnoreCase) -lt 0) `
            "no-path-$($case.label): 输出不得包含路径：$($caseResult.Text)"
    }
    Write-Output 'no-path-output OK'

    Write-Output 'POLICY-MAINTENANCE-TESTS OK'
} finally {
    foreach ($call in $childProcesses) {
        try {
            if (-not $call.Process.HasExited) { $call.Process.Kill($true) }
            $call.Process.WaitForExit()
        } catch { }
    }
    Remove-TestTree -Path $scratchRoot
}
