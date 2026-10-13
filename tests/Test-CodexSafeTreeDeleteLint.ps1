[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #79，spec #73「实现决策 › Lint 模式」「加载器结构规则」):
# 唯一接缝：fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 Lint mode。只观察 JSON 结果
# （findings、nestedRoots、policy / evidence 摘要、决定生产入口退出码的 refusalReason），以及 policy 与
# evidence 在运行前后的状态。
# policy 全部是本套件合成的 fixture；不读仓库 policy，也不读写生产 evidence 根。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'lint'
$junctionPaths = [Collections.Generic.List[string]]::new()

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
        -Name 'safe-delete lint test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete lint test cleanup'
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-PolicyEntry {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][long]$Depth,
        [string]$Purpose = 'none',
        [string[]]$Deny = @()
    )

    return [ordered]@{
        id = $Id
        capabilityRoot = $Root
        minimumDescendantDepth = $Depth
        rootDeletionPurpose = $Purpose
        deniedExactPaths = @($Deny)
    }
}

function Write-LintPolicy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Entries
    )

    $policy = [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @($Entries)
    }
    Write-Utf8File -Path $Path -Text ($policy | ConvertTo-Json -Depth 10)
}

function Invoke-Lint {
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $output = @(& $entryPath `
            -Mode Lint `
            -Json `
            -FixturePolicyPath $PolicyPath `
            -FixtureEvidenceRoot $EvidenceRoot)
    Assert-True ($output.Count -eq 1) "Lint -Json 必须只输出一行 JSON，实际 $($output.Count) 项"
    return [pscustomobject][ordered]@{
        text = [string]$output[0]
        result = [string]$output[0] | ConvertFrom-Json -Depth 32 -ErrorAction Stop
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function Get-Findings {
    param(
        [Parameter(Mandatory)][object]$Result,
        [string]$Rule,
        [string]$Severity
    )

    return @(@($Result.findings) | Where-Object {
            ([string]::IsNullOrEmpty($Rule) -or [string]$_.rule -ceq $Rule) -and
            ([string]::IsNullOrEmpty($Severity) -or [string]$_.severity -ceq $Severity)
        })
}

function Format-Findings {
    param([Parameter(Mandatory)][object]$Result)
    return (@($Result.findings) | ConvertTo-Json -Depth 8 -Compress)
}

function Get-FindingKeys {
    # finding 的可比较身份：rule|severity|entryId|denyIndex（无 denyIndex 时为空）。
    param([Parameter(Mandatory)][object]$Result, [string]$Severity)

    return @(@(Get-Findings -Result $Result -Severity $Severity) | ForEach-Object {
            $denyIndex = if ($_.PSObject.Properties.Name -contains 'denyIndex') { [string]$_.denyIndex } else { '' }
            '{0}|{1}|{2}|{3}' -f $_.rule, $_.severity, $_.entryId, $denyIndex
        } | Sort-Object)
}

function Assert-FindingKeys {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected,
        [string]$Severity,
        [Parameter(Mandatory)][string]$Scope
    )

    $actual = @(Get-FindingKeys -Result $Result -Severity $Severity)
    $expectedSorted = @($Expected | Sort-Object)
    Assert-True (($actual -join "`n") -ceq ($expectedSorted -join "`n")) (
        "$Scope finding 不符。期望：$($expectedSorted -join '; ')；实际：$(Format-Findings -Result $Result)")
}

function Write-StructuralPolicy {
    # 同一形状的结构问题 policy：规则 1、2、3 各一处违例，外加一处深度 0 未声明用途（加载器拒绝）。
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Base)

    $parent = Join-Path $Base 'parent'
    Write-LintPolicy -Path $Path -Entries @(
        (New-PolicyEntry -Id 'lint-s-parent' -Root $parent -Depth 1 -Deny @((Join-Path $parent 'covered'), (Join-Path $parent 'a\b'))),
        (New-PolicyEntry -Id 'lint-s-covered' -Root (Join-Path $parent 'covered') -Depth 1),
        (New-PolicyEntry -Id 'lint-s-uncovered' -Root (Join-Path $parent 'uncovered') -Depth 1),
        (New-PolicyEntry -Id 'lint-s-build' -Root (Join-Path $Base 'build') -Depth 0 -Purpose 'rebuildable-build-output' -Deny @((Join-Path $Base 'build'))),
        (New-PolicyEntry -Id 'lint-s-purpose' -Root (Join-Path $Base 'state') -Depth 0)
    )
}

function Get-ErrorSignature {
    param([Parameter(Mandatory)][object]$Result)
    return @(@(Get-Findings -Result $Result -Severity 'error') | ForEach-Object {
            $denyIndex = if ($_.PSObject.Properties.Name -contains 'denyIndex') { [string]$_.denyIndex } else { '' }
            '{0}|{1}|{2}|{3}' -f $_.rule, $_.entryId, $denyIndex, $_.detail
        } | Sort-Object) -join "`n"
}

function Get-TreeState {
    # 只读证明用的树快照：相对路径、类型、长度、最后写入时间与文件 SHA-256；不进入 reparse point。
    # 目录的最后写入时间覆盖「建了又删」的临时文件或锁文件。
    param([Parameter(Mandatory)][string]$Root)

    $lines = [Collections.Generic.List[string]]::new()
    $rootInfo = [IO.DirectoryInfo]::new($Root)
    $lines.Add(('.|dir|{0}' -f $rootInfo.LastWriteTimeUtc.Ticks))
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($rootInfo)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in $directory.EnumerateFileSystemInfos()) {
            $relative = [IO.Path]::GetRelativePath($Root, $item.FullName)
            if ($item -is [IO.DirectoryInfo]) {
                $kind = if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { 'reparse' } else { 'dir' }
                $lines.Add(('{0}|{1}|{2}' -f $relative, $kind, $item.LastWriteTimeUtc.Ticks))
                if ($kind -ceq 'dir') { $pending.Push($item) }
            } else {
                $lines.Add(('{0}|file|{1}|{2}|{3}' -f $relative, $item.Length, $item.LastWriteTimeUtc.Ticks, (Get-FileSha256 -Path $item.FullName)))
            }
        }
    }
    [string[]]$sorted = $lines.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted -join "`n"
}

function Assert-TextExcludesPath {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Scope
    )

    $escaped = ($Path | ConvertTo-Json -Compress).Trim('"')
    Assert-True (-not $Text.Contains($Path, [StringComparison]::OrdinalIgnoreCase)) "$Scope 回显了完整路径"
    Assert-True (-not $Text.Contains($escaped, [StringComparison]::OrdinalIgnoreCase)) "$Scope 回显了 JSON 转义后的完整路径"
}

try {
    # 1. 合规 policy + 空 evidence：没有任何 finding，摘要如实反映 policy 与 evidence。
    $cleanRoot = Join-Path $scratchRoot 'clean'
    $cleanCapabilityRoot = Join-Path $cleanRoot 'root'
    $cleanKeep = Join-Path $cleanCapabilityRoot 'keep'
    $cleanEvidence = Join-Path $cleanRoot 'evidence'
    $cleanPolicyPath = Join-Path $cleanRoot 'policy.json'
    [void][IO.Directory]::CreateDirectory($cleanKeep)
    [void][IO.Directory]::CreateDirectory($cleanEvidence)
    Write-LintPolicy -Path $cleanPolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-clean' -Root $cleanCapabilityRoot -Depth 1 -Deny @($cleanKeep))
    )
    $clean = (Invoke-Lint -PolicyPath $cleanPolicyPath -EvidenceRoot $cleanEvidence).result
    Assert-True (@($clean.findings).Count -eq 0) "合规 policy 不得有 finding：$($clean.findings | ConvertTo-Json -Depth 8 -Compress)"
    Assert-True ($clean.errorCount -eq 0 -and $clean.warningCount -eq 0) '合规 policy 的 error / warning 计数必须为 0'
    Assert-True (@($clean.nestedRoots).Count -eq 0) '单条目 policy 不得有嵌套关系'
    Assert-True ($clean.policy.loadable -eq $true) '合规 policy 必须标为可加载'
    Assert-True ($clean.policy.entryCount -eq 1 -and $clean.policy.evaluatedEntryCount -eq 1) 'policy 摘要条目数不符'
    Assert-True ([string]$clean.policy.sha256 -ceq (Get-FileSha256 -Path $cleanPolicyPath)) 'policy 摘要 SHA-256 必须等于文件字节的 SHA-256'
    Assert-True ($clean.policy.schemaVersion -eq 4) 'policy 摘要 schemaVersion 不符'
    Assert-True ($clean.evidence.exists -eq $true) '空 evidence 根必须标为存在'
    foreach ($counter in @('runDirectories', 'nonRunTopLevelDirectories', 'transactionFiles', 'nonCanonicalTransactionFiles')) {
        Assert-True ($clean.evidence.$counter -eq 0) "空 evidence 根的 $counter 必须为 0"
    }

    # 2. 规则 1：deny 相对所属 root 的深度 ≤ 最小后代深度。等于、浅于都合规；更深的 deny 是 error，
    #    只报条目 id 与 deny 序号。加载器本票不执行新规则，所以 policy 仍可加载。
    $rule1Root = Join-Path $scratchRoot 'rule1'
    $rule1A = Join-Path $rule1Root 'root-a'
    $rule1B = Join-Path $rule1Root 'root-b'
    $rule1DeepDeny = Join-Path $rule1A 'deep\nested'
    $rule1Evidence = Join-Path $rule1Root 'evidence'
    $rule1PolicyPath = Join-Path $rule1Root 'policy.json'
    foreach ($directory in @(
            (Join-Path $rule1A 'keep'),
            $rule1DeepDeny,
            (Join-Path $rule1B 'one\two'),
            $rule1Evidence)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Write-LintPolicy -Path $rule1PolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-rule1-a' -Root $rule1A -Depth 1 -Deny @((Join-Path $rule1A 'keep'), $rule1DeepDeny)),
        (New-PolicyEntry -Id 'lint-rule1-b' -Root $rule1B -Depth 2 -Deny @((Join-Path $rule1B 'one'), (Join-Path $rule1B 'one\two')))
    )
    $rule1Run = Invoke-Lint -PolicyPath $rule1PolicyPath -EvidenceRoot $rule1Evidence
    Assert-FindingKeys -Result $rule1Run.result -Scope '规则 1' -Expected @(
        'deny-deeper-than-minimum-depth|error|lint-rule1-a|1'
    )
    Assert-True ($rule1Run.result.errorCount -eq 1 -and $rule1Run.result.warningCount -eq 0) '规则 1 计数不符'
    Assert-True ($rule1Run.result.policy.loadable -eq $true) '本票不改加载器：只违反新规则的 policy 仍可加载'
    Assert-TextExcludesPath -Text $rule1Run.text -Path $rule1DeepDeny -Scope '规则 1 发现'

    # 3. 规则 2：最小后代深度为 0 的条目不得带 deny，逐条 deny 报告。deny 等于 root 只违反规则 2；
    #    更深的 deny 同时违反规则 1。不带 deny 的深度 0 条目合规。
    $rule2Root = Join-Path $scratchRoot 'rule2'
    $rule2A = Join-Path $rule2Root 'build-a'
    $rule2B = Join-Path $rule2Root 'build-b'
    $rule2C = Join-Path $rule2Root 'build-c'
    $rule2Evidence = Join-Path $rule2Root 'evidence'
    $rule2PolicyPath = Join-Path $rule2Root 'policy.json'
    foreach ($directory in @($rule2A, (Join-Path $rule2B 'cache'), $rule2C, $rule2Evidence)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Write-LintPolicy -Path $rule2PolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-rule2-a' -Root $rule2A -Depth 0 -Purpose 'rebuildable-build-output' -Deny @($rule2A)),
        (New-PolicyEntry -Id 'lint-rule2-b' -Root $rule2B -Depth 0 -Purpose 'rebuildable-build-output' -Deny @((Join-Path $rule2B 'cache'))),
        (New-PolicyEntry -Id 'lint-rule2-c' -Root $rule2C -Depth 0 -Purpose 'rebuildable-build-output')
    )
    $rule2Run = Invoke-Lint -PolicyPath $rule2PolicyPath -EvidenceRoot $rule2Evidence
    Assert-FindingKeys -Result $rule2Run.result -Scope '规则 2' -Expected @(
        'deny-on-depth-zero-entry|error|lint-rule2-a|0',
        'deny-on-depth-zero-entry|error|lint-rule2-b|0',
        'deny-deeper-than-minimum-depth|error|lint-rule2-b|0'
    )
    Assert-True ($rule2Run.result.policy.loadable -eq $true) '本票不改加载器：只违反规则 2 的 policy 仍可加载'
    Assert-TextExcludesPath -Text $rule2Run.text -Path (Join-Path $rule2B 'cache') -Scope '规则 2 发现'

    # 4. 规则 3：某条 root 严格位于另一条 root 之内时，父条目必须有一条 deny 精确等于子 root。
    #    嵌套关系清单列出每一对及是否被覆盖；只共享字符串前缀的兄弟目录不算嵌套。
    $rule3Root = Join-Path $scratchRoot 'rule3'
    $rule3Parent = Join-Path $rule3Root 'parent'
    $rule3Covered = Join-Path $rule3Parent 'covered'
    $rule3Uncovered = Join-Path $rule3Parent 'uncovered'
    $rule3Sibling = Join-Path $rule3Root 'parent-sibling'
    $rule3Evidence = Join-Path $rule3Root 'evidence'
    $rule3PolicyPath = Join-Path $rule3Root 'policy.json'
    foreach ($directory in @($rule3Covered, $rule3Uncovered, $rule3Sibling, $rule3Evidence)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Write-LintPolicy -Path $rule3PolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-rule3-parent' -Root $rule3Parent -Depth 1 -Deny @($rule3Covered)),
        (New-PolicyEntry -Id 'lint-rule3-covered' -Root $rule3Covered -Depth 1),
        (New-PolicyEntry -Id 'lint-rule3-uncovered' -Root $rule3Uncovered -Depth 1),
        (New-PolicyEntry -Id 'lint-rule3-sibling' -Root $rule3Sibling -Depth 1)
    )
    $rule3Run = Invoke-Lint -PolicyPath $rule3PolicyPath -EvidenceRoot $rule3Evidence
    Assert-FindingKeys -Result $rule3Run.result -Scope '规则 3' -Expected @(
        'nested-root-not-denied|error|lint-rule3-parent|'
    )
    $rule3Finding = @(Get-Findings -Result $rule3Run.result -Rule 'nested-root-not-denied')[0]
    Assert-True ([string]$rule3Finding.detail -clike '*lint-rule3-uncovered*') '规则 3 发现必须指明未被覆盖的子条目 id'
    $nested = @(@($rule3Run.result.nestedRoots) | ForEach-Object {
            '{0}>{1}:{2}' -f $_.parentEntryId, $_.childEntryId, ([string]$_.covered).ToLowerInvariant()
        })
    Assert-True (($nested -join ';') -ceq 'lint-rule3-parent>lint-rule3-covered:true;lint-rule3-parent>lint-rule3-uncovered:false') (
        "嵌套关系清单不符：$($nested -join ';')")
    Assert-True ($rule3Run.result.policy.loadable -eq $true) '本票不改加载器：只违反规则 3 的 policy 仍可加载'
    Assert-TextExcludesPath -Text $rule3Run.text -Path $rule3Covered -Scope '规则 3 结果'
    Assert-TextExcludesPath -Text $rule3Run.text -Path $rule3Uncovered -Scope '规则 3 结果'

    # 5. 现有加载约束（重复 id、大小写不同的重复 root、深度 0 未声明用途）逐条报告；加载器拒绝整个
    #    policy 时另给一条 policy-load-refused，新规则照样评估——一次运行给出全部结构问题。
    $legacyRoot = Join-Path $scratchRoot 'legacy'
    $legacyA = Join-Path $legacyRoot 'root-a'
    $legacyB = Join-Path $legacyRoot 'root-b'
    $legacyC = Join-Path $legacyRoot 'root-c'
    $legacyD = Join-Path $legacyRoot 'root-d'
    $legacyDeepDeny = Join-Path $legacyD 'x\y'
    $legacyEvidence = Join-Path $legacyRoot 'evidence'
    $legacyPolicyPath = Join-Path $legacyRoot 'policy.json'
    foreach ($directory in @($legacyA, $legacyB, $legacyC, $legacyDeepDeny, $legacyEvidence)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Write-LintPolicy -Path $legacyPolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-dup' -Root $legacyA -Depth 1),
        (New-PolicyEntry -Id 'lint-dup' -Root $legacyB -Depth 1),
        (New-PolicyEntry -Id 'lint-dup-root' -Root $legacyA.ToUpperInvariant() -Depth 1),
        (New-PolicyEntry -Id 'lint-purpose' -Root $legacyC -Depth 0),
        (New-PolicyEntry -Id 'lint-deep' -Root $legacyD -Depth 1 -Deny @($legacyDeepDeny))
    )
    $legacyRun = Invoke-Lint -PolicyPath $legacyPolicyPath -EvidenceRoot $legacyEvidence
    Assert-FindingKeys -Result $legacyRun.result -Severity 'error' -Scope '现有加载约束' -Expected @(
        'policy-load-refused|error||',
        'duplicate-entry-id|error|lint-dup|',
        'duplicate-capability-root|error|lint-dup-root|',
        'depth-zero-purpose-required|error|lint-purpose|',
        'deny-deeper-than-minimum-depth|error|lint-deep|0'
    )
    Assert-True ($legacyRun.result.policy.loadable -eq $false) '加载器拒绝的 policy 必须标为不可加载'
    Assert-True ($legacyRun.result.policy.entryCount -eq 5 -and $legacyRun.result.policy.evaluatedEntryCount -eq 5) (
        '被拒绝的 policy 仍要逐条评估结构规则')
    $duplicateRoot = @(Get-Findings -Result $legacyRun.result -Rule 'duplicate-capability-root')[0]
    Assert-True ([string]$duplicateRoot.detail -clike '*lint-dup*') '重复 root 发现必须指明先出现的条目 id'

    # 6. 加载器的拒绝信息可能回显路径：Lint 转述时去掉路径，只留规则含义。deny 不合规的条目不参与
    #    新规则评估（evaluatedEntryCount 如实少计）。
    $redactRoot = Join-Path $scratchRoot 'redact'
    $redactCapabilityRoot = Join-Path $redactRoot 'root'
    $redactBadDeny = Join-Path $redactCapabilityRoot 'private*note'
    $redactEvidence = Join-Path $redactRoot 'evidence'
    $redactPolicyPath = Join-Path $redactRoot 'policy.json'
    foreach ($directory in @($redactCapabilityRoot, $redactEvidence)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Write-LintPolicy -Path $redactPolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-redact' -Root $redactCapabilityRoot -Depth 1 -Deny @($redactBadDeny))
    )
    $redactRun = Invoke-Lint -PolicyPath $redactPolicyPath -EvidenceRoot $redactEvidence
    Assert-FindingKeys -Result $redactRun.result -Severity 'error' -Scope '加载器拒绝信息' -Expected @(
        'policy-load-refused|error||'
    )
    $refusal = @(Get-Findings -Result $redactRun.result -Rule 'policy-load-refused')[0]
    Assert-True ([string]$refusal.detail -clike '*lint-redact*') '加载器拒绝发现必须保留规则含义（含条目 id）'
    Assert-True ($redactRun.result.policy.evaluatedEntryCount -eq 0) 'deny 不合规的条目不得参与新规则评估'
    Assert-TextExcludesPath -Text $redactRun.text -Path $redactBadDeny -Scope '加载器拒绝发现'
    Assert-True (-not $redactRun.text.Contains('private*note', [StringComparison]::OrdinalIgnoreCase)) '加载器拒绝发现回显了 deny 片段'

    # 7. 结构部分不依赖宿主：同一形状的 policy，root 全部不存在时的 error 与宿主齐备时逐条相同（含 detail）；
    #    宿主差异只体现为 warning：root 不存在、owner 不存在、deny 指向不存在的路径、evidence 根不存在。
    $hostPresentRoot = Join-Path $scratchRoot 'structure-host'
    $hostPresentBase = Join-Path $hostPresentRoot 'base'
    $hostPresentEvidence = Join-Path $hostPresentRoot 'evidence'
    $hostPresentPolicyPath = Join-Path $hostPresentRoot 'policy.json'
    foreach ($relative in @('parent\covered', 'parent\a\b', 'parent\uncovered', 'build', 'state')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $hostPresentBase $relative))
    }
    [void][IO.Directory]::CreateDirectory($hostPresentEvidence)
    Write-StructuralPolicy -Path $hostPresentPolicyPath -Base $hostPresentBase
    $noHostBase = 'D:\agents\projects\lint-nohost-' + [guid]::NewGuid().ToString('N')
    $noHostRoot = Join-Path $scratchRoot 'structure-nohost'
    $noHostEvidence = Join-Path $noHostRoot 'evidence-missing'
    $noHostPolicyPath = Join-Path $noHostRoot 'policy.json'
    Write-StructuralPolicy -Path $noHostPolicyPath -Base $noHostBase
    Assert-True (-not [IO.Directory]::Exists($noHostBase)) 'fixture 前提：无宿主 base 不得存在'

    $hostPresent = (Invoke-Lint -PolicyPath $hostPresentPolicyPath -EvidenceRoot $hostPresentEvidence).result
    $noHost = (Invoke-Lint -PolicyPath $noHostPolicyPath -EvidenceRoot $noHostEvidence).result
    $structuralErrors = @(
        'policy-load-refused|error||',
        'depth-zero-purpose-required|error|lint-s-purpose|',
        'deny-deeper-than-minimum-depth|error|lint-s-parent|1',
        'deny-on-depth-zero-entry|error|lint-s-build|0',
        'nested-root-not-denied|error|lint-s-parent|'
    )
    Assert-FindingKeys -Result $hostPresent -Severity 'error' -Scope '宿主齐备的结构规则' -Expected $structuralErrors
    Assert-FindingKeys -Result $hostPresent -Severity 'warning' -Scope '宿主齐备的宿主规则' -Expected @()
    Assert-True ((Get-ErrorSignature -Result $noHost) -ceq (Get-ErrorSignature -Result $hostPresent)) (
        "无宿主时结构 error 必须与宿主齐备时逐条相同：$(Format-Findings -Result $noHost)")
    $noHostWarnings = @('evidence-root-missing|warning||')
    foreach ($entryId in @('lint-s-parent', 'lint-s-covered', 'lint-s-uncovered', 'lint-s-build', 'lint-s-purpose')) {
        $noHostWarnings += "root-missing|warning|$entryId|"
        $noHostWarnings += "owner-missing|warning|$entryId|"
    }
    $noHostWarnings += @(
        'deny-target-missing|warning|lint-s-parent|0',
        'deny-target-missing|warning|lint-s-parent|1',
        'deny-target-missing|warning|lint-s-build|0'
    )
    Assert-FindingKeys -Result $noHost -Severity 'warning' -Scope '无宿主的宿主规则' -Expected $noHostWarnings
    Assert-True ($noHost.evidence.exists -eq $false) '不存在的 evidence 根必须标为不存在'
    Assert-True ($noHost.errorCount -eq 5 -and $noHost.warningCount -eq $noHostWarnings.Count) '无宿主运行的计数不符'
    Assert-True (-not [IO.Directory]::Exists($noHostEvidence)) 'Lint 不得创建 evidence 根'
    Assert-True (-not [IO.Directory]::Exists($noHostBase)) 'Lint 不得创建 root 或 owner'

    # 8. 宿主规则细节：文件型 deny、指向不存在路径的 deny、root 是文件；owner 按固定前缀推导
    #    （项目目录、worktree 目录、prd-210 下的 worktree），推导不出的 host 级 root 不做 owner 检查。
    #    deny 类发现只给条目 id 与 deny 序号，整份结果不含 deny 的完整路径或文件名。
    $hostRoot = Join-Path $scratchRoot 'host'
    $hostEvidence = Join-Path $hostRoot 'evidence'
    $hostPolicyPath = Join-Path $hostRoot 'policy.json'
    $filesRoot = Join-Path $hostRoot 'root-files'
    $fileDeny = Join-Path $filesRoot 'personal-note.txt'
    $missingDeny = Join-Path $filesRoot 'gone'
    $rootIsFile = Join-Path $hostRoot 'root-is-file'
    [void][IO.Directory]::CreateDirectory((Join-Path $filesRoot 'kept'))
    [void][IO.Directory]::CreateDirectory($hostEvidence)
    Write-Utf8File -Path $fileDeny -Text 'fixture'
    Write-Utf8File -Path $rootIsFile -Text 'fixture'
    $ownerToken = [guid]::NewGuid().ToString('N')
    $syntheticRoots = [ordered]@{
        'lint-h-project' = "D:\agents\projects\lint-owner-$ownerToken\a\b"
        'lint-h-codex' = "D:\Codex\projects\lint-owner-$ownerToken\a"
        'lint-h-prd' = "D:\agents\worktrees\prd-210\lint-owner-$ownerToken\a"
        'lint-h-worktree' = "D:\agents\worktrees\lint-owner-$ownerToken"
        'lint-h-host' = "D:\lint-fixture-host-$ownerToken\root"
    }
    foreach ($syntheticRoot in $syntheticRoots.Values) {
        Assert-True (-not [IO.Directory]::Exists($syntheticRoot) -and -not [IO.File]::Exists($syntheticRoot)) 'fixture 前提：合成 root 不得存在'
    }
    $hostEntries = @(
        (New-PolicyEntry -Id 'lint-h-files' -Root $filesRoot -Depth 1 -Deny @($fileDeny, $missingDeny, (Join-Path $filesRoot 'kept'))),
        (New-PolicyEntry -Id 'lint-h-root-file' -Root $rootIsFile -Depth 1)
    )
    foreach ($syntheticId in $syntheticRoots.Keys) {
        $hostEntries += New-PolicyEntry -Id $syntheticId -Root $syntheticRoots[$syntheticId] -Depth 1
    }
    Write-LintPolicy -Path $hostPolicyPath -Entries $hostEntries
    $hostRun = Invoke-Lint -PolicyPath $hostPolicyPath -EvidenceRoot $hostEvidence
    Assert-FindingKeys -Result $hostRun.result -Severity 'error' -Scope '宿主规则 fixture 的结构规则' -Expected @()
    Assert-FindingKeys -Result $hostRun.result -Severity 'warning' -Scope '宿主规则' -Expected @(
        'deny-target-is-file|warning|lint-h-files|0',
        'deny-target-missing|warning|lint-h-files|1',
        'root-missing|warning|lint-h-root-file|',
        'root-missing|warning|lint-h-project|',
        'owner-missing|warning|lint-h-project|',
        'root-missing|warning|lint-h-codex|',
        'owner-missing|warning|lint-h-codex|',
        'root-missing|warning|lint-h-prd|',
        'owner-missing|warning|lint-h-prd|',
        'root-missing|warning|lint-h-worktree|',
        'owner-missing|warning|lint-h-worktree|',
        'root-missing|warning|lint-h-host|'
    )
    $rootFileFinding = @(@(Get-Findings -Result $hostRun.result -Rule 'root-missing') | Where-Object { $_.entryId -ceq 'lint-h-root-file' })[0]
    Assert-True ([string]$rootFileFinding.detail -clike '*是文件*') 'root 是文件时 detail 必须说明'
    $ownerExpectations = [ordered]@{
        'lint-h-project' = @('project', '第 2 级')
        'lint-h-codex' = @('project', '第 1 级')
        'lint-h-prd' = @('worktree', '第 1 级')
        'lint-h-worktree' = @('worktree', 'root 本身')
    }
    foreach ($ownerEntryId in $ownerExpectations.Keys) {
        $ownerFinding = @(@(Get-Findings -Result $hostRun.result -Rule 'owner-missing') | Where-Object { $_.entryId -ceq $ownerEntryId })[0]
        foreach ($fragment in $ownerExpectations[$ownerEntryId]) {
            Assert-True ([string]$ownerFinding.detail -clike "*$fragment*") "$ownerEntryId 的 owner 推导不符：$($ownerFinding.detail)"
        }
    }
    foreach ($denyPath in @($fileDeny, $missingDeny)) {
        Assert-TextExcludesPath -Text $hostRun.text -Path $denyPath -Scope '宿主规则 deny 发现'
    }
    Assert-True (-not $hostRun.text.Contains('personal-note', [StringComparison]::OrdinalIgnoreCase)) '宿主规则发现回显了 deny 文件名'

    # 9. evidence 布局：run 目录是 evidence 根顶层、名字为 producer run id 的普通目录；规范位置是
    #    <evidence 根>\<顶层目录>\transaction.json（与 BatchPurge 历史扫描 C# 预筛的规范位置同口径）。
    #    其余位置的 transaction 只给数量和相对 run 的位置，不回显非 run 目录名；非 run 顶层目录只给数量。
    #    不跟随 reparse point。
    $layoutRoot = Join-Path $scratchRoot 'evidence-layout'
    $layoutEvidence = Join-Path $layoutRoot 'evidence'
    $layoutOutside = Join-Path $layoutRoot 'outside'
    $layoutPolicyPath = Join-Path $layoutRoot 'policy.json'
    $layoutCapabilityRoot = Join-Path $layoutRoot 'root'
    $runIds = @(1..4 | ForEach-Object { '20261012T000000Z-00000000-0000-4000-8000-{0:d12}' -f $_ })
    [void][IO.Directory]::CreateDirectory($layoutCapabilityRoot)
    Write-LintPolicy -Path $layoutPolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-layout' -Root $layoutCapabilityRoot -Depth 1)
    )
    foreach ($relative in @(
            "$($runIds[0])\plan.json",
            "$($runIds[0])\transaction.json",
            "$($runIds[1])\transaction.json",
            "$($runIds[1])\nested\transaction.json",
            "$($runIds[2])\plan.json",
            "legacy-import\$($runIds[3])\transaction.json",
            'stray\transaction.json',
            'stray\sub\transaction.json',
            'transaction.json',
            'README.txt')) {
        Write-Utf8File -Path (Join-Path $layoutEvidence $relative) -Text '{}'
    }
    Write-Utf8File -Path (Join-Path $layoutOutside 'transaction.json') -Text '{}'
    $layoutJunction = Join-Path $layoutEvidence 'junction-out'
    $junctionOutput = & $env:ComSpec /d /c mklink /J $layoutJunction $layoutOutside 2>&1
    if ($LASTEXITCODE -ne 0) { throw "无法创建 evidence junction fixture：$junctionOutput" }
    $junctionPaths.Add($layoutJunction)

    $layout = (Invoke-Lint -PolicyPath $layoutPolicyPath -EvidenceRoot $layoutEvidence).result
    Assert-True ($layout.evidence.exists -eq $true) 'evidence 根存在时必须如实标记'
    Assert-True ($layout.evidence.runDirectories -eq 3) "run 目录数不符：$($layout.evidence.runDirectories)"
    Assert-True ($layout.evidence.nonRunTopLevelDirectories -eq 3) "非 run 顶层目录数不符：$($layout.evidence.nonRunTopLevelDirectories)"
    Assert-True ($layout.evidence.transactionFiles -eq 7) "transaction 文件数不符（不得跟随 junction）：$($layout.evidence.transactionFiles)"
    Assert-True ($layout.evidence.nonCanonicalTransactionFiles -eq 4) "非规范 transaction 数不符：$($layout.evidence.nonCanonicalTransactionFiles)"
    Assert-FindingKeys -Result $layout -Scope 'evidence 布局' -Expected @(
        'evidence-noncanonical-transaction|warning||',
        'evidence-noncanonical-transaction|warning||',
        'evidence-noncanonical-transaction|warning||',
        'evidence-noncanonical-transaction|warning||',
        'evidence-non-run-top-level-directories|warning||'
    )
    $positions = @(@(Get-Findings -Result $layout -Rule 'evidence-noncanonical-transaction') | ForEach-Object { [string]$_.detail } | Sort-Object)
    $expectedPositions = @(
        "位于 run 目录 $($runIds[1]) 内第 2 层。",
        "位于 run 目录 $($runIds[3]) 内第 1 层；该 run 目录位于 evidence 根下第 2 层。",
        '不在任何 run 目录内，位于 evidence 根下第 3 层。',
        '不在任何 run 目录内，位于 evidence 根下第 1 层。'
    ) | Sort-Object
    Assert-True (($positions -join "`n") -ceq ($expectedPositions -join "`n")) "非规范 transaction 的位置描述不符：$($positions -join ' | ')"
    $nonRunFinding = @(Get-Findings -Result $layout -Rule 'evidence-non-run-top-level-directories')[0]
    Assert-True ([string]$nonRunFinding.detail -clike '*3*') '非 run 顶层目录发现必须给出数量'
    $layoutText = $layout | ConvertTo-Json -Depth 12 -Compress
    foreach ($name in @('legacy-import', 'stray', 'junction-out', 'README')) {
        Assert-True (-not $layoutText.Contains($name, [StringComparison]::OrdinalIgnoreCase)) "evidence 布局报告回显了目录或文件名：$name"
    }

    # 10. 全程只读，只报告不拦截：policy 有 error、evidence 有 warning 时，Lint 前后整个 fixture 树
    #     （policy、evidence、junction 指向的外部目录、capability root）逐项不变；结果没有 refusalReason，
    #     生产入口按既有 JSON 合同（只有 leaf-delete-failed 退出 1）退出 0。
    $readOnlyPolicyPath = Join-Path $layoutRoot 'policy-with-errors.json'
    Write-LintPolicy -Path $readOnlyPolicyPath -Entries @(
        (New-PolicyEntry -Id 'lint-readonly' -Root $layoutCapabilityRoot -Depth 0 -Purpose 'rebuildable-build-output' -Deny @((Join-Path $layoutCapabilityRoot 'kept')))
    )
    $stateBefore = Get-TreeState -Root $layoutRoot
    $readOnlyRun = Invoke-Lint -PolicyPath $readOnlyPolicyPath -EvidenceRoot $layoutEvidence
    $stateAfter = Get-TreeState -Root $layoutRoot
    if ($stateAfter -cne $stateBefore) {
        $changedLines = @(Compare-Object -ReferenceObject ($stateBefore -split "`n") -DifferenceObject ($stateAfter -split "`n") -CaseSensitive |
            ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject })
        throw "Lint 改动了 policy 或 evidence：$($changedLines -join '; ')"
    }
    Assert-True ($readOnlyRun.result.policy.loadable -eq $true) '只读 fixture 的 policy 应能被现役加载器加载'
    Assert-True ($readOnlyRun.result.errorCount -gt 0 -and $readOnlyRun.result.warningCount -gt 0) (
        "只读 fixture 应同时有 error 与 warning：$(Format-Findings -Result $readOnlyRun.result)")
    Assert-True ($readOnlyRun.result.PSObject.Properties.Name -cnotcontains 'refusalReason') (
        'Lint 结果不得带 refusalReason：Lint 只报告、不拦截，入口退出码必须为 0')
} finally {
    foreach ($junctionPath in $junctionPaths) {
        if ([IO.Directory]::Exists($junctionPath)) { & $env:ComSpec /d /c rmdir $junctionPath | Out-Null }
    }
    Remove-TestTree -Path $scratchRoot
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteLint'
}
