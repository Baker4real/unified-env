[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #84，spec #73「实现决策 › 加载器结构规则」):
# 加载器 Read-CodexSafeTreeDeletePolicy 读 fixture policy 文件，以及 fixture 入口
# tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 Check mode。三条结构规则各有一份合规、一份违规的 fixture
# policy；违规时整个 policy fail-closed，拒绝原文含规则名、条目 id 与 deny 序号，不含任何路径。
# CI 在仓库副本里按字母序 fail-fast 运行本套件，所以先从非宿主视角自检：读写的路径全部由本文件位置推导、
# 位于仓库内，不依赖宿主上的 root、owner 或 evidence。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'policystructure'
$evidenceRoot = Join-Path $scratchRoot 'evidence'
# deny 的叶名带随机记号：拒绝原文与结果里出现它就说明回显了 deny 路径。
$denyToken = 'personal-' + [guid]::NewGuid().ToString('N')

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
        -Name 'safe-delete policy structure test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete policy structure test cleanup'
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

function Write-Policy {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Entries)

    $policy = [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @($Entries)
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, ($policy | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}

function Get-ThrownMessage {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Label)

    try { & $Action | Out-Null } catch { return [string]$_.Exception.Message }
    throw "$Label：必须抛出拒绝，实际放行"
}

function Assert-NoPathInText {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Label)

    Assert-True ($Text -notmatch '(?i)(?<![a-z0-9])[a-z]:[\\/]') "$Label 回显了盘符路径：$Text"
    Assert-True (-not $Text.Contains((Split-Path -Leaf $scratchRoot), [StringComparison]::OrdinalIgnoreCase)) (
        "$Label 回显了 fixture 路径：$Text")
    Assert-True (-not $Text.Contains($denyToken, [StringComparison]::OrdinalIgnoreCase)) "$Label 回显了 deny 路径：$Text"
}

function Assert-StructureRefusal {
    # 违规 policy：加载器与 fixture 入口（Check，显式 CapabilityRoot）都以同一原文拒绝；原文含规则名、
    # 条目 id 与 deny 序号（有时），且不含路径。
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$Label
    )

    $loaderMessage = Get-ThrownMessage -Label "$Label（加载器）" -Action {
        Read-CodexSafeTreeDeletePolicy -PolicyPath $PolicyPath
    }
    Assert-True ($loaderMessage.Contains($Expected)) "$Label：加载器拒绝原文必须含「$Expected」，实际：$loaderMessage"
    Assert-NoPathInText -Text $loaderMessage -Label "$Label 加载器拒绝原文"
    $entryMessage = Get-ThrownMessage -Label "$Label（fixture 入口）" -Action {
        & $entryPath -Mode Check -TargetPath $TargetPath -CapabilityRoot $CapabilityRoot -Json `
            -FixturePolicyPath $PolicyPath -FixtureEvidenceRoot $evidenceRoot
    }
    Assert-True ($entryMessage -ceq $loaderMessage) "$Label：fixture 入口必须以加载器原文拒绝，实际：$entryMessage"
    return $loaderMessage
}

function Invoke-CheckAllowed {
    # 合规 policy：fixture 入口的 Check 放行目标，并由预期条目覆盖。
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedEntryId,
        [Parameter(Mandatory)][string]$Label
    )

    $output = @(& $entryPath -Mode Check @Arguments -Json -FixturePolicyPath $PolicyPath -FixtureEvidenceRoot $evidenceRoot)
    Assert-True ($output.Count -eq 1) "$Label：Check -Json 必须只输出一行 JSON"
    $row = @(([string]$output[0] | ConvertFrom-Json -Depth 32).results)[0]
    Assert-True ($row.allowed -eq $true -and [string]$row.policyEntryId -ceq $ExpectedEntryId) (
        "$Label：合规 policy 下 Check 必须由 $ExpectedEntryId 放行：$($output[0])")
}

try {
    # 0. 自检（非宿主视角）：仓库 policy、fixture 入口与 scratch 根都由本文件位置推导并位于仓库内；
    #    本套件源码不写任何盘符绝对路径，fixture policy 的 root 与 deny 全部建在 scratch 根下。
    $repoPolicyPath = Join-Path $projectRoot 'managed\safe-tree-delete\policy.json'
    Assert-True ([IO.File]::Exists($repoPolicyPath)) '自检：仓库 policy 必须位于本文件所在仓库内的固定位置'
    foreach ($ownPath in @($repoPolicyPath, $entryPath, $scratchRoot)) {
        Assert-True (Test-CodexHookPathWithin -Path $ownPath -ParentPath $projectRoot) '自检：本套件读写的路径必须位于仓库内'
    }
    Assert-True ([IO.File]::ReadAllText($PSCommandPath) -notmatch '(?i)(?<![a-z0-9])[a-z]:\\') (
        '自检：本套件源码不得写死盘符绝对路径，路径一律由本文件位置推导')

    # 1. 规则 1（deny-deeper-than-minimum-depth）：deny 相对所属 root 的深度 ≤ 最小后代深度。深度等于
    #    最小后代深度的 deny 合规；更深的 deny 能经删除其祖先目录绕过，整个 policy 拒绝加载。
    $rule1Workspace = Join-Path $scratchRoot 'rule1\workspace'
    $rule1Shallow = Join-Path $rule1Workspace 'keep'
    $rule1Deep = Join-Path $rule1Shallow $denyToken
    $rule1Target = Join-Path $rule1Workspace 'cache\entry'
    foreach ($directory in @($rule1Deep, $rule1Target)) { [void][IO.Directory]::CreateDirectory($directory) }
    $rule1CompliantPath = Join-Path $scratchRoot 'rule1\compliant-policy.json'
    $rule1ViolatingPath = Join-Path $scratchRoot 'rule1\violating-policy.json'
    Write-Policy -Path $rule1CompliantPath -Entries @(
        (New-PolicyEntry -Id 'structure-rule1' -Root $rule1Workspace -Depth 2 -Deny @($rule1Shallow, $rule1Deep))
    )
    Write-Policy -Path $rule1ViolatingPath -Entries @(
        (New-PolicyEntry -Id 'structure-rule1' -Root $rule1Workspace -Depth 1 -Deny @($rule1Shallow, $rule1Deep))
    )
    Assert-True (@((Read-CodexSafeTreeDeletePolicy -PolicyPath $rule1CompliantPath).entries).Count -eq 1) (
        '规则 1 合规：deny 深度等于最小后代深度的 policy 必须可加载')
    Invoke-CheckAllowed -PolicyPath $rule1CompliantPath -ExpectedEntryId 'structure-rule1' -Label '规则 1 合规' -Arguments @{
        TargetPath = $rule1Target
        CapabilityRoot = $rule1Workspace
    }
    $rule1Message = Assert-StructureRefusal -PolicyPath $rule1ViolatingPath -Label '规则 1 违规' `
        -Expected 'deny-deeper-than-minimum-depth（条目 structure-rule1，deniedExactPaths[1]）' `
        -TargetPath $rule1Shallow -CapabilityRoot $rule1Workspace
    Assert-True ($rule1Message.Contains('deny 深度 2 大于最小后代深度 1')) "规则 1 违规：拒绝原文必须说明深度：$rule1Message"

    # 2. 规则 2（deny-on-depth-zero-entry）：最小后代深度为 0 的条目允许删除 root 本身，带 deny 也拦不住，
    #    所以不得带 deny。深度 0 条目用 retired-evidence-root 用途：它只要求 root 是 run-evidence(-analog)
    #    下的一级目录，不依赖仓库所在位置。
    $rule2Root = Join-Path $scratchRoot "rule2\run-evidence-analog\retired-$denyToken"
    [void][IO.Directory]::CreateDirectory($rule2Root)
    $rule2CompliantPath = Join-Path $scratchRoot 'rule2\compliant-policy.json'
    $rule2ViolatingPath = Join-Path $scratchRoot 'rule2\violating-policy.json'
    Write-Policy -Path $rule2CompliantPath -Entries @(
        (New-PolicyEntry -Id 'structure-rule2' -Root $rule2Root -Depth 0 -Purpose 'retired-evidence-root')
    )
    Write-Policy -Path $rule2ViolatingPath -Entries @(
        (New-PolicyEntry -Id 'structure-rule2' -Root $rule2Root -Depth 0 -Purpose 'retired-evidence-root' -Deny @($rule2Root))
    )
    Assert-True (@((Read-CodexSafeTreeDeletePolicy -PolicyPath $rule2CompliantPath).entries).Count -eq 1) (
        '规则 2 合规：不带 deny 的深度 0 条目必须可加载')
    Invoke-CheckAllowed -PolicyPath $rule2CompliantPath -ExpectedEntryId 'structure-rule2' -Label '规则 2 合规' -Arguments @{
        TargetPath = $rule2Root
        CapabilityRoot = $rule2Root
    }
    $rule2Message = Assert-StructureRefusal -PolicyPath $rule2ViolatingPath -Label '规则 2 违规' `
        -Expected 'deny-on-depth-zero-entry（条目 structure-rule2，deniedExactPaths[0]）' `
        -TargetPath $rule2Root -CapabilityRoot $rule2Root
    Assert-True (-not $rule2Message.Contains('共 ')) "规则 2 违规：只有一处违例时不得报告总数：$rule2Message"

    # 3. 规则 3（nested-root-not-denied）：某条 root 严格位于另一条 root 之内时，父条目必须有一条 deny 精确
    #    等于子 root，否则传入父 root 就能绕过子条目的约束。只共享字符串前缀的兄弟目录不算嵌套。合规时
    #    子 root 下的目标只有子条目能合法覆盖，省略 CapabilityRoot 也唯一解析到子条目。
    $rule3Parent = Join-Path $scratchRoot 'rule3\parent'
    $rule3Child = Join-Path $rule3Parent 'child'
    $rule3Sibling = Join-Path $scratchRoot 'rule3\parent-sibling'
    $rule3Leaf = Join-Path $rule3Child 'leaf'
    $rule3SiblingTarget = Join-Path $rule3Sibling 'stale'
    foreach ($directory in @($rule3Leaf, $rule3SiblingTarget)) { [void][IO.Directory]::CreateDirectory($directory) }
    $rule3CompliantPath = Join-Path $scratchRoot 'rule3\compliant-policy.json'
    $rule3ViolatingPath = Join-Path $scratchRoot 'rule3\violating-policy.json'
    Write-Policy -Path $rule3CompliantPath -Entries @(
        (New-PolicyEntry -Id 'structure-rule3-parent' -Root $rule3Parent -Depth 1 -Deny @($rule3Child)),
        (New-PolicyEntry -Id 'structure-rule3-child' -Root $rule3Child -Depth 1),
        (New-PolicyEntry -Id 'structure-rule3-sibling' -Root $rule3Sibling -Depth 1)
    )
    Write-Policy -Path $rule3ViolatingPath -Entries @(
        (New-PolicyEntry -Id 'structure-rule3-parent' -Root $rule3Parent -Depth 1),
        (New-PolicyEntry -Id 'structure-rule3-child' -Root $rule3Child -Depth 1),
        (New-PolicyEntry -Id 'structure-rule3-sibling' -Root $rule3Sibling -Depth 1)
    )
    Assert-True (@((Read-CodexSafeTreeDeletePolicy -PolicyPath $rule3CompliantPath).entries).Count -eq 3) (
        '规则 3 合规：父条目 deny 精确覆盖子 root 的 policy 必须可加载')
    Invoke-CheckAllowed -PolicyPath $rule3CompliantPath -ExpectedEntryId 'structure-rule3-child' -Label '规则 3 合规' -Arguments @{
        TargetPath = $rule3Leaf
    }
    # 整个 policy fail-closed：本身合规的兄弟条目下的目标同样被拒绝，不部分采用。
    $rule3Message = Assert-StructureRefusal -PolicyPath $rule3ViolatingPath -Label '规则 3 违规' `
        -Expected 'nested-root-not-denied（条目 structure-rule3-parent）' `
        -TargetPath $rule3SiblingTarget -CapabilityRoot $rule3Sibling
    Assert-True ($rule3Message.Contains('子条目 structure-rule3-child')) "规则 3 违规：拒绝原文必须指明未被覆盖的子条目：$rule3Message"
    Assert-True (-not $rule3Message.Contains('deniedExactPaths[')) "规则 3 违规：嵌套违例没有 deny 序号：$rule3Message"

    # 4. 多处违例：拒绝原文给出第一处违例（条目顺序下先规则 1、2，再规则 3）和违例总数。
    $combinedPath = Join-Path $scratchRoot 'combined-policy.json'
    Write-Policy -Path $combinedPath -Entries @(
        (New-PolicyEntry -Id 'structure-rule1' -Root $rule1Workspace -Depth 1 -Deny @($rule1Shallow, $rule1Deep)),
        (New-PolicyEntry -Id 'structure-rule2' -Root $rule2Root -Depth 0 -Purpose 'retired-evidence-root' -Deny @($rule2Root)),
        (New-PolicyEntry -Id 'structure-rule3-parent' -Root $rule3Parent -Depth 1),
        (New-PolicyEntry -Id 'structure-rule3-child' -Root $rule3Child -Depth 1)
    )
    $combinedMessage = Assert-StructureRefusal -PolicyPath $combinedPath -Label '多处违例' `
        -Expected 'deny-deeper-than-minimum-depth（条目 structure-rule1，deniedExactPaths[1]）' `
        -TargetPath $rule3Leaf -CapabilityRoot $rule3Child
    Assert-True ($combinedMessage.Contains('共 3 处结构违例')) "多处违例：拒绝原文必须给出违例总数：$combinedMessage"
} finally {
    Remove-TestTree -Path $scratchRoot
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeletePolicyStructure'
}
