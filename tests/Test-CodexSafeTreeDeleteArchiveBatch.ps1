[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #85，spec #73「Archive 一次归档多组 terminal 记录」):
# 唯一接缝：fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 Archive mode，进程内调用与
# pwsh -File 子进程两种形态。只观察结果 JSON、退出码、异常消息与 evidence operation run 的前后状态。
# 本套件不读写生产 evidence 根，也不执行生产入口。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$fixtureRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'archivebatch'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$targetsRoot = Join-Path $fixtureRoot 'targets'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$shaMismatchMessage = 'safe-delete archive approved transaction SHA-256 不匹配。'
# 改动前（c22e7e0）单组 Archive 返回对象与 terminal-archive.json 的字段顺序。
$singleArchivedFields = 'archived|alreadyArchived|archivePath|archiveSha256|archivedAtUtc|metrics'
$singleRefusalFields = 'archived|alreadyArchived|refusalReason|metrics'
$markerFields = 'artifactType|schemaVersion|generationId|planPath|planSha256|planIdentity|' +
    'transactionPath|transactionSha256|transactionIdentity|transactionSchemaVersion|transactionStatus|' +
    'transactionUpdatedAtUtc|targetPath|quarantinePath|quarantineAbsent|restoreJournalAnchorCount|archivedAtUtc'
$batchFields = 'completed|transactionCount|archivedCount|alreadyArchivedCount|refusedCount|failedCount|results'

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
        -Name 'safe-delete archive batch test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete archive batch test cleanup'
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ArchiveRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        # 只 Plan → Apply，留下 quarantined（非 terminal）记录。
        [switch]$QuarantinedOnly
    )

    $target = Join-Path $targetsRoot $Name
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'payload.txt'), "archive-batch-$Name", $utf8)
    $plan = & $entryPath `
        -Mode Plan `
        -TargetPath $target `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($apply.quarantined -eq $true) "$Name 夹具 Apply 必须成功"
    $transactionPath = [string]$apply.transactionPath
    if (-not $QuarantinedOnly) {
        $purge = & $entryPath `
            -Mode Purge `
            -TransactionPath $transactionPath `
            -ApprovedTransactionSha256 ([string]$apply.transactionSha256) `
            -ConfirmPurge `
            -FixturePolicyPath $policyPath `
            -FixtureEvidenceRoot $evidenceRoot
        Assert-True ($purge.purged -eq $true) "$Name 夹具 Purge 必须成功"
    }
    $runDirectory = Split-Path -Parent $transactionPath
    return [pscustomobject][ordered]@{
        name = $Name
        transactionPath = $transactionPath
        runDirectory = $runDirectory
        operationId = Split-Path -Leaf $runDirectory
        markerPath = Join-Path $runDirectory 'terminal-archive.json'
        # 当前 transaction 的 SHA-256：调用方现场批准的值。
        approvedSha256 = Get-FileSha256 -Path $transactionPath
        # Apply 时的 transaction SHA-256：Purge 改写 transaction 后即成为过期批准。
        applySha256 = [string]$apply.transactionSha256
    }
}

function Get-RunState {
    param([Parameter(Mandatory)][string]$RunDirectory)

    # operation run 内每个文件的相对路径、SHA-256 与 file identity，用于证明零写入。
    $rows = foreach ($file in @(Get-ChildItem -LiteralPath $RunDirectory -File -Force -Recurse |
            Sort-Object -Property FullName)) {
        $snapshot = Get-CodexHookCapabilityFileSnapshot `
            -Path $file.FullName `
            -CapabilityRoot $RunDirectory `
            -AllowedExactPaths @($file.FullName) `
            -Name 'safe-delete archive batch run state'
        '{0}|{1}|{2}' -f [IO.Path]::GetRelativePath($RunDirectory, $file.FullName),
            [string]$snapshot.sha256, (@($snapshot.identity) -join ',')
    }
    return (@($rows) -join "`n")
}

function Invoke-ArchiveBatch {
    param(
        [Parameter(Mandatory)][string[]]$TransactionPaths,
        [Parameter(Mandatory)][string[]]$ApprovedTransactionSha256s
    )

    return & $entryPath `
        -Mode Archive `
        -TransactionPaths $TransactionPaths `
        -ApprovedTransactionSha256s $ApprovedTransactionSha256s `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
}

function Invoke-FixtureEntryProcess {
    param([Parameter(Mandatory)][string[]]$Arguments)

    # 宿主 .cmd → gate shim 链以 pwsh -File 传参，每个参数都是单个字符串。stdout 按 Latin1 逐字节
    # 解码，不依赖子进程控制台代码页；调用方只断言 ASCII 内容。
    $start = [Diagnostics.ProcessStartInfo]::new([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::Latin1
    $start.StandardErrorEncoding = [Text.Encoding]::Latin1
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $entryPath) + $Arguments +
            @('-FixturePolicyPath', $policyPath, '-FixtureEvidenceRoot', $evidenceRoot)) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-True ($process.WaitForExit(120000)) 'fixture 入口子进程必须在 120 秒内退出'
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(1000)
        }
        $process.Dispose()
    }
}

function Get-MarkerShape {
    param([Parameter(Mandatory)][object]$Record)

    # 把本记录特有的取值换成占位符，留下字段顺序、取值类型与序列化格式（BOM、换行、缩进）。
    $text = $utf8.GetString([IO.File]::ReadAllBytes($Record.markerPath))
    $document = $text | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    # run 目录名形如 <时间戳>-<generationId>，必须先于 generationId 替换。
    $replacements = [ordered]@{ $Record.operationId = '<run>' }
    foreach ($value in @($document.planIdentity) + @($document.transactionIdentity)) {
        $replacements[('"{0}"' -f [string]$value)] = '"<identity>"'
    }
    foreach ($name in @('planSha256', 'transactionSha256', 'transactionUpdatedAtUtc', 'archivedAtUtc')) {
        $replacements[('"{0}"' -f [string]$document.$name)] = ('"<{0}>"' -f $name)
    }
    $replacements[[string]$document.generationId] = '<generation>'
    $replacements[('\\{0}"' -f $Record.name)] = '\\<target>"'
    foreach ($key in $replacements.Keys) {
        $text = $text.Replace([string]$key, [string]$replacements[$key])
    }
    return $text
}

function Get-FirstLineDifference {
    param([AllowEmptyString()][string]$Expected, [AllowEmptyString()][string]$Actual)

    $expectedLines = $Expected -split "`n"
    $actualLines = $Actual -split "`n"
    for ($index = 0; $index -lt [Math]::Max($expectedLines.Count, $actualLines.Count); $index++) {
        $left = if ($index -lt $expectedLines.Count) { $expectedLines[$index] } else { '<missing>' }
        $right = if ($index -lt $actualLines.Count) { $actualLines[$index] } else { '<missing>' }
        if ($left -cne $right) { return "line $($index + 1): expected [$left] actual [$right]" }
    }
    return 'no difference'
}

function Get-StatusOperation {
    param([Parameter(Mandatory)][object]$Status, [Parameter(Mandatory)][object]$Record)

    $found = @($Status.operations | Where-Object operationId -ceq $Record.operationId)
    Assert-True ($found.Count -eq 1) "Status 必须恰好列出 operation $($Record.operationId)"
    return $found[0]
}

function Assert-ArchivedRow {
    param([Parameter(Mandatory)][object]$Row, [Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Label)

    Assert-True ([string]$Row.transactionPath -ceq $Record.transactionPath) "$Label 结果行必须回显本组 transaction path"
    Assert-True ($Row.archived -eq $true -and $Row.alreadyArchived -eq $false) "$Label 必须新归档"
    Assert-True ([string]$Row.archivePath -ceq $Record.markerPath -and [IO.File]::Exists($Record.markerPath)) `
        "$Label 必须在本组 operation run 内发布 terminal-archive.json"
    Assert-True ([string]$Row.archiveSha256 -ceq (Get-FileSha256 -Path $Record.markerPath)) `
        "$Label 结果行的 archiveSha256 必须等于 marker 实际 SHA-256"
}

function Assert-FailedRowWithoutMarker {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$RunStateBefore,
        [Parameter(Mandatory)][string]$ExpectedError,
        [Parameter(Mandatory)][string]$Label
    )

    Assert-True ([string]$Row.transactionPath -ceq $Record.transactionPath) "$Label 结果行必须回显本组 transaction path"
    Assert-True ($Row.archived -eq $false -and $Row.alreadyArchived -eq $false) "$Label 不得归档"
    Assert-True ([string]$Row.refusalReason -ceq 'archive-operation-failed') `
        "$Label 抛错必须收敛为稳定原因 archive-operation-failed，实际 $($Row.refusalReason)"
    Assert-True ([string]$Row.error -ceq $ExpectedError) "$Label 必须保留单组调用的异常消息，实际 $($Row.error)"
    Assert-True (-not [IO.File]::Exists($Record.markerPath)) "$Label 失败的组不得产生 terminal-archive.json"
    Assert-True ((Get-RunState -RunDirectory $Record.runDirectory) -ceq $RunStateBefore) `
        "$Label 失败的组必须保持 operation run 零写入"
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [void][IO.Directory]::CreateDirectory($targetsRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'archive-batch'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 10), $utf8)

    # 1. 请求级校验先于任何一组：单组与多组参数混用、只给一半、'::' 拆分后组数不等、含空白组或拆分后
    #    为空，一律整体抛错；请求里的有效组也不归档，evidence 零写入。
    $pending = New-ArchiveRecord -Name 'request-pending'
    $evidenceBefore = Get-RunState -RunDirectory $evidenceRoot
    $pairMessage = 'Archive 多组模式要求 TransactionPaths 与 ApprovedTransactionSha256s 一一对应且均不为空。'
    $invalidRequests = @(
        @{
            label = '单组与多组参数混用'
            message = 'Archive 不能同时使用单组参数（TransactionPath / ApprovedTransactionSha256）' +
                '与多组参数（TransactionPaths / ApprovedTransactionSha256s）。'
            arguments = @{
                TransactionPath = $pending.transactionPath
                ApprovedTransactionSha256 = $pending.approvedSha256
                TransactionPaths = @($pending.transactionPath)
                ApprovedTransactionSha256s = @($pending.approvedSha256)
            }
        },
        @{
            label = '只给 TransactionPaths'
            message = $pairMessage
            arguments = @{ TransactionPaths = @($pending.transactionPath) }
        },
        @{
            label = '只给 ApprovedTransactionSha256s'
            message = $pairMessage
            arguments = @{ ApprovedTransactionSha256s = @($pending.approvedSha256) }
        },
        @{
            label = "'::' 拆分后组数不等"
            message = $pairMessage
            arguments = @{
                TransactionPaths = @("$($pending.transactionPath)::$($pending.transactionPath)")
                ApprovedTransactionSha256s = @($pending.approvedSha256)
            }
        },
        @{
            label = '含空白组'
            message = $pairMessage
            arguments = @{
                TransactionPaths = @($pending.transactionPath, ' ')
                ApprovedTransactionSha256s = @($pending.approvedSha256, $pending.approvedSha256)
            }
        },
        @{
            label = "'::' 拆分后为空"
            message = $pairMessage
            arguments = @{ TransactionPaths = @('::'); ApprovedTransactionSha256s = @('::') }
        }
    )
    foreach ($request in $invalidRequests) {
        $requestArguments = $request.arguments
        $requestError = $null
        try {
            [void](& $entryPath `
                -Mode Archive `
                -ConfirmArchive `
                -FixturePolicyPath $policyPath `
                -FixtureEvidenceRoot $evidenceRoot `
                @requestArguments)
        } catch {
            $requestError = $_.Exception.Message
        }
        Assert-True ($requestError -ceq $request.message) "$($request.label) 必须在处理任何一组之前整体拒绝，实际：$requestError"
        Assert-True ((Get-RunState -RunDirectory $evidenceRoot) -ceq $evidenceBefore) "$($request.label) 不得写入 evidence"
    }

    # 未确认时与单组相同：稳定结构化拒绝、零写入。
    $unconfirmed = & $entryPath `
        -Mode Archive `
        -TransactionPaths @($pending.transactionPath) `
        -ApprovedTransactionSha256s @($pending.approvedSha256) `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True (($unconfirmed | ConvertTo-Json -Compress) -ceq '{"archived":false,"refusalReason":"confirm-archive-required"}') `
        "多组参数缺少 -ConfirmArchive 必须返回 confirm-archive-required，实际：$($unconfirmed | ConvertTo-Json -Compress)"
    Assert-True ((Get-RunState -RunDirectory $evidenceRoot) -ceq $evidenceBefore) '多组确认拒绝必须零写入'

    # 同一记录换成合法请求即可归档；多组参数即使只有一组，也返回多组结果形状。
    $oneGroup = Invoke-ArchiveBatch `
        -TransactionPaths @($pending.transactionPath) `
        -ApprovedTransactionSha256s @($pending.approvedSha256)
    Assert-True ((@($oneGroup.PSObject.Properties.Name) -join '|') -ceq $batchFields -and
        $oneGroup.completed -eq $true -and
        $oneGroup.transactionCount -eq 1 -and
        @($oneGroup.results).Count -eq 1) `
        "只有一组的多组调用必须返回多组结果形状：$($oneGroup | ConvertTo-Json -Depth 8 -Compress)"
    Assert-ArchivedRow -Row $oneGroup.results[0] -Record $pending -Label '只有一组的多组调用'

    # 2. 混合批次：有效 / 过期 SHA / 有效。过期 SHA 的组单独失败、零写入，前后两组照常归档。
    $mixedFirst = New-ArchiveRecord -Name 'mixed-first'
    $mixedStale = New-ArchiveRecord -Name 'mixed-stale'
    $mixedLast = New-ArchiveRecord -Name 'mixed-last'
    Assert-True ($mixedStale.applySha256 -cne $mixedStale.approvedSha256) 'Purge 必须改写 transaction，使 Apply 时的 SHA 过期'
    $mixedStaleBefore = Get-RunState -RunDirectory $mixedStale.runDirectory
    $mixed = Invoke-ArchiveBatch `
        -TransactionPaths @($mixedFirst.transactionPath, $mixedStale.transactionPath, $mixedLast.transactionPath) `
        -ApprovedTransactionSha256s @($mixedFirst.approvedSha256, $mixedStale.applySha256, $mixedLast.approvedSha256)
    Assert-True (@($mixed.results).Count -eq 3) '多组结果必须按输入逐组各占一行'
    Assert-ArchivedRow -Row $mixed.results[0] -Record $mixedFirst -Label '混合批次第 1 组（有效）'
    Assert-FailedRowWithoutMarker `
        -Row $mixed.results[1] `
        -Record $mixedStale `
        -RunStateBefore $mixedStaleBefore `
        -ExpectedError $shaMismatchMessage `
        -Label '混合批次第 2 组（过期 SHA）'
    Assert-ArchivedRow -Row $mixed.results[2] -Record $mixedLast -Label '混合批次第 3 组（有效，位于失败组之后）'
    Assert-True ($mixed.completed -eq $false -and
        $mixed.transactionCount -eq 3 -and
        $mixed.archivedCount -eq 2 -and
        $mixed.alreadyArchivedCount -eq 0 -and
        $mixed.refusedCount -eq 0 -and
        $mixed.failedCount -eq 1) `
        "混合批次的汇总计数必须与逐组结果一致：$($mixed | Select-Object -Property * -ExcludeProperty results | ConvertTo-Json -Compress)"

    # 3. 多组全部成功，经 pwsh -File 子进程：宿主链只能传单个字符串，多组 path 与 SHA 各以 '::' 连接。
    $allRecords = @(
        (New-ArchiveRecord -Name 'all-a'),
        (New-ArchiveRecord -Name 'all-b'),
        (New-ArchiveRecord -Name 'all-c'))
    $allProcess = Invoke-FixtureEntryProcess -Arguments @(
        '-Mode', 'Archive',
        '-TransactionPaths', (@($allRecords | ForEach-Object { $_.transactionPath }) -join '::'),
        '-ApprovedTransactionSha256s', (@($allRecords | ForEach-Object { $_.approvedSha256 }) -join '::'),
        '-ConfirmArchive',
        '-Json')
    Assert-True ($allProcess.exitCode -eq 0) "多组全部成功的 JSON 调用必须 exit 0，实际 $($allProcess.exitCode)：$($allProcess.stderr)"
    $all = $allProcess.stdout | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-True ((@($all.PSObject.Properties.Name) -join '|') -ceq $batchFields) `
        "多组结果的顶层字段必须稳定且没有顶层 refusalReason：$(@($all.PSObject.Properties.Name) -join '|')"
    Assert-True ($all.completed -eq $true -and
        $all.transactionCount -eq 3 -and
        $all.archivedCount -eq 3 -and
        $all.alreadyArchivedCount -eq 0 -and
        $all.refusedCount -eq 0 -and
        $all.failedCount -eq 0 -and
        @($all.results).Count -eq 3) `
        "多组全部成功必须 completed=true 且计数一致：$($allProcess.stdout)"
    for ($index = 0; $index -lt $allRecords.Count; $index++) {
        $row = $all.results[$index]
        $record = $allRecords[$index]
        Assert-True ((@($row.PSObject.Properties.Name) -join '|') -ceq "transactionPath|$singleArchivedFields") `
            "全部成功第 $($index + 1) 组的结果行必须是 transactionPath 加单组返回字段：$(@($row.PSObject.Properties.Name) -join '|')"
        Assert-True ([string]$row.transactionPath -clike "*\$($record.operationId)\transaction.json" -and
            $row.archived -eq $true -and
            $row.alreadyArchived -eq $false -and
            [string]$row.archiveSha256 -ceq (Get-FileSha256 -Path $record.markerPath)) `
            "全部成功第 $($index + 1) 组必须按输入顺序新归档"
        Assert-True ($row.metrics.schemaVersion -eq 1 -and [string]$row.metrics.phase -ceq 'archive') `
            "全部成功第 $($index + 1) 组必须带单组的 archive metrics"
    }

    # terminal-archive 格式不变：多组写出的 marker 与单组写出的 marker 除各记录自身取值外逐字节相同，
    # 且都能被 Status 认证为已归档 terminal。
    $singleShapeRecord = New-ArchiveRecord -Name 'shape-single'
    $singleShapeArchive = & $entryPath `
        -Mode Archive `
        -TransactionPath $singleShapeRecord.transactionPath `
        -ApprovedTransactionSha256 $singleShapeRecord.approvedSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ((@($singleShapeArchive.PSObject.Properties.Name) -join '|') -ceq $singleArchivedFields -and
        $singleShapeArchive.archived -eq $true) `
        "单组参照记录必须归档成功且返回改动前的单组字段：$(@($singleShapeArchive.PSObject.Properties.Name) -join '|')"
    $singleShape = Get-MarkerShape -Record $singleShapeRecord
    $singleMarker = [IO.File]::ReadAllText($singleShapeRecord.markerPath) |
        ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-True ((@($singleMarker.PSObject.Properties.Name) -join '|') -ceq $markerFields) `
        "单组 terminal-archive.json 字段顺序必须与改动前一致：$(@($singleMarker.PSObject.Properties.Name) -join '|')"
    foreach ($record in $allRecords + @($mixedFirst, $mixedLast)) {
        $batchShape = Get-MarkerShape -Record $record
        Assert-True ($batchShape -ceq $singleShape) (
            "多组写出的 $($record.name) terminal-archive.json 必须与单组格式逐字节一致：" +
            (Get-FirstLineDifference -Expected $singleShape -Actual $batchShape))
    }
    $statusAfterBatches = & $entryPath `
        -Mode Status `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    foreach ($record in $allRecords + @($mixedFirst, $mixedLast)) {
        $operation = Get-StatusOperation -Status $statusAfterBatches -Record $record
        Assert-True ($operation.lifecycle -ceq 'terminal' -and $operation.journalStatus -ceq 'archived') `
            "Status 必须认证多组写出的 $($record.name) marker 为已归档 terminal"
    }
    Assert-True ((Get-StatusOperation -Status $statusAfterBatches -Record $mixedStale).journalStatus -cne 'archived') `
        'Status 不得把失败组 mixed-stale 当作已归档'

    # 多组归档后的记录再走单组调用：照常认证并报告 alreadyArchived，marker 字节与 identity 不变。
    $replayRecord = $allRecords[1]
    $replayBefore = Get-RunState -RunDirectory $replayRecord.runDirectory
    $replay = & $entryPath `
        -Mode Archive `
        -TransactionPath $replayRecord.transactionPath `
        -ApprovedTransactionSha256 $replayRecord.approvedSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ((@($replay.PSObject.Properties.Name) -join '|') -ceq $singleArchivedFields -and
        $replay.archived -eq $true -and
        $replay.alreadyArchived -eq $true -and
        [string]$replay.archivePath -ceq $replayRecord.markerPath) `
        '多组归档的记录再单组 Archive 必须报告 alreadyArchived'
    Assert-True ((Get-RunState -RunDirectory $replayRecord.runDirectory) -ceq $replayBefore) `
        '单组重放不得改动多组写出的 marker 或其他 evidence'

    # 4. 成功与各类失败混合：非 terminal（结构化拒绝）、已归档、evidence run 之外的路径、SHA 格式非法、
    #    同一组重复出现。每组结果相互独立，失败的组不产生归档，也不改动 evidence。
    $quarantined = New-ArchiveRecord -Name 'mixed-quarantined' -QuarantinedOnly
    $badFormat = New-ArchiveRecord -Name 'mixed-bad-format'
    $fresh = New-ArchiveRecord -Name 'mixed-fresh'
    $outsideDirectory = Join-Path $targetsRoot 'outside-evidence'
    $outsideTransactionPath = Join-Path $outsideDirectory 'transaction.json'
    [void][IO.Directory]::CreateDirectory($outsideDirectory)
    [IO.File]::Copy($fresh.transactionPath, $outsideTransactionPath)
    $alreadyArchived = $allRecords[0]
    $quarantinedBefore = Get-RunState -RunDirectory $quarantined.runDirectory
    $badFormatBefore = Get-RunState -RunDirectory $badFormat.runDirectory
    $alreadyArchivedBefore = Get-RunState -RunDirectory $alreadyArchived.runDirectory
    $outsideBefore = Get-RunState -RunDirectory $outsideDirectory
    $varied = Invoke-ArchiveBatch `
        -TransactionPaths @(
            $quarantined.transactionPath,
            $alreadyArchived.transactionPath,
            $outsideTransactionPath,
            $badFormat.transactionPath,
            $fresh.transactionPath,
            $fresh.transactionPath) `
        -ApprovedTransactionSha256s @(
            $quarantined.approvedSha256,
            $alreadyArchived.approvedSha256,
            $fresh.approvedSha256,
            'not-a-sha256',
            $fresh.approvedSha256,
            $fresh.approvedSha256)
    Assert-True (@($varied.results).Count -eq 6) '混合失败批次必须逐组各占一行'
    $refusedRow = $varied.results[0]
    Assert-True ((@($refusedRow.PSObject.Properties.Name) -join '|') -ceq "transactionPath|$singleRefusalFields" -and
        [string]$refusedRow.transactionPath -ceq $quarantined.transactionPath -and
        $refusedRow.archived -eq $false -and
        [string]$refusedRow.refusalReason -ceq 'transaction-status-not-purged') `
        '非 terminal 组必须原样返回单组的结构化拒绝'
    Assert-True (-not [IO.File]::Exists($quarantined.markerPath) -and
        (Get-RunState -RunDirectory $quarantined.runDirectory) -ceq $quarantinedBefore) `
        '非 terminal 组不得产生归档或改动 evidence'
    $alreadyRow = $varied.results[1]
    Assert-True ($alreadyRow.archived -eq $true -and
        $alreadyRow.alreadyArchived -eq $true -and
        [string]$alreadyRow.archivePath -ceq $alreadyArchived.markerPath -and
        (Get-RunState -RunDirectory $alreadyArchived.runDirectory) -ceq $alreadyArchivedBefore) `
        '已归档组必须报告 alreadyArchived 且 marker 不变'
    Assert-True ([string]$varied.results[2].transactionPath -ceq $outsideTransactionPath -and
        $varied.results[2].archived -eq $false -and
        [string]$varied.results[2].refusalReason -ceq 'archive-operation-failed' -and
        [string]$varied.results[2].error -ceq 'safe-delete archive transaction path 不在受管 evidence run 下。' -and
        (Get-RunState -RunDirectory $outsideDirectory) -ceq $outsideBefore) `
        'evidence run 之外的组必须单独失败且不写入任何文件'
    Assert-FailedRowWithoutMarker `
        -Row $varied.results[3] `
        -Record $badFormat `
        -RunStateBefore $badFormatBefore `
        -ExpectedError 'ApprovedTransactionSha256 格式非法。' `
        -Label '混合失败批次第 4 组（SHA 格式非法）'
    Assert-ArchivedRow -Row $varied.results[4] -Record $fresh -Label '混合失败批次第 5 组（有效）'
    Assert-True ($varied.results[5].archived -eq $true -and
        $varied.results[5].alreadyArchived -eq $true -and
        [string]$varied.results[5].archiveSha256 -ceq [string]$varied.results[4].archiveSha256) `
        '同一批内重复的组必须认证首份 marker 并报告 alreadyArchived'
    Assert-True ($varied.completed -eq $false -and
        $varied.transactionCount -eq 6 -and
        $varied.archivedCount -eq 3 -and
        $varied.alreadyArchivedCount -eq 2 -and
        $varied.refusedCount -eq 1 -and
        $varied.failedCount -eq 2) `
        "混合失败批次的汇总计数必须与逐组结果一致：$($varied | Select-Object -Property * -ExcludeProperty results | ConvertTo-Json -Compress)"

    # 有失败组的多组调用仍以结构化结果返回：JSON 模式 exit 0，由 completed / failedCount 表达。
    $childValid = New-ArchiveRecord -Name 'child-valid'
    $childStale = New-ArchiveRecord -Name 'child-stale'
    $childProcess = Invoke-FixtureEntryProcess -Arguments @(
        '-Mode', 'Archive',
        '-TransactionPaths', "$($childStale.transactionPath)::$($childValid.transactionPath)",
        '-ApprovedTransactionSha256s', "$($childStale.applySha256)::$($childValid.approvedSha256)",
        '-ConfirmArchive',
        '-Json')
    Assert-True ($childProcess.exitCode -eq 0) "含失败组的多组 JSON 调用必须 exit 0，实际 $($childProcess.exitCode)：$($childProcess.stderr)"
    $childBatch = $childProcess.stdout | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-True ($childBatch.completed -eq $false -and
        $childBatch.failedCount -eq 1 -and
        $childBatch.archivedCount -eq 1 -and
        [string]$childBatch.results[0].refusalReason -ceq 'archive-operation-failed' -and
        $childBatch.results[1].archived -eq $true -and
        -not [IO.File]::Exists($childStale.markerPath) -and
        [IO.File]::Exists($childValid.markerPath)) `
        "含失败组的多组 JSON 调用必须逐组返回结果：$($childProcess.stdout)"

    # 5. 单组调用不变：结构化拒绝的字段、JSON 输出形状与退出码都与改动前（c22e7e0）一致。
    $singleRefusal = & $entryPath `
        -Mode Archive `
        -TransactionPath $quarantined.transactionPath `
        -ApprovedTransactionSha256 $quarantined.approvedSha256 `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ((@($singleRefusal.PSObject.Properties.Name) -join '|') -ceq $singleRefusalFields -and
        [string]$singleRefusal.refusalReason -ceq 'transaction-status-not-purged' -and
        -not [IO.File]::Exists($quarantined.markerPath)) `
        "单组结构化拒绝必须保持改动前的字段与原因：$(@($singleRefusal.PSObject.Properties.Name) -join '|')"
    $singleJsonRecord = New-ArchiveRecord -Name 'single-json'
    $singleJson = Invoke-FixtureEntryProcess -Arguments @(
        '-Mode', 'Archive',
        '-TransactionPath', $singleJsonRecord.transactionPath,
        '-ApprovedTransactionSha256', $singleJsonRecord.approvedSha256,
        '-ConfirmArchive',
        '-Json')
    Assert-True ($singleJson.exitCode -eq 0) "单组成功的 JSON 调用必须 exit 0，实际 $($singleJson.exitCode)：$($singleJson.stderr)"
    $singleJsonResult = $singleJson.stdout | ConvertFrom-Json -Depth 32 -DateKind String -ErrorAction Stop
    Assert-True ((@($singleJsonResult.PSObject.Properties.Name) -join '|') -ceq $singleArchivedFields -and
        $singleJsonResult.archived -eq $true -and
        $singleJsonResult.alreadyArchived -eq $false -and
        [string]$singleJsonResult.archiveSha256 -ceq (Get-FileSha256 -Path $singleJsonRecord.markerPath)) `
        "单组成功的 JSON 输出必须保持改动前的单组形状：$($singleJson.stdout)"
    $singleStaleRecord = New-ArchiveRecord -Name 'single-stale'
    $singleStaleBefore = Get-RunState -RunDirectory $singleStaleRecord.runDirectory
    $singleStale = Invoke-FixtureEntryProcess -Arguments @(
        '-Mode', 'Archive',
        '-TransactionPath', $singleStaleRecord.transactionPath,
        '-ApprovedTransactionSha256', $singleStaleRecord.applySha256,
        '-ConfirmArchive',
        '-Json')
    Assert-True ($singleStale.exitCode -eq 1 -and [string]::IsNullOrWhiteSpace($singleStale.stdout)) `
        "单组 SHA 不匹配的 JSON 调用必须照旧 exit 1 且没有 stdout，实际 $($singleStale.exitCode)：$($singleStale.stdout)"
    Assert-True (-not [IO.File]::Exists($singleStaleRecord.markerPath) -and
        (Get-RunState -RunDirectory $singleStaleRecord.runDirectory) -ceq $singleStaleBefore) `
        '单组 SHA 不匹配必须零写入'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteArchiveBatch'
    }
} finally {
    Remove-TestTree -Path $fixtureRoot
}
