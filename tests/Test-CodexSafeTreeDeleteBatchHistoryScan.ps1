[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #76 / #78，spec #73「BatchPurge 单次历史扫描」):
# 1. 唯一接缝：fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 BatchPurge mode；
#    只观察结果字段（含新增 historyScan）与 evidence / 目标命名空间的前后状态。
# 2. kill switch：CODEX_SAFE_TREE_DELETE_BATCH_HISTORY_SCAN 只有字符串 '0' 退回逐目标参考查找。
# 3. C# 预筛（#78）：只裁决 run 目录第一层、producer 规范形态的 transaction；能证明与本批
#    任何目标都不匹配的才排除，其余（含非规范、读取或解析异常）一律走参考认证链。
#    快慢等价逐字段比较（historyScan 除外），预筛的裁决只体现在 historyScan 计数上。
# 性能数字只记录不设阈值；本套件不读写生产 evidence 根。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$evidenceHome = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'batchhistoryscan'
$killSwitchName = 'CODEX_SAFE_TREE_DELETE_BATCH_HISTORY_SCAN'
$originalKillSwitch = [Environment]::GetEnvironmentVariable($killSwitchName)
$existingResultFields = @(
    'completed', 'targetCount', 'purgedCount', 'recoveredCount',
    'alreadyAbsentCount', 'skippedCount', 'failedCount', 'results')
$historyScanFields = @(
    'mode', 'scanCount', 'enumeratedFiles', 'canonicalFiles', 'fallbackFiles',
    'excludedByPrefilter', 'fullyAuthenticated', 'elapsedMs')

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
        -Name 'safe-delete batch history scan test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete batch history scan test cleanup'
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-HistoryFixture {
    param([Parameter(Mandatory)][string]$Name)

    $root = Join-Path $evidenceHome $Name
    $evidenceRoot = Join-Path $root 'evidence'
    $targetsRoot = Join-Path $root 'targets'
    $policyPath = Join-Path $root 'policy.json'
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [void][IO.Directory]::CreateDirectory($targetsRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = "batch-history-$Name"
                capabilityRoot = $root
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    Write-Utf8File -Path $policyPath -Text ($policy | ConvertTo-Json -Depth 10)
    return [pscustomobject][ordered]@{
        name = $Name
        root = $root
        evidenceRoot = $evidenceRoot
        targetsRoot = $targetsRoot
        policyPath = $policyPath
        # 物理名 → 逻辑名（run 目录名、generationId），用于跨 fixture 比较结果与落盘状态。
        tokens = [Collections.Generic.List[object]]::new()
    }
}

function New-PresentTarget {
    param([Parameter(Mandatory)][string]$Path)

    [void][IO.Directory]::CreateDirectory($Path)
    Write-Utf8File -Path (Join-Path $Path 'payload.txt') -Text 'batch-history-payload'
}

function New-QuarantinedTarget {
    param(
        [Parameter(Mandatory)][object]$Fixture,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Label
    )

    # 经 fixture 入口 Plan → Apply，留下 quarantined transaction 与隔离目录。
    New-PresentTarget -Path $TargetPath
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $TargetPath `
        -CapabilityRoot $Fixture.root `
        -FixturePolicyPath $Fixture.policyPath `
        -FixtureEvidenceRoot $Fixture.evidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $Fixture.policyPath `
        -FixtureEvidenceRoot $Fixture.evidenceRoot
    Assert-True ($apply.quarantined -eq $true) "$Label 夹具 Apply 必须成功"
    $transaction = [IO.File]::ReadAllText([string]$apply.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    $Fixture.tokens.Add([pscustomobject]@{
        from = Split-Path -Leaf (Split-Path -Parent ([string]$apply.transactionPath))
        to = "<run:$Label>"
    })
    $Fixture.tokens.Add([pscustomobject]@{ from = [string]$transaction.generationId; to = "<gen:$Label>" })
    return $apply
}

function ConvertTo-LogicalText {
    param([Parameter(Mandatory)][object]$Fixture, [AllowEmptyString()][string]$Text)

    $value = $Text.Replace([string]$Fixture.root, '<ROOT>')
    foreach ($token in $Fixture.tokens) {
        $value = $value.Replace([string]$token.from, [string]$token.to)
    }
    return $value
}

function ConvertTo-ComparableBatchResult {
    param([Parameter(Mandatory)][object]$Result, [Parameter(Mandatory)][object]$Fixture)

    # 除 historyScan 外逐字段比较；planned-applied-purged 的 transactionPath 是本次新建的
    # run（时间戳 + 随机 generationId），只能比较其存在与终态（见落盘状态快照）。
    $rows = foreach ($row in @($Result.results)) {
        $fields = [ordered]@{}
        foreach ($property in $row.PSObject.Properties) {
            $value = $property.Value
            if ($property.Name -ceq 'transactionPath' -and
                [string]$row.action -ceq 'planned-applied-purged') {
                $value = '<new-run>'
            } elseif ($value -is [string]) {
                $value = ConvertTo-LogicalText -Fixture $Fixture -Text $value
            }
            $fields[$property.Name] = $value
        }
        [pscustomobject]$fields
    }
    $top = [ordered]@{}
    foreach ($property in $Result.PSObject.Properties) {
        if ($property.Name -ceq 'historyScan') { continue }
        $top[$property.Name] = if ($property.Name -ceq 'results') { @($rows) } else { $property.Value }
    }
    return ([pscustomobject]$top | ConvertTo-Json -Depth 8 -Compress)
}

function Get-ComparableFixtureState {
    param([Parameter(Mandatory)][object]$Fixture)

    # evidence 中每个 transaction.json 的位置 / status / targetPath，加上目标命名空间的条目；
    # 本次 BatchPurge 新建的 run 以「<new-run:目标名>」表示。
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($file in [IO.Directory]::EnumerateFiles(
            $Fixture.evidenceRoot, 'transaction.json', [IO.SearchOption]::AllDirectories)) {
        $status = '<unparsed>'
        $targetPath = '<unparsed>'
        try {
            $document = [IO.File]::ReadAllText($file) | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
            $status = [string]$document.status
            $targetPath = [string]$document.targetPath
        } catch {
            $status = '<unparsed>'
        }
        $relative = ConvertTo-LogicalText `
            -Fixture $Fixture `
            -Text $file.Substring($Fixture.evidenceRoot.Length + 1)
        if ($relative -match '^\d{8}T\d{6}Z-[0-9a-fA-F-]+\\transaction\.json$') {
            $relative = "<new-run:$(Split-Path -Leaf $targetPath)>\transaction.json"
        }
        $rows.Add("evidence:$relative|$status|$(ConvertTo-LogicalText -Fixture $Fixture -Text $targetPath)")
    }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Fixture.targetsRoot)) {
        $rows.Add("targets:$(ConvertTo-LogicalText -Fixture $Fixture -Text (Split-Path -Leaf $entry))")
    }
    $sorted = $rows.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return ($sorted -join "`n")
}

function New-EquivalenceFixture {
    param([Parameter(Mandatory)][string]$Name)

    # 覆盖：规范 / 非规范位置、schema 1、多个匹配、大小写不同的 targetPath、Unicode 上
    # 等价但字节不同的路径、终态记录、存在 / 从未存在的目标。
    $fixture = New-HistoryFixture -Name $Name
    $targets = $fixture.targetsRoot
    $nfcName = 'caf' + [string][char]0x00E9
    $nfdName = 'cafe' + [string][char]0x0301
    [void](New-QuarantinedTarget -Fixture $fixture -TargetPath (Join-Path $targets 'Recover-Case') -Label 'recover-case')
    [void](New-QuarantinedTarget -Fixture $fixture -TargetPath (Join-Path $targets $nfcName) -Label 'cafe-nfc')
    $schemaOne = New-QuarantinedTarget -Fixture $fixture -TargetPath (Join-Path $targets 'schema-one') -Label 'schema-one'
    $current = [IO.File]::ReadAllText([string]$schemaOne.transactionPath) |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Write-Utf8File -Path ([string]$schemaOne.transactionPath) -Text ([pscustomobject][ordered]@{
        artifactType = [string]$current.artifactType
        schemaVersion = 1L
        generationId = [string]$current.generationId
        planPath = [string]$current.planPath
        planSha256 = [string]$current.planSha256
        targetPath = [string]$current.targetPath
        quarantinePath = [string]$current.quarantinePath
        status = [string]$current.status
        updatedAtUtc = [string]$current.updatedAtUtc
    } | ConvertTo-Json -Depth 16)
    $multi = New-QuarantinedTarget -Fixture $fixture -TargetPath (Join-Path $targets 'multi') -Label 'multi'
    $copyPath = Join-Path $fixture.evidenceRoot 'nested\copy\transaction.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $copyPath))
    [IO.File]::Copy([string]$multi.transactionPath, $copyPath)
    New-PresentTarget -Path (Join-Path $targets 'present-a')
    New-PresentTarget -Path (Join-Path $targets 'present-b')
    New-TerminalHistoryRecord `
        -Fixture $fixture `
        -RelativePath 'legacy\deep\transaction.json' `
        -TargetPath (Join-Path $targets 'present-a')
    $fixture | Add-Member -NotePropertyName batchTargets -NotePropertyValue @(
        (Join-Path $targets 'recover-case'),
        (Join-Path $targets $nfdName),
        (Join-Path $targets 'schema-one'),
        (Join-Path $targets 'multi'),
        (Join-Path $targets 'present-a'),
        (Join-Path $targets 'never-created'),
        (Join-Path $targets 'present-b'))
    return $fixture
}

function New-NestedFixture {
    param([Parameter(Mandatory)][string]$Name)

    # 祖先 anc 与后代 anc\desc 同批；anc\old 是早先 Apply 过的目标，其隔离目录位于 anc 内，
    # anc 被清除后它的 quarantined 记录不再可恢复。
    $fixture = New-HistoryFixture -Name $Name
    $ancestor = Join-Path $fixture.targetsRoot 'anc'
    $descendant = Join-Path $ancestor 'desc'
    $quarantinedDescendant = Join-Path $ancestor 'old'
    New-PresentTarget -Path $ancestor
    New-PresentTarget -Path $descendant
    [void](New-QuarantinedTarget -Fixture $fixture -TargetPath $quarantinedDescendant -Label 'anc-old')
    $fixture | Add-Member -NotePropertyName batchTargets -NotePropertyValue @(
        $ancestor,
        $descendant,
        $quarantinedDescendant)
    return $fixture
}

function New-ProducerTransactionProperties {
    param(
        [Parameter(Mandatory)][object]$Fixture,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$SchemaVersion,
        [Parameter(Mandatory)][object]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TargetPath
    )

    # producer 规范形态（schemaVersion 1 / 2 / 3 各自的属性名集合）的 transaction 属性。
    # 预筛与参考链在扫描阶段都只看 status 与 targetPath，其余值是占位，不是真实删除证据；
    # quarantinePath 永不存在，所以 live 记录只有 status 为 purging 时才继续裁决 schema。
    $properties = [ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-transaction'
        schemaVersion = $SchemaVersion
        generationId = 'history-record'
        planPath = Join-Path $Fixture.root 'history-record-plan.json'
        planSha256 = '0' * 64
        targetPath = $TargetPath
        quarantinePath = Join-Path $Fixture.root 'history-record-quarantine'
    }
    if ($SchemaVersion -ge 2) { $properties['directoryCommitAnchors'] = @() }
    $properties['status'] = $Status
    $properties['updatedAtUtc'] = '2026-01-01T00:00:00.0000000Z'
    if ($SchemaVersion -eq 3) {
        $properties['quarantineTimeAnchor'] = $null
        $properties['restoreJournalAnchors'] = @()
    }
    return $properties
}

function Write-HistoryRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.Specialized.OrderedDictionary]$Properties,
        [string]$RawAnchors,
        [switch]$Bom,
        [switch]$InvalidUtf8
    )

    # RawAnchors 原样作为 directoryCommitAnchors 的值写入，用来构造 ConvertTo-Json 写不出的
    # 严格 JSON（同一对象内只差大小写的属性名、超长整数字面量等）；InvalidUtf8 把
    # generationId 的值换成非法 UTF-8 字节序列。
    $anchorsMarker = 'RAW-ANCHORS-MARKER'
    $invalidMarker = 'INVALID-UTF8-MARKER'
    $document = [ordered]@{}
    foreach ($key in $Properties.Keys) { $document[$key] = $Properties[$key] }
    if ($PSBoundParameters.ContainsKey('RawAnchors')) { $document['directoryCommitAnchors'] = $anchorsMarker }
    if ($InvalidUtf8) { $document['generationId'] = $invalidMarker }
    $text = [pscustomobject]$document | ConvertTo-Json -Depth 8
    if ($PSBoundParameters.ContainsKey('RawAnchors')) {
        Assert-True ($text.Contains("`"$anchorsMarker`"")) 'RawAnchors 占位必须写入 directoryCommitAnchors'
        $text = $text.Replace("`"$anchorsMarker`"", $RawAnchors)
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $bytes = [Collections.Generic.List[byte]]::new()
    if ($Bom) { $bytes.AddRange([byte[]]@(0xEF, 0xBB, 0xBF)) }
    if ($InvalidUtf8) {
        $markerIndex = $text.IndexOf($invalidMarker, [StringComparison]::Ordinal)
        Assert-True ($markerIndex -ge 0) 'InvalidUtf8 占位必须写入 generationId'
        $bytes.AddRange($utf8.GetBytes($text.Substring(0, $markerIndex)))
        $bytes.AddRange([byte[]]@(0xC3, 0x28))
        $bytes.AddRange($utf8.GetBytes($text.Substring($markerIndex + $invalidMarker.Length)))
    } else {
        $bytes.AddRange($utf8.GetBytes($text))
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllBytes($Path, $bytes.ToArray())
}

function New-TerminalHistoryRecord {
    param(
        [Parameter(Mandatory)][object]$Fixture,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    # producer 规范 v2 形态的终态记录。
    Write-HistoryRecord `
        -Path (Join-Path $Fixture.evidenceRoot $RelativePath) `
        -Properties (New-ProducerTransactionProperties `
            -Fixture $Fixture `
            -SchemaVersion 2 `
            -Status 'purged' `
            -TargetPath $TargetPath)
}

function Invoke-BatchPurge {
    param(
        [Parameter(Mandatory)][object]$Fixture,
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [AllowNull()][string]$KillSwitchValue,
        [scriptblock]$AfterScan
    )

    try {
        [Environment]::SetEnvironmentVariable($killSwitchName, $KillSwitchValue)
        return & $entryPath `
            -Mode BatchPurge `
            -TargetPaths $TargetPaths `
            -CapabilityRoot $Fixture.root `
            -ConfirmApply `
            -ConfirmPurge `
            -FixturePolicyPath $Fixture.policyPath `
            -FixtureEvidenceRoot $Fixture.evidenceRoot `
            -FixtureAfterBatchHistoryScan $AfterScan
    } finally {
        [Environment]::SetEnvironmentVariable($killSwitchName, $originalKillSwitch)
    }
}

function Assert-HistoryScanShape {
    param([Parameter(Mandatory)][object]$Result, [Parameter(Mandatory)][string]$Scope)

    $names = @($Result.PSObject.Properties.Name)
    Assert-True (
        ($names -join ',') -ceq (($existingResultFields + @('historyScan')) -join ',')) `
        "$Scope 既有结果字段必须保持原顺序，historyScan 只能追加在末尾：$($names -join ',')"
    $historyScan = $Result.historyScan
    $scanNames = @($historyScan.PSObject.Properties.Name | Where-Object { $_ -cne 'failure' })
    Assert-True (($scanNames -join ',') -ceq ($historyScanFields -join ',')) `
        "$Scope historyScan 字段集合不符：$($scanNames -join ',')"
    foreach ($counter in @($historyScanFields | Where-Object { $_ -cne 'mode' })) {
        Assert-True ($historyScan.$counter -is [long] -or $historyScan.$counter -is [int]) `
            "$Scope historyScan.$counter 必须是整数"
        Assert-True ([long]$historyScan.$counter -ge 0) "$Scope historyScan.$counter 不得为负"
    }
    Assert-True ([long]$historyScan.excludedByPrefilter -le [long]$historyScan.canonicalFiles) `
        "$Scope 只有预筛裁决过的规范文件才能被排除：excludedByPrefilter 不得大于 canonicalFiles"
    Assert-True (
        [long]$historyScan.fullyAuthenticated -le
            [long]$historyScan.enumeratedFiles - [long]$historyScan.excludedByPrefilter) `
        "$Scope 被预筛排除的文件不得再计入 fullyAuthenticated"
    if ([string]$historyScan.mode -ceq 'reference') {
        Assert-True ([long]$historyScan.canonicalFiles -eq 0 -and [long]$historyScan.excludedByPrefilter -eq 0) `
            "$Scope reference 模式不做预筛：canonicalFiles 与 excludedByPrefilter 必须为 0"
    }
    Assert-True (
        [long]$historyScan.canonicalFiles + [long]$historyScan.fallbackFiles -eq
            [long]$historyScan.enumeratedFiles) `
        "$Scope canonicalFiles + fallbackFiles 必须等于 enumeratedFiles"
}

try {
    # --- 切片 1：historyScan 字段、fast 模式 scanCount 恒为 1、kill switch 只认 '0' ---
    $switchFixture = New-HistoryFixture -Name 'switch'
    $switchTargets = @(
        (Join-Path $switchFixture.targetsRoot 'absent-1'),
        (Join-Path $switchFixture.targetsRoot 'absent-2'),
        (Join-Path $switchFixture.targetsRoot 'absent-3'))
    New-TerminalHistoryRecord -Fixture $switchFixture -RelativePath 'run-a\transaction.json' -TargetPath $switchTargets[0]
    New-TerminalHistoryRecord -Fixture $switchFixture -RelativePath 'run-b\transaction.json' -TargetPath $switchTargets[1]
    New-TerminalHistoryRecord -Fixture $switchFixture -RelativePath 'legacy\deep\transaction.json' -TargetPath $switchTargets[2]

    $singleFast = Invoke-BatchPurge -Fixture $switchFixture -TargetPaths @($switchTargets[0]) -KillSwitchValue $null
    Assert-HistoryScanShape -Result $singleFast -Scope '单目标 fast'
    Assert-True ($singleFast.completed -eq $true -and $singleFast.alreadyAbsentCount -eq 1) `
        '单目标 fast 批次必须照常报告 already-absent'
    Assert-True ([string]$singleFast.historyScan.mode -ceq 'fast') 'kill switch 未设置时必须走 fast 模式'
    Assert-True ([long]$singleFast.historyScan.scanCount -eq 1) '单目标 fast 模式 scanCount 必须为 1'
    Assert-True ([long]$singleFast.historyScan.enumeratedFiles -eq 3) 'fast 模式必须枚举全部 3 个历史文件'
    Assert-True ([long]$singleFast.historyScan.canonicalFiles -eq 2) 'run 目录第一层的 2 个规范形态文件由预筛裁决'
    Assert-True ([long]$singleFast.historyScan.excludedByPrefilter -eq 2) '规范形态的终态记录必须被预筛排除'
    Assert-True ([long]$singleFast.historyScan.fallbackFiles -eq 1) '嵌套位置的 1 个文件走回退'
    Assert-True ([long]$singleFast.historyScan.fullyAuthenticated -eq 1) '只有回退的文件需要在扫描阶段完整参考认证'
    Assert-True ($null -eq $singleFast.historyScan.PSObject.Properties['failure']) '成功扫描不得带 failure'

    $multiFast = Invoke-BatchPurge -Fixture $switchFixture -TargetPaths $switchTargets -KillSwitchValue $null
    Assert-HistoryScanShape -Result $multiFast -Scope '三目标 fast'
    Assert-True ($multiFast.targetCount -eq 3 -and $multiFast.alreadyAbsentCount -eq 3) `
        '三目标 fast 批次必须逐目标 already-absent'
    Assert-True ([long]$multiFast.historyScan.scanCount -eq 1) 'fast 模式 scanCount 不得随目标数变化'
    Assert-True ([long]$multiFast.historyScan.enumeratedFiles -eq 3) 'fast 模式整批只枚举一遍历史'

    $multiReference = Invoke-BatchPurge -Fixture $switchFixture -TargetPaths $switchTargets -KillSwitchValue '0'
    Assert-HistoryScanShape -Result $multiReference -Scope '三目标 reference'
    Assert-True ([string]$multiReference.historyScan.mode -ceq 'reference') "kill switch='0' 必须退回 reference 模式"
    Assert-True ([long]$multiReference.historyScan.scanCount -eq 3) 'reference 模式 scanCount 必须等于目标数'
    Assert-True ([long]$multiReference.historyScan.enumeratedFiles -eq 9 -and
        [long]$multiReference.historyScan.fallbackFiles -eq 9 -and
        [long]$multiReference.historyScan.fullyAuthenticated -eq 9) `
        'reference 模式逐目标各扫一遍历史，每个文件都走参考认证链'

    foreach ($value in @('1', 'false', ' 0', '00', 'off')) {
        $notSwitched = Invoke-BatchPurge -Fixture $switchFixture -TargetPaths @($switchTargets[1]) -KillSwitchValue $value
        Assert-True ([string]$notSwitched.historyScan.mode -ceq 'fast') "kill switch 值 '$value' 不得关闭 fast 模式"
    }

    # 目标去重是 OrdinalIgnoreCase 且不做 Unicode 规范化，两种模式相同：只差大小写的目标按重复
    # 拒绝整批；NFC 与 NFD 写法是两个不同目标。
    $caseVariantTarget = Join-Path $switchFixture.targetsRoot 'ABSENT-1'
    $nfcTarget = Join-Path $switchFixture.targetsRoot ('caf' + [string][char]0x00E9)
    $nfdTarget = Join-Path $switchFixture.targetsRoot ('cafe' + [string][char]0x0301)
    foreach ($dedupCase in @(
            [pscustomobject]@{ name = 'fast'; killSwitch = $null },
            [pscustomobject]@{ name = 'reference'; killSwitch = '0' })) {
        $duplicateError = $null
        try {
            [void](Invoke-BatchPurge `
                -Fixture $switchFixture `
                -TargetPaths @($switchTargets[0], $caseVariantTarget) `
                -KillSwitchValue $dedupCase.killSwitch)
        } catch {
            $duplicateError = [string]$_.Exception.Message
        }
        Assert-True ($null -ne $duplicateError -and $duplicateError.Contains('重复')) `
            "只差大小写的目标在 $($dedupCase.name) 模式下必须按重复拒绝整批：$duplicateError"
        $unicodeVariants = Invoke-BatchPurge `
            -Fixture $switchFixture `
            -TargetPaths @($nfcTarget, $nfdTarget) `
            -KillSwitchValue $dedupCase.killSwitch
        Assert-True ($unicodeVariants.targetCount -eq 2 -and $unicodeVariants.alreadyAbsentCount -eq 2) `
            "NFC 与 NFD 写法在 $($dedupCase.name) 模式下必须是两个不同目标"
    }

    # --- 切片 2：快慢等价（同一份 evidence 布局各建一份，分别以 reference / fast 跑同一批）---
    $referenceFixture = New-EquivalenceFixture -Name 'ref'
    $fastFixture = New-EquivalenceFixture -Name 'fast'
    $expectedActions = @(
        'recovered-purged',
        'already-absent',
        'skipped-unsupported-transaction-schema',
        'skipped-target-error',
        'planned-applied-purged',
        'already-absent',
        'planned-applied-purged')

    Assert-True (
        (Get-ComparableFixtureState -Fixture $referenceFixture) -ceq
            (Get-ComparableFixtureState -Fixture $fastFixture)) `
        '两份等价夹具在批处理前必须逻辑相同'

    # --- 切片 3：坏记录（枚举顺序排在全部候选之后）让每个目标都 skipped-target-error ---
    $badRecordDirectory = Join-Path $referenceFixture.evidenceRoot 'zz-bad'
    Write-Utf8File -Path (Join-Path $badRecordDirectory 'transaction.json') -Text '{"artifactType":'
    $badStateBefore = Get-ComparableFixtureState -Fixture $referenceFixture
    $badReference = Invoke-BatchPurge `
        -Fixture $referenceFixture `
        -TargetPaths $referenceFixture.batchTargets `
        -KillSwitchValue '0'
    $badFast = Invoke-BatchPurge `
        -Fixture $referenceFixture `
        -TargetPaths $referenceFixture.batchTargets `
        -KillSwitchValue $null
    foreach ($badCase in @(
            [pscustomobject]@{ name = 'reference'; result = $badReference },
            [pscustomobject]@{ name = 'fast'; result = $badFast })) {
        $badResult = $badCase.result
        Assert-HistoryScanShape -Result $badResult -Scope "坏记录 $($badCase.name)"
        Assert-True ($badResult.completed -eq $false -and
            $badResult.targetCount -eq 7 -and
            $badResult.skippedCount -eq 7 -and
            $badResult.purgedCount -eq 0) "坏记录 $($badCase.name) 批次必须整批 fail-closed"
        Assert-True (
            @($badResult.results | Where-Object { [string]$_.action -cne 'skipped-target-error' }).Count -eq 0) `
            "坏记录 $($badCase.name) 每个目标都必须 skipped-target-error"
        Assert-True ($null -ne $badResult.historyScan.PSObject.Properties['failure'] -and
            [string]$badResult.historyScan.failure.phase -ceq 'scan') `
            "坏记录 $($badCase.name) historyScan 必须带 scan 阶段 failure"
    }
    Assert-True ([long]$badFast.historyScan.scanCount -eq 1) '坏记录 fast 模式也只扫描一次'
    $badReferenceComparable = ConvertTo-ComparableBatchResult -Result $badReference -Fixture $referenceFixture
    $badFastComparable = ConvertTo-ComparableBatchResult -Result $badFast -Fixture $referenceFixture
    Assert-True ($badReferenceComparable -ceq $badFastComparable) (
        "坏记录时 fast 与 reference 结果必须逐字段相等`nreference=$badReferenceComparable`nfast=$badFastComparable")
    Assert-True ((Get-ComparableFixtureState -Fixture $referenceFixture) -ceq $badStateBefore) `
        '坏记录批次不得写入 evidence 或目标命名空间'
    Remove-TestTree -Path $badRecordDirectory

    $referenceRich = Invoke-BatchPurge `
        -Fixture $referenceFixture `
        -TargetPaths $referenceFixture.batchTargets `
        -KillSwitchValue '0'
    $fastRich = Invoke-BatchPurge `
        -Fixture $fastFixture `
        -TargetPaths $fastFixture.batchTargets `
        -KillSwitchValue $null
    Assert-HistoryScanShape -Result $referenceRich -Scope '等价 reference'
    Assert-HistoryScanShape -Result $fastRich -Scope '等价 fast'
    Assert-True ((@($referenceRich.results.action) -join ',') -ceq ($expectedActions -join ',')) `
        "reference 模式等价夹具的逐目标 action 不符：$(@($referenceRich.results.action) -join ',')"
    Assert-True (([string]$referenceRich.results[3].error).Contains('不唯一')) `
        '多个可恢复事务必须以「不唯一」报错'
    $referenceComparable = ConvertTo-ComparableBatchResult -Result $referenceRich -Fixture $referenceFixture
    $fastComparable = ConvertTo-ComparableBatchResult -Result $fastRich -Fixture $fastFixture
    Assert-True ($referenceComparable -ceq $fastComparable) (
        "fast 与 reference 结果除 historyScan 外必须逐字段相等`nreference=$referenceComparable`nfast=$fastComparable")
    $referenceState = Get-ComparableFixtureState -Fixture $referenceFixture
    $fastState = Get-ComparableFixtureState -Fixture $fastFixture
    Assert-True ($referenceState -ceq $fastState) (
        "fast 与 reference 的落盘状态必须相同`nreference=$referenceState`nfast=$fastState")
    Assert-True ($fastState.Contains('evidence:<new-run:present-a>\transaction.json|purged|') -and
        $fastState.Contains('evidence:<new-run:present-b>\transaction.json|purged|')) `
        '存在目标必须各自新建 run 并 purge 到终态'
    Assert-True ([string]$referenceRich.historyScan.mode -ceq 'reference' -and
        [long]$referenceRich.historyScan.scanCount -eq 7) 'reference 模式 scanCount 必须等于目标数 7'
    # 规范位置 4 个（Recover-Case、café NFC、schema-one、multi）；café NFC 是 live 记录但与
    # 本批（NFD 写法）任何目标都不匹配，被预筛排除；nested\copy 与 legacy\deep 走回退。
    Assert-True ([string]$fastRich.historyScan.mode -ceq 'fast' -and
        [long]$fastRich.historyScan.scanCount -eq 1 -and
        [long]$fastRich.historyScan.enumeratedFiles -eq 6 -and
        [long]$fastRich.historyScan.canonicalFiles -eq 4 -and
        [long]$fastRich.historyScan.excludedByPrefilter -eq 1 -and
        [long]$fastRich.historyScan.fallbackFiles -eq 2 -and
        [long]$fastRich.historyScan.fullyAuthenticated -eq 5) `
        "fast 模式等价夹具的扫描计数不符：$($fastRich.historyScan | ConvertTo-Json -Compress)"

    # --- 切片 4：故障钩子在扫描与处理之间改写候选（仍是合法 JSON，只是字节变了）---
    $tamperFixture = New-HistoryFixture -Name 'tamper'
    $tamperTargets = @(
        (Join-Path $tamperFixture.targetsRoot 'present-1'),
        (Join-Path $tamperFixture.targetsRoot 'quarantined-2'),
        (Join-Path $tamperFixture.targetsRoot 'present-3'))
    New-PresentTarget -Path $tamperTargets[0]
    $tamperApply = New-QuarantinedTarget -Fixture $tamperFixture -TargetPath $tamperTargets[1] -Label 'quarantined-2'
    New-PresentTarget -Path $tamperTargets[2]
    $tamperTarget = $tamperTargets[1]
    $tamperHook = {
        param($context)
        $candidate = @($context.candidates | Where-Object { [string]$_.targetPath -ceq $tamperTarget })
        if ($candidate.Count -ne 1) { throw "篡改钩子期望恰好 1 个候选，实际 $($candidate.Count)" }
        $path = [string]$candidate[0].transactionPath
        $document = [IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
        [IO.File]::WriteAllText(
            $path,
            ($document | ConvertTo-Json -Depth 32 -Compress),
            [Text.UTF8Encoding]::new($false))
    }.GetNewClosure()
    $tamperResult = Invoke-BatchPurge `
        -Fixture $tamperFixture `
        -TargetPaths $tamperTargets `
        -KillSwitchValue $null `
        -AfterScan $tamperHook
    Assert-HistoryScanShape -Result $tamperResult -Scope '篡改'
    Assert-True ((@($tamperResult.results.action) -join ',') -ceq
        'planned-applied-purged,skipped-target-error,skipped-target-error') `
        "篡改后当前与剩余目标必须 skipped-target-error，已完成目标保持原结果：$(@($tamperResult.results.action) -join ',')"
    Assert-True ($tamperResult.completed -eq $false -and
        $tamperResult.purgedCount -eq 1 -and
        $tamperResult.skippedCount -eq 2) '篡改批次的汇总计数必须与逐目标结果一致'
    Assert-True (@($tamperResult.results[1..2] | Where-Object {
            -not ([string]$_.error).Contains('重新认证失败')
        }).Count -eq 0) '篡改导致的 skipped-target-error 必须说明候选重新认证失败'
    Assert-True ([string]$tamperResult.historyScan.failure.phase -ceq 'reauthentication' -and
        [string]$tamperResult.historyScan.failure.targetPath -ceq $tamperTargets[1]) `
        'historyScan.failure 必须记录重新认证阶段与当前目标'
    Assert-True ([IO.Directory]::Exists($tamperTargets[2]) -and
        [IO.Directory]::Exists([string]$tamperApply.quarantinePath) -and
        -not [IO.Directory]::Exists($tamperTargets[0])) `
        '篡改后剩余目标与被篡改目标的隔离目录都不得被处理'

    # --- 切片 5：故障钩子在扫描后删除目标：处理到它时如实报告 already-absent ---
    $vanishFixture = New-HistoryFixture -Name 'vanish'
    $vanishTarget = Join-Path $vanishFixture.targetsRoot 'vanish-after-scan'
    New-PresentTarget -Path $vanishTarget
    $vanishHook = {
        param($context)
        if (@($context.targetPaths) -cnotcontains $vanishTarget) { throw '删除钩子没有收到目标' }
        [IO.File]::Delete((Join-Path $vanishTarget 'payload.txt'))
        [IO.Directory]::Delete($vanishTarget)
    }.GetNewClosure()
    $vanishResult = Invoke-BatchPurge `
        -Fixture $vanishFixture `
        -TargetPaths @($vanishTarget) `
        -KillSwitchValue $null `
        -AfterScan $vanishHook
    Assert-True ($vanishResult.completed -eq $true -and
        [string]$vanishResult.results[0].action -ceq 'already-absent' -and
        $vanishResult.alreadyAbsentCount -eq 1) `
        "扫描后被删除的目标必须报告 already-absent：$(@($vanishResult.results.action) -join ',')"

    # --- 切片 6：祖先与后代同批：后代在处理时才复查存在性与隔离目录，报告 already-absent ---
    $nestedReferenceFixture = New-NestedFixture -Name 'nest-ref'
    $nestedFastFixture = New-NestedFixture -Name 'nest-fast'
    $nestedReference = Invoke-BatchPurge `
        -Fixture $nestedReferenceFixture `
        -TargetPaths $nestedReferenceFixture.batchTargets `
        -KillSwitchValue '0'
    $nestedFast = Invoke-BatchPurge `
        -Fixture $nestedFastFixture `
        -TargetPaths $nestedFastFixture.batchTargets `
        -KillSwitchValue $null
    foreach ($nestedCase in @(
            [pscustomobject]@{ name = 'reference'; result = $nestedReference },
            [pscustomobject]@{ name = 'fast'; result = $nestedFast })) {
        Assert-True ((@($nestedCase.result.results.action) -join ',') -ceq
            'planned-applied-purged,already-absent,already-absent') `
            "祖先与后代同批（$($nestedCase.name)）时后代必须报告 already-absent：$(@($nestedCase.result.results.action) -join ',')"
        Assert-True ($nestedCase.result.completed -eq $true) "祖先与后代同批（$($nestedCase.name)）必须整批完成"
    }
    $nestedReferenceComparable = ConvertTo-ComparableBatchResult -Result $nestedReference -Fixture $nestedReferenceFixture
    $nestedFastComparable = ConvertTo-ComparableBatchResult -Result $nestedFast -Fixture $nestedFastFixture
    Assert-True ($nestedReferenceComparable -ceq $nestedFastComparable) (
        "祖先与后代同批时 fast 与 reference 结果必须逐字段相等`nreference=$nestedReferenceComparable`nfast=$nestedFastComparable")
    Assert-True (
        (Get-ComparableFixtureState -Fixture $nestedReferenceFixture) -ceq
            (Get-ComparableFixtureState -Fixture $nestedFastFixture)) `
        '祖先与后代同批时 fast 与 reference 的落盘状态必须相同'

    # --- 切片 7：扫描后钩子只能经 fixture 入口到达 ---
    $productionEntryPath = Join-Path $projectRoot 'scripts\Invoke-CodexSafeTreeDelete.ps1'
    $productionCommand = Get-Command -Name $productionEntryPath
    $exposedTestParameters = @($productionCommand.Parameters.Keys | Where-Object {
        $_ -like 'Fixture*' -or $_ -like '*ForTest'
    })
    Assert-True ($exposedTestParameters.Count -eq 0) `
        "生产入口不得暴露 fixture 或测试钩子参数：$($exposedTestParameters -join ',')"
    Assert-True (-not [IO.File]::ReadAllText($productionEntryPath).Contains('AfterBatchHistoryScan')) `
        '生产入口不得把 BatchPurge 扫描后钩子传给库函数'

    # --- 切片 8：预筛的三种裁决（全部位于规范位置，目标都不存在，批处理不写任何东西）---
    # 排除：v3 终态、targetPath 不在本批的 live 记录、带 BOM 的终态。候选：targetPath 只差
    # 大小写的 live 记录。回退：多余属性、属性名只差大小写、schemaVersion 4、缺属性、status
    # 含可忽略字符（参考链的 -cnotin 按文化比较，仍视为 live）、status 是数组（参考链转成
    # 字符串后仍是 live）。候选与回退的记录 schemaVersion 都不受支持，结果是
    # skipped-unsupported-transaction-schema，被错误排除时会变成 already-absent。
    $prefilterFixture = New-HistoryFixture -Name 'prefilter'
    $prefilterNames = @(
        'terminal', 'case-candidate', 'extra-property', 'status-case',
        'schema-four', 'missing-property', 'soft-hyphen', 'status-array')
    $prefilterTarget = @{}
    foreach ($name in $prefilterNames) {
        $prefilterTarget[$name] = Join-Path $prefilterFixture.targetsRoot $name
    }
    $prefilterRecords = @(
        [pscustomobject]@{
            run = 'run-01-terminal-v3'
            properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 3 -Status 'purged' -TargetPath $prefilterTarget['terminal']
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-02-live-elsewhere'
            properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 2 -Status 'quarantined' -TargetPath (Join-Path $prefilterFixture.targetsRoot 'not-in-batch')
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-03-case-candidate'
            properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 1 -Status 'purging' -TargetPath (Join-Path $prefilterFixture.targetsRoot 'CASE-Candidate')
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-04-extra-property'
            properties = & {
                $properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 1 -Status 'purging' -TargetPath $prefilterTarget['extra-property']
                $properties['note'] = 'not a producer property'
                $properties
            }
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-05-status-case'
            properties = & {
                $properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 1 -Status 'purging' -TargetPath $prefilterTarget['status-case']
                $properties.Remove('status')
                $properties['Status'] = 'purging'
                $properties
            }
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-06-schema-four'
            properties = & {
                $properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 2 -Status 'purging' -TargetPath $prefilterTarget['schema-four']
                $properties['schemaVersion'] = 4
                $properties
            }
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-07-missing-property'
            properties = & {
                $properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 1 -Status 'purging' -TargetPath $prefilterTarget['missing-property']
                $properties.Remove('updatedAtUtc')
                $properties
            }
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-08-soft-hyphen'
            properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 1 -Status ('pur' + [string][char]0x00AD + 'ging') -TargetPath $prefilterTarget['soft-hyphen']
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-09-status-array'
            properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 1 -Status @('purging') -TargetPath $prefilterTarget['status-array']
            bom = $false
        },
        [pscustomobject]@{
            run = 'run-10-bom-terminal'
            properties = New-ProducerTransactionProperties -Fixture $prefilterFixture -SchemaVersion 2 -Status 'purged' -TargetPath $prefilterTarget['terminal']
            bom = $true
        })
    foreach ($record in $prefilterRecords) {
        Write-HistoryRecord `
            -Path (Join-Path $prefilterFixture.evidenceRoot "$($record.run)\transaction.json") `
            -Properties $record.properties `
            -Bom:$record.bom
    }
    $prefilterTargets = @($prefilterNames | ForEach-Object { $prefilterTarget[$_] })
    $prefilterStateBefore = Get-ComparableFixtureState -Fixture $prefilterFixture
    $prefilterReference = Invoke-BatchPurge -Fixture $prefilterFixture -TargetPaths $prefilterTargets -KillSwitchValue '0'
    $prefilterFast = Invoke-BatchPurge -Fixture $prefilterFixture -TargetPaths $prefilterTargets -KillSwitchValue $null
    Assert-HistoryScanShape -Result $prefilterReference -Scope '预筛 reference'
    Assert-HistoryScanShape -Result $prefilterFast -Scope '预筛 fast'
    $prefilterExpectedActions = @('already-absent') + @('skipped-unsupported-transaction-schema') * 7
    Assert-True ((@($prefilterReference.results.action) -join ',') -ceq ($prefilterExpectedActions -join ',')) `
        "预筛夹具 reference 模式的逐目标 action 不符：$(@($prefilterReference.results.action) -join ',')"
    $prefilterReferenceComparable = ConvertTo-ComparableBatchResult -Result $prefilterReference -Fixture $prefilterFixture
    $prefilterFastComparable = ConvertTo-ComparableBatchResult -Result $prefilterFast -Fixture $prefilterFixture
    Assert-True ($prefilterReferenceComparable -ceq $prefilterFastComparable) (
        "预筛夹具 fast 与 reference 结果除 historyScan 外必须逐字段相等`nreference=$prefilterReferenceComparable`nfast=$prefilterFastComparable")
    Assert-True ((Get-ComparableFixtureState -Fixture $prefilterFixture) -ceq $prefilterStateBefore) `
        '预筛夹具的批处理不得写入 evidence 或目标命名空间'
    Assert-True ([long]$prefilterReference.historyScan.scanCount -eq 8 -and
        [long]$prefilterReference.historyScan.enumeratedFiles -eq 80 -and
        [long]$prefilterReference.historyScan.fallbackFiles -eq 80 -and
        [long]$prefilterReference.historyScan.fullyAuthenticated -eq 80) `
        "预筛夹具 reference 模式的扫描计数不符：$($prefilterReference.historyScan | ConvertTo-Json -Compress)"
    Assert-True ([long]$prefilterFast.historyScan.scanCount -eq 1 -and
        [long]$prefilterFast.historyScan.enumeratedFiles -eq 10 -and
        [long]$prefilterFast.historyScan.canonicalFiles -eq 4 -and
        [long]$prefilterFast.historyScan.excludedByPrefilter -eq 3 -and
        [long]$prefilterFast.historyScan.fallbackFiles -eq 6 -and
        [long]$prefilterFast.historyScan.fullyAuthenticated -eq 7) `
        "预筛夹具 fast 模式的扫描计数不符（排除 3、候选 1、回退 6）：$($prefilterFast.historyScan | ConvertTo-Json -Compress)"

    # --- 切片 9：参考链一定失败的规范位置记录：预筛必须回退而不是排除，两种模式都在扫描阶段
    # fail-closed，且结果逐字段相等。每条坏记录除了一处缺陷都是规范形态的终态记录（或 live 但
    # targetPath 为空），缺少对应防线的预筛会把它排除，fast 模式随之「成功」。---
    $badFixture = New-HistoryFixture -Name 'prefilter-bad'
    $badTargets = @(
        (Join-Path $badFixture.targetsRoot 'absent-1'),
        (Join-Path $badFixture.targetsRoot 'absent-2'))
    New-TerminalHistoryRecord -Fixture $badFixture -RelativePath 'run-a\transaction.json' -TargetPath $badTargets[0]
    $badRunDirectory = Join-Path $badFixture.evidenceRoot 'zz-bad'
    $badRecordPath = Join-Path $badRunDirectory 'transaction.json'
    $badStateBefore = Get-ComparableFixtureState -Fixture $badFixture
    $hugeInteger = '1' + ('0' * 399)
    $badCases = @(
        [pscustomobject]@{ name = '非严格 UTF-8'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = $null; invalidUtf8 = $true; layout = 'file' },
        [pscustomobject]@{ name = '嵌套对象内属性名只差大小写'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = '[{"anchor":1,"Anchor":2}]'; invalidUtf8 = $false; layout = 'file' },
        [pscustomobject]@{ name = '嵌套对象使用 PSObject 保留名'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = '[{"PSObject":1}]'; invalidUtf8 = $false; layout = 'file' },
        [pscustomobject]@{ name = '嵌套对象有空属性名'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = '[{"":1}]'; invalidUtf8 = $false; layout = 'file' },
        [pscustomobject]@{ name = '嵌套超过 ConvertFrom-Json 深度'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = ('[' * 40) + (']' * 40); invalidUtf8 = $false; layout = 'file' },
        [pscustomobject]@{ name = '400 位整数'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = "[$hugeInteger]"; invalidUtf8 = $false; layout = 'file' },
        [pscustomobject]@{ name = 'live 记录 targetPath 为空'; status = 'quarantined'; targetPath = ''; rawAnchors = $null; invalidUtf8 = $false; layout = 'file' },
        [pscustomobject]@{ name = '硬链接'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = $null; invalidUtf8 = $false; layout = 'hard-link' },
        [pscustomobject]@{ name = '读取时被独占打开'; status = 'purged'; targetPath = $badTargets[1]; rawAnchors = $null; invalidUtf8 = $false; layout = 'locked' })
    foreach ($badCase in $badCases) {
        $writeParameters = @{
            Properties = New-ProducerTransactionProperties `
                -Fixture $badFixture `
                -SchemaVersion 2 `
                -Status $badCase.status `
                -TargetPath $badCase.targetPath
            InvalidUtf8 = [bool]$badCase.invalidUtf8
        }
        if ($null -ne $badCase.rawAnchors) { $writeParameters['RawAnchors'] = [string]$badCase.rawAnchors }
        $hardLinkSource = Join-Path $badFixture.root 'hard-link-source.json'
        if ($badCase.layout -ceq 'hard-link') {
            Write-HistoryRecord -Path $hardLinkSource @writeParameters
            [void][IO.Directory]::CreateDirectory($badRunDirectory)
            [void](New-Item -ItemType HardLink -Path $badRecordPath -Value $hardLinkSource -ErrorAction Stop)
        } else {
            Write-HistoryRecord -Path $badRecordPath @writeParameters
        }
        $lock = $null
        try {
            if ($badCase.layout -ceq 'locked') {
                $lock = [IO.File]::Open($badRecordPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            }
            $caseReference = Invoke-BatchPurge -Fixture $badFixture -TargetPaths $badTargets -KillSwitchValue '0'
            $caseFast = Invoke-BatchPurge -Fixture $badFixture -TargetPaths $badTargets -KillSwitchValue $null
        } finally {
            if ($null -ne $lock) { $lock.Dispose() }
        }
        foreach ($caseRun in @(
                [pscustomobject]@{ mode = 'reference'; result = $caseReference },
                [pscustomobject]@{ mode = 'fast'; result = $caseFast })) {
            $scope = "坏记录「$($badCase.name)」$($caseRun.mode)"
            Assert-HistoryScanShape -Result $caseRun.result -Scope $scope
            Assert-True ($caseRun.result.completed -eq $false -and
                $caseRun.result.skippedCount -eq 2 -and
                @($caseRun.result.results | Where-Object { [string]$_.action -cne 'skipped-target-error' }).Count -eq 0) `
                "$scope 必须整批 skipped-target-error：$(@($caseRun.result.results.action) -join ',')"
            Assert-True ($null -ne $caseRun.result.historyScan.PSObject.Properties['failure'] -and
                [string]$caseRun.result.historyScan.failure.phase -ceq 'scan') `
                "$scope historyScan 必须带 scan 阶段 failure"
        }
        Assert-True ([long]$caseFast.historyScan.excludedByPrefilter -eq 1 -and
            [long]$caseFast.historyScan.fallbackFiles -eq 1) `
            "坏记录「$($badCase.name)」不得被预筛排除：$($caseFast.historyScan | ConvertTo-Json -Compress)"
        $caseReferenceComparable = ConvertTo-ComparableBatchResult -Result $caseReference -Fixture $badFixture
        $caseFastComparable = ConvertTo-ComparableBatchResult -Result $caseFast -Fixture $badFixture
        Assert-True ($caseReferenceComparable -ceq $caseFastComparable) (
            "坏记录「$($badCase.name)」fast 与 reference 结果必须逐字段相等`nreference=$caseReferenceComparable`nfast=$caseFastComparable")
        if ($badCase.layout -ceq 'hard-link') {
            [IO.File]::Delete($badRecordPath)
            [IO.File]::Delete($hardLinkSource)
        }
        Remove-TestTree -Path $badRunDirectory
        Assert-True ((Get-ComparableFixtureState -Fixture $badFixture) -ceq $badStateBefore) `
            "坏记录「$($badCase.name)」批次不得写入 evidence 或目标命名空间"
    }

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteBatchHistoryScan'
        fastElapsedMs = [long]$multiFast.historyScan.elapsedMs
        referenceElapsedMs = [long]$multiReference.historyScan.elapsedMs
    }
} finally {
    [Environment]::SetEnvironmentVariable($killSwitchName, $originalKillSwitch)
    if ([IO.Directory]::Exists($evidenceHome)) {
        Remove-TestTree -Path $evidenceHome
    }
}
