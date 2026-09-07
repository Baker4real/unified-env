[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 Wave A 等价性测试：C# 单遍 Plan walker 与 PowerShell 三遍路径在同一未变树上
# 产物等价（保序逐位 + 词法断言）、开关/env 路由、metrics 等值与负路径失败闭锁对齐。
# 依据 docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md §5。

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$libraryPath = Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1'
$fixtureRoot = Join-Path $projectRoot ("reports\safe-tree-delete-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$linkAwarePolicyPath = Join-Path $fixtureRoot 'link-aware-policy.json'
$emptyProjectPolicyPath = Join-Path $fixtureRoot 'empty-project-policy.json'

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

function Remove-TestTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$LinkAware
    )

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshotArguments = @{
        Path = $Path
        CapabilityRoot = $parent
        AllowedExactPaths = @($Path)
        Name = 'safe-delete plan walker equivalence cleanup snapshot'
    }
    $removeArguments = @{
        Path = $Path
        CapabilityRoot = $parent
        AllowedExactPaths = @($Path)
        Scope = 'safe-delete plan walker equivalence cleanup'
    }
    if ($LinkAware) {
        $snapshotArguments.AllowHardLinks = $true
        $snapshotArguments.AllowInternalDirectoryJunctions = $true
        $snapshotArguments.InternalDirectoryJunctionTargetRoot = $Path
        $removeArguments.AllowHardLinks = $true
        $removeArguments.AllowInternalDirectoryJunctions = $true
        $removeArguments.InternalDirectoryJunctionTargetRoot = $Path
    }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot @snapshotArguments
    Remove-CodexHookCapabilityDirectoryTree `
        @removeArguments `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot
}

function Invoke-EquivalencePlan {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$Policy,
        [switch]$UsePowerShellWalker
    )

    $planArguments = @{
        TargetPath = $Path
        CapabilityRoot = $CapabilityRoot
        PolicyPath = $Policy
        EvidenceRoot = $evidenceRoot
    }
    if ($UsePowerShellWalker) {
        $planArguments.DisablePlanCSharpWalkerForTest = $true
    }
    return (New-CodexSafeTreeDeletePlan @planArguments)
}

function Read-PlanDocument {
    param([Parameter(Mandatory)][string]$PlanPath)

    return (Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json -Depth 128 -DateKind String)
}

function ConvertTo-EquivalenceUInt64Text {
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Scope
    )

    if ($null -eq $Value -or $Value -is [string] -or
        ($Value -isnot [long] -and $Value -isnot [int] -and
            $Value -isnot [UInt64] -and $Value -isnot [Numerics.BigInteger])) {
        throw "$Scope 必须是 uint64 范围内的 JSON number。"
    }
    $bigValue = [Numerics.BigInteger]$Value
    if ($bigValue -lt [Numerics.BigInteger]::Zero -or
        $bigValue -gt [Numerics.BigInteger][UInt64]::MaxValue) {
        throw "$Scope 必须是 uint64 范围内的 JSON number。"
    }
    return $bigValue.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Compare-PlanDocuments {
    param(
        [Parameter(Mandatory)][object]$CSharpPlanPath,
        [Parameter(Mandatory)][object]$PowerShellPlanPath
    )

    $csharp = Read-PlanDocument -PlanPath ([string]$CSharpPlanPath)
    $powershell = Read-PlanDocument -PlanPath ([string]$PowerShellPlanPath)

    foreach ($label in @('artifactType', 'schemaVersion', 'policyEntryId', 'targetPath', 'capabilityRoot')) {
        if ([string]$csharp.$label -cne [string]$powershell.$label) { throw "等价性失败：$label 不一致" }
    }
    Assert-True ([long]$csharp.schemaVersion -eq 1L) 'plan schemaVersion 必须保持 1'
    Assert-True ([long]$csharp.treeManifest.schemaVersion -eq 2L) 'treeManifest schemaVersion 必须保持 2'

    $entriesA = @($csharp.treeManifest.entries)
    $entriesB = @($powershell.treeManifest.entries)
    Assert-True ($entriesA.Count -eq $entriesB.Count -and $entriesA.Count -gt 0) 'treeManifest 条目数必须一致且非空'
    for ($index = 0; $index -lt $entriesA.Count; $index++) {
        $left = $entriesA[$index]
        $right = $entriesB[$index]
        if ([string]$left.relativePath -cne [string]$right.relativePath) {
            throw "等价性失败：entries[$index] 顺序或路径不一致（$($left.relativePath) vs $($right.relativePath)）"
        }
        if ([string]$left.kind -cne [string]$right.kind) { throw "等价性失败：$($left.relativePath) kind 不一致" }
        if ([string]$left.sha256 -cne [string]$right.sha256) { throw "等价性失败：$($left.relativePath) sha256 不一致" }
        $identityA = @($left.identity)
        $identityB = @($right.identity)
        Assert-True ($identityA.Count -eq 2 -and $identityB.Count -eq 2) "等价性失败：$($left.relativePath) identity 必须是二元数组"
        if ([string]$identityA[0] -cne [string]$identityB[0] -or
            [string]$identityA[1] -cne [string]$identityB[1]) {
            throw "等价性失败：$($left.relativePath) identity 不一致"
        }
        if ($identityA[0] -cnotmatch '^[0-9a-f]{8}$' -or $identityA[1] -cnotmatch '^[0-9a-f]{16}$') {
            throw "等价性失败：$($left.relativePath) identity 词法必须是 lower-hex 8/16"
        }
        if ([string]$left.kind -ceq 'file' -and [string]$left.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "等价性失败：$($left.relativePath) file sha256 词法非法"
        }
        if ([string]$left.kind -ceq 'directory' -and $null -ne $left.sha256) {
            throw "等价性失败：$($left.relativePath) directory sha256 必须为 null"
        }
    }

    $idsA = @($csharp.fileIdentitiesV2)
    $idsB = @($powershell.fileIdentitiesV2)
    Assert-True ($idsA.Count -eq $idsB.Count) 'fileIdentitiesV2 条数必须一致'
    for ($index = 0; $index -lt $idsA.Count; $index++) {
        $left = $idsA[$index]
        $right = $idsB[$index]
        $expectedProperties = @(
            'capturedAtUtc', 'fileId128', 'fileSize', 'lastWriteTimeUtc', 'relativePath', 'volumeSerialNumber')
        $actualA = @($left.PSObject.Properties.Name)
        Assert-True (
            (@($actualA | Where-Object { $_ -notin $expectedProperties }).Count -eq 0 -and
                @($expectedProperties | Where-Object { $_ -notin $actualA }).Count -eq 0)
        ) "等价性失败：fileIdentitiesV2[$index] 属性集合非法"
        if ([string]$left.relativePath -cne [string]$right.relativePath) {
            throw "等价性失败：fileIdentitiesV2[$index] 顺序或路径不一致"
        }
        if ([string]$left.fileId128 -cne [string]$right.fileId128) {
            throw "等价性失败：$($left.relativePath) fileId128 不一致"
        }
        if ([long]$left.fileSize -ne [long]$right.fileSize) {
            throw "等价性失败：$($left.relativePath) fileSize 不一致"
        }
        Assert-True ($left.fileSize -is [long]) 'fileSize 必须是 JSON integer'
        if ([string]$left.lastWriteTimeUtc -cne [string]$right.lastWriteTimeUtc) {
            throw "等价性失败：$($left.relativePath) lastWriteTimeUtc 不一致"
        }
        $serialLeft = ConvertTo-EquivalenceUInt64Text -Value $left.volumeSerialNumber -Scope "fileIdentitiesV2[$index] volumeSerialNumber"
        $serialRight = ConvertTo-EquivalenceUInt64Text -Value $right.volumeSerialNumber -Scope "fileIdentitiesV2[$index] volumeSerialNumber"
        if ([string]$serialLeft -cne [string]$serialRight) {
            throw "等价性失败：$($left.relativePath) volumeSerialNumber 不一致"
        }
        Assert-True ([Convert]::FromBase64String([string]$left.fileId128).Length -eq 16) 'fileId128 必须是 16 字节 Base64'
    }

    foreach ($plan in @($csharp, $powershell)) {
        Assert-True ([long]$plan.leafStreamSetV1.schemaVersion -eq 1L) 'leafStreamSetV1 schemaVersion 必须是 1'
        $boundary = $plan.leafStreamSetV1.consumptionBoundary
        Assert-True (
            [string]$boundary.apply -ceq 'apply-locked-preflight' -and
            [string]$boundary.purge -ceq 'purge-locked-preflight' -and
            [string]$boundary.streamDrift -ceq 'fail-closed' -and
            [string]$boundary.leafDrift -ceq 'fail-closed' -and
            [string]$boundary.requiresTreeManifestReverification -ceq 'always'
        ) 'leafStreamSetV1 consumptionBoundary 必须精确一致'
    }
    $leavesA = @($csharp.leafStreamSetV1.leaves)
    $leavesB = @($powershell.leafStreamSetV1.leaves)
    Assert-True ($leavesA.Count -eq $leavesB.Count -and $leavesA.Count -eq $entriesA.Count) 'leaves 条数必须一致且等于 manifest 条目数'
    for ($index = 0; $index -lt $leavesA.Count; $index++) {
        $left = $leavesA[$index]
        $right = $leavesB[$index]
        if ([string]$left.relativePath -cne [string]$right.relativePath) {
            throw "等价性失败：leaves[$index] 顺序或路径不一致（$($left.relativePath) vs $($right.relativePath)）"
        }
        if ([string]$left.kind -cne [string]$right.kind) { throw "等价性失败：leaf $($left.relativePath) kind 不一致" }
        if ((@($left.streamNames) -join '|') -cne (@($right.streamNames) -join '|')) {
            throw "等价性失败：leaf $($left.relativePath) streamNames 不一致"
        }
        if ([long]$left.hardLinkCount -ne [long]$right.hardLinkCount) {
            throw "等价性失败：leaf $($left.relativePath) hardLinkCount 不一致"
        }
        Assert-True ($left.hardLinkCount -is [long]) 'hardLinkCount 必须是 JSON integer'
        Assert-True ($null -ne $left.streamNames) 'streamNames 必须是数组而非 null'
    }

    if ([long]$csharp.summary.fileCount -ne [long]$powershell.summary.fileCount -or
        [long]$csharp.summary.directoryCount -ne [long]$powershell.summary.directoryCount) {
        throw '等价性失败：summary 计数不一致'
    }
    if ((@($csharp.summary.topLevelEntries) -join '|') -cne
        (@($powershell.summary.topLevelEntries) -join '|')) {
        throw '等价性失败：summary.topLevelEntries 不一致'
    }
    return $csharp
}

$runtimeEdition = [string]$PSVersionTable.PSEdition
$runtimeVersion = [string]$PSVersionTable.PSVersion
$runtimeMajor = [int]$PSVersionTable.PSVersion.Major
$runtimeMinor = [int]$PSVersionTable.PSVersion.Minor
Assert-True ($runtimeEdition -ceq 'Core') "本测试要求 PowerShell Core，实际为 $runtimeEdition"
Assert-True (
    $runtimeMajor -gt 7 -or
    ($runtimeMajor -eq 7 -and $runtimeMinor -ge 6)
) "本测试要求 PowerShell 7.6+，实际为 $runtimeVersion"

$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($projectRoot))
Assert-True (
    $drive.DriveFormat -ceq 'NTFS'
) "本测试要求 NTFS（junction/ADS 用例依赖），实际为 $($drive.DriveFormat)"

. $hostSafetyLibraryPath
. $libraryPath
Assert-True (
    $null -ne (Get-Command -Name Get-CodexSafeTreeDeletePlanTreeSnapshot -ErrorAction SilentlyContinue)
) 'RED: Get-CodexSafeTreeDeletePlanTreeSnapshot 尚不存在'
Assert-True (
    $null -ne (Get-Command -Name New-CodexSafeTreeDeletePlanFileIdentitiesV2FromCaptures -ErrorAction SilentlyContinue)
) 'RED: New-CodexSafeTreeDeletePlanFileIdentitiesV2FromCaptures 尚不存在'
Assert-True (
    $null -ne ('CodexSafeTreeDelete.PlanTreeSnapshotBuilder' -as [type])
) 'RED: CodexSafeTreeDelete.PlanTreeSnapshotBuilder 尚未加载'

Write-Output (
    'ENV ps={0} culture={1} uiculture={2}' -f @(
        $runtimeVersion,
        [Globalization.CultureInfo]::CurrentCulture.Name,
        [Globalization.CultureInfo]::CurrentUICulture.Name))

# 密封化：清除套件级传入的 CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER（例如双模式
# 回归轮的 env=0），使"默认必须走 csharp walker"断言不被环境预设击穿；结束时恢复原值。
$ambientPlanWalkerEnv = [string]$env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER
if ($null -ne $env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER) {
    Remove-Item Env:\CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER -ErrorAction Stop
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'plan-walker-equivalence'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    [IO.File]::WriteAllText(
        $policyPath,
        ($policy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $linkAwarePolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'plan-walker-equivalence-link-aware'
                capabilityRoot = '<filled-per-tree>'
                minimumDescendantDepth = 0
                rootDeletionPurpose = 'rebuildable-build-output'
                allowHardLinks = $true
                allowInternalDirectoryJunctions = $true
                deniedExactPaths = @()
            }
        )
    }
    $emptyProjectPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'plan-walker-equivalence-empty-project'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'empty-project-state'
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    [IO.File]::WriteAllText(
        $emptyProjectPolicyPath,
        ($emptyProjectPolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))

    # ---- Slice A：多形态基础树（嵌套/非 ASCII/大小写平局/U+212A 平局/目录 ADS）双模式等价 ----
    $basicTarget = Join-Path $fixtureRoot 'candidate-basic'
    [void][IO.Directory]::CreateDirectory((Join-Path $basicTarget 'nested'))
    [void][IO.Directory]::CreateDirectory((Join-Path $basicTarget '中文目录'))
    [IO.File]::WriteAllText((Join-Path $basicTarget 'a.txt'), 'alpha', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $basicTarget 'A.txt'), 'alpha-upper', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $basicTarget ('{0}.txt' -f [char]0x212A)),
        'kelvin',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $basicTarget 'k.txt'), 'ascii-k', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $basicTarget 'nested\b.bin'), 'bravo', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $basicTarget '中文目录\文件.txt'), 'charlie', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $basicTarget 'nested:dir-ads'), 'dir-ads', [Text.UTF8Encoding]::new($false))

    $csharpBasic = Invoke-EquivalencePlan -Path $basicTarget -CapabilityRoot $fixtureRoot -Policy $policyPath
    Assert-True ($csharpBasic.planned -eq $true) 'C# walker Plan 必须成功'
    Assert-True ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -ceq 'csharp') '默认必须走 csharp walker'
    $powerShellBasic = Invoke-EquivalencePlan -Path $basicTarget -CapabilityRoot $fixtureRoot -Policy $policyPath -UsePowerShellWalker
    Assert-True ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -ceq 'powershell') '回退开关必须走 powershell 三遍'

    $env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER = '0'
    $envFallback = Invoke-EquivalencePlan -Path $basicTarget -CapabilityRoot $fixtureRoot -Policy $policyPath
    Remove-Item Env:\CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER -ErrorAction Stop
    Assert-True ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -ceq 'powershell') "env=0 必须强制回退，实际 $($script:CodexSafeTreeDeleteLastPlanSegments.walker)"
    $envEnabled = Invoke-EquivalencePlan -Path $basicTarget -CapabilityRoot $fixtureRoot -Policy $policyPath
    Assert-True ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -ceq 'csharp') 'env 清除后必须恢复 csharp walker'

    $basicDocument = Compare-PlanDocuments `
        -CSharpPlanPath $csharpBasic.planPath `
        -PowerShellPlanPath $powerShellBasic.planPath
    $basicKelvin = @($basicDocument.treeManifest.entries |
        Where-Object relativePath -ceq ([string]::Format('{0}.txt', [char]0x212A)))
    Assert-True ($basicKelvin.Count -eq 1) 'U+212A 平局名必须被两模式同位记录'
    $basicDirAds = @($basicDocument.leafStreamSetV1.leaves |
        Where-Object relativePath -ceq 'nested')
    Assert-True ($basicDirAds.Count -eq 1) '目录 leaf 必须存在'
    Assert-True (@($basicDirAds[0].streamNames).Count -eq 1) '带 ADS 的目录必须记录命名流（记录放行语义）'
    Assert-True ([string]$basicDirAds[0].streamNames[0] -ceq ':dir-ads:$DATA') '目录 ADS 流名必须逐字记录'
    Assert-True (
        [long]$csharpBasic.metrics.entriesScanned -eq [long]$powerShellBasic.metrics.entriesScanned -and
        [long]$csharpBasic.metrics.logicalBytes -eq [long]$powerShellBasic.metrics.logicalBytes -and
        [long]$csharpBasic.metrics.bytesHashed -eq [long]$powerShellBasic.metrics.bytesHashed
    ) '两模式 metrics（entriesScanned/logicalBytes/bytesHashed）必须等值'
    Assert-True (
        [long]$csharpBasic.metrics.entriesScanned -eq
        ([long]$basicDocument.summary.fileCount + [long]$basicDocument.summary.directoryCount)
    ) 'entriesScanned 必须等于 file+directory 计数'

    # ---- Slice B：空树目标（仅 '.' 条目）双模式等价 ----
    $emptyTarget = Join-Path $fixtureRoot 'candidate-empty'
    [void][IO.Directory]::CreateDirectory($emptyTarget)
    $csharpEmpty = Invoke-EquivalencePlan -Path $emptyTarget -CapabilityRoot $fixtureRoot -Policy $policyPath
    $powerShellEmpty = Invoke-EquivalencePlan -Path $emptyTarget -CapabilityRoot $fixtureRoot -Policy $policyPath -UsePowerShellWalker
    $emptyDocument = Compare-PlanDocuments `
        -CSharpPlanPath $csharpEmpty.planPath `
        -PowerShellPlanPath $powerShellEmpty.planPath
    Assert-True (@($emptyDocument.treeManifest.entries).Count -eq 1) '空树必须只有根条目'
    Assert-True ([string]$emptyDocument.treeManifest.entries[0].relativePath -ceq '.') '空树唯一条目必须是根'
    Assert-True (@($emptyDocument.summary.topLevelEntries).Count -eq 0) 'topLevelEntries 空态必须是空数组'

    # ---- Slice C：junction + hardlink（policy v4）双模式等价 ----
    $linkTarget = Join-Path $fixtureRoot 'candidate-link-aware'
    $linkInternal = Join-Path $linkTarget 'store\package'
    $linkJunction = Join-Path $linkTarget 'linked-package'
    $linkExternalFile = Join-Path $fixtureRoot 'link-external-source.bin'
    $linkHardLink = Join-Path $linkTarget 'shared-cache.bin'
    [void][IO.Directory]::CreateDirectory($linkInternal)
    [IO.File]::WriteAllText((Join-Path $linkInternal 'package.json'), '{"name":"equivalence"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($linkExternalFile, 'hardlink-payload', [Text.UTF8Encoding]::new($false))
    [void](New-Item -ItemType Junction -Path $linkJunction -Target $linkInternal)
    [void](New-Item -ItemType HardLink -Path $linkHardLink -Target $linkExternalFile)
    $linkAwarePolicy.entries[0].capabilityRoot = $linkTarget
    [IO.File]::WriteAllText(
        $linkAwarePolicyPath,
        ($linkAwarePolicy | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $csharpLink = Invoke-EquivalencePlan -Path $linkTarget -CapabilityRoot $linkTarget -Policy $linkAwarePolicyPath
    $powerShellLink = Invoke-EquivalencePlan -Path $linkTarget -CapabilityRoot $linkTarget -Policy $linkAwarePolicyPath -UsePowerShellWalker
    $linkDocument = Compare-PlanDocuments `
        -CSharpPlanPath $csharpLink.planPath `
        -PowerShellPlanPath $powerShellLink.planPath
    $junctionLeaves = @($linkDocument.leafStreamSetV1.leaves | Where-Object kind -ceq 'directory-junction')
    Assert-True ($junctionLeaves.Count -eq 1) 'junction leaf 必须恰好一个'
    Assert-True ([string]$junctionLeaves[0].relativePath -ceq 'linked-package') 'junction leaf 相对路径必须正确'
    Assert-True (@($junctionLeaves[0].streamNames).Count -eq 0) 'junction leaf 不得携带命名流'
    $hardLinkLeaf = @($linkDocument.leafStreamSetV1.leaves | Where-Object relativePath -ceq 'shared-cache.bin')
    Assert-True ($hardLinkLeaf.Count -eq 1) 'hardlink leaf 必须存在'
    Assert-True ([long]$hardLinkLeaf[0].hardLinkCount -eq 2L) 'hardlink 计数必须记录完整 alias 数 2'
    $junctionManifest = @($linkDocument.treeManifest.entries | Where-Object kind -ceq 'directory-junction')
    Assert-True ($junctionManifest.Count -eq 1 -and
        [string]$junctionManifest[0].sha256 -cmatch '^[0-9a-f]{64}$') 'junction manifest 必须记录 reparse data sha256'

    # ---- Slice D：负路径失败闭锁对齐（两模式同消息）----
    $adsTarget = Join-Path $fixtureRoot 'candidate-file-ads'
    [void][IO.Directory]::CreateDirectory($adsTarget)
    [IO.File]::WriteAllText((Join-Path $adsTarget 'plain.txt'), 'plain', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $adsTarget 'plain.txt:zone'), 'ads', [Text.UTF8Encoding]::new($false))
    $adsErrorCSharp = Assert-Throws -Message 'C# 模式 file ADS 必须失败闭锁' -Action {
        Invoke-EquivalencePlan -Path $adsTarget -CapabilityRoot $fixtureRoot -Policy $policyPath
    }
    $adsErrorPowerShell = Assert-Throws -Message 'PS 模式 file ADS 必须失败闭锁' -Action {
        Invoke-EquivalencePlan -Path $adsTarget -CapabilityRoot $fixtureRoot -Policy $policyPath -UsePowerShellWalker
    }
    Assert-True ($adsErrorCSharp -match 'alternate data stream') 'C# 模式 file ADS 闭锁必须发生在 lease ADS 断言层'
    Assert-True ($adsErrorPowerShell -match 'alternate data stream') 'PS 模式 file ADS 闭锁必须发生在 lease ADS 断言层'

    $reparseTarget = Join-Path $fixtureRoot 'candidate-unauthorized-junction'
    [void][IO.Directory]::CreateDirectory($reparseTarget)
    $reparseInner = Join-Path $fixtureRoot 'reparse-inner'
    [void][IO.Directory]::CreateDirectory($reparseInner)
    [void](New-Item -ItemType Junction -Path (Join-Path $reparseTarget 'unauthorized-link') -Target $reparseInner)
    $reparseErrorCSharp = Assert-Throws -Message 'C# 模式未授权 reparse 必须失败闭锁' -Action {
        Invoke-EquivalencePlan -Path $reparseTarget -CapabilityRoot $fixtureRoot -Policy $policyPath
    }
    $reparseErrorPowerShell = Assert-Throws -Message 'PS 模式未授权 reparse 必须失败闭锁' -Action {
        Invoke-EquivalencePlan -Path $reparseTarget -CapabilityRoot $fixtureRoot -Policy $policyPath -UsePowerShellWalker
    }
    Assert-True ($reparseErrorCSharp -match '未授权 reparse point') 'C# 模式未授权 reparse 拒绝消息必须对齐'
    Assert-True ($reparseErrorCSharp -ceq $reparseErrorPowerShell) '两模式未授权 reparse 拒绝消息必须逐字一致'

    $emptyProjectTarget = Join-Path $fixtureRoot 'candidate-empty-project'
    [void][IO.Directory]::CreateDirectory($emptyProjectTarget)
    [IO.File]::WriteAllText((Join-Path $emptyProjectTarget 'must-not-exist.txt'), 'x', [Text.UTF8Encoding]::new($false))
    # empty-project-state 的用途校验在 policy/目标解析层（walker 之前的共享前置层）：
    # 非 D:\(Codex|agents)\projects\<proj>\.codex 根直接拒绝。两模式在此层逐字一致。
    $emptyProjectErrorCSharp = Assert-Throws -Message 'C# 模式 empty-project-state 前置层必须失败闭锁' -Action {
        Invoke-EquivalencePlan -Path $emptyProjectTarget -CapabilityRoot $fixtureRoot -Policy $emptyProjectPolicyPath
    }
    $emptyProjectErrorPowerShell = Assert-Throws -Message 'PS 模式 empty-project-state 前置层必须失败闭锁' -Action {
        Invoke-EquivalencePlan -Path $emptyProjectTarget -CapabilityRoot $fixtureRoot -Policy $emptyProjectPolicyPath -UsePowerShellWalker
    }
    Assert-True ($emptyProjectErrorCSharp -match 'purpose') 'empty-project-state 非法用途必须在 policy 前置层拒绝'
    Assert-True ($emptyProjectErrorCSharp -ceq $emptyProjectErrorPowerShell) '两模式 empty-project-state 前置层拒绝消息必须逐字一致'

    # ---- Slice E：guard seam 差分 + checkpoint 语义（plan §5/§4.1）----
    $differentialTarget = Join-Path $fixtureRoot 'candidate-differential'
    [void][IO.Directory]::CreateDirectory((Join-Path $differentialTarget 'plain-dir'))
    $adsDir = Join-Path $differentialTarget 'ads-dir'
    [void][IO.Directory]::CreateDirectory($adsDir)
    [IO.File]::WriteAllText("$adsDir`:z-stream", 'z', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText("$adsDir`:a-stream", 'a', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $differentialTarget 'payload.txt'), 'diff', [Text.UTF8Encoding]::new($false))
    $csharpDiff = Invoke-EquivalencePlan -Path $differentialTarget -CapabilityRoot $fixtureRoot -Policy $policyPath
    $powerShellDiff = Invoke-EquivalencePlan -Path $differentialTarget -CapabilityRoot $fixtureRoot -Policy $policyPath -UsePowerShellWalker
    $diffDocument = Compare-PlanDocuments `
        -CSharpPlanPath $csharpDiff.planPath `
        -PowerShellPlanPath $powerShellDiff.planPath
    # 差分：plan（guard 同句柄 seam）的目录流集与 LeafStreamSetReader per-path 捕获同值。
    foreach ($leaf in @($diffDocument.leafStreamSetV1.leaves | Where-Object kind -ceq 'directory')) {
        $leafPath = if ([string]$leaf.relativePath -ceq '.') { $differentialTarget } else { ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath -TreePath $differentialTarget -RelativePath ([string]$leaf.relativePath) -Scope 'differential' }
        $direct = Get-CodexSafeTreeDeleteLeafStreamSet -LiteralPath $leafPath
        if ((@($leaf.streamNames) -join '|') -cne (@($direct.StreamNames) -join '|')) {
            throw "差分失败：directory $($leaf.relativePath) 的流集与 per-path 捕获不一致"
        }
        if ([long]$leaf.hardLinkCount -ne [long]$direct.NumberOfLinks) {
            throw "差分失败：directory $($leaf.relativePath) 的 link 计数与 per-path 捕获不一致"
        }
    }
    $adsDirLeaf = @($diffDocument.leafStreamSetV1.leaves | Where-Object relativePath -ceq 'ads-dir')
    Assert-True ($adsDirLeaf.Count -eq 1) '带 ADS 目录 leaf 必须存在'
    Assert-True ((@($adsDirLeaf[0].streamNames) -join '|') -ceq ':a-stream:$DATA|:z-stream:$DATA') `
        '目录 ADS 流名必须 ordinal 排序且两套 parser 同值'

    # checkpoint 1：file→directory kind 漂移在 open 时拒绝，且 plan.json 零发布。
    $driftTarget = Join-Path $fixtureRoot 'candidate-kind-drift'
    [void][IO.Directory]::CreateDirectory($driftTarget)
    $driftFile = Join-Path $driftTarget 'swap.txt'
    [IO.File]::WriteAllText($driftFile, 'before', [Text.UTF8Encoding]::new($false))
    $driftError = Assert-Throws -Message 'kind 漂移必须在 open 时拒绝' -Action {
        $checkpoint = {
            param([string]$checkpointKind, [object]$event)
            if ($checkpointKind -ceq 'after-entry-observed-before-open' -and
                [string]$event.RelativePath -ceq 'swap.txt') {
                [void][IO.Directory]::Delete($driftFile, $false)
                [void][IO.Directory]::CreateDirectory($driftFile)
            }
        }
        New-CodexSafeTreeDeletePlan `
            -TargetPath $driftTarget -CapabilityRoot $fixtureRoot -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot -PlanWalkerCheckpointForTest $checkpoint | Out-Null
    }
    Assert-True ($driftError.Length -gt 0) 'kind 漂移拒绝必须产生错误'
    if ([IO.Directory]::Exists($driftFile)) { [void][IO.Directory]::Delete($driftFile, $false) }

    # checkpoint 2：lease 阻断普通写/rename/ADS/hardlink；全部被拒后 plan 正常完成。
    $leaseTarget = Join-Path $fixtureRoot 'candidate-lease-guard'
    [void][IO.Directory]::CreateDirectory($leaseTarget)
    $leaseFile = Join-Path $leaseTarget 'protected.txt'
    [IO.File]::WriteAllText($leaseFile, 'protected', [Text.UTF8Encoding]::new($false))
    $mutationResults = [ordered]@{
        write = $null; rename = $null; ads = $null; hardlink = $null
    }
    $leaseHardLinkPath = Join-Path $leaseTarget 'alias.txt'
    $leaseCheckpoint = {
        param([string]$checkpointKind, [object]$event)
        if ($checkpointKind -ceq 'after-file-baseline-captured-before-hash' -and
            [string]$event.RelativePath -ceq 'protected.txt') {
            foreach ($attempt in @(
                @{ name = 'write'; action = { [void][IO.File]::Open($leaseFile, 'Open', 'Write').Dispose() } },
                @{ name = 'rename'; action = { [IO.File]::Move($leaseFile, "$leaseFile-renamed") } },
                @{ name = 'ads'; action = { [IO.File]::WriteAllText("$leaseFile`:extra", 'x', [Text.UTF8Encoding]::new($false)) } },
                @{ name = 'hardlink'; action = { [void](New-Item -ItemType HardLink -Path $leaseHardLinkPath -Target $leaseFile) } }
            )) {
                try {
                    & $attempt.action
                    $mutationResults[$attempt.name] = 'succeeded'
                } catch {
                    $mutationResults[$attempt.name] = 'denied'
                }
            }
        }
    }
    $leasePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $leaseTarget -CapabilityRoot $fixtureRoot -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot -PlanWalkerCheckpointForTest $leaseCheckpoint
    foreach ($name in @('write', 'rename', 'ads')) {
        Assert-True ([string]$mutationResults[$name] -ceq 'denied') "lease 必须阻断 $name（实际：$($mutationResults[$name])）"
    }
    if ([string]$mutationResults.hardlink -ceq 'succeeded') {
        throw 'hardlink 在 lease 下成功：本用例要求它与其它变更同样被拒（若 OS 允许则属计划外路径，需回到方案审查）'
    }
    Assert-True ($leasePlan.planned -eq $true) '全部变更被拒后 plan 必须正常完成'

    # checkpoint 异常不吞：checkpoint throw 必须使 plan 失败。
    $swallowTarget = Join-Path $fixtureRoot 'candidate-checkpoint-throw'
    [void][IO.Directory]::CreateDirectory($swallowTarget)
    [IO.File]::WriteAllText((Join-Path $swallowTarget 'x.txt'), 'x', [Text.UTF8Encoding]::new($false))
    $swallowError = Assert-Throws -Message 'checkpoint 异常不得被吞' -Action {
        $checkpoint = { param([string]$checkpointKind, [object]$event) throw 'checkpoint-injected-failure' }
        New-CodexSafeTreeDeletePlan `
            -TargetPath $swallowTarget -CapabilityRoot $fixtureRoot -PolicyPath $policyPath `
            -EvidenceRoot $evidenceRoot -PlanWalkerCheckpointForTest $checkpoint | Out-Null
    }
    Assert-True ($swallowError -match 'checkpoint-injected-failure') 'checkpoint 异常必须原样冒泡'

    # 替换正例：open 前同 kind 替换在 lease 线性化点之前，以新对象形成自洽 plan。
    $replaceTarget = Join-Path $fixtureRoot 'candidate-replace'
    [void][IO.Directory]::CreateDirectory($replaceTarget)
    $replaceFile = Join-Path $replaceTarget 'swap-same-kind.txt'
    [IO.File]::WriteAllText($replaceFile, 'old-content', [Text.UTF8Encoding]::new($false))
    $replaceCheckpoint = {
        param([string]$checkpointKind, [object]$event)
        if ($checkpointKind -ceq 'after-entry-observed-before-open' -and
            [string]$event.RelativePath -ceq 'swap-same-kind.txt') {
            [void][IO.File]::Delete($replaceFile)
            [IO.File]::WriteAllText($replaceFile, 'new-content', [Text.UTF8Encoding]::new($false))
        }
    }
    $replacePlan = New-CodexSafeTreeDeletePlan `
        -TargetPath $replaceTarget -CapabilityRoot $fixtureRoot -PolicyPath $policyPath `
        -EvidenceRoot $evidenceRoot -PlanWalkerCheckpointForTest $replaceCheckpoint
    Assert-True ($replacePlan.planned -eq $true) '同 kind 替换后必须以新对象成功 plan'
    $replaceDoc = Read-PlanDocument -PlanPath ([string]$replacePlan.planPath)
    $newSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes('new-content'))).ToLowerInvariant()
    $replaceEntry = @($replaceDoc.treeManifest.entries | Where-Object relativePath -ceq 'swap-same-kind.txt')
    Assert-True ($replaceEntry.Count -eq 1 -and [string]$replaceEntry[0].sha256 -ceq $newSha) `
        '替换正例必须记录新对象内容哈希'

    Write-Output 'EQUIVALENCE OK'
} finally {
    if ($null -ne $ambientPlanWalkerEnv) {
        $env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER = $ambientPlanWalkerEnv
    } elseif (Test-Path Env:\CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER) {
        Remove-Item Env:\CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER -ErrorAction SilentlyContinue
    }
    # file ADS 会让受管清理的 lease 断言闭锁，先删除流再走受管树清理（LeafStreamSet 测试同款先例）。
    $adsStreamPath = Join-Path $fixtureRoot 'candidate-file-ads\plain.txt:zone'
    if ([IO.File]::Exists($adsStreamPath)) { [void][IO.File]::Delete($adsStreamPath) }
    $unauthorizedJunctionPath = Join-Path $fixtureRoot 'candidate-unauthorized-junction\unauthorized-link'
    if ([IO.Directory]::Exists($unauthorizedJunctionPath)) {
        [void][IO.Directory]::Delete($unauthorizedJunctionPath, $false)
    }
    foreach ($cleanup in @(
        @{ Path = (Join-Path $fixtureRoot 'candidate-basic') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-empty') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-file-ads') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-unauthorized-junction') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-empty-project') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-differential') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-kind-drift') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-lease-guard') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-checkpoint-throw') },
        @{ Path = (Join-Path $fixtureRoot 'candidate-replace') },
        @{ Path = (Join-Path $fixtureRoot 'reparse-inner') },
        @{ Path = $fixtureRoot; LinkAware = $true }
    )) {
        $cleanupArguments = @{ Path = [string]$cleanup.Path }
        if ($cleanup.ContainsKey('LinkAware')) { $cleanupArguments.LinkAware = $true }
        try {
            Remove-TestTree @cleanupArguments
        } catch {
            Write-Output ("CLEANUP-FAILED path={0} error={1}" -f $cleanupArguments.Path, $_.Exception.Message)
        }
    }
}
Write-Output 'PLAN-WALKER-EQUIVALENCE DONE'
