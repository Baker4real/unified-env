#requires -Version 7.4
<#
.SYNOPSIS
先预检 PowerShell 输入，再执行或只检查语法、常量正则与内置 cmdlet 参数。
.DESCRIPTION
使用当前受管 Core 7.4+ 运行时的独立无窗口进程，关闭 profile，设置 UTF-8，
并启用 ErrorActionPreference=Stop 与 PSNativeCommandUseErrorActionPreference。
子进程固定为 STA，需要 STA 的 Shell/COM 调用（如 SHFileOperationW）可直接运行。
执行前预检 -match 与 Select-String 的单引号常量正则；SimpleMatch 不按正则检查。
执行前还按 StaticParameterBinder 检查随 pwsh 发布的模块（Core、Management、Utility、Security）里
cmdlet 的调用：参数集无法确定（AmbiguousParameterSet）或参数名不存在（NamedParameterNotFound）即拒绝。
输入自己定义的同名函数、splat 调用和其他模块的命令不查；内置 provider 的动态参数
（Get-Content -Raw、注册表 provider 的 -PropertyType 等）放行。
stdout/stderr 在子进程结束后输出。单个流超过 MaxOutputChars 时只回显开头 2/3 与结尾 1/3，
全文写进 SpillDirectory 下的 txt，stderr 末尾给出 output-truncated 行和文件路径。
启用 JSON 字段校验时 stdout 不截断，JSON 不合格不回显输出正文；
目标非零退出时不做校验，照常转出它的 stdout/stderr。
.PARAMETER ScriptPath
待检查和执行的 .ps1 文件，与 CommandText 互斥。保留目标 PSScriptRoot 与调用目录。
.PARAMETER CommandText
待解析的 PowerShell 源码。通过 argv 传递；受 Windows 命令行长度限制，长源码使用文件。
.PARAMETER ScriptArgument
字符串位置实参，也可用别名 ScriptArguments。用 PowerShell 数组传多个值；值不会
重新解析为 PowerShell 表达式或命名参数。需要命名绑定时在 CommandText 中明确调用。
.PARAMETER RequiredJsonFields
stdout 必须是单个 JSON 对象，每个字段必须存在且不为 null。支持区分大小写的
简单 dot path，不支持数组下标或包含点号的字面键。false、0、空字符串均可通过。
.PARAMETER CheckOnly
只做输入、语法、常量正则和 cmdlet 参数检查，不启动目标，也不验证目标输出。
.PARAMETER TimeoutSeconds
目标运行超时，默认 60 秒，范围 1-3600。超时仅请求结束本次创建的进程树。
.PARAMETER MaxOutputChars
stdout、stderr 各自回显的字符上限，默认 12000；0 不截断。按全文解析输出的程序传 0。
.PARAMETER SpillDirectory
截断时写全文的目录，默认 D:/Codex/temp/checked-powershell。文件不自动清理，也不脱敏。
.EXAMPLE
& D:/Codex/.codex/scripts/Invoke-CheckedPowerShell.ps1 -CommandText '$rows = foreach ($x in 1,2) { $x }; $rows | ConvertTo-Json' -CheckOnly
.EXAMPLE
& D:/Codex/.codex/scripts/Invoke-CheckedPowerShell.ps1 -CommandText '[pscustomobject]@{ count = 0; enabled = $false } | ConvertTo-Json -Compress' -RequiredJsonFields @('count', 'enabled')
.NOTES
退出码：0 成功；2 输入/语法/常量正则/参数预检拒绝；3 JSON 断言失败；124 超时；1 执行异常。
原生程序非零码保留，因此数值可能重合；以 stderr 的稳定状态前缀区分。
执行异常的 stderr 只报异常类型、错误分类和失败位置（script/line/column），不回显消息或源码。
PowerShell 自身的参数绑定错误也可能返回 1。
这是显式 CLI 入口，不是宿主 exec 拦截器或安全沙箱。预检不验证动态表达式或运行语义；
字段断言只检查调用者指定的字段。目标可主动处理异常或改写错误偏好。
只有输出被截断时才写 spill 文件，其余情况不建文件。普通目标输出由调用者控制，不能作为自动脱敏保证。
后台后代由目标脚本自行管理生命周期。根进程退出后若仍有后代持有输出管道，
本入口在 5 秒后以 124 失败；Process API 无法保证收束该类后代，它们可能继续运行。
此分支额外输出 output-state 字段，区分目标退出与输出关闭；retrySafe=false 表示
不得仅因 CLI 失败就重复启动。先按调用者的所有权和 readiness 合同核对后台状态。
不通过全局进程扫描推定或终止已失去可靠归属的进程。
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'File')]
    [string]$ScriptPath,
    [Parameter(Mandatory, ParameterSetName = 'Text')]
    [AllowEmptyString()]
    [string]$CommandText,
    [switch]$CheckOnly,
    [string[]]$RequiredJsonFields = @(),
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 60,
    [ValidateRange(0, 1000000000)]
    [int]$MaxOutputChars = 12000,
    [ValidateNotNullOrEmpty()]
    [string]$SpillDirectory = 'D:/Codex/temp/checked-powershell',
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [Alias('ScriptArguments')]
    [AllowEmptyString()]
    [string[]]$ScriptArgument = @()
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$RequiredJsonFields = @(
    foreach ($fieldValue in @($RequiredJsonFields)) {
        # Native pwsh callers pass comma-separated values as one argv token.
        # Accept that form while retaining array binding for in-process callers.
        foreach ($fieldPart in ([string] $fieldValue -split ',')) {
            $fieldPart.Trim().Trim([char[]] @([char] 39, [char] 34))
        }
    }
)
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -ne 7) {
    [Console]::Error.WriteLine('CheckedPowerShell runtime-required: PowerShell Core 7.')
    exit 2
}
foreach ($field in $RequiredJsonFields) {
    if ([string]::IsNullOrWhiteSpace($field) -or @($field.Split('.') | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
        [Console]::Error.WriteLine('CheckedPowerShell input-error: required JSON paths must have nonempty segments.')
        exit 2
    }
}

$tokens = $null
$parseErrors = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $resolvedPath = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).ProviderPath
        if (-not [IO.File]::Exists($resolvedPath) -or [IO.Path]::GetExtension($resolvedPath) -ine '.ps1') {
            throw 'Input must be a PowerShell script file.'
        }
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedPath, [ref]$tokens, [ref]$parseErrors)
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($CommandText, [ref]$tokens, [ref]$parseErrors)
    }
} catch {
    [Console]::Error.WriteLine('CheckedPowerShell input-error: unable to parse input.')
    exit 2
}
if ($parseErrors.Count) {
    foreach ($parseError in $parseErrors) {
        [Console]::Error.WriteLine(('CheckedPowerShell syntax-error id={0} line={1} column={2}' -f
            $parseError.ErrorId, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber))
    }
    exit 2
}

$regexCandidates = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $node.Operator.ToString().EndsWith('match', [StringComparison]::OrdinalIgnoreCase) -and
        $node.Right -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Right.StringConstantType -in @('SingleQuoted', 'SingleQuotedHereString', 'BareWord')
}, $true) | ForEach-Object { $_.Right })
$selectStringCommands = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Select-String'
}, $true)
foreach ($command in $selectStringCommands) {
    $elements = @($command.CommandElements)
    $simpleMatch = @($elements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SimpleMatch'
    }).Count -gt 0
    if ($simpleMatch) { continue }
    $patternFound = $false
    for ($index = 1; $index -lt $elements.Count - 1; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'Pattern') {
            $patternFound = $true
            $value = $elements[$index + 1]
            if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $value.StringConstantType -in @('SingleQuoted', 'SingleQuotedHereString', 'BareWord')) {
                $regexCandidates += $value
            }
            break
        }
    }
    if (-not $patternFound -and $elements.Count -gt 1) {
        $value = $elements[1]
        if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $value.StringConstantType -in @('SingleQuoted', 'SingleQuotedHereString', 'BareWord')) {
            $regexCandidates += $value
        }
    }
}
foreach ($candidate in $regexCandidates) {
    try {
        $null = [regex]::new($candidate.Value)
    } catch [ArgumentException] {
        [Console]::Error.WriteLine(('CheckedPowerShell regex-error line={0} column={1}' -f
            $candidate.Extent.StartLineNumber, $candidate.Extent.StartColumnNumber))
        exit 2
    }
}

# A cmdlet call whose parameter set cannot be resolved, or that names a missing parameter, fails only when it is
# reached, after earlier statements already ran. Only cmdlets of the modules that ship with pwsh are bound.
$builtinModules = @('Microsoft.PowerShell.Core', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security')
$definedFunctions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
$resolvedCmdlets = @{}
$providerParameters = @{}
foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $command.GetCommandName()
    if (-not $name -or $definedFunctions -contains $name) { continue }
    $splatted = $false
    foreach ($element in $command.CommandElements) {
        if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) { $splatted = $true; break }
    }
    if ($splatted) { continue }
    if (-not $resolvedCmdlets.ContainsKey($name)) {
        # Verb-Noun names are looked up in the built-in modules only, other names in the session alias table by their
        # definition, so native commands and unknown names never start command discovery (hundreds of ms each).
        $lookup = $name
        if ($name -notmatch '^[A-Za-z]+-[A-Za-z0-9]+$') {
            $alias = Get-Alias -Name ([WildcardPattern]::Escape($name)) -ErrorAction Ignore | Select-Object -First 1
            $lookup = if ($alias) { $alias.Definition } else { '' }
        }
        $info = if ($lookup -match '^[A-Za-z]+-[A-Za-z0-9]+$') {
            # GetCmdlet answers from loaded modules without autoloading; Get-Command imports the one built-in module
            # that holds the name.
            $loaded = $ExecutionContext.InvokeCommand.GetCmdlet($lookup)
            if ($loaded) { $loaded } else { Get-Command -Name $lookup -CommandType Cmdlet -Module $builtinModules -ErrorAction Ignore | Select-Object -First 1 }
        }
        $resolvedCmdlets[$name] = if ($info -is [System.Management.Automation.CmdletInfo] -and $builtinModules -contains $info.ModuleName) { $info } else { $null }
    }
    $cmdlet = $resolvedCmdlets[$name]
    if (-not $cmdlet) { continue }
    $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($command, $true)
    foreach ($parameterName in @($binding.BindingExceptions.Keys)) {
        $bindingError = $binding.BindingExceptions[$parameterName]
        $errorId = $bindingError.BindingException.ErrorId
        if ($errorId -notin @('AmbiguousParameterSet', 'NamedParameterNotFound')) { continue }
        if ($errorId -eq 'NamedParameterNotFound') {
            # Provider cmdlets take dynamic parameters from their path, which the binder cannot evaluate when it is a
            # variable; a parameter or alias any built-in provider offers passes. FileSystem comes first and the
            # certificate provider, the slow one to load, last.
            $offered = $false
            # The registry provider is probed through HKLM:\ because pretool-guard rule 8 denies commands that run a
            # script naming the current-user hive next to a registry-property verb; the dynamic parameters are the same.
            foreach ($providerPath in @($PSHOME, 'HKLM:\', 'Env:\', 'Alias:\', 'Function:\', 'Variable:\', 'Cert:\')) {
                $key = $cmdlet.Name + '|' + $providerPath
                if (-not $providerParameters.ContainsKey($key)) {
                    $providerParameters[$key] = @(try {
                        foreach ($parameter in (Get-Command -Name $cmdlet.Name -ArgumentList $providerPath -ErrorAction Stop).Parameters.Values) {
                            $parameter.Name; $parameter.Aliases
                        }
                    } catch { })
                }
                if (@($providerParameters[$key] | Where-Object { $_.StartsWith($parameterName, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                    $offered = $true
                    break
                }
            }
            if ($offered) { continue }
        }
        $extent = $bindingError.CommandElement.Extent
        [Console]::Error.WriteLine(('CheckedPowerShell parameter-error id={0} command={1} line={2} column={3}' -f
            $errorId, $cmdlet.Name, $extent.StartLineNumber, $extent.StartColumnNumber))
        exit 2
    }
}
if ($CheckOnly) { exit 0 }

# The bootstrap is fixed source. User input and argument values only enter through
# ProcessStartInfo.ArgumentList; they are never interpolated into shell source.
$bootstrap = @'
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8
$mode = $args[0]
$target = $args[1]
$targetArguments = @($args | Select-Object -Skip 2)
$global:LASTEXITCODE = 0
try {
    if ($mode -eq 'File') {
        & $target @targetArguments
    } else {
        & ([scriptblock]::Create($target)) @targetArguments
    }
    exit $LASTEXITCODE
} catch {
    if ($_.Exception -is [System.Management.Automation.NativeCommandExitException]) {
        [Console]::Error.WriteLine(('CheckedPowerShell native-exit code={0}' -f $_.Exception.ExitCode))
        exit $_.Exception.ExitCode
    }
    # Locate the failure without echoing payload: exception messages and throw-derived error
    # ids can carry it. The first script stack frame names the failing line; InvocationInfo
    # adds a column only when it points at that same line.
    $scriptName = '-'
    $line = 0
    $column = '-'
    $frame = [regex]::Match([string] $_.ScriptStackTrace, '^at .*?, (?<file>.*): line (?<line>\d+)\r?$', 'Multiline')
    if ($frame.Success) {
        if ($frame.Groups['file'].Value -ne '<No file>') { $scriptName = [IO.Path]::GetFileName($frame.Groups['file'].Value) }
        $line = [int] $frame.Groups['line'].Value
        $invocation = $_.InvocationInfo
        $invocationScript = if ($invocation -and $invocation.ScriptName) { [IO.Path]::GetFileName($invocation.ScriptName) } else { '-' }
        if ($invocation -and $invocation.ScriptLineNumber -eq $line -and $invocationScript -eq $scriptName) { $column = $invocation.OffsetInLine }
    }
    # 只取最内层异常的类型和数值码；消息、Data、路径和完整堆栈不进入诊断。
    $cause = $_.Exception
    $innerType = '-'
    for ($depth = 0; $depth -lt 16 -and $null -ne $cause.InnerException; $depth++) {
        $cause = $cause.InnerException
        $innerType = $cause.GetType().FullName
    }
    $nativeErrorCode = if ($cause -is [ComponentModel.Win32Exception]) { [int]$cause.NativeErrorCode } else { '-' }
    [Console]::Error.WriteLine(('CheckedPowerShell runtime-error type={0} category={1} script={2} line={3} column={4} innerType={5} hresult={6} nativeErrorCode={7}' -f
        $_.Exception.GetType().FullName, $_.CategoryInfo.Category, $scriptName, $line, $column,
        $innerType, [int]$cause.HResult, $nativeErrorCode))
    exit 1
}
'@
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $PSHOME 'pwsh.exe'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$psi.WorkingDirectory = $PWD.ProviderPath
$inputValue = if ($PSCmdlet.ParameterSetName -eq 'File') { $resolvedPath } else { $CommandText }
foreach ($argument in @('-NoProfile', '-NonInteractive', '-STA', '-CommandWithArgs', $bootstrap, $PSCmdlet.ParameterSetName, $inputValue) + $ScriptArgument) {
    $psi.ArgumentList.Add($argument)
}
try {
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $null = $process.WaitForExit(5000)
            [Console]::Error.WriteLine('CheckedPowerShell timeout: owned process tree termination requested.')
            exit 124
        }
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 5000)) {
            [Console]::Error.WriteLine('CheckedPowerShell timeout: redirected output did not close; descendants may remain.')
            [Console]::Error.WriteLine(('CheckedPowerShell output-state: targetExited=true targetExitCode={0} outputClosed=false descendantsMayRemain=true retrySafe=false' -f $process.ExitCode))
            exit 124
        }
        $targetExitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
} catch {
    [Console]::Error.WriteLine('CheckedPowerShell execution-error: unable to run input.')
    exit 1
}

# A stream over MaxOutputChars shows its first two thirds and last third and goes whole to a spill file.
function Limit-TargetStream([string]$Text, [string]$Stream, [System.Collections.Generic.List[string]]$Notes) {
    if ($MaxOutputChars -eq 0 -or $Text.Length -le $MaxOutputChars) { return $Text }
    $directory = [IO.Path]::GetFullPath($SpillDirectory, $PWD.ProviderPath)
    $spillPath = Join-Path $directory ('{0:yyyyMMddTHHmmssfff}-{1}-{2}.txt' -f [DateTime]::Now, $PID, $Stream)
    try {
        $null = [IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText($spillPath, $Text, $utf8)
    } catch {
        $Notes.Add(('CheckedPowerShell output-spill-error stream={0}: spill file not written; full output shown.' -f $Stream))
        return $Text
    }
    $headLength = [int][Math]::Floor($MaxOutputChars * 2 / 3)
    $tailStart = $Text.Length - ($MaxOutputChars - $headLength)
    # Keep surrogate pairs whole at both cuts.
    if ($headLength -gt 0 -and [char]::IsHighSurrogate($Text[$headLength - 1])) { $headLength-- }
    if ([char]::IsLowSurrogate($Text[$tailStart])) { $tailStart++ }
    $Notes.Add(('CheckedPowerShell output-truncated stream={0} shown={1} total={2} path={3}' -f
        $Stream, ($headLength + $Text.Length - $tailStart), $Text.Length, $spillPath))
    return $Text.Substring(0, $headLength) +
        ("`n[CheckedPowerShell output-truncated: {0} chars omitted]`n" -f ($tailStart - $headLength)) + $Text.Substring($tailStart)
}

# stdout stays whole when JSON fields are validated: those callers parse it.
function Write-TargetOutput([string[]]$Trailer = @()) {
    $notes = [System.Collections.Generic.List[string]]::new()
    $shownStdout = if ($RequiredJsonFields.Count) { $stdout } else { Limit-TargetStream $stdout 'stdout' $notes }
    $shownStderr = Limit-TargetStream $stderr 'stderr' $notes
    [Console]::Out.Write($shownStdout)
    [Console]::Error.Write($shownStderr)
    $lines = @($notes) + @($Trailer)
    if ($lines.Count -and $shownStderr.Length -and -not $shownStderr.EndsWith("`n")) { [Console]::Error.WriteLine() }
    foreach ($line in $lines) { [Console]::Error.WriteLine($line) }
}

if ($RequiredJsonFields.Count) {
    if ($targetExitCode -ne 0) {
        # A failing target's own report (often a JSON error object) is what the caller needs to see.
        Write-TargetOutput @(('CheckedPowerShell target-exit code={0}; JSON validation not performed.' -f $targetExitCode))
        exit $targetExitCode
    }
    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($stdout)
    } catch {
        [Console]::Error.WriteLine('CheckedPowerShell json-error reason=invalid-json')
        exit 3
    }
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            [Console]::Error.WriteLine('CheckedPowerShell json-error reason=object-required')
            exit 3
        }
        for ($fieldIndex = 0; $fieldIndex -lt $RequiredJsonFields.Count; $fieldIndex++) {
            $current = $document.RootElement
            $fieldPath = [string] $RequiredJsonFields[$fieldIndex]
            foreach ($segment in $fieldPath.Split('.')) {
                $next = [System.Text.Json.JsonElement]::new()
                if ($current.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or -not $current.TryGetProperty($segment, [ref]$next)) {
                    [Console]::Error.WriteLine(('CheckedPowerShell json-error reason=missing-field field-index={0} field={1}' -f $fieldIndex, $fieldPath))
                    exit 3
                }
                $current = $next
            }
            if ($current.ValueKind -eq [System.Text.Json.JsonValueKind]::Null) {
                [Console]::Error.WriteLine(('CheckedPowerShell json-error reason=null-field field-index={0} field={1}' -f $fieldIndex, $fieldPath))
                exit 3
            }
        }
    } finally {
        $document.Dispose()
    }
}
Write-TargetOutput
exit $targetExitCode
