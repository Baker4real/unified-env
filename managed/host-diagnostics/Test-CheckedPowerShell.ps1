#requires -Version 7.4
<#
.SYNOPSIS
Exercise Invoke-CheckedPowerShell through its public process interface.
#>
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/checked-powershell-tests')

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$fullEvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not $fullEvidenceRoot.StartsWith('D:\',[StringComparison]::OrdinalIgnoreCase)) { throw 'EvidenceRoot must resolve to D drive.' }
$fixture = Join-Path $fullEvidenceRoot ('CheckedPowerShell-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$wrapper = Join-Path $PSScriptRoot 'Invoke-CheckedPowerShell.ps1'
$cases = [System.Collections.Generic.List[object]]::new()

function Invoke-PublicCli {
    param([string[]]$CliArguments, [scriptblock]$AfterExit)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $PSHOME 'pwsh.exe'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $wrapper) + $CliArguments) {
        $psi.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            $null = $process.WaitForExit(5000)
            throw 'Public CLI exceeded its 15-second test timeout.'
        }
        # An inherited-handle fixture may also hold this controller's capture pipes.
        # Observe CLI exit and reclaim only its handshaken worker before draining them.
        if ($AfterExit) { & $AfterExit }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) {
            throw 'Public CLI exited but its test capture pipes did not close.'
        }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdout.GetAwaiter().GetResult()
            stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Assert-Case {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        $cases.Add([pscustomobject]@{ name = $Name; status = 'passed' })
    } catch {
        $cases.Add([pscustomobject]@{ name = $Name; status = 'failed'; reason = $_.Exception.Message })
    }
}

$marker = Join-Path $fixture 'CheckedPowerShell-syntax.executed'
$invalidPath = Join-Path $fixture 'CheckedPowerShell-invalid.ps1'
$invalidSource = @'
'synthetic-source-do-not-echo'
[IO.File]::WriteAllText('__MARKER__', 'ran')
foreach ($item in 1, 2) { $item } | ConvertTo-Json
'@.Replace('__MARKER__', $marker.Replace("'", "''"))
[IO.File]::WriteAllText($invalidPath, $invalidSource, $utf8)

Assert-Case 'syntax failure prevents side effects and redacts source' {
    $result = Invoke-PublicCli @('-ScriptPath', $invalidPath)
    if ($result.exitCode -ne 2) { throw "Expected syntax exit 2; received $($result.exitCode)." }
    if (Test-Path -LiteralPath $marker) { throw 'Invalid script executed a side effect.' }
    if ($result.stderr -notmatch 'EmptyPipeElement' -or $result.stderr -notmatch 'line=3 column=') {
        throw 'Syntax error did not include its id and location.'
    }
    if ($result.stdout -or $result.stderr.Contains('synthetic-source-do-not-echo') -or $result.stderr.Contains('[IO.File]')) {
        throw 'Syntax failure exposed source or stdout.'
    }
}

$argumentScript = Join-Path $fixture "CheckedPowerShell-合法 ' space.ps1"
[IO.File]::WriteAllText($argumentScript, @'
[pscustomobject]@{
    arguments = @($args)
    edition = $PSVersionTable.PSEdition
    major = $PSVersionTable.PSVersion.Major
    apartment = [Threading.Thread]::CurrentThread.GetApartmentState().ToString()
    scriptRoot = $PSScriptRoot
} | ConvertTo-Json -Compress
'@, $utf8)
Assert-Case 'script arguments preserve spaces commas Unicode dollars quotes and empty strings' {
    $expected = @('has space', 'a,b,c', '中文 🧪', '$literal', 'x"y', 'semi;colon', '')
    $result = Invoke-PublicCli (@('-ScriptPath', $argumentScript) + $expected)
    if ($result.exitCode -ne 0) { throw "Expected execution exit 0; received $($result.exitCode)." }
    $received = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    if ($received.arguments.Count -ne $expected.Count) { throw 'Argument count changed.' }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($received.arguments[$index] -cne $expected[$index]) { throw "Argument changed at index $index." }
    }
    if ($received.edition -ne 'Core' -or $received.major -ne 7) { throw 'Execution did not use Core 7.' }
    if ($received.apartment -ne 'STA') { throw 'Execution did not run in an STA thread.' }
    if ($received.scriptRoot -ne $fixture) { throw 'Target PSScriptRoot changed.' }
}

Assert-Case 'native nonzero exit is preserved and cannot be hidden by later output' {
    $command = @'
& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -Command 'exit 23'
'must-not-run-after-native-failure'
'@
    $result = Invoke-PublicCli @('-CommandText', $command)
    if ($result.exitCode -ne 23) { throw "Expected native exit 23; received $($result.exitCode)." }
    if ($result.stdout.Contains('must-not-run-after-native-failure')) { throw 'Execution continued after a native failure.' }
    if ($result.stderr -notmatch 'native-exit code=23') { throw 'Native failure status was not identifiable.' }
}

Assert-Case 'PowerShell execution errors report type and location without exception payloads' {
    $result = Invoke-PublicCli @('-CommandText', "`$null = 1; throw 'synthetic-exception-do-not-echo'")
    if ($result.exitCode -ne 1 -or $result.stderr -notmatch 'runtime-error type=System\.Management\.Automation\.RuntimeException category=OperationStopped script=- line=1 column=12') {
        throw 'Runtime failure was not reported with its type and location.'
    }
    if ($result.stderr.Contains('synthetic-exception-do-not-echo')) { throw 'Runtime failure exposed its exception payload.' }
    $failingScript = Join-Path $fixture 'CheckedPowerShell-runtime.ps1'
    [IO.File]::WriteAllText($failingScript, "`$null = 1`nfunction Invoke-Inner { Write-Error 'synthetic-exception-do-not-echo' }`nInvoke-Inner`n", $utf8)
    $result = Invoke-PublicCli @('-ScriptPath', $failingScript)
    if ($result.exitCode -ne 1 -or $result.stderr -notmatch 'runtime-error type=Microsoft\.PowerShell\.Commands\.WriteErrorException category=NotSpecified script=CheckedPowerShell-runtime\.ps1 line=2 column=-') {
        throw 'Runtime failure inside a script function was not located at its own line.'
    }
    if ($result.stderr.Contains('synthetic-exception-do-not-echo')) { throw 'Runtime failure exposed its exception payload.' }
}

Assert-Case 'inner exception diagnostics expose only types and numeric codes' {
    $command = '[IO.File]::ReadAllText(''D:/missing-synthetic-payload-do-not-echo/file.txt'')'
    $result = Invoke-PublicCli @('-CommandText', $command)
    if ($result.exitCode -ne 1 -or $result.stderr -notmatch 'innerType=System\.IO\.DirectoryNotFoundException hresult=-2147024893 nativeErrorCode=-') {
        throw 'The underlying filesystem error type and numeric HResult were not reported.'
    }
    if (($result.stderr + $result.stdout).Contains('synthetic-payload-do-not-echo')) { throw 'Filesystem error exposed its path payload.' }
    $command = 'throw [Reflection.TargetInvocationException]::new(''outer-synthetic-do-not-echo'', [ComponentModel.Win32Exception]::new(5, ''inner-synthetic-do-not-echo''))'
    $result = Invoke-PublicCli @('-CommandText', $command)
    if ($result.exitCode -ne 1 -or $result.stderr -notmatch 'innerType=System\.ComponentModel\.Win32Exception hresult=-?\d+ nativeErrorCode=5') {
        throw 'The underlying Win32 error code was not reported.'
    }
    if (($result.stderr + $result.stdout) -match 'synthetic-do-not-echo') { throw 'Nested exception messages were exposed.' }
}

Assert-Case 'required JSON fields reject missing null and the ordered dictionary projection failure' {
    $commands = @(
        '''{"other":"synthetic-payload-do-not-echo"}''',
        '''{"required":null,"other":"synthetic-payload-do-not-echo"}''',
        '[ordered]@{ required = ''synthetic-payload-do-not-echo'' } | Select-Object required | ConvertTo-Json',
        '''synthetic-payload-do-not-echo invalid JSON''',
        '''[{"required":1}]'''
    )
    foreach ($command in $commands) {
        $result = Invoke-PublicCli @('-CommandText', $command, '-RequiredJsonFields', 'required')
        if ($result.exitCode -ne 3) { throw "Expected JSON rejection exit 3; received $($result.exitCode)." }
        if ($result.stdout -or $result.stderr.Contains('synthetic-payload-do-not-echo')) { throw 'Rejected JSON payload was exposed.' }
        if ($result.stderr -notmatch 'json-error') { throw 'JSON rejection reason was not identifiable.' }
    }
}

Assert-Case 'required JSON fields accept false zero and a nested path' {
    foreach ($field in @('enabled', 'count', 'nested.name')) {
        $result = Invoke-PublicCli @('-CommandText', '''{"enabled":false,"count":0,"nested":{"name":"中文"}}''', '-RequiredJsonFields', $field)
        if ($result.exitCode -ne 0) { throw "Valid JSON was rejected for field $field." }
        $received = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
        if ($received.enabled -ne $false -or $received.count -ne 0 -or $received.nested.name -cne '中文') {
            throw 'Valid JSON values changed.'
        }
    }
}

Assert-Case 'required JSON fields accept native comma-separated argv values and identify the missing path' {
    $valid = Invoke-PublicCli @(
        '-CommandText', '''{"Status":"ok","Target":"x","Backup":"b"}''',
        '-RequiredJsonFields', 'Status,Target,Backup'
    )
    if ($valid.exitCode -ne 0) { throw "Comma-separated required fields were rejected: $($valid.stderr)" }
    $missing = Invoke-PublicCli @(
        '-CommandText', '''{"Status":"ok"}''',
        '-RequiredJsonFields', 'Status,Target'
    )
    if ($missing.exitCode -ne 3 -or $missing.stderr -notmatch 'field=Target') {
        throw "Missing field diagnostic did not identify Target: $($missing.stderr)"
    }
}

Assert-Case 'required JSON fields forward a failing target''s output and exit code' {
    $failingReport = Join-Path $fixture 'CheckedPowerShell-failing-report.ps1'
    [IO.File]::WriteAllText($failingReport, @'
[pscustomobject]@{ ok = $false; reason = 'synthetic-target-failure' } | ConvertTo-Json -Compress
[Console]::Error.Write('synthetic-target-stderr')
exit 4
'@, $utf8)
    $result = Invoke-PublicCli @('-ScriptPath', $failingReport, '-RequiredJsonFields', 'ok')
    if ($result.exitCode -ne 4) { throw "Expected target exit 4; received $($result.exitCode)." }
    $received = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    if ($received.ok -ne $false -or $received.reason -cne 'synthetic-target-failure') { throw 'The failing target''s report was not forwarded.' }
    if (-not $result.stderr.Contains('synthetic-target-stderr')) { throw 'The failing target''s stderr was not forwarded.' }
    if ($result.stderr -notmatch '(?m)^CheckedPowerShell target-exit code=4; JSON validation not performed\.') {
        throw 'Target failure status was not identifiable on its own line.'
    }
}

Assert-Case 'CheckOnly validates file and text without executing either' {
    $checkMarker = Join-Path $fixture 'CheckedPowerShell-check-only.executed'
    $checkSource = '[IO.File]::WriteAllText(''{0}'', ''ran'')' -f $checkMarker.Replace("'", "''")
    $checkPath = Join-Path $fixture 'CheckedPowerShell-check-only.ps1'
    [IO.File]::WriteAllText($checkPath, $checkSource, $utf8)
    foreach ($inputArguments in @(@('-ScriptPath', $checkPath), @('-CommandText', $checkSource))) {
        $result = Invoke-PublicCli ($inputArguments + '-CheckOnly')
        if ($result.exitCode -ne 0 -or (Test-Path -LiteralPath $checkMarker)) { throw 'CheckOnly executed valid input or failed parsing.' }
    }
    $invalid = Invoke-PublicCli @('-CommandText', $invalidSource, '-CheckOnly')
    if ($invalid.exitCode -ne 2 -or $invalid.stderr -notmatch 'EmptyPipeElement') { throw 'CheckOnly accepted invalid command text.' }
    if ($invalid.stderr.Contains('synthetic-source-do-not-echo') -or (Test-Path -LiteralPath $marker)) { throw 'Invalid text leaked or executed.' }
}

Assert-Case 'constant regex validation prevents execution and preserves simple match' {
    $regexMarker = Join-Path $fixture 'CheckedPowerShell-regex.executed'
    $invalidSource = @'
[IO.File]::WriteAllText('__MARKER__', 'ran')
'abc' -match 'miners\xmrig'
'@.Replace('__MARKER__', $regexMarker.Replace("'", "''"))
    $invalidPath = Join-Path $fixture 'CheckedPowerShell-invalid-regex.ps1'
    [IO.File]::WriteAllText($invalidPath, $invalidSource, $utf8)
    foreach ($inputArguments in @(@('-ScriptPath', $invalidPath), @('-CommandText', $invalidSource))) {
        $result = Invoke-PublicCli ($inputArguments + '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'regex-error' -or $result.stderr.Contains('miners')) {
            throw "CheckOnly did not safely reject the constant regex: exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
    $result = Invoke-PublicCli @('-ScriptPath', $invalidPath)
    if ($result.exitCode -ne 2 -or (Test-Path -LiteralPath $regexMarker) -or $result.stderr -notmatch 'regex-error') {
        throw 'Invalid regex ran a side effect or was not rejected before execution.'
    }
    $result = Invoke-PublicCli @('-CommandText', "Select-String -InputObject 'abc' -Pattern 'miners\xmrig'", '-CheckOnly')
    if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'regex-error') { throw 'Select-String constant regex was accepted.' }
    $result = Invoke-PublicCli @('-CommandText', "'abc' -match '^a'", '-CheckOnly')
    if ($result.exitCode -ne 0) { throw "Valid regex was rejected: $($result.stderr)" }
    $result = Invoke-PublicCli @('-CommandText', "Select-String -InputObject 'abc' -Pattern 'miners\xmrig' -SimpleMatch", '-CheckOnly')
    if ($result.exitCode -ne 0) { throw "SimpleMatch was incorrectly validated as regex: $($result.stderr)" }
}

Assert-Case 'built-in cmdlet parameter preflight rejects unresolvable sets and unknown names before execution' {
    $parameterMarker = Join-Path $fixture 'CheckedPowerShell-parameter.executed'
    $ambiguousPath = Join-Path $fixture 'CheckedPowerShell-ambiguous-set.ps1'
    $ambiguousSource = @'
[IO.File]::WriteAllText('__MARKER__', 'ran')
Split-Path -LiteralPath $synthetic_path_do_not_echo -Parent
'@.Replace('__MARKER__', $parameterMarker.Replace("'", "''"))
    [IO.File]::WriteAllText($ambiguousPath, $ambiguousSource, $utf8)
    $result = Invoke-PublicCli @('-ScriptPath', $ambiguousPath)
    if ($result.exitCode -ne 2 -or (Test-Path -LiteralPath $parameterMarker) -or
        $result.stderr -notmatch 'parameter-error id=AmbiguousParameterSet command=Split-Path line=2 column=1') {
        throw "Ambiguous parameter set was not rejected before execution: exit=$($result.exitCode) stderr=$($result.stderr)"
    }
    if ($result.stdout -or $result.stderr.Contains('synthetic_path_do_not_echo')) { throw 'Parameter rejection exposed source.' }
    foreach ($typo in @('Get-ChildItem -Recurce', 'gci -Recurce')) {
        $result = Invoke-PublicCli @('-CommandText', $typo, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=NamedParameterNotFound command=Get-ChildItem') {
            throw "Unknown parameter was accepted: $typo exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
}

Assert-Case 'parameter preflight passes provider dynamic parameters splats local functions and other commands' {
    # The registry verb is split: the pretool guard scans this file when pwsh -File runs it.
    $valid = @(
        'Get-Content -LiteralPath $f -Raw -Encoding utf8',
        'Get-ChildItem -LiteralPath $d -File -Attributes !ReparsePoint',
        'Set-Content -LiteralPath $f -Value 1 -NoNewline',
        ('New-Item' + 'Property -LiteralPath $k -Name a -Value 1 -PropertyType DWord'),
        '$p = @{ Parent = $true }; Split-Path @p -LiteralPath $f',
        'Split-Path -Path $f -Leaf; git status --short; Get-WinEvent -LogName System -MaxEvents 1'
    ) -join "`n"
    foreach ($source in @($valid, 'function Split-Path { param($LiteralPath, [switch]$Parent) }; Split-Path -LiteralPath x -Parent')) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) { throw "Valid calls were rejected: exit=$($result.exitCode) stderr=$($result.stderr)" }
    }
}

Assert-Case 'gh json preflight rejects a bare field array before execution without exposing source' {
    $nativeMarker = Join-Path $fixture 'CheckedPowerShell-gh-json.executed'
    $nativeSource = @'
[IO.File]::WriteAllText('__MARKER__', 'ran')
gh issue view 161 --json number,title,body
'@.Replace('__MARKER__', $nativeMarker.Replace("'", "''"))
    $nativePath = Join-Path $fixture 'CheckedPowerShell-gh-json.ps1'
    [IO.File]::WriteAllText($nativePath, $nativeSource, $utf8)
    foreach ($inputArguments in @(@('-CommandText', $nativeSource, '-CheckOnly'), @('-ScriptPath', $nativePath))) {
        $result = Invoke-PublicCli $inputArguments
        if ($result.exitCode -ne 2 -or (Test-Path -LiteralPath $nativeMarker) -or
            $result.stderr -notmatch 'native-argument-error command=gh parameter=--json reason=bare-comma-array line=2 column=26') {
            throw "Bare gh JSON fields were not rejected: exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('number,title,body')) { throw 'Native argument rejection exposed source.' }
    }
}

Assert-Case 'gh json preflight accepts single string fields and leaves other native commands alone' {
    $valid = @(
        "gh issue view 161 --json 'number,title,body'",
        'gh issue view 161 --json $issueFields',
        'gh issue view 161 --json number',
        '& gh issue view 161 --json ''number,title''',
        'custom-cli --json number,title,body'
    )
    foreach ($source in $valid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) { throw "Valid native command was rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)" }
    }
}

Assert-Case 'rg -e preflight rejects argv-changing escaped quotes before execution' {
    $nativeMarker = Join-Path $fixture 'CheckedPowerShell-rg-quotes.executed'
    $invalidSource = @'
[IO.File]::WriteAllText('__MARKER__', 'ran')
rg -n -e "Grid.SetRowSpan(actions, 3)|VerticalAlignment=\"Center\"" src/MinminCountdown
'@.Replace('__MARKER__', $nativeMarker.Replace("'", "''"))
    $nativePath = Join-Path $fixture 'CheckedPowerShell-rg-quotes.ps1'
    [IO.File]::WriteAllText($nativePath, $invalidSource, $utf8)
    foreach ($inputArguments in @(@('-CommandText', $invalidSource, '-CheckOnly'), @('-ScriptPath', $nativePath))) {
        $result = Invoke-PublicCli $inputArguments
        if ($result.exitCode -ne 2 -or (Test-Path -LiteralPath $nativeMarker) -or
            $result.stderr -notmatch 'native-argument-error command=rg reason=escaped-quote-native-argv') {
            throw "Argv-changing rg quotes were not rejected: exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('Grid.SetRowSpan')) { throw 'Native argument rejection exposed source.' }
    }
}

Assert-Case 'rg -e preflight accepts single quoted patterns and commands without -e' {
    $valid = @(@'
rg -n -e 'Grid.SetRowSpan\(actions, 3\)|VerticalAlignment=\"Center\"' src/MinminCountdown
'@, @'
rg -e 'MinHeight = 39' src/MinminCountdown
'@, 'rg -n "Grid.SetRowSpan(actions, 3)" src/MinminCountdown', 'custom-cli -e "VerticalAlignment=\"Center\"" src')
    foreach ($source in $valid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) { throw "Valid native command was rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)" }
    }
}

Assert-Case 'rg wildcard absolute search paths are rejected before any side effect' {
    $nativeMarker = Join-Path $fixture 'CheckedPowerShell-rg-path.executed'
    $invalidSource = @'
[IO.File]::WriteAllText('__MARKER__', 'ran')
rg -n -i -e 'viewSchema|failed to project session' D:/synthetic-private-path/DeepSeek*
'@.Replace('__MARKER__', $nativeMarker.Replace("'", "''"))
    $nativePath = Join-Path $fixture 'CheckedPowerShell-rg-path.ps1'
    [IO.File]::WriteAllText($nativePath, $invalidSource, $utf8)
    foreach ($inputArguments in @(@('-CommandText', $invalidSource, '-CheckOnly'), @('-ScriptPath', $nativePath))) {
        $result = Invoke-PublicCli $inputArguments
        if ($result.exitCode -ne 2 -or (Test-Path -LiteralPath $nativeMarker) -or
            $result.stderr -notmatch 'native-argument-error command=rg reason=unexpanded-wildcard-path line=2 column=') {
            throw "Wildcard rg path was not rejected before execution: exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('synthetic-private-path') -or $result.stderr.Contains('viewSchema')) {
            throw 'Wildcard path rejection exposed source.'
        }
    }
}

Assert-Case 'rg path classification handles positional patterns files mode and option values' {
    $invalid = @(
        "rg 'pattern' 'D:/synthetic*'",
        "rg --regexp=pattern 'D:/synthetic?'",
        "rg --files 'D:/synthetic*'",
        "rg -nHefoo 'D:/synthetic*'",
        "rg -C 3 -g '*.md' -n 'pattern' 'D:/synthetic*'",
        '& "D:/synthetic/rg.exe" -e pattern D:/synthetic*',
        "rg --files -- '\\server\share\synthetic*'",
        "rg --file D:/patterns.txt D:/synthetic*",
        "rg D:/synthetic* -e pattern"
    )
    foreach ($source in $invalid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'reason=unexpanded-wildcard-path') {
            throw "Wildcard search path was not rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
}

Assert-Case 'rg glob regexp and unresolved argv are not mistaken for search paths' {
    $valid = @(
        "rg -g 'D:/*.md' -e 'D:/regexp*' D:/source",
        "rg --glob=D:/*.md --regexp=D:/regexp* D:/source",
        "rg -gD:/*.md -eD:/regexp* D:/source",
        "rg 'D:/regexp*' D:/source",
        "rg -- 'D:/regexp*' D:/source",
        "rg --files -g '*.md' D:/source",
        "rg -nHC3 'pattern' D:/source",
        'rg --files ''\\?\D:\source''',
        'rg -e pattern $paths',
        'rg $pattern D:/synthetic*',
        'rg @rgArguments D:/synthetic*',
        'rg --future-option D:/synthetic*',
        'rg --help D:/synthetic*',
        'function rg { param($Pattern, $Path) }; rg pattern D:/synthetic*',
        'custom-cli -e pattern D:/synthetic*'
    )
    foreach ($source in $valid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) {
            throw "Valid or unresolved argv was rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
}

Assert-Case 'rg without search path or upstream pipeline is rejected before execution' {
    $nativeMarker = Join-Path $fixture 'CheckedPowerShell-rg-missing-path.executed'
    $invalidSource = @'
[IO.File]::WriteAllText('__MARKER__', 'ran')
rg -n 'synthetic-pattern-do-not-echo'
'@.Replace('__MARKER__', $nativeMarker.Replace("'", "''"))
    $nativePath = Join-Path $fixture 'CheckedPowerShell-rg-missing-path.ps1'
    [IO.File]::WriteAllText($nativePath, $invalidSource, $utf8)
    foreach ($inputArguments in @(@('-CommandText', $invalidSource, '-CheckOnly'), @('-ScriptPath', $nativePath))) {
        $result = Invoke-PublicCli $inputArguments
        if ($result.exitCode -ne 2 -or (Test-Path -LiteralPath $nativeMarker) -or
            $result.stderr -notmatch 'native-argument-error command=rg reason=missing-rg-target-path line=2 column=1') {
            throw "Bare rg without search path was not rejected: exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('synthetic-pattern-do-not-echo')) {
            throw 'Missing-path rejection exposed source.'
        }
    }
    $invalid = @(
        "rg 'pattern'",
        "rg -n -g '*.md' 'pattern'",
        "rg -e 'pattern'",
        "rg -f D:/patterns.txt",
        "rg -n 'pattern' | Select-Object -First 5",
        "rg -- 'pattern'"
    )
    foreach ($source in $invalid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'reason=missing-rg-target-path') {
            throw "Bare rg invocation was not rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
    $valid = @(
        "rg -n 'pattern' .",
        "rg -e 'pattern' .",
        "rg -n 'pattern' -",
        "'abc' | rg -n 'a'",
        "Get-Content a.txt | rg -e 'a' | Select-Object -First 1",
        "rg --files",
        "rg --version",
        "rg -V",
        "rg --help",
        "rg -h",
        "rg --type-list",
        'rg -e pattern $paths',
        'function rg { param($Pattern) }; rg pattern'
    )
    foreach ($source in $valid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) {
            throw "Valid rg invocation was rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
}

Assert-Case 'gh issue view rejects mutually exclusive comments and json before execution' {
    $nativeMarker = Join-Path $fixture 'CheckedPowerShell-gh-comments-json.executed'
    $nativeSource = @'
[IO.File]::WriteAllText('__MARKER__', 'ran')
gh issue view 252 --comments --json number,title,comments
'@.Replace('__MARKER__', $nativeMarker.Replace("'", "''"))
    $result = Invoke-PublicCli @('-CommandText', $nativeSource, '-CheckOnly')
    if ($result.exitCode -ne 2 -or (Test-Path -LiteralPath $nativeMarker) -or
        $result.stderr -notmatch 'native-argument-error command=gh reason=comments-json-mutually-exclusive') {
        throw "Mutually exclusive gh arguments were not rejected: exit=$($result.exitCode) stderr=$($result.stderr)"
    }
    $valid = @(
        "gh issue view 252 --json 'number,title,comments'",
        'gh issue view 252 --comments',
        'gh pr view 252 --comments --json comments',
        'gh issue list --json comments'
    )
    foreach ($source in $valid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) { throw "Valid gh command was rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)" }
    }
}

Assert-Case 'gh repo view rejects gh search repos json field names before execution' {
    $invalid = @(
        "gh repo view cemu-project/Cemu --json 'nameWithOwner,stargazersCount,licenseInfo'",
        "gh -R cemu-project/Cemu repo view --json 'forksCount,url'",
        "gh repo view cemu-project/Cemu --json 'license,pushedAt'",
        "gh repo view cemu-project/Cemu --json 'fullName,url'"
    )
    foreach ($source in $invalid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'native-argument-error command=gh parameter=--json reason=gh-repo-view-invalid-json-field') {
            throw "Invalid gh repo view --json field was not rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
    $valid = @(
        "gh repo view cemu-project/Cemu --json 'nameWithOwner,stargazerCount,forkCount,licenseInfo,url'",
        "gh search repos 'cemu' --json 'fullName,stargazersCount,forksCount,license,url'"
    )
    foreach ($source in $valid) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) { throw "Valid gh repo/search --json command was rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)" }
    }
}

Assert-Case 'oversized output shows head and tail and spills the whole stream' {
    $spill = Join-Path $fixture 'spill'
    $generator = '-join (0..17999 | ForEach-Object { [char](65 + ($_ % 26)) })'
    $expected = Invoke-Expression $generator
    $result = Invoke-PublicCli @('-CommandText', "[Console]::Out.Write($generator)", '-MaxOutputChars', '3000', '-SpillDirectory', $spill)
    $note = [regex]::Match($result.stderr, 'CheckedPowerShell output-truncated stream=stdout shown=3000 total=18000 path=(?<path>.+?)\r?$', 'Multiline')
    if ($result.exitCode -ne 0 -or -not $note.Success) { throw "Truncation note missing: exit=$($result.exitCode) stderr=$($result.stderr)" }
    if (-not $result.stdout.StartsWith($expected.Substring(0, 2000)) -or -not $result.stdout.EndsWith($expected.Substring(17000)) -or
        -not $result.stdout.Contains('[CheckedPowerShell output-truncated: 15000 chars omitted]')) {
        throw 'Truncated stdout lost its head, its tail or the omission marker.'
    }
    if ([IO.File]::ReadAllText($note.Groups['path'].Value, $utf8) -cne $expected) { throw 'Spill file does not hold the whole stdout.' }
    $result = Invoke-PublicCli @('-CommandText', "[Console]::Out.Write($generator)", '-MaxOutputChars', '0', '-SpillDirectory', $spill)
    if ($result.stdout -cne $expected -or $result.stderr) { throw 'MaxOutputChars 0 did not pass the output through whole.' }
    $result = Invoke-PublicCli @('-CommandText', "[Console]::Error.Write('e' * 5000)", '-MaxOutputChars', '1000', '-SpillDirectory', $spill)
    if ($result.stderr -notmatch 'output-truncated stream=stderr shown=1000 total=5000 path=') { throw 'Oversized stderr was not truncated.' }
    $result = Invoke-PublicCli @('-CommandText', '[pscustomobject]@{ data = (''x'' * 5000) } | ConvertTo-Json -Compress', '-RequiredJsonFields', 'data', '-MaxOutputChars', '1000', '-SpillDirectory', $spill)
    if ($result.exitCode -ne 0 -or (ConvertFrom-Json -InputObject $result.stdout).data.Length -ne 5000 -or $result.stderr) {
        throw 'Validated JSON stdout was truncated.'
    }
    $quiet = Join-Path $fixture 'spill-unused'
    $result = Invoke-PublicCli @('-CommandText', 'Write-Output ok', '-MaxOutputChars', '1000', '-SpillDirectory', $quiet)
    if ($result.stdout.Trim() -cne 'ok' -or $result.stderr -or (Test-Path -LiteralPath $quiet)) { throw 'Small output was altered or spilled.' }
}

Assert-Case 'script and command input are mutually exclusive' {
    $result = Invoke-PublicCli @('-ScriptPath', $argumentScript, '-CommandText', '''must-not-run''')
    if ($result.exitCode -eq 0 -or $result.stdout) { throw 'Ambiguous input was accepted.' }
}

Assert-Case 'file input must use PowerShell script execution semantics' {
    $otherLanguagePath = Join-Path $fixture 'CheckedPowerShell-not-a-script.cmd'
    [IO.File]::WriteAllText($otherLanguagePath, 'echo synthetic-other-interpreter', $utf8)
    $result = Invoke-PublicCli @('-ScriptPath', $otherLanguagePath)
    if ($result.exitCode -ne 2 -or $result.stdout) { throw 'A non-ps1 file was executed after PowerShell parsing.' }
}

Assert-Case 'timeout terminates the owned child and returns 124' {
    $pidPath = Join-Path $fixture 'CheckedPowerShell-timeout.pid'
    $timeoutSource = '[IO.File]::WriteAllText(''{0}'', [string]$PID); Start-Sleep -Seconds 30' -f $pidPath.Replace("'", "''")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-PublicCli @('-CommandText', $timeoutSource, '-TimeoutSeconds', '1')
    if ($result.exitCode -ne 124 -or $result.stderr -notmatch 'timeout') { throw 'Timeout was not reported with exit 124.' }
    if ($watch.Elapsed.TotalSeconds -ge 10) { throw 'Timeout did not return within its bounded cleanup window.' }
    if (-not (Test-Path -LiteralPath $pidPath)) { throw 'Timeout fixture never entered target execution.' }
    $ownedPid = [int][IO.File]::ReadAllText($pidPath)
    if (Get-Process -Id $ownedPid -ErrorAction SilentlyContinue) { throw 'Owned target child survived timeout.' }
}

Assert-Case 'exited target with inherited output reports unsafe retry while the owned worker remains ready' {
    $ownerToken = [guid]::NewGuid().ToString('N')
    $ownerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($ownerToken)))
    $readyPath = Join-Path $fixture 'CheckedPowerShell-worker-ready.json'
    $stopPath = Join-Path $fixture 'CheckedPowerShell-worker-stop.txt'
    $exitPath = Join-Path $fixture 'CheckedPowerShell-worker-exit.json'
    $launchPath = Join-Path $fixture 'CheckedPowerShell-worker-launch.json'
    $workerPath = Join-Path $fixture 'CheckedPowerShell-worker.ps1'
    $parentPath = Join-Path $fixture 'CheckedPowerShell-launch-worker.ps1'
    [IO.File]::WriteAllText($workerPath, @'
param($OwnerToken, $ReadyPath, $StopPath, $ExitPath)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$self = Get-Process -Id $PID
$parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
$ownerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($OwnerToken)))
$ready = [ordered]@{
    ownerTokenSha256 = $ownerHash; processId = $PID; parentProcessId = $parentId
    startTimeUtcTicks = $self.StartTime.ToUniversalTime().Ticks; executable = $self.Path
    ready = $true
}
[IO.File]::WriteAllText($ReadyPath, ($ready | ConvertTo-Json -Compress), $utf8)
[Console]::Out.WriteLine('synthetic-worker-output-do-not-echo')
$deadline = [Diagnostics.Stopwatch]::StartNew()
$gracefulStop = $false
while ($deadline.Elapsed.TotalSeconds -lt 20) {
    if ([IO.File]::Exists($StopPath) -and [IO.File]::ReadAllText($StopPath) -ceq $ownerHash) {
        $gracefulStop = $true
        break
    }
    Start-Sleep -Milliseconds 25
}
$receipt = [ordered]@{ ownerTokenSha256 = $ownerHash; processId = $PID; gracefulStop = $gracefulStop; exitCode = 0 }
[IO.File]::WriteAllText($ExitPath, ($receipt | ConvertTo-Json -Compress), $utf8)
exit 0
'@, $utf8)
    [IO.File]::WriteAllText($parentPath, @'
param($WorkerPath, $OwnerToken, $ReadyPath, $StopPath, $ExitPath, $LaunchPath)
$utf8 = [Text.UTF8Encoding]::new($false)
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $PSHOME 'pwsh.exe'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
# Deliberately inherit the target's stdout/stderr. This reproduces the reported failure.
foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $WorkerPath, $OwnerToken, $ReadyPath, $StopPath, $ExitPath)) {
    $psi.ArgumentList.Add($arg)
}
$worker = [Diagnostics.Process]::Start($psi)
try {
    $launch = [ordered]@{
        processId = $worker.Id; parentProcessId = $PID
        startTimeUtcTicks = $worker.StartTime.ToUniversalTime().Ticks; executable = $psi.FileName
    }
    [IO.File]::WriteAllText($LaunchPath, ($launch | ConvertTo-Json -Compress), $utf8)
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($ReadyPath) -and $deadline.Elapsed.TotalSeconds -lt 5 -and -not $worker.HasExited) {
        Start-Sleep -Milliseconds 25
    }
    if (-not [IO.File]::Exists($ReadyPath)) { throw 'Owned worker did not become ready.' }
} finally { $worker.Dispose() }
exit 0
'@, $utf8)
    $launchIntent = [ordered]@{
        ownershipMode = 'task-scoped'; ownerTokenSha256 = $ownerHash
        ownerTokenIssuedUtc = [DateTime]::UtcNow.ToString('o'); ownerTokenChannel = 'isolated worker argv'
        task = 'checked-powershell-inherited-output'; workingDirectory = $PWD.ProviderPath
        executable = Join-Path $PSHOME 'pwsh.exe'; script = $workerPath
        readiness = 'matching owner handshake and process identity'; readinessTimeoutSeconds = 5
        expectedExitCode = 0; lifetimeSeconds = 20; gracefulStopTimeoutSeconds = 5
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'CheckedPowerShell-worker-intent.json'), ($launchIntent | ConvertTo-Json), $utf8)
    $result = Invoke-PublicCli -CliArguments @('-ScriptPath', $parentPath, $workerPath, $ownerToken, $readyPath, $stopPath, $exitPath, $launchPath) -AfterExit {
        $ownedWorker = $null
        $ownershipVerified = $false
        try {
            if (-not [IO.File]::Exists($readyPath) -or -not [IO.File]::Exists($launchPath)) { throw 'Owned worker handshake is missing.' }
            $ready = [IO.File]::ReadAllText($readyPath) | ConvertFrom-Json
            $launch = [IO.File]::ReadAllText($launchPath) | ConvertFrom-Json
            $ownedWorker = [Diagnostics.Process]::GetProcessById([int]$ready.processId)
            # Retain the OS handle so exit-code evidence survives process termination.
            $null = $ownedWorker.Handle
            if ($ready.ownerTokenSha256 -cne $ownerHash -or -not $ready.ready -or
                $ready.processId -ne $launch.processId -or $ready.parentProcessId -ne $launch.parentProcessId -or
                $ready.startTimeUtcTicks -ne $launch.startTimeUtcTicks -or
                $ownedWorker.StartTime.ToUniversalTime().Ticks -ne $ready.startTimeUtcTicks -or
                $ownedWorker.MainModule.FileName -ine $ready.executable -or $ready.executable -ine $launch.executable) {
                $ownedWorker.Dispose()
                $ownedWorker = $null
                throw 'Owned worker identity or owner token changed; no control action is allowed.'
            }
            $ownershipVerified = $true
        } finally {
            if ($null -ne $ownedWorker) {
                try {
                    if ($ownershipVerified) {
                        [IO.File]::WriteAllText($stopPath, $ownerHash, $utf8)
                        if (-not $ownedWorker.WaitForExit(5000)) {
                            $ownedWorker.Kill()
                            $null = $ownedWorker.WaitForExit(5000)
                            throw 'Owned worker did not stop gracefully within its declared budget.'
                        }
                        $receipt = [IO.File]::ReadAllText($exitPath) | ConvertFrom-Json
                        if ($receipt.ownerTokenSha256 -cne $ownerHash -or $receipt.processId -ne $ownedWorker.Id -or
                            -not $receipt.gracefulStop -or $receipt.exitCode -ne 0 -or $ownedWorker.ExitCode -ne 0) {
                            throw 'Owned worker shutdown was not proven.'
                        }
                        $closed = [ordered]@{
                            ownerTokenSha256 = $ownerHash; identity = $ready; processState = 'stopped'
                            wasReadyAfterCliExit = $true; exitCode = $ownedWorker.ExitCode
                        }
                        [IO.File]::WriteAllText((Join-Path $fixture 'CheckedPowerShell-worker-stopped.json'), ($closed | ConvertTo-Json -Depth 4), $utf8)
                    }
                } finally { $ownedWorker.Dispose() }
            }
        }
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'CheckedPowerShell-worker-cli.json'), ($result | ConvertTo-Json), $utf8)
    if ($result.exitCode -ne 124 -or $result.stderr -notmatch 'redirected output did not close; descendants may remain') {
        throw 'Inherited output did not preserve the synchronous timeout contract.'
    }
    if ($result.stderr -notmatch 'targetExited=true targetExitCode=0 outputClosed=false descendantsMayRemain=true retrySafe=false') {
        throw 'Timeout did not distinguish an exited target from a stopped service or a safe retry.'
    }
    if ($result.stdout -or $result.stderr.Contains('synthetic-worker-output-do-not-echo')) { throw 'An incomplete output stream was exposed.' }
}

Assert-Case 'python -c preflight rejects single-quoted escaped quotes and multiline inline code without exposing source' {
    $invalidCases = @(
        @{
            Source = @'
python -c 'print(\"PRIVATE-PY-SENTINEL\")'
'@
            Reason = 'single-quoted-backslash-quote'
        },
        @{
            Source = @'
python -c 'import sys
print("PRIVATE-PY-SENTINEL")'
'@
            Reason = 'multiline-inline-python'
        },
        @{
            Source = @'
python3 -c "import os
print('PRIVATE-PY-SENTINEL')"
'@
            Reason = 'multiline-inline-python'
        }
    )
    foreach ($case in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $case.Source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch ('native-argument-error command=python parameter=-c reason=' + $case.Reason)) {
            throw "Inline python hazard was not rejected ($($case.Reason)): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('PRIVATE-PY-SENTINEL')) { throw 'Python preflight rejection exposed source.' }
    }
    $validCases = @(
        @'
python -c 'print(1 + 1)'
'@,
        @'
python -c "import sys; print(sys.version)"
'@,
        ("@'`nimport json`nprint(json.dumps({'ok': True}))`n'@ | python -")
    )
    foreach ($source in $validCases) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 0) { throw "Valid python command was rejected: $source exit=$($result.exitCode) stderr=$($result.stderr)" }
    }
}

Assert-Case 'gh api piped into file-writing python -c is rejected while read-only pipe passes' {
    $invalid = @'
gh api 'repos/owner/repo/contents/a.go' --jq '.content' | python -c "import sys,base64; open('PRIVATE-OUT.go','wb').write(base64.b64decode(sys.stdin.read()))"
'@
    $result = Invoke-PublicCli @('-CommandText', $invalid, '-CheckOnly')
    if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'native-argument-error command=gh reason=unguarded-pipe-write') {
        throw "Unguarded gh api pipe write was not rejected: exit=$($result.exitCode) stderr=$($result.stderr)"
    }
    if ($result.stdout -or $result.stderr.Contains('PRIVATE-OUT.go')) { throw 'gh pipe rejection exposed source.' }
    $valid = @'
gh api 'repos/owner/repo/releases/latest' | python -c 'import sys,json; print(len(json.load(sys.stdin)))'
'@
    $ok = Invoke-PublicCli @('-CommandText', $valid, '-CheckOnly')
    if ($ok.exitCode -ne 0) { throw "Read-only gh api pipe was rejected: exit=$($ok.exitCode) stderr=$($ok.stderr)" }
}

Assert-Case 'preflight rejects writes to AllScope read-only automatic variables while allowing env, properties and discard' {
    $invalidCases = @(
        @{ Source = '$pId = 42; "PRIVATE-AUTO-SENTINEL"'; Canonical = '$PID' },
        @{ Source = '[int]$pid = 42'; Canonical = '$PID' },
        @{ Source = 'foreach ($Home in @("a")) { $Home }'; Canonical = '$HOME' },
        @{ Source = 'function Test-Shadow([string]$host) { $host }'; Canonical = '$Host' },
        @{ Source = 'param([bool]$isWindows)'; Canonical = '$IsWindows' },
        @{ Source = '$script:psHome = "x"'; Canonical = '$PSHOME' }
    )
    foreach ($case in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $case.Source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=ReadOnlyAutomaticVariable' -or -not $result.stderr.Contains("command=$($case.Canonical) ")) {
            throw "Read-only automatic variable write was not rejected ($($case.Source)): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('PRIVATE-AUTO-SENTINEL')) {
            throw 'Automatic variable rejection exposed source.'
        }
    }
    $validCases = @(
        '$env:HOME = "D:/tmp"',
        '$obj = @{ pid = 1; home = "x" }; $obj.pid = 2',
        '$null = "discard"',
        '$error = "local-ok"',
        '$procId = $PID'
    )
    foreach ($source in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($ok.exitCode -ne 0) { throw "Valid variable usage was rejected ($source): exit=$($ok.exitCode) stderr=$($ok.stderr)" }
    }
}

Assert-Case 'preflight rejects Get-WinEvent on Diagnostic/Analytic logs without -Oldest' {
    $invalidCases = @(
        'Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-Dwm-Core/Diagnostic" }',
        'Get-WinEvent -LogName "Microsoft-Windows-Kernel-Power/Analytic" -MaxEvents 5',
        'Get-WinEvent "Microsoft-Windows-Dwm-Core/Diagnostic" -MaxEvents 5',
        'Get-WinEvent -LogName "Microsoft-Windows-Dwm-Core/Diagnostic" -Oldest:$false'
    )
    foreach ($source in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=AnalyticLogRequiresOldest command=Get-WinEvent') {
            throw "Diagnostic/Analytic Get-WinEvent without -Oldest was not rejected ($source): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
    }
    $validCases = @(
        'Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-Dwm-Core/Diagnostic" } -Oldest -MaxEvents 5',
        'Get-WinEvent -LogName "Microsoft-Windows-Kernel-Power/Analytic" -Oldest',
        'Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-Storage-ClassPnP/Operational" } -MaxEvents 5',
        'Get-WinEvent -LogName "System" -MaxEvents 5'
    )
    foreach ($source in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($ok.exitCode -ne 0) { throw "Valid Get-WinEvent was rejected ($source): exit=$($ok.exitCode) stderr=$($ok.stderr)" }
    }
}

Assert-Case 'preflight rejects Get-WinEvent FilterHashtable Id arrays over 22 entries' {
    $invalidCases = @(
        'Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = @(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24) }; "WINEVENT-SECRET-SENTINEL"',
        'Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23 }',
        'Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = (1..25) }',
        '$powerIds = @(12,13,41,42,86,88,107,109,172,187,506,507,1001,1015,1074,1076,6005,6006,6008,6009,6013,46,161,162); Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = $powerIds }'
    )
    foreach ($source in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=WinEventFilterIdLimitExceeded command=Get-WinEvent') {
            throw "Oversized FilterHashtable Id was not rejected ($source): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('WINEVENT-SECRET-SENTINEL')) {
            throw 'Oversized FilterHashtable Id rejection exposed source.'
        }
    }
    $validCases = @(
        'Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 41 }',
        'Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = @(1..22) }',
        '$powerIds = @(1..22); Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = $powerIds }',
        '$ids = @(1..30); $ids = @(1, 2, 3); Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = $ids }'
    )
    foreach ($source in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($ok.exitCode -ne 0) { throw "Valid FilterHashtable Id was rejected ($source): exit=$($ok.exitCode) stderr=$($ok.stderr)" }
    }
}

Assert-Case 'TruncateValidatedJson validates full JSON before spilling and truncating stdout' {
    $spill = Join-Path $fixture 'spill-validated-json'
    $result = Invoke-PublicCli @(
        '-CommandText', '[pscustomobject]@{ status = "ok"; data = ("z" * 5000) } | ConvertTo-Json -Compress',
        '-RequiredJsonFields', 'status,data',
        '-TruncateValidatedJson',
        '-MaxOutputChars', '1000',
        '-SpillDirectory', $spill
    )
    $note = [regex]::Match($result.stderr, 'CheckedPowerShell output-truncated stream=stdout shown=1000 total=(?<total>\d+) path=(?<path>.+?)\r?$', 'Multiline')
    if ($result.exitCode -ne 0 -or -not $note.Success -or -not $result.stdout.Contains('[CheckedPowerShell output-truncated:')) {
        throw "TruncateValidatedJson did not truncate valid oversized JSON: exit=$($result.exitCode) stderr=$($result.stderr)"
    }
    $spilledObj = [IO.File]::ReadAllText($note.Groups['path'].Value, $utf8) | ConvertFrom-Json -ErrorAction Stop
    if ($spilledObj.status -cne 'ok' -or $spilledObj.data.Length -ne 5000) {
        throw 'Spilled validated JSON did not retain full valid object.'
    }
    $badSpill = Join-Path $fixture 'spill-invalid-json'
    $bad = Invoke-PublicCli @(
        '-CommandText', '[pscustomobject]@{ other = ("z" * 5000) } | ConvertTo-Json -Compress',
        '-RequiredJsonFields', 'status',
        '-TruncateValidatedJson',
        '-MaxOutputChars', '1000',
        '-SpillDirectory', $badSpill
    )
    if ($bad.exitCode -ne 3 -or $bad.stdout -or (Test-Path -LiteralPath $badSpill)) {
        throw "Failed JSON validation under -TruncateValidatedJson leaked stdout or created spill file: exit=$($bad.exitCode)"
    }
}

Assert-Case 'preflight rejects New-ScheduledTaskTrigger -Weekly without local StartBoundary override' {
    $invalidCases = @(
        'New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At "02:00"; "WEEKLY-SECRET-SENTINEL"',
        '$t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At "02:00"; Register-ScheduledTask -TaskName "Demo" -Trigger $t',
        '$t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At "02:00"; $t.StartBoundary = "2026-11-28T18:00:00Z"'
    )
    foreach ($source in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=WeeklyTriggerUtcBoundaryShift command=New-ScheduledTaskTrigger') {
            throw "Unoverridden New-ScheduledTaskTrigger -Weekly was not rejected ($source): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('WEEKLY-SECRET-SENTINEL')) {
            throw 'Weekly trigger rejection exposed source.'
        }
    }
    $validCases = @(
        '$t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At "02:00"; $t.StartBoundary = "2026-11-28T02:00:00"',
        '$boundary = "2026-11-28T02:00:00"; $t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At "02:00"; $t.StartBoundary = $boundary',
        'New-ScheduledTaskTrigger -Daily -At "02:00"',
        'New-ScheduledTaskTrigger -AtLogOn'
    )
    foreach ($source in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($ok.exitCode -ne 0) { throw "Valid ScheduledTaskTrigger was rejected ($source): exit=$($ok.exitCode) stderr=$($ok.stderr)" }
    }
}

Assert-Case 'preflight rejects Get-ItemPropertyValue with -ErrorAction Ignore or SilentlyContinue' {
    $invalidCases = @(
        'Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -ErrorAction Ignore; "GIPV-SECRET-SENTINEL"',
        'Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -ErrorAction SilentlyContinue',
        'gpv -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -ea Ignore',
        'Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -ErrorAction ([System.Management.Automation.ActionPreference]::Ignore)'
    )
    foreach ($source in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=GetItemPropertyValueIgnoresErrorAction command=Get-ItemPropertyValue') {
            throw "Get-ItemPropertyValue with non-effective ErrorAction was not rejected ($source): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('GIPV-SECRET-SENTINEL')) {
            throw 'Get-ItemPropertyValue rejection exposed source.'
        }
    }
    $validCases = @(
        'Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ProgramFilesDir"',
        'Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ProgramFilesDir" -ErrorAction Stop',
        '(Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -ErrorAction Ignore).PSObject.Properties["AutoAdminLogon"]?.Value'
    )
    foreach ($source in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($ok.exitCode -ne 0) { throw "Valid registry property lookup was rejected ($source): exit=$($ok.exitCode) stderr=$($ok.stderr)" }
    }
}

Assert-Case 'preflight rejects mixed top-level Select-Object pipelines with disjoint columns' {
    $invalidCases = @(
        'Get-CimInstance Win32_Processor | Select-Object Name; Get-Process -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,Path; "SELECT-SECRET-SENTINEL"',
        'Get-Date | select Year; Get-ChildItem | select Name,Length',
        'Get-Process | Select-Object -Property Name; $x = 1; Get-Service | Select-Object -Property Status,DisplayName'
    )
    foreach ($source in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=MixedSelectObjectFormatting command=Select-Object') {
            throw "Mixed top-level Select-Object was not rejected ($source): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('SELECT-SECRET-SENTINEL')) {
            throw 'Mixed Select-Object rejection exposed source.'
        }
    }
    $validCases = @(
        'Get-CimInstance Win32_Processor | Select-Object Name | Out-String; Get-Process | Select-Object Id,ProcessName | Out-String',
        '$cpu = Get-CimInstance Win32_Processor | Select-Object Name; $procs = Get-Process | Select-Object Id,ProcessName; [pscustomobject]@{ cpu = $cpu; procs = $procs } | ConvertTo-Json',
        'Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name; Get-Process | Select-Object Id,ProcessName',
        'Get-Item a | Select-Object Name,Length; Get-Item b | Select-Object Name,Length'
    )
    foreach ($source in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($ok.exitCode -ne 0) { throw "Valid Select-Object pipeline was rejected ($source): exit=$($ok.exitCode) stderr=$($ok.stderr)" }
    }
}

Assert-Case 'preflight rejects PowerShell background pipeline operator ampersand' {
    $invalidCases = @(
        'tasklist /fi "IMAGENAME eq SystemSettings.exe" & tasklist /fi "IMAGENAME eq ApplicationFrameHost.exe"; "BG-SECRET-SENTINEL"',
        'Get-Date &',
        'Write-Output "a" & Write-Output "b"'
    )
    foreach ($source in $invalidCases) {
        $result = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'syntax-error id=BackgroundPipelineOperator') {
            throw "Background '&' pipeline was not rejected ($source): exit=$($result.exitCode) stderr=$($result.stderr)"
        }
        if ($result.stdout -or $result.stderr.Contains('BG-SECRET-SENTINEL')) {
            throw 'Background pipeline rejection exposed source.'
        }
    }
    $validCases = @(
        '& "C:/Windows/System32/cmd.exe" /c "echo ok"',
        '$x = 1; & (Join-Path $PSHOME "pwsh.exe") -Version',
        'Write-Output "a & b"'
    )
    foreach ($source in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $source, '-CheckOnly')
        if ($ok.exitCode -ne 0) { throw "Valid call operator '&' was rejected ($source): exit=$($ok.exitCode) stderr=$($ok.stderr)" }
    }
}

Assert-Case 'preflight rejects uncleaned LASTEXITCODE after PSNativeCommandUseErrorActionPreference probe before JSON output' {
    $invalidSource = @'
$PSNativeCommandUseErrorActionPreference = $false
$hits = @(rg -n 'needle' 'D:/docs/index.md')
$code = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
$secret = 'PROBE-EXIT-SECRET-SENTINEL'
[pscustomobject]@{ status = 'ok'; code = $code } | ConvertTo-Json -Compress
'@
    $result = Invoke-PublicCli @('-CommandText', $invalidSource, '-CheckOnly')
    if ($result.exitCode -ne 2 -or $result.stderr -notmatch 'parameter-error id=UncleanedProbeExitCode command=ConvertTo-Json') {
        throw "Uncleaned probe LASTEXITCODE was not rejected: exit=$($result.exitCode) stderr=$($result.stderr)"
    }
    if ($result.stdout -or $result.stderr.Contains('PROBE-EXIT-SECRET-SENTINEL')) {
        throw 'UncleanedProbeExitCode rejection exposed source.'
    }
    $validResetSource = @'
$PSNativeCommandUseErrorActionPreference = $false
$hits = @(rg -n 'needle' 'D:/docs/index.md')
$code = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
$global:LASTEXITCODE = 0
[pscustomobject]@{ status = 'ok'; code = $code } | ConvertTo-Json -Compress
'@
    $okReset = Invoke-PublicCli @('-CommandText', $validResetSource, '-CheckOnly')
    if ($okReset.exitCode -ne 0) {
        throw "Valid reset $global:LASTEXITCODE = 0 was rejected: exit=$($okReset.exitCode) stderr=$($okReset.stderr)"
    }
    $validFuncHelperSource = @'
function Invoke-ProbeHelper {
    $PSNativeCommandUseErrorActionPreference = $false
    $PSNativeCommandUseErrorActionPreference = $true
}
[pscustomobject]@{ status = 'ok' } | ConvertTo-Json -Compress
'@
    $okHelper = Invoke-PublicCli @('-CommandText', $validFuncHelperSource, '-CheckOnly')
    if ($okHelper.exitCode -ne 0) {
        throw "Function-scoped helper preference toggle was rejected: exit=$($okHelper.exitCode) stderr=$($okHelper.stderr)"
    }
}

Assert-Case 'preflight rejects undersized 16-byte C# PROPVARIANT structs and accepts 24-byte layouts' {
    $badExplicit = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Explicit)]
public struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr ptrVal;
}
"@
'PROPVARIANT-SECRET-SENTINEL'
'@
    $badSequential = @'
$cs = '
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct PROPVARIANT {
    public ushort vt;
    public ushort w1;
    public ushort w2;
    public ushort w3;
    public IntPtr ptrVal;
}
'
Add-Type -TypeDefinition $cs
'@
    foreach ($src in @($badExplicit, $badSequential)) {
        $res = Invoke-PublicCli @('-CommandText', $src, '-CheckOnly')
        if ($res.exitCode -ne 2 -or $res.stderr -notmatch 'parameter-error id=UndersizedPropVariantStruct command=Add-Type') {
            throw "Undersized PROPVARIANT was not rejected: exit=$($res.exitCode) stderr=$($res.stderr)"
        }
        if ($res.stdout -or $res.stderr.Contains('PROPVARIANT-SECRET-SENTINEL')) {
            throw 'UndersizedPropVariantStruct rejection exposed source.'
        }
    }

    $goodSequential = @'
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct PROPVARIANT {
    public ushort vt;
    public ushort r1;
    public ushort r2;
    public ushort r3;
    public IntPtr ptrVal;
    public IntPtr ptrVal2;
}
'
'@
    $goodExplicitOffset = @'
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Explicit)]
public struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr ptrVal;
    [FieldOffset(16)] public ulong pad;
}
'
'@
    $goodExplicitSize = @'
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Explicit, Size = 24)]
public struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr ptrVal;
}
'
'@
    foreach ($src in @($goodSequential, $goodExplicitOffset, $goodExplicitSize)) {
        $ok = Invoke-PublicCli @('-CommandText', $src, '-CheckOnly')
        if ($ok.exitCode -ne 0) {
            throw "Valid 24-byte PROPVARIANT was rejected: exit=$($ok.exitCode) stderr=$($ok.stderr)"
        }
    }
}

Assert-Case 'default TruncateValidatedJson spills multi-byte UTF-8 payloads over 8500 bytes even under 8000 chars' {
    $utf8Spill = Join-Path $fixture 'spill-utf8-budget'
    $res = Invoke-PublicCli @(
        '-CommandText', '[pscustomobject]@{ status = "ok"; text = ("中" * 4000) } | ConvertTo-Json -Compress',
        '-RequiredJsonFields', 'status,text',
        '-TruncateValidatedJson',
        '-SpillDirectory', $utf8Spill
    )
    $note = [regex]::Match($res.stderr, 'CheckedPowerShell output-truncated stream=stdout shown=\d+ total=\d+ path=(?<path>.+?)\r?$', 'Multiline')
    if ($res.exitCode -ne 0 -or -not $note.Success -or -not $res.stdout.Contains('[CheckedPowerShell output-truncated:')) {
        throw "Multi-byte UTF-8 payload over 8500 bytes did not spill under default MaxOutputChars: exit=$($res.exitCode) stderr=$($res.stderr)"
    }
    if ($utf8.GetByteCount($res.stdout) -gt 9000) {
        throw "Truncated stdout UTF-8 byte count exceeded 9000 bytes: $($utf8.GetByteCount($res.stdout))"
    }
    $spilled = [IO.File]::ReadAllText($note.Groups['path'].Value, $utf8) | ConvertFrom-Json -ErrorAction Stop
    if ($spilled.text.Length -ne 4000) {
        throw 'Spilled multi-byte JSON payload lost characters.'
    }
}

Assert-Case 'preflight rejects Start-Process -Wait -PassThru piped into downstream consumers' {
    $invalidCases = @(
        "Start-Process -FilePath 'D:/app/tool.exe' -ArgumentList '--check' -Wait -PassThru | Select-Object ExitCode | ConvertTo-Json -Compress; 'WAIT-PIPE-SECRET-SENTINEL'",
        "saps 'C:/Windows/System32/cmd.exe' -ArgumentList '/c exit 7' -Wait -PassThru | ForEach-Object { `$_.ExitCode }"
    )
    foreach ($src in $invalidCases) {
        $res = Invoke-PublicCli @('-CommandText', $src, '-CheckOnly')
        if ($res.exitCode -ne 2 -or $res.stderr -notmatch 'parameter-error id=StartProcessWaitPipelineOrder command=Start-Process') {
            throw "Piped Start-Process -Wait -PassThru was not rejected ($src): exit=$($res.exitCode) stderr=$($res.stderr)"
        }
        if ($res.stdout -or $res.stderr.Contains('WAIT-PIPE-SECRET-SENTINEL')) {
            throw 'StartProcessWaitPipelineOrder rejection exposed source.'
        }
    }
    $validCases = @(
        "`$p = Start-Process -FilePath 'D:/app/tool.exe' -Wait -PassThru; `$p.ExitCode",
        "Start-Process -FilePath 'D:/app/tool.exe' -Wait -PassThru | Out-Null",
        "Start-Process -FilePath 'D:/app/tool.exe' -PassThru | Select-Object Id"
    )
    foreach ($src in $validCases) {
        $ok = Invoke-PublicCli @('-CommandText', $src, '-CheckOnly')
        if ($ok.exitCode -ne 0) {
            throw "Valid Start-Process usage was rejected ($src): exit=$($ok.exitCode) stderr=$($ok.stderr)"
        }
    }
}

Assert-Case 'Add-Type compilation errors expose Roslyn CS codes and coordinates without source identifiers' {
    $badAddType = @'
Add-Type -TypeDefinition @"
public class SecretTypeDoNotEcho {
    public static int SecretFieldDoNotEcho = "bad-string-do-not-echo";
}
"@
'@
    $res = Invoke-PublicCli @('-CommandText', $badAddType)
    if ($res.exitCode -ne 1 -or $res.stderr -notmatch 'compilerErrors=CS0029@\d+:\d+') {
        throw "Add-Type compilation failure did not report CS0029@line:col: exit=$($res.exitCode) stderr=$($res.stderr)"
    }
    if (($res.stdout + $res.stderr) -match 'SecretTypeDoNotEcho|SecretFieldDoNotEcho|bad-string-do-not-echo') {
        throw 'Add-Type compiler diagnostic leaked source identifiers or string literals.'
    }
}

$failed = @($cases | Where-Object status -eq 'failed')
$report = [ordered]@{
    status = if ($failed.Count) { 'failed' } else { 'passed' }
    cases = $cases.Count
    failures = $failed.Count
    fixture = $fixture
    runtime = $PSVersionTable.PSVersion.ToString()
    wrapperSha256 = (Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash
    testSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    results = $cases.ToArray()
}
$json = $report | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $fixture 'CheckedPowerShell-results.json'), $json, $utf8)
$json
if ($failed.Count) { exit 1 }
exit 0
