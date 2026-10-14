#requires -Version 7.4
<#
.SYNOPSIS
先解析 PowerShell 输入，再执行或只检查语法。
.DESCRIPTION
使用当前受管 Core 7.4+ 运行时的独立无窗口进程，关闭 profile，设置 UTF-8，
并启用 ErrorActionPreference=Stop 与 PSNativeCommandUseErrorActionPreference。
子进程固定为 STA，需要 STA 的 Shell/COM 调用（如 SHFileOperationW）可直接运行。
stdout/stderr 在子进程结束后输出。启用 JSON 字段校验时，失败不回显输出正文。
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
只做输入和语法检查，不启动目标，也不验证目标输出。
.PARAMETER TimeoutSeconds
目标运行超时，默认 60 秒，范围 1-3600。超时仅请求结束本次创建的进程树。
.EXAMPLE
& D:/Codex/.codex/scripts/Invoke-CheckedPowerShell.ps1 -CommandText '$rows = foreach ($x in 1,2) { $x }; $rows | ConvertTo-Json' -CheckOnly
.EXAMPLE
& D:/Codex/.codex/scripts/Invoke-CheckedPowerShell.ps1 -CommandText '[pscustomobject]@{ count = 0; enabled = $false } | ConvertTo-Json -Compress' -RequiredJsonFields @('count', 'enabled')
.NOTES
退出码：0 成功；2 输入/语法预检拒绝；3 JSON 断言失败；124 超时；1 执行异常。
原生程序非零码保留，因此数值可能重合；以 stderr 的稳定状态前缀区分。
执行异常的 stderr 只报异常类型、错误分类和失败位置（script/line/column），不回显消息或源码。
PowerShell 自身的参数绑定错误也可能返回 1。
这是显式 CLI 入口，不是宿主 exec 拦截器或安全沙箱。静态语法检查不验证运行语义；
字段断言只检查调用者指定的字段。目标可主动处理异常或改写错误偏好。
本入口不创建临时文件。普通目标输出由调用者控制，不能作为自动脱敏保证。
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
        $null = [System.Management.Automation.Language.Parser]::ParseFile($resolvedPath, [ref]$tokens, [ref]$parseErrors)
    } else {
        $null = [System.Management.Automation.Language.Parser]::ParseInput($CommandText, [ref]$tokens, [ref]$parseErrors)
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
    [Console]::Error.WriteLine(('CheckedPowerShell runtime-error type={0} category={1} script={2} line={3} column={4}' -f
        $_.Exception.GetType().FullName, $_.CategoryInfo.Category, $scriptName, $line, $column))
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
if ($RequiredJsonFields.Count) {
    if ($targetExitCode -ne 0) {
        [Console]::Error.WriteLine(('CheckedPowerShell target-exit code={0}; JSON validation not performed.' -f $targetExitCode))
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
[Console]::Out.Write($stdout)
[Console]::Error.Write($stderr)
exit $targetExitCode
