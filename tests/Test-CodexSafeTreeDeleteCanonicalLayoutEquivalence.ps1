[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #95，Lint 与 BatchPurge 历史预筛的规范位置等价性):
# 1. PowerShell Lint 布局函数 Get-CodexSafeTreeDeleteLintEvidenceLayout（Lint mode evidence
#    布局结论的唯一实现）：transactionFiles 与 nonCanonicalTransactions。
# 2. C# 预筛 StatusScanCoordinator.ClassifyBatchHistoryTransaction（BatchPurge
#    historyScan.canonicalFiles / fallbackFiles 的来源）：decision 不是 Fallback 即位置判定通过。
# 对同一 evidence 根下同一个 transaction.json 逐文件断言：Lint 判为规范位置，当且仅当预筛的
# 位置判定通过。fixture 的 transaction 一律用 producer v2 规范形态（预筛对内容形态不合规的
# 文件也会 Fallback），C# 侧结论因此只由位置与路径链决定；经 junction 可达的文件两边都不算
# 规范：Lint 不枚举，预筛经 reparse 祖先检查回退。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'canonicallayout'
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
        -Name 'safe-delete canonical layout equivalence test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete canonical layout equivalence test cleanup'
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

try {
    $fixtureRoot = Join-Path $scratchRoot 'layout'
    $evidenceRoot = Join-Path $fixtureRoot 'evidence'
    $outsideRoot = Join-Path $fixtureRoot 'outside'
    [void][IO.Directory]::CreateDirectory($evidenceRoot)

    $runA = '20261021T000000Z-00000000-0000-4000-8000-000000000001'
    $runB = '20261021T000000Z-00000000-0000-4000-8000-000000000002'
    $runC = '20261021T000000Z-00000000-0000-4000-8000-000000000003'

    # producer v2 规范形态（与 tests/Test-CodexSafeTreeDeleteBatchHistoryScan.ps1 的
    # New-ProducerTransactionProperties 同形）：预筛据此只按位置与路径链裁决；终态 status
    # 让规范位置的文件一律 Excluded，位置或路径链不合规一律 Fallback。
    $transactionText = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-transaction'
        schemaVersion = 2L
        generationId = 'canonical-layout-equivalence'
        planPath = Join-Path $fixtureRoot 'plan.json'
        planSha256 = '0' * 64
        targetPath = Join-Path $fixtureRoot 'target'
        quarantinePath = Join-Path $fixtureRoot 'quarantine'
        directoryCommitAnchors = @()
        status = 'purged'
        updatedAtUtc = '2026-01-01T00:00:00.0000000Z'
    } | ConvertTo-Json -Depth 8

    # 布局用例（acceptance：六种布局逐文件断言两边结论相同）。expectedCanonical 是规范位置
    # 定义的独立判读：相对 evidence 根恰好两段（顶层目录是否 run 目录不影响）；junction 可达
    # 的文件两边都不算规范。lintEnumerates 表示 Lint 的不跟随 reparse 枚举能不能看到该文件。
    $layoutCases = @(
        [pscustomobject]@{ name = 'run 目录直下'; relative = "$runA\transaction.json"; expectedCanonical = $true; lintEnumerates = $true },
        [pscustomobject]@{ name = 'run 目录内多层嵌套'; relative = "$runB\nested\deeper\transaction.json"; expectedCanonical = $false; lintEnumerates = $true },
        [pscustomobject]@{ name = '非 run 名字的顶层目录直下'; relative = 'stray\transaction.json'; expectedCanonical = $true; lintEnumerates = $true },
        [pscustomobject]@{ name = '非 run 顶层目录里再套 run 目录'; relative = "legacy-import\$runC\transaction.json"; expectedCanonical = $false; lintEnumerates = $true },
        [pscustomobject]@{ name = 'evidence 根直下'; relative = 'transaction.json'; expectedCanonical = $false; lintEnumerates = $true },
        [pscustomobject]@{ name = '经 junction 可达'; relative = 'junction-out\transaction.json'; expectedCanonical = $false; lintEnumerates = $false }
    )
    foreach ($case in @($layoutCases | Where-Object { $_.lintEnumerates })) {
        Write-Utf8File -Path (Join-Path $evidenceRoot $case.relative) -Text $transactionText
    }
    Write-Utf8File -Path (Join-Path $outsideRoot 'transaction.json') -Text $transactionText
    $layoutJunction = Join-Path $evidenceRoot 'junction-out'
    $junctionOutput = & $env:ComSpec /d /c mklink /J $layoutJunction $outsideRoot 2>&1
    if ($LASTEXITCODE -ne 0) { throw "无法创建 evidence junction fixture：$junctionOutput" }
    $junctionPaths.Add($layoutJunction)

    # Lint 侧结论：枚举计数与非规范清单共同钉死「逐文件是否规范、是否被枚举」。
    $layout = Get-CodexSafeTreeDeleteLintEvidenceLayout -FullEvidenceRoot $evidenceRoot
    Assert-True ($layout.runDirectories -eq 2) "run 目录数不符（runC 嵌套在非 run 顶层目录内，不计）：$($layout.runDirectories)"
    Assert-True ($layout.nonRunTopLevelDirectories -eq 3) "非 run 顶层目录数不符：$($layout.nonRunTopLevelDirectories)"
    Assert-True ($layout.transactionFiles -eq 5) "transaction 文件数不符（不得跟随 junction）：$($layout.transactionFiles)"
    $nonCanonicalRelative = @($layout.nonCanonicalTransactions | ForEach-Object { [string]$_.relativePath })
    $expectedNonCanonical = @(
        "$runB\nested\deeper\transaction.json",
        "legacy-import\$runC\transaction.json",
        'transaction.json'
    ) | Sort-Object -CaseSensitive
    Assert-True ((($nonCanonicalRelative | Sort-Object -CaseSensitive) -join "`n") -ceq ($expectedNonCanonical -join "`n")) (
        "非规范 transaction 清单不符：$($nonCanonicalRelative -join '; ')")
    Assert-True ($nonCanonicalRelative -cnotcontains 'junction-out\transaction.json') 'Lint 不得枚举 junction 内的 transaction.json'

    # 逐文件等价：Lint 规范位置 ⟺ 预筛位置判定通过（decision 不是 Fallback）。
    $fallbackDecision = [CodexSafeTreeDelete.BatchHistoryPrefilterDecision]::Fallback
    $excludedDecision = [CodexSafeTreeDelete.BatchHistoryPrefilterDecision]::Excluded
    $prefilterTargets = [string[]]@((Join-Path $fixtureRoot 'not-a-batch-target'))
    foreach ($case in $layoutCases) {
        $lintCanonical = $case.lintEnumerates -and ($nonCanonicalRelative -cnotcontains $case.relative)
        $fullPath = Join-Path $evidenceRoot $case.relative
        $decision = [CodexSafeTreeDelete.StatusScanCoordinator]::ClassifyBatchHistoryTransaction(
            $fullPath, $evidenceRoot, $prefilterTargets)
        $prefilterCanonical = $decision -ne $fallbackDecision
        Assert-True ($lintCanonical -eq $prefilterCanonical) (
            "$($case.name)：Lint 规范位置结论（$lintCanonical）与预筛位置判定（$prefilterCanonical，decision=$decision）不一致")
        Assert-True ($prefilterCanonical -eq $case.expectedCanonical) (
            "$($case.name)：位置结论不符合规范位置定义（期望 $($case.expectedCanonical)，decision=$decision）")
        $expectedDecision = if ($case.expectedCanonical) { $excludedDecision } else { $fallbackDecision }
        Assert-True ($decision -eq $expectedDecision) (
            "$($case.name)：预筛裁决不符（期望 $expectedDecision，实际 $decision）；规范位置且形态合规应 Excluded，其余应 Fallback")
    }

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteCanonicalLayoutEquivalence'
    }
} finally {
    foreach ($junctionPath in $junctionPaths) {
        if ([IO.Directory]::Exists($junctionPath)) { & $env:ComSpec /d /c rmdir $junctionPath | Out-Null }
    }
    Remove-TestTree -Path $scratchRoot
}
