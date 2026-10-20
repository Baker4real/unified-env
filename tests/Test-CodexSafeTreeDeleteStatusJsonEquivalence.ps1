[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# issue #90：Status fast scan 对异常 JSON 的结论必须与 PowerShell 参考路径逐字节一致。
# 同一 evidence 根分别跑 FAST_SCAN=1 / FAST_SCAN=0（+PARALLEL_FALLBACK=0 纯串行基线），
# 逐 operation 比较完整 JSON；针对性断言钉住错误文本层（严格词法 / ConvertFrom-Json 兼容）。
$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$fixtureRoot = Join-Path $projectRoot (".scratch\safe-tree-delete-tests-status-json-eq-{0}" -f ([guid]::NewGuid().ToString('N')))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$bogusPolicyPath = Join-Path $fixtureRoot 'nonexistent-policy.json'
$hugeInteger = '9' * 400
$bigInteger21 = '123456789012345678901'
$script:assertions = 0

. $hostSafetyLibraryPath

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:assertions++
    if (-not $Condition) { throw $Message }
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete Status JSON equivalence cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete Status JSON equivalence cleanup'
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CaseOperation {
    param([Parameter(Mandatory)][object]$Status, [Parameter(Mandatory)][string]$OperationId)

    $matches = @($Status.operations | Where-Object operationId -ceq $OperationId)
    Assert-True ($matches.Count -eq 1) "Status operation $OperationId 必须唯一。"
    return $matches[0]
}

function ConvertTo-StatusSemanticJson {
    param([Parameter(Mandatory)][object]$Status)

    $semantic = [ordered]@{}
    foreach ($property in $Status.PSObject.Properties) {
        if ($property.Name -cin @('capturedAtUtc', 'metrics', 'statusSegments')) { continue }
        $semantic[$property.Name] = $property.Value
    }
    return $semantic | ConvertTo-Json -Depth 100 -Compress
}

function New-CasePlanRun {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [switch]$DeleteTarget
    )

    $target = Join-Path $fixtureRoot "target-$CaseName"
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText(
        (Join-Path $target 'payload.txt'),
        "payload-$CaseName",
        [Text.UTF8Encoding]::new($false))
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $target `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    if ($DeleteTarget) { Remove-TestTree -Path $target }
    $runDirectory = Split-Path -Parent ([string]$plan.planPath)
    return [pscustomobject][ordered]@{
        caseName = $CaseName
        operationId = Split-Path -Leaf $runDirectory
        targetPath = $target
        planPath = [string]$plan.planPath
        runDirectory = $runDirectory
    }
}

function ConvertTo-CompactPlanText {
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [AllowNull()][string]$PolicyPathOverride
    )

    $document = [IO.File]::ReadAllText($PlanPath) | ConvertFrom-Json -Depth 128 -DateKind String
    if ($null -ne $PolicyPathOverride) { $document.policyPath = $PolicyPathOverride }
    return ($document | ConvertTo-Json -Depth 100 -Compress)
}

function Add-TrailingComma {
    param([Parameter(Mandatory)][string]$Text)

    $index = $Text.LastIndexOf('}')
    Assert-True ($index -gt 0) 'JSON 文本必须包含对象结束符。'
    return $Text.Substring(0, $index) + ',' + $Text.Substring($index)
}

function Add-LeadingComment {
    param([Parameter(Mandatory)][string]$Text)

    $index = $Text.IndexOf('{')
    Assert-True ($index -ge 0) 'JSON 文本必须包含对象开始符。'
    return $Text.Insert($index + 1, '/*issue90*/')
}

function Add-TopLevelPropertyAfterOpen {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$PropertyJson
    )

    $index = $Text.IndexOf('{')
    Assert-True ($index -ge 0) 'JSON 文本必须包含对象开始符。'
    return $Text.Insert($index + 1, $PropertyJson + ',')
}

function Edit-FirstSummaryFileCount {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Replacement
    )

    $summaryIndex = $Text.IndexOf('"summary":')
    Assert-True ($summaryIndex -ge 0) 'plan 必须包含 summary 段。'
    $head = $Text.Substring(0, $summaryIndex)
    $tail = $Text.Substring($summaryIndex)
    $replaced = [regex]::new('"fileCount":(\d+)').Replace($tail, $Replacement, 1)
    Assert-True ($replaced -cne $tail) 'summary.fileCount 注入必须生效。'
    return $head + $replaced
}

function New-ObservedTransactionText {
    param(
        [Parameter(Mandatory)][object]$Run,
        [long]$SchemaVersion = 2L,
        [string]$Status = 'quarantined'
    )

    $planDocument = [IO.File]::ReadAllText($Run.planPath) | ConvertFrom-Json -Depth 128 -DateKind String
    $generationId = [string]$planDocument.generationId
    $transaction = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-transaction'
        schemaVersion = $SchemaVersion
        generationId = $generationId
        planPath = $Run.planPath
        planSha256 = (Get-Sha256Hex -Path $Run.planPath)
        targetPath = $Run.targetPath
        quarantinePath = Join-Path `
            (Split-Path -Parent $Run.targetPath) `
            ('.codex-safe-delete-{0}.quarantine' -f $generationId)
        directoryCommitAnchors = @()
        status = $Status
        updatedAtUtc = [datetimeoffset]::UtcNow.ToString(
            'o', [Globalization.CultureInfo]::InvariantCulture)
    }
    return ($transaction | ConvertTo-Json -Depth 16 -Compress)
}

# operationId（run 目录名）→ 友好 case 名与预期错误层。
$caseMap = [ordered]@{}
function Register-Case {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$CaseName,
        [ValidateSet('none', 'strict', 'cfj')][string]$ErrorClass = 'none'
    )
    Assert-True (-not $caseMap.Contains($OperationId)) "operationId $OperationId 不得重复。"
    $caseMap[$OperationId] = [pscustomobject][ordered]@{
        caseName = $CaseName
        errorClass = $ErrorClass
    }
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'status-json-equivalence'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                allowHardLinks = $false
                allowInternalDirectoryJunctions = $false
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    Write-Utf8File $policyPath ($policy | ConvertTo-Json -Depth 16)

    # 健康对照：producer 规范 plan 在两条路径下都必须分类为 planned。
    $healthyRun = New-CasePlanRun -CaseName 'case-01-healthy-planned'
    Register-Case -OperationId $healthyRun.operationId -CaseName 'case-01-healthy-planned'

    # plan 严格词法失败：fast scan 直接裁决，错误文本必须与参考路径一致。
    foreach ($variant in @('trailing-comma', 'comment')) {
        $caseName = "case-02-plan-strict-$variant"
        $run = New-CasePlanRun -CaseName $caseName
        $planText = [IO.File]::ReadAllText($run.planPath)
        $defective = if ($variant -ceq 'trailing-comma') {
            Add-TrailingComma $planText
        } else {
            Add-LeadingComment $planText
        }
        Write-Utf8File $run.planPath $defective
        Register-Case -OperationId $run.operationId -CaseName $caseName -ErrorClass 'strict'
    }

    # plan 顶层 ConvertFrom-Json 兼容缺陷（canonical shape 兜底回退，等价性对照）。
    $planTopLevelVariants = @(
        @{ suffix = 'casedup'; property = '"SchemaVersion":1' },
        @{ suffix = 'empty-name'; property = '"":1' },
        @{ suffix = 'reserved'; property = '"PSObject":1' }
    )
    foreach ($variant in $planTopLevelVariants) {
        $caseName = "case-03-plan-cfj-$([string]$variant.suffix)"
        $run = New-CasePlanRun -CaseName $caseName
        $compact = ConvertTo-CompactPlanText -PlanPath $run.planPath
        Write-Utf8File $run.planPath (
            Add-TopLevelPropertyAfterOpen -Text $compact -PropertyJson ([string]$variant.property))
        Register-Case -OperationId $run.operationId -CaseName $caseName -ErrorClass 'cfj'
    }
    $caseName = 'case-03-plan-cfj-hugeint-schemaversion'
    $run = New-CasePlanRun -CaseName $caseName
    $compact = ConvertTo-CompactPlanText -PlanPath $run.planPath
    $defective = [regex]::new([regex]::Escape('"schemaVersion":1')).Replace(
        $compact, '"schemaVersion":' + $hugeInteger, 1)
    Assert-True ($defective -cne $compact) 'plan schemaVersion 超长整数注入必须生效。'
    Write-Utf8File $run.planPath $defective
    Register-Case -OperationId $run.operationId -CaseName $caseName -ErrorClass 'cfj'

    # plan 嵌套（summary）ConvertFrom-Json 兼容缺陷 + policyPath 伪造不匹配：
    # 参考路径在 plan 审批前就因 ConvertFrom-Json 失败；fast scan 必须先过兼容门再裁决。
    $planNestedVariants = @(
        @{ suffix = 'casedup'; replacement = '"fileCount":$1,"FileCount":$1'; errorClass = 'cfj' },
        @{ suffix = 'empty-name'; replacement = '"":1,"fileCount":$1'; errorClass = 'cfj' },
        @{ suffix = 'reserved'; replacement = '"PSObject":1,"fileCount":$1'; errorClass = 'cfj' },
        @{ suffix = 'hugeint'; replacement = ('"fileCount":' + $hugeInteger); errorClass = 'cfj' },
        @{ suffix = 'bigint21-control'; replacement = ('"fileCount":' + $bigInteger21); errorClass = 'none' }
    )
    foreach ($variant in $planNestedVariants) {
        $caseName = "case-04-plan-nested-$([string]$variant.suffix)-policydrift"
        $run = New-CasePlanRun -CaseName $caseName
        $compact = ConvertTo-CompactPlanText -PlanPath $run.planPath -PolicyPathOverride $bogusPolicyPath
        Write-Utf8File $run.planPath (
            Edit-FirstSummaryFileCount -Text $compact -Replacement ([string]$variant.replacement))
        Register-Case -OperationId $run.operationId -CaseName $caseName -ErrorClass ([string]$variant.errorClass)
    }

    # 嵌套缺陷 + plan 可审批 + 无 transaction + target/quarantine 均缺失：
    # fast scan 的 approved-missing-transaction 分支不得越过 ConvertFrom-Json 兼容门。
    $caseName = 'case-05-plan-nested-casedup-approved-missing-tx'
    $run = New-CasePlanRun -CaseName $caseName -DeleteTarget
    $compact = ConvertTo-CompactPlanText -PlanPath $run.planPath
    Write-Utf8File $run.planPath (
        Edit-FirstSummaryFileCount -Text $compact -Replacement '"fileCount":$1,"FileCount":$1')
    Register-Case -OperationId $run.operationId -CaseName $caseName -ErrorClass 'cfj'

    # plan 被拒（policyPath 不匹配）且存在观测 transaction：transaction 各类异常 JSON。
    $rejectedTransactionVariants = @(
        @{ suffix = 'strict-trailing-comma'; inject = { param([string]$t) Add-TrailingComma $t }; errorClass = 'strict' },
        @{ suffix = 'strict-comment'; inject = { param([string]$t) Add-LeadingComment $t }; errorClass = 'strict' },
        @{ suffix = 'cfj-casedup'; inject = { param([string]$t) Add-TopLevelPropertyAfterOpen -Text $t -PropertyJson '"Status":"quarantined"' }; errorClass = 'cfj' },
        @{ suffix = 'cfj-empty-name'; inject = { param([string]$t) Add-TopLevelPropertyAfterOpen -Text $t -PropertyJson '"":1' }; errorClass = 'cfj' },
        @{ suffix = 'cfj-reserved'; inject = { param([string]$t) Add-TopLevelPropertyAfterOpen -Text $t -PropertyJson '"PSObject":1' }; errorClass = 'cfj' },
        @{ suffix = 'cfj-hugeint-schemaversion'; inject = { param([string]$t) [regex]::new([regex]::Escape('"schemaVersion":2')).Replace($t, '"schemaVersion":' + $hugeInteger, 1) }; errorClass = 'cfj' },
        @{ suffix = 'nested-anchors-casedup'; inject = { param([string]$t) $t.Replace('"directoryCommitAnchors":[]', '"directoryCommitAnchors":[{"anchor":1,"Anchor":2}]') }; errorClass = 'cfj' },
        @{ suffix = 'nested-anchors-empty-name'; inject = { param([string]$t) $t.Replace('"directoryCommitAnchors":[]', '"directoryCommitAnchors":[{"":1}]') }; errorClass = 'cfj' },
        @{ suffix = 'nested-anchors-reserved'; inject = { param([string]$t) $t.Replace('"directoryCommitAnchors":[]', '"directoryCommitAnchors":[{"PSObject":1}]') }; errorClass = 'cfj' },
        @{ suffix = 'nested-anchors-hugeint'; inject = { param([string]$t) $t.Replace('"directoryCommitAnchors":[]', '"directoryCommitAnchors":[{"anchor":' + $hugeInteger + '}]') }; errorClass = 'cfj' }
    )
    foreach ($variant in $rejectedTransactionVariants) {
        $caseName = "case-06-rejtx-$([string]$variant.suffix)"
        $run = New-CasePlanRun -CaseName $caseName
        Write-Utf8File $run.planPath (
            ConvertTo-CompactPlanText -PlanPath $run.planPath -PolicyPathOverride $bogusPolicyPath)
        $transactionText = New-ObservedTransactionText -Run $run
        $transactionText = & ([scriptblock]$variant.inject) $transactionText
        Assert-True (-not [string]::IsNullOrEmpty($transactionText)) 'transaction 注入必须产生文本。'
        Write-Utf8File (Join-Path $run.runDirectory 'transaction.json') $transactionText
        Register-Case -OperationId $run.operationId -CaseName $caseName -ErrorClass ([string]$variant.errorClass)
    }

    # orphan transaction（无 plan.json）：fast scan 固定回退，等价性对照。
    $caseName = 'case-07-orphan-strict-trailing-comma'
    $orphanRun = Join-Path $evidenceRoot $caseName
    [void][IO.Directory]::CreateDirectory($orphanRun)
    Write-Utf8File (Join-Path $orphanRun 'transaction.json') (
        Add-TrailingComma '{"artifactType":"env-governance.codex-safe-tree-delete-transaction","schemaVersion":2}')
    Register-Case -OperationId $caseName -CaseName $caseName -ErrorClass 'strict'

    # 归档记录：terminal-archive.json 各类异常 JSON（归档 fast 路径总是回退，等价性对照）。
    $archivedVariants = @(
        @{ suffix = 'strict-trailing-comma'; inject = { param([string]$t) Add-TrailingComma $t }; errorClass = 'strict' },
        @{ suffix = 'strict-comment'; inject = { param([string]$t) Add-LeadingComment $t }; errorClass = 'strict' },
        @{ suffix = 'cfj-casedup'; inject = { param([string]$t) Add-TopLevelPropertyAfterOpen -Text $t -PropertyJson '"SchemaVersion":1' }; errorClass = 'cfj' },
        @{ suffix = 'cfj-empty-name'; inject = { param([string]$t) Add-TopLevelPropertyAfterOpen -Text $t -PropertyJson '"":1' }; errorClass = 'cfj' },
        @{ suffix = 'cfj-reserved'; inject = { param([string]$t) Add-TopLevelPropertyAfterOpen -Text $t -PropertyJson '"PSObject":1' }; errorClass = 'cfj' },
        @{ suffix = 'cfj-hugeint-schemaversion'; inject = { param([string]$t) [regex]::new('"schemaVersion":\s*\d+').Replace($t, '"schemaVersion":' + $hugeInteger, 1) }; errorClass = 'cfj' }
    )
    foreach ($variant in $archivedVariants) {
        $caseName = "case-08-arch-$([string]$variant.suffix)"
        $archTarget = Join-Path $fixtureRoot "target-$caseName"
        [void][IO.Directory]::CreateDirectory($archTarget)
        [IO.File]::WriteAllText(
            (Join-Path $archTarget 'payload.txt'),
            "payload-$caseName",
            [Text.UTF8Encoding]::new($false))
        $archPlan = & $entryPath `
            -Mode Plan `
            -TargetPath $archTarget `
            -CapabilityRoot $fixtureRoot `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
        $archApply = & $entryPath `
            -Mode Apply `
            -PlanPath ([string]$archPlan.planPath) `
            -ApprovedPlanSha256 ([string]$archPlan.planSha256) `
            -ConfirmApply `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
        $archPurge = & $entryPath `
            -Mode Purge `
            -TransactionPath ([string]$archApply.transactionPath) `
            -ApprovedTransactionSha256 ([string]$archApply.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
        $archArchive = & $entryPath `
            -Mode Archive `
            -TransactionPath ([string]$archPurge.transactionPath) `
            -ApprovedTransactionSha256 ([string]$archPurge.transactionSha256) `
            -ConfirmArchive `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
        Assert-True ([bool]$archArchive.archived) "$caseName 归档必须成功。"
        $archRunDirectory = Split-Path -Parent ([string]$archPurge.transactionPath)
        $archMarkerPath = Join-Path $archRunDirectory 'terminal-archive.json'
        $archMarkerText = [IO.File]::ReadAllText($archMarkerPath)
        $archMarkerText = & ([scriptblock]$variant.inject) $archMarkerText
        Assert-True (-not [string]::IsNullOrEmpty($archMarkerText)) 'terminal-archive 注入必须产生文本。'
        Write-Utf8File $archMarkerPath $archMarkerText
        Register-Case -OperationId (Split-Path -Leaf $archRunDirectory) -CaseName $caseName `
            -ErrorClass ([string]$variant.errorClass)
    }

    # v3 approved-terminal：quarantineTimeAnchor 嵌套空属性名；fast scan 不得判 terminal。
    $caseName = 'case-09-v3-terminal-nested-empty-name'
    $run = New-CasePlanRun -CaseName $caseName -DeleteTarget
    $v3Text = New-ObservedTransactionText -Run $run -SchemaVersion 3L -Status 'purged'
    $v3Document = $v3Text | ConvertFrom-Json -Depth 16 -DateKind String
    $v3Document | Add-Member -NotePropertyName quarantineTimeAnchor `
        -NotePropertyValue ([pscustomobject][ordered]@{ note = 'fixture' })
    $v3Document | Add-Member -NotePropertyName restoreJournalAnchors -NotePropertyValue @()
    $v3Text = $v3Document | ConvertTo-Json -Depth 16 -Compress
    $v3Defective = $v3Text.Replace('"quarantineTimeAnchor":{"note":"fixture"}', '"quarantineTimeAnchor":{"":1}')
    Assert-True ($v3Defective -cne $v3Text) 'v3 quarantineTimeAnchor 缺陷注入必须生效。'
    Write-Utf8File (Join-Path $run.runDirectory 'transaction.json') $v3Defective
    Register-Case -OperationId $run.operationId -CaseName $caseName -ErrorClass 'cfj'

    $previousFastScan = $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN
    $previousParallelFallback = $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK
    try {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '1'
        $fastStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = '0'
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = '0'
        $slowStatus = & $entryPath -Mode Status `
            -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
    } finally {
        $env:CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN = $previousFastScan
        $env:CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK = $previousParallelFallback
    }

    Assert-True (@($fastStatus.operations).Count -eq $caseMap.Count) `
        "fast Status operation 数必须等于 case 数（$($caseMap.Count)）。"
    Assert-True (@($slowStatus.operations).Count -eq $caseMap.Count) `
        "slow Status operation 数必须等于 case 数（$($caseMap.Count)）。"

    $mismatches = [Collections.Generic.List[string]]::new()
    foreach ($operationId in $caseMap.Keys) {
        $caseName = [string]$caseMap[$operationId].caseName
        $fastOperation = Get-CaseOperation -Status $fastStatus -OperationId $operationId
        $slowOperation = Get-CaseOperation -Status $slowStatus -OperationId $operationId
        $fastJson = $fastOperation | ConvertTo-Json -Depth 100 -Compress
        $slowJson = $slowOperation | ConvertTo-Json -Depth 100 -Compress
        $script:assertions++
        if ($fastJson -cne $slowJson) {
            $mismatches.Add("$caseName`nfast=$fastJson`nslow=$slowJson")
        }
    }
    Assert-True ($mismatches.Count -eq 0) `
        ("issue #90: fast scan 与参考路径发散的 case 数 " + $mismatches.Count + "：`n" + ($mismatches -join "`n---`n"))
    Assert-True ((ConvertTo-StatusSemanticJson $fastStatus) -ceq
        (ConvertTo-StatusSemanticJson $slowStatus)) `
        'issue #90: 混合异常 JSON 的完整 Status 语义输出必须 fast/slow 等价。'

    Assert-True (-not [bool]$fastStatus.complete -and -not [bool]$slowStatus.complete) `
        '存在异常记录的 Status 必须 complete=false。'
    Assert-True ((Get-CaseOperation -Status $slowStatus -OperationId $healthyRun.operationId).lifecycle -ceq 'planned' -and
        (Get-CaseOperation -Status $fastStatus -OperationId $healthyRun.operationId).lifecycle -ceq 'planned') `
        '健康对照必须在两条路径下都分类为 planned。'

    foreach ($operationId in $caseMap.Keys) {
        $caseName = [string]$caseMap[$operationId].caseName
        $errorClass = [string]$caseMap[$operationId].errorClass
        if ($errorClass -ceq 'none') { continue }
        $operation = Get-CaseOperation -Status $slowStatus -OperationId $operationId
        Assert-True ($operation.lifecycle -ceq 'manual-review') `
            "$caseName 必须分类为 manual-review。"
        $errorText = (@($operation.errors) -join ' ')
        if ($errorClass -ceq 'strict') {
            Assert-True ($errorText.StartsWith('严格 JSON 词法校验失败：')) `
                "$caseName 必须以严格词法错误开头：$errorText"
            Assert-True ($errorText -cnotmatch 'Exception calling') `
                "issue #90: $caseName 严格词法错误文本不得携带 PS 方法调用包装：$errorText"
        } else {
            Assert-True ($errorText -match 'different casing|empty string|reserved|too large') `
                "$caseName 必须真实打到 ConvertFrom-Json 兼容层：$errorText"
        }
    }

    $bigIntControlId = @($caseMap.Keys | Where-Object {
            [string]$caseMap[$_].caseName -ceq 'case-04-plan-nested-bigint21-control-policydrift' })[0]
    $bigIntControl = Get-CaseOperation -Status $slowStatus -OperationId $bigIntControlId
    Assert-True ($bigIntControl.lifecycle -ceq 'manual-review' -and
        @($bigIntControl.errors)[0] -ceq 'safe-delete policy 自计划生成后已漂移。') `
        '21 位整数（ConvertFrom-Json 接受为 BigInteger）必须穿过兼容层并维持 policy 漂移拒绝。'
    $v3CaseId = @($caseMap.Keys | Where-Object {
            [string]$caseMap[$_].caseName -ceq 'case-09-v3-terminal-nested-empty-name' })[0]
    $v3Operation = Get-CaseOperation -Status $fastStatus -OperationId $v3CaseId
    Assert-True ($v3Operation.lifecycle -ceq 'manual-review') `
        'issue #90: v3 quarantineTimeAnchor 嵌套缺陷时 fast scan 不得判 terminal。'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteStatusJsonEquivalence'
        cases = $caseMap.Count
        assertions = $script:assertions
    }
} finally {
    Remove-TestTree -Path $fixtureRoot
}
