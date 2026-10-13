[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #74：生产入口与 fixture 入口共用同一份 mode 分发（确认拒绝对象、参数校验、库函数分发）。
# 行为一律经 fixture 入口驱动。生产入口绑定仓库 policy 与生产 evidence 根，本套件绝不执行它，
# 只读取它的 Get-Command 元数据与 AST。

$projectRoot = Split-Path -Parent $PSScriptRoot
$productionEntryPath = Join-Path $projectRoot 'scripts\Invoke-CodexSafeTreeDelete.ps1'
$fixtureEntryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
$sharedDispatchName = 'Invoke-CodexSafeTreeDeleteMode'
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'mode-dispatch'
$evidenceRoot = Join-Path $scratchRoot 'evidence'
# 本套件的每次调用都在读取 policy 之前就拒绝或抛错，所以 policy 文件故意不存在。
$policyPath = Join-Path $scratchRoot 'policy.json'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-FixtureEntry {
    param([Parameter(Mandatory)][hashtable]$Arguments)
    & $fixtureEntryPath @Arguments -FixturePolicyPath $policyPath -FixtureEvidenceRoot $evidenceRoot
}

function Get-FixtureEntryError {
    param([Parameter(Mandatory)][hashtable]$Arguments)
    try {
        Invoke-FixtureEntry -Arguments $Arguments | Out-Null
    } catch {
        return $_
    }
    throw "fixture 入口本应失败：$($Arguments | ConvertTo-Json -Compress)"
}

# 该异常类型是 PowerShell 内部类型，无法写成类型字面量，按全名比较。
$bindingValidationExceptionName = 'System.Management.Automation.ParameterBindingValidationException'
$powerShellCommonParameters = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
    @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

function Get-EntryCliContract {
    param([Parameter(Mandatory)][string]$Path)

    $contract = [ordered]@{}
    foreach ($parameter in (Get-Command -Name $Path).Parameters.Values) {
        if ($parameter.Name -cin $powerShellCommonParameters) { continue }
        $mandatory = @($parameter.Attributes | Where-Object {
                $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
            }).Count -gt 0
        $validateSets = @($parameter.Attributes | Where-Object {
                $_ -is [System.Management.Automation.ValidateSetAttribute]
            } | ForEach-Object { '{0}|ignoreCase={1}' -f (@($_.ValidValues) -join ','), $_.IgnoreCase })
        $contract[$parameter.Name] = [ordered]@{
            type = $parameter.ParameterType.FullName
            mandatory = $mandatory
            validateSet = $validateSets
        } | ConvertTo-Json -Compress
    }
    return $contract
}

function Get-EntryDispatchShape {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$SharedParameterNames
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) "$Path 必须能无错解析"
    $bodyStart = $ast.ParamBlock.Extent.EndOffset
    $bodyVariableNames = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst]
            }, $true) |
            Where-Object { $_.Extent.StartOffset -ge $bodyStart } |
            ForEach-Object { [string]$_.VariablePath.UserPath } |
            Sort-Object -Unique)
    $dispatchCalls = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq $sharedDispatchName
            }, $true))
    $dispatchArguments = @{}
    if ($dispatchCalls.Count -eq 1) {
        $elements = $dispatchCalls[0].CommandElements
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $argument = $element.Argument
            if ($null -eq $argument -and $index + 1 -lt $elements.Count -and
                $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                $argument = $elements[$index + 1]
                $index++
            }
            $dispatchArguments[$element.ParameterName] = if ($null -eq $argument) { $null } else { $argument.Extent.Text }
        }
    }
    return [pscustomobject][ordered]@{
        interpretedSharedParameters = @($bodyVariableNames | Where-Object {
                $_ -in $SharedParameterNames -and $_ -notin @('Json')
            })
        dispatchCallCount = $dispatchCalls.Count
        dispatchArguments = $dispatchArguments
        # 注释之外任何提到 fixture 或 *ForTest 的代码记号。
        fixtureHookTokens = @($tokens | Where-Object {
                $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and
                $_.Text -match 'Fixture|ForTest'
            } | ForEach-Object { $_.Text })
    }
}

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)

    # 1. 不带确认参数时，五个写 mode 都先于参数校验和任何 policy / evidence 访问，返回逐字节固定的拒绝 JSON。
    $refusalCases = @(
        @{ arguments = @{ Mode = 'Apply' }; json = '{"quarantined":false,"refusalReason":"confirm-apply-required"}' },
        @{ arguments = @{ Mode = 'Purge' }; json = '{"purged":false,"refusalReason":"confirm-purge-required"}' },
        @{ arguments = @{ Mode = 'BatchPurge' }; json = '{"completed":false,"refusalReason":"confirm-apply-and-purge-required"}' },
        @{ arguments = @{ Mode = 'BatchPurge'; ConfirmApply = $true }; json = '{"completed":false,"refusalReason":"confirm-apply-and-purge-required"}' },
        @{ arguments = @{ Mode = 'BatchPurge'; ConfirmPurge = $true }; json = '{"completed":false,"refusalReason":"confirm-apply-and-purge-required"}' },
        @{ arguments = @{ Mode = 'Restore' }; json = '{"restored":false,"refusalReason":"confirm-restore-required"}' },
        @{ arguments = @{ Mode = 'Archive' }; json = '{"archived":false,"refusalReason":"confirm-archive-required"}' }
    )
    foreach ($case in $refusalCases) {
        $label = $case.arguments | ConvertTo-Json -Compress
        $output = @(Invoke-FixtureEntry -Arguments ($case.arguments + @{ Json = $true }))
        Assert-True ($output.Count -eq 1) "未确认 $label 必须只输出一行 JSON，实际 $($output.Count) 项"
        Assert-True ([string]$output[0] -ceq $case.json) (
            "未确认 $label 的拒绝 JSON 必须逐字节为 $($case.json)，实际为 $($output[0])")
    }

    # 2. 已确认但缺必需参数时，各 mode 抛出固定的校验错误，同样早于任何 policy / evidence 访问。
    $batchPurgeMessage = 'BatchPurge 模式要求 TargetPaths 与 CapabilityRoot。'
    $statusScopeMessage = 'Status 范围查询要求 TargetPaths 至少一个目标且均不为空。'
    $validationCases = @(
        @{ arguments = @{ Mode = 'Plan' }; message = 'Plan 模式要求 TargetPath 与 CapabilityRoot。' },
        @{ arguments = @{ Mode = 'Plan'; TargetPath = $scratchRoot }; message = 'Plan 模式要求 TargetPath 与 CapabilityRoot。' },
        @{ arguments = @{ Mode = 'Apply'; ConfirmApply = $true; PlanPath = 'unused-plan.json' }; message = 'Apply 模式要求 PlanPath 与 ApprovedPlanSha256。' },
        @{ arguments = @{ Mode = 'Purge'; ConfirmPurge = $true }; message = 'Purge 模式要求 TransactionPath 与 ApprovedTransactionSha256。' },
        @{ arguments = @{ Mode = 'Restore'; ConfirmRestore = $true; TransactionPath = 'unused-transaction.json' }; message = 'Restore 模式要求 TransactionPath 与 ApprovedTransactionSha256。' },
        @{ arguments = @{ Mode = 'Archive'; ConfirmArchive = $true; ApprovedTransactionSha256 = ('0' * 64) }; message = 'Archive 模式要求 TransactionPath 与 ApprovedTransactionSha256。' },
        @{ arguments = @{ Mode = 'BatchPurge'; ConfirmApply = $true; ConfirmPurge = $true; TargetPaths = @($scratchRoot) }; message = $batchPurgeMessage },
        # 宿主 .cmd 链只能传单个字符串，多个目标以 '::' 连接后在分发里拆开；拆完为空同样算缺 TargetPaths。
        @{ arguments = @{ Mode = 'BatchPurge'; ConfirmApply = $true; ConfirmPurge = $true; TargetPaths = @('::'); CapabilityRoot = $scratchRoot }; message = $batchPurgeMessage },
        # Status 范围查询（#80）：TargetPaths 同样接受 '::' 连接；拆完为空或含空白目标时在分发层拒绝。
        @{ arguments = @{ Mode = 'Status'; TargetPaths = @('::') }; message = $statusScopeMessage },
        @{ arguments = @{ Mode = 'Status'; TargetPaths = @($scratchRoot, ' ') }; message = $statusScopeMessage }
    )
    foreach ($case in $validationCases) {
        $label = $case.arguments | ConvertTo-Json -Compress
        $errorRecord = Get-FixtureEntryError -Arguments $case.arguments
        Assert-True ($errorRecord.Exception.GetType() -eq [System.Management.Automation.RuntimeException]) (
            "$label 必须以普通 throw 拒绝，实际异常类型 $($errorRecord.Exception.GetType().FullName)")
        Assert-True ($errorRecord.Exception.Message -ceq $case.message) (
            "$label 的校验错误必须为 $($case.message)，实际为 $($errorRecord.Exception.Message)")
        Assert-True ($errorRecord.FullyQualifiedErrorId -ceq $case.message) (
            "$label 的错误标识必须等于校验消息，实际为 $($errorRecord.FullyQualifiedErrorId)")
    }

    # 现状：确认后完全不带 -TargetPaths 时，未绑定的 $null 被拆成 @($null)，绕过上面的校验消息，
    # 由库函数 Invoke-CodexSafeTreeDeleteBatchPurge 的 Mandatory 绑定拒绝，同样早于读取 policy。
    # 错误标识末尾的命令名取决于发起库调用的那一帧，所以只断言错误类型、错误 ID 与参数名。
    $missingTargetPaths = Get-FixtureEntryError -Arguments @{
        Mode = 'BatchPurge'; ConfirmApply = $true; ConfirmPurge = $true; CapabilityRoot = $scratchRoot
    }
    Assert-True ($missingTargetPaths.Exception.GetType().FullName -ceq $bindingValidationExceptionName -and
        [string]$missingTargetPaths.Exception.ParameterName -ceq 'TargetPaths' -and
        $missingTargetPaths.FullyQualifiedErrorId.StartsWith('ParameterArgumentValidationErrorEmptyStringNotAllowed,', [StringComparison]::Ordinal)) (
        "确认后缺 -TargetPaths 的 BatchPurge 必须由库函数绑定拒绝 TargetPaths，实际为 $($missingTargetPaths.FullyQualifiedErrorId)：$($missingTargetPaths.Exception.Message)")

    # 3. 未知 mode 由入口自己的参数绑定拒绝（早于加载库），不是由分发层拒绝。
    $unknownMode = Get-FixtureEntryError -Arguments @{ Mode = 'NoSuchMode' }
    Assert-True ($unknownMode.Exception.GetType().FullName -ceq $bindingValidationExceptionName) (
        "未知 mode 必须在参数绑定阶段被 ValidateSet 拒绝，实际异常类型 $($unknownMode.Exception.GetType().FullName)")
    Assert-True ([string]$unknownMode.Exception.ParameterName -ceq 'Mode' -and
        $unknownMode.FullyQualifiedErrorId.StartsWith('ParameterArgumentValidationError,', [StringComparison]::Ordinal)) (
        "未知 mode 必须由入口的 Mode 参数校验拒绝，实际为 $($unknownMode.FullyQualifiedErrorId)：$($unknownMode.Exception.Message)")

    Assert-True (@([IO.Directory]::GetFileSystemEntries($evidenceRoot)).Count -eq 0) (
        '确认拒绝、参数校验失败与未知 mode 都不得向 evidence 根写入任何内容')
    Assert-True (-not [IO.File]::Exists($policyPath)) '本套件不得创建 policy 文件'

    # 4. 两个入口的 CLI 合同一致：生产入口的每个参数（含 Mode 的 ValidateSet）在 fixture 入口里同名、
    #    同类型、同必填；fixture 入口多出的参数只能是 Fixture*。生产入口只取元数据，不执行。
    $productionContract = Get-EntryCliContract -Path $productionEntryPath
    $fixtureContract = Get-EntryCliContract -Path $fixtureEntryPath
    Assert-True ($productionContract.Contains('Mode')) '生产入口必须声明 Mode'
    foreach ($name in @($productionContract.Keys)) {
        Assert-True (-not $name.StartsWith('Fixture', [StringComparison]::OrdinalIgnoreCase)) "生产入口不得暴露 fixture 参数 $name"
        Assert-True ($fixtureContract.Contains($name)) "fixture 入口缺少生产入口参数 $name"
        Assert-True ([string]$fixtureContract[$name] -ceq [string]$productionContract[$name]) (
            "参数 $name 在两个入口的合同不一致：生产 $($productionContract[$name])；fixture $($fixtureContract[$name])")
    }
    foreach ($name in @($fixtureContract.Keys)) {
        if ($productionContract.Contains($name)) { continue }
        Assert-True ($name.StartsWith('Fixture', [StringComparison]::Ordinal)) "fixture 入口多出的参数必须以 Fixture 开头：$name"
    }
    $sharedParameterNames = [string[]]@($productionContract.Keys)

    # 5. 入口只负责各自的 policy / evidence 根、fixture 钩子、输出与退出码：除 -Json 外不自行解读任何
    #    共享 CLI 参数，而是把 $PSBoundParameters 原样交给唯一的共享分发。这样 fixture 套件测到的
    #    分发就是生产入口实际使用的分发。
    $fixtureShape = Get-EntryDispatchShape -Path $fixtureEntryPath -SharedParameterNames $sharedParameterNames
    Assert-True ($fixtureShape.dispatchCallCount -eq 1) (
        "fixture 入口必须恰好调用一次共享分发 $sharedDispatchName，实际 $($fixtureShape.dispatchCallCount) 次")
    Assert-True ([string]$fixtureShape.dispatchArguments['EntryParameters'] -ceq '$PSBoundParameters') (
        'fixture 入口必须把 $PSBoundParameters 原样交给共享分发')
    Assert-True ($fixtureShape.interpretedSharedParameters.Count -eq 0) (
        "fixture 入口除 -Json 外不得自行解读共享 CLI 参数：$($fixtureShape.interpretedSharedParameters -join ', ')")

    # 6. 生产入口走同一个共享分发，只给出固定的 policy / evidence 根，不传测试参数，也没有任何
    #    fixture 钩子的代码。只做静态检查，绝不执行生产入口。
    $productionShape = Get-EntryDispatchShape -Path $productionEntryPath -SharedParameterNames $sharedParameterNames
    Assert-True ($productionShape.dispatchCallCount -eq 1) (
        "生产入口必须恰好调用一次共享分发 $sharedDispatchName，实际 $($productionShape.dispatchCallCount) 次")
    Assert-True ([string]$productionShape.dispatchArguments['EntryParameters'] -ceq '$PSBoundParameters') (
        '生产入口必须把 $PSBoundParameters 原样交给共享分发')
    Assert-True (-not $productionShape.dispatchArguments.ContainsKey('ModeArgumentsForTest')) (
        '生产入口不得向共享分发传入 ModeArgumentsForTest')
    Assert-True ($productionShape.interpretedSharedParameters.Count -eq 0) (
        "生产入口除 -Json 外不得自行解读共享 CLI 参数：$($productionShape.interpretedSharedParameters -join ', ')")
    Assert-True ($productionShape.fixtureHookTokens.Count -eq 0) (
        "生产入口不得出现 fixture 钩子代码：$($productionShape.fixtureHookTokens -join ', ')")
} finally {
    # 只删本套件建的空目录；不为空说明有用例越界写入，留给人查看。
    foreach ($directory in @($evidenceRoot, $scratchRoot)) {
        if ([IO.Directory]::Exists($directory) -and @([IO.Directory]::GetFileSystemEntries($directory)).Count -eq 0) {
            [IO.Directory]::Delete($directory)
        }
    }
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteModeDispatch'
    refusalCases = $refusalCases.Count
    validationCases = $validationCases.Count
    sharedParameters = $sharedParameterNames.Count
}
