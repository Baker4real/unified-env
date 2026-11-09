#requires -Version 7.4
# Read-StudyUuMarker → Invoke-RemoteStep → Invoke-OfficeRemote 都按同目录解析。helper 替身在本机子进程里
# 带着远端目标标记执行生成的脚本，模拟远端，所以 marker 文件真实存在于夹具目录。
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$repo = Split-Path -Parent $PSScriptRoot
$evidence = 'D:/agents/run-evidence/uu-marker-reader-tests/' + [guid]::NewGuid().ToString('N')
$fixture = Join-Path $evidence 'scripts'
$null = New-Item -ItemType Directory -Path $fixture -Force
foreach ($name in @('Read-StudyUuMarker.ps1', 'Invoke-RemoteStep.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "managed/host-diagnostics/$name") -Destination (Join-Path $fixture $name)
}
@'
param([string]$Target, [string]$ScriptPath, [string]$OutputPath, [string]$StdinScript, [int]$TimeoutSeconds, [switch]$RequireRemoteContext)
$utf8 = [Text.UTF8Encoding]::new($false)
$scriptFull = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($scriptFull), [IO.Path]::GetFileNameWithoutExtension($scriptFull))
$outPath = "$base.out.txt"
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $scriptFull)) { $psi.ArgumentList.Add($argument) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.Environment['CODEX_REMOTE_EXECUTION_TARGET'] = $Target
$process = [Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$null = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
[IO.File]::WriteAllText($outPath, $stdout.GetAwaiter().GetResult(), $utf8)
$exitCode = if ($env:FAKE_REMOTE_MODE -eq 'failed') { 1 } else { $process.ExitCode }
$result = if ($exitCode -eq 0) { 'ok' } else { 'failed' }
[ordered]@{ result = $result; target = $Target; exitCode = $exitCode; stdout = $outPath } | ConvertTo-Json -Compress
exit $exitCode
'@ | Set-Content -LiteralPath (Join-Path $fixture 'Invoke-OfficeRemote.ps1') -Encoding utf8
$entry = Join-Path $fixture 'Read-StudyUuMarker.ps1'

function New-Marker([string]$Directory, [string]$RunId, [int]$Index, [string]$Hash) {
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $path = Join-Path $Directory "command-$Index.json"
    [IO.File]::WriteAllText($path, ([ordered]@{ runId = $RunId; index = $Index; commandSha256 = $Hash } | ConvertTo-Json -Compress) + " `r`n", $utf8)
    $path
}
function Read-Marker([string]$Path, [string]$Hash, [string]$RunId, [int]$Index) {
    & $entry -MarkerPath $Path -ExpectedHash $Hash -RunId $RunId -Index $Index -EvidenceRoot (Join-Path $evidence 'runs')
}

$hash = 'ab' * 32
$marker = New-Marker (Join-Path $evidence 'markers/run-1') 'run-1' 0 $hash
$cases = 0
if ((Read-Marker $marker $hash 'run-1' 0) -ne $true) { throw 'A valid marker was not accepted by the reader' }
$cases++
if ((Read-Marker $marker ('cd' * 32) 'run-1' 0) -ne $false) { throw 'A marker with another command hash was accepted' }
$cases++
if ((Read-Marker (Join-Path $evidence 'markers/run-1/command-9.json') $hash 'run-1' 9) -ne $false) { throw 'A missing marker was accepted' }
$cases++
$quoted = New-Marker (Join-Path $evidence ("markers/quote$([char]0x2019)s 'run'")) "run$([char]0x2019)'2" 1 $hash
if ((Read-Marker $quoted $hash "run$([char]0x2019)'2" 1) -ne $true) { throw 'A marker path containing quotes was not read verbatim' }
$cases++
$env:FAKE_REMOTE_MODE = 'failed'
try {
    if ((Read-Marker $marker $hash 'run-1' 0) -ne $false) { throw 'A failed remote read was treated as proof' }
} finally { $env:FAKE_REMOTE_MODE = $null }
$cases++
[ordered]@{ status = 'passed'; evidence = $evidence; cases = $cases } | ConvertTo-Json -Compress
