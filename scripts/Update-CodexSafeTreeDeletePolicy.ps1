[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('DryRun', 'Apply')][string]$Mode,
    [Parameter(Mandatory)][string]$ChangeSetPath,
    [string]$ApprovedCandidatePolicySha256,
    [string[]]$ConfirmManualReviewOperationIds = @(),
    # 测试专用 seam（capability spec 记录；生产调用不得传递）：前四个必须同时给出或同时缺省。
    [string]$PolicyPathForTest,
    [string]$EvidenceRootForTest,
    [string]$MutexNameForTest,
    [string]$MarkerPathForTest,
    [int]$StopAfterPhaseForTest = 0,
    [int]$GateWaitSecondsForTest = 0,
    [int]$PauseAfterPhaseForTest = 0,
    [string]$PauseSignalDirectoryForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #82（spec #73）safe-tree-delete policy 维护工具。独立脚本：不经 gate shim、不是生产入口的 Mode。
# 与部署工具共用同名 deployment mutex、同一 maintenance marker 与 #77 持锁者面包屑
# （mode=policy-maintenance），因此与 shim 调用、部署互斥。两种 Mode 都持锁执行同一条检查链：
# 读现役 policy → 按声明式变更集生成候选 → 现有加载器加载候选、结构规则不新增违例 → 在途检查
# （进程内调用 Status 的候选 policy 预检）。DryRun 到此输出候选 SHA；Apply 要求同一候选 SHA，
# 再以同目录临时文件原子替换落盘。候选只在内存里：加载器与 Status 预检读同一份候选原始字节，
# DryRun 不写任何文件。

$productionPolicyPath = 'D:\agents\projects\统一环境\managed\safe-tree-delete\policy.json'
$productionEvidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$productionMutexName = 'Global\CodexSafeTreeDeleteDeployment'
$productionMarkerPath = 'D:\Codex\.codex\state\safe-tree-delete-deployment\maintenance.json'

$result = [ordered]@{
    ok = $false
    mode = $Mode
    refusalReason = $null
    message = $null
    livePolicySha256 = $null
    livePolicySchemaVersion = $null
    liveFormat = $null
    candidatePolicySha256 = $null
    approvedCandidatePolicySha256 = $null
    changes = @()
    entryCount = $null
    structure = $null
    inFlight = $null
    safeCleanupJob = $null
    written = $false
    notice = $null
}

function Get-PolicyMaintenanceMutexName {
    # current-user 命名空间，与 shim 和 Deploy-CodexSafeTreeDelete.ps1 Get-DeploymentMutexName 同款。
    param([Parameter(Mandatory)][string]$BaseName)

    $sid = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return ('{0}-u-{1}' -f $BaseName, ($sid -replace '[^0-9]', ''))
}

function Wait-IfPauseRequested {
    # 测试暂停 seam：在第一个不小于 PauseAfterPhaseForTest 的阶段边界（仍持锁）暂停一次，在信号目录
    # 写 paused-<阶段>，等到同目录出现 resume 再继续；超过 2 分钟未放行则失败。
    param([Parameter(Mandatory)][int]$Sequence)
    if ($PauseAfterPhaseForTest -le 0 -or $Sequence -lt $PauseAfterPhaseForTest -or $script:testPauseDone) { return }
    $script:testPauseDone = $true
    [IO.File]::WriteAllBytes((Join-Path $PauseSignalDirectoryForTest ('paused-{0}' -f $Sequence)), [byte[]]@())
    $resumePath = Join-Path $PauseSignalDirectoryForTest 'resume'
    $deadline = [datetime]::UtcNow.AddMinutes(2)
    while (-not [IO.File]::Exists($resumePath)) {
        if ([datetime]::UtcNow -ge $deadline) { throw '测试暂停超过 2 分钟未收到 resume。' }
        Start-Sleep -Milliseconds 20
    }
}

function Stop-IfRequested {
    # 阶段边界：先按暂停 seam 暂停，再按 StopAfterPhaseForTest 停止。
    param([Parameter(Mandatory)][int]$Sequence)
    Wait-IfPauseRequested -Sequence $Sequence
    if ($StopAfterPhaseForTest -gt 0 -and $Sequence -ge $StopAfterPhaseForTest) {
        Write-Output ('STOPPED-AFTER-PHASE {0}' -f $Sequence)
        exit 0
    }
}

function Write-ToolResult {
    # 唯一输出：一行 ASCII-only JSON；ok=false 时 exit 1。
    $script:result | ConvertTo-Json -Compress -Depth 12 -EscapeHandling EscapeNonAscii
    exit $(if ([bool]$script:result.ok) { 0 } else { 1 })
}

function ConvertTo-RedactedToolMessage {
    # 输出不回显路径。规则与 Lint 的 ConvertTo-CodexSafeTreeDeleteLintRedactedText 相同：库与宿主库把出错的值
    # 接在全角冒号之后，只保留冒号前的规则含义；残留的盘符路径（.NET 异常文本等）替换为 <path>。库在持锁且
    # 确认无 marker 之后才加载，锁前的拒绝也要脱敏，所以工具自带这一份。
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $cut = $Text.IndexOf([char]0xFF1A)
    if ($cut -ge 0) { $Text = $Text.Substring(0, $cut) }
    return ($Text -replace '(?i)(?<![a-z0-9])[a-z]:[\\/][^\s''"，。；]*', '<path>').Trim()
}

function Stop-WithRefusal {
    param(
        [Parameter(Mandatory)][string]$RefusalReason,
        [string]$Message
    )
    $redacted = ConvertTo-RedactedToolMessage -Text $Message
    $script:result.ok = $false
    $script:result.refusalReason = $RefusalReason
    $script:result.message = $(if ([string]::IsNullOrEmpty($redacted)) { $null } else { $redacted })
    Write-ToolResult
}

function ConvertTo-PolicyBytes {
    # 仓库 policy 的书写格式：ConvertTo-Json -Depth 32（两空格缩进）、LF、末尾换行、UTF-8 无 BOM。
    param([Parameter(Mandatory)][object]$Document)

    $json = $Document | ConvertTo-Json -Depth 32
    return , [Text.UTF8Encoding]::new($false).GetBytes(($json -replace "`r`n", "`n") + "`n")
}

function Get-CanonicalChangePath {
    # 变更集里的路径必须已是规范形态（Assert-CodexHookDPath 的输出、无尾随分隔符），policy 才能保持整洁，
    # remove-deny 的匹配也不依赖拼写。
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )
    $canonical = Assert-CodexHookDPath -Value $Value -Name $Name
    if ($canonical -cne [string]$Value -or $canonical.EndsWith('\', [StringComparison]::Ordinal)) {
        throw "$Name 必须是规范绝对路径（无相对段、无 '/'、无尾随分隔符）。"
    }
    return $canonical
}

function Test-PolicyPathSame {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    return [StringComparer]::OrdinalIgnoreCase.Equals($Left.TrimEnd('\', '/'), $Right.TrimEnd('\', '/'))
}

function Read-PolicyChangeSet {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Assert-CodexHookDPath -Value $Path -Name 'policy change set path'
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $fullPath -Name 'policy change set' -AllowedExactPaths @($fullPath)
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    $document = $snapshot.text | ConvertFrom-Json -Depth 32 -DateKind String
    Assert-CodexHookExactProperties -Value $document -Names @('artifactType', 'schemaVersion', 'changes') -Scope 'policy change set'
    if ($document.artifactType -cne 'env-governance.codex-safe-tree-delete-policy-change-set') {
        throw 'policy change set artifactType 非法。'
    }
    if ($document.schemaVersion -isnot [long] -or [long]$document.schemaVersion -ne 1L) {
        throw 'policy change set schemaVersion 必须是 JSON integer 1。'
    }
    if ($document.changes -isnot [Array] -or @($document.changes).Count -eq 0) {
        throw 'policy change set changes 必须是非空 JSON array。'
    }
    return @($document.changes)
}

function Find-PolicyDocumentEntry {
    param(
        [Parameter(Mandatory)][object]$Document,
        [AllowNull()][object]$EntryId,
        [Parameter(Mandatory)][int]$ChangeIndex
    )
    if ($EntryId -isnot [string]) { throw "changes[$ChangeIndex].entryId 必须是 JSON string。" }
    $matched = @(@($Document.entries) | Where-Object { [string]$_.id -ceq $EntryId })
    if ($matched.Count -ne 1) { throw "changes[$ChangeIndex] 引用的条目不存在：$EntryId" }
    return $matched[0]
}

function Invoke-PolicyChangeSet {
    # 按声明顺序把变更作用到现役 policy 的原始文档上（原地修改），返回不含路径的变更摘要。
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Changes
    )

    $summary = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Changes.Count; $index++) {
        $change = $Changes[$index]
        if ($null -eq $change -or $change -is [string] -or $change -is [array] -or
            @($change.PSObject.Properties.Name) -cnotcontains 'op' -or $change.op -isnot [string]) {
            throw "changes[$index] 必须是带 op 的 JSON object。"
        }
        switch -CaseSensitive ([string]$change.op) {
            'add-deny' {
                Assert-CodexHookExactProperties -Value $change -Names @('op', 'entryId', 'path') -Scope "changes[$index]"
                $entry = Find-PolicyDocumentEntry -Document $Document -EntryId $change.entryId -ChangeIndex $index
                $deniedPath = Get-CanonicalChangePath -Value $change.path -Name "changes[$index].path"
                foreach ($existing in @($entry.deniedExactPaths)) {
                    if (Test-PolicyPathSame -Left (Assert-CodexHookDPath -Value $existing -Name 'policy denied path') -Right $deniedPath) {
                        throw "changes[$index] 的 deny 已存在于条目 $($change.entryId)。"
                    }
                }
                $entry.deniedExactPaths = [object[]](@($entry.deniedExactPaths) + @($deniedPath))
                $summary.Add([pscustomobject][ordered]@{ op = 'add-deny'; entryId = [string]$change.entryId })
            }
            'remove-deny' {
                Assert-CodexHookExactProperties -Value $change -Names @('op', 'entryId', 'path') -Scope "changes[$index]"
                $entry = Find-PolicyDocumentEntry -Document $Document -EntryId $change.entryId -ChangeIndex $index
                $deniedPath = Get-CanonicalChangePath -Value $change.path -Name "changes[$index].path"
                $remaining = [Collections.Generic.List[object]]::new()
                $removedCount = 0
                foreach ($existing in @($entry.deniedExactPaths)) {
                    if (Test-PolicyPathSame -Left (Assert-CodexHookDPath -Value $existing -Name 'policy denied path') -Right $deniedPath) {
                        $removedCount++
                    } else {
                        $remaining.Add($existing)
                    }
                }
                if ($removedCount -ne 1) {
                    throw "changes[$index] 的 deny 必须在条目 $($change.entryId) 中恰好匹配一条（实际 $removedCount 条）。"
                }
                $entry.deniedExactPaths = [object[]]$remaining.ToArray()
                $summary.Add([pscustomobject][ordered]@{ op = 'remove-deny'; entryId = [string]$change.entryId })
            }
            'add-entry' {
                # 新条目追加在末尾，属性按仓库 policy 的顺序重排；字段取值与按 schema 的属性集合交给加载器校验。
                Assert-CodexHookExactProperties -Value $change -Names @('op', 'entry') -Scope "changes[$index]"
                $newEntry = $change.entry
                if ($newEntry -isnot [Management.Automation.PSCustomObject]) {
                    throw "changes[$index].entry 必须是 JSON object。"
                }
                $propertyOrder = @('id', 'capabilityRoot', 'minimumDescendantDepth', 'rootDeletionPurpose', 'allowHardLinks',
                    'allowInternalDirectoryJunctions', 'minimumQuarantineAgeMinutes', 'producerFenceMode', 'deniedExactPaths')
                $names = @($newEntry.PSObject.Properties.Name)
                $unknown = @($names | Where-Object { $propertyOrder -cnotcontains $_ })
                if ($unknown.Count -ne 0) { throw "changes[$index].entry 含未知属性：$($unknown -join ', ')" }
                if ($names -cnotcontains 'id' -or $newEntry.id -isnot [string] -or
                    @(@($Document.entries) | Where-Object { [string]$_.id -ceq [string]$newEntry.id }).Count -ne 0) {
                    throw "changes[$index].entry.id 必须是 policy 中尚不存在的 JSON string。"
                }
                $root = Get-CanonicalChangePath -Value $(if ($names -ccontains 'capabilityRoot') { $newEntry.capabilityRoot }) `
                    -Name "changes[$index].entry.capabilityRoot"
                foreach ($existing in @($Document.entries)) {
                    if (Test-PolicyPathSame -Left (Assert-CodexHookDPath -Value $existing.capabilityRoot -Name 'policy root') -Right $root) {
                        throw "changes[$index].entry.capabilityRoot 与条目 $($existing.id) 重复。"
                    }
                }
                if ($names -ccontains 'deniedExactPaths') {
                    if ($newEntry.deniedExactPaths -isnot [Array]) { throw "changes[$index].entry.deniedExactPaths 必须是 JSON array。" }
                    foreach ($deniedPath in @($newEntry.deniedExactPaths)) {
                        [void](Get-CanonicalChangePath -Value $deniedPath -Name "changes[$index].entry.deniedExactPaths[]")
                    }
                }
                $ordered = [ordered]@{}
                foreach ($name in $propertyOrder) {
                    if ($names -ccontains $name) { $ordered[$name] = $newEntry.$name }
                }
                $Document.entries = [object[]](@($Document.entries) + @([pscustomobject]$ordered))
                $summary.Add([pscustomobject][ordered]@{ op = 'add-entry'; entryId = [string]$newEntry.id })
            }
            'retire-entry' {
                # 退役即移除整条（不改用途重用），与 #83 的约束一致。
                Assert-CodexHookExactProperties -Value $change -Names @('op', 'entryId') -Scope "changes[$index]"
                [void](Find-PolicyDocumentEntry -Document $Document -EntryId $change.entryId -ChangeIndex $index)
                $Document.entries = [object[]]@(@($Document.entries) | Where-Object { [string]$_.id -cne [string]$change.entryId })
                $summary.Add([pscustomobject][ordered]@{ op = 'retire-entry'; entryId = [string]$change.entryId })
            }
            default {
                throw "changes[$index].op 非法：$($change.op)"
            }
        }
    }
    return $summary.ToArray()
}

function Get-SafeCleanupJobImpact {
    # gap 3：SafeCleanupJob 描述符的位置由操作者决定，本工具看不到。按 job 的 policy 比对口径
    # （scripts/lib/SafeCleanupJob.ps1 Compare-SafeCleanupJobPolicy：原有条目逐条不变、新增条目不与 job 的
    # capability root 重叠）报告候选改动了哪些原有条目、新增了哪些条目。
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LiveEntries,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CandidateEntries
    )

    $changed = [Collections.Generic.List[string]]::new()
    foreach ($live in $LiveEntries) {
        $candidate = @($CandidateEntries | Where-Object { [string]$_.id -ceq [string]$live.id })
        if ($candidate.Count -ne 1 -or
            ($live | ConvertTo-Json -Compress -Depth 32) -cne ($candidate[0] | ConvertTo-Json -Compress -Depth 32)) {
            $changed.Add([string]$live.id)
        }
    }
    $liveIds = @($LiveEntries | ForEach-Object { [string]$_.id })
    return [pscustomobject][ordered]@{
        changedExistingEntryIds = $changed.ToArray()
        addedEntryIds = @($CandidateEntries | ForEach-Object { [string]$_.id } | Where-Object { $liveIds -cnotcontains $_ })
        note = 'SafeCleanupJob 描述符不在本工具视野内：job 的 policy 比对要求原有条目全部不变、新增条目不与 job 的 capability root 重叠。仍需要的 job 先完成 Verify，再 Apply。'
    }
}

function Get-StructureViolationKey {
    # deny 类违例按（规则、条目、deny 路径）识别，嵌套类按（规则、父条目、detail 中的子条目）识别；
    # denyIndex 会随增删移动，不能用作身份。
    param(
        [Parameter(Mandatory)][object]$Violation,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries
    )
    if ($null -ne $Violation.denyIndex) {
        $entry = @($Entries | Where-Object { [string]$_.id -ceq [string]$Violation.entryId })[0]
        $deniedPath = [string]@($entry.deniedExactPaths)[[int]$Violation.denyIndex]
        return ('{0}|{1}|{2}' -f $Violation.rule, $Violation.entryId, $deniedPath.TrimEnd('\', '/'))
    }
    return ('{0}|{1}|{2}' -f $Violation.rule, $Violation.entryId, $Violation.detail)
}

function Get-StructureComparison {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LiveEntries,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CandidateEntries
    )

    $live = @((Get-CodexSafeTreeDeletePolicyStructureViolations -Entries $LiveEntries).violations)
    $candidate = @((Get-CodexSafeTreeDeletePolicyStructureViolations -Entries $CandidateEntries).violations)
    $liveKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($violation in $live) { [void]$liveKeys.Add((Get-StructureViolationKey -Violation $violation -Entries $LiveEntries)) }
    $candidateKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($violation in $candidate) { [void]$candidateKeys.Add((Get-StructureViolationKey -Violation $violation -Entries $CandidateEntries)) }
    return [pscustomobject][ordered]@{
        liveViolations = @($live)
        newViolations = @($candidate | Where-Object {
                -not $liveKeys.Contains((Get-StructureViolationKey -Violation $_ -Entries $CandidateEntries)) })
        resolvedViolations = @($live | Where-Object {
                -not $candidateKeys.Contains((Get-StructureViolationKey -Violation $_ -Entries $LiveEntries)) })
    }
}

function Read-RunPlanDocument {
    # 只读 evidence run 下的 plan.json：与 Read-CodexSafeTreeDeleteApprovedPlan 同一套路径约束与快照读取。
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$FullEvidenceRoot
    )

    $planPath = Assert-CodexHookDPath -Value (Join-Path $RunDirectory 'plan.json') -Name 'safe-delete run plan path'
    if (-not (Test-CodexHookPathWithin -Path $planPath -ParentPath $FullEvidenceRoot)) {
        throw 'plan 不在受管 evidence 根下。'
    }
    [void](Assert-CodexHookCapabilityPath -Path $planPath -CapabilityRoot $FullEvidenceRoot `
        -AllowedExactPaths @($planPath) -Name 'safe-delete run plan')
    $snapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $planPath -Name 'safe-delete run plan' -AllowedExactPaths @($planPath)
    Assert-CodexHookStrictJsonText -JsonText $snapshot.text
    return ($snapshot.text | ConvertFrom-Json -Depth 128 -DateKind String)
}

function Get-PlanExpiryState {
    # gap 2：Status 的 planned 含已过期 plan 且不带过期字段，按 plan.json 的 expiresAtUtc 判定；
    # 与 Apply 用同一个函数（Assert-CodexSafeTreeDeletePlanExpiration）。返回 unexpired、expired 或 unreadable。
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$FullEvidenceRoot
    )

    try {
        $plan = Read-RunPlanDocument -RunDirectory $RunDirectory -FullEvidenceRoot $FullEvidenceRoot
        Assert-CodexSafeTreeDeletePlanExpiration -Plan $plan -Scope 'in-flight plan' -AllowExpiredPlan
    } catch {
        return 'unreadable'
    }
    try {
        Assert-CodexSafeTreeDeletePlanExpiration -Plan $plan -Scope 'in-flight plan'
    } catch {
        return 'expired'
    }
    return 'unexpired'
}

function Get-ResolutionAffectedPaths {
    # 候选相对现役改动了哪些路径的解析：被移除、换了 root 或改了 deny 之外字段的条目 root，以及新增的 deny。
    # plan 的 target 不在这些路径之内（含相等）时，它在候选下与在现役下的解析结果相同。
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LiveEntries,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CandidateEntries
    )

    $settingNames = @('rootDeletionPurpose', 'minimumDescendantDepth', 'allowHardLinks',
        'allowInternalDirectoryJunctions', 'minimumQuarantineAgeMinutes', 'producerFenceMode')
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($live in $LiveEntries) {
        $candidate = @($CandidateEntries | Where-Object { [string]$_.id -ceq [string]$live.id })
        if ($candidate.Count -ne 1 -or
            -not (Test-PolicyPathSame -Left ([string]$live.capabilityRoot) -Right ([string]$candidate[0].capabilityRoot)) -or
            @($settingNames | Where-Object { [string]$live.$_ -cne [string]$candidate[0].$_ }).Count -ne 0) {
            $paths.Add([string]$live.capabilityRoot)
            continue
        }
        foreach ($deniedPath in @($candidate[0].deniedExactPaths)) {
            $existing = @(@($live.deniedExactPaths) | Where-Object {
                    Test-PolicyPathSame -Left ([string]$_) -Right ([string]$deniedPath) })
            if ($existing.Count -eq 0) { $paths.Add([string]$deniedPath) }
        }
    }
    return $paths.ToArray()
}

function Test-TargetAffected {
    param(
        [AllowNull()][object]$TargetPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AffectedPaths
    )
    if ($AffectedPaths.Count -eq 0) { return $false }
    if ($TargetPath -isnot [string] -or [string]::IsNullOrWhiteSpace($TargetPath)) { return $true }
    try {
        foreach ($path in $AffectedPaths) {
            if ((Test-PolicyPathSame -Left $TargetPath -Right $path) -or
                (Test-CodexHookPathWithin -Path $TargetPath -ParentPath $path)) {
                return $true
            }
        }
    } catch {
        return $true
    }
    return $false
}

function Get-PlanResolutionRefusal {
    # gap 1：与 Status 的 v3 候选重解析、Read-CodexSafeTreeDeleteApprovedPlan 同一组判定（Resolve 不要求
    # target 现存、条目 id 不变、目标树规则），在候选 policy 下复核 plan。可解析返回 $null，否则返回拒绝代码。
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Policy
    )

    $decision = Get-CodexSafeTreeDeleteTargetDecision -TargetPath ([string]$Plan.targetPath) `
        -CapabilityRoot ([string]$Plan.capabilityRoot) -Policy $Policy -RequireExisting $false
    if (-not [bool]$decision.allowed) { return [string]$decision.refusalReason }
    if ([string]$decision.entry.id -cne [string]$Plan.policyEntryId) { return 'policy-entry-id-changed' }
    try {
        $target = Resolve-CodexSafeTreeDeleteTarget -TargetPath ([string]$Plan.targetPath) `
            -CapabilityRoot ([string]$Plan.capabilityRoot) -Policy $Policy -RequireExisting $false
        Assert-CodexSafeTreeDeleteTargetTreePolicy -Target $target -TreeManifest $Plan.treeManifest
    } catch {
        return 'target-tree-policy-refused'
    }
    return $null
}

function Get-InFlightAssessment {
    # 进程内调用 Status 的候选 policy 预检（逐条 candidatePolicyCompatible），再按 lifecycle 归类：
    # 只有绑定现役 policy、且会因候选失去兼容的非 terminal 记录参与阻止。
    param(
        [Parameter(Mandatory)][string]$LivePolicySha256,
        [Parameter(Mandatory)][byte[]]$CandidatePolicyBytes,
        [Parameter(Mandatory)][string]$CandidatePolicySha256,
        [Parameter(Mandatory)][object]$CandidatePolicy,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AffectedPaths,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ConfirmedOperationIds
    )

    $fullEvidenceRoot = Assert-CodexHookDPath -Value $evidenceRoot -Name 'safe-delete evidence root'
    $status = Get-CodexSafeTreeDeleteStatus `
        -PolicyPath $policyPath `
        -EvidenceRoot $fullEvidenceRoot `
        -CandidatePolicyBytes $CandidatePolicyBytes `
        -ApprovedCandidatePolicySha256 $CandidatePolicySha256
    if ([string]$status.policySha256 -cne $LivePolicySha256) {
        throw 'Status 读到的现役 policy 与本次读取的不一致（policy 在检查期间被改动）。'
    }
    $blocking = [Collections.Generic.List[object]]::new()
    $confirmed = [Collections.Generic.List[string]]::new()
    $expiredPlans = [Collections.Generic.List[string]]::new()
    $boundToOtherPolicyCount = 0L
    $terminalLosingResolution = [Collections.Generic.List[object]]::new()
    foreach ($operation in @($status.operations)) {
        $lifecycle = [string]$operation.lifecycle
        if ($lifecycle -ceq 'terminal') {
            # gap 1：预检把 terminal 记录一律视为兼容；未归档的在候选下若不再解析，变更后 Status 会把它
            # 改报为 manual-review。列出，不阻止；已归档的不读 policy，不受影响。
            if ([string]$operation.journalStatus -cne 'archived' -and
                (Test-TargetAffected -TargetPath $operation.targetPath -AffectedPaths $AffectedPaths)) {
                try {
                    $plan = Read-RunPlanDocument -RunDirectory ([string]$operation.runDirectory) -FullEvidenceRoot $fullEvidenceRoot
                    $refusal = Get-PlanResolutionRefusal -Plan $plan -Policy $CandidatePolicy
                } catch {
                    $refusal = 'plan-unreadable'
                }
                if ($null -ne $refusal) {
                    $terminalLosingResolution.Add([pscustomobject][ordered]@{
                        operationId = [string]$operation.operationId
                        refusalReason = $refusal
                    })
                }
            }
            continue
        }
        if (-not [bool]$operation.policyCompatible) {
            # 已绑定其他 policy 字节的记录不因本次变更改变处境：只计数。
            $boundToOtherPolicyCount++
            continue
        }
        if ([bool]$operation.candidatePolicyCompatible) {
            continue
        }
        $reason = 'policy-bound-record'
        if ($lifecycle -ceq 'planned') {
            $expiry = Get-PlanExpiryState -RunDirectory ([string]$operation.runDirectory) -FullEvidenceRoot $fullEvidenceRoot
            if ($expiry -ceq 'expired') {
                # 过期 plan 不能再 Apply，不阻止；policy 变更后 Status 把它报告为 manual-review。
                $expiredPlans.Add([string]$operation.operationId)
                continue
            }
            $reason = if ($expiry -ceq 'unexpired') { 'unexpired-plan' } else { 'plan-expiry-unreadable' }
        } elseif ($lifecycle -cin @('recoverable', 'purge-resumable')) {
            $reason = 'resumable-transaction'
        } elseif ($lifecycle -cin @('manual-review', 'inconsistent')) {
            # inconsistent 的 safeActions 同样只有 manual-review，按 manual-review 处理。
            if ($ConfirmedOperationIds -ccontains [string]$operation.operationId) {
                $confirmed.Add([string]$operation.operationId)
                continue
            }
            $reason = 'manual-review-unconfirmed'
        }
        $blocking.Add([pscustomobject][ordered]@{
            operationId = [string]$operation.operationId
            lifecycle = $lifecycle
            transactionStatus = $operation.transactionStatus
            reason = $reason
        })
    }
    return [pscustomobject][ordered]@{
        operationCount = @($status.operations).Count
        blocking = $blocking.ToArray()
        confirmedManualReview = $confirmed.ToArray()
        unmatchedConfirmations = @($ConfirmedOperationIds | Where-Object { -not $confirmed.Contains($_) })
        expiredPlans = $expiredPlans.ToArray()
        boundToOtherPolicyCount = $boundToOtherPolicyCount
        terminalRecordsLosingResolution = $terminalLosingResolution.ToArray()
    }
}

# ---------------- main ----------------
# 脚本主体的任何失败都以同一行 JSON 结束（ok=false、exit 1）：参数检查在取锁之前拒绝为 invalid-arguments，
# 其余异常由最外层 catch 报告为 unexpected-error。Stop-WithRefusal 与 Write-ToolResult 以 exit 结束，exit
# 不被 catch 截获；持锁段的 finally 照常删除面包屑、释放锁。参数绑定错误（未知参数、类型转换、ValidateSet、
# 缺少必需参数）发生在主体运行之前，由 PowerShell 报错，不经这里。
try {
    $seamValues = @($PolicyPathForTest, $EvidenceRootForTest, $MutexNameForTest, $MarkerPathForTest)
    $seamCount = @($seamValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($seamCount -ne 0 -and $seamCount -ne $seamValues.Count) {
        Stop-WithRefusal -RefusalReason 'invalid-arguments' `
            -Message 'policy 维护工具的测试 seam（PolicyPathForTest、EvidenceRootForTest、MutexNameForTest、MarkerPathForTest）必须同时给出。'
    }
    $testSeamActive = ($seamCount -eq $seamValues.Count)
    $pauseRequested = -not [string]::IsNullOrWhiteSpace($PauseSignalDirectoryForTest)
    if (-not $testSeamActive -and ($StopAfterPhaseForTest -ne 0 -or $GateWaitSecondsForTest -ne 0 -or
            $PauseAfterPhaseForTest -ne 0 -or $pauseRequested)) {
        Stop-WithRefusal -RefusalReason 'invalid-arguments' `
            -Message 'StopAfterPhaseForTest、GateWaitSecondsForTest 与暂停 seam 只在测试 seam 生效时可用。'
    }
    if (($PauseAfterPhaseForTest -gt 0) -ne $pauseRequested) {
        Stop-WithRefusal -RefusalReason 'invalid-arguments' `
            -Message 'PauseAfterPhaseForTest 与 PauseSignalDirectoryForTest 必须同时给出。'
    }
    $testPauseDone = $false

    if ($Mode -ceq 'DryRun' -and -not [string]::IsNullOrEmpty($ApprovedCandidatePolicySha256)) {
        Stop-WithRefusal -RefusalReason 'invalid-arguments' `
            -Message 'DryRun 不接受 ApprovedCandidatePolicySha256；先 DryRun 取得 candidatePolicySha256，再以 Apply 提交。'
    }
    if ($Mode -ceq 'Apply' -and $ApprovedCandidatePolicySha256 -cnotmatch '^[0-9a-f]{64}\z') {
        Stop-WithRefusal -RefusalReason 'invalid-arguments' `
            -Message 'Apply 必须给出 DryRun 输出的 candidatePolicySha256（64 位小写十六进制）。'
    }
    # 只回显通过校验的批准值。
    if ($Mode -ceq 'Apply') { $result.approvedCandidatePolicySha256 = $ApprovedCandidatePolicySha256 }
    # 宿主 .cmd 链只能传单个字符串：单个含 '::' 的值按 '::' 拆成多个 operation id。
    $confirmationValues = @($ConfirmManualReviewOperationIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($confirmationValues.Count -eq 1 -and ([string]$confirmationValues[0]).Contains('::')) {
        $confirmationValues = ([string]$confirmationValues[0]).Split([string[]]@('::'), [StringSplitOptions]::RemoveEmptyEntries)
    }
    $confirmedOperationIds = [Collections.Generic.List[string]]::new()
    for ($position = 1; $position -le $confirmationValues.Count; $position++) {
        $operationId = [string]$confirmationValues[$position - 1]
        if ($operationId -cnotmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,127}\z') {
            # 只报位置，不回显取值。
            Stop-WithRefusal -RefusalReason 'invalid-arguments' `
                -Message "ConfirmManualReviewOperationIds 的第 $position 个值不是合法 operation id。"
        }
        if (-not $confirmedOperationIds.Contains($operationId)) { $confirmedOperationIds.Add($operationId) }
    }

    $policyPath = if ($testSeamActive) { $PolicyPathForTest } else { $productionPolicyPath }
    $evidenceRoot = if ($testSeamActive) { $EvidenceRootForTest } else { $productionEvidenceRoot }
    $mutexBaseName = if ($testSeamActive) { $MutexNameForTest } else { $productionMutexName }
    $markerPath = if ($testSeamActive) { $MarkerPathForTest } else { $productionMarkerPath }
    # 面包屑与 marker 同目录（state root），与 shim、部署工具一致。
    $stateRoot = Split-Path -Parent $markerPath
    $gateWait = if ($GateWaitSecondsForTest -gt 0) {
        [TimeSpan]::FromSeconds($GateWaitSecondsForTest)
    } else {
        [TimeSpan]::FromMinutes(5)
    }

    . (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDeleteGateHolder.ps1')

    $mutex = [System.Threading.Mutex]::new($false, (Get-PolicyMaintenanceMutexName -BaseName $mutexBaseName))
    $acquired = $false
    foreach ($attempt in 1..2) {
        try {
            $acquired = $mutex.WaitOne($gateWait)
            break
        } catch [System.Threading.AbandonedMutexException] {
            # 所有权已转移给本进程：释放后重试一次（与 shim 同款，阻止 abandoned 级联）。
            try { [void]$mutex.ReleaseMutex() } catch { }
        }
    }
    if (-not $acquired) {
        $mutex.Dispose()
        $result['holder'] = Read-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot
        Stop-WithRefusal -RefusalReason 'deployment-mutex-acquire-timeout'
    }
    try {
        # #77：持锁期间留 mode=policy-maintenance 面包屑；写失败是有意降级，不阻塞。
        [void](Write-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot -Mode 'policy-maintenance')
        Stop-IfRequested -Sequence 10
        if (Test-Path -LiteralPath $markerPath) {
            Stop-WithRefusal -RefusalReason 'deployment-maintenance-marker-present'
        }
        # 库在持锁且确认无 maintenance marker 之后才加载（与 shim 委托 repo entry 的时机一致）。
        . (Join-Path $PSScriptRoot 'lib\CodexHostSafety.ps1')
        . (Join-Path $PSScriptRoot 'lib\CodexSafeTreeDelete.ps1')
        Stop-IfRequested -Sequence 20

        # 3. 读取并校验现役 policy：加载器校验，同时取同一份原始字节作为候选的起点。
        try {
            $policyFullPath = Assert-CodexHookDPath -Value $policyPath -Name 'safe-delete policy path'
            $liveSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $policyFullPath -Name 'safe-delete policy' `
                -AllowedExactPaths @($policyFullPath)
            $livePolicy = Read-CodexSafeTreeDeletePolicy -PolicyPath $policyFullPath
            if ([string]$livePolicy.sha256 -cne [string]$liveSnapshot.sha256) {
                throw '现役 policy 在读取期间被改动。'
            }
            $liveDocument = $liveSnapshot.text | ConvertFrom-Json -Depth 32 -DateKind String
        } catch {
            Stop-WithRefusal -RefusalReason 'live-policy-invalid' -Message $_.Exception.Message
        }
        [byte[]]$liveBytes = $liveSnapshot.bytes
        $result.livePolicySha256 = [string]$livePolicy.sha256
        $result.livePolicySchemaVersion = [long]$livePolicy.schemaVersion
        $liveText = [Text.Encoding]::UTF8.GetString($liveBytes)
        $result.liveFormat = [pscustomobject][ordered]@{
            reserializesIdentically = [Linq.Enumerable]::SequenceEqual($liveBytes, [byte[]](ConvertTo-PolicyBytes -Document $liveDocument))
            crlfLineCount = [regex]::Matches($liveText, "`r`n").Count
            utf8Bom = ($liveBytes.Length -ge 3 -and $liveBytes[0] -eq 0xEF -and $liveBytes[1] -eq 0xBB -and $liveBytes[2] -eq 0xBF)
        }
        Stop-IfRequested -Sequence 30

        # 4. 生成候选 policy。
        try {
            $changes = @(Read-PolicyChangeSet -Path $ChangeSetPath)
            $candidateDocument = $liveSnapshot.text | ConvertFrom-Json -Depth 32 -DateKind String
            $result.changes = @(Invoke-PolicyChangeSet -Document $candidateDocument -Changes $changes)
        } catch {
            Stop-WithRefusal -RefusalReason 'change-set-invalid' -Message $_.Exception.Message
        }
        [byte[]]$candidateBytes = ConvertTo-PolicyBytes -Document $candidateDocument
        $candidateSha256 = Get-CodexHookBytesSha256 -Bytes $candidateBytes
        $result.candidatePolicySha256 = $candidateSha256
        $result.entryCount = [pscustomobject][ordered]@{
            before = @($liveDocument.entries).Count
            after = @($candidateDocument.entries).Count
        }
        $result.safeCleanupJob = Get-SafeCleanupJobImpact -LiveEntries @($liveDocument.entries) -CandidateEntries @($candidateDocument.entries)
        if ($Mode -ceq 'Apply' -and $candidateSha256 -cne $ApprovedCandidatePolicySha256) {
            Stop-WithRefusal -RefusalReason 'candidate-sha-mismatch' `
                -Message '本次生成的候选 policy SHA-256 与批准的不一致；重新 DryRun 并复核。'
        }
        Stop-IfRequested -Sequence 40

        # 5. 候选必须能被现有加载器加载，且按结构规则不新增违例（现役已有的违例列入输出，不阻止）。
        # 加载器与 Status 预检读同一份内存中的候选原始字节，不落盘。
        try {
            $candidatePolicy = Read-CodexSafeTreeDeletePolicy -PolicyBytes $candidateBytes
        } catch {
            Stop-WithRefusal -RefusalReason 'candidate-policy-invalid' -Message $_.Exception.Message
        }
        $structure = Get-StructureComparison -LiveEntries @($livePolicy.entries) -CandidateEntries @($candidatePolicy.entries)
        $result.structure = $structure
        if (@($structure.newViolations).Count -ne 0) {
            Stop-WithRefusal -RefusalReason 'candidate-adds-structure-violations' `
                -Message '候选 policy 按结构规则新增了违例，见 structure.newViolations。'
        }
        Stop-IfRequested -Sequence 50

        # 6. 在途检查。
        try {
            $inFlight = Get-InFlightAssessment `
                -LivePolicySha256 ([string]$livePolicy.sha256) `
                -CandidatePolicyBytes $candidateBytes `
                -CandidatePolicySha256 $candidateSha256 `
                -CandidatePolicy $candidatePolicy `
                -AffectedPaths @(Get-ResolutionAffectedPaths -LiveEntries @($livePolicy.entries) -CandidateEntries @($candidatePolicy.entries)) `
                -ConfirmedOperationIds $confirmedOperationIds.ToArray()
        } catch {
            Stop-WithRefusal -RefusalReason 'in-flight-check-failed' -Message $_.Exception.Message
        }
        $result.inFlight = $inFlight
        if (@($inFlight.blocking).Count -ne 0) {
            Stop-WithRefusal -RefusalReason 'in-flight-records-blocking' `
                -Message '有绑定现役 policy、会因本次变更失去兼容的在途记录，见 inFlight.blocking。'
        }
        Stop-IfRequested -Sequence 60

        if ($Mode -ceq 'DryRun') {
            $result.ok = $true
            Write-ToolResult
        }

        # 7. 原子替换落盘：同目录临时文件写入批准的候选字节，换名前复核现役字节未变，换名后复核候选 SHA。
        $policyDirectory = Split-Path -Parent $policyFullPath
        try {
            Set-CodexHookAtomicFileBytesWithCapability `
                -Path $policyFullPath `
                -Bytes $candidateBytes `
                -ExpectedExists $true `
                -ExpectedSha256 ([string]$livePolicy.sha256) `
                -AfterSha256 $candidateSha256 `
                -CapabilityRoot $policyDirectory `
                -AllowedExactPaths @($policyFullPath) `
                -Scope 'safe-delete policy maintenance' `
                -BeforeRename { Stop-IfRequested -Sequence 65 }
        } catch {
            Stop-WithRefusal -RefusalReason 'policy-write-failed' -Message $_.Exception.Message
        }
        $result.written = $true
        Stop-IfRequested -Sequence 70

        # 8. 输出结果。
        $result.ok = $true
        $result.notice = 'policy 已对宿主立即生效，git 提交需另行完成'
        Write-ToolResult
    } finally {
        Remove-CodexSafeTreeDeleteGateHolder -StateRoot $stateRoot
        [void]$mutex.ReleaseMutex()
        $mutex.Dispose()
    }
} catch {
    Stop-WithRefusal -RefusalReason 'unexpected-error' -Message $_.Exception.Message
}
