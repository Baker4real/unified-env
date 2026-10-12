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
    param([string[]]$CliArguments)
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

Assert-Case 'PowerShell execution errors do not expose exception payloads' {
    $result = Invoke-PublicCli @('-CommandText', "throw 'synthetic-exception-do-not-echo'")
    if ($result.exitCode -ne 1 -or $result.stderr -notmatch 'runtime-error') { throw 'Runtime failure was not reported.' }
    if ($result.stderr.Contains('synthetic-exception-do-not-echo')) { throw 'Runtime failure exposed its exception payload.' }
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
