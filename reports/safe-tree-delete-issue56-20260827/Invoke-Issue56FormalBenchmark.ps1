[CmdletBinding()]
param(
    [int]$FileCount = 10000,
    [int]$BytesPerFile = 4096,
    [string]$EvidenceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 §3.1/§7.3/§7.4 正式基准轮（单一判定协议）。
# 固定 schedule：baseline-pre → AC1-s1..s3 → DOP2-s1,DOP4-s1,DOP2-s2,DOP4-s2,DOP2-s3,DOP4-s3
# → baseline-post。每次 attempt：create-only attempt-started/terminal ledger（UUID/sequence/
# label 一一配对）、fresh pwsh 子进程、runtime/storage attestation、closure 前后校验。
# 判定（未取整原值）：AC1 = max(planElapsedMs)<=40000（恰好 3 个正式 attempt）；
# AC2 typical = DOP2 的 max(endToEnd) → 576238/value>=4.0；AC2 best = 候选 {DOP2,DOP4} 按
# (max,median,DOP) 升序唯一选出 → 576238/selected.max>=6.0；AC3 = 3 个 DOP2 attempt 全部
# journalOverheadPercent<10.000。退出码：0=AC1-AC3 全过；2=有效测量但有 AC 未达；
# 3=baseline/closure/样本协议无效；1=未处理执行错误。不允许排除/替换/重试正式 attempt。

$evidenceHome = if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot } else { $PSScriptRoot }
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteClosure.ps1')

$roundUtc = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$roundRoot = Join-Path $evidenceHome ('formal-round-' + $roundUtc)
$ledgerRoot = Join-Path $roundRoot 'attempts'
[void][IO.Directory]::CreateDirectory($ledgerRoot)
$baselineConstantMedianMs = 576238L

function Write-CreateOnlyJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Document)
    if ([IO.File]::Exists($Path)) { throw "attempt ledger create-only 冲突：$Path" }
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Get-AttemptClosureRow {
    $closure = Get-CodexSafeTreeDeleteClosure -ProjectRoot $projectRoot
    return [pscustomobject]@{ closureSha256 = [string]$closure.closureSha256; files = @($closure.files).Count }
}

# ---------------- 子进程 attempt 脚本 ----------------
# 场景类型：plan（仅 Plan 相位计时）、e2e（Plan+Apply+Purge，可带 DOP/回退开关）、baseline（全 PS 管线重建）。
function New-AttemptScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('plan', 'e2e', 'baseline')][string]$Kind,
        [int]$PurgeDop = 0
    )

    $body = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = 'PROJECT_ROOT'
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$scaleRoot = 'SCALE_ROOT'
$policyPath = Join-Path $scaleRoot 'policy.json'
$evidenceRoot = Join-Path $scaleRoot 'evidence'
[void][IO.Directory]::CreateDirectory($evidenceRoot)
[IO.File]::WriteAllText($policyPath, (@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(@{
        id = 'issue56-formal'
        capabilityRoot = $scaleRoot
        minimumDescendantDepth = 1
        rootDeletionPurpose = 'none'
        deniedExactPaths = @($evidenceRoot)
    })
} | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$target = Join-Path $scaleRoot 'TARGET_NAME'
$registry = Get-CodexHostSafetyNativeLoaderRegistryState
$attestation = [pscustomobject][ordered]@{
    kind = 'KIND_PLACEHOLDER'
    resolvedAlgorithm = (Get-CodexHostSafetyNativeResolvedWalkerAlgorithm)
    loadedVariant = $(if ($null -ne $registry) { [string]$registry.loadedVariant } else { $null })
    psVersion = [string]$PSVersionTable.PSVersion
    processorCount = [int][Environment]::ProcessorCount
    attemptUtc = [datetimeoffset]::UtcNow.ToString('o')
}
function Remove-Tree {
    param([string]$TreePath)
    if (-not [IO.Directory]::Exists($TreePath)) { return }
    $parent = Split-Path -Parent $TreePath
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot -Path $TreePath -CapabilityRoot $parent -AllowedExactPaths @($TreePath) -Name 'issue56 formal cleanup'
    Remove-CodexHookCapabilityDirectoryTree -Path $TreePath -CapabilityRoot $parent -AllowedExactPaths @($TreePath) -ExpectedRootIdentity @($snapshot.rootIdentity) -ExpectedTreeManifest $snapshot -Scope 'issue56 formal cleanup'
}
function New-ScaleTree {
    param([string]$TreePath, [int]$FileCountValue, [int]$BytesPerFileValue)
    if ([IO.Directory]::Exists($TreePath)) { Remove-Tree -TreePath $TreePath }
    $directoryCount = [Math]::Max(1, [int][Math]::Ceiling($FileCountValue / 100.0))
    $payload = [byte[]]::new($BytesPerFileValue)
    for ($index = 0; $index -lt $payload.Length; $index++) { $payload[$index] = [byte](($index + 17) % 251) }
    $written = 0
    for ($directoryIndex = 0; $directoryIndex -lt $directoryCount -and $written -lt $FileCountValue; $directoryIndex++) {
        $directory = Join-Path $TreePath ('d{0:D3}' -f $directoryIndex)
        [void][IO.Directory]::CreateDirectory($directory)
        $batch = [Math]::Min(100, $FileCountValue - $written)
        for ($fileIndex = 0; $fileIndex -lt $batch; $fileIndex++) {
            [IO.File]::WriteAllBytes((Join-Path $directory ('f{0:D2}.bin' -f $fileIndex)), $payload)
            $written += 1
        }
    }
    if ($written -ne $FileCountValue) { throw "tree 写出 $written" }
}
[void](New-ScaleTree -TreePath $target -FileCountValue FILECOUNT -BytesPerFileValue BYTESPERFILE)
OUTPUT_BODY
'@
    $body = $body.Replace('PROJECT_ROOT', $projectRoot)
    $body = $body.Replace('SCALE_ROOT', (Split-Path -Parent $Path))
    $body = $body.Replace('TARGET_NAME', 'attempt-tree')
    $body = $body.Replace('FILECOUNT', [string]$FileCount)
    $body = $body.Replace('BYTESPERFILE', [string]$BytesPerFile)
    $body = $body.Replace('KIND_PLACEHOLDER', $Kind)

    $outputBody = switch ($Kind) {
        'plan' {
            @'
$plan = New-CodexSafeTreeDeletePlan -TargetPath $target -CapabilityRoot $scaleRoot -PolicyPath $policyPath -EvidenceRoot $evidenceRoot
$segments = $script:CodexSafeTreeDeleteLastPlanSegments
$attestation | Add-Member -NotePropertyName result -NotePropertyValue ([pscustomobject][ordered]@{
    walkerKind = $(if ([string]$segments.walker -ceq 'csharp') { 'csharp-plan-snapshot' } else { 'powershell-three-pass' })
    planElapsedMs = [long]$plan.metrics.elapsedMs
    entriesScanned = [long]$plan.metrics.entriesScanned
    fileCount = [int]$plan.fileCount
    walker = [string]$segments.walker
    walkerTotalMs = [long]$segments.walkerTotalMs
    hashMs = [long]$segments.hashMs
    streamSetMs = [long]$segments.streamSetMs
    capturesMs = [long]$segments.capturesMs
    identityPassMs = [long]$segments.identityPassMs
    streamSetPassMs = [long]$segments.streamSetPassMs
    documentMs = [long]$segments.documentMs
    publishMs = [long]$segments.publishMs
    readbackMs = [long]$segments.readbackMs
})
Remove-Tree -TreePath $target
$attestation | ConvertTo-Json -Depth 8
'@
        }
        'e2e' {
            @'
$plan = New-CodexSafeTreeDeletePlan -TargetPath $target -CapabilityRoot $scaleRoot -PolicyPath $policyPath -EvidenceRoot $evidenceRoot
$attemptWalkerKind = $(if ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -ceq 'csharp') { 'csharp-plan-snapshot' } else { 'powershell-three-pass' })
$apply = Invoke-CodexSafeTreeDeleteQuarantine -PlanPath ([string]$plan.planPath) -ApprovedPlanSha256 ([string]$plan.planSha256) -PolicyPath $policyPath -EvidenceRoot $evidenceRoot
$purgeArguments = @{
    TransactionPath = [string]$apply.transactionPath
    ApprovedTransactionSha256 = [string]$apply.transactionSha256
    PolicyPath = $policyPath
    EvidenceRoot = $evidenceRoot
}
if (DOP_PLACEHOLDER) { $purgeArguments.PurgeMaxDegreeOfParallelismForTest = DOP_VALUE }
$purge = Invoke-CodexSafeTreeDeletePurge @purgeArguments
if (-not [bool]$purge.purged) { throw 'Purge 未成功' }
$purgeElapsedMs = [long]$purge.metrics.elapsedMs
$applyElapsedMs = [long]$apply.metrics.elapsedMs
$planElapsedMs = [long]$plan.metrics.elapsedMs
$coordinatorMs = $null
$journalOverheadPercent = $null
if ($null -ne $purge.parallelPurge -and $null -ne $purge.parallelPurge.timings) {
    $coordinatorMs = [long]$purge.parallelPurge.timings.coordinatorMs
    if ($coordinatorMs -gt 0) {
        $journalOverheadPercent = [double]$coordinatorMs * 100.0 / [double]$purgeElapsedMs
    }
}
$attestation | Add-Member -NotePropertyName result -NotePropertyValue ([pscustomobject][ordered]@{
    walkerKind = $attemptWalkerKind
    planElapsedMs = $planElapsedMs
    applyElapsedMs = $applyElapsedMs
    purgeElapsedMs = $purgeElapsedMs
    endToEndElapsedMs = $planElapsedMs + $applyElapsedMs + $purgeElapsedMs
    purgeDopRequested = $(if (DOP_PLACEHOLDER) { DOP_VALUE } else { 0 })
    parallelPurgeUsed = [bool]$purge.parallelPurge.used
    coordinatorMs = $coordinatorMs
    journalOverheadPercent = $journalOverheadPercent
})
$attestation | ConvertTo-Json -Depth 8
'@
        }
        'baseline' {
            @'
$plan = New-CodexSafeTreeDeletePlan -TargetPath $target -CapabilityRoot $scaleRoot -PolicyPath $policyPath -EvidenceRoot $evidenceRoot -DisablePlanCSharpWalkerForTest
$attemptWalkerKind = $(if ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -ceq 'csharp') { 'csharp-plan-snapshot' } else { 'powershell-three-pass' })
$apply = Invoke-CodexSafeTreeDeleteQuarantine -PlanPath ([string]$plan.planPath) -ApprovedPlanSha256 ([string]$plan.planSha256) -PolicyPath $policyPath -EvidenceRoot $evidenceRoot -DisableApplyHashReuseForTest
$purge = Invoke-CodexSafeTreeDeletePurge -TransactionPath ([string]$apply.transactionPath) -ApprovedTransactionSha256 ([string]$apply.transactionSha256) -PolicyPath $policyPath -EvidenceRoot $evidenceRoot -DisablePurgeHashReuseForTest
if (-not [bool]$purge.purged) { throw 'baseline Purge 未成功' }
$attestation | Add-Member -NotePropertyName result -NotePropertyValue ([pscustomobject][ordered]@{
    walkerKind = $attemptWalkerKind
    planElapsedMs = [long]$plan.metrics.elapsedMs
    applyElapsedMs = [long]$apply.metrics.elapsedMs
    purgeElapsedMs = [long]$purge.metrics.elapsedMs
    endToEndElapsedMs = [long]$plan.metrics.elapsedMs + [long]$apply.metrics.elapsedMs + [long]$purge.metrics.elapsedMs
    baselineMode = $true
})
$attestation | ConvertTo-Json -Depth 8
'@
        }
    }
    $body = $body.Replace('OUTPUT_BODY', $outputBody)
    if ($Kind -ceq 'e2e') {
        $body = $body.Replace('DOP_PLACEHOLDER', '$false')
        if ($PurgeDop -ge 1) {
            $body = $body.Replace('$false) { $purgeArguments.PurgeMaxDegreeOfParallelismForTest = DOP_VALUE }', ('$true) { $purgeArguments.PurgeMaxDegreeOfParallelismForTest = ' + $PurgeDop + ' }'))
            $body = $body.Replace('$(if ($false) { DOP_VALUE } else { 0 })', ([string]$PurgeDop))
        } else {
            $body = $body.Replace('DOP_VALUE', '2')
        }
    }
    [IO.File]::WriteAllText($Path, $body, [Text.UTF8Encoding]::new($false))
    return $Path
}

# ---------------- schedule 执行 ----------------
$schedule = @(
    @{ label = 'baseline-pre'; kind = 'baseline'; dop = 0; gapSeconds = 120 },
    @{ label = 'ac1-s1'; kind = 'plan'; dop = 0; gapSeconds = 60 },
    @{ label = 'ac1-s2'; kind = 'plan'; dop = 0; gapSeconds = 60 },
    @{ label = 'ac1-s3'; kind = 'plan'; dop = 0; gapSeconds = 60 },
    @{ label = 'dop2-s1'; kind = 'e2e'; dop = 0; gapSeconds = 60 },
    @{ label = 'dop4-s1'; kind = 'e2e'; dop = 4; gapSeconds = 60 },
    @{ label = 'dop2-s2'; kind = 'e2e'; dop = 0; gapSeconds = 60 },
    @{ label = 'dop4-s2'; kind = 'e2e'; dop = 4; gapSeconds = 60 },
    @{ label = 'dop2-s3'; kind = 'e2e'; dop = 0; gapSeconds = 60 },
    @{ label = 'dop4-s3'; kind = 'e2e'; dop = 4; gapSeconds = 60 },
    @{ label = 'baseline-post'; kind = 'baseline'; dop = 0; gapSeconds = 0 }
)

$closureBefore = Get-AttemptClosureRow
$attemptRows = [Collections.Generic.List[object]]::new()
$sequence = 0
$protocolValid = $true
$protocolInvalidReasons = [Collections.Generic.List[string]]::new()

# warm-up：仅生成/加载 DLL，不计时、不入 ledger。
$warmScript = Join-Path $roundRoot 'warm.ps1'
$warmBody = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path 'PROJECT_ROOT' 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path 'PROJECT_ROOT' 'scripts\lib\CodexSafeTreeDelete.ps1')
'@.Replace('PROJECT_ROOT', $projectRoot)
[IO.File]::WriteAllText($warmScript, $warmBody, [Text.UTF8Encoding]::new($false))
$warmProcess = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $warmScript) -PassThru -WindowStyle Hidden -Wait
if ($warmProcess.ExitCode -ne 0) { throw 'warm-up 子进程失败。' }
[void][IO.File]::Delete($warmScript)

foreach ($item in $schedule) {
    $sequence++
    $label = [string]$item.label
    $attemptUuid = [guid]::NewGuid().ToString('N')
    $attemptDir = Join-Path $ledgerRoot ('{0:D2}-{1}' -f $sequence, $label)
    [void][IO.Directory]::CreateDirectory($attemptDir)
    $closurePre = Get-AttemptClosureRow
    if ([string]$closurePre.closureSha256 -cne [string]$closureBefore.closureSha256) {
        $protocolValid = $false
        $protocolInvalidReasons.Add(('closure 漂移 before attempt {0}' -f $label))
    }

    $scriptPath = Join-Path $attemptDir 'attempt.ps1'
    [void](New-AttemptScript -Path $scriptPath -Kind ([string]$item.kind) -PurgeDop ([int]$item.dop))
    $startedPath = Join-Path $attemptDir 'attempt-started.json'
    Write-CreateOnlyJson -Path $startedPath -Document ([pscustomobject][ordered]@{
        schemaVersion = 1
        sequence = $sequence
        label = $label
        attemptUuid = $attemptUuid
        utc = [datetimeoffset]::UtcNow.ToString('o')
        closureSha256 = [string]$closurePre.closureSha256
        kind = [string]$item.kind
        purgeDop = [int]$item.dop
    })

    $stdoutPath = Join-Path $attemptDir 'stdout.json'
    $stderrPath = Join-Path $attemptDir 'stderr.txt'
    $process = Start-Process -FilePath 'pwsh' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $scriptPath) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait
    $exitCode = [int]$process.ExitCode

    $terminalPath = Join-Path $attemptDir 'attempt-terminal.json'
    Write-CreateOnlyJson -Path $terminalPath -Document ([pscustomobject][ordered]@{
        schemaVersion = 1
        sequence = $sequence
        label = $label
        attemptUuid = $attemptUuid
        utc = [datetimeoffset]::UtcNow.ToString('o')
        exitCode = $exitCode
    })

    $result = $null
    $walkerKind = $null
    if ($exitCode -eq 0 -and [IO.File]::Exists($stdoutPath)) {
        $stdoutText = ([IO.File]::ReadAllText($stdoutPath, [Text.UTF8Encoding]::new($false))).Trim()
        if ($stdoutText.Length -gt 0) {
            try { $parsed = $stdoutText | ConvertFrom-Json -Depth 12 } catch { $parsed = $null }
            if ($null -ne $parsed) {
                $result = $parsed.result
                $walkerKind = [string]$result.walkerKind
            }
        }
    }
    $invalid = $false
    if ($exitCode -ne 0 -or $null -eq $result) {
        $invalid = $true
        $protocolInvalidReasons.Add(('attempt {0} 无有效输出（exit={1}）' -f $label, $exitCode))
    }
    if ($item.kind -ceq 'baseline' -and $walkerKind -cne 'powershell-three-pass') {
        $invalid = $true
        $protocolInvalidReasons.Add(('baseline {0} walkerKind={1} 非法' -f $label, $walkerKind))
    }
    if ($item.kind -ceq 'plan' -and $walkerKind -cne 'csharp-plan-snapshot') {
        $invalid = $true
        $protocolInvalidReasons.Add(('plan attempt {0} walkerKind={1} 非法' -f $label, $walkerKind))
    }
    if ($invalid) { $protocolValid = $false }

    $attemptRows.Add([pscustomobject][ordered]@{
        sequence = $sequence
        label = $label
        kind = [string]$item.kind
        purgeDop = [int]$item.dop
        attemptUuid = $attemptUuid
        exitCode = $exitCode
        walkerKind = $walkerKind
        result = $result
        stderr = $(if ([IO.File]::Exists($stderrPath)) { ([IO.File]::ReadAllText($stderrPath)).Trim() } else { '' })
    })
    $hasPlan = $null -ne $result -and $null -ne ($result.PSObject.Properties['planElapsedMs'])
    $hasTotal = $null -ne $result -and $null -ne ($result.PSObject.Properties['endToEndElapsedMs'])
    Write-Output ("ATTEMPT {0} exit={1} walker={2} plan={3} total={4}" -f @(
        $label, $exitCode, [string]$walkerKind,
        $(if ($hasPlan) { [long]$result.planElapsedMs } else { -1 }),
        $(if ($hasTotal) { [long]$result.endToEndElapsedMs } else { -1 })))
    if (-not $protocolValid) { break }
    if ([int]$item.gapSeconds -gt 0) { Start-Sleep -Seconds ([int]$item.gapSeconds) }
}

$closureAfter = Get-AttemptClosureRow
if ([string]$closureAfter.closureSha256 -cne [string]$closureBefore.closureSha256) {
    $protocolValid = $false
    $protocolInvalidReasons.Add('closure 漂移 after schedule')
}

# ---------------- 评估（G4：BENCH_PASS/BENCH_FAIL/BENCH_INVALID）----------------
$evaluation = [pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue56-formal-round'
    roundUtc = $roundUtc
    baselineConstantMedianMs = $baselineConstantMedianMs
    closureBefore = [string]$closureBefore.closureSha256
    closureAfter = [string]$closureAfter.closureSha256
    protocolValid = $protocolValid
    protocolInvalidReasons = @($protocolInvalidReasons)
    fileCount = $FileCount
    bytesPerFile = $BytesPerFile
    psVersion = [string]$PSVersionTable.PSVersion
    processorCount = [int][Environment]::ProcessorCount
    attempts = @($attemptRows)
}
$exitCodeFinal = 1

if (-not $protocolValid) {
    $evaluation | Add-Member -NotePropertyName verdict -NotePropertyValue 'BENCH_INVALID'
    $evaluation | Add-Member -NotePropertyName acResults -NotePropertyValue $null
    $exitCodeFinal = 3
} else {
    $baselinePre = @($attemptRows | Where-Object { $_.label -ceq 'baseline-pre' })[0]
    $baselinePost = @($attemptRows | Where-Object { $_.label -ceq 'baseline-post' })[0]
    $baselineOk = $true
    foreach ($baselineRow in @($baselinePre, $baselinePost)) {
        $elapsed = [long]$baselineRow.result.endToEndElapsedMs
        if ($elapsed -gt [long]($baselineConstantMedianMs * 1.10) -or
            $elapsed -lt [long]($baselineConstantMedianMs * 0.90)) {
            $baselineOk = $false
            $protocolInvalidReasons.Add(('baseline {0}={1}ms 超出 ±10%（仅环境 sanity，不换分母）' -f $baselineRow.label, $elapsed))
        }
    }

    $planAttempts = @($attemptRows | Where-Object { $_.kind -ceq 'plan' })
    $ac1Max = [long](($planAttempts | ForEach-Object { [long]$_.result.planElapsedMs }) | Measure-Object -Maximum).Maximum
    $ac1Pass = ($planAttempts.Count -eq 3) -and ($ac1Max -le 40000L)

    $dop2 = @($attemptRows | Where-Object { $_.kind -ceq 'e2e' -and $_.purgeDop -eq 0 })
    $dop4 = @($attemptRows | Where-Object { $_.kind -ceq 'e2e' -and $_.purgeDop -eq 4 })
    $dop2Values = @($dop2 | ForEach-Object { [long]$_.result.endToEndElapsedMs })
    $dop4Values = @($dop4 | ForEach-Object { [long]$_.result.endToEndElapsedMs })
    $dop2Max = [long]($dop2Values | Measure-Object -Maximum).Maximum
    $dop2Median = [long](($dop2Values | Sort-Object)[[int][Math]::Floor(($dop2Values.Count - 1) / 2.0)])
    $dop4Max = [long]($dop4Values | Measure-Object -Maximum).Maximum
    $dop4Median = [long](($dop4Values | Sort-Object)[[int][Math]::Floor(($dop4Values.Count - 1) / 2.0)])
    # best 候选 {DOP2, DOP4}：按 (max, median, DOP) 升序唯一选出。
    $candidates = @(
        [pscustomobject]@{ dop = 2; max = $dop2Max; median = $dop2Median },
        [pscustomobject]@{ dop = 4; max = $dop4Max; median = $dop4Median }
    ) | Sort-Object max, median, dop
    $best = $candidates[0]
    $typicalSpeedup = [double]$baselineConstantMedianMs / [double]$dop2Max
    $bestSpeedup = [double]$baselineConstantMedianMs / [double]$best.max
    $ac2TypicalPass = ($dop2.Count -eq 3) -and ($typicalSpeedup -ge 4.0)
    $ac2BestPass = ($bestSpeedup -ge 6.0)

    $ac3Values = @($dop2 | ForEach-Object { [double]$_.result.journalOverheadPercent })
    $ac3Pass = ($ac3Values.Count -eq 3) -and (@($ac3Values | Where-Object { $_ -ge 10.0 }).Count -eq 0)

    if (-not $baselineOk) {
        $evaluation | Add-Member -NotePropertyName verdict -NotePropertyValue 'BENCH_INVALID'
        $evaluation | Add-Member -NotePropertyName acResults -NotePropertyValue $null
        $evaluation.protocolValid = $false
        $evaluation.protocolInvalidReasons = @($protocolInvalidReasons)
        $exitCodeFinal = 3
    } else {
        $allPass = $ac1Pass -and $ac2TypicalPass -and $ac2BestPass -and $ac3Pass
        $evaluation | Add-Member -NotePropertyName verdict -NotePropertyValue (
            $(if ($allPass) { 'BENCH_PASS' } else { 'BENCH_FAIL' }))
        $evaluation | Add-Member -NotePropertyName acResults -NotePropertyValue ([pscustomobject][ordered]@{
            ac1 = [pscustomobject]@{ attempts = 3; maxPlanElapsedMs = $ac1Max; pass = $ac1Pass; thresholdMs = 40000L }
            ac2Typical = [pscustomobject]@{ dop = 2; maxEndToEndMs = $dop2Max; speedup = [Math]::Round($typicalSpeedup, 4); pass = $ac2TypicalPass; threshold = 4.0 }
            ac2Best = [pscustomobject]@{ selectedDop = [int]$best.dop; maxEndToEndMs = [long]$best.max; speedup = [Math]::Round($bestSpeedup, 4); pass = $ac2BestPass; threshold = 6.0; candidates = @($candidates) }
            ac3 = [pscustomobject]@{ journalOverheadPercents = @($ac3Values | ForEach-Object { [Math]::Round($_, 4) }); pass = $ac3Pass; threshold = 10.0 }
        })
        $exitCodeFinal = $(if ($allPass) { 0 } else { 2 })
    }
}

Write-CreateOnlyJson -Path (Join-Path $roundRoot 'evaluation.json') -Document $evaluation
Write-Output ("VERDICT {0} EXIT={1}" -f $evaluation.verdict, $exitCodeFinal)
exit $exitCodeFinal
