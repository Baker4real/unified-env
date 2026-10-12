[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #81，spec #73「Check 模式」):
# 唯一接缝：fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 Check mode，对照同一目标、同一
# CapabilityRoot 下的 Plan。只观察 Check 的 JSON 结果、Plan 的结果或抛出的拒绝原文，以及 fixture evidence
# 目录树的前后快照。全部 policy、目标与 evidence 都在本套件的 scratch 根下；不读写生产 evidence 根，
# 也不执行生产入口。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'check'

$evidenceRoot = Join-Path $scratchRoot 'evidence'
$policyPath = Join-Path $scratchRoot 'policy.json'
$workspaceRoot = Join-Path $scratchRoot 'workspace'
$candidatePath = Join-Path $workspaceRoot 'candidate'
$deepPath = Join-Path $workspaceRoot 'nested\deep'
$deniedPath = Join-Path $workspaceRoot 'denied'
$realTargetPath = Join-Path $workspaceRoot 'real-target'
$junctionPath = Join-Path $workspaceRoot 'link'
$filePath = Join-Path $workspaceRoot 'file.txt'
$buildOutputRoot = Join-Path $scratchRoot 'build-output'
$retiredEvidenceRoot = Join-Path $scratchRoot 'run-evidence\retired-root'
$outsideRoot = Join-Path $scratchRoot 'outside'
$strayPath = Join-Path $outsideRoot 'stray'

$nestRoot = Join-Path $scratchRoot 'nest'
$nestInnerRoot = Join-Path $nestRoot 'inner'
$nestLeafPath = Join-Path $nestInnerRoot 'leaf'
$ambiguousPolicyPath = Join-Path $scratchRoot 'nested-ambiguous-policy.json'
$coveredPolicyPath = Join-Path $scratchRoot 'nested-covered-policy.json'

$topLevelFields = @('allowed', 'targetCount', 'results')
$rowFields = @('targetPath', 'allowed', 'policyEntryId', 'capabilityRoot', 'depth', 'refusalReason', 'refusalMessage')
$candidateFields = @('policyEntryId', 'capabilityRoot', 'allowed', 'depth', 'refusalReason', 'refusalMessage')
$noCapabilityRootMessage = 'safe-delete target 没有能合法覆盖它的 capability root。'
$ambiguousCapabilityRootMessage = 'safe-delete target 有多条能合法覆盖它的 capability root，须显式指定 CapabilityRoot。'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-PolicyFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Entries)

    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @($Entries)
    }
    Write-Utf8File -Path $Path -Text ($policy | ConvertTo-Json -Depth 10)
}

function New-PolicyEntry {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][long]$MinimumDepth,
        [string]$Purpose = 'none',
        [string[]]$Denied = @(),
        [switch]$AllowHardLinks
    )

    $entry = [ordered]@{
        id = $Id
        capabilityRoot = $Root
        minimumDescendantDepth = $MinimumDepth
        rootDeletionPurpose = $Purpose
        deniedExactPaths = @($Denied)
    }
    if ($AllowHardLinks) { $entry.allowHardLinks = $true }
    return [pscustomobject]$entry
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete check test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete check test cleanup'
}

function Get-EvidenceSnapshot {
    # evidence 目录树的完整快照：相对路径、类型、目录与文件的 LastWriteTimeUtc、文件长度与 SHA-256。
    if (-not [IO.Directory]::Exists($evidenceRoot)) {
        if ([IO.File]::Exists($evidenceRoot)) { return '<file>' }
        return '<absent>'
    }
    $root = [IO.DirectoryInfo]::new($evidenceRoot)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(('.|dir|{0}' -f $root.LastWriteTimeUtc.Ticks))
    foreach ($item in $root.EnumerateFileSystemInfos('*', [IO.SearchOption]::AllDirectories)) {
        $relative = [IO.Path]::GetRelativePath($evidenceRoot, $item.FullName)
        if ($item -is [IO.FileInfo]) {
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($item.FullName)))
            $lines.Add(('{0}|file|{1}|{2}|{3}' -f $relative, $item.Length, $item.LastWriteTimeUtc.Ticks, $hash))
        } else {
            $lines.Add(('{0}|dir|{1}' -f $relative, $item.LastWriteTimeUtc.Ticks))
        }
    }
    return (@($lines | Sort-Object -CaseSensitive) -join "`n")
}

function Invoke-Check {
    # 经 fixture 入口以 -Json 运行 Check，并断言 evidence 目录树在调用前后逐项相同。
    param(
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$Label
    )

    $before = Get-EvidenceSnapshot
    $output = @(& $entryPath -Mode Check @Arguments -Json -FixturePolicyPath $PolicyPath -FixtureEvidenceRoot $evidenceRoot)
    $after = Get-EvidenceSnapshot
    Assert-True ($after -ceq $before) "$Label：Check 不得改动 evidence 目录树"
    Assert-True ($output.Count -eq 1 -and $output[0] -is [string]) "$Label：Check -Json 必须只输出一行 JSON"
    $result = $output[0] | ConvertFrom-Json -Depth 32
    Assert-True ((@($result.PSObject.Properties.Name) -join ',') -ceq ($topLevelFields -join ',')) (
        "$Label：Check 顶层字段必须为 $($topLevelFields -join ',')，实际 $(@($result.PSObject.Properties.Name) -join ',')")
    return [pscustomobject]@{ json = [string]$output[0]; result = $result }
}

function Invoke-PlanOutcome {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$PolicyPath
    )

    try {
        $plan = & $entryPath `
            -Mode Plan `
            -TargetPath $TargetPath `
            -CapabilityRoot $CapabilityRoot `
            -FixturePolicyPath $PolicyPath `
            -FixtureEvidenceRoot $evidenceRoot
        return [pscustomobject]@{
            planned = [bool]$plan.planned
            targetPath = [string]$plan.targetPath
            policyEntryId = [string]$plan.policyEntryId
            message = $null
        }
    } catch {
        return [pscustomobject]@{
            planned = $false
            targetPath = $null
            policyEntryId = $null
            message = [string]$_.Exception.Message
        }
    }
}

function Assert-Verdict {
    # 逐字段核对一行结果或一个候选：字段名与顺序、allowed 为 bool、字符串字段逐字相等或为 null、depth 为整数或 null。
    param(
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][hashtable]$Expected,
        [Parameter(Mandatory)][string[]]$Fields,
        [Parameter(Mandatory)][string]$Label
    )

    $actualFields = @($Actual.PSObject.Properties.Name) -join ','
    Assert-True ($actualFields -ceq ($Fields -join ',')) "$Label：字段必须为 $($Fields -join ',')，实际 $actualFields"
    Assert-True ($Actual.allowed -is [bool] -and $Actual.allowed -eq [bool]$Expected.allowed) (
        "$Label：allowed 必须为 $($Expected.allowed)，实际 $($Actual.allowed)")
    foreach ($field in @('targetPath', 'policyEntryId', 'capabilityRoot', 'refusalReason', 'refusalMessage')) {
        if ($field -cnotin $Fields) { continue }
        $expectedValue = $Expected[$field]
        $actualValue = $Actual.$field
        if ($null -eq $expectedValue) {
            Assert-True ($null -eq $actualValue) "$Label：$field 必须为 null，实际 $actualValue"
        } else {
            Assert-True ($actualValue -is [string] -and $actualValue -ceq [string]$expectedValue) (
                "$Label：$field 必须为 $expectedValue，实际 $actualValue")
        }
    }
    if ($null -eq $Expected.depth) {
        Assert-True ($null -eq $Actual.depth) "$Label：depth 必须为 null，实际 $($Actual.depth)"
    } else {
        Assert-True ($Actual.depth -is [long] -and $Actual.depth -eq [long]$Expected.depth) (
            "$Label：depth 必须为 $($Expected.depth)，实际 $($Actual.depth)")
    }
}

function Assert-CheckRow {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][hashtable]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    $expectedFields = @($rowFields)
    if ($Expected.ContainsKey('candidates')) { $expectedFields += 'candidates' }
    Assert-Verdict -Actual $Row -Expected $Expected -Fields $expectedFields -Label $Label
    if (-not $Expected.ContainsKey('candidates')) { return }
    $expectedCandidates = @($Expected.candidates)
    $actualCandidates = @($Row.candidates)
    Assert-True ($actualCandidates.Count -eq $expectedCandidates.Count) (
        "$Label：候选必须有 $($expectedCandidates.Count) 个，实际 $($actualCandidates.Count) 个")
    for ($index = 0; $index -lt $expectedCandidates.Count; $index++) {
        Assert-Verdict -Actual $actualCandidates[$index] -Expected $expectedCandidates[$index] -Fields $candidateFields -Label (
            "$Label 候选 #$index")
    }
}

function Get-ExpectedRow {
    param([Parameter(Mandatory)][hashtable]$Case)

    # 用例表是哈希表：缺省的键（放行用例没有 reason/message 等）按 $null 读取。
    $expectedTarget = if ($Case.ContainsKey('expectedTarget')) { $Case['expectedTarget'] } else { $Case['target'] }
    $expectedRoot = if ($Case.ContainsKey('expectedRoot')) { $Case['expectedRoot'] } else { $Case['root'] }
    $expected = @{
        targetPath = $expectedTarget
        allowed = [bool]$Case['allowed']
        policyEntryId = $Case['entry']
        capabilityRoot = $expectedRoot
        depth = $Case['depth']
        refusalReason = $Case['reason']
        refusalMessage = $Case['message']
    }
    if ($Case.ContainsKey('candidates')) {
        $expected.candidates = @($Case['candidates'] | ForEach-Object { Get-ExpectedRow -Case $_ })
    }
    return $expected
}

function Assert-VerdictAgreesWithPlan {
    # 对 Check 给出的一个结论（采用的条目或一个候选），用同一目标、同一 CapabilityRoot 跑 Plan 对照。
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][object]$Verdict,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$Label
    )

    $plan = Invoke-PlanOutcome -TargetPath $TargetPath -CapabilityRoot ([string]$Verdict.capabilityRoot) -PolicyPath $PolicyPath
    if ($Verdict.allowed) {
        Assert-True ($plan.planned -and $null -eq $plan.message) "$Label：Check 放行时 Plan 也必须放行，实际拒绝：$($plan.message)"
        Assert-True ($plan.policyEntryId -ceq [string]$Verdict.policyEntryId) (
            "$Label：Plan 与 Check 的 policyEntryId 必须一致，实际 $($plan.policyEntryId) / $($Verdict.policyEntryId)")
    } else {
        Assert-True (-not $plan.planned -and $plan.message -ceq [string]$Verdict.refusalMessage) (
            "$Label：Plan 必须以原文「$($Verdict.refusalMessage)」拒绝，实际：$($plan.message)")
    }
}

$cleanupError = $null
try {
    # 主 fixture policy：普通后代条目（带一条 deny）、link-aware 深度 0 构建产物根、退役证据根（只允许精确 root）。
    foreach ($directory in @(
            $candidatePath,
            $deepPath,
            (Join-Path $deniedPath 'child'),
            (Join-Path $realTargetPath 'inner'),
            (Join-Path $buildOutputRoot 'child'),
            (Join-Path $retiredEvidenceRoot 'child'),
            $strayPath)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Write-Utf8File -Path (Join-Path $candidatePath 'payload.txt') -Text 'check-candidate'
    Write-Utf8File -Path (Join-Path $deepPath 'payload.txt') -Text 'check-deep'
    Write-Utf8File -Path $filePath -Text 'check-file-target'
    Write-Utf8File -Path (Join-Path $buildOutputRoot 'payload.txt') -Text 'check-build-output'
    Write-Utf8File -Path (Join-Path $retiredEvidenceRoot 'old-run.txt') -Text 'check-retired-evidence'
    Write-Utf8File -Path (Join-Path $nestLeafPath 'payload.txt') -Text 'check-nest-leaf'
    New-Item -ItemType Junction -Path $junctionPath -Target $realTargetPath | Out-Null
    Write-PolicyFile -Path $policyPath -Entries @(
        (New-PolicyEntry -Id 'check-workspace' -Root $workspaceRoot -MinimumDepth 1 -Denied @($deniedPath)),
        (New-PolicyEntry -Id 'check-build-output' -Root $buildOutputRoot -MinimumDepth 0 -Purpose 'rebuildable-build-output' -AllowHardLinks),
        (New-PolicyEntry -Id 'check-retired-evidence' -Root $retiredEvidenceRoot -MinimumDepth 0 -Purpose 'retired-evidence-root')
    )

    # 1. 显式 CapabilityRoot：每个放行与拒绝用例都先跑 Check（evidence 根此时尚不存在），再对同一目标、
    #    同一 CapabilityRoot 跑 Plan，比较放行/拒绝结论与拒绝原因（Check 的 refusalMessage 必须逐字等于
    #    Plan 抛出的原文，原文本身也钉成字面量，保证 Plan 的既有输出不变）。
    $explicitCases = @(
        @{ label = '普通后代'; target = $candidatePath; root = $workspaceRoot; allowed = $true; entry = 'check-workspace'; depth = 1 },
        @{ label = '更深的后代'; target = $deepPath; root = $workspaceRoot; allowed = $true; entry = 'check-workspace'; depth = 2 },
        @{ label = 'link-aware 精确 root'; target = $buildOutputRoot; root = $buildOutputRoot; allowed = $true; entry = 'check-build-output'; depth = 0 },
        @{ label = '退役证据精确 root'; target = $retiredEvidenceRoot; root = $retiredEvidenceRoot; allowed = $true; entry = 'check-retired-evidence'; depth = 0 },
        @{
            label = '目标不是绝对路径'; target = 'relative\candidate'; root = $workspaceRoot; allowed = $false; entry = $null; depth = $null
            reason = 'invalid-target-path'; message = 'safe-delete target 必须是 D 盘绝对路径：relative\candidate'
        },
        @{
            label = 'capability root 不是绝对路径'; target = $candidatePath; root = 'relative-root'; allowed = $false; entry = $null; depth = $null
            reason = 'invalid-capability-root'; message = 'safe-delete capability root 必须是 D 盘绝对路径：relative-root'
        },
        @{
            label = 'capability root 未登记'; target = $strayPath; root = $outsideRoot; allowed = $false; entry = $null; depth = $null
            reason = 'capability-root-not-allowlisted'; message = 'safe-delete capability root 不在受管 allowlist。'
        },
        @{
            label = '目标在 root 之外'; target = $strayPath; root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = $null
            reason = 'target-outside-capability-root'; message = 'safe-delete target 必须位于 capability root 内。'
        },
        @{
            label = '根删除用途的后代'; target = (Join-Path $retiredEvidenceRoot 'child'); root = $retiredEvidenceRoot; allowed = $false
            entry = 'check-retired-evidence'; depth = $null
            reason = 'root-deletion-requires-exact-root'; message = 'safe-delete root 删除用途只允许精确 capability root。'
        },
        @{
            label = 'link-aware 条目的后代'; target = (Join-Path $buildOutputRoot 'child'); root = $buildOutputRoot; allowed = $false
            entry = 'check-build-output'; depth = $null
            reason = 'link-aware-requires-exact-root'; message = 'safe-delete link-aware 能力只允许精确 capability root。'
        },
        @{
            label = '低于最小深度'; target = $workspaceRoot; root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = 0
            reason = 'below-minimum-depth'; message = 'safe-delete target 未达到策略要求的最小后代深度。'
        },
        @{
            label = '等于 deny'; target = $deniedPath; root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = 1
            reason = 'target-denied'; message = 'safe-delete target 命中 denylist。'
        },
        @{
            label = '位于 deny 之内'; target = (Join-Path $deniedPath 'child'); root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = 2
            reason = 'target-denied'; message = 'safe-delete target 命中 denylist。'
        },
        @{
            label = '目标本身是 junction'; target = $junctionPath; root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = 1
            reason = 'capability-path-refused'; message = 'safe-delete target 祖先或 final path 包含 reparse point。'
        },
        @{
            label = '祖先是 junction'; target = (Join-Path $junctionPath 'inner'); root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = 2
            reason = 'capability-path-refused'; message = 'safe-delete target 祖先或 final path 包含 reparse point。'
        },
        @{
            label = '目标不存在'; target = (Join-Path $workspaceRoot 'missing'); root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = 1
            reason = 'target-not-existing-directory'; message = 'safe-delete target 必须是现存普通目录。'
        },
        @{
            label = '目标是文件'; target = $filePath; root = $workspaceRoot; allowed = $false; entry = 'check-workspace'; depth = 1
            reason = 'target-not-existing-directory'; message = 'safe-delete target 必须是现存普通目录。'
        }
    )
    $explicitRows = @{}
    foreach ($case in $explicitCases) {
        $check = Invoke-Check -PolicyPath $policyPath -Label $case.label -Arguments @{
            TargetPath = $case.target
            CapabilityRoot = $case.root
        }
        Assert-True ($check.result.allowed -eq [bool]$case.allowed -and $check.result.targetCount -eq 1) (
            "$($case.label)：Check 顶层 allowed/targetCount 不符：$($check.json)")
        Assert-True (@($check.result.results).Count -eq 1) "$($case.label)：单目标 Check 必须恰好返回一行结果"
        Assert-CheckRow -Row @($check.result.results)[0] -Expected (Get-ExpectedRow -Case $case) -Label $case.label
        $explicitRows[$case.label] = $check.json
    }
    Assert-True ((Get-EvidenceSnapshot) -ceq '<absent>') 'Check 不得创建 evidence 根或 run 目录'

    foreach ($case in $explicitCases) {
        $plan = Invoke-PlanOutcome -TargetPath $case.target -CapabilityRoot $case.root -PolicyPath $policyPath
        if ($case.allowed) {
            Assert-True ($plan.planned -and $null -eq $plan.message) "$($case.label)：Check 放行时 Plan 也必须放行，实际拒绝：$($plan.message)"
            Assert-True ($plan.policyEntryId -ceq $case.entry -and $plan.targetPath -ceq $case.target) (
                "$($case.label)：Plan 与 Check 的 policyEntryId/targetPath 必须一致，实际 $($plan.policyEntryId) $($plan.targetPath)")
        } else {
            Assert-True (-not $plan.planned -and $plan.message -ceq $case.message) (
                "$($case.label)：Plan 必须以原文「$($case.message)」拒绝，实际：$($plan.message)")
        }
    }
    Assert-True ((Get-EvidenceSnapshot) -cne '<absent>') '放行用例的 Plan 必须已写出 evidence（快照对照的前提）'

    # 2. evidence 根已有 Plan 写出的 run 目录时再跑一遍：Check 仍不改动 evidence，结果也与第一遍逐字节相同。
    foreach ($case in $explicitCases) {
        $check = Invoke-Check -PolicyPath $policyPath -Label "$($case.label)（evidence 已有内容）" -Arguments @{
            TargetPath = $case.target
            CapabilityRoot = $case.root
        }
        Assert-True ($check.json -ceq $explicitRows[$case.label]) (
            "$($case.label)：Check 结果不得随 evidence 内容变化：$($check.json) / $($explicitRows[$case.label])")
    }

    # 3. 省略 CapabilityRoot：对每条条目运行同一判定，root 包含目标的条目是候选；候选中恰好一条放行才采用，
    #    否则拒绝并列出全部候选及各自的判定。嵌套 root 用两份 policy：父条目没有 deny 覆盖子 root 时两条都
    #    能合法覆盖子 root 下的目标（歧义）；父条目 deny 精确等于子 root 时只有子条目合法（唯一）。
    Write-PolicyFile -Path $ambiguousPolicyPath -Entries @(
        (New-PolicyEntry -Id 'check-outer' -Root $nestRoot -MinimumDepth 1),
        (New-PolicyEntry -Id 'check-inner' -Root $nestInnerRoot -MinimumDepth 1)
    )
    Write-PolicyFile -Path $coveredPolicyPath -Entries @(
        (New-PolicyEntry -Id 'check-outer' -Root $nestRoot -MinimumDepth 1 -Denied @($nestInnerRoot)),
        (New-PolicyEntry -Id 'check-inner' -Root $nestInnerRoot -MinimumDepth 1)
    )
    $autoCases = @(
        @{ label = '自动解析唯一：后代'; target = $candidatePath; allowed = $true; entry = 'check-workspace'; expectedRoot = $workspaceRoot; depth = 1 },
        @{ label = '自动解析唯一：精确 root'; target = $buildOutputRoot; allowed = $true; entry = 'check-build-output'; expectedRoot = $buildOutputRoot; depth = 0 },
        @{
            label = '自动解析唯一：父条目 deny 精确覆盖子 root'; policy = $coveredPolicyPath; target = $nestLeafPath; allowed = $true
            entry = 'check-inner'; expectedRoot = $nestInnerRoot; depth = 1
        },
        @{
            label = '自动解析零匹配：没有条目包含目标'; target = $strayPath; allowed = $false; entry = $null; expectedRoot = $null; depth = $null
            reason = 'no-capability-root'; message = $noCapabilityRootMessage; candidates = @()
        },
        @{
            label = '自动解析零匹配：包含目标的条目拒绝'; target = $workspaceRoot; allowed = $false; entry = $null; expectedRoot = $null; depth = $null
            reason = 'no-capability-root'; message = $noCapabilityRootMessage; candidates = @(
                @{
                    entry = 'check-workspace'; root = $workspaceRoot; allowed = $false; depth = 0
                    reason = 'below-minimum-depth'; message = 'safe-delete target 未达到策略要求的最小后代深度。'
                }
            )
        },
        @{
            label = '自动解析歧义：父条目未 deny 子 root'; policy = $ambiguousPolicyPath; target = $nestLeafPath; allowed = $false
            entry = $null; expectedRoot = $null; depth = $null
            reason = 'ambiguous-capability-root'; message = $ambiguousCapabilityRootMessage; candidates = @(
                @{ entry = 'check-outer'; root = $nestRoot; allowed = $true; depth = 2 },
                @{ entry = 'check-inner'; root = $nestInnerRoot; allowed = $true; depth = 1 }
            )
        },
        @{
            label = '自动解析：目标不是绝对路径'; target = 'relative\candidate'; allowed = $false; entry = $null; expectedRoot = $null; depth = $null
            reason = 'invalid-target-path'; message = 'safe-delete target 必须是 D 盘绝对路径：relative\candidate'
        }
    )
    $autoRows = @{}
    foreach ($case in $autoCases) {
        $casePolicyPath = if ($case.ContainsKey('policy')) { $case['policy'] } else { $policyPath }
        $check = Invoke-Check -PolicyPath $casePolicyPath -Label $case.label -Arguments @{ TargetPath = $case.target }
        $autoRows[$case.label] = $check.json
        Assert-True ($check.result.allowed -eq [bool]$case.allowed -and $check.result.targetCount -eq 1) (
            "$($case.label)：Check 顶层 allowed/targetCount 不符：$($check.json)")
        $row = @($check.result.results)[0]
        Assert-CheckRow -Row $row -Expected (Get-ExpectedRow -Case $case) -Label $case.label
        # 自动解析的每个结论（采用的条目或每个候选）都必须与同一 CapabilityRoot 下的 Plan 一致。
        $verdicts = if ($case.ContainsKey('candidates')) { @($row.candidates) } elseif ($row.allowed) { @($row) } else { @() }
        foreach ($verdict in $verdicts) {
            Assert-VerdictAgreesWithPlan -TargetPath $case.target -Verdict $verdict -PolicyPath $casePolicyPath -Label (
                "$($case.label)（$($verdict.policyEntryId)）")
        }
    }

    # 4. 多目标：TargetPaths 按输入顺序逐个返回，每行与该目标单独 Check 的结果相同；顶层 allowed 只在全部放行时
    #    为 true。宿主 .cmd 链只能传单个字符串，'::' 连接的形式与数组形式结果逐字节相同。
    $multiCases = @(
        @{
            label = '多目标（显式 root）'; arguments = @{ TargetPaths = @($candidatePath, $strayPath, $deepPath); CapabilityRoot = $workspaceRoot }
            joined = @{ TargetPaths = @("$candidatePath::$strayPath::$deepPath"); CapabilityRoot = $workspaceRoot }
            allowed = $false; rows = @($explicitRows['普通后代'], $explicitRows['目标在 root 之外'], $explicitRows['更深的后代'])
        },
        @{
            label = '多目标（自动解析）'; arguments = @{ TargetPaths = @($candidatePath, $buildOutputRoot) }
            joined = @{ TargetPaths = @("$candidatePath::$buildOutputRoot") }
            allowed = $true; rows = @($autoRows['自动解析唯一：后代'], $autoRows['自动解析唯一：精确 root'])
        }
    )
    foreach ($case in $multiCases) {
        $check = Invoke-Check -PolicyPath $policyPath -Label $case.label -Arguments $case.arguments
        Assert-True ($check.result.allowed -eq [bool]$case.allowed -and $check.result.targetCount -eq $case.rows.Count) (
            "$($case.label)：Check 顶层 allowed/targetCount 不符：$($check.json)")
        $actualRows = @($check.result.results | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
        $expectedRows = @($case.rows | ForEach-Object { @(($_ | ConvertFrom-Json -Depth 32).results)[0] | ConvertTo-Json -Depth 12 -Compress })
        Assert-True (($actualRows -join "`n") -ceq ($expectedRows -join "`n")) (
            "$($case.label)：每行必须按输入顺序等于单目标结果：$($check.json)")
        $joined = Invoke-Check -PolicyPath $policyPath -Label "$($case.label)（'::' 连接）" -Arguments $case.joined
        Assert-True ($joined.json -ceq $check.json) "$($case.label)：'::' 连接形式必须与数组形式结果相同：$($joined.json)"
    }

    # 5. 用法错误：TargetPath 与 TargetPaths 必须恰好给一个且不含空白目标，否则在读取 policy 之前以固定的校验
    #    错误普通 throw（与其他 mode 的参数校验一致）。policy 路径故意不存在，证明错误早于读取 policy。
    $usageMessage = 'Check 模式要求 TargetPath 或 TargetPaths（二者择一）。'
    $missingPolicyPath = Join-Path $scratchRoot 'missing-policy.json'
    $usageCases = @(
        @{ label = '两者都缺'; arguments = @{} },
        @{ label = '两者都给'; arguments = @{ TargetPath = $candidatePath; TargetPaths = @($deepPath) } },
        @{ label = 'TargetPath 为空白'; arguments = @{ TargetPath = ' '; CapabilityRoot = $workspaceRoot } },
        @{ label = 'TargetPaths 含空白目标'; arguments = @{ TargetPaths = @($candidatePath, ' ') } },
        @{ label = "TargetPaths 拆开后为空"; arguments = @{ TargetPaths = @('::') } }
    )
    foreach ($case in $usageCases) {
        $before = Get-EvidenceSnapshot
        $arguments = $case.arguments
        $usageError = $null
        try {
            & $entryPath -Mode Check @arguments -Json -FixturePolicyPath $missingPolicyPath -FixtureEvidenceRoot $evidenceRoot | Out-Null
        } catch {
            $usageError = $_
        }
        Assert-True ($null -ne $usageError) "$($case.label)：Check 必须以用法错误拒绝"
        Assert-True ($usageError.Exception.GetType() -eq [Management.Automation.RuntimeException] -and
            $usageError.Exception.Message -ceq $usageMessage -and
            $usageError.FullyQualifiedErrorId -ceq $usageMessage) (
            "$($case.label)：用法错误必须为普通 throw「$usageMessage」，实际 $($usageError.Exception.GetType().FullName)：$($usageError.Exception.Message)")
        Assert-True ((Get-EvidenceSnapshot) -ceq $before) "$($case.label)：用法错误不得改动 evidence 目录树"
    }
} finally {
    try {
        # 先单独删掉 junction 链接本身（非递归，不触及其目标），清理快照不接受 reparse point。
        if ([IO.Directory]::Exists($junctionPath)) { [IO.Directory]::Delete($junctionPath) }
        Remove-TestTree -Path $scratchRoot
    } catch {
        $cleanupError = $_
    }
}
if ($null -ne $cleanupError) { throw $cleanupError }

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteCheck'
    explicitCases = $explicitCases.Count
    autoCases = $autoCases.Count
    multiTargetCases = $multiCases.Count
    usageCases = $usageCases.Count
}
