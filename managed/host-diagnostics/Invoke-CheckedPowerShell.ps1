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
rg 参数可静态分类时，绝对搜索路径含未展开的 * 或 ?，或未接管道输入却省略搜索路径时
在执行前拒绝；正则、glob 选项值不按路径检查，--files、信息选项、动态 argv、未知选项或输入自定义的 rg 函数保持运行时验证。
stdout/stderr 在子进程结束后输出。单个流超过 MaxOutputChars 时只回显开头 2/3 与结尾 1/3，
全文写进 SpillDirectory 下的 txt，stderr 末尾给出 output-truncated 行和文件路径。
启用 JSON 字段校验时默认 stdout 不截断（供外层程序直接解析）；交互式探测可加
-TruncateValidatedJson，先按完整 stdout 校验字段，通过后再写 spill 并按 MaxOutputChars 截断回显。
JSON 不合格不回显输出正文；目标非零退出时不做校验，照常转出它的 stdout/stderr。
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
.PARAMETER TruncateValidatedJson
与 RequiredJsonFields 同用时，先对完整 stdout 完成 JSON 与必填字段校验，再对超长 stdout 应用
MaxOutputChars 截断并写入 SpillDirectory（别名 SpillValidatedJson）。默认不开启以兼容管道解析方。
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
    [Alias('SpillValidatedJson')]
    [switch]$TruncateValidatedJson,
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

# Backslash-escaped quotes survive PowerShell parsing inside an expandable string, but the native
# argument parser consumes the backslash and turns the quote into an argv boundary. After rg -e,
# that can reinterpret an intended XAML attribute fragment as a search path instead of a pattern.
foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $elements = @($command.CommandElements)
    if (-not $elements.Count) { continue }
    $executable = $elements[0]
    if ($executable -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $executable.StringConstantType -eq 'DoubleQuoted' -or $executable.StringConstantType -eq 'DoubleQuotedHereString' -or
        ([IO.Path]::GetFileNameWithoutExtension($executable.Value) -ine 'rg')) { continue }
    $explicitPattern = @($elements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
            $_.Extent.Text -in @('-e', '--regexp')
    }).Count -gt 0
    if (-not $explicitPattern) { continue }
    $invalidQuote = $command.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.StringConstantType -eq 'DoubleQuoted' -and
            $node.Extent.Text.Contains('\"')
    }, $true) | Select-Object -First 1
    if ($null -ne $invalidQuote) {
        [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=rg reason=escaped-quote-native-argv line={0} column={1}' -f
            $invalidQuote.Extent.StartLineNumber, $invalidQuote.Extent.StartColumnNumber))
        exit 2
    }
}

# Native argv does not expand Windows wildcard paths, and in non-TTY subshells rg without a
# search path or upstream pipeline waits on stdin (or reads empty stdin) instead of searching ".".
# Classify only a completely static, recognized rg invocation; a glob or regexp option's value
# is not a search path.
function Find-RgStaticArgumentIssue([System.Management.Automation.Language.CommandAst]$Command) {
    $elements = @($Command.CommandElements)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($element in $elements | Select-Object -Skip 1) {
        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $arguments.Add($element.Value)
        } elseif ($element -is [System.Management.Automation.Language.ConstantExpressionAst] -and $element.Value -is [ValueType]) {
            $arguments.Add([Convert]::ToString($element.Value, [Globalization.CultureInfo]::InvariantCulture))
        } elseif ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $null -eq $element.Argument) {
            $arguments.Add($element.Extent.Text)
        } else { return $null }
    }
    $valueOptions = @(
        '--regexp', '--file', '--pre', '--pre-glob', '--dfa-size-limit', '--encoding', '--engine',
        '--max-count', '--regex-size-limit', '--threads', '--glob', '--iglob', '--ignore-file',
        '--max-depth', '--max-filesize', '--type', '--type-not', '--type-add', '--type-clear',
        '--after-context', '--before-context', '--color', '--colors', '--context', '--context-separator',
        '--field-context-separator', '--field-match-separator', '--hostname-bin', '--hyperlink-format',
        '--max-columns', '--path-separator', '--replace', '--sort', '--sortr', '--generate'
    )
    $switchOptions = @(
        '--search-zip', '--case-sensitive', '--crlf', '--fixed-strings', '--ignore-case', '--invert-match',
        '--line-regexp', '--mmap', '--multiline', '--multiline-dotall', '--no-unicode', '--null-data',
        '--pcre2', '--smart-case', '--stop-on-nonmatch', '--text', '--word-regexp', '--auto-hybrid-regex',
        '--no-pcre2-unicode', '--binary', '--follow', '--glob-case-insensitive', '--hidden',
        '--ignore-file-case-insensitive', '--no-ignore', '--no-ignore-dot', '--no-ignore-exclude',
        '--no-ignore-files', '--no-ignore-global', '--no-ignore-parent', '--no-ignore-vcs', '--no-require-git',
        '--one-file-system', '--unrestricted', '--block-buffered', '--byte-offset', '--column', '--heading',
        '--include-zero', '--line-buffered', '--line-number', '--no-line-number', '--max-columns-preview',
        '--null', '--only-matching', '--passthru', '--pretty', '--quiet', '--trim', '--vimgrep',
        '--with-filename', '--no-filename', '--sort-files', '--count', '--count-matches', '--files-with-matches',
        '--files-without-match', '--json', '--debug', '--no-ignore-messages', '--no-messages', '--stats',
        '--trace', '--files', '--no-config'
    )
    $positionals = [Collections.Generic.List[int]]::new()
    $explicitPattern = $false
    $filesMode = $false
    $endOptions = $false
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($endOptions -or -not $argument.StartsWith('-') -or $argument -eq '-') {
            $positionals.Add($index)
            continue
        }
        if ($argument -eq '--') { $endOptions = $true; continue }
        if ($argument.StartsWith('--')) {
            $option = ($argument -split '=', 2)[0]
            if ($option -cin @('--help', '--version', '--pcre2-version', '--type-list', '--generate')) { return $null }
            if ($valueOptions -ccontains $option) {
                if ($option -cin @('--regexp', '--file')) { $explicitPattern = $true }
                if (-not $argument.Contains('=')) {
                    $index++
                    if ($index -ge $arguments.Count) { return $null }
                }
            } elseif (($switchOptions -ccontains $option) -and -not $argument.Contains('=')) {
                if ($option -ceq '--files') { $filesMode = $true }
            } else { return $null }
            continue
        }
        # rg permits clusters (-nH) and attached option values (-g*.md, -C3).
        for ($offset = 1; $offset -lt $argument.Length; $offset++) {
            $flag = $argument.Substring($offset, 1)
            if ($flag -cin @('h', 'V')) { return $null }
            if ('efEmjgdtTABCMr'.Contains($flag)) {
                if ($flag -cin @('e', 'f')) { $explicitPattern = $true }
                if ($offset -eq $argument.Length - 1) {
                    $index++
                    if ($index -ge $arguments.Count) { return $null }
                }
                break
            }
            if (-not 'zsFivxUPSawL.ubnN0opqHIcl'.Contains($flag)) { return $null }
        }
    }
    $firstPath = if ($explicitPattern -or $filesMode) { 0 } else { 1 }
    $receivesPipelineInput = $Command.Parent -is [System.Management.Automation.Language.PipelineAst] -and
        $Command.Parent.PipelineElements.Count -gt 1 -and
        $Command.Parent.PipelineElements[0] -ne $Command
    if (-not $filesMode -and -not $receivesPipelineInput -and ($explicitPattern -or $positionals.Count -ge 1) -and $positionals.Count -le $firstPath) {
        return [pscustomobject]@{
            Reason = 'missing-rg-target-path'
            Node = $Command
            Hint = 'pass an explicit search path or pipe stdin'
        }
    }
    for ($index = $firstPath; $index -lt $positionals.Count; $index++) {
        $argumentIndex = $positionals[$index]
        $path = $arguments[$argumentIndex]
        # The question mark in a Windows extended-path prefix is not a wildcard.
        $pathBody = $path -replace '^[\\/]{2}\?[\\/]', ''
        if ([IO.Path]::IsPathFullyQualified($path) -and ($pathBody.Contains('*') -or $pathBody.Contains('?'))) {
            return [pscustomobject]@{
                Reason = 'unexpanded-wildcard-path'
                Node = $elements[$argumentIndex + 1]
                Hint = 'expand paths before rg'
            }
        }
    }
    return $null
}
$rgDefinedLocally = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -match '^(?:(?:global|script|local|private):)?rg(?:\.exe)?$' }, $true)).Count -gt 0
if (-not $rgDefinedLocally) {
    foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if (-not $name -or [IO.Path]::GetFileNameWithoutExtension($name) -ine 'rg') { continue }
        $issue = Find-RgStaticArgumentIssue $command
        if ($null -ne $issue) {
            [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=rg reason={0} line={1} column={2}; {3}' -f
                $issue.Reason, $issue.Node.Extent.StartLineNumber, $issue.Node.Extent.StartColumnNumber, $issue.Hint))
            exit 2
        }
    }
}

# A bare comma becomes an ArrayLiteralAst. Native argv binding then splits a gh --json field list into separate arguments.
foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $elements = @($command.CommandElements)
    if (-not $elements.Count) { continue }
    $executable = $elements[0]
    if ($executable -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $executable.StringConstantType -eq 'DoubleQuoted' -or $executable.StringConstantType -eq 'DoubleQuotedHereString' -or
        ([IO.Path]::GetFileNameWithoutExtension($executable.Value) -ine 'gh')) { continue }
    $commandParts = @($elements | ForEach-Object { $_.Extent.Text })
    if ($commandParts.Count -ge 4 -and $commandParts[1] -eq 'issue' -and $commandParts[2] -eq 'view' -and
        $commandParts -contains '--comments' -and $commandParts -contains '--json') {
        [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=gh reason=comments-json-mutually-exclusive line={0} column={1}' -f
            $command.Extent.StartLineNumber, $command.Extent.StartColumnNumber))
        exit 2
    }
    $ghSubcommands = [Collections.Generic.List[string]]::new()
    for ($subIdx = 1; $subIdx -lt $elements.Count -and $ghSubcommands.Count -lt 2; $subIdx++) {
        $tokText = $elements[$subIdx].Extent.Text
        if ($tokText -in @('-R', '--repo', '-H', '--hostname')) { $subIdx++; continue }
        if ($tokText.StartsWith('-')) { continue }
        $ghSubcommands.Add(($elements[$subIdx].Extent.Text.Trim("'", '"')))
    }
    $isGhRepoView = $ghSubcommands.Count -ge 2 -and $ghSubcommands[0] -ieq 'repo' -and $ghSubcommands[1] -ieq 'view'
    $ghRepoViewSearchFieldMap = @{
        'stargazersCount' = 'stargazerCount'
        'forksCount'      = 'forkCount'
        'license'         = 'licenseInfo'
        'fullName'        = 'nameWithOwner'
    }
    for ($index = 1; $index -lt $elements.Count - 1; $index++) {
        if ($elements[$index].Extent.Text -ine '--json') { continue }
        $value = $elements[$index + 1]
        if ($value -is [System.Management.Automation.Language.ArrayLiteralAst]) {
            [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=gh parameter=--json reason=bare-comma-array line={0} column={1}' -f
                $value.Extent.StartLineNumber, $value.Extent.StartColumnNumber))
            exit 2
        }
        if ($isGhRepoView -and $value -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            foreach ($jsonField in ($value.Value -split ',')) {
                $trimmedField = $jsonField.Trim()
                if ($ghRepoViewSearchFieldMap.ContainsKey($trimmedField)) {
                    $replacementField = $ghRepoViewSearchFieldMap[$trimmedField]
                    [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=gh parameter=--json reason=gh-repo-view-invalid-json-field line={0} column={1}; gh repo view rejects search field {2} (use {3})' -f
                        $value.Extent.StartLineNumber, $value.Extent.StartColumnNumber, $trimmedField, $replacementField))
                    exit 2
                }
            }
        }
    }
}

# PowerShell single-quoted strings do not unescape \", and multiline inline python -c strings repeatedly break on
# mixed PowerShell/Python quoting. Require here-strings (@' ... '@ | python -) or .py files instead.
foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $elements = @($command.CommandElements)
    if ($elements.Count -lt 3) { continue }
    $executable = $elements[0]
    if ($executable -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $executable.StringConstantType -in @('DoubleQuoted', 'DoubleQuotedHereString') -or
        ([IO.Path]::GetFileNameWithoutExtension($executable.Value) -notin @('python', 'python3', 'py'))) { continue }
    for ($index = 1; $index -lt $elements.Count - 1; $index++) {
        $flag = $elements[$index]
        $isDashC = ($flag -is [System.Management.Automation.Language.CommandParameterAst] -and $flag.ParameterName -ceq 'c' -and $null -eq $flag.Argument) -or
            ($flag -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $flag.Value -ceq '-c')
        if (-not $isDashC) { continue }
        $code = $elements[$index + 1]
        if ($code -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            if ($code.StringConstantType -eq 'SingleQuoted' -and $code.Value.Contains('\"')) {
                [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=python parameter=-c reason=single-quoted-backslash-quote line={0} column={1}; use @'' ... ''@ | python - or write a .py file' -f
                    $code.Extent.StartLineNumber, $code.Extent.StartColumnNumber))
                exit 2
            }
            if ($code.StringConstantType -in @('SingleQuoted', 'DoubleQuoted') -and ($code.Value.Contains("`n") -or $code.Value.Contains("`r"))) {
                [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=python parameter=-c reason=multiline-inline-python line={0} column={1}; use @'' ... ''@ | python - or write a .py file' -f
                    $code.Extent.StartLineNumber, $code.Extent.StartColumnNumber))
                exit 2
            }
        } elseif ($code -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                  $code.StringConstantType -eq 'DoubleQuoted' -and ($code.Extent.Text.Contains("`n") -or $code.Extent.Text.Contains("`r"))) {
            [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=python parameter=-c reason=multiline-inline-python line={0} column={1}; use @'' ... ''@ | python - or write a .py file' -f
                $code.Extent.StartLineNumber, $code.Extent.StartColumnNumber))
            exit 2
        }
        break
    }
}

# Piping gh api directly into a file-writing python -c runs the writer even when gh fails with EOF/404,
# silently creating empty 0-byte files and printing false success messages.
foreach ($pipeline in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.PipelineAst] -and $node.PipelineElements.Count -ge 2 }, $true)) {
    $hasGhApi = $false
    foreach ($stage in $pipeline.PipelineElements) {
        if ($stage -isnot [System.Management.Automation.Language.CommandAst]) { continue }
        $elements = @($stage.CommandElements)
        if ($elements.Count -lt 2) { continue }
        $executable = $elements[0]
        if ($executable -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $executable.StringConstantType -in @('DoubleQuoted', 'DoubleQuotedHereString')) { continue }
        $exeBase = [IO.Path]::GetFileNameWithoutExtension($executable.Value)
        if (-not $hasGhApi) {
            if ($exeBase -ieq 'gh' -and $elements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $elements[1].Value -ieq 'api') {
                $hasGhApi = $true
            }
            continue
        }
        if ($exeBase -notin @('python', 'python3', 'py')) { continue }
        for ($index = 1; $index -lt $elements.Count - 1; $index++) {
            $flag = $elements[$index]
            $isDashC = ($flag -is [System.Management.Automation.Language.CommandParameterAst] -and $flag.ParameterName -ceq 'c' -and $null -eq $flag.Argument) -or
                ($flag -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $flag.Value -ceq '-c')
            if (-not $isDashC) { continue }
            $codeText = $elements[$index + 1].Extent.Text
            if ($codeText -cmatch '\bopen\s*\([^)]*[''"][a-zA-Z+]*w|\.(?:write|write_bytes|write_text)\s*\(') {
                [Console]::Error.WriteLine(('CheckedPowerShell native-argument-error command=gh reason=unguarded-pipe-write line={0} column={1}; save via gh api -H raw or check $LASTEXITCODE before writing' -f
                    $stage.Extent.StartLineNumber, $stage.Extent.StartColumnNumber))
                exit 2
            }
            break
        }
    }
}

# Assigning to PowerShell's AllScope read-only/constant automatic variables (case-insensitive, e.g. $pId = ...)
# always throws SessionStateUnauthorizedAccessException at runtime, including inside functions and foreach/param.
$readOnlyAutoVars = @{
    'pid' = 'PID'
    'home' = 'HOME'
    'host' = 'Host'
    'true' = 'true'
    'false' = 'false'
    'pshome' = 'PSHOME'
    'psversiontable' = 'PSVersionTable'
    'psedition' = 'PSEdition'
    'shellid' = 'ShellId'
    'executioncontext' = 'ExecutionContext'
    'iswindows' = 'IsWindows'
    'islinux' = 'IsLinux'
    'ismacos' = 'IsMacOS'
    'iscoreclr' = 'IsCoreCLR'
    'psculture' = 'PSCulture'
    'psuiculture' = 'PSUICulture'
    'enabledexperimentalfeatures' = 'EnabledExperimentalFeatures'
}
function Test-ReadOnlyAutoVarAst([System.Management.Automation.Language.VariableExpressionAst]$VarAst) {
    if ($null -eq $VarAst -or $VarAst.VariablePath.IsDriveQualified) { return $null }
    $raw = $VarAst.VariablePath.UserPath -replace '^(?:global|local|script|private):', ''
    $lower = $raw.ToLowerInvariant()
    if ($readOnlyAutoVars.ContainsKey($lower)) { return $readOnlyAutoVars[$lower] }
    return $null
}
$autoVarTargets = [Collections.Generic.List[System.Management.Automation.Language.VariableExpressionAst]]::new()
foreach ($assign in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $lhs = $assign.Left
    while ($lhs -is [System.Management.Automation.Language.AttributedExpressionAst]) { $lhs = $lhs.Child }
    if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) { $autoVarTargets.Add($lhs) }
}
foreach ($fe in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
    if ($null -ne $fe.Variable) { $autoVarTargets.Add($fe.Variable) }
}
foreach ($prm in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
    if ($null -ne $prm.Name) { $autoVarTargets.Add($prm.Name) }
}
$autoVarTargets.Sort([Comparison[System.Management.Automation.Language.VariableExpressionAst]]{
    param($a, $b)
    $a.Extent.StartOffset.CompareTo($b.Extent.StartOffset)
})
foreach ($targetVar in $autoVarTargets) {
    $canonical = Test-ReadOnlyAutoVarAst $targetVar
    if ($null -ne $canonical) {
        [Console]::Error.WriteLine(('CheckedPowerShell parameter-error id=ReadOnlyAutomaticVariable command=${0} line={1} column={2}; PowerShell variable names are case-insensitive and ${0} is read-only/constant; rename it' -f
            $canonical, $targetVar.Extent.StartLineNumber, $targetVar.Extent.StartColumnNumber))
        exit 2
    }
}

# A cmdlet call whose parameter set cannot be resolved, or that names a missing parameter, fails only when it is
# reached, after earlier statements already ran. Only cmdlets of the modules that ship with pwsh are bound.
$builtinModules = @('Microsoft.PowerShell.Core', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security')
$definedFunctions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
function Get-StaticSelectObjectProperties([System.Management.Automation.Language.CommandAst]$CmdAst) {
    $elements = @($CmdAst.CommandElements)
    if ($elements.Count -le 1) { return $null }
    $props = [Collections.Generic.List[string]]::new()
    $expectValueFor = $null
    for ($idx = 1; $idx -lt $elements.Count; $idx++) {
        $el = $elements[$idx]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            $pName = $el.ParameterName
            if ($pName -imatch '^(?:Expand|ExpandProperty)$') { return $null }
            if ($pName -imatch '^(?:Exclude|ExcludeProperty)$') { return $null }
            if ($pName -imatch '^Prop(?:erty)?$') {
                if ($null -ne $el.Argument) {
                    $el = $el.Argument
                    $expectValueFor = 'Property'
                } else {
                    $expectValueFor = 'PropertyNext'
                    continue
                }
            } else {
                if ($null -eq $el.Argument -and $pName -imatch '^(?:First|Last|Skip|SkipLast|Index|SkipIndex)$') {
                    $expectValueFor = 'SkipArg'
                } else {
                    $expectValueFor = $null
                }
                continue
            }
        }
        if ($expectValueFor -eq 'SkipArg') {
            $expectValueFor = $null
            continue
        }
        $isPropertyArg = ($null -eq $expectValueFor -or $expectValueFor -in @('Property', 'PropertyNext'))
        if ($expectValueFor -in @('Property', 'PropertyNext')) { $expectValueFor = $null }
        if (-not $isPropertyArg) { continue }
        $items = if ($el -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($el.Elements) } else { @($el) }
        foreach ($item in $items) {
            if ($item -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
            $val = $item.Value
            if ([string]::IsNullOrWhiteSpace($val) -or $val.IndexOfAny([char[]]@('*', '?')) -ge 0) { return $null }
            $props.Add($val)
        }
    }
    if ($props.Count -eq 0) { return $null }
    return ,$props.ToArray()
}
if ($null -ne $ast.EndBlock) {
    $firstSelectSet = $null
    foreach ($topStmt in @($ast.EndBlock.Statements)) {
        if ($topStmt -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
        $pipeEls = @($topStmt.PipelineElements)
        if ($pipeEls.Count -eq 0) { continue }
        $tailEl = $pipeEls[$pipeEls.Count - 1]
        if ($tailEl -isnot [System.Management.Automation.Language.CommandAst] -or @($tailEl.Redirections).Count -gt 0) { continue }
        $tailName = $tailEl.GetCommandName()
        if (-not $tailName -or $definedFunctions -contains $tailName) { continue }
        if ($tailName -notin @('Select-Object', 'select')) { continue }
        $staticProps = Get-StaticSelectObjectProperties $tailEl
        if ($null -eq $staticProps) { continue }
        if ($null -eq $firstSelectSet) {
            $firstSelectSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($p in $staticProps) { [void]$firstSelectSet.Add($p) }
        } else {
            $missingProps = @($staticProps | Where-Object { -not $firstSelectSet.Contains($_) })
            if ($missingProps.Count -gt 0) {
                [Console]::Error.WriteLine(('CheckedPowerShell parameter-error id=MixedSelectObjectFormatting command=Select-Object line={0} column={1}; multiple top-level Select-Object pipelines share one console formatter and silently drop properties missing from the first Select-Object ({2}); pipe each to Out-String/Format-List or combine into one [pscustomobject] | ConvertTo-Json' -f
                    $tailEl.Extent.StartLineNumber, $tailEl.Extent.StartColumnNumber, ($missingProps -join ',')))
                exit 2
            }
        }
    }
}
$resolvedCmdlets = @{}
$providerParameters = @{}
$winEventSingleAssignVars = $null
$hasLocalStartBoundaryAssign = $null
function Unwrap-SimpleAst([System.Management.Automation.Language.Ast]$Node) {
    $cur = $Node
    while ($null -ne $cur) {
        if ($cur -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $cur = $cur.Pipeline
        } elseif ($cur -is [System.Management.Automation.Language.PipelineAst] -and $cur.PipelineElements.Count -eq 1 -and
            $cur.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $cur = $cur.PipelineElements[0].Expression
        } elseif ($cur -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $cur = $cur.Expression
        } elseif ($cur -is [System.Management.Automation.Language.AttributedExpressionAst]) {
            $cur = $cur.Child
        } else {
            break
        }
    }
    return $cur
}
function Try-GetStaticIntValue([System.Management.Automation.Language.Ast]$Node, [ref]$OutVal) {
    $cur = Unwrap-SimpleAst $Node
    $sign = 1L
    if ($cur -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        if ($cur.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus) { $sign = -1L; $cur = Unwrap-SimpleAst $cur.Child }
        elseif ($cur.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Plus) { $cur = Unwrap-SimpleAst $cur.Child }
    }
    if ($cur -is [System.Management.Automation.Language.ConstantExpressionAst] -and $null -ne $cur.Value) {
        $parsed = 0L
        if ([long]::TryParse([string]$cur.Value, [ref]$parsed)) {
            $OutVal.Value = $sign * $parsed
            return $true
        }
    }
    return $false
}
function Measure-StaticFilterIdCount([System.Management.Automation.Language.Ast]$ExprAst, [hashtable]$SingleAssignVars, [int]$Depth = 0) {
    if ($null -eq $ExprAst -or $Depth -gt 4) { return -1 }
    $cur = Unwrap-SimpleAst $ExprAst
    if ($cur -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $stmts = @($cur.SubExpression.Statements)
        if ($stmts.Count -eq 0) { return 0 }
        $sum = 0
        foreach ($st in $stmts) {
            if ($st -isnot [System.Management.Automation.Language.PipelineAst]) { return -1 }
            $subCount = Measure-StaticFilterIdCount $st $SingleAssignVars ($Depth + 1)
            if ($subCount -lt 0) { return -1 }
            $sum += $subCount
        }
        return $sum
    }
    if ($cur -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $sum = 0
        foreach ($elem in $cur.Elements) {
            $subCount = Measure-StaticFilterIdCount $elem $SingleAssignVars ($Depth + 1)
            if ($subCount -lt 0) { return -1 }
            $sum += $subCount
        }
        return $sum
    }
    if ($cur -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        if ($cur.Operator -eq [System.Management.Automation.Language.TokenKind]::DotDot) {
            $lo = 0L; $hi = 0L
            if ((Try-GetStaticIntValue $cur.Left ([ref]$lo)) -and (Try-GetStaticIntValue $cur.Right ([ref]$hi))) {
                $span = [Math]::Abs($hi - $lo) + 1L
                if ($span -gt [int]::MaxValue) { return [int]::MaxValue }
                return [int]$span
            }
            return -1
        }
        if ($cur.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) {
            $lc = Measure-StaticFilterIdCount $cur.Left $SingleAssignVars ($Depth + 1)
            $rc = Measure-StaticFilterIdCount $cur.Right $SingleAssignVars ($Depth + 1)
            if ($lc -ge 0 -and $rc -ge 0) { return ($lc + $rc) }
            return -1
        }
        return -1
    }
    $dummy = 0L
    if ($cur -is [System.Management.Automation.Language.ConstantExpressionAst] -or
        $cur -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        (Try-GetStaticIntValue $cur ([ref]$dummy))) {
        return 1
    }
    if ($cur -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $cur.VariablePath.IsDriveQualified -and $null -ne $SingleAssignVars) {
        $vName = ($cur.VariablePath.UserPath -replace '^(?:global|local|script|private):', '').ToLowerInvariant()
        if ($SingleAssignVars.ContainsKey($vName)) {
            return Measure-StaticFilterIdCount $SingleAssignVars[$vName] $SingleAssignVars ($Depth + 1)
        }
    }
    return -1
}
foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $command.GetCommandName()
    if (-not $name -or $definedFunctions -contains $name) { continue }
    $splatted = $false
    foreach ($element in $command.CommandElements) {
        if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) { $splatted = $true; break }
    }
    if ($splatted) { continue }
    # New-ScheduledTaskTrigger -Weekly serializes -At as UTC (...Z), shifting local 00:00-07:59 triggers across weekdays unless .StartBoundary is explicitly assigned without trailing Z.
    if ($name -ieq 'New-ScheduledTaskTrigger') {
        $elements = @($command.CommandElements)
        $hasWeekly = $false
        foreach ($el in $elements) {
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                'Weekly'.StartsWith($el.ParameterName, [StringComparison]::OrdinalIgnoreCase)) {
                $argText = if ($null -ne $el.Argument) { $el.Argument.Extent.Text.Trim() } else { '' }
                if ($argText -ine '$false' -and $argText -ne '0') { $hasWeekly = $true }
            }
        }
        if ($hasWeekly) {
            if ($null -eq $hasLocalStartBoundaryAssign) {
                $hasLocalStartBoundaryAssign = $false
                foreach ($asg in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                    $lhs = Unwrap-SimpleAst $asg.Left
                    if ($lhs -is [System.Management.Automation.Language.MemberExpressionAst] -and
                        $lhs.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $lhs.Member.Value -ieq 'StartBoundary') {
                        $rhs = Unwrap-SimpleAst $asg.Right
                        $isTrailingUtcZ =
                            ($rhs -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $rhs.Value -imatch 'Z$') -or
                            ($rhs -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $rhs.Value -imatch 'Z$')
                        if (-not $isTrailingUtcZ) {
                            $hasLocalStartBoundaryAssign = $true
                            break
                        }
                    }
                }
            }
            if (-not $hasLocalStartBoundaryAssign) {
                [Console]::Error.WriteLine(('CheckedPowerShell parameter-error id=WeeklyTriggerUtcBoundaryShift command=New-ScheduledTaskTrigger line={0} column={1}; -Weekly serializes -At as UTC (...Z) and shifts local 00:00-07:59 triggers across weekdays; assign $trigger.StartBoundary = "yyyy-MM-ddTHH:mm:ss" without trailing Z' -f
                    $command.Extent.StartLineNumber, $command.Extent.StartColumnNumber))
                exit 2
            }
        }
    }
    # Get-ItemPropertyValue throws a terminating PSArgumentException on missing registry values even with -ErrorAction Ignore/SilentlyContinue.
    if ($name -iin @('Get-ItemPropertyValue', 'gpv')) {
        $elements = @($command.CommandElements)
        for ($elIdx = 1; $elIdx -lt $elements.Count; $elIdx++) {
            $el = $elements[$elIdx]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                ('ErrorAction'.StartsWith($el.ParameterName, [StringComparison]::OrdinalIgnoreCase) -or $el.ParameterName -ieq 'ea')) {
                $valAst = if ($null -ne $el.Argument) { $el.Argument } elseif (($elIdx + 1) -lt $elements.Count) { $elIdx++; $elements[$elIdx] } else { $null }
                $valCur = Unwrap-SimpleAst $valAst
                $eaTokens = [Collections.Generic.List[string]]::new()
                if ($valCur -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $eaTokens.Add($valCur.Value)
                } elseif ($valCur -is [System.Management.Automation.Language.ConstantExpressionAst] -and $null -ne $valCur.Value) {
                    $eaTokens.Add([string]$valCur.Value)
                } elseif ($valCur -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $valCur.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $eaTokens.Add($valCur.Member.Value)
                }
                if (@($eaTokens | Where-Object { $_ -imatch '^(?:Ignore|SilentlyContinue|0|4)$' }).Count -gt 0) {
                    [Console]::Error.WriteLine(('CheckedPowerShell parameter-error id=GetItemPropertyValueIgnoresErrorAction command=Get-ItemPropertyValue line={0} column={1}; Get-ItemPropertyValue throws a terminating PSArgumentException on missing registry values even with -ErrorAction Ignore/SilentlyContinue; use (Get-ItemProperty -LiteralPath <key> -Name <name> -ErrorAction Ignore).PSObject.Properties["<name>"]?.Value' -f
                        $command.Extent.StartLineNumber, $command.Extent.StartColumnNumber))
                    exit 2
                }
            }
        }
    }
    # Analytic/Diagnostic event logs reject forward-reverse reads without -Oldest; FilterHashtable Id accepts <= 22 entries.
    if ($name -ieq 'Get-WinEvent') {
        if ($null -eq $winEventSingleAssignVars) {
            $assignCounts = @{}
            $assignExprs = @{}
            foreach ($asg in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                $lhs = $asg.Left
                while ($lhs -is [System.Management.Automation.Language.AttributedExpressionAst]) { $lhs = $lhs.Child }
                if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $lhs.VariablePath.IsDriveQualified) {
                    $k = ($lhs.VariablePath.UserPath -replace '^(?:global|local|script|private):', '').ToLowerInvariant()
                    $assignCounts[$k] = $(if ($assignCounts.ContainsKey($k)) { $assignCounts[$k] + 1 } else { 1 })
                    if ($asg.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals) {
                        $assignExprs[$k] = $asg.Right
                    } else {
                        $assignCounts[$k] = 2
                    }
                }
            }
            foreach ($feNode in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
                if ($null -ne $feNode.Variable) {
                    $k = ($feNode.Variable.VariablePath.UserPath -replace '^(?:global|local|script|private):', '').ToLowerInvariant()
                    $assignCounts[$k] = 2
                }
            }
            foreach ($prmNode in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
                if ($null -ne $prmNode.Name) {
                    $k = ($prmNode.Name.VariablePath.UserPath -replace '^(?:global|local|script|private):', '').ToLowerInvariant()
                    $assignCounts[$k] = 2
                }
            }
            $winEventSingleAssignVars = @{}
            foreach ($k in $assignCounts.Keys) {
                if ($assignCounts[$k] -eq 1 -and $assignExprs.ContainsKey($k)) {
                    $winEventSingleAssignVars[$k] = $assignExprs[$k]
                }
            }
        }
        $elements = @($command.CommandElements)
        $hasOldest = $false
        $logLiterals = [Collections.Generic.List[string]]::new()
        for ($elIdx = 1; $elIdx -lt $elements.Count; $elIdx++) {
            $el = $elements[$elIdx]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ('Oldest'.StartsWith($el.ParameterName, [StringComparison]::OrdinalIgnoreCase)) {
                    $argText = if ($null -ne $el.Argument) { $el.Argument.Extent.Text.Trim() } else { '' }
                    if ($argText -ine '$false' -and $argText -ne '0') { $hasOldest = $true }
                    continue
                }
                if ('LogName'.StartsWith($el.ParameterName, [StringComparison]::OrdinalIgnoreCase)) {
                    $valAst = if ($null -ne $el.Argument) { $el.Argument } elseif (($elIdx + 1) -lt $elements.Count) { $elIdx++; $elements[$elIdx] } else { $null }
                    if ($null -ne $valAst) {
                        foreach ($strNode in $valAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                            $logLiterals.Add($strNode.Value)
                        }
                    }
                    continue
                }
                if ('FilterHashtable'.StartsWith($el.ParameterName, [StringComparison]::OrdinalIgnoreCase)) {
                    $valAst = if ($null -ne $el.Argument) { $el.Argument } elseif (($elIdx + 1) -lt $elements.Count) { $elIdx++; $elements[$elIdx] } else { $null }
                    if ($null -ne $valAst) {
                        foreach ($ht in $valAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
                            foreach ($pair in $ht.KeyValuePairs) {
                                if ($pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                    if ($pair.Item1.Value -ieq 'LogName') {
                                        foreach ($strNode in $pair.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                                            $logLiterals.Add($strNode.Value)
                                        }
                                    } elseif ($pair.Item1.Value -ieq 'Id') {
                                        $idCount = Measure-StaticFilterIdCount $pair.Item2 $winEventSingleAssignVars
                                        if ($idCount -gt 22) {
                                            [Console]::Error.WriteLine(('CheckedPowerShell parameter-error id=WinEventFilterIdLimitExceeded command=Get-WinEvent line={0} column={1}; FilterHashtable Id accepts at most 22 values (got {2}), split into multiple queries' -f
                                                $command.Extent.StartLineNumber, $command.Extent.StartColumnNumber, $idCount))
                                            exit 2
                                        }
                                    }
                                }
                            }
                        }
                    }
                    continue
                }
            } elseif ($elIdx -eq 1 -and $el -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $logLiterals.Add($el.Value)
            }
        }
        if (-not $hasOldest -and @($logLiterals | Where-Object { $_ -imatch '/(?:Diagnostic|Analytic)$' }).Count -gt 0) {
            [Console]::Error.WriteLine(('CheckedPowerShell parameter-error id=AnalyticLogRequiresOldest command=Get-WinEvent line={0} column={1}; analytic/diagnostic event logs require -Oldest' -f
                $command.Extent.StartLineNumber, $command.Extent.StartColumnNumber))
            exit 2
        }
    }
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

# stdout stays whole when JSON fields are validated unless -TruncateValidatedJson is explicitly requested.
function Write-TargetOutput([string[]]$Trailer = @()) {
    $notes = [System.Collections.Generic.List[string]]::new()
    $shownStdout = if ($RequiredJsonFields.Count -and -not $TruncateValidatedJson) { $stdout } else { Limit-TargetStream $stdout 'stdout' $notes }
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
