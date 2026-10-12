[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #76，spec #73「BatchPurge 单次历史扫描」):
# 1. 唯一接缝：fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 BatchPurge mode；
#    只观察结果字段（含新增 historyScan）与 evidence / 目标命名空间的前后状态。
# 2. kill switch：CODEX_SAFE_TREE_DELETE_BATCH_HISTORY_SCAN 只有字符串 '0' 退回逐目标参考查找。
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

function New-TerminalHistoryRecord {
    param(
        [Parameter(Mandatory)][object]$Fixture,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    # 终态记录只需通过参考认证链（严格 JSON），随后被 status 过滤；不是真实删除证据。
    Write-Utf8File `
        -Path (Join-Path $Fixture.evidenceRoot $RelativePath) `
        -Text ([pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-safe-tree-delete-transaction'
            schemaVersion = 2
            targetPath = $TargetPath
            status = 'purged'
        } | ConvertTo-Json -Depth 4)
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
    Assert-True ([long]$historyScan.excludedByPrefilter -eq 0) `
        "$Scope 本 ticket 不做 C# 预筛，excludedByPrefilter 必须恒为 0"
    Assert-True (
        [long]$historyScan.canonicalFiles + [long]$historyScan.fallbackFiles -eq
            [long]$historyScan.enumeratedFiles) `
        "$Scope canonicalFiles + fallbackFiles 必须等于 enumeratedFiles"
}

$records = [Collections.Generic.List[object]]::new()
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
    Assert-True ([long]$singleFast.historyScan.canonicalFiles -eq 2) 'run 目录第一层的 2 个文件是规范位置'
    Assert-True ([long]$singleFast.historyScan.fallbackFiles -eq 1) '嵌套位置的 1 个文件走回退'
    Assert-True ([long]$singleFast.historyScan.fullyAuthenticated -eq 3) '本 ticket 每个历史文件都必须完整参考认证'
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
    Assert-True ([long]$multiReference.historyScan.enumeratedFiles -eq 9) 'reference 模式逐目标各扫一遍历史'

    foreach ($value in @('1', 'false', ' 0', '00', 'off')) {
        $notSwitched = Invoke-BatchPurge -Fixture $switchFixture -TargetPaths @($switchTargets[1]) -KillSwitchValue $value
        Assert-True ([string]$notSwitched.historyScan.mode -ceq 'fast') "kill switch 值 '$value' 不得关闭 fast 模式"
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
    Assert-True ([string]$fastRich.historyScan.mode -ceq 'fast' -and
        [long]$fastRich.historyScan.scanCount -eq 1 -and
        [long]$fastRich.historyScan.enumeratedFiles -eq 6 -and
        [long]$fastRich.historyScan.canonicalFiles -eq 4 -and
        [long]$fastRich.historyScan.fallbackFiles -eq 2 -and
        [long]$fastRich.historyScan.fullyAuthenticated -eq 6) `
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
