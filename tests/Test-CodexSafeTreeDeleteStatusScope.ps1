[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #80，spec #73「实现决策 › Status 范围查询」):
# 唯一接缝：fixture 入口 tests\Invoke-CodexSafeTreeDeleteFixture.ps1 的 Status mode（进程内调用与
# pwsh -File 子进程两种形态）。只观察结果对象 / JSON 与异常消息；本套件不读写生产 evidence 根，
# 也不执行生产入口。

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$fixtureRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'statusscope'
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$targetsRoot = Join-Path $fixtureRoot 'targets'
$policyPath = Join-Path $fixtureRoot 'policy.json'
$utf8 = [Text.UTF8Encoding]::new($false)
# 改动前（1fbfd2f）Status 的顶层与 migrationReadiness 字段顺序；带 TargetPaths 时只在 capturedAtUtc
# 之后多出 scope。
$statusFields = 'artifactType|schemaVersion|capturedAtUtc|complete|policyPath|policySha256|' +
    'policySchemaVersion|migrationReadiness|operations|metrics'
$scopedStatusFields = 'artifactType|schemaVersion|capturedAtUtc|scope|complete|policyPath|policySha256|' +
    'policySchemaVersion|migrationReadiness|operations|metrics'
$readinessFields = 'evaluated|candidatePolicyPath|candidatePolicySha256|candidatePolicySchemaVersion|ready|blockingRecords'
$scopeFields = 'kind|targets|matchedRecords|unattributableRecords'

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
        -Name 'safe-delete status scope test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete status scope test cleanup'
}

function New-Target {
    param([Parameter(Mandatory)][string]$Name)

    $target = Join-Path $targetsRoot $Name
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'payload.txt'), "status-scope-$Name", $utf8)
    return $target
}

function New-PlannedRecord {
    param([Parameter(Mandatory)][string]$TargetPath)

    return & $entryPath `
        -Mode Plan `
        -TargetPath $TargetPath `
        -CapabilityRoot $fixtureRoot `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
}

function New-QuarantinedRecord {
    param([Parameter(Mandatory)][string]$TargetPath)

    $plan = New-PlannedRecord -TargetPath $TargetPath
    $apply = & $entryPath `
        -Mode Apply `
        -PlanPath ([string]$plan.planPath) `
        -ApprovedPlanSha256 ([string]$plan.planSha256) `
        -ConfirmApply `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($apply.quarantined -eq $true) "夹具 Apply 必须成功：$TargetPath"
    return $apply
}

function New-PurgedRecord {
    param([Parameter(Mandatory)][string]$TargetPath)

    $apply = New-QuarantinedRecord -TargetPath $TargetPath
    $purge = & $entryPath `
        -Mode Purge `
        -TransactionPath ([string]$apply.transactionPath) `
        -ApprovedTransactionSha256 ([string]$apply.transactionSha256) `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($purge.purged -eq $true) "夹具 Purge 必须成功：$TargetPath"
    return $purge
}

function New-TruncatedPlanRun {
    # 只有 plan.json 的 run：开头声明了 targetPath，随后在 treeManifest 中途截断。
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ClaimedTargetPath)

    $run = Join-Path $evidenceRoot $Name
    [void][IO.Directory]::CreateDirectory($run)
    $prefix = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-plan'
        targetPath = $ClaimedTargetPath
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText(
        (Join-Path $run 'plan.json'),
        $prefix.Substring(0, $prefix.Length - 1) + ',"treeManifest":{"schemaVersion":',
        $utf8)
}

function Invoke-Status {
    param([string[]]$TargetPaths)

    $arguments = @{
        Mode = 'Status'
        FixturePolicyPath = $policyPath
        FixtureEvidenceRoot = $evidenceRoot
    }
    if ($PSBoundParameters.ContainsKey('TargetPaths')) { $arguments.TargetPaths = $TargetPaths }
    return & $entryPath @arguments
}

function Invoke-StatusWithEnvironment {
    # 临时设置环境变量（kill switch、诊断开关）后调用范围 Status，结束后恢复原值。
    param([Parameter(Mandatory)][hashtable]$Environment, [Parameter(Mandatory)][string[]]$TargetPaths)

    $previous = @{}
    foreach ($name in $Environment.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name]) }
        return Invoke-Status -TargetPaths $TargetPaths
    } finally {
        foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    }
}

function Get-StatusErrorMessage {
    # 调用应当失败的 Status，返回异常消息。
    param([Parameter(Mandatory)][hashtable]$Arguments)

    try {
        & $entryPath -Mode Status @Arguments | Out-Null
    } catch {
        return [string]$_.Exception.Message
    }
    throw "Status 本应失败：$($Arguments | ConvertTo-Json -Compress)"
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

function ConvertTo-OperationJson {
    param([Parameter(Mandatory)][object]$Operation)
    return $Operation | ConvertTo-Json -Depth 100 -Compress
}

function ConvertTo-StatusSemanticJson {
    # 与 Test-CodexSafeTreeDeleteStatus.ps1 同一口径：去掉每次都会变的 capturedAtUtc、metrics 与诊断段。
    param([Parameter(Mandatory)][object]$Status)

    $semantic = [ordered]@{}
    foreach ($property in $Status.PSObject.Properties) {
        if ($property.Name -cin @('capturedAtUtc', 'metrics', 'statusSegments')) { continue }
        $semantic[$property.Name] = $property.Value
    }
    return $semantic | ConvertTo-Json -Depth 100 -Compress
}

function ConvertTo-ScopeAgreementJson {
    # 比较 fast scan 与参考路径的范围结果。无法归属记录的 errors 文本在两条路径之间本来就可能不同
    # （plan 不是合法 JSON 时，参考路径的消息带 PowerShell 方法调用异常的外壳，C# 副本不带；全量
    # Status 同样如此，与范围查询无关），所以这些记录只比较 errors 以外的字段。
    param([Parameter(Mandatory)][object]$Status)

    $semantic = [ordered]@{}
    foreach ($property in $Status.PSObject.Properties) {
        if ($property.Name -cin @('capturedAtUtc', 'metrics', 'statusSegments')) { continue }
        $semantic[$property.Name] = $property.Value
    }
    $semantic.operations = @(foreach ($operation in @($Status.operations)) {
            if ($null -ne $operation.targetPath) {
                $operation
            } else {
                $operation | Select-Object -Property * -ExcludeProperty errors
            }
        })
    return $semantic | ConvertTo-Json -Depth 100 -Compress
}

function Assert-ScopedMatchesFiltered {
    # 范围结果与「全量结果按 targetPath 过滤」逐字段相等：命中记录（targetPath 与任一目标按
    # OrdinalIgnoreCase 相等）一条不少、一条不多、顺序与内容都相同。
    param(
        [Parameter(Mandatory)][object]$Full,
        [Parameter(Mandatory)][object]$Scoped,
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)][string]$Label
    )

    $expected = @($Full.operations | Where-Object {
            $targetPath = $_.targetPath
            -not [string]::IsNullOrEmpty($targetPath) -and
                @($Targets | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals($_, $targetPath) }).Count -gt 0
        } | ForEach-Object { ConvertTo-OperationJson -Operation $_ })
    $actual = @($Scoped.operations | Where-Object { -not [string]::IsNullOrEmpty($_.targetPath) } |
        ForEach-Object { ConvertTo-OperationJson -Operation $_ })
    Assert-True ($actual.Count -eq $expected.Count) "$Label 命中记录数必须为 $($expected.Count)，实际 $($actual.Count)"
    for ($index = 0; $index -lt $expected.Count; $index++) {
        Assert-True ($actual[$index] -ceq $expected[$index]) (
            "$Label 第 $index 条命中记录必须与全量结果逐字段相等：`nexpected=$($expected[$index])`nactual=$($actual[$index])")
    }
    Assert-True ([long]$Scoped.scope.matchedRecords -eq [long]$expected.Count) "$Label scope.matchedRecords 必须为 $($expected.Count)"

    # 无法归属的记录：每条都与全量结果中的同一记录逐字段相等，且为 manual-review。
    $fullById = @{}
    foreach ($operation in @($Full.operations)) { $fullById[[string]$operation.operationId] = $operation }
    $unattributable = @($Scoped.operations | Where-Object { [string]::IsNullOrEmpty($_.targetPath) })
    foreach ($operation in $unattributable) {
        Assert-True ($fullById.ContainsKey([string]$operation.operationId) -and
            (ConvertTo-OperationJson -Operation $operation) -ceq (ConvertTo-OperationJson -Operation $fullById[[string]$operation.operationId])) `
            "$Label 无法归属的记录 $($operation.operationId) 必须与全量结果逐字段相等"
        Assert-True ($operation.lifecycle -ceq 'manual-review') "$Label 无法归属的记录 $($operation.operationId) 必须为 manual-review"
    }
    Assert-True ([long]$Scoped.scope.unattributableRecords -eq [long]$unattributable.Count -and
        [long]$Scoped.scope.matchedRecords + [long]$Scoped.scope.unattributableRecords -eq [long]@($Scoped.operations).Count) `
        "$Label scope 计数必须与 operations 一致"

    # blockingRecords 只针对范围内的记录：等于全量 blockingRecords 限定到范围内记录。
    $scopedIds = @($Scoped.operations | ForEach-Object { [string]$_.operationId })
    $expectedBlocking = @($Full.migrationReadiness.blockingRecords | Where-Object { $_ -cin $scopedIds })
    Assert-True ((@($Scoped.migrationReadiness.blockingRecords) -join '|') -ceq ($expectedBlocking -join '|')) `
        "$Label blockingRecords 必须是全量 blockingRecords 限定到范围内的记录"
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    [void][IO.Directory]::CreateDirectory($targetsRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 3
        entries = @(
            [pscustomobject][ordered]@{
                id = 'status-scope'
                capabilityRoot = $fixtureRoot
                minimumDescendantDepth = 1
                rootDeletionPurpose = 'none'
                deniedExactPaths = @($evidenceRoot)
            }
        )
    }
    [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 10), $utf8)

    # 健康与「可归属的坏记录」：alpha 两次 Plan（同一目标两条 planned）、beta 已隔离、gamma 已 Purge、
    # delta 已 Purge 并 Archive、epsilon Plan 后改动目标内容（planned tree manifest 漂移 → manual-review，
    # targetPath 仍可确定）。
    $alpha = New-Target -Name 'alpha'
    $beta = New-Target -Name 'beta'
    $gamma = New-Target -Name 'gamma'
    $delta = New-Target -Name 'delta'
    $epsilon = New-Target -Name 'epsilon'
    [void](New-PlannedRecord -TargetPath $alpha)
    [void](New-PlannedRecord -TargetPath $alpha)
    [void](New-QuarantinedRecord -TargetPath $beta)
    [void](New-PurgedRecord -TargetPath $gamma)
    $deltaPurge = New-PurgedRecord -TargetPath $delta
    $deltaArchive = & $entryPath `
        -Mode Archive `
        -TransactionPath ([string]$deltaPurge.transactionPath) `
        -ApprovedTransactionSha256 ((Get-FileHash -LiteralPath ([string]$deltaPurge.transactionPath) -Algorithm SHA256).Hash.ToLowerInvariant()) `
        -ConfirmArchive `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot $evidenceRoot
    Assert-True ($deltaArchive.archived -eq $true) '夹具 Archive 必须成功'
    [void](New-PlannedRecord -TargetPath $epsilon)
    [IO.File]::AppendAllText((Join-Path $epsilon 'payload.txt'), '-drift', $utf8)

    # 1. 单个目标：结果带 scope 标注，命中记录与全量结果按 targetPath 过滤逐字段相等。
    $full = Invoke-Status
    $scopedAlpha = Invoke-Status -TargetPaths @($alpha)
    Assert-True ($null -ne $scopedAlpha.PSObject.Properties['scope']) '带 TargetPaths 的 Status 必须输出 scope'
    Assert-True ([string]$scopedAlpha.scope.kind -ceq 'targets') 'scope.kind 必须为 targets'
    Assert-True ((@($scopedAlpha.scope.targets) -join '|') -ceq $alpha) 'scope.targets 必须回显规范化目标'
    Assert-ScopedMatchesFiltered -Full $full -Scoped $scopedAlpha -Targets @($alpha) -Label 'alpha 范围'
    Assert-True ([long]$scopedAlpha.scope.matchedRecords -eq 2L) 'alpha 的两条 planned 记录都必须命中'
    Assert-True ([long]$scopedAlpha.scope.unattributableRecords -eq 0L) '健康夹具没有无法归属的记录'

    # 2. complete、blockingRecords 与 ready 只针对范围内的记录：范围外 epsilon 的漂移不影响 alpha 范围。
    $epsilonOperations = @($full.operations | Where-Object { $_.targetPath -ceq $epsilon })
    Assert-True ($epsilonOperations.Count -eq 1 -and $epsilonOperations[0].lifecycle -ceq 'manual-review') `
        '夹具前提：epsilon 必须是可归属的 manual-review 记录'
    Assert-True (-not [bool]$full.complete -and
        (@($full.migrationReadiness.blockingRecords) -join '|') -ceq [string]$epsilonOperations[0].operationId) `
        '夹具前提：全量 Status 只因 epsilon 不完整'
    Assert-True ([bool]$scopedAlpha.complete -and @($scopedAlpha.migrationReadiness.blockingRecords).Count -eq 0 -and
        [bool]$scopedAlpha.migrationReadiness.ready) 'alpha 范围的 complete / blockingRecords / ready 不受范围外记录影响'
    $scopedEpsilon = Invoke-Status -TargetPaths @($epsilon)
    Assert-ScopedMatchesFiltered -Full $full -Scoped $scopedEpsilon -Targets @($epsilon) -Label 'epsilon 范围'
    Assert-True (-not [bool]$scopedEpsilon.complete -and -not [bool]$scopedEpsilon.migrationReadiness.ready -and
        (@($scopedEpsilon.migrationReadiness.blockingRecords) -join '|') -ceq [string]$epsilonOperations[0].operationId) `
        'epsilon 范围必须报告自己的漂移'

    # 3. 命中按 OrdinalIgnoreCase；目标先规范化为 D 盘全路径再比较；祖先与后代路径都不算命中。
    $caseVariant = $alpha.Substring(0, $alpha.Length - 'alpha'.Length) + 'ALPHA'
    $scopedCaseVariant = Invoke-Status -TargetPaths @($caseVariant)
    Assert-ScopedMatchesFiltered -Full $full -Scoped $scopedCaseVariant -Targets @($alpha) -Label '大小写变体范围'
    Assert-True ((@($scopedCaseVariant.scope.targets) -join '|') -ceq $caseVariant) 'scope.targets 必须原样回显大小写'
    $dottedAlpha = Join-Path $targetsRoot 'beta\..\alpha'
    $scopedDotted = Invoke-Status -TargetPaths @($dottedAlpha)
    Assert-True ((@($scopedDotted.scope.targets) -join '|') -ceq $alpha -and [long]$scopedDotted.scope.matchedRecords -eq 2L) `
        '含相对段的目标必须先规范化再匹配'
    $scopedRelatives = Invoke-Status -TargetPaths @($targetsRoot, (Join-Path $alpha 'payload.txt'))
    Assert-True (@($scopedRelatives.operations).Count -eq 0 -and [long]$scopedRelatives.scope.matchedRecords -eq 0L -and
        [bool]$scopedRelatives.complete) '祖先与后代路径都不得命中'
    # 枚举阶段按 targetPath 预筛：范围外的规范形态记录不做完整认证（不哈希 plan / transaction，
    # 不扫描目标树），开销与空 evidence 根上的 Status 相同（只剩 policy 读取）。
    $emptyEvidenceRoot = Join-Path $fixtureRoot 'evidence-empty'
    [void][IO.Directory]::CreateDirectory($emptyEvidenceRoot)
    $emptyStatus = & $entryPath -Mode Status -FixturePolicyPath $policyPath -FixtureEvidenceRoot $emptyEvidenceRoot
    Assert-True ([long]$full.metrics.bytesHashed -gt [long]$emptyStatus.metrics.bytesHashed -and
        [long]$full.metrics.entriesScanned -gt [long]$emptyStatus.metrics.entriesScanned) '夹具前提：全量 Status 必须认证全部记录'
    Assert-True ([long]$scopedRelatives.metrics.bytesHashed -eq [long]$emptyStatus.metrics.bytesHashed -and
        [long]$scopedRelatives.metrics.entriesScanned -eq [long]$emptyStatus.metrics.entriesScanned) (
        "范围外的规范形态记录不得进入完整认证：bytesHashed=$($scopedRelatives.metrics.bytesHashed) " +
        "entriesScanned=$($scopedRelatives.metrics.entriesScanned)，空 evidence 根为 " +
        "$($emptyStatus.metrics.bytesHashed) / $($emptyStatus.metrics.entriesScanned)")

    # 4. 多个目标：命中记录是各目标命中的并集，顺序与全量结果一致（含已 Archive 的 delta）。
    $multiTargets = @($gamma, $alpha, $delta, $epsilon)
    $scopedMulti = Invoke-Status -TargetPaths $multiTargets
    Assert-ScopedMatchesFiltered -Full $full -Scoped $scopedMulti -Targets $multiTargets -Label '多目标范围'
    Assert-True ((@($scopedMulti.scope.targets) -join '|') -ceq ($multiTargets -join '|')) 'scope.targets 必须按传入顺序回显'

    # 5. pwsh -File 子进程：宿主 .cmd 链只能传单个字符串，多个范围目标与 BatchPurge 一样以 '::' 连接，
    #    结果与进程内传数组相同。子进程 stdout 只按 ASCII 内容比较（operationId、lifecycle、计数与目标
    #    路径的 ASCII 尾段），所以放在加入错误消息为中文的坏记录之前。
    $joinedTargets = @($gamma, $alpha, $delta)
    $inProcessJoined = Invoke-Status -TargetPaths $joinedTargets
    $joinedProcess = Invoke-FixtureEntryProcess -Arguments @(
        '-Mode', 'Status',
        '-TargetPaths', ($joinedTargets -join '::'),
        '-Json')
    Assert-True ($joinedProcess.exitCode -eq 0) "'::' 连接的范围 Status 必须 exit 0，实际 $($joinedProcess.exitCode)：$($joinedProcess.stderr)"
    $joinedLines = @($joinedProcess.stdout -split "`r?`n" | Where-Object { $_ -ne '' })
    Assert-True ($joinedLines.Count -eq 1) "范围 Status 的 -Json 输出必须只有一行，实际 $($joinedLines.Count) 行"
    $joinedStatus = $joinedLines[0] | ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
    Assert-True ((@($joinedStatus.PSObject.Properties.Name) -join '|') -ceq $scopedStatusFields -and
        (@($joinedStatus.scope.PSObject.Properties.Name) -join '|') -ceq $scopeFields -and
        [string]$joinedStatus.scope.kind -ceq 'targets') (
        "子进程范围 Status 的字段必须为 $scopedStatusFields，实际 $(@($joinedStatus.PSObject.Properties.Name) -join '|')")
    $joinedSuffixes = @('\targets\gamma', '\targets\alpha', '\targets\delta')
    Assert-True (@($joinedStatus.scope.targets).Count -eq $joinedSuffixes.Count) "'::' 必须拆成 $($joinedSuffixes.Count) 个范围目标"
    for ($index = 0; $index -lt $joinedSuffixes.Count; $index++) {
        Assert-True (([string]$joinedStatus.scope.targets[$index]).EndsWith($joinedSuffixes[$index], [StringComparison]::Ordinal)) (
            "子进程 scope.targets 第 $index 项必须按传入顺序回显 *$($joinedSuffixes[$index])")
    }
    $operationShape = { param($Status) (@($Status.operations | ForEach-Object { '{0}={1}' -f $_.operationId, $_.lifecycle }) -join '|') }
    Assert-True ((& $operationShape $joinedStatus) -ceq (& $operationShape $inProcessJoined) -and
        [long]$joinedStatus.scope.matchedRecords -eq [long]$inProcessJoined.scope.matchedRecords -and
        [long]$joinedStatus.scope.unattributableRecords -eq [long]$inProcessJoined.scope.unattributableRecords -and
        [bool]$joinedStatus.complete -eq [bool]$inProcessJoined.complete -and
        (@($joinedStatus.migrationReadiness.blockingRecords) -join '|') -ceq (@($inProcessJoined.migrationReadiness.blockingRecords) -join '|')) (
        "'::' 连接的子进程结果必须与进程内传数组相同：child=$(& $operationShape $joinedStatus) inProcess=$(& $operationShape $inProcessJoined)")
    Assert-True ([long]$inProcessJoined.scope.matchedRecords -eq 4L) 'gamma、alpha（两条）、delta 范围必须命中 4 条'

    # 6. 无法确定 targetPath 的记录（evidence 根下的文件、空 run、plan 无法解析、只有 transaction 的
    #    孤儿 run）计入任何范围：与全量结果逐字段相等、为 manual-review、计入 unattributableRecords，
    #    并让范围结果不完整。孤儿 transaction 里写着 alpha 也不作为归属依据。
    [IO.File]::WriteAllText((Join-Path $evidenceRoot 'zz-bad-file.json'), '{}', $utf8)
    [void][IO.Directory]::CreateDirectory((Join-Path $evidenceRoot 'zz-bad-empty'))
    $garbageRun = Join-Path $evidenceRoot 'zz-bad-garbage'
    [void][IO.Directory]::CreateDirectory($garbageRun)
    [IO.File]::WriteAllText((Join-Path $garbageRun 'plan.json'), 'not json', $utf8)
    $orphanRun = Join-Path $evidenceRoot 'zz-bad-orphan'
    [void][IO.Directory]::CreateDirectory($orphanRun)
    [IO.File]::WriteAllText(
        (Join-Path $orphanRun 'transaction.json'),
        ([pscustomobject][ordered]@{ targetPath = $alpha } | ConvertTo-Json -Compress),
        $utf8)
    $badIds = @('zz-bad-empty', 'zz-bad-file.json', 'zz-bad-garbage', 'zz-bad-orphan')
    $fullWithBad = Invoke-Status
    $fullBad = @($fullWithBad.operations | Where-Object { $_.operationId -cin $badIds })
    Assert-True ($fullBad.Count -eq $badIds.Count -and
        @($fullBad | Where-Object { $null -eq $_.targetPath -and $_.lifecycle -ceq 'manual-review' }).Count -eq $badIds.Count) `
        '夹具前提：坏记录在全量 Status 中都是 targetPath 为 null 的 manual-review'
    $scopedAlphaBad = Invoke-Status -TargetPaths @($alpha)
    Assert-ScopedMatchesFiltered -Full $fullWithBad -Scoped $scopedAlphaBad -Targets @($alpha) -Label 'alpha 范围（含坏记录）'
    Assert-True ([long]$scopedAlphaBad.scope.matchedRecords -eq 2L -and
        [long]$scopedAlphaBad.scope.unattributableRecords -eq [long]$badIds.Count) 'alpha 范围必须命中 2 条并计入全部坏记录'
    Assert-True (-not [bool]$scopedAlphaBad.complete -and -not [bool]$scopedAlphaBad.migrationReadiness.ready -and
        (@($scopedAlphaBad.migrationReadiness.blockingRecords | Sort-Object) -join '|') -ceq ($badIds -join '|')) `
        '坏记录必须让范围结果不完整，且只有坏记录阻塞'
    $scopedNoneBad = Invoke-Status -TargetPaths @($targetsRoot)
    Assert-ScopedMatchesFiltered -Full $fullWithBad -Scoped $scopedNoneBad -Targets @($targetsRoot) -Label '无命中范围（含坏记录）'
    Assert-True ((@($scopedNoneBad.operations | ForEach-Object { [string]$_.operationId } | Sort-Object) -join '|') -ceq ($badIds -join '|')) `
        '没有命中时范围结果只剩坏记录'

    # 7. 预筛只凭 plan / terminal-archive 开头的 targetPath 声明排除记录。声明命中范围（大小写变体、
    #    未规范化的写法也算）的记录保留并完整认证；声明在范围外、但完整认证会失败的记录（targetPath
    #    之后被截断的 plan）不出现在范围结果里，这是预筛的已知代价。
    $zeta = Join-Path $targetsRoot 'zeta'
    New-TruncatedPlanRun -Name 'zz-claim-tail' -ClaimedTargetPath $zeta
    New-TruncatedPlanRun -Name 'zz-claim-variant' -ClaimedTargetPath (Join-Path $targetsRoot 'zeta\..\ALPHA')
    $claimIds = @('zz-claim-tail', 'zz-claim-variant')
    $fullWithClaims = Invoke-Status
    Assert-True (@($fullWithClaims.operations | Where-Object {
                $_.operationId -cin $claimIds -and $null -eq $_.targetPath -and $_.lifecycle -ceq 'manual-review'
            }).Count -eq $claimIds.Count) '夹具前提：截断的 plan 在全量 Status 中是 targetPath 为 null 的 manual-review'
    $scopedAlphaClaims = Invoke-Status -TargetPaths @($alpha)
    Assert-ScopedMatchesFiltered -Full $fullWithClaims -Scoped $scopedAlphaClaims -Targets @($alpha) -Label 'alpha 范围（含截断 plan）'
    $alphaClaimIds = @($scopedAlphaClaims.operations | Where-Object { $_.operationId -cin $claimIds } |
        ForEach-Object { [string]$_.operationId })
    Assert-True (($alphaClaimIds -join '|') -ceq 'zz-claim-variant' -and
        [long]$scopedAlphaClaims.scope.unattributableRecords -eq [long]($badIds.Count + 1)) `
        'alpha 范围必须保留声明命中 alpha 的截断 plan，排除声明为 zeta 的截断 plan'
    $scopedZeta = Invoke-Status -TargetPaths @($zeta)
    Assert-ScopedMatchesFiltered -Full $fullWithClaims -Scoped $scopedZeta -Targets @($zeta) -Label 'zeta 范围'
    $zetaClaimIds = @($scopedZeta.operations | Where-Object { $_.operationId -cin $claimIds } |
        ForEach-Object { [string]$_.operationId })
    Assert-True (($zetaClaimIds -join '|') -ceq 'zz-claim-tail' -and [long]$scopedZeta.scope.matchedRecords -eq 0L) `
        'zeta 范围必须只保留声明为 zeta 的截断 plan'

    # 8. 范围查询下现有 kill switch 照常生效，且不改变范围结果：分别关闭 fast scan、tree fast、
    #    parallel fallback 以及三者全关时，范围结果与默认路径相同（含预筛排除的截断 plan）。
    $fastScanSwitch = 'CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN'
    $treeFastSwitch = 'CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST'
    $parallelFallbackSwitch = 'CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK'
    $switchSets = @(
        , [string[]]@($fastScanSwitch)
        , [string[]]@($treeFastSwitch)
        , [string[]]@($parallelFallbackSwitch)
        , [string[]]@($fastScanSwitch, $treeFastSwitch, $parallelFallbackSwitch)
    )
    $switchScopes = @(
        , [string[]]@($alpha)
        , [string[]]@($zeta)
        , [string[]]@($gamma, $alpha, $delta, $beta, $epsilon, $zeta)
    )
    foreach ($switchScope in $switchScopes) {
        $defaultEnvironment = @{
            CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS = '1'
            $fastScanSwitch = '1'
            $treeFastSwitch = '1'
            $parallelFallbackSwitch = '1'
        }
        $defaultScoped = Invoke-StatusWithEnvironment -Environment $defaultEnvironment -TargetPaths $switchScope
        Assert-True ([int]$defaultScoped.statusSegments.fastScanDop -gt 0) '夹具前提：默认路径必须走 fast scan'
        $defaultJson = ConvertTo-ScopeAgreementJson -Status $defaultScoped
        foreach ($switchSet in $switchSets) {
            $environment = $defaultEnvironment.Clone()
            foreach ($name in $switchSet) { $environment[$name] = '0' }
            $switched = Invoke-StatusWithEnvironment -Environment $environment -TargetPaths $switchScope
            $label = "范围 [$($switchScope -join ', ')] 关闭 [$($switchSet -join ', ')]"
            $switchedJson = ConvertTo-ScopeAgreementJson -Status $switched
            Assert-True ($switchedJson -ceq $defaultJson) (
                "$label 时范围结果必须与默认路径相同：`ndefault=$defaultJson`nswitched=$switchedJson")
            if ($switchSet -ccontains $fastScanSwitch) {
                Assert-True ([int]$switched.statusSegments.fastScanDop -eq 0 -and
                    [long]$switched.statusSegments.fastScanHandled -eq 0L) "$label 时必须走参考路径"
            }
        }
    }

    # 9. 不带 TargetPaths 时输出与改动前相同：没有 scope，顶层与 migrationReadiness 字段及顺序不变。
    #    范围覆盖全部目标时，去掉 scope 后与全量结果的语义 JSON 相同。
    $fullFinal = Invoke-Status
    Assert-True ((@($fullFinal.PSObject.Properties.Name) -join '|') -ceq $statusFields) (
        "不带 TargetPaths 的 Status 顶层字段必须为 $statusFields，实际 $(@($fullFinal.PSObject.Properties.Name) -join '|')")
    Assert-True ((@($fullFinal.migrationReadiness.PSObject.Properties.Name) -join '|') -ceq $readinessFields) (
        "不带 TargetPaths 的 migrationReadiness 字段必须为 $readinessFields")
    $allTargets = @($gamma, $alpha, $delta, $beta, $epsilon, $zeta)
    $scopedAll = Invoke-Status -TargetPaths $allTargets
    Assert-True ((@($scopedAll.PSObject.Properties.Name) -join '|') -ceq $scopedStatusFields) (
        "范围 Status 顶层字段必须为 $scopedStatusFields，实际 $(@($scopedAll.PSObject.Properties.Name) -join '|')")
    Assert-True ((@($scopedAll.scope.PSObject.Properties.Name) -join '|') -ceq $scopeFields -and
        (@($scopedAll.migrationReadiness.PSObject.Properties.Name) -join '|') -ceq $readinessFields) (
        "scope 字段必须为 $scopeFields，migrationReadiness 字段不变")
    $fullFinalJson = ConvertTo-StatusSemanticJson -Status $fullFinal
    $scopedAllJson = ConvertTo-StatusSemanticJson -Status ($scopedAll | Select-Object -Property * -ExcludeProperty scope)
    Assert-True ($scopedAllJson -ceq $fullFinalJson) (
        "覆盖全部目标的范围结果去掉 scope 后必须与全量结果相同：`nfull=$fullFinalJson`nscoped=$scopedAllJson")

    # 10. 范围目标的校验先于任何 policy / evidence 访问：policy 与 evidence 根都不存在时，非法目标仍报
    #     范围错误（不带范围时报 evidence 根不存在）。目标与 BatchPurge 一样规范化为 D 盘全路径，按
    #     OrdinalIgnoreCase 不得重复。
    $missingRoots = @{
        FixturePolicyPath = Join-Path $fixtureRoot 'missing-policy.json'
        FixtureEvidenceRoot = Join-Path $fixtureRoot 'missing-evidence'
    }
    $missingRootsMessage = Get-StatusErrorMessage -Arguments $missingRoots
    Assert-True ($missingRootsMessage -ceq 'safe-delete status evidence root 不存在。') (
        "夹具前提：不带范围时必须报 evidence 根不存在，实际 $missingRootsMessage")
    $scopeErrorCases = @(
        @{ targets = [string[]]@('targets\alpha'); message = 'safe-delete status scope target 必须是 D 盘绝对路径：targets\alpha' },
        @{ targets = [string[]]@($alpha, 'C:\status-scope-outside'); message = 'safe-delete status scope target 必须位于 D:\：C:\status-scope-outside' },
        @{ targets = [string[]]@($alpha, $caseVariant); message = 'safe-delete status scope target 重复。' },
        @{ targets = [string[]]@($alpha, $dottedAlpha); message = 'safe-delete status scope target 重复。' }
    )
    foreach ($case in $scopeErrorCases) {
        $message = Get-StatusErrorMessage -Arguments ($missingRoots + @{ TargetPaths = $case.targets })
        Assert-True ($message -ceq $case.message) (
            "范围目标 [$($case.targets -join ', ')] 必须先于 policy / evidence 访问报 $($case.message)，实际 $message")
    }
    Assert-True (-not [IO.Directory]::Exists($missingRoots.FixtureEvidenceRoot) -and
        -not [IO.File]::Exists($missingRoots.FixturePolicyPath)) '范围校验失败不得创建 policy 或 evidence 根'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteStatusScope'
    }
} finally {
    Remove-TestTree -Path $fixtureRoot
}
