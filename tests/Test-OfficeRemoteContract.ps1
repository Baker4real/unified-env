#requires -Version 7.4
# host-live：核对宿主线上 Invoke-OfficeRemote.ps1 仍满足 managed/host-diagnostics 远端入口依赖的合同。
# 只用 -DryRun 和连接前拒绝，不连接任何远端。helper 归 ssh-mesh.md 维护，不在本仓库。
# 超长用例先由 helper 预检证实拒绝，再经部署后的 RemoteStep 核对同一拒绝的回执。
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$officeHelper = 'D:/Codex/.codex/scripts/Invoke-OfficeRemote.ps1'
if (-not (Test-Path -LiteralPath $officeHelper -PathType Leaf)) { throw "Live helper is missing: $officeHelper" }
$evidence = 'D:/agents/run-evidence/office-remote-contract-tests/' + [guid]::NewGuid().ToString('N')
$null = New-Item -ItemType Directory -Path $evidence -Force
$cases = 0

$helperText = [IO.File]::ReadAllText($officeHelper)
if ($helperText -notmatch 'Console\]::InputEncoding\s*=\s*\[System\.Text\.UTF8Encoding\]::new\(\$false\)') { throw 'Remote PowerShell prefix does not require UTF-8 input encoding' }
if ($helperText -notmatch "CODEX_REMOTE_EXECUTION_TARGET = '''\s*\+\s*\`$Target") { throw 'Remote prefix no longer injects the execution target marker' }
$cases++

function Invoke-RemoteEntry([string]$Entry, [string]$ScriptPath, [string[]]$Extra) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Entry, '-Target', 'study', '-ScriptPath', $ScriptPath) + $Extra) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Office helper dry-run timed out' }
    $text = $stdout.GetAwaiter().GetResult()
    # Invoke-RemoteStep 以 stdout 的最后一行 JSON 为业务门禁：拒绝与 dry-run 都必须只打印一行摘要。
    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) { throw "Helper printed $($lines.Count) stdout lines instead of one summary" }
    return [pscustomobject]@{ exitCode = $process.ExitCode; summary = ($lines[0] | ConvertFrom-Json); stderr = $stderr.GetAwaiter().GetResult() }
}

$directWrite = Join-Path $evidence 'direct-write.txt'
$guard = "if (`$env:CODEX_REMOTE_EXECUTION_TARGET -ne 'study') { throw 'Remote execution context required: study' }"
$guardedScript = Join-Path $evidence 'Guarded.ps1'
[IO.File]::WriteAllText($guardedScript, "$guard`n[IO.File]::WriteAllText('$directWrite', 'proof')`n", $utf8)
$guarded = Invoke-RemoteEntry $officeHelper $guardedScript @('-RequireRemoteContext', '-DryRun')
if ($guarded.exitCode -ne 0 -or $guarded.summary.result -ne 'dry-run') { throw "Guarded payload was rejected: $($guarded.stderr)" }
$cases++
$bodies = [ordered]@{
    unguarded = "[IO.File]::WriteAllText('$directWrite', 'proof')`n"
    commented = "# $guard`n[IO.File]::WriteAllText('$directWrite', 'proof')`n"
    late = "[IO.File]::WriteAllText('$directWrite', 'proof')`n$guard`n"
}
foreach ($kind in $bodies.Keys) {
    $script = Join-Path $evidence "Invalid-$kind.ps1"
    [IO.File]::WriteAllText($script, $bodies[$kind], $utf8)
    $refused = Invoke-RemoteEntry $officeHelper $script @('-RequireRemoteContext', '-DryRun')
    if ($refused.exitCode -ne 2 -or $refused.summary.result -ne 'refused' -or $refused.summary.reason -ne 'remote-context-assertion-missing' -or (Test-Path -LiteralPath $directWrite)) { throw "Payload without a leading assertion was accepted: $kind" }
    $cases++
}

$oversizedScript = Join-Path $evidence 'Oversized.ps1'
[IO.File]::WriteAllText($oversizedScript, "$guard`n# $('x' * 4000)`n", $utf8)
$preflight = Invoke-RemoteEntry $officeHelper $oversizedScript @('-RequireRemoteContext', '-DryRun')
if ($preflight.exitCode -ne 2 -or $preflight.summary.result -ne 'refused' -or $preflight.summary.reason -ne 'command-too-long' -or $preflight.summary.detail -notmatch '^([0-9]+) > 8000 ') {
    throw 'DryRun did not report the study command length and limit'
}
if ([int]$Matches[1] -le 8000) { throw 'DryRun reported a command length within the limit' }

$remoteStep = Join-Path ([IO.Path]::GetDirectoryName($officeHelper)) 'Invoke-RemoteStep.ps1'
$refused = Invoke-RemoteEntry $remoteStep $oversizedScript @('-WriteOperation', '-TimeoutSeconds', '5')
if ($refused.exitCode -ne 1 -or $refused.summary.status -ne 'refused' -or $refused.summary.reason -ne 'command-too-long' -or $null -ne $refused.summary.exitCode) {
    throw 'RemoteStep did not return a pre-connection refusal for the oversized script'
}
if ($refused.summary.detail -cne $preflight.summary.detail) { throw 'RemoteStep lost the encoded command length and limit' }
$cases++
[ordered]@{ status = 'passed'; evidence = $evidence; cases = $cases; oversizedCommand = $refused.summary.detail } | ConvertTo-Json -Compress
