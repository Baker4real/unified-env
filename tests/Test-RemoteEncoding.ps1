#requires -Version 7.4
# Invoke-RemotePython 与 Invoke-RemoteStep 都从自身目录解析下一层：把两者复制进夹具目录，旁边放
# helper 替身。替身像真 helper 一样在本机运行 StdinScript，记下生成的远端脚本和发射出的 stdin。
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$repo = Split-Path -Parent $PSScriptRoot
$evidence = 'D:/agents/run-evidence/remote-encoding-tests/' + [guid]::NewGuid().ToString('N')
$fixture = Join-Path $evidence 'scripts'
$null = New-Item -ItemType Directory -Path $fixture -Force
foreach ($name in @('Invoke-RemotePython.ps1', 'Invoke-RemoteStep.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "managed/host-diagnostics/$name") -Destination (Join-Path $fixture $name)
}
$capture = Join-Path $evidence 'captured'
$null = New-Item -ItemType Directory -Path $capture -Force
@'
param([string]$Target, [string]$ScriptPath, [string]$OutputPath, [string]$StdinScript, [int]$TimeoutSeconds, [switch]$RequireRemoteContext)
$utf8 = [Text.UTF8Encoding]::new($false)
$capture = Join-Path (Split-Path -Parent $PSScriptRoot) 'captured'
Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $capture 'remote.ps1')
$stdinText = (& $StdinScript | Out-String).TrimEnd("`r", "`n")
[IO.File]::WriteAllText((Join-Path $capture 'stdin.txt'), $stdinText, $utf8)
[IO.File]::WriteAllText((Join-Path $capture 'require-remote-context.txt'), [string]$RequireRemoteContext.IsPresent, $utf8)
$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outPath)) -Force
[IO.File]::WriteAllText($outPath, 'fixture-output', $utf8)
[ordered]@{ result = 'ok'; target = $Target; exitCode = 0; stdout = $outPath } | ConvertTo-Json -Compress
exit 0
'@ | Set-Content -LiteralPath (Join-Path $fixture 'Invoke-OfficeRemote.ps1') -Encoding utf8

$smartQuote = [string][char]0x2019
$quoteDirectory = Join-Path $evidence ("quote$($smartQuote)s 'dir'")
$null = New-Item -ItemType Directory -Path $quoteDirectory -Force
$pythonScript = Join-Path $quoteDirectory 'unicode.py'
$pythonSource = "print('中文 🧪')`nprint('$($smartQuote)')`n"
[IO.File]::WriteAllText($pythonScript, $pythonSource, $utf8)
$pythonArguments = @("a$($smartQuote); Remove-Item x $($smartQuote)", "it's", 'say "hi"', '')
$cases = 0

$global:LASTEXITCODE = 0
$stepOutput = & (Join-Path $fixture 'Invoke-RemotePython.ps1') -Target study -PythonScriptPath $pythonScript -PythonArgument $pythonArguments -EvidenceRoot (Join-Path $evidence 'runs')
if ($LASTEXITCODE -ne 0) { throw "Remote Python entry failed: $stepOutput" }
if ((@($stepOutput)[-1] | ConvertFrom-Json).status -ne 'ok') { throw 'Remote Python did not pass the business gate' }

$remoteText = [IO.File]::ReadAllText((Join-Path $capture 'remote.ps1'))
if ($remoteText -notmatch "'-B'.*'-I'.*'-X'.*'utf8'.*'-'") { throw 'Remote Python was not forced to UTF-8 mode' }
if ($remoteText -notmatch 'Console\]::InputEncoding') { throw 'Remote Python wrapper did not set UTF-8 input encoding' }
$cases++

$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($remoteText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Generated remote script does not parse' }
$first = $ast.EndBlock.Statements[0]
if ($first -isnot [Management.Automation.Language.IfStatementAst] -or -not $first.Extent.Text.StartsWith("if (`$env:CODEX_REMOTE_EXECUTION_TARGET -ne 'study')")) { throw 'Generated remote script does not start with the target assertion' }
if ([IO.File]::ReadAllText((Join-Path $capture 'require-remote-context.txt')) -ne 'True') { throw 'Remote Python did not request the write gate' }
$cases++

# 参数原文不进脚本；解码语句还原出逐字相同的参数。
foreach ($argument in $pythonArguments | Where-Object { $_ }) {
    if ($remoteText.Contains($argument)) { throw 'A Python argument was spliced into the remote script' }
}
$assignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$additionalArguments' }, $true)
$decoded = @(& ([scriptblock]::Create($assignment.Extent.Text + '; $additionalArguments')))
if ($decoded.Count -ne $pythonArguments.Count) { throw "Decoded $($decoded.Count) Python arguments instead of $($pythonArguments.Count)" }
for ($i = 0; $i -lt $pythonArguments.Count; $i++) {
    if ([string]$decoded[$i] -cne $pythonArguments[$i]) { throw "Python argument $i did not round-trip" }
}
$cases++

$stdinText = [IO.File]::ReadAllText((Join-Path $capture 'stdin.txt'), $utf8)
if ($stdinText -cne $pythonSource.TrimEnd("`r", "`n")) { throw 'Python source under a quoted directory was not emitted verbatim' }
$cases++

# 生成的远端脚本在本机直接运行时，必须在启动 Python 之前停下。
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $capture 'remote.ps1'))) { $psi.ArgumentList.Add($argument) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
[void]$psi.Environment.Remove('CODEX_REMOTE_EXECUTION_TARGET')
$process = [Diagnostics.Process]::Start($psi)
$process.StandardInput.Close()
$localStderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Local remote-script run timed out' }
if ($process.ExitCode -eq 0 -or $localStderr.GetAwaiter().GetResult() -notmatch 'Remote execution context required: study') { throw 'Generated remote script ran locally without the target marker' }
$cases++
# 真正执行生成的 Python wrapper；不把 helper 的固定成功摘要当作退出码证明。
@'
param([string]$Target, [string]$ScriptPath, [string]$OutputPath, [string]$StdinScript, [int]$TimeoutSeconds, [switch]$RequireRemoteContext)
$utf8 = [Text.UTF8Encoding]::new($false)
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
foreach ($arg in @('-NoProfile','-NonInteractive','-File',$ScriptPath)) { $psi.ArgumentList.Add($arg) }
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardInputEncoding = $utf8
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$psi.Environment['CODEX_REMOTE_EXECUTION_TARGET'] = $Target
$proc = [Diagnostics.Process]::Start($psi)
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()
$proc.StandardInput.Write((& $StdinScript | Out-String))
$proc.StandardInput.Close()
if (-not $proc.WaitForExit(15000)) { $proc.Kill($true); throw 'Python fixture timed out' }
[IO.File]::WriteAllText($OutputPath, $outTask.GetAwaiter().GetResult(), $utf8)
[IO.File]::WriteAllText("$OutputPath.err", $errTask.GetAwaiter().GetResult(), $utf8)
[ordered]@{result=$(if ($proc.ExitCode -eq 0) {'ok'} else {'failed'});target=$Target;exitCode=$proc.ExitCode;stdout=$OutputPath;stderr="$OutputPath.err"} | ConvertTo-Json -Compress
exit $proc.ExitCode
'@ | Set-Content -LiteralPath (Join-Path $fixture 'Invoke-OfficeRemote.ps1') -Encoding utf8
$pythonExe = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
foreach ($failure in @('success','exit7','exception')) {
    $source = "import sys`nprint('中文 🧪')`n"
    if ($failure -eq 'exit7') { $source += "print('错误信号', file=sys.stderr)`nsys.exit(7)`n" }
    if ($failure -eq 'exception') { $source += "raise RuntimeError('fixture failure')`n" }
    [IO.File]::WriteAllText($pythonScript, $source, $utf8)
    $outer = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $fixture 'Invoke-RemotePython.ps1'),'-Target','study','-PythonScriptPath',$pythonScript,'-PythonExecutable',$pythonExe,'-EvidenceRoot',$evidence,'-IncludeOutput')) { $outer.ArgumentList.Add($arg) }
    $outer.UseShellExecute = $false; $outer.RedirectStandardOutput = $true; $outer.RedirectStandardError = $true
    $outer.StandardOutputEncoding = $utf8; $outer.StandardErrorEncoding = $utf8
    $proc = [Diagnostics.Process]::Start($outer)
    $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(20000)) { $proc.Kill($true); throw 'Remote Python caller timed out' }
    $text = $outTask.GetAwaiter().GetResult(); $errorText = $errTask.GetAwaiter().GetResult()
    if (-not $text.Trim()) { throw "No business summary for $failure : $errorText" }
    $result = $text | ConvertFrom-Json
    $expectedCode = switch ($failure) { 'success' {0} 'exit7' {7} 'exception' {1} }
    if ($result.exitCode -ne $expectedCode -or (($proc.ExitCode -eq 0) -ne ($expectedCode -eq 0))) { throw "Python exit was swallowed for $failure" }
    if (($result.status -eq 'ok') -ne ($failure -eq 'success')) { throw "Wrong summary status for $failure" }
    if ($result.output.Replace("`r`n", "`n") -cne "中文 🧪`n") { throw "UTF-8 stdout damaged for $failure" }
    $nativeError = [IO.File]::ReadAllText("$($result.outputPath).err", $utf8)
    if ($failure -eq 'exit7' -and $nativeError -notmatch '错误信号') { throw 'UTF-8 stderr damaged' }
    if ($failure -eq 'exception' -and $nativeError -notmatch 'RuntimeError: fixture failure') { throw 'Python exception was lost' }
    $cases++
}
[ordered]@{ status = 'passed'; evidence = $evidence; cases = $cases } | ConvertTo-Json -Compress
